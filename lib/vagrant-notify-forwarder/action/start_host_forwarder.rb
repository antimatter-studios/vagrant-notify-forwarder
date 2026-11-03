require 'vagrant-notify-forwarder/utils'
require 'rbconfig'

module VagrantPlugins
  module VagrantNotifyForwarder
    module Action
      class StartHostForwarder
        # A watcher still running this many seconds after the last one started is
        # taken to have started. macOS checks an executable on its first run: a new
        # one that exits at once took 0.3 seconds on an idle host and up to 2.3 with
        # twelve starting together.
        WATCHER_STARTUP_GRACE = 3

        def initialize(app, env)
          @app = app
        end

        def ensure_binary_downloaded(env)
          os = Utils.parse_os_name `uname -s`
          hardware = Utils.parse_hardware_name `uname -m`

          env[:ui].error "Notify-forwarder: Unsupported host operating system (detected: #{os})" if os == :unsupported
          env[:ui].error "Notify-forwarder: Unsupported host hardware (detected: #{hardware})" if hardware == :unsupported

          if os != :unsupported and hardware != :unsupported
            Utils.ensure_binary_downloaded env, os, hardware
          end
        end

        # Takes an argument list so no shell ever reads a path. Returns the pid and
        # the thread that reaps it, or nil if the watcher could not be started.
        def start_watcher(env, command)
          unless File.executable?(command.first)
            error = File.exist?(command.first) ? Errno::EACCES : Errno::ENOENT
            raise error, command.first
          end

          machine = env.fetch(:machine)
          ssh = machine.ssh_info
          unless ssh && ssh[:host] && ssh[:port] && machine.id
            env[:ui].error 'Notify-forwarder: Cannot watch a machine without its ID and SSH endpoint'
            return
          end

          options = {
            command: command, host: ssh[:host], port: ssh[:port],
            machine_id_path: machine.data_dir.join('id').to_s, machine_id: machine.id
          }
          supervisor = File.expand_path('../host_watcher.rb', __dir__)
          # A watcher outlives this process, so it takes none of its descriptors:
          # whoever reads the output of `vagrant up` must be able to reach its end.
          log = Utils.host_watcher_log(env).to_s
          pid = Process.spawn(RbConfig.ruby, supervisor, JSON.generate(options), in: File::NULL, out: [log, 'a'], err: [:child, :out])
          [pid, Process.detach(pid)]
        rescue SystemCallError => e
          env[:ui].error "Notify-forwarder: Could not start '#{command.join(' ')}': #{e.message}"
          nil
        end

        # Records a watcher that is still running at the deadline, and reports one
        # that is not. Returns whether it is running.
        def confirm_watcher(env, command, pid, reaper, deadline)
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)

          if reaper.join([remaining, 0].max)
            env[:ui].error "Notify-forwarder: '#{command.join(' ')}' exited at once (#{reaper.value})"
            return false
          end

          Utils.record_host_watcher(env, pid, reaper)
        end

        # Host and guest path pairs. The binary aborts on a path it cannot resolve,
        # so one missing folder left in would end the watcher for all of them.
        def watched_folders(env)
          env[:machine].config.vm.synced_folders.each_value.with_object([]) do |options, folders|
            next if options[:disabled]

            hostpath = File.expand_path(options[:hostpath], env[:root_path])
            if File.exist?(hostpath)
              folders << [hostpath, options[:guestpath]]
            else
              env[:ui].error "Notify-forwarder: Not watching '#{hostpath}': it does not exist"
            end
          end
        end

        def call(env)
          Utils.stop_host_watchers(env)

          if env[:machine].config.notify_forwarder.enable
            port = Utils.choose_port(env)
            env[:machine].config.vm.network :forwarded_port, host: port, guest: port, host_ip: '127.0.0.1', protocol: 'udp', auto_correct: true
          end

          begin
            @app.call env
          ensure
            Utils.release_port_claim(env)
          end

          if env[:machine].config.notify_forwarder.enable
            path = ensure_binary_downloaded env
            return unless path

            folders = watched_folders(env)
            return if folders.empty?

            Utils.host_watcher_log(env).write('')

            command = [path.to_s, 'watch', '-c', "127.0.0.1:#{port}", *folders.flatten]
            pid, reaper = start_watcher env, command
            return unless pid

            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WATCHER_STARTUP_GRACE
            return unless confirm_watcher env, command, pid, reaper, deadline

            env[:ui].detail("Notify-forwarder: host sending file change notifications to 127.0.0.1:#{port}")
            folders.each do |hostpath, guestpath|
              env[:ui].detail("Notify-forwarder: host forwarding notifications on #{hostpath} to #{guestpath}")
            end
          end
        end
      end
    end
  end
end
