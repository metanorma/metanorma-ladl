# frozen_string_literal: true

require "yaml"
require "json"
require_relative "instance"
require_relative "lml_codec"
require_relative "sequence"

module Metanorma
  module Ladl
    class Profile
      SCHEMA = "mn112/1"
      KEYS = {
        "LabelStyle" => %w[name definition labellers sequences templates
                           contexts],
        "LabelContext" => %w[name definition parent labellers],
        "LabelTemplate" => %w[pattern definition direction condition],
        "Labeller" => %w[id sequence context type parent template
                         global_template definition],
        "NumericSequence" => %w[base_sequence initial_value increment
                                char_direction cycle_length definition],
        "CharacterSequence" => %w[characters expansion_rule expansion_prefix
                                  direction definition],
      }.freeze
      Template = Data.define(:name, :pattern, :direction, :condition)
      Context = Data.define(:name, :type, :parent)
      Labeller = Data.define(:name, :id, :type, :context, :sequence, :parent,
                             :templates, :global_templates)

      attr_reader :instances, :contexts, :labellers, :name

      def self.from_yaml(text)
        check_yaml_keys(Psych.parse_stream(text))
        data = YAML.safe_load(text, permitted_classes: [],
                                    permitted_symbols: [], aliases: false)
        unless data.is_a?(Hash) && data.keys.all?(String) && data.keys.sort == %w[
          instances schema
        ] && data["schema"] == SCHEMA
          raise ProfileError, "Expected #{SCHEMA} schema and instances"
        end

        new(data.fetch("instances"))
      rescue Psych::Exception => e
        raise ProfileError, "Invalid profile YAML: #{e.message}"
      end

      def self.from_lml(text)
        new(LmlCodec.load(text))
      end

      # Explicit operative specialization; the original 66-declaration worked
      # example and its entrypoint remain unchanged.
      def self.iso_iec_native
        from_yaml(File.read(
                    File.expand_path("../../../ladl/iso-native.yaml",
                                     __dir__), encoding: "UTF-8"
                  ))
      end

      def self.iso_iec
        from_yaml(File.read(
                    File.expand_path("../../../ladl/iso-iec.yaml",
                                     __dir__), encoding: "UTF-8"
                  ))
      end

      def self.check_yaml_keys(node)
        if node.is_a?(Psych::Nodes::Mapping)
          keys = node.children.each_slice(2).map(&:first)
          unless keys.all? { |key| key.is_a?(Psych::Nodes::Scalar) }
            raise ProfileError, "Profile YAML map keys must be scalar strings"
          end

          duplicate = keys.map(&:value).tally.find { |_key, count| count > 1 }
          if duplicate
            raise ProfileError,
                  "Duplicate YAML key #{duplicate.first}"
          end
        end
        Array(node.respond_to?(:children) ? node.children : nil).each do |child|
          check_yaml_keys(child)
        end
      end

      def initialize(rows)
        unless rows.is_a?(Array)
          raise ProfileError,
                "instances must be an array"
        end

        @instances = rows.map { |row| make_instance(row) }
        @by_name = instances.to_h { |entry| [entry.name, entry] }
        unless @by_name.length == instances.length
          raise ProfileError,
                "Duplicate instance names"
        end

        styles = instances.select { |entry| entry.type == "LabelStyle" }
        unless styles.length == 1
          raise ProfileError,
                "Exactly one LabelStyle is required"
        end

        @style = styles.first
        %w[labellers sequences templates contexts].each do |key|
          value = @style.properties[key]
          unless value.is_a?(Array) && !value.empty?
            raise ProfileError, "LabelStyle #{key} must be a nonempty array"
          end
        end
        @name = @style.properties.fetch("name", @style.name)
        unless @name.is_a?(String)
          raise ProfileError,
                "LabelStyle name must be a string"
        end

        @sequences = {}
        @templates = instances.select do |i|
          i.type == "LabelTemplate"
        end.to_h { |i| [i.name, template(i)] }
        @contexts = instances.select do |i|
          i.type == "LabelContext"
        end.to_h do |i|
          parent = reference(i.properties["parent"])
          [i.name, Context.new(i.name, i.properties.fetch("name"), parent)]
        end
        validate_contexts
        @labellers = declared("labellers", "Labeller").map do |entry|
          labeller(entry)
        end
        if labellers.map(&:id).uniq.length != labellers.length
          raise ProfileError,
                "Duplicate labeller ids"
        end

        declared("templates", "LabelTemplate")
        declared("contexts", "LabelContext")
        Array(@style.properties.fetch("sequences")).each do |ref|
          sequence(reference(ref))
        end
        validate_labellers
        instances.each do |instance|
          deep_freeze(instance.to_data)
          instance.freeze
        end
        @instances.freeze
        [@by_name, @templates, @contexts, @sequences].each(&:freeze)
        @labellers.freeze
        freeze
      rescue KeyError => e
        raise ProfileError, "Missing profile field: #{e.message}"
      end

      def to_h
        { "schema" => SCHEMA,
          "instances" => JSON.parse(JSON.generate(instances.map(&:to_data))) }
      end

      def to_yaml
        YAML.safe_dump(to_h, aliases: false)
      end

      def to_lml
        LmlCodec.dump(to_h.fetch("instances"))
      end

      def context(name)
        contexts[name] || contexts.values.find do |context|
          context.type == name
        end
      end

      private

      def deep_freeze(value)
        case value
        when Hash then value.each do |key, item|
          deep_freeze(key)
          deep_freeze(item)
        end
        when Array then value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end

      def make_instance(row)
        unless row.is_a?(Hash) && row.keys.all?(String) && row.keys.sort == %w[
          name properties type
        ] && row["properties"].is_a?(Hash)
          raise ProfileError, "Each instance needs name, type and properties"
        end
        unless row["properties"].keys.all?(String)
          raise ProfileError,
                "Property names must be strings"
        end
        unless row["name"].is_a?(String) && row["name"].match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
          raise ProfileError, "Invalid instance name #{row['name'].inspect}"
        end

        allowed = KEYS[row["type"]]
        unless allowed
          raise UnsupportedFeature,
                "Unsupported instance type #{row['type']}"
        end

        unknown = row["properties"].keys - allowed
        unless unknown.empty?
          raise ProfileError,
                "#{row['name']}: unknown properties #{unknown.join(', ')}"
        end
        if row["properties"].key?("definition") && !row["properties"]["definition"].is_a?(String)
          raise ProfileError, "#{row['name']}: definition must be text"
        end
        if %w[NumericSequence CharacterSequence].include?(row["type"]) && Sequence::BUILTINS.key?(row["name"])
          raise ProfileError, "Cannot redefine built-in sequence #{row['name']}"
        end

        Instance.new(name: row["name"], type: row["type"],
                     properties: row["properties"])
      end

      def reference(value)
        return nil if value.nil?
        return value.fetch("ref") if value.is_a?(Hash) && value.keys == ["ref"]
        return value if value.is_a?(String)

        raise ProfileError, "Expected a named reference, got #{value.inspect}"
      end

      def refs(value)
        Array(value.is_a?(Array) ? value : [value]).map do |item|
          reference(item)
        end
      end

      def declared(key, type)
        refs(@style.properties.fetch(key)).map do |name|
          entry = if name&.start_with?("id:")
                    instances.find do |i|
                      i.type == type && i.properties["id"] == name.delete_prefix("id:")
                    end
                  else @by_name[name]
                  end
          unless entry&.type == type
            raise ProfileError,
                  "Unresolved #{type} reference #{name}"
          end

          entry
        end
      end

      def template(entry)
        pattern = entry.properties.fetch("pattern")
        unless pattern.is_a?(String)
          raise ProfileError,
                "#{entry.name}: pattern must be a string"
        end

        unsupported = pattern.scan(/%[A-Za-z]+/) - %w[%n %pn %parent %self]
        unless unsupported.empty?
          raise UnsupportedFeature,
                "Unknown template placeholders #{unsupported.inspect}"
        end

        direction = entry.properties["direction"]
        raise ProfileError, "Invalid template direction" if direction && !%w[
          ltr rtl
        ].include?(direction)

        condition = entry.properties["condition"]
        if condition && !(condition.is_a?(Hash) && condition.keys.all?(String) && condition.keys.sort == %w[
          threshold type
        ] &&
              %w[element_count_gt element_count_eq
                 element_count_lt].include?(condition["type"]) && condition["threshold"].is_a?(Integer))
          raise ProfileError, "#{entry.name}: invalid element-count condition"
        end

        Template.new(entry.name, pattern, direction, condition)
      end

      def sequence(name, stack = [])
        return @sequences[name] if @sequences.key?(name)
        if stack.include?(name)
          raise ProfileError,
                "Sequence inheritance cycle: #{(stack + [name]).join(' -> ')}"
        end

        entry = @by_name[name]
        return @sequences[name] = Sequence.builtin(name) unless entry

        p = entry.properties
        @sequences[name] = case entry.type
                           when "NumericSequence"
                             raise UnsupportedFeature, "Custom cycle_length has no specified expansion algorithm" if p.key?("cycle_length")

                             base = sequence(reference(p.fetch("base_sequence")), stack + [name])
                             Sequence.new(name, base: base, initial_value: p.fetch("initial_value", 1), increment: p.fetch("increment", 1), direction: p["char_direction"])
                           when "CharacterSequence"
                             chars = p.fetch("characters")
                             unless chars.is_a?(Array) && !chars.empty? && chars.all? do |c|
                               c.is_a?(String) && !c.empty?
                             end
                               raise ProfileError, "#{name}: characters must be nonempty strings"
                             end

                             Sequence.new(name, kind: :characters, characters: chars, expansion_rule: p.fetch("expansion_rule", "none"), expansion_prefix: p.fetch("expansion_prefix", []), direction: p["direction"])
                           else raise ProfileError, "#{name} is not a sequence"
                           end
      end

      def labeller(entry)
        p = entry.properties
        unless %w[id type].all? { |key| p[key].is_a?(String) && !p[key].empty? }
          raise ProfileError,
                "#{entry.name}: id and type must be nonempty strings"
        end

        templates = refs(p.fetch("template")).map do |name|
          @templates.fetch(name)
        end
        globals = if p["global_template"]
                    refs(p["global_template"]).map do |name|
                      @templates.fetch(name)
                    end
                  else
                    []
                  end
        if templates.empty?
          raise ProfileError,
                "#{entry.name}: at least one template required"
        end
        if templates.any? { |t| t.pattern.include?("%self") }
          raise ProfileError,
                "#{entry.name}: local template cannot recursively interpolate %self"
        end

        context = reference(p.fetch("context"))
        unless contexts.key?(context)
          raise ProfileError,
                "Unknown context #{context}"
        end

        Labeller.new(entry.name, p.fetch("id"), p.fetch("type"), context,
                     sequence(reference(p.fetch("sequence"))), reference(p["parent"]), templates, globals)
      end

      def validate_contexts
        contexts.each_value do |context|
          unless context.type.is_a?(String) && !context.type.empty?
            raise ProfileError,
                  "#{context.name}: context name must be a nonempty string"
          end

          seen = []
          current = context
          while current
            if seen.include?(current.name)
              raise ProfileError,
                    "Context inheritance cycle"
            end

            seen << current.name
            if current.parent && !contexts.key?(current.parent)
              raise ProfileError,
                    "Unknown parent context #{current.parent}"
            end

            current = contexts[current.parent]
          end
        end
        if contexts.values.map(&:type).uniq.length != contexts.length
          raise ProfileError,
                "Duplicate context type names"
        end
      end

      def validate_labellers
        by_name = labellers.to_h { |entry| [entry.name, entry] }
        labellers.each do |entry|
          seen = []
          current = entry
          while current
            if seen.include?(current.name)
              raise ProfileError,
                    "Labeller inheritance cycle"
            end

            seen << current.name
            if current.parent && !by_name.key?(current.parent)
              raise ProfileError,
                    "Unknown parent labeller #{current.parent}"
            end

            current = by_name[current.parent]
          end
        end
        duplicate = labellers.group_by do |l|
          [l.context, l.type]
        end.find { |_key, values| values.length > 1 }
        if duplicate
          raise ProfileError,
                "Ambiguous labellers for context/type #{duplicate.first.inspect}"
        end

        instances.select do |entry|
          entry.type == "LabelContext"
        end.each do |context|
          next unless context.properties.key?("labellers")

          refs(context.properties["labellers"]).each do |name|
            bound = labellers.find do |l|
              l.name == name || "id:#{l.id}" == name
            end
            unless bound && bound.context == context.name
              raise ProfileError,
                    "#{context.name}: labeller binding #{name} disagrees with its declared context"
            end
          end
        end
      end
    end
  end
end
