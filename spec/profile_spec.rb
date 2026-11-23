# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Metanorma::Ladl::Profile do
  let(:candidate) { File.read(File.expand_path("../ladl/iso-iec.lml", __dir__)) }

  it "loads all 66 declarations, 20 labellers and 6 contexts from the corrected worked instance" do
    profile = described_class.from_lml(candidate)
    expect(profile.instances.length).to eq(66)
    expect(profile.labellers.length).to eq(20)
    expect(profile.contexts.length).to eq(6)
    expect(profile.instances.count { |i| i.type == "LabelTemplate" }).to eq(39)
  end

  it "round-trips the entire profile through both official-parser LML and safe YAML" do
    profile = described_class.from_lml(candidate)
    expect(described_class.from_yaml(profile.to_yaml).to_h).to eq(profile.to_h)
    expect(described_class.from_lml(profile.to_lml).to_h).to eq(profile.to_h)
    expect(iso_profile.to_h).to eq(profile.to_h)
  end

  it "preserves multiline definitions, escaped quotes, backslashes and empty strings" do
    data = minimal_data
    data["instances"][0]["properties"]["definition"] = "a \"quote\", \\ path\nand another line"
    data["instances"][2]["properties"]["pattern"] = ""
    profile = profile_data(data)
    expect(described_class.from_lml(profile.to_lml).to_h).to eq(profile.to_h)
  end

  it "extracts authored keyword-inline definitions without parser capture metadata" do
    text = <<~'LML'
      LabelTemplate "Inline" {
        pattern = "%n"
        definition "A \"quoted\" label, C:\\labels, Ελληνικά — 日本語"
      }
      LabelTemplate "Empty" {
        pattern = "%n"
        definition ""
      }
      LabelTemplate "Multiline" {
        pattern = "%n"
        definition "first line
      second line"
      }
      LabelTemplate "Block" {
        pattern = "%n"
        definition {
          Block preserves layout and literal C:\labels.
        }
      }
    LML
    definitions = Metanorma::Ladl::LmlCodec.load(text).map { |i| i.fetch("properties").fetch("definition") }
    expect(definitions).to eq([
      'A "quoted" label, C:\\labels, Ελληνικά — 日本語',
      "", "first line\nsecond line",
      "\n    Block preserves layout and literal C:\\labels.\n  "
    ])
  end

  it "retains independently authored worked-profile definition meanings" do
    instances = described_class.from_lml(candidate).to_h.fetch("instances")
    by_name = instances.to_h { |i| [i.fetch("name"), i.fetch("properties").fetch("definition")] }
    expect(by_name.fetch("DocumentContext")).to eq("Top-level document context for ISO/IEC documents")
    expect(by_name.fetch("ClauseLabelTemplate")).to eq("Template for local clause references")
    expect(by_name.fetch("OrderedListItemLevel4Labeller")).to eq("Labeller for fourth level ordered list items")
    expect(by_name.values).to all(be_a(String))
    expect(by_name.values.grep(/\{:string|"@\d+/)).to be_empty
  end

  it "rejects the untouched source's unsupported draft instance syntax" do
    source = File.read(File.expand_path("fixtures/iso-original.lml", __dir__))
    expect { described_class.from_lml(source) }.to raise_error(Metanorma::Ladl::ProfileError, /Invalid supported LML/)
  end

  it "rejects opaque parser fall-through instead of losing unsupported values" do
    text = "LabelTemplate \"Bad\" {\n pattern = unquoted opaque text\n}\n"
    expect { described_class.from_lml(text) }.to raise_error(Metanorma::Ladl::UnsupportedFeature, /Opaque LML/)
  end

  it "rejects executable requires and model definitions without evaluating them" do
    expect { described_class.from_lml('require "some-library"') }
      .to raise_error(Metanorma::Ladl::UnsupportedFeature, /executable/)
    expect { described_class.from_lml('class Unexpected { }') }
      .to raise_error(Metanorma::Ladl::UnsupportedFeature, /Only LML instance/)
  end

  it "rejects YAML aliases, Ruby object tags and duplicate keys" do
    expect { described_class.from_yaml("schema: &v mn112/1\ninstances: *v\n") }
      .to raise_error(Metanorma::Ladl::ProfileError)
    expect { described_class.from_yaml("--- !ruby/object:Object {}") }
      .to raise_error(Metanorma::Ladl::ProfileError)
    expect { described_class.from_yaml("schema: mn112/1\nschema: another\ninstances: []\n") }
      .to raise_error(Metanorma::Ladl::ProfileError, /Duplicate YAML key/)
  end

  it "rejects unknown properties and unresolved references" do
    data = minimal_data
    data["instances"][3]["properties"]["executable"] = "run()"
    expect { profile_data(data) }.to raise_error(Metanorma::Ladl::ProfileError, /unknown properties/)
    data["instances"][3]["properties"].delete("executable")
    data["instances"][3]["properties"]["context"] = { "ref" => "Missing" }
    expect { profile_data(data) }.to raise_error(Metanorma::Ladl::ProfileError, /Unknown context/)
  end

  it "rejects cycles independently in contexts, labellers and sequences" do
    data = minimal_data
    data["instances"][1]["properties"]["parent"] = { "ref" => "DocumentContext" }
    expect { profile_data(data) }.to raise_error(Metanorma::Ladl::ProfileError, /Context inheritance cycle/)
    data = minimal_data
    data["instances"][3]["properties"]["parent"] = { "ref" => "ClauseLabeller" }
    expect { profile_data(data) }.to raise_error(Metanorma::Ladl::ProfileError, /Labeller inheritance cycle/)
    data = minimal_data(sequence: "Circular")
    data["instances"] << { "name" => "Circular", "type" => "NumericSequence", "properties" => { "base_sequence" => { "ref" => "Circular" } } }
    expect { profile_data(data) }.to raise_error(Metanorma::Ladl::ProfileError, /Sequence inheritance cycle/)
  end

  it "rejects ambiguous labellers and unsafe or recursive placeholder definitions" do
    data = minimal_data
    other = Marshal.load(Marshal.dump(data["instances"].last))
    other["name"], other["properties"]["id"] = "Other", "other"
    data["instances"] << other
    data["instances"][0]["properties"]["labellers"] << { "ref" => "Other" }
    expect { profile_data(data) }.to raise_error(Metanorma::Ladl::ProfileError, /Ambiguous labellers/)
    expect { profile_data(minimal_data(pattern: "%eval")) }.to raise_error(Metanorma::Ladl::UnsupportedFeature)
    expect { profile_data(minimal_data(pattern: "%self")) }.to raise_error(Metanorma::Ladl::ProfileError, /recursively/)
  end

  it "is immutable after validation while exported data is an independent copy" do
    profile = iso_profile
    expect { profile.labellers.clear }.to raise_error(FrozenError)
    expect { profile.instances.first.properties["name"] = "changed" }.to raise_error(FrozenError)
    data = profile.to_h
    data["instances"].clear
    expect(profile.instances.length).to eq(66)
  end

  it "rejects contradictory explicit context bindings and builtin redefinition" do
    data = minimal_data
    data["instances"][1]["properties"]["labellers"] = ["id:absent"]
    expect { profile_data(data) }.to raise_error(Metanorma::Ladl::ProfileError, /binding/)
    data = minimal_data
    data["instances"] << { "name" => "DecimalNumericSequence", "type" => "CharacterSequence", "properties" => { "characters" => ["x"] } }
    expect { profile_data(data) }.to raise_error(Metanorma::Ladl::ProfileError, /Cannot redefine/)
  end
end
