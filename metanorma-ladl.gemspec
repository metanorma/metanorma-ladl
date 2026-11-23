require_relative "lib/metanorma/ladl/version"
Gem::Specification.new do |s|
  s.name = "metanorma-ladl"
  s.version = Metanorma::Ladl::VERSION
  s.authors = ["Ribose Inc."]
  s.summary = "Declarative Metanorma label assignment"
  s.license = "BSD-2-Clause"
  s.homepage = "https://github.com/metanorma/metanorma-ladl"
  s.description = "Parse declarative label profiles and assign persistent labels to Metanorma presentation models."
  s.required_ruby_version = ">= 3.3"
  s.files = Dir["lib/**/*.rb", "ladl/iso-iec.lml", "ladl/iso-iec.yaml", "ladl/README.adoc", "README.adoc", "LICENSE.txt"].select { |f| File.file?(f) }
  s.require_paths = ["lib"]
  s.add_dependency "lutaml-model", "~> 0.8"
  s.add_dependency "lutaml-lml", ">= 0.3.6", "< 0.3.7"
end
