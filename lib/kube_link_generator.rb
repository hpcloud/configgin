require 'base64'
require 'digest/sha1'
require 'kubeclient'
require 'uri'
require_relative 'exceptions'

# KubeLinkSpecs provides the information required to generate BOSH links by
# pretending to be a hash.
class KubeLinkSpecs
  # ANNOTATION_AZ is the Kube annotation for the (availability) zone
  ANNOTATION_AZ = 'failure-domain.beta.kubernetes.io/zone'.freeze

  def initialize(spec, namespace, kube_client, kube_client_stateful_set)
    @links = {}
    @client = kube_client
    @client_stateful_set = kube_client_stateful_set
    @namespace = namespace
    @spec = spec || {}
  end

  attr_reader :client, :spec, :namespace
  SLEEP_DURATION = 1

  def this_name
    spec['job']['name']
  end

  # pod_index returns a number for the given pod name. The number is expected to
  # be unique across all pods for the role.
  def pod_index(name)
    index = name.rpartition('-').last
    return index.to_i if /^\d+$/ =~ index

    # The pod name is something like role-abcxyz
    # Derive the index from the randomness that went into the suffix.
    # chars are the characters kubernetes might use to generate names
    # Copied from https://github.com/kubernetes/kubernetes/blob/52a6ad0acb26/staging/src/k8s.io/client-go/pkg/util/rand/rand.go#L73
    chars = 'bcdfghjklmnpqrstvwxz0123456789'
    index.chars.map { |c| chars.index(c) }.reduce(0) { |v, c| v * chars.length + c }
  end

  def _get_image_for_pod_spec(pod_spec)
    pod_spec.containers.map(&:image).sort.join("\n")
  end

  def _get_sts_image_for_role(role_name)
    statefulset = @client_stateful_set.get_stateful_set(role_name, namespace)
    _get_image_for_pod_spec statefulset.spec.template.spec
  end

  def _get_pods_for_role(role_name, sts_image)
    client
      .get_pods(namespace: namespace, label_selector: "app.kubernetes.io/component=#{role_name}")
      .select { |pod| _get_image_for_pod_spec(pod.spec) == sts_image }
  end

  def get_pods_for_role(role_name, job, options = {})
    sts_image = _get_sts_image_for_role(role_name)

    loop do
      # The 30.times loop exists to print out status messages
      30.times do
        1.times do
          pods = _get_pods_for_role(role_name, sts_image)
          good_pods = pods.select { |pod| pod.status.podIP }
          if options[:wait_for_all]
            break unless good_pods.length == pods.length
          end
          return good_pods unless good_pods.empty?
        end
        sleep SLEEP_DURATION
      end
      $stdout.puts "Waiting for pods for role #{role_name} and provider job #{job} (at #{Time.now})..."
      $stdout.flush
    end
  end

  def get_exported_properties(role_name, job_name)
    # Containers are not starting until all the properties they want to import already exist.
    # This is done using the CONFIGGIN_IMPORT_ROLE environment variables referencing the version
    # tag in the corresponding secret.
    secret = client.get_secret(role_name, namespace)
    begin
      JSON.parse(Base64.strict_decode64(secret.data["skiff-exported-properties-#{job_name}"]))
    rescue
      puts "Role #{role_name} is missing skiff-exported-properties-#{job_name}"
      fail
    end
  end

  def get_pod_instance_info(role_name, pod, job, pods_per_image)
    index = pod_index(pod.metadata.name)
    # Use pod DNS name for address field, instead of IP address which may change
    {
      'name' => pod.metadata.name,
      'index' => index,
      'id' => pod.metadata.name,
      'az' => pod.metadata.annotations['failure-domain.beta.kubernetes.io/zone'] || 'az0',
      'address' => "#{pod.metadata.name}.#{pod.spec.subdomain}.#{ENV['KUBERNETES_NAMESPACE']}.svc.#{ENV['KUBERNETES_CLUSTER_DOMAIN']}",
      'properties' => get_exported_properties(role_name, job),
      'bootstrap' => pods_per_image[pod.metadata.uid] < 2
    }
  end

  # Return the number of pods for each image
  def get_pods_per_image(pods)
    result = {}
    sets = Hash.new(0)
    keys = {}
    pods.each do |pod|
      next if pod.status.containerStatuses.nil?

      key = pod.status.containerStatuses.map(&:imageID).sort.join("\n")
      sets[key] += 1
      keys[pod.metadata.uid] = key
    end
    pods.each do |pod|
      result[pod.metadata.uid] = sets[keys[pod.metadata.uid]]
    end
    result
  end

  def get_svc_instance_info(role_name, job)
    svc = client.get_service(role_name, namespace)
    pod = get_pods_for_role(role_name, job).first
    {
      'name' => svc.metadata.name,
      'index' => 0, # Completely made up index; there is only ever one service
      'id' => svc.metadata.name,
      # XXX bogus, but what can we do?
      'az' => pod.metadata.annotations['failure-domain.beta.kubernetes.io/zone'] || 'az0',
      'address' => svc.spec.clusterIP,
      'properties' => get_exported_properties(role_name, job),
      'bootstrap' => true
    }
  end

  def get_statefulset_instance_info(role_name, job)
    ss = @client_stateful_set.get_stateful_set(role_name, namespace)
    pod = get_pods_for_role(role_name, job).first

    Array.new(ss.spec.replicas) do |i|
      {
        'name' => ss.metadata.name,
        'index' => i,
        'id' => ss.metadata.name,
        'az' => pod.metadata.annotations['failure-domain.beta.kubernetes.io/zone'] || 'az0',
        'address' => "#{ss.metadata.name}-#{i}.#{ss.spec.serviceName}",
        'properties' => get_exported_properties(role_name, job),
        # XXX not actually correct during updates
        'bootstrap' => i.zero?
      }
    end
  end

  def service?(role_name)
    client.get_service(role_name, namespace)
    true
  rescue KubeException
    false
  end

  def [](key)
    return @links[key] if @links.key? key

    # Resolve the role we're looking for
    provider = spec['consumes'][key]
    unless provider
      warn "No link provider found for #{key}"
      return @links[key] = nil
    end

    if provider['role'] == this_name
      warn "Resolving link #{key} via self provider #{provider}"
      pods = get_pods_for_role(provider['role'], provider['job'], wait_for_all: true)
      pods_per_image = get_pods_per_image(pods)
      instances = pods.map { |p| get_pod_instance_info(provider['role'], p, provider['job'], pods_per_image) }
    elsif service? provider['role']
      # Getting pods for a different service; since we have kube services, we don't handle it in configgin
      warn "Resolving link #{key} via service #{provider}"
      instances = [get_svc_instance_info(provider['role'], provider['job'])]
    else
      # If there's no service associated, check the statefulset instead
      warn "Resolving link #{key} via statefulset #{provider}"
      instances = get_statefulset_instance_info(provider['role'], provider['job'])
    end

    # Underscores aren't valid hostnames, so jobs are transformed in fissile to use dashes
    job_name = provider['job'].tr('_', '-')
    service_name = provider['service_name'] || "#{provider['role']}-#{job_name}"

    @links[key] = {
      'address' => "#{service_name}.#{ENV['KUBERNETES_NAMESPACE']}.svc.#{ENV['KUBERNETES_CLUSTER_DOMAIN']}",
      'instance_group' => '', # This is probably the role name from the manifest
      'default_network' => '',
      'deployment_name' => namespace,
      'domain' => "#{ENV['KUBERNETES_NAMESPACE']}.svc.#{ENV['KUBERNETES_CLUSTER_DOMAIN']}",
      'root_domain' => "#{ENV['KUBERNETES_NAMESPACE']}.svc.#{ENV['KUBERNETES_CLUSTER_DOMAIN']}",
      'instances' => instances,
      'properties' => instances.first['properties']
    }
  end
end

# KubeDNSEncoder is a BOSH DNS encoder object. It is unclear at this point what it does.
class KubeDNSEncoder
  def initialize(link_specs)
    @link_specs = link_specs
  end
end
