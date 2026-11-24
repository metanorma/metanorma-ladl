# frozen_string_literal: true

module LadlNativeSpecs
  OPTIONAL_REQUIRES = %w[nokogiri metanorma/document
                         metanorma/document/components/inline/fmt_ladl_label_data
                         metanorma/standoc/document metanorma/iso/document
                         isodoc/iso/presentation_xml_convert isodoc/iso/html_convert
                         metanorma/iso/publisher_identity metanorma/requirements/requirements].freeze

  def self.available?(legacy: false)
    require "nokogiri"
    require "metanorma/ladl/document_adapter"
    require "metanorma/iso/document"
    if legacy
      require "isodoc/iso/presentation_xml_convert"
      require "isodoc/iso/html_convert"
      require "metanorma/iso/publisher_identity"
      require "metanorma/requirements/requirements"
    end
    true
  rescue LoadError => e
    # Suppress only missing optional dependencies. Internal adapter load errors
    # must still fail when the integration bundle was explicitly requested.
    raise if ENV["LADL_NATIVE"] == "1" || !OPTIONAL_REQUIRES.include?(e.path)

    reason = "Optional native SDK unavailable (#{e.path}); use LADL_NATIVE=1 bundle install"
    RSpec.describe "Optional native LADL integration" do
      it("requires the development SDK and flavor models") { skip reason }
    end

    false
  end
end
