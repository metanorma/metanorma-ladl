# frozen_string_literal: true

require "metanorma/document"
require "metanorma/document/components/inline/fmt_ladl_label_data"
require "metanorma/standoc/document"

module Metanorma
  module Ladl
    # Explicit adapter for the actual Document/Standoc model graph. The caller
    # must identify presentation processing; semantic documents are never labelled.
    class DocumentAdapter
      Inline = Metanorma::Document::Components::Inline
      Blocks = Metanorma::Document::Components::Blocks
      Ancillary = Metanorma::Document::Components::AncillaryBlocks
      Lists = Metanorma::Document::Components::Lists
      Sections = Metanorma::Standoc::Document::Sections
      ORDERED_SEQUENCES = {
        "arabic" => "DecimalNumericSequence",
        "alphabet" => "AlphaLowerNumericSequence",
        "roman" => "RomanLowerNumericSequence",
      }.freeze
      GENERATED_CONTAINER = "ladl"
      OMIT = %i[bibdata bibliography title name fmt_title fmt_name fmt_xref_label
                fmt_fn_label fmt_ladl_label_data contrib_metadata].freeze

      def initialize(mode:, profile: nil)
        raise TreeError, "LADL requires presentation mode" unless mode == :presentation

        raise ProfileError, "Native profile must be a validated Profile" if profile && !profile.is_a?(Profile)
        @native_list_types = profile ? profile.labellers.map(&:type).grep(/\Alist_item_ordered_native_/).freeze : []
        @native_list_depth = @native_list_types.filter_map { |type| type[/_level(\d+)\z/, 1]&.to_i }.max || 0
        @parents = {}
      end

      def children(node)
        # Ordered/mixed models expose document order through the framework. Other
        # nodes use declared attribute order. Never walk formatting/label metadata.
        candidates = []
        if node.respond_to?(:each_mixed_content) && (node.mixed? || node.ordered?) && node.element_order&.any?
          node.each_mixed_content { |child| candidates << child }
        else
          node.class.attributes.each_key do |key|
            next if OMIT.include?(key)
            candidates.concat(Array(node.public_send(key)))
          end
        end
        children = candidates.select do |child|
          child.is_a?(Lutaml::Model::Serializable) &&
            !child.is_a?(Inline::RenderedDisplay) &&
            !excluded?(node, child)
        end
        # Newly appended native children have no parsed element_order entry.
        # Preserve recorded order, then include every declared occurrence not
        # represented there. Repeated identities remain visible to Engine's
        # shared-node validation instead of being silently deduplicated.
        ordered_counts = children.tally
        declared_counts = Hash.new(0)
        node.class.attributes.each_key do |key|
          next if OMIT.include?(key)
          Array(node.public_send(key)).each do |child|
            next unless child.is_a?(Lutaml::Model::Serializable)
            next if child.is_a?(Inline::RenderedDisplay) || excluded?(node, child)
            declared_counts[child] += 1
            children << child if declared_counts[child] > ordered_counts.fetch(child, 0)
          end
        end
        children.each { |child| @parents[child.object_id] = node }
        children
      end

      def identifier(node)
        value(node, :id)
      end

      def type(node)
        return nil if flag?(node, :unnumbered) || hidden?(node)
        return "document" if root?(node)
        if node.is_a?(Sections::AnnexSection)
          return ancestors(node).any? { |p| p.is_a?(Sections::AnnexSection) } ? "clause" : "annex"
        end
        if node.is_a?(Sections::ClauseSection)
          return "clause" if ancestors(node).any? { |p| p.is_a?(Sections::AnnexSection) }
          return ancestors(node).any? { |p| p.is_a?(Sections::ClauseSection) } ? "subclause" : "clause"
        end
        return "subfigure" if node.is_a?(Ancillary::Subfigure)
        return "figure" if node.is_a?(Ancillary::FigureBlock)
        return "table" if node.is_a?(Metanorma::Document::Components::Tables::TableBlock)
        return ordinary_note?(node) ? "note" : nil if note?(node)
        return "example" if node.is_a?(Ancillary::ExampleBlock)
        return "formula" if node.is_a?(Ancillary::FormulaBlock)
        if node.is_a?(Lists::List)
          return "list" if node.is_a?(Lists::OrderedList) && ancestors(node).none? { |parent| parent.is_a?(Lists::OrderedList) }
          return nil
        end
        if node.is_a?(Lists::ListItem)
          lists = ancestors(node).select { |p| p.is_a?(Lists::List) }
          return "list_item_unordered" unless lists.first.is_a?(Lists::OrderedList)
          depth = lists.count { |p| p.is_a?(Lists::OrderedList) }
          unless @native_list_types.empty?
            style = value(lists.first, :type)
            suffix = style ? "style_#{style}" : (depth > @native_list_depth ? "deep" : "level#{depth}")
            selected = "list_item_ordered_native_#{suffix}"
            unless @native_list_types.include?(selected)
              raise UnsupportedFeature, "Native profile has no ordered-list type #{style.inspect} at depth #{depth}"
            end
            return selected
          end
          raise TreeError, "ISO/IEC supports four ordered list levels" if depth > 4
          return "list_item_ordered_level#{depth}"
        end
        nil
      end

      def context(node)
        contexts_for(node, nil).first
      end

      # A context belongs to an actual ancestor, never to a fabricated wrapper.
      # Siblings consequently share a counter; descendants restart at their own
      # containing clause/list/annex. An owner does not consume its own context.
      #
      # The worked profile has no figure/table context and declares six contexts,
      # so native owners act as instances of the declared context: a figure
      # scopes its subfigures, a figure/table scopes its notes, and a nested
      # annex clause scopes its child clauses. Figures, tables, formulas and
      # lists in nested annex clauses still count across the whole annex.
      def contexts_for(owner, target)
        return [] if owner.equal?(target)
        return ["DocumentContext"] if root?(owner)
        return asset_contexts(owner, target) if asset?(owner)
        return ["ListContext"] if owner.is_a?(Lists::List)
        return nested_annex_contexts(target) if nested_annex_section?(owner)
        return ["AnnexClauseContext", "AnnexContext", "ClauseContext"] if owner.is_a?(Sections::AnnexSection)
        return ["ClauseContext"] if owner.is_a?(Sections::ClauseSection)
        []
      end

      # Legacy note template selection uses all notes in the owning context,
      # including hidden notes, while only numbered notes consume an ordinal.
      def template_element_count(scope:, type:, context:, nodes:, default:)
        return default unless type == "note"

        nodes.count do |node|
          next false unless ordinary_note?(node)

          owner = ancestors(node).find { |parent| contexts_for(parent, node).include?(context) }
          owner.equal?(scope)
        end
      end

      # Authored native list inputs select an existing sequence and set its
      # initial value without mutating the profile's declaration or shared state.
      def sequence_for(node, default:)
        return default unless node.is_a?(Lists::ListItem)

        list = ancestors(node).find { |parent| parent.is_a?(Lists::List) }
        return default unless list.is_a?(Lists::OrderedList)

        style = @native_list_types.empty? ? value(list, :type) : nil
        if %w[alphabet_upper roman_upper].include?(style)
          raise UnsupportedFeature, "Native uppercase ordered lists need a profile template for the legacy period delimiter"
        end
        sequence = if style
                     name = ORDERED_SEQUENCES[style]
                     raise UnsupportedFeature, "Unsupported native ordered-list type #{style.inspect}" unless name
                     Sequence.builtin(name)
                   else
                     default
                   end
        start = value(list, :start)
        return sequence if start.nil?

        unless start.to_s.match?(/\A[+-]?\d+\z/)
          raise TreeError, "Native ordered-list start must be an integer"
        end
        sequence.with_initial_value(Integer(start.to_s, 10))
      end

      def validate(node)
        raise TreeError, "DocumentAdapter needs native Lutaml model nodes" unless node.is_a?(Lutaml::Model::Serializable)
        if root?(node)
          if value(node, :type) && value(node, :type) != "presentation"
            raise TreeError, "LADL requires a presentation document"
          end
          @parents.clear
          return
        end
        return unless type(node)
        return if typed_xref?(node) || node.class.attributes.key?(:fmt_ladl_label_data)

        raise TreeError, "#{node.class} has no native presentation label metadata slot"
      end

      def assign(node, label)
        return clear_generated(node) unless label

        data = Inline::FmtLadlLabelData.new(**%i[local global value direction global_direction labeller]
          .to_h { |key| [key, label.public_send(key)] })
        if typed_xref?(node)
          existing = Array(value(node, :fmt_xref_label))
          generated = Inline::FmtXrefLabelElement.new(container: GENERATED_CONTAINER,
            text: [label.global || label.local], fmt_ladl_label_data: data)
          node.fmt_xref_label = existing.reject { |item| item.container == GENERATED_CONTAINER } + [generated]
        else
          node.fmt_ladl_label_data = data
          node.fmt_xref_label = label.global || label.local if node.class.attributes.key?(:fmt_xref_label)
        end
        node.autonum = label.value if node.class.attributes.key?(:autonum)
        node.label = label.local if node.is_a?(Lists::ListItem)
      end

      # Consumers select local versus global text from the persisted native data.
      # No lookup in engine-side state is needed after XML roundtrip.
      def label_for(node, form: :global)
        raise ArgumentError, "form must be :local or :global" unless %i[local global].include?(form)
        data = label_data(node)
        data && (data.public_send(form) || data.local)
      end

      def label_data(node)
        if typed_xref?(node)
          Array(value(node, :fmt_xref_label)).find { |label| label.container == GENERATED_CONTAINER }&.fmt_ladl_label_data
        else
          value(node, :fmt_ladl_label_data)
        end
      end

      private

      # Removes only values this adapter generated, so a node that became
      # hidden or unnumbered keeps its authored labels and loses stale ones.
      def clear_generated(node)
        data = label_data(node)
        return unless data

        if typed_xref?(node)
          node.fmt_xref_label = Array(value(node, :fmt_xref_label)).reject { |item| item.container == GENERATED_CONTAINER }
        else
          node.fmt_ladl_label_data = nil
          if node.class.attributes.key?(:fmt_xref_label) && node.fmt_xref_label == (data.global || data.local)
            node.fmt_xref_label = nil
          end
        end
        node.autonum = nil if node.class.attributes.key?(:autonum) && node.autonum == data.value
        node.label = nil if node.is_a?(Lists::ListItem) && node.label == data.local
      end

      def asset?(node)
        node.is_a?(Ancillary::FigureBlock) || node.is_a?(Ancillary::Subfigure) ||
          node.is_a?(Metanorma::Document::Components::Tables::TableBlock)
      end

      def asset_contexts(owner, target)
        return [] unless target

        case context_type(target)
        when "subfigure" then owner.is_a?(Metanorma::Document::Components::Tables::TableBlock) ? [] : ["DocumentContext"]
        when "note" then ["ClauseContext"]
        else []
        end
      end

      def section?(node)
        node.is_a?(Sections::AnnexSection) || node.is_a?(Sections::ClauseSection)
      end

      def nested_annex_section?(node)
        section?(node) && ancestors(node).any? { |p| p.is_a?(Sections::AnnexSection) }
      end

      def nested_annex_contexts(target)
        return ["ClauseContext"] unless target
        return ["AnnexContext"] if section?(target)

        %w[note example].include?(context_type(target)) ? ["ClauseContext"] : []
      end

      def context_type(node)
        return ordinary_note?(node) ? "note" : nil if note?(node)
        return "subfigure" if node.is_a?(Ancillary::Subfigure)
        return "example" if node.is_a?(Ancillary::ExampleBlock)

        type(node)
      end

      def note?(node)
        node.is_a?(Blocks::NoteBlock) || standoc_note?(node)
      end

      def ordinary_note?(node)
        return false unless note?(node)
        return false if identifier(node).to_s.strip.empty?
        return false if %w[units requirement].include?(value(node, :type_attr))

        true
      end

      def hidden?(node)
        flag?(node, :hidden)
      end

      def flag?(node, key)
        flag = value(node, key)
        flag == true || flag.to_s.casecmp?("true")
      end

      def root?(node)
        node.is_a?(Metanorma::Document::Root) ||
          (defined?(Metanorma::Iso::Document::Root) && node.is_a?(Metanorma::Iso::Document::Root))
      end

      def standoc_note?(node)
        node.is_a?(Metanorma::Standoc::Document::Blocks::StandardNoteBlock)
      end

      def typed_xref?(node)
        attr = node.class.attributes[:fmt_xref_label]
        attr && attr.type == Inline::FmtXrefLabelElement && attr.collection?
      end

      def value(node, key)
        node.public_send(key) if node.class.attributes.key?(key)
      end

      def ancestors(node)
        out, seen = [], {}
        while (node = @parents[node.object_id])
          raise TreeError, "Content must be a tree" if seen[node.object_id]
          seen[node.object_id] = true
          out << node
        end
        out
      end

      def excluded?(parent, child)
        OMIT.any? { |key| Array(value(parent, key)).any? { |item| item.equal?(child) } }
      end
    end
  end
end
