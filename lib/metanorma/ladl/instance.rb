# frozen_string_literal: true

require "lutaml/model"

module Metanorma
  module Ladl
    # Normalized LML instance data. Both realizations retain every declaration,
    # reference and definition; runtime validation lives in Profile.
    class Instance < Lutaml::Model::Serializable
      attribute :name, :string
      attribute :type, :string
      attribute :properties, :hash

      def to_data
        { "name" => name, "type" => type, "properties" => properties }
      end
    end
  end
end
