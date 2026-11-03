module VagrantPlugins
  module VagrantNotifyForwarder
    class Config < Vagrant.plugin(2, :config)
      attr_accessor :port
      attr_accessor :enable
      attr_accessor :run_as_root
      attr_accessor :binaries

      NOTIFY_FORWARDER_VERSION = 'v1.1.0'.freeze
      NOTIFY_FORWARDER_BASE_URL = "https://github.com/antimatter-studios/notify-forwarder/releases/download/#{NOTIFY_FORWARDER_VERSION}".freeze

      # The checksums belong to NOTIFY_FORWARDER_VERSION and move with it. The release
      # workflow stops if a release binary does not match.
      DEFAULT_BINARIES = {
        [:linux, :x86_64] => [
          "#{NOTIFY_FORWARDER_BASE_URL}/notify-forwarder-linux_x86_64",
          '8fe1b79e2673187319044595b485fded2fc79a8dc886e9d3616b6bbe15e398dc'
        ],
        [:linux, :arm64] => [
          "#{NOTIFY_FORWARDER_BASE_URL}/notify-forwarder-linux_arm64",
          '5ee81f9bc7ed888351e78c6015a49e42847b5d29b87ed828721cbf2ce452f876'
        ],
        [:linux, :armv7l] => [
          "#{NOTIFY_FORWARDER_BASE_URL}/notify-forwarder-linux_armv7l",
          '9ef5130e050cd47af29c7358e7bd63cffee185185ca32ec77597c0bfeb3d38a6'
        ],
        [:darwin, :x86_64] => [
          "#{NOTIFY_FORWARDER_BASE_URL}/notify-forwarder-darwin_x86_64",
          '0160e13cad8b3b91c0d5dbfe7b2f013a1c0362538056aa69dcfd26596b96bddb'
        ],
        [:darwin, :arm64] => [
          "#{NOTIFY_FORWARDER_BASE_URL}/notify-forwarder-darwin_arm64",
          '33dd00bf392c71e94238b2cfbf793f9ff2e987c37837634fabc1e04f242ef9a8'
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
