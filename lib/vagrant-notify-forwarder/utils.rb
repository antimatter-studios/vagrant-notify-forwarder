require 'digest'
require 'securerandom'
require 'uri'
require 'vagrant'
require 'vagrant/util/downloader'

module VagrantPlugins
  module VagrantNotifyForwarder
    # A VagrantError, so Vagrant reports the message and its recovery does not
    # destroy a machine that has already booted.
    class BinaryChecksumMismatch < Vagrant::Errors::VagrantError
      def initialize(url, expected, actual)
        @mismatch = "Notify-forwarder: Checksum mismatch for '#{url}': " \
                    "expected sha256 #{expected}, got #{actual}. The download was deleted."
        super()
      end

      def error_message
        @mismatch
      end
    end

    class Utils
      @@OS_NAMES = {
          "Linux" => :linux,
          "Darwin" => :darwin,
          "FreeBSD" => :freebsd,
      }

      @@HARDWARE_NAMES = {
          "x86_64" => :x86_64,
          "amd64" => :x86_64,
          "arm64" => :arm64,
          "aarch64" => :arm64,
          "armv7l" => :armv7l,
      }

      def self.parse_os_name(data)
        @@OS_NAMES[data.strip] or :unsupported
      end

      def self.parse_hardware_name(data)
        @@HARDWARE_NAMES[data.strip] or :unsupported
      end

      def self.ensure_binary_downloaded(env, os, hardware)
        config = env.fetch(:machine).config.notify_forwarder
        download_map = config.binaries
        url, sha256sum = download_map[[os, hardware]]
        sha256sum = sha256sum.downcase if sha256sum

        unless url && sha256sum
          env[:ui].error "Notify-forwarder: No binary configured for host '#{os}' '#{hardware}'"
          return
        end

        expanded_url = expand_binary_url(url)
        env[:ui].info "Notify-forwarder: Using binary '#{expanded_url}' (sha256 #{sha256sum[0,8]}...) for '#{os}' '#{hardware}'"

        uri = safe_parse_uri(expanded_url)
        basename = File.basename(uri ? uri.path : expanded_url)
        path = env[:tmp_path].join basename
        should_download = true

        if File.exist? path
          digest = Digest::SHA256.file(path).hexdigest

          if digest == sha256sum
            should_download = false
          end
        end

        if should_download
          env[:ui].detail 'Notify-forwarder: Downloading client'
          download_verified expanded_url, path, sha256sum
        end

        File.chmod(0755, path)

        path
      end

      # Parallel `up`s share tmp_path, so each downloads to its own name and only
      # a verified file ever appears at the path that gets executed.
      def self.download_verified(url, path, sha256sum)
        partial = "#{path}.#{Process.pid}.#{SecureRandom.hex(4)}.part"

        begin
          Vagrant::Util::Downloader.new(url, partial).download!

          digest = Digest::SHA256.file(partial).hexdigest
          raise BinaryChecksumMismatch.new(url, sha256sum, digest) unless digest == sha256sum

          File.chmod(0755, partial)
          File.rename(partial, path)
        ensure
          File.delete(partial) if File.exist?(partial)
        end
      end

      def self.expand_binary_url(url)
        expanded = expand_environment(url.to_s)

        if expanded.start_with?('file://')
          uri = URI.parse(expanded)
          uri.path = File.expand_path(uri.path)
          return uri.to_s
        end

        return expanded if expanded =~ %r{^[a-zA-Z][a-zA-Z0-9+.-]*://}

        File.expand_path(expanded)
      end

      def self.expand_environment(value)
        value.gsub(/\$(\{)?([A-Za-z0-9_]+)\}?/) do
          key = Regexp.last_match(2)
          ENV.fetch(key, '')
        end
      end

      def self.safe_parse_uri(url)
        URI.parse(url)
      rescue URI::InvalidURIError
        nil
      end

      def self.host_pidfile(env)
        env[:machine].data_dir.join('notify_watcher_host_pid')
      end
    end
  end
end
