require_relative 'spec_helper'
require 'json'
require 'timeout'

RSpec.describe 'a watcher and the vagrant that started it' do
  include_context 'middleware env'

  let(:pidfile) { directory.join('notify_watcher_host_pid') }
  let(:binary) { directory.join('notify-forwarder') }
  let(:report) { directory.join('stdin read status') }
  let(:log) { directory.join('notify_watcher_host.log') }

  before do
    directory.join('id').write('test-machine')
    stub_const('VagrantPlugins::VagrantNotifyForwarder::Action::StartHostForwarder::WATCHER_STARTUP_GRACE', 0.5)
    allow(vm).to receive(:network)
    allow(vm).to receive(:synced_folders).and_return(
      'project' => { hostpath: directory.join('project').to_s, guestpath: '/guest' }
    )
    allow(VagrantPlugins::VagrantNotifyForwarder::Utils).to receive(:ensure_binary_downloaded).and_return(binary)
    # A blocking read proves stdin is still the caller's: it ends only if the watcher was given nothing.
    binary.write(<<~SH)
      #!/bin/sh
      echo 'from standard output'
      echo 'from standard error' >&2
      read -r line
      echo "$?" > '#{report}.tmp'
      mv '#{report}.tmp' '#{report}'
      exec sleep 20
    SH
    binary.chmod(0o755)
  end

  after do
    next unless pidfile.exist?

    pidfile.readlines.each do |line|
      begin
        Process.kill('TERM', line.to_i)
      rescue Errno::ESRCH
        nil
      end
    end
  end

  # Runs the action as `vagrant up` would, in a process whose descriptors are
  # pipes the example holds, and returns once that process has exited.
  def start_with_pipes
    @stdin_reader, @stdin_writer = IO.pipe
    @output_reader, output_writer = IO.pipe
    action = VagrantPlugins::VagrantNotifyForwarder::Action::StartHostForwarder.new(app, env)
    starter = Process.fork do
      @stdin_writer.close
      @output_reader.close
      $stdin.reopen(@stdin_reader)
      $stdout.reopen(output_writer)
      $stderr.reopen(output_writer)
      action.call(env)
      exit!(0)
    end
    @stdin_reader.close
    output_writer.close
    Process.waitpid(starter)
    expect(pidfile).to exist
  end

  after do
    [@stdin_writer, @output_reader].each { |pipe| pipe.close if pipe && !pipe.closed? }
  end

  def wait_for(path, seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    sleep 0.05 until path.exist? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    path.exist?
  end

  it 'lets a reader of the output of vagrant reach end of file while the watcher runs' do
    start_with_pipes

    ended = begin
      Timeout.timeout(3) { @output_reader.read; true }
    rescue Timeout::Error
      false
    end

    expect(ended).to be(true), 'the watcher still holds the output of the process that started it'
  end

  it 'does not read the stdin of the process that started it' do
    start_with_pipes

    expect(wait_for(report, 3)).to be(true), 'the watcher is still reading the stdin it inherited'
  end

  it 'keeps what the watcher prints in a log beside the machine data' do
    start_with_pipes

    expect(wait_for(log, 3)).to be(true), "no log at #{log}"
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.05 until log.read.include?('from standard error') || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    expect(log.read).to include('from standard output').and include('from standard error')
  end

  it 'starts each run with an empty log' do
    log.write("from an earlier run\n")

    start_with_pipes

    expect(log.read).not_to include('from an earlier run')
  end
end
