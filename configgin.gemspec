lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'configgin/version'

Gem::Specification.new do |spec|
  spec.name          = 'configgin'
  spec.version       = Configgin::VERSION
  spec.authors       = ['SUSE']

  spec.summary       = 'A simple cli app in Ruby to generate configurations using BOSH ERB templates and a BOSH spec.'
  spec.description   = 'A simple cli app in Ruby to generate configurations using BOSH ERB templates and a BOSH spec, but also using configurations based on environment variables, processed using a set of templates.'
  spec.homepage      = 'https://github.com/SUSE/configgin'
  spec.licenses      = ['Apache-2.0']

  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.bindir        = 'bin'
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '~> 1.10'
  spec.add_development_dependency 'rake', '~> 10.0'

  spec.add_dependency 'bosh-template', '~> 2.0'
  spec.add_dependency 'deep_merge', '~> 1.1'
  spec.add_dependency 'kubeclient', '~>4.3'
  spec.add_dependency 'mustache', '~> 1.0'
  spec.add_dependency 'rainbow', '~>2.0', '!=2.2.1'
end
