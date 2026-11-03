require 'json'
require 'socket'
require 'timeout'

module VagrantPlugins
  module VagrantNotifyForwarder
    class HostWatcher
      def initialize(command:, host:, port:, machine_id_path:, machine_id:, interval: 5, probe_timeout: 2)
        @command = command
        @host = host
        @port = port
        @machine_id_path = machine_id_path
        @machine_id = machine_id
        @interval = interval
        @probe_timeout = probe_timeout
        @stopping = false
      end

      def run
        @reader, @writer = IO.pipe
        signals = {}
        ['TERM', 'INT'].each do |signal|
          signals[signal] = Signal.trap(signal) do
            @stopping = true
            @writer.write_nonblock('.', exception: false)
          end
        end
        signals['CHLD'] = Signal.trap('CHLD') do
          @writer.write_nonblock('.', exception: false)
        end
        @pid = Process.spawn(*@command)
        failures = 0

        loop do
          result = Process.waitpid2(@pid, Process::WNOHANG)
          if result
            @pid = nil
            status = result.last
            return status.exitstatus || 128 + status.termsig
          end

          break if @stopping || !same_machine?

          failures = endpoint_alive? ? 0 : failures + 1
          break if failures >= 3

          IO.select([@reader], nil, nil, @interval)
          @reader.read_nonblock(4096, exception: false)
        end
        0
      rescue SystemCallError => error
        warn "Notify-forwarder: Watcher failed: #{error.message}"
        1
      ensure
        stop_child
        signals.each { |signal, handler| Signal.trap(signal, handler) } if signals
        @reader.close if @reader && !@reader.closed?
        @writer.close if @writer && !@writer.closed?
      end

      def same_machine?
        File.read(@machine_id_path).strip == @machine_id
      rescue SystemCallError
        false
      end

      def endpoint_alive?
        socket = nil
        Timeout.timeout(@probe_timeout) do
          socket = Socket.tcp(@host, @port, connect_timeout: @probe_timeout)
          socket.gets(255).to_s.start_with?('SSH-')
        end
      rescue SystemCallError, IOError, SocketError, Timeout::Error
        false
      ensure
        socket.close if socket
      end

      def stop_child
        return unless @pid
        return if Process.waitpid(@pid, Process::WNOHANG)

        Process.kill('TERM', @pid)
        begin
          Timeout.timeout(2) { Process.waitpid(@pid) }
        rescue Timeout::Error
          Process.kill('KILL', @pid)
          Process.waitpid(@pid)
        end
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = JSON.parse(ARGV.fetch(0)).transform_keys(&:to_sym)
  exit VagrantPlugins::VagrantNotifyForwarder::HostWatcher.new(**options).run
end
