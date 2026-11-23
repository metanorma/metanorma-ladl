# frozen_string_literal: true

module Metanorma
  module Ladl
    class Error < StandardError; end
    class ProfileError < Error; end
    class UnsupportedFeature < ProfileError; end
    class TreeError < Error; end
    class MissingParent < TreeError; end
  end
end
