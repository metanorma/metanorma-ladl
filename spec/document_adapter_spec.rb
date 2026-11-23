# frozen_string_literal: true

require_relative "spec_helper"
require "nokogiri"
require "metanorma/ladl/document_adapter"
require "metanorma/iso/document"

RSpec.describe Metanorma::Ladl::DocumentAdapter do
  let(:adapter) { described_class.new(mode: :presentation) }
  let(:engine) { Metanorma::Ladl::Engine.new(profile: iso_profile) }
  let(:body) do
    <<~XML
      <sections><clause id="clause"><title>Original <em>title</em></title>
      <clause id="subclause"/><figure id="figure"><figure id="subfigure"/></figure>
      <table id="table"/><note id="note"><p>Original note</p></note><example id="example"/>
      <formula id="formula"/><ol id="list"><li id="level1"><ol><li id="level2"><ol><li id="level3"><ol><li id="level4"/></ol></li></ol></li></ol></li></ol>
      <ul><li id="unordered"/></ul></clause></sections>
      <annex id="annex"><clause id="annex_clause"/><figure id="annex_figure"/><table id="annex_table"/>
      <formula id="annex_formula"/><ol id="annex_list"/></annex>
    XML
  end
  let(:xml) { '<metanorma xmlns="https://www.metanorma.org/ns/standoc" type="presentation">' + body + '</metanorma>' }

  before { Lutaml::Model::Config.xml_adapter_type = :nokogiri }

  def nodes(root, adapter = self.adapter)
    out, pending = [], [root]
    until pending.empty?
      node = pending.shift
      out << node
      pending.concat(adapter.children(node))
    end
    out
  end

  [Metanorma::Standoc::Document::Root, Metanorma::Iso::Document::Root].each do |root_class|
    it "assigns native persisted labels for all twenty labellers on #{root_class}" do
      root = root_class.from_xml(xml)
      before_title = root.sections.clause.first.title.to_xml
      expect(engine.call(root, adapter: adapter)).to equal(root)
      by_id = nodes(root).to_h { |n| [adapter.identifier(n), n] }
      expected = { "clause" => "Clause 1", "subclause" => "1.1", "annex" => "Annex A",
        "annex_clause" => "A.1", "figure" => "Figure 1", "annex_figure" => "Figure A.1",
        "subfigure" => "Figure 1 a)", "table" => "Table 1", "annex_table" => "Table A.1",
        "note" => "NOTE", "example" => "EXAMPLE", "formula" => "(1)",
        "annex_formula" => "(A.1)", "list" => "List 1", "annex_list" => "List A.1",
        "unordered" => "—", "level1" => "a)", "level2" => "1)", "level3" => "i)", "level4" => "a)" }
      actual = expected.keys.to_h { |id| [id, adapter.label_for(by_id.fetch(id), form: :local)] }
      expect(actual).to eq(expected)
      expect(expected.keys.map { |id| adapter.label_data(by_id[id]).labeller }.uniq.sort).to eq(iso_profile.labellers.map(&:id).sort)
      first_xml = root.to_xml
      engine.call(root, adapter: adapter)
      expect(root.to_xml).to eq(first_xml)
      expect(root.sections.clause.first.title.to_xml).to eq(before_title)
      parsed = root_class.from_xml(first_xml)
      roundtrip = nodes(parsed).to_h { |n| [adapter.identifier(n), n] }
      expected.each { |id, label| expect(adapter.label_for(roundtrip.fetch(id), form: :local)).to eq(label) }
      expect(adapter.label_for(roundtrip.fetch("note"))).to eq("Clause 1, NOTE")
    end
  end

  it "keeps sibling nested clauses and annex counters on actual containing owners" do
    xml = '<metanorma xmlns="https://www.metanorma.org/ns/standoc" type="presentation"><sections><clause id="c1"><clause id="s1"/><clause id="s2"/></clause><clause id="c2"><clause id="s3"/></clause></sections><annex id="a"><clause id="a1"/><clause id="a2"/><figure id="af"/></annex><annex id="b"><clause id="b1"/><figure id="bf"/></annex></metanorma>'
    root = Metanorma::Standoc::Document::Root.from_xml(xml)
    engine.call(root, adapter: adapter)
    got = nodes(root).to_h { |n| [adapter.identifier(n), adapter.label_for(n, form: :local)] }
    expect(got.slice("s1", "s2", "s3", "a1", "a2", "b1", "af", "bf")).to eq(
      "s1" => "1.1", "s2" => "1.2", "s3" => "2.1", "a1" => "A.1", "a2" => "A.2", "b1" => "B.1", "af" => "Figure A.1", "bf" => "Figure B.1")
  end

  it "shares main-document figure counts and restarts conditional note labels per native clause" do
    fragment = '<sections><clause id="c1"><figure id="f1"/><note id="n1"/><note id="n2"/></clause><clause id="c2"><figure id="f2"/><note id="n3"/></clause></sections><annex id="a"><note id="an"/></annex>'
    root = Metanorma::Standoc::Document::Root.from_xml('<metanorma xmlns="https://www.metanorma.org/ns/standoc" type="presentation">' + fragment + '</metanorma>')
    engine.call(root, adapter: adapter)
    got = nodes(root).to_h { |n| [adapter.identifier(n), adapter.label_for(n, form: :local)] }
    expect(got.slice("f1", "f2", "n1", "n2", "n3", "an")).to eq(
      "f1" => "Figure 1", "f2" => "Figure 2", "n1" => "NOTE 1", "n2" => "NOTE 2", "n3" => "NOTE", "an" => "NOTE")
  end

  it "includes appended native children and recounts without replacing source objects" do
    root = Metanorma::Standoc::Document::Root.from_xml(xml)
    clause = root.sections.clause.first
    note = clause.notes.first
    engine.call(root, adapter: adapter)
    expect(adapter.label_for(note, form: :local)).to eq("NOTE")
    added = Metanorma::Document::Components::Blocks::NoteBlock.new(id: "new-note")
    clause.notes << added
    engine.call(root, adapter: adapter)
    expect(clause.notes.first).to equal(note)
    expect(clause.notes.last).to equal(added)
    expect(adapter.label_for(note, form: :local)).to eq("NOTE 1")
    expect(adapter.label_for(added, form: :local)).to eq("NOTE 2")
    clause.notes << added
    original = note.to_xml
    expect { engine.call(root, adapter: adapter) }.to raise_error(Metanorma::Ladl::TreeError, /tree/)
    expect(note.to_xml).to eq(original)
  end

  it "persists six-field metadata on actual legacy string-slot block models" do
    root = Metanorma::Standoc::Document::Root.from_xml(xml)
    engine.call(root, adapter: adapter)
    clause = root.sections.clause.first
    data = adapter.label_data(clause)
    label = Metanorma::Ladl::Label.new(**%i[local global value direction global_direction labeller].to_h { |key| [key, data.public_send(key)] })
    classes = Metanorma::Standoc::Document::Blocks
    [classes::StandardFigureBlock, classes::StandardTableBlock, classes::StandardNoteBlock].each do |klass|
      node = klass.new(id: "legacy")
      expect(klass.attributes.fetch(:fmt_xref_label).type).to eq(Lutaml::Model::Type::String)
      adapter.assign(node, label)
      parsed = klass.from_xml(node.to_xml)
      expect(parsed.fmt_xref_label).to eq("Clause 1")
      expect(adapter.label_for(parsed, form: :local)).to eq("Clause 1")
      expect(adapter.label_data(parsed)).to be_a(Metanorma::Document::Components::Inline::FmtLadlLabelData)
    end
  end

  it "preserves authored mixed labels while deterministically replacing only its generated label" do
    root = Metanorma::Standoc::Document::Root.from_xml(xml.sub('<title>', '<fmt-xref-label>before<semx element="autonum" source="clause">old</semx>after</fmt-xref-label><title>'))
    clause = root.sections.clause.first
    original = clause.fmt_xref_label.first.to_xml
    engine.call(root, adapter: adapter)
    expect(clause.fmt_xref_label.first.to_xml).to eq(original)
    expect(clause.fmt_xref_label.length).to eq(2)
    engine.call(root, adapter: adapter)
    expect(clause.fmt_xref_label.length).to eq(2)
    expect(clause.fmt_xref_label.first.to_xml).to eq(original)
  end

  it "rejects semantic processing without mutation" do
    root = Metanorma::Standoc::Document::Root.from_xml(xml.sub('type="presentation"', 'type="semantic"'))
    original = root.to_xml
    expect { described_class.new(mode: :semantic) }.to raise_error(Metanorma::Ladl::TreeError, /presentation/)
    expect { engine.call(root, adapter: adapter) }.to raise_error(Metanorma::Ladl::TreeError, /presentation/)
    expect(root.to_xml).to eq(original)
  end

  it "does not leave labels partially assigned on a later duplicate identifier" do
    root = Metanorma::Standoc::Document::Root.from_xml(xml.sub('id="annex"', 'id="clause"'))
    original = root.to_xml
    expect { engine.call(root, adapter: adapter) }.to raise_error(Metanorma::Ladl::TreeError, /Duplicate/)
    expect(root.to_xml).to eq(original)
  end
end
