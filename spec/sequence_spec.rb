# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Metanorma::Ladl::Sequence do
  it "uses bijective alphabet expansion and actual lower/upper Roman values" do
    expect([1, 26, 27, 52, 53].map { |n| described_class.builtin("AlphaUpperNumericSequence").value(n) }).to eq(%w[A Z AA AZ BA])
    expect([1, 4, 9, 14, 40, 99].map { |n| described_class.builtin("RomanLowerNumericSequence").value(n) }).to eq(%w[i iv ix xiv xl xcix])
  end

  it "keeps Decimal and Arabic-script numeric sequences distinct" do
    expect(described_class.builtin("DecimalNumericSequence").value(12)).to eq("12")
    expect(described_class.builtin("ArabicNumericSequence").value(12)).to eq("١٢")
    expect(described_class.builtin("ArabicNumericSequence").direction).to eq("rtl")
  end

  it "supports explicit initial and increment values through a base sequence" do
    seq = described_class.new("Even", base: described_class.builtin("DecimalNumericSequence"), initial_value: 2, increment: 2)
    expect((1..4).map { |n| seq.value(n) }).to eq(%w[2 4 6 8])
  end

  it "supports deterministic finite custom character expansion" do
    seq = described_class.new("YiJing", kind: :characters, characters: %w[元 亨 利 貞], expansion_rule: "prepend_prefix", expansion_prefix: %w[乾 坤])
    expect([1, 4, 5, 8, 9].map { |n| seq.value(n) }).to eq(%w[元 貞 乾元 乾貞 坤元])
    expect { seq.value(13) }.to raise_error(Metanorma::Ladl::UnsupportedFeature, /prefixes exhausted/)
  end

  it "rejects unavailable/underspecified numeral systems rather than using decimal silently" do
    expect { described_class.builtin("HebrewNumericSequence") }.to raise_error(Metanorma::Ladl::UnsupportedFeature)
    expect { described_class.builtin("RomanUpperNumericSequence").value(4000) }.to raise_error(Metanorma::Ladl::UnsupportedFeature)
    expect { described_class.builtin("DecimalNumericSequence").value(0) }.to raise_error(Metanorma::Ladl::ProfileError)
  end

  it "does not invent expansion for the finite Greek character sequence" do
    seq = described_class.builtin("GreekUpperCharacterSequence")
    expect([seq.value(1), seq.value(24)]).to eq(%w[Α Ω])
    expect { seq.value(25) }.to raise_error(Metanorma::Ladl::UnsupportedFeature, /exhausted/)
    expect { described_class.builtin("CyrillicUpperCharacterSequence") }.to raise_error(Metanorma::Ladl::UnsupportedFeature)
  end
  it "sets an invocation-local initial value while preserving base, increment and the source sequence" do
    base = described_class.new("Even", base: described_class.builtin("DecimalNumericSequence"), initial_value: 2, increment: 2)
    authored = base.with_initial_value(5)
    expect([authored.value(1), authored.value(2)]).to eq(%w[5 7])
    expect([base.value(1), base.value(2)]).to eq(%w[2 4])
  end

end
