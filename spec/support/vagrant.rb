module Vagrant
  class Config
    UNSET_VALUE = Object.new.freeze
  end

  def self.plugin(version, component)
    raise ArgumentError, 'Only the config API is stubbed' unless version == 2 && component == :config

    Config
  end
end
