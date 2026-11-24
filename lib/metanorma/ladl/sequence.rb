# frozen_string_literal: true

module Metanorma
  module Ladl
    class Sequence
      BUILTINS = {
        "DecimalNumericSequence" => [:decimal, nil, "ltr"],
        "ArabicNumericSequence" => [:arabic, nil, "rtl"],
        "AlphaLowerNumericSequence" => [:alphabet, ("a".."z").to_a, "ltr"],
        "AlphaUpperNumericSequence" => [:alphabet, ("A".."Z").to_a, "ltr"],
        "RomanLowerNumericSequence" => [:roman_lower, nil, "ltr"],
        "RomanUpperNumericSequence" => [:roman_upper, nil, "ltr"],
        "GreekLowerCharacterSequence" => [:characters,
                                          "αβγδεζηθικλμνξοπρστυφχψω".chars, "ltr"],
        "GreekUpperCharacterSequence" => [:characters,
                                          "ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ".chars, "ltr"],
      }.freeze
      ROMAN = [[1000, "M"], [900, "CM"], [500, "D"], [400, "CD"],
               [100, "C"], [90, "XC"], [50, "L"], [40, "XL"],
               [10, "X"], [9, "IX"], [5, "V"], [4, "IV"], [1, "I"]].freeze

      attr_reader :name, :direction

      def self.builtin(name)
        kind, chars, direction = BUILTINS.fetch(name) do
          raise UnsupportedFeature, "Unsupported or undefined sequence #{name}"
        end
        new(name, kind: kind, characters: chars, direction: direction)
      end

      def initialize(name, kind: nil, base: nil, initial_value: 1, increment: 1,
                     characters: nil, expansion_rule: "none", expansion_prefix: [],
                     direction: nil)
        unless initial_value.is_a?(Integer) && increment.is_a?(Integer) && !increment.zero?
          raise ProfileError,
                "#{name}: numeric initial_value/increment must be integers; increment cannot be zero"
        end

        @name = name
        @kind = kind
        @base = base
        @initial_value = initial_value
        @increment = increment
        @characters = characters&.dup&.freeze
        @expansion_rule = expansion_rule
        @prefixes = expansion_prefix
        unless %w[none repeat_label double_character
                  prepend_prefix].include?(expansion_rule)
          raise UnsupportedFeature,
                "#{name}: expansion #{expansion_rule.inspect} has no implemented semantics"
        end
        unless expansion_prefix.is_a?(Array) && expansion_prefix.all? do |p|
          p.is_a?(String) && !p.empty?
        end
          raise ProfileError,
                "#{name}: expansion_prefix must be an array of nonempty strings"
        end
        if kind == :characters && (!characters.is_a?(Array) || characters.empty?)
          raise ProfileError, "#{name}: character sequences require characters"
        end

        @direction = direction || base&.direction || "ltr"
        unless %w[ltr rtl].include?(@direction)
          raise ProfileError, "#{name}: invalid direction #{@direction.inspect}"
        end
      end

      # Sequence#set_initial_value from MN112, represented as an immutable
      # invocation-local value so one authored list cannot change the next.
      def with_initial_value(initial_value)
        self.class.new(name, kind: @kind, base: @base,
                             initial_value: initial_value, increment: @increment,
                             characters: @characters, expansion_rule: @expansion_rule,
                             expansion_prefix: @prefixes, direction: direction)
      end

      def value(position)
        unless position.is_a?(Integer) && position.positive?
          raise ProfileError,
                "Sequence position must be a positive integer"
        end

        format(@initial_value + ((position - 1) * @increment))
      end

      def format(number)
        return @base.format(number) if @base

        case @kind
        when :decimal then number.to_s
        when :arabic then number.to_s.tr("0123456789", "٠١٢٣٤٥٦٧٨٩")
        when :alphabet then alphabet(number)
        when :roman_upper then roman(number)
        when :roman_lower then roman(number).downcase
        when :characters then character(number)
        else raise UnsupportedFeature, "#{name}: unsupported sequence kind"
        end
      end

      private

      def alphabet(number)
        unless number.positive?
          raise ProfileError,
                "#{name}: alphabet position must be positive"
        end

        result = +""
        while number.positive?
          number, digit = (number - 1).divmod(@characters.length)
          result.prepend(@characters.fetch(digit))
        end
        result
      end

      def roman(number)
        unless (1..3999).cover?(number)
          raise UnsupportedFeature, "Roman sequence supports positions 1..3999"
        end

        ROMAN.each_with_object(+"") do |(value, glyph), output|
          count, number = number.divmod(value)
          output << (glyph * count)
        end
      end

      def character(number)
        unless number.positive?
          raise ProfileError,
                "#{name}: character position must be positive"
        end

        cycle, index = (number - 1).divmod(@characters.length)
        glyph = @characters.fetch(index)
        return glyph if cycle.zero?

        case @expansion_rule
        when "repeat_label" then glyph * (cycle + 1)
        when "double_character" then glyph * (2**cycle)
        when "prepend_prefix"
          prefix = @prefixes[cycle - 1]
          unless prefix
            raise UnsupportedFeature,
                  "#{name}: expansion prefixes exhausted"
          end

          prefix + glyph
        when "none" then raise UnsupportedFeature,
                               "#{name}: character sequence exhausted"
        else raise UnsupportedFeature,
                   "#{name}: expansion #{@expansion_rule.inspect} requires a defined suffix rule"
        end
      end
    end
  end
end
