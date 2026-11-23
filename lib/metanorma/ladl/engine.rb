# frozen_string_literal: true

module Metanorma
  module Ladl
    class Engine
      def initialize(profile:)
        raise ProfileError, "Engine needs a validated Profile" unless profile.is_a?(Profile)
        @profile = profile
      end

      # All runtime counters/bindings are invocation-local. No labels are written
      # until every label has been calculated successfully.
      def call(presentation_model, adapter: ContentElementAdapter.new, **_options)
        required = %i[children type context identifier assign validate]
        missing = required.reject { |method| adapter.respond_to?(method) }
        raise TreeError, "Model adapter lacks #{missing.join(', ')}" unless missing.empty?
        Run.new(@profile, adapter).call(presentation_model)
      end

      class Run
        Binding = Data.define(:labeller, :scope)

        def initialize(profile, adapter)
          @profile, @adapter = profile, adapter
          @nodes, @parents, @bindings, @labels = [], {}, {}, {}
        end

        def call(root)
          collect(root)
          identify_bindings
          groups = @bindings.group_by { |_id, binding| [binding.labeller.name, binding.scope.object_id] }
          positions = {}
          groups.each_value do |items|
            items.each_with_index { |(id, _binding), index| positions[id] = [index + 1, items.length] }
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
          ids, seen = {}, {}
          pending = [[root, nil]]
          until pending.empty?
            node, parent = pending.pop
            @adapter.validate(node)
            raise TreeError, "Content must be a tree; repeated or cyclic node" if seen[node.object_id]
            seen[node.object_id] = true
            id = @adapter.identifier(node)
            raise TreeError, "Duplicate content id #{id}" if id && ids.key?(id)
            ids[id] = node if id
            children = @adapter.children(node)
            raise TreeError, "Adapter children must be an Array" unless children.is_a?(Array)
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
              raise TreeError, "Adapter contexts must be an Array" unless contexts.is_a?(Array)
              contexts.each do |context_name|
                context = @profile.context(context_name)
                raise TreeError, "Unknown content context #{context_name}" unless context
                labeller = @profile.labellers.find { |l| l.context == context.name && l.type == @adapter.type(node) }
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
          value = labeller.sequence.value(position)
          local_template = select_template(labeller.templates, count)
          local = interpolate(local_template.pattern, value: value, parent: parent, self_value: nil)
          global_template = select_template(labeller.global_templates, count)
          global = global_template && interpolate(global_template.pattern, value: value, parent: parent, self_value: local)
          Label.new(local: local, global: global, value: value,
                    direction: local_template.direction || labeller.sequence.direction,
                    global_direction: global_template && (global_template.direction || labeller.sequence.direction),
                    labeller: labeller.id)
        end

        def parent_label(node, binding)
          expected = binding.labeller.parent
          current = expected ? @parents[node.object_id] : binding.scope
          while current
            parent_binding = @bindings[current.object_id]
            label = @labels[current.object_id]
            return label if label && (!expected || parent_binding.labeller.name == expected)
            current = @parents[current.object_id]
          end
          if expected
            raise MissingParent, "#{binding.labeller.name}: no ancestor labeled by #{expected}"
          end
          nil
        end

        def select_template(templates, count)
          return nil if templates.empty?
          templates.find { |template| template.condition && matches?(template.condition, count) } ||
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
              raise MissingParent, "%pn needs a parent labeller value" unless parent
              parent.value
            when "parent"
              raise MissingParent, "%parent needs a labeled context ancestor" unless parent
              parent.global || parent.local
            when "self"
              raise ProfileError, "%self cannot occur in a local template" unless self_value
              self_value
            end
          end
        end
      end
    end
  end
end
