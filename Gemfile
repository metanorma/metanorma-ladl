source "https://rubygems.org"
gemspec

gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"

# Development lint gate.
gem "rubocop", "~> 1.92", require: false
gem "rubocop-rspec", require: false
gem "rubocop-performance", require: false
gem "rubocop-rake", require: false

# Native integration is opt-in until the presentation metadata SDK is released.
# LADL_NATIVE=1 bundle install enables the pinned SDK and flavor fixtures.
if ENV["LADL_NATIVE"] == "1"
  gem "amath", "= 0.2.0"
  gem "metanorma-document", git: "https://github.com/metanorma/metanorma-document.git",
      ref: "328e45559a98fab536e1955ed0fc960b6d0390cf"
  gem "metanorma-iso", "= 3.5.28"
  gem "metanorma-standoc", git: "https://github.com/metanorma/metanorma-standoc.git",
      ref: "e4918b4b801de5346220b3a9bdf1dcfdc939a5d9"
  gem "bigdecimal", "= 3.3.1"
end
