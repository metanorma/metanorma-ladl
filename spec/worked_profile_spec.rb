# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "MN112 corrected ISO/IEC worked profile" do
  it "exercises every one of the twenty declared labellers with independent expected labels" do
    nodes = {}
    make = lambda do |id, type, context = nil, *children|
      nodes[id] = element(id, type, context, *children)
    end
    l4 = make.call("level4", "list_item_ordered_level4")
    l3 = make.call("level3", "list_item_ordered_level3", nil, element("scope4", "container", "ListContext", l4))
    l2 = make.call("level2", "list_item_ordered_level2", nil, element("scope3", "container", "ListContext", l3))
    l1 = make.call("level1", "list_item_ordered_level1", nil, element("scope2", "container", "ListContext", l2))
    list = make.call("list", "list", "ListContext", l1, make.call("unordered", "list_item_unordered"))
    figure = make.call("figure", "figure", nil, make.call("subfigure", "subfigure"))
    clause = make.call("clause", "clause", "ClauseContext",
                       make.call("subclause", "subclause", "SubclauseContext"), figure,
                       make.call("table", "table"), make.call("note", "note"),
                       make.call("example", "example"), make.call("formula", "formula"), list)
    annex = make.call("annex", "annex", "AnnexContext",
                      make.call("annex_clause", "clause", "AnnexClauseContext"),
                      make.call("annex_figure", "figure"), make.call("annex_table", "table"),
                      make.call("annex_formula", "formula"), make.call("annex_list", "list", "ListContext"))
    document = element("document", "document", "DocumentContext", clause, annex)
    Metanorma::Ladl::Engine.new(profile: iso_profile).call(document)
    expected = {
      "clause" => "Clause 1", "subclause" => "1.1", "annex" => "Annex A",
      "annex_clause" => "A.1", "figure" => "Figure 1", "annex_figure" => "Figure A.1",
      "subfigure" => "Figure 1 a)", "table" => "Table 1", "annex_table" => "Table A.1",
      "note" => "NOTE", "example" => "EXAMPLE", "formula" => "(1)",
      "annex_formula" => "(A.1)", "list" => "List 1", "annex_list" => "List A.1",
      "unordered" => "—", "level1" => "a)", "level2" => "1)", "level3" => "i)", "level4" => "a)",
    }
    expect(nodes.transform_values { |node| node.label.local }).to eq(expected)
    expect(nodes.values.map { |node| node.label.labeller }.sort).to eq(iso_profile.labellers.map(&:id).sort)
    expect(nodes.fetch("note").label.global).to eq("Clause 1, NOTE")
    expect(nodes.fetch("example").label.global).to eq("Clause 1, EXAMPLE")
  end
end
