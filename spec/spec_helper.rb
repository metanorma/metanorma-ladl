# frozen_string_literal: true

require "rspec"
require_relative "../lib/metanorma/ladl"

module LadlFixtures
  def iso_profile
    Metanorma::Ladl::Profile.iso_iec
  end

  def element(id, type, context = nil, *children)
    Metanorma::Ladl::ContentElement.new(id: id, type: type, context: context).add(*children)
  end

  def minimal_data(sequence: "DecimalNumericSequence", pattern: "Clause %n")
    ref = ->(name) { { "ref" => name } }
    { "schema" => "mn112/1", "instances" => [
      { "name" => "Style", "type" => "LabelStyle", "properties" => {
        "name" => "Test style", "contexts" => [ref.call("DocumentContext")],
        "templates" => [ref.call("Template")], "sequences" => [ref.call(sequence)],
        "labellers" => [ref.call("ClauseLabeller")] } },
      { "name" => "DocumentContext", "type" => "LabelContext", "properties" => { "name" => "document" } },
      { "name" => "Template", "type" => "LabelTemplate", "properties" => { "pattern" => pattern } },
      { "name" => "ClauseLabeller", "type" => "Labeller", "properties" => {
        "id" => "clause", "type" => "clause", "context" => ref.call("DocumentContext"),
        "sequence" => ref.call(sequence), "template" => ref.call("Template") } },
    ] }
  end

  def profile_data(data)
    Metanorma::Ladl::Profile.from_yaml(YAML.safe_dump(data, aliases: false))
  end
end

RSpec.configure { |config| config.include(LadlFixtures) }
