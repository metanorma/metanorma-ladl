# frozen_string_literal: true

require "json"

module Metanorma
  module Ladl
    # Decode the official parser's captured AST, not a second LML grammar.
    # Opaque fall-through tokens are deliberately rejected: accepting one would
    # silently reinterpret unsupported source syntax as a string/reference.
    module LmlCodec
      module_function

      def load(text)
        require "lutaml/lml"
        tree = Lutaml::Lml::Parser.parse(text)
        unless Array(tree[:requires]).empty?
          raise UnsupportedFeature, "LADL profiles cannot import executable requirements"
        end
        Array(tree.fetch(:members)).map do |member|
          entry = member[:instance]
          raise UnsupportedFeature, "Only LML instance declarations are supported" unless entry
          if entry[:instance] || entry[:parent] || entry[:template]
            raise UnsupportedFeature, "Nested/extended LML instances are not LADL definitions"
          end
          { "name" => value(entry.fetch(:name)),
            "type" => entry.fetch(:instance_type).to_s,
            "properties" => properties(entry[:attributes]) }
        end
      rescue Lutaml::Lml::ParsingError, Parsanol::ParseFailed => e
        raise ProfileError, "Invalid supported LML realization: #{e.message}"
      rescue KeyError => e
        raise ProfileError, "Incomplete LML instance: #{e.message}"
      end

      def properties(attributes)
        Array(attributes).each_with_object({}) do |item, result|
          if item[:definition]
            capture = item[:definition]
            # The official parser captures keyword-inline definitions as a
            # string value node, but block definitions as a source slice.
            # Stringifying the former leaks Ruby inspection/offset metadata.
            key = "definition"
            val = capture.is_a?(Hash) ? value(capture) : capture.to_s
            unless val.is_a?(String)
              raise UnsupportedFeature, "LML definitions must contain text"
            end
          elsif item[:comments]
            next
          else
            raise UnsupportedFeature, "Additive LML assignments are unsupported" if item[:add]
            key, val = item.fetch(:key).to_s, value(item.fetch(:value))
          end
          raise ProfileError, "Duplicate LML property #{key}" if result.key?(key)
          result[key] = val
        end
      end

      def value(node)
        unless node.is_a?(Hash)
          raise UnsupportedFeature, "Opaque LML value #{node.to_s.inspect}; use explicit literals/references"
        end
        case node.keys
        when [:string]
          raw = node[:string]
          Lutaml::Lml::Transform.unescape(raw == [] ? "" : raw.to_s)
        when [:number] then Integer(node[:number].to_s, 10)
        when [:boolean] then node[:boolean].to_s == "true"
        when [:null] then nil
        when [:reference] then { "ref" => Array(node[:reference]).map(&:to_s).join(".") }
        when [:list] then Array(node[:list]).map { |item| value(item) }
        when [:key_value_map]
          Array(node[:key_value_map]).each_with_object({}) do |item, result|
            key = item.fetch(:key).to_s
            raise ProfileError, "Duplicate LML map key #{key}" if result.key?(key)
            result[key] = value(item.fetch(:value))
          end
        else
          raise UnsupportedFeature, "Unsupported LML value capture #{node.keys.inspect}"
        end
      rescue ArgumentError => e
        raise ProfileError, "Non-integer LML numeric value: #{e.message}"
      end

      def dump(instances)
        require "lutaml/lml"
        instances.map do |entry|
          lines = entry.fetch("properties").map do |key, val|
            "  #{key} = #{literal(val)}"
          end
          "#{entry.fetch('type')} #{Lutaml::Lml::Quoting.quote_always(entry.fetch('name'))} {\n#{lines.join("\n")}\n}\n"
        end.join("\n")
      end

      def literal(value)
        case value
        when Hash
          return "ref:(#{value.fetch('ref')})" if value.keys == ["ref"]
          "{ #{value.map { |key, val| "#{key} = #{literal(val)}" }.join(' ')} }"
        when Array then "[#{value.map { |item| literal(item) }.join(', ')}]"
        when String then Lutaml::Lml::Quoting.quote_always(value)
        when Integer, TrueClass, FalseClass, NilClass then JSON.generate(value)
        else raise ProfileError, "Unsupported profile value #{value.class}"
        end
      end
    end
  end
end
