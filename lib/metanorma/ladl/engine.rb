# frozen_string_literal: true

module Metanorma
  module Ladl
    class Engine
      def initialize(profile:)
        unless profile.is_a?(Profile)
          raise ProfileError,
                "Engine needs a validated Profile"
        end

        @profile = profile
      end

      # All runtime counters/bindings are invocation-local. No labels are written
      # until every label has been calculated successfully.
      def call(presentation_model, adapter: ContentElementAdapter.new,
**_options)
        required = %i[children type context identifier assign validate]
        missing = required.reject { |method| adapter.respond_to?(method) }
        unless missing.empty?
          raise TreeError,
                "Model adapter lacks #{missing.join(', ')}"
        end

        Run.new(@profile, adapter).call(presentation_model)
      end

      class Run
        Binding = Data.define(:labeller, :scope)

        def initialize(profile, adapter)
          @profile = profile
          @adapter = adapter
          @nodes = []
          @parents = {}
          @bindings = {}
          @labels = {}
          # Invocation-local compound numbers ("1.1", "A.1"), keyed by Label.
          # Label#value stays the element's own ordinal.
          @qualified = {}
          @labellers_by_name = profile.labellers.to_h do |entry|
            [entry.name, entry]
          end
        end

        def call(root)
          collect(root)
          identify_bindings
          groups = @bindings.group_by do |_id, binding|
            [binding.labeller.name, binding.scope.object_id]
          end
          positions = {}
          groups.each_value do |items|
            binding = items.first.last
            count = if @adapter.respond_to?(:template_element_count)
                      @adapter.template_element_count(scope: binding.scope,
                                                      type: binding.labeller.type, context: binding.labeller.context,
                                                      nodes: @nodes, default: items.length)
                    else
                      items.length
                    end
            unless count.is_a?(Integer) && count >= items.length && count <= @nodes.length
              raise TreeError,
                    "Adapter template element count must be an Integer between the numbered group size and tree size"
            end

            items.each_with_index do |(id, _binding), index|
              positions[id] = [index + 1, count]
            end
          end
          @nodes.each do |node|
            binding = @bindings[node.object_id]
            next unless binding

            position, count = positions.fetch(node.object_id)
            @labels[node.object_id] = calculate(node, binding, position, count)
          end
          @nodes.each { |node| @adapter.assign(node, @labels[node.object_id]) }
          root
        end

        private

        def collect(root)
          ids = {}
          seen = {}
          pending = [[root, nil]]
          until pending.empty?
            node, parent = pending.pop
            @adapter.validate(node)
            if seen[node.object_id]
              raise TreeError,
                    "Content must be a tree; repeated or cyclic node"
            end

            seen[node.object_id] = true
            id = @adapter.identifier(node)
            raise TreeError, "Duplicate content id #{id}" if id && ids.key?(id)

            ids[id] = node if id
            children = @adapter.children(node)
            unless children.is_a?(Array)
              raise TreeError,
                    "Adapter children must be an Array"
            end

            @nodes << node
            @parents[node.object_id] = parent
            children.reverse_each { |child| pending << [child, node] }
          end
        end

        def identify_bindings
          @nodes.each do |node|
            current = node
            while current
              contexts = if @adapter.respond_to?(:contexts_for)
                           @adapter.contexts_for(current, node)
                         else
                           [@adapter.context(current)].compact
                         end
              unless contexts.is_a?(Array)
                raise TreeError,
                      "Adapter contexts must be an Array"
              end

              contexts.each do |context_name|
                context = @profile.context(context_name)
                unless context
                  raise TreeError,
                        "Unknown content context #{context_name}"
                end

                labeller = @profile.labellers.find do |l|
                  l.context == context.name && l.type == @adapter.type(node)
                end
                next unless labeller

                @bindings[node.object_id] = Binding.new(labeller, current)
                break
              end
              break if @bindings.key?(node.object_id)

              current = @parents[current.object_id]
            end
          end
        end

        def calculate(node, binding, position, count)
          labeller = binding.labeller
          parent = parent_label(node, binding)
          if labeller.parent && parent&.labeller == labeller.id && !@qualified.key?(parent.object_id)
            raise UnsupportedFeature,
                  "#{labeller.name}: nested use needs a compound %pn<separator>%n template"
          end

          sequence = if @adapter.respond_to?(:sequence_for)
                       @adapter.sequence_for(node, default: labeller.sequence)
                     else
                       labeller.sequence
                     end
          unless sequence.is_a?(Sequence)
            raise TreeError,
                  "Adapter sequence must be a Sequence"
          end

          value = sequence.value(position)
          local_template = select_template(labeller.templates, count)
          local = interpolate(local_template.pattern, value: value,
                                                      parent: parent, self_value: nil)
          global_template = select_template(labeller.global_templates, count)
          global = global_template && interpolate(global_template.pattern,
                                                  value: value, parent: parent, self_value: local)
          label = Label.new(local: local, global: global, value: value,
                            direction: local_template.direction || sequence.direction,
                            global_direction: global_template && (global_template.direction || sequence.direction),
                            labeller: labeller.id)
          compound = qualified_number(local_template, value, parent)
          @qualified[label.object_id] = compound if compound
          label
        end

        # The nearest qualifying ancestor supplies the parent: the declared
        # labeller, the same labeller (recursive hierarchy), or a same-type
        # variant that is this element's own counter scope (an annex figure
        # for its subfigures). No other labeller satisfies a declared parent.
        def parent_label(node, binding)
          expected = binding.labeller.parent
          current = expected ? @parents[node.object_id] : binding.scope
          while current
            label = @labels[current.object_id]
            return label if label && (!expected || parent_match?(current,
                                                                 binding))

            current = @parents[current.object_id]
          end
          if expected
            raise MissingParent,
                  "#{binding.labeller.name}: no ancestor labeled by #{expected}"
          end

          nil
        end

        def parent_match?(candidate, binding)
          found = @bindings.fetch(candidate.object_id).labeller
          expected = binding.labeller.parent
          return true if found.name == expected || found.name == binding.labeller.name

          candidate.equal?(binding.scope) && found.type == @labellers_by_name.fetch(expected).type
        end

        def qualified_number(template, value, parent)
          separator = template.pattern[/%pn([.\-:\/])%n/, 1]
          return unless separator && parent

          "#{parent_number(parent)}#{separator}#{value}"
        end

        def parent_number(parent)
          @qualified.fetch(parent.object_id, parent.value)
        end

        def select_template(templates, count)
          return nil if templates.empty?

          templates.find do |template|
            template.condition && matches?(template.condition, count)
          end ||
            templates.find { |template| !template.condition } || templates.first
        end

        def matches?(condition, count)
          threshold = condition.fetch("threshold")
          case condition.fetch("type")
          when "element_count_gt" then count > threshold
          when "element_count_eq" then count == threshold
          when "element_count_lt" then count < threshold
          end
        end

        def interpolate(pattern, value:, parent:, self_value:)
          pattern.gsub(/%(parent|self|pn|n)/) do
            case Regexp.last_match(1)
            when "n" then value
            when "pn"
              unless parent
                raise MissingParent,
                      "%pn needs a parent labeller value"
              end

              parent_number(parent)
            when "parent"
              unless parent
                raise MissingParent,
                      "%parent needs a labeled context ancestor"
              end

              parent.global || parent.local
            when "self"
              unless self_value
                raise ProfileError,
                      "%self cannot occur in a local template"
              end

              self_value
            end
          end
        end
      end
    end
  end
end
