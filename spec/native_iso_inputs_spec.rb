# frozen_string_literal: true

require_relative "spec_helper"
require_relative "native_spec_helper"

return unless LadlNativeSpecs.available?(legacy: true)

RSpec.describe "native ISO note and authored-list inputs against the real legacy converter" do
  let(:profile) { Metanorma::Ladl::Profile.iso_iec_native }
  let(:engine) { Metanorma::Ladl::Engine.new(profile: profile) }
  let(:adapter) { Metanorma::Ladl::DocumentAdapter.new(mode: :presentation, profile: profile) }
  let(:bibdata) do
    '<bibdata type="standard"><title language="en">Native parity</title><docidentifier>ISO 1234:2020</docidentifier><language>en</language><script>Latn</script><contributor><role type="publisher"/><organization><name>International Organization for Standardization</name><abbreviation>ISO</abbreviation></organization></contributor></bibdata>'
  end

  def native(root_class, body)
    root_class.from_xml(%(<metanorma xmlns="https://www.metanorma.org/ns/standoc" type="presentation">#{bibdata}<sections>#{body}</sections></metanorma>))
  end

  def legacy(body)
    converter = IsoDoc::Iso::PresentationXMLConvert.new(presxml_options: {}, language: "en", script: "Latn")
    output = converter.convert("native-input-parity",
      %(<iso-standard xmlns="http://riboseinc.com/isoxml">#{bibdata}<sections>#{body}</sections></iso-standard>), true)
    [Nokogiri::XML(output), converter.xrefs.get]
  end

  def nodes(root)
    found, pending = {}, [root]
    until pending.empty?
      node = pending.shift
      found[adapter.identifier(node)] = node if adapter.identifier(node)
      pending.concat(adapter.children(node))
    end
    found
  end

  # Compare displayed caption content, excluding only newline indentation
  # introduced by the legacy XML pretty serializer. Keep ordinary inline spaces
  # and punctuation; no model content/order/IDs or metadata are normalized.
  def legacy_local(document, id, note: false)
    node = document.at_xpath("//*[@id='#{id}']/*[local-name()='fmt-name']")
    return nil unless node
    node = node.at_xpath(".//*[local-name()='span'][@class='fmt-caption-label']") if note
    return nil unless node

    node.xpath(".//text()").reject { |text| text.text.match?(/\A[[:space:]]*\n[[:space:]]*\z/) }.map(&:text).join.strip
  end

  def compare_notes(root_class, body, ids)
    output, = legacy(body)
    root = native(root_class, body)
    engine.call(root, adapter: adapter)
    found = nodes(root)
    actual = ids.to_h { |id| [id, adapter.label_for(found.fetch(id), form: :local)] }
    expected = ids.to_h { |id| [id, legacy_local(output, id, note: true)] }
    expect(actual).to eq(expected)
    root
  end


  [Metanorma::Standoc::Document::Root, Metanorma::Iso::Document::Root].each do |root_class|
    context root_class.name do
      it "excludes native units and requirement note types from ordinals and single-note selection" do
        body = '<clause id="c"><title>Scope</title><note id="u" type="units"><p>Units</p></note><note id="r" type="requirement"><p>Requirement</p></note><note id="n"><p>Normal</p></note></clause>'
        compare_notes(root_class, body, %w[u r n])
      end

      it "counts ordinary and custom-type notes while filtering special types in clause and asset scopes" do
        body = '<clause id="c"><title>Scope</title><note id="u" type="units"><p>Units</p></note><note id="n1"><p>One</p></note><note id="n2" type="custom"><p>Two</p></note><figure id="f"><name>Figure</name><pre>Figure body</pre><note id="fu" type="units"><p>Units</p></note><note id="fn"><p>Normal</p></note></figure><table id="t"><tbody><tr><td>Cell</td></tr></tbody><note id="tr" type="requirement"><p>Requirement</p></note><note id="tn"><p>Normal</p></note></table></clause>'
        compare_notes(root_class, body, %w[u n1 n2 fu fn tr tn])
      end

      it "excludes idless notes from the legacy single-note population" do
        body = '<clause id="c"><title>Scope</title><note><p>No identity</p></note><note id="n"><p>Normal</p></note></clause>'
        compare_notes(root_class, body, %w[n])
      end

      it "numbers only top-level ordered lists and retains nested item labels" do
        body = '<clause id="c"><title>Scope</title><ul id="ul"><li id="ui"><p>Bullet</p></li></ul><ol id="ol"><li id="i1"><p>One</p><ol id="nested"><li id="i2"><p>Nested</p></li></ol></li><li id="i3"><p>Two</p></li></ol><ol id="after"><li id="i4"><p>After</p></li></ol></clause>'
        output, anchors = legacy(body)
        root = native(root_class, body)
        engine.call(root, adapter: adapter)
        found = nodes(root)
        expect(adapter.label_data(found.fetch("ul"))).to be_nil
        expect(adapter.label_data(found.fetch("nested"))).to be_nil
        %w[ol after].each do |id|
          expect(adapter.label_for(found.fetch(id), form: :local)).to eq(Nokogiri::XML.fragment(anchors.fetch(id).fetch(:xref)).text)
        end
        %w[i1 i2 i3 i4].each do |id|
          expect(adapter.label_for(found.fetch(id), form: :local)).to eq(legacy_local(output, id))
        end
      end

      %w[arabic alphabet alphabet_upper roman roman_upper].each do |style|
        it "honors authored #{style} type and start without leaking to the next list" do
          body = %(<clause id="c"><title>Scope</title><ol id="ol" type="#{style}" start="3"><li id="i1"><p>One</p></li><li id="i2"><p>Two</p></li></ol><ol id="after"><li id="i3"><p>After</p></li></ol></clause>)
          output, = legacy(body)
          root = native(root_class, body)
          2.times { engine.call(root, adapter: adapter) }
          found = nodes(root)
          %w[i1 i2 i3].each do |id|
            expect(adapter.label_for(found.fetch(id), form: :local)).to eq(legacy_local(output, id))
          end
        end
      end

      it "retains authored nested starts and explicit fourth-level type through native XML" do
        body = '<clause id="c"><title>Scope</title><ol id="o1"><li id="i1"><p>One</p><ol id="o2" start="4"><li id="i2"><p>Two</p><ol id="o3" start="3"><li id="i3"><p>Three</p><ol id="o4" start="2" type="alphabet_upper"><li id="i4"><p>Four</p></li></ol></li></ol></li></ol></li></ol></clause>'
        output, = legacy(body)
        root = native(root_class, body)
        engine.call(root, adapter: adapter)
        found = nodes(root)
        expected = %w[i1 i2 i3 i4].to_h { |id| [id, legacy_local(output, id)] }
        expect(expected.keys.to_h { |id| [id, adapter.label_for(found.fetch(id), form: :local)] }).to eq(expected)
        reparsed = root.class.from_xml(root.to_xml)
        again = nodes(reparsed)
        expect(expected.keys.to_h { |id| [id, adapter.label_for(again.fetch(id), form: :local)] }).to eq(expected)
        expect(again.fetch("o4").type).to eq(found.fetch("o4").type)
        expect(again.fetch("o4").start).to eq(found.fetch("o4").start)
      end

      it "uses declared native defaults through ten levels and the legacy deep fallback" do
        body = '<p>Body</p>'
        11.downto(1) { |depth| body = %(<ol id="o#{depth}"><li id="i#{depth}">#{body}</li></ol>) }
        body = %(<clause id="c"><title>Scope</title>#{body}</clause>)
        output, = legacy(body)
        root = native(root_class, body)
        engine.call(root, adapter: adapter)
        found = nodes(root)
        (1..11).each do |depth|
          id = "i#{depth}"
          expect(adapter.label_for(found.fetch(id), form: :local)).to eq(legacy_local(output, id))
        end
      end

      it "refuses Latin overflow instead of approximating the legacy non-letter glyph" do
        body = '<clause id="c"><title>Scope</title><ol id="ol" type="alphabet" start="27"><li id="i"><p>Text</p></li></ol></clause>'
        output, = legacy(body)
        expect(legacy_local(output, "i")).not_to be_empty
        root = native(root_class, body)
        expect { engine.call(root, adapter: adapter) }
          .to raise_error(Metanorma::Ladl::UnsupportedFeature, /character sequence exhausted/)
        expect(nodes(root).values.map { |node| adapter.label_data(node) }.compact).to be_empty
      end

      it "fails atomically for unsupported authored list types and malformed starts" do
        root = native(root_class, '<clause id="c"><title>Scope</title><ol id="ol" type="unknown"><li id="i"><p>Text</p></li></ol></clause>')
        expect { engine.call(root, adapter: adapter) }.to raise_error(Metanorma::Ladl::UnsupportedFeature, /ordered-list type/)
        expect(nodes(root).values.map { |node| adapter.label_data(node) }.compact).to be_empty
        root = native(root_class, '<clause id="c"><title>Scope</title><ol id="ol" start="invalid"><li id="i"><p>Text</p></li></ol></clause>')
        expect { engine.call(root, adapter: adapter) }.to raise_error(Metanorma::Ladl::TreeError, /start must be an integer/)
        expect(nodes(root).values.map { |node| adapter.label_data(node) }.compact).to be_empty
      end
    end
  end
end
