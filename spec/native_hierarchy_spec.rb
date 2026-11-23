# frozen_string_literal: true

require_relative "spec_helper"
require "nokogiri"
require "metanorma/ladl/document_adapter"
require "metanorma/iso/document"

RSpec.describe "LADL native hierarchy and context parity" do
  let(:adapter) { Metanorma::Ladl::DocumentAdapter.new(mode: :presentation) }
  let(:engine) { Metanorma::Ladl::Engine.new(profile: iso_profile) }

  before { Lutaml::Model::Config.xml_adapter_type = :nokogiri }

  def doc(root_class, body)
    root_class.from_xml(%(<metanorma xmlns="https://www.metanorma.org/ns/standoc" type="presentation">#{body}</metanorma>))
  end

  def walk(root)
    out, pending = {}, [root]
    until pending.empty?
      node = pending.shift
      id = adapter.identifier(node)
      out[id] = node if id
      pending.concat(adapter.children(node))
    end
    out
  end

  def labels(root, form: :local)
    walk(root).transform_values { |node| adapter.label_for(node, form: form) }
  end

  def run(root_class, body)
    root = doc(root_class, body)
    engine.call(root, adapter: adapter)
    root
  end

  LADL_HIERARCHY_MAIN = <<~XML
    <sections>
      <clause id="c1">
        <clause id="c1_1">
          <clause id="c1_1_1"><clause id="c1_1_1_1"><note id="deep_note"/></clause><clause id="c1_1_1_2"/></clause>
          <clause id="c1_1_2"/>
        </clause>
        <clause id="c1_2"><clause id="c1_2_1"/></clause>
      </clause>
      <clause id="c2"><clause id="c2_1"><clause id="c2_1_1"/></clause></clause>
    </sections>
  XML

  LADL_HIERARCHY_ANNEX = <<~XML
    <annex id="a">
      <clause id="a1">
        <clause id="a1_1"><clause id="a1_1_1"><note id="annex_deep_note"/></clause><clause id="a1_1_2"/></clause>
        <clause id="a1_2"/>
      </clause>
      <clause id="a2"><clause id="a2_1"/></clause>
    </annex>
    <annex id="b"><clause id="b1"><clause id="b1_1"/></clause></annex>
  XML

  LADL_HIERARCHY_ASSETS = <<~XML
    <sections>
      <clause id="c1">
        <figure id="f1"><figure id="f1a"/><figure id="f1b"/></figure>
        <note id="clause_note"/>
      </clause>
      <clause id="c2"><figure id="f2"><figure id="f2a"/></figure></clause>
    </sections>
    <annex id="a">
      <clause id="a1"><clause id="a1_1"><figure id="af1"><figure id="af1a"/><figure id="af1b"/></figure><ol id="al1"/></clause></clause>
      <clause id="a2"><figure id="af2"><figure id="af2a"/></figure><table id="at1"/></clause>
    </annex>
    <annex id="b"><figure id="bf1"><figure id="bf1a"/></figure></annex>
  XML

  LADL_HIERARCHY_NOTES = <<~XML
    <sections>
      <clause id="c1">
        <figure id="f1"><note id="fn1"/><note id="fn2"/></figure>
        <table id="t1"><note id="tn1"/></table>
        <note id="cn1"/>
      </clause>
    </sections>
    <annex id="a"><clause id="a1"><figure id="af1"><note id="afn1"/></figure><table id="at1"><note id="atn1"/><note id="atn2"/></table></clause></annex>
  XML

  [Metanorma::Standoc::Document::Root, Metanorma::Iso::Document::Root].each do |root_class|
    context root_class.name do
      it "numbers four main-clause depths and restarts siblings" do
        got = labels(run(root_class, LADL_HIERARCHY_MAIN))
        expect(got.slice("c1", "c1_1", "c1_1_1", "c1_1_1_1", "c1_1_1_2", "c1_1_2", "c1_2", "c1_2_1", "c2", "c2_1", "c2_1_1")).to eq(
          "c1" => "Clause 1", "c1_1" => "1.1", "c1_1_1" => "1.1.1", "c1_1_1_1" => "1.1.1.1",
          "c1_1_1_2" => "1.1.1.2", "c1_1_2" => "1.1.2", "c1_2" => "1.2", "c1_2_1" => "1.2.1",
          "c2" => "Clause 2", "c2_1" => "2.1", "c2_1_1" => "2.1.1",
        )
      end

      it "numbers annex clauses recursively and restarts per parent and annex" do
        got = labels(run(root_class, LADL_HIERARCHY_ANNEX))
        expect(got.slice("a", "a1", "a1_1", "a1_1_1", "a1_1_2", "a1_2", "a2", "a2_1", "b", "b1", "b1_1")).to eq(
          "a" => "Annex A", "a1" => "A.1", "a1_1" => "A.1.1", "a1_1_1" => "A.1.1.1", "a1_1_2" => "A.1.1.2",
          "a1_2" => "A.1.2", "a2" => "A.2", "a2_1" => "A.2.1", "b" => "Annex B", "b1" => "B.1", "b1_1" => "B.1.1",
        )
      end

      it "uses the compound clause label in deep note global labels" do
        root = run(root_class, LADL_HIERARCHY_MAIN + LADL_HIERARCHY_ANNEX)
        got = labels(root, form: :global)
        expect(got.fetch("deep_note")).to eq("1.1.1.1, NOTE")
        expect(got.fetch("annex_deep_note")).to eq("A.1.1.1, NOTE")
      end

      it "restarts subfigures per parent figure, including annex figures" do
        got = labels(run(root_class, LADL_HIERARCHY_ASSETS))
        expect(got.slice("f1a", "f1b", "f2a", "af1a", "af1b", "af2a", "bf1a")).to eq(
          "f1a" => "Figure 1 a)", "f1b" => "Figure 1 b)", "f2a" => "Figure 2 a)",
          "af1a" => "Figure A.1 a)", "af1b" => "Figure A.1 b)", "af2a" => "Figure A.2 a)", "bf1a" => "Figure B.1 a)",
        )
      end

      it "counts assets in nested annex clauses across the whole annex" do
        got = labels(run(root_class, LADL_HIERARCHY_ASSETS))
        expect(got.slice("f1", "f2", "af1", "af2", "bf1", "at1", "al1")).to eq(
          "f1" => "Figure 1", "f2" => "Figure 2", "af1" => "Figure A.1", "af2" => "Figure A.2",
          "bf1" => "Figure B.1", "at1" => "Table A.1", "al1" => "List A.1",
        )
      end

      it "scopes figure and table notes to their asset" do
        root = run(root_class, LADL_HIERARCHY_NOTES)
        expect(labels(root).slice("fn1", "fn2", "tn1", "cn1", "afn1", "atn1", "atn2")).to eq(
          "fn1" => "NOTE 1", "fn2" => "NOTE 2", "tn1" => "NOTE", "cn1" => "NOTE",
          "afn1" => "NOTE", "atn1" => "NOTE 1", "atn2" => "NOTE 2",
        )
        expect(labels(root, form: :global).slice("fn1", "tn1", "cn1", "afn1", "atn2")).to eq(
          "fn1" => "Figure 1, NOTE 1", "tn1" => "Table 1, NOTE", "cn1" => "Clause 1, NOTE",
          "afn1" => "Figure A.1, NOTE", "atn2" => "Table A.1, NOTE 2",
        )
      end

      it "persists deep labels idempotently without changing authored titles" do
        body = LADL_HIERARCHY_MAIN.sub('<clause id="c1_1_1_2"/>', '<clause id="c1_1_1_2"><title>Authored <em>title</em></title></clause>')
        root = doc(root_class, body)
        title = walk(root).fetch("c1_1_1_2").title.to_xml
        engine.call(root, adapter: adapter)
        first = root.to_xml
        engine.call(root, adapter: adapter)
        expect(root.to_xml).to eq(first)
        expect(walk(root).fetch("c1_1_1_2").title.to_xml).to eq(title)
        parsed = root_class.from_xml(first)
        data = adapter.label_data(walk(parsed).fetch("c1_1_1_2"))
        expect([data.local, data.global, data.value, data.direction, data.global_direction, data.labeller])
          .to eq(["1.1.1.2", "1.1.1.2", "2", "ltr", "ltr", "subclause_labeller"])
      end

      {
        "clause" => ['<sections><clause id="x" hidden="true"/><clause id="y"/></sections>', "Clause 1"],
        "figure" => ['<sections><clause id="c"><figure id="x" hidden="true"/><figure id="y"/></clause></sections>', "Figure 1"],
        "table" => ['<sections><clause id="c"><table id="x" hidden="true"/><table id="y"/></clause></sections>', "Table 1"],
        "note" => ['<sections><clause id="c"><note id="x" hidden="true"/><note id="y"/></clause></sections>', "NOTE 1"],
      }.each do |kind, (body, expected)|
        it "does not let a hidden #{kind} consume a number" do
          root = doc(root_class, body)
          hidden = walk(root).fetch("x")
          expect(hidden.class.attributes.fetch(:hidden).type).to eq(Lutaml::Model::Type::Boolean)
          engine.call(root, adapter: adapter)
          expect(adapter.label_data(hidden)).to be_nil
          expect(adapter.label_for(walk(root).fetch("y"), form: :local)).to eq(expected)
        end
      end

      it "fails closed on a numbered child whose hidden parent has no number" do
        root = doc(root_class, '<sections><clause id="x" hidden="true"><clause id="x1"/></clause><clause id="y"><clause id="y1"/></clause></sections>')
        expect(walk(root).fetch("x").hidden).to be true
        original = root.to_xml
        expect { engine.call(root, adapter: adapter) }.to raise_error(Metanorma::Ladl::MissingParent)
        expect(root.to_xml).to eq(original)
      end

      it "continues document-scoped asset counts inside a hidden section" do
        root = run(root_class, '<sections><clause id="x" hidden="true"><figure id="f1"/></clause><clause id="y"><figure id="f2"/></clause></sections>')
        expect(labels(root).slice("x", "y", "f1", "f2"))
          .to eq("x" => nil, "y" => "Clause 1", "f1" => "Figure 1", "f2" => "Figure 2")
      end

      it "removes a stale generated label when a node becomes hidden" do
        root = doc(root_class, '<sections><clause id="x"/><clause id="y"/></sections>')
        node = walk(root).fetch("x")
        expect(node.class.attributes.fetch(:hidden).type).to eq(Lutaml::Model::Type::Boolean)
        engine.call(root, adapter: adapter)
        expect(adapter.label_for(walk(root).fetch("y"), form: :local)).to eq("Clause 2")
        node.hidden = true
        engine.call(root, adapter: adapter)
        expect(adapter.label_data(node)).to be_nil
        expect(adapter.label_for(walk(root).fetch("y"), form: :local)).to eq("Clause 1")
      end
    end
  end

  describe "native conditional-count contract" do
    [0, -1, "2", 1.5, 100_000].each do |invalid|
      it "rejects invalid template count #{invalid.inspect} before any assignment" do
        root = doc(Metanorma::Standoc::Document::Root, '<sections><clause id="c"><note id="n"/></clause></sections>')
        original = root.to_xml
        allow(adapter).to receive(:template_element_count).and_return(invalid)
        expect { engine.call(root, adapter: adapter) }.to raise_error(Metanorma::Ladl::TreeError, /element count/)
        expect(root.to_xml).to eq(original)
      end
    end
  end

  describe "fail-closed parent resolution" do
    it "rejects same-labeller nesting without a compound template and writes nothing" do
      inner = element("s2", "subfigure")
      outer = element("s1", "subfigure", nil, inner)
      figure = element("f", "figure", nil, outer)
      root = element("d", "document", "DocumentContext", figure)
      expect { engine.call(root) }.to raise_error(Metanorma::Ladl::UnsupportedFeature, /compound/)
      expect(figure.label).to be_nil
    end

    it "does not accept a same-type variant that is not the counter scope" do
      orphan = element("s", "subclause")
      scope = element("scope", "container", "ClauseContext", orphan)
      annex_clause = element("ac", "clause", "AnnexClauseContext", scope)
      root = element("d", "document", "DocumentContext", element("a", "annex", "AnnexContext", annex_clause))
      expect { engine.call(root) }.to raise_error(Metanorma::Ladl::MissingParent)
      expect(annex_clause.label).to be_nil
    end
  end
end
