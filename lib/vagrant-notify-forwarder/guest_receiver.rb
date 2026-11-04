require 'digest'
require 'shellwords'

module VagrantPlugins
  module VagrantNotifyForwarder
    # Installs the receiver in the guest and keeps it running. Each step compares
    # first, so running this against a guest that already has it, on a resume or a
    # second `up`, uploads nothing and restarts nothing.
    class GuestReceiver
      SYSTEM_DIRECTORY = '/usr/local/libexec/notify-forwarder'.freeze
      RUNTIME_DIRECTORY = '/run/notify-forwarder'.freeze
      USER_DIRECTORY = '.local/libexec/notify-forwarder'.freeze
      SYSTEMD_RUNTIME = '/run/systemd/system'.freeze
      PROC_DIRECTORY = '/proc'.freeze
      SERVICE = 'notify-forwarder.service'.freeze
      UNIT_PATH = "/etc/systemd/system/#{SERVICE}".freeze
      LEGACY_BINARY = '/tmp/notify-forwarder'.freeze
      BINARY_NAME = 'notify-forwarder'.freeze
      USER_NAME = /\A[a-zA-Z_][a-zA-Z0-9_.-]*\z/.freeze
      NOT_RUNNING = 3
      SYSTEMD_ESCAPES = { '\\' => '\\\\', '"' => '\\"', '$' => '$$', '%' => '%%', "\n" => '\\n', "\r" => '\\r', "\t" => '\\t' }.freeze

      def initialize(env, binary, port)
        @ui = env[:ui]
        @communicate = env[:machine].communicate
        settings = env[:machine].config.notify_forwarder
        @binary = binary
        @port = Integer(port)
        @run_as_root = settings.run_as_root
        @roots = env[:machine].config.vm.synced_folders.each_value.reject { |options| options[:disabled] }
                    .map { |options| options[:guestpath] }.uniq.sort
        @digest = Digest::SHA256.file(binary).hexdigest
      end

      # Returns whether the receiver was left running.
      def ensure_running
        user = guest_user
        unless user.match?(USER_NAME)
          @ui.error "Notify-forwarder: Unusable guest user name #{user.inspect}; the receiver was not started"
          return false
        end

        privileged = @communicate.test('sudo -n true')
        stop_legacy_receiver(privileged)

        if @roots.empty?
          if privileged && systemd?
            @communicate.execute("systemctl disable --now #{SERVICE}", sudo: true, error_check: false)
          elsif privileged
            stop_process(SYSTEM_DIRECTORY, RUNTIME_DIRECTORY, @run_as_root)
          else
            directory = File.join(guest_home, USER_DIRECTORY)
            stop_process(directory, directory, false)
          end
          @ui.error 'Notify-forwarder: No enabled synced folders; the guest receiver was stopped and will not start without roots'
          return false
        end

        if privileged
          changed = install_binary(SYSTEM_DIRECTORY, true)
          if systemd?
            ensure_service(user, changed)
          else
            ensure_process(SYSTEM_DIRECTORY, prepare_runtime_directory(user), changed, @run_as_root)
          end
        else
          if @run_as_root
            @ui.error 'Notify-forwarder: run_as_root is set but passwordless sudo is not available; the receiver runs as the SSH user'
          end
          directory = File.join(guest_home, USER_DIRECTORY)
          changed = install_binary(directory, false)
          ensure_process(directory, directory, changed, false)
        end
      end

      private

      def capture(command)
        output = ''
        @communicate.execute(command) { |type, data| output += data if type == :stdout }
        output
      end

      # A login shell can print before the command does, so the answer is the last line.
      def last_line(command)
        capture(command).lines.last.to_s.strip
      end

      def guest_user
        last_line('id -un')
      end

      def guest_home
        last_line('printf "%s\n" "$HOME"')
      end

      def systemd?
        @communicate.test("test -d #{quote(SYSTEMD_RUNTIME)} && command -v systemctl")
      end

      # In a subshell, so that `set -e` ends with these lines. Vagrant reads them
      # into a login shell and then sends `exit`, so the logout file would run with
      # it still on. Debian's ends in clear_console, which returns 1 without a
      # console, and the shell would then report 1 for a script that succeeded.
      def strictly(*lines)
        ['(', 'set -e', *lines, ')'].join("\n")
      end

      def quote(value)
        Shellwords.escape(value.to_s)
      end

      # An earlier version of this plugin ran the receiver from here, which holds
      # the port the service needs.
      def stop_legacy_receiver(privileged)
        legacy = quote(LEGACY_BINARY)
        @communicate.execute(
          "if [ -e #{legacy} ]; then pkill -f #{quote("^#{Regexp.escape(LEGACY_BINARY)} receive")} || true; rm -f #{legacy}; fi",
          sudo: privileged, error_check: false
        )
      end

      def digest_matches(target)
        %([ "$(sha256sum #{quote(target)} 2>/dev/null | cut -d' ' -f1)" = #{@digest} ])
      end

      # Uploads only into a new private directory. Nothing is ever run from it, so
      # neither a name another guest user chose first nor a noexec /tmp matters.
      # Returns whether the binary was replaced.
      def install_binary(directory, privileged)
        target = File.join(directory, BINARY_NAME)
        return false if @communicate.test(digest_matches(target), sudo: privileged)

        staging = last_line('mktemp -d "${TMPDIR:-/tmp}/nf-receiver.XXXXXX"')
        staged = File.join(staging, BINARY_NAME)
        @communicate.upload(@binary.to_s, staged)
        owner = privileged ? '-o root -g root ' : ''
        directory_mode = privileged ? '755' : '700'
        @communicate.execute(
          strictly(
            "install -d #{owner}-m #{directory_mode} #{quote(directory)}",
            "install #{owner}-m 755 #{quote(staged)} #{quote("#{target}.new")}",
            "mv -f #{quote("#{target}.new")} #{quote(target)}",
            "rm -f #{quote(staged)}",
            "rmdir #{quote(staging)}",
            digest_matches(target)
          ),
          sudo: privileged
        )
        true
      end

      def unit(user)
        <<~UNIT
          [Unit]
          Description=notify-forwarder receiver, managed by vagrant-notify-forwarder
          After=network.target

          [Service]
          ExecStart=#{File.join(SYSTEM_DIRECTORY, BINARY_NAME)} receive -p #{@port} #{@roots.map { |root| systemd_quote(root) }.join(' ')}
          User=#{@run_as_root ? 'root' : user}
          Restart=on-failure
          RestartSec=5
          NoNewPrivileges=true

          [Install]
          WantedBy=multi-user.target
        UNIT
      end

      def systemd_quote(value)
        '"' + value.gsub(/[\\"$%\n\r\t]/, SYSTEMD_ESCAPES) + '"'
      end

      def ensure_service(user, changed)
        status = @communicate.execute(
          strictly(
            "restart=#{changed ? 1 : 0}",
            'wanted=$(mktemp "${TMPDIR:-/tmp}/nf-receiver.XXXXXX")',
            %(printf %s #{quote(unit(user))} > "$wanted"),
            %(if ! cmp -s "$wanted" #{quote(UNIT_PATH)}; then),
            %(  install -o root -g root -m 644 "$wanted" #{quote(UNIT_PATH)}),
            '  systemctl daemon-reload',
            '  restart=1',
            'fi',
            'rm -f "$wanted"',
            *restart_when_a_root_moved,
            "systemctl enable #{SERVICE} >/dev/null 2>&1",
            %(if [ "$restart" = 1 ]; then systemctl restart #{SERVICE}; else systemctl start #{SERVICE}; fi),
            'sleep 1',
            # A receiver that exits cleanly is allowed: `inactive` is not a failure.
            "case \"$(systemctl is-active #{SERVICE} || true)\" in failed|activating) exit #{NOT_RUNNING} ;; esac"
          ),
          sudo: true, error_check: false
        )
        return true if status.zero?

        @ui.error "Notify-forwarder: The guest service did not stay up; see `journalctl -u notify-forwarder` in the guest"
        false
      end

      # The receiver opens each root once, when it starts, and works through those
      # descriptors. On a later boot the service starts before Vagrant mounts anything,
      # so it holds the empty directories under the mounts and never sees a file in
      # them, and `systemctl start` leaves it that way. Nothing in the guest knows
      # about the mounts at boot, so no unit ordering can wait for them.
      #
      # A root that does not resolve is left alone: the receiver would exit for all
      # of its roots, and the service already retries until it comes back.
      def restart_when_a_root_moved
        [
          "main=$(systemctl show -p MainPID #{SERVICE} | cut -d= -f2)",
          'if [ -n "$main" ] && [ "$main" != 0 ]; then',
          "  for root in #{@roots.map { |root| quote(root) }.join(' ')}; do",
          '    [ -e "$root" ] || continue',
          '    held=0',
          "    for descriptor in #{quote(PROC_DIRECTORY)}/\"$main\"/fd/*; do",
          '      if [ "$descriptor" -ef "$root" ]; then held=1; fi',
          '    done',
          '    if [ "$held" = 0 ]; then restart=1; fi',
          '  done',
          'fi'
        ]
      end

      def prepare_runtime_directory(user)
        owner = @run_as_root ? 'root' : user
        @communicate.execute("install -d -o #{owner} -m 755 #{quote(RUNTIME_DIRECTORY)}", sudo: true)
        RUNTIME_DIRECTORY
      end

      # Without systemd nothing restarts the receiver after a reboot until the next
      # `up`. The recorded process is checked by its arguments before it is trusted
      # or signalled, because a PID from before a reboot can belong to anything now.
      def ensure_process(directory, state_directory, changed, as_root)
        target = File.join(directory, BINARY_NAME)
        arguments = [target, 'receive', '-p', @port.to_s, *@roots]
        status = @communicate.execute(
          [
            *process_state(directory, state_directory),
            "expected=#{quote(arguments.join(' '))}",
            "arguments=#{quote(Shellwords.join(arguments))}",
            "argsfile=#{quote(File.join(state_directory, 'receiver.args'))}",
            'case "$running" in',
            '  *"$expected")',
            %(    if [ #{changed ? 1 : 0} = 0 ] && [ "$(cat "$argsfile" 2>/dev/null)" = "$arguments" ]; then exit 0; fi),
            '    kill "$pid" ;;',
            '  *"$target receive -p "*)',
            '    kill "$pid" ;;',
            'esac',
            %((umask 077; printf %s "$arguments" > "$argsfile") || exit #{NOT_RUNNING}),
            %(nohup sh -c 'echo $$ > "$1"; shift; exec "$@"' sh "$pidfile" #{Shellwords.join(arguments)} </dev/null >/dev/null 2>&1 &),
            'child=$!',
            'sleep 1',
            'if ! kill -0 "$child" 2>/dev/null; then',
            "  wait \"$child\" || exit #{NOT_RUNNING}",
            'fi'
          ].join("\n"),
          sudo: as_root, error_check: false
        )
        return true if status.zero?

        @ui.error "Notify-forwarder: The guest receiver exited at once; run #{Shellwords.join(arguments)} in the guest to see why"
        false
      end

      def process_state(directory, state_directory)
        [
          "target=#{quote(File.join(directory, BINARY_NAME))}",
          "pidfile=#{quote(File.join(state_directory, 'receiver.pid'))}",
          'pid=$(cat "$pidfile" 2>/dev/null || true)',
          'running=',
          'if [ -n "$pid" ]; then running=$(ps -ww -o args= -p "$pid" 2>/dev/null || true); fi'
        ]
      end

      def stop_process(directory, state_directory, as_root)
        @communicate.execute(
          [*process_state(directory, state_directory),
           'case "$running" in *"$target receive -p "*) kill "$pid" ;; esac'].join("\n"),
          sudo: as_root, error_check: false
        )
      end
    end
  end
end
