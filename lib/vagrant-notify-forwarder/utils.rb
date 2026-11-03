require 'digest'
require 'securerandom'
require 'uri'
require 'json'
require 'open3'
require 'socket'
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

    class PortUnavailable < Vagrant::Errors::VagrantError
      def initialize(first, last)
        @unavailable = "Notify-forwarder: No free UDP port on 127.0.0.1 in #{first}-#{last}. " \
                       'Set config.notify_forwarder.port to another range.'
        super()
      end

      def error_message
        @unavailable
      end
    end

    class Utils
      PORT_ATTEMPTS = 10
      @port_claims = {}
      @port_claims_lock = Mutex.new

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
          env[:ui].error "Notify-forwarder: No binary configured for '#{os}' '#{hardware}'. " \
                         'Set one through config.notify_forwarder.binaries.'
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

      # States in which the guest and any forward are what the last start set up.
      RETAINED_STATES = [:running, :saved, :paused].freeze

      def self.port_file(env)
        env[:machine].data_dir.join('notify_forwarder_port')
      end

      def self.recorded_port(env)
        path = port_file(env)
        return unless path.file?

        value = path.read.strip
        value.to_i if value.match?(/\A[1-9][0-9]*\z/)
      end

      # A machine that kept its forward keeps the port it recorded: its own forward
      # holds that port, so a probe would find it taken and move away from it. Any
      # other start chooses here, once, and the forward and the watcher both use it.
      def self.choose_port(env)
        machine = env[:machine]
        retained = RETAINED_STATES.include?(machine.state.id) ? recorded_port(env) : nil
        port = retained || claim_free_port(env, machine.config.notify_forwarder.port)
        port_file(env).write("#{port}\n")
        port
      end

      def self.udp_port_free?(port)
        socket = UDPSocket.new
        socket.bind('127.0.0.1', port)
        true
      rescue SystemCallError
        false
      ensure
        socket.close if socket
      end

      # A claim covers the time between choosing a port and the provider binding it,
      # when a machine starting beside this one would find the port still free. It is
      # a lock on a file, so it holds between `vagrant` processes sharing a
      # VAGRANT_HOME as well as within one, and it ends when the process does.
      def self.claim_free_port(env, first)
        release_port_claim(env)

        PORT_ATTEMPTS.times do |offset|
          port = first + offset
          claim = lock_port(env, port)
          next unless claim

          if udp_port_free?(port)
            @port_claims_lock.synchronize { @port_claims[env[:machine].data_dir.to_s] = claim }
            return port
          end
          claim.close
        end
        raise PortUnavailable.new(first, first + PORT_ATTEMPTS - 1)
      end

      # The files stay: removing one could separate two holders of the same port.
      # File.open marks the descriptor close-on-exec, so a provider's process does not
      # inherit the lock and keep it after this `vagrant` has gone.
      def self.lock_port(env, port)
        directory = env[:tmp_path].join('notify-forwarder-ports')
        directory.mkpath
        file = File.open(directory.join("#{port}.lock"), File::RDWR | File::CREAT, 0o600)
        return file if file.flock(File::LOCK_EX | File::LOCK_NB)

        file.close
        nil
      end

      def self.release_port_claim(env)
        claim = @port_claims_lock.synchronize { @port_claims.delete(env[:machine].data_dir.to_s) }
        claim.close if claim
      end

      def self.current_port(env)
        recorded_port(env) || env[:machine].config.notify_forwarder.port
      end

      def self.host_pidfile(env)
        env[:machine].data_dir.join('notify_watcher_host_pid')
      end

      def self.host_watcher_log(env)
        env[:machine].data_dir.join('notify_watcher_host.log')
      end

      def self.watcher_identity(pid)
        return unless pid.to_s.match?(/\A[1-9][0-9]*\z/) && pid.to_i > 1

        output, _error, status = Open3.capture3(
          { 'LC_ALL' => 'C' }, 'ps', '-ww', '-p', pid.to_s, '-o', 'lstart=', '-o', 'args='
        )
        output.strip if status.success? && !output.strip.empty?
      rescue SystemCallError, IOError
        nil
      end

      def self.record_host_watcher(env, pid, reaper = nil)
        identity = watcher_identity(pid)
        return false if reaper && reaper.join(0)
        unless identity
          env[:ui].error "Notify-forwarder: Could not verify watcher #{pid}; its PID was not recorded"
          return false
        end

        host_pidfile(env).open('a') do |file|
          file.puts("#{pid} #{JSON.generate(identity: identity)}")
        end
        true
      end

      def self.stop_host_watchers(env)
        pidfile = host_pidfile(env)
        return unless pidfile.file?

        pidfile.each_line do |line|
          pid, metadata = line.split(' ', 2)
          next unless pid && metadata && pid.match?(/\A[1-9][0-9]*\z/) && pid.to_i > 1

          begin
            record = JSON.parse(metadata)
            next unless record.is_a?(Hash) && record['identity'].is_a?(String)
            next unless watcher_identity(pid.to_i) == record['identity']

            Process.kill('TERM', pid.to_i)
          rescue JSON::ParserError, Errno::ESRCH
            next
          end
        end
        pidfile.delete
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
