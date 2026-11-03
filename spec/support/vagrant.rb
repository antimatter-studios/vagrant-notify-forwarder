module Vagrant
  class Config
    UNSET_VALUE = Object.new.freeze
  end

  module Errors
    class VagrantError < StandardError
      def initialize(*)
        super(error_message)
      end

      def error_message
        'No error message'
      end
    end
  end

  def self.plugin(version, component)
    raise ArgumentError, 'Only the config API is stubbed' unless version == 2 && component == :config

    Config
  end
end
