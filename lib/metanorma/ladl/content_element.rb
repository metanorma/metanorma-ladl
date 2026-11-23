# frozen_string_literal: true

require "lutaml/model"

module Metanorma
  module Ladl
    class Label < Lutaml::Model::Serializable
      attribute :local, :string
      attribute :global, :string
      attribute :value, :string
      attribute :direction, :string
      attribute :global_direction, :string
      attribute :labeller, :string
    end

    # MN112's illustrative ContentElement model. This is an explicitly supported
    # component tree, not a Metanorma Document adapter or a replacement model.
    class ContentElement < Lutaml::Model::Serializable
      attribute :id, :string
      attribute :type, :string
      attribute :context, :string
      attribute :children, "Metanorma::Ladl::ContentElement", collection: true, default: -> { [] }
      attribute :label, Label

      def add(*elements)
        children.concat(elements)
        self
      end
    end

    class ContentElementAdapter
      def children(node) = node.children
      def type(node) = node.type
      def context(node) = node.context
      def identifier(node) = node.id
      def assign(node, label) = node.label = label

      def validate(node)
        return if node.is_a?(ContentElement)
        raise TreeError, "#{node.class} is not supported by ContentElementAdapter; supply an explicit model adapter"
      end
    end
  end
end
