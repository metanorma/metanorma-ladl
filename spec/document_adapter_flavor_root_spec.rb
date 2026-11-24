# frozen_string_literal: true

require_relative "spec_helper"
require_relative "native_spec_helper"

return unless LadlNativeSpecs.available?(legacy: false)

RSpec.describe Metanorma::Ladl::DocumentAdapter, "#root?" do
  let(:adapter) { described_class.new(mode: :presentation) }

  before do
    stub_const("Metanorma::Fancy::Document::Root", Class.new)
    stub_const("Metanorma::Fancy::Document::SubRoot",
               Class.new(Metanorma::Fancy::Document::Root))
  end

  it "accepts any flavor root and subclasses of it" do
    expect(adapter.send(:root?, Metanorma::Fancy::Document::Root.new)).to be true
    expect(adapter.send(:root?, Metanorma::Fancy::Document::SubRoot.new)).to be true
  end

  it "accepts the shared SDK root" do
    expect(adapter.send(:root?, Metanorma::Document::Root.new)).to be true
  end

  it "rejects other nodes" do
    expect(adapter.send(:root?, Object.new)).to be false
  end
end
