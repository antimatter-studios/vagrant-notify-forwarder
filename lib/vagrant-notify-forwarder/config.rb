module VagrantPlugins
  module VagrantNotifyForwarder
    class Config < Vagrant.plugin(2, :config)
      attr_accessor :port
      attr_accessor :enable
      attr_accessor :run_as_root
      attr_accessor :binaries

      NOTIFY_FORWARDER_VERSION = 'v1.2.0'.freeze
      NOTIFY_FORWARDER_BASE_URL = "https://github.com/antimatter-studios/notify-forwarder/releases/download/#{NOTIFY_FORWARDER_VERSION}".freeze

      # The checksums belong to NOTIFY_FORWARDER_VERSION and move with it. The release
      # workflow stops if a release binary does not match.
      DEFAULT_BINARIES = {
        [:linux, :x86_64] => [
          "#{NOTIFY_FORWARDER_BASE_URL}/notify-forwarder-linux_x86_64",
          'aa9e75bab32c6566ed2f1812084ba81f5984baa47b99b5591b6331cccfc4aa55'
        ],
        [:linux, :arm64] => [
          "#{NOTIFY_FORWARDER_BASE_URL}/notify-forwarder-linux_arm64",
          '4c28fa44154acb8898f46ca62115375ad5620b0dcd9ce56b231edac1ffd252d5'
        ],
        [:linux, :armv7l] => [
          "#{NOTIFY_FORWARDER_BASE_URL}/notify-forwarder-linux_armv7l",
          '153ca6ab7ec6f71aab23188af6e5a1fa5f74bb5c083d9af9bfd16a6ef0b520e1'
        ],
        [:darwin, :x86_64] => [
          "#{NOTIFY_FORWARDER_BASE_URL}/notify-forwarder-darwin_x86_64",
          '88b7ca2070dcaf278e35531fd06aa359623f4a84e8a9f03adf2bd349e7343dfd'
        ],
        [:darwin, :arm64] => [
          "#{NOTIFY_FORWARDER_BASE_URL}/notify-forwarder-darwin_arm64",
          '4236f8bf950268fe43eb7765e9f2b4c0546f847ea0abd2f2cff1e5395a4014f7'
        ],
      }.freeze

      def initialize
        @port = UNSET_VALUE
        @enable = UNSET_VALUE
        @run_as_root = UNSET_VALUE
        @binaries = UNSET_VALUE
      end

      def finalize!
        @port = 29324 if @port == UNSET_VALUE
        @enable = true if @enable == UNSET_VALUE
        @run_as_root = false if @run_as_root == UNSET_VALUE
        @binaries = prepare_binaries(@binaries)
      end

      def validate(_machine)
        errors = []
        unless @port.is_a?(Integer) && (1..65535).cover?(@port)
          errors << 'config.notify_forwarder.port must be an integer between 1 and 65535.'
        end
        { 'notify_forwarder' => errors }
      end

      private

      def prepare_binaries(value)
        defaults = DEFAULT_BINARIES.transform_values(&:dup)

        return defaults if value == UNSET_VALUE || value.nil?

        overrides = normalize_binary_map(value)
        defaults.merge(overrides) do |_key, _old, new_value|
          Array(new_value)
        end
      end

      def normalize_binary_map(map)
        map.each_with_object({}) do |(key, raw_value), acc|
          normalized_key = normalize_binary_key(key)
          acc[normalized_key] = normalize_binary_value(raw_value)
        end
      end

      def normalize_binary_key(key)
        tuple = Array(key).map do |segment|
          segment.respond_to?(:to_sym) ? segment.to_sym : segment
        end

        unless tuple.length == 2
          raise ArgumentError, "Binary definitions must use two-part keys like [:linux, :x86_64]"
        end

        [tuple[0], tuple[1]]
      end

      def normalize_binary_value(value)
        case value
        when Array
          value
        when Hash
          url = value[:url] || value['url']
          checksum = value[:sha256] || value['sha256']
          if url.nil? || checksum.nil?
            raise ArgumentError, "Binary definition hash must include :url and :sha256 keys"
          end
          [url, checksum]
        else
          raise ArgumentError, "Binary definition must be an Array [url, sha256] or Hash with :url/:sha256"
        end
      end
    end
  end
end
