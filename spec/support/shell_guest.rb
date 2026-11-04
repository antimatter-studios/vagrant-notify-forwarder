require 'fileutils'
require 'open3'

# A communicator that runs what it is given in a real shell, inside a sandbox.
# `sudo`, `systemctl` and `install` are stubs on PATH, so scripts written for a
# guest run unprivileged and leave a record of what they asked for.
class ShellGuest
  attr_reader :root, :uploads, :commands

  def initialize(root, sudo: true, is_active: 'active', login_shell: false, main_pid: 0)
    @root = Pathname.new(root)
    @login_shell = login_shell
    @uploads = []
    @commands = []
    @bin = @root.join('stub-bin')
    @bin.mkpath
    @root.join('home').mkpath
    @root.join('tmp').mkpath
    stub('sudo', sudo ? "while [ \"${1#-}\" != \"$1\" ]; do shift; done\nexec \"$@\"" : "exit 1")
    stub('systemctl', <<~SH)
      echo "$*" >> '#{systemctl_log}'
      if [ "$1" = is-active ]; then echo '#{is_active}'; [ '#{is_active}' = active ]; fi
      if [ "$1" = show ]; then echo 'MainPID=#{main_pid}'; fi
    SH
    # Ownership is what cannot be given without root: the request is recorded.
    stub('install', <<~SH)
      echo "$*" >> '#{install_log}'
      arguments=
      while [ $# -gt 0 ]; do
        case "$1" in
          -o|-g) shift 2; continue ;;
        esac
        arguments="$arguments '$1'"
        shift
      done
      eval "exec #{real('install')} $arguments"
    SH
  end

  def systemctl_log
    @root.join('systemctl.log')
  end

  def install_log
    @root.join('install.log')
  end

  def systemctl_calls
    systemctl_log.exist? ? systemctl_log.readlines(chomp: true) : []
  end

  def execute(command, opts = {})
    @commands << command
    # Not the sandbox: on Linux it is /tmp/notify-forwarder-spec<random>.
    if command.match?(%r{/tmp/notify-forwarder(?!-spec)})
      raise "A command names the fixed path in /tmp: #{command}"
    end

    # Vagrant's SSH communicator feeds a login shell on stdin, then tells it to exit.
    # A profile can reset PATH, so the stubs go back on it first.
    output, error, status =
      if @login_shell
        Open3.capture3(environment.merge('SHLVL' => '0'), 'bash', '-l', stdin_data: "export PATH='#{@bin}':\"$PATH\"\n#{command}\nexit\n")
      else
        Open3.capture3(environment, 'bash', '-c', command)
      end
    yield :stdout, output if block_given? && !output.empty?
    yield :stderr, error if block_given? && !error.empty?
    if opts.fetch(:error_check, true) && !status.success?
      raise "#{command} exited with #{status.exitstatus}: #{error}"
    end

    status.exitstatus
  end

  def sudo(command, opts = {})
    execute(command, opts.merge(sudo: true))
  end

  def test(command, opts = {})
    execute(command, { error_check: false }.merge(opts)).zero?
  end

  def upload(from, to)
    @uploads << to
    raise "An upload left the sandbox: #{to}" unless to.start_with?(@root.to_s)

    FileUtils.cp(from, to)
  end

  private

  def environment
    { 'PATH' => "#{@bin}:#{ENV.fetch('PATH')}", 'HOME' => @root.join('home').to_s, 'TMPDIR' => @root.join('tmp').to_s }
  end

  def stub(name, body)
    path = @bin.join(name)
    path.write("#!/bin/sh\n#{body}\n")
    path.chmod(0o755)
  end

  def real(name)
    ENV.fetch('PATH').split(':').map { |dir| File.join(dir, name) }.find { |path| File.executable?(path) }
  end
end
