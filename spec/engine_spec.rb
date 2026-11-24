# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Metanorma::Ladl::Engine do
  let(:engine) { described_class.new(profile: iso_profile) }

  it "assigns hierarchical clause and annex values from the real worked profile" do
    sub1, sub2 = element("s1", "subclause"), element("s2", "subclause")
    c1 = element("c1", "clause", "ClauseContext", sub1, sub2)
    ac1 = element("a1", "clause", "AnnexClauseContext")
    annex = element("annex", "annex", "AnnexContext", ac1)
    root = element("doc", "document", "DocumentContext", c1, element("c2", "clause"), annex)
    expect(engine.call(root)).to equal(root)
    expect(c1.label.local).to eq("Clause 1")
    expect(sub1.label.local).to eq("1.1")
    expect(sub2.label.local).to eq("1.2")
    expect(annex.label.local).to eq("Annex A")
    expect(ac1.label.local).to eq("A.1")
  end

  it "keeps main-document counters shared and annex counters scoped per annex" do
    f1, f2, af1, af2 = %w[f1 f2 af1 af2].map { |id| element(id, "figure") }
    t1, at1 = element("t1", "table"), element("at1", "table")
    formula, annex_formula = element("eq1", "formula"), element("aeq1", "formula")
    root = element("doc", "document", "DocumentContext",
                   element("c1", "clause", "ClauseContext", f1, t1, formula),
                   element("c2", "clause", "ClauseContext", f2),
                   element("a", "annex", "AnnexContext", af1, at1, annex_formula),
                   element("b", "annex", "AnnexContext", af2))
    engine.call(root)
    expect([f1, f2, af1, af2].map { |n| n.label.local }).to eq(["Figure 1", "Figure 2", "Figure A.1", "Figure B.1"])
    expect([t1, at1, formula, annex_formula].map { |n| n.label.local }).to eq(["Table 1", "Table A.1", "(1)", "(A.1)"])
  end

  it "uses total same-context element count before choosing note/example templates" do
    n1, n2, n3 = %w[n1 n2 n3].map { |id| element(id, "note") }
    ex1, ex2, ex3 = %w[e1 e2 e3].map { |id| element(id, "example") }
    root = element("doc", "document", "DocumentContext",
                   element("c1", "clause", "ClauseContext", n1, n2, ex1),
                   element("c2", "clause", "ClauseContext", n3, ex2, ex3))
    engine.call(root)
    expect([n1, n2, n3].map { |n| n.label.local }).to eq(["NOTE 1", "NOTE 2", "NOTE"])
    expect([ex1, ex2, ex3].map { |n| n.label.local }).to eq(["EXAMPLE", "EXAMPLE 1", "EXAMPLE 2"])
    expect(n1.label.global).to eq("Clause 1, NOTE 1")
    expect(n3.label.global).to eq("Clause 2, NOTE")
  end

  it "resolves explicit parent labellers for subfigures and ordered lists" do
    subfigure = element("sf", "subfigure")
    level2 = element("li2", "list_item_ordered_level2")
    nested = element("nested", "container", "ListContext", level2)
    level1 = element("li1", "list_item_ordered_level1", nil, nested)
    list = element("list", "list", "ListContext", level1, element("u", "list_item_unordered"))
    root = element("doc", "document", "DocumentContext", element("c", "clause", "ClauseContext", element("f", "figure", nil, subfigure), list))
    engine.call(root)
    expect(subfigure.label.local).to eq("Figure 1 a)")
    expect([list, level1, level2].map { |n| n.label.local }).to eq(["List 1", "a)", "1)"])
    expect(list.children.last.label.local).to eq("—")
  end

  it "restores deterministic counters and conditional templates on another call" do
    note = element("n", "note")
    clause = element("c", "clause", "ClauseContext", note)
    root = element("d", "document", "DocumentContext", clause)
    2.times { engine.call(root); expect(note.label.local).to eq("NOTE") }
    clause.add(element("n2", "note"))
    engine.call(root)
    expect(note.label.local).to eq("NOTE 1")
  end

  it "does not mutate any labels when a later required parent is missing" do
    c = element("c", "clause")
    orphan = element("s", "subclause")
    root = element("d", "document", "DocumentContext", c, element("scope", "container", "ClauseContext", orphan))
    expect { engine.call(root) }.to raise_error(Metanorma::Ladl::MissingParent)
    expect(c.label).to be_nil
  end

  it "fails on cyclic/shared nodes, duplicate ids, unknown contexts and unsupported model adapters" do
    root = element("d", "document", "DocumentContext")
    root.add(root)
    expect { engine.call(root) }.to raise_error(Metanorma::Ladl::TreeError, /tree/)
    expect { engine.call(element("d", "document", "DocumentContext", element("x", "clause"), element("x", "clause"))) }
      .to raise_error(Metanorma::Ladl::TreeError, /Duplicate content id/)
    expect { engine.call(element("d", "document", "UnknownContext")) }.to raise_error(Metanorma::Ladl::TreeError, /Unknown content context/)
    expect { engine.call(Object.new) }.to raise_error(Metanorma::Ladl::TreeError, /explicit model adapter/)
    expect { engine.call(Object.new, adapter: Object.new) }.to raise_error(Metanorma::Ladl::TreeError, /adapter lacks/)
  end

  it "retains Arabic-script digits and explicit right-to-left direction" do
    data = minimal_data(sequence: "ArabicNumericSequence", pattern: "%n قسم")
    data["instances"][2]["properties"]["direction"] = "rtl"
    engine = described_class.new(profile: profile_data(data))
    node = element("c", "clause")
    engine.call(element("d", "document", "DocumentContext", node))
    expect(node.label.local).to eq("١ قسم")
    expect(node.label.direction).to eq("rtl")
  end

  it "treats template content as data rather than Ruby code" do
    engine = described_class.new(profile: profile_data(minimal_data(pattern: 'literal #{raise "executed"} %n')))
    node = element("c", "clause")
    engine.call(element("d", "document", "DocumentContext", node))
    expect(node.label.local).to eq('literal #{raise "executed"} 1')
  end
  it "rejects an invalid optional adapter sequence before assigning any label" do
    adapter = Metanorma::Ladl::ContentElementAdapter.new
    def adapter.sequence_for(_node, default:)
      Object.new
    end
    clause = element("c", "clause")
    root = element("d", "document", "DocumentContext", clause)
    expect { engine.call(root, adapter: adapter) }.to raise_error(Metanorma::Ladl::TreeError, /must be a Sequence/)
    expect(clause.label).to be_nil
  end

end
