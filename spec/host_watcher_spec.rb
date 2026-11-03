require_relative 'spec_helper'

RSpec.describe VagrantPlugins::VagrantNotifyForwarder::Action::StartHostForwarder do
  include_context 'middleware env'

  subject(:middleware) { described_class.new(app, env) }

  let(:pidfile) { directory.join('notify_watcher_host_pid') }
  let(:recorded) { directory.join('recorded arguments') }
  let(:guestpath) { '/guest dir' }
  let(:hostpath) { directory.join('project dir').to_s }
  let(:binary) { directory.join('notify-forwarder') }

  # Records its arguments one per line, then stays alive like a real watcher.
  let(:recording_watcher) do
    <<~SH
      for argument in "$@"; do printf '%s\\n' "$argument"; done > '#{recorded}.tmp'
      mv '#{recorded}.tmp' '#{recorded}'
      exec sleep 20
    SH
  end

  # A running watcher only has to outlast this. An exiting one is reaped as soon
  # as it exits, so the examples that need one set a long grace and never race it.
  def grace(seconds)
    stub_const("#{described_class}::WATCHER_STARTUP_GRACE", seconds)
  end

  before do
    directory.join('id').write('test-machine')
    FileUtils.mkpath(hostpath)
    grace(0.05)
    allow(vm).to receive(:network)
    allow(vm).to receive(:synced_folders).and_return(
      'project' => { hostpath: hostpath, guestpath: guestpath }
    )
    allow(VagrantPlugins::VagrantNotifyForwarder::Utils).to receive(:ensure_binary_downloaded).and_return(binary)
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

  def install_watcher(body, path = binary)
    path.dirname.mkpath
    path.write("#!/bin/sh\n#{body}")
    path.chmod(0o755)
  end

  def recorded_arguments
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    sleep 0.05 until recorded.exist? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    recorded.exist? ? recorded.readlines(chomp: true) : nil
  end

  def expect_arguments_kept_whole
    expect(recorded_arguments).to eq(['watch', '-c', '127.0.0.1:29324', hostpath, guestpath])
  end

  it 'passes a host path with a space as one argument' do
    install_watcher(recording_watcher)

    middleware.call(env)

    expect_arguments_kept_whole
    expect(ui).not_to have_received(:error)
    expect(ui).to have_received(:detail).with(/forwarding notifications on #{Regexp.escape(hostpath)} to/)
  end

  it 'runs a binary whose own path has a space' do
    spaced_binary = directory.join('tool dir').join('notify-forwarder')
    install_watcher(recording_watcher, spaced_binary)
    allow(VagrantPlugins::VagrantNotifyForwarder::Utils).to receive(:ensure_binary_downloaded).and_return(spaced_binary)

    middleware.call(env)

    expect_arguments_kept_whole
    expect(ui).not_to have_received(:error)
  end

  context 'with shell metacharacters in a host path' do
    let(:marker) { directory.join('marker') }
    let(:hostpath) { "#{directory}/project; touch #{marker}; echo " }

    it 'does not execute them' do
      install_watcher(recording_watcher)

      middleware.call(env)

      expect_arguments_kept_whole
      expect(marker).not_to exist
    end
  end

  it 'records the pid of a watcher that keeps running' do
    install_watcher(recording_watcher)

    middleware.call(env)

    recorded_arguments
    pid = pidfile.read.to_i
    expect(pid).to be > 0
    expect(Process.kill(0, pid)).to eq(1)
  end

  it 'reports a watcher that exits at once and does not claim success' do
    grace(60)
    install_watcher('exit 3')

    middleware.call(env)

    expect(ui).to have_received(:error).with(/#{Regexp.escape(hostpath)}.*exited at once.*exit 3/)
    expect(ui).not_to have_received(:detail).with(/forwarding notifications/)
    expect(pidfile).not_to exist
  end

  context 'with several folders' do
    let(:other) { directory.join('other dir').to_s }
    let(:missing) { directory.join('missing').to_s }

    def folders(*extra)
      allow(vm).to receive(:synced_folders).and_return(
        { 'project' => { hostpath: hostpath, guestpath: guestpath } }.merge(*extra)
      )
    end

    before { FileUtils.mkpath(other) }

    it 'starts one watcher carrying every enabled folder' do
      folders('other' => { hostpath: other, guestpath: '/other dir' },
              'off' => { hostpath: other, guestpath: '/off', disabled: true })
      install_watcher(recording_watcher)

      middleware.call(env)

      expect(recorded_arguments).to eq(['watch', '-c', '127.0.0.1:29324', hostpath, guestpath, other, '/other dir'])
      expect(pidfile.readlines.length).to eq(1)
      expect(ui).to have_received(:detail).with(/forwarding notifications on #{Regexp.escape(hostpath)} to/)
      expect(ui).to have_received(:detail).with(/forwarding notifications on #{Regexp.escape(other)} to/)
      expect(ui).not_to have_received(:detail).with(%r{to /off})
    end

    # The binary aborts on a path it cannot resolve, which would end every folder.
    it 'leaves out a host path that does not exist, names it, and watches the rest' do
      folders('missing' => { hostpath: missing, guestpath: '/missing' })
      install_watcher(recording_watcher)

      middleware.call(env)

      expect_arguments_kept_whole
      expect(ui).to have_received(:error).once.with(/#{Regexp.escape(missing)}/)
      expect(ui).not_to have_received(:detail).with(/forwarding notifications on #{Regexp.escape(missing)} to/)
    end

    it 'claims no folder when the watcher exits at once' do
      folders('other' => { hostpath: other, guestpath: '/other dir' })
      grace(60)
      install_watcher('exit 3')

      middleware.call(env)

      expect(ui).to have_received(:error).once.with(/exited at once.*exit 3/)
      expect(ui).not_to have_received(:detail).with(/forwarding notifications/)
    end

    it 'starts no watcher when no folder is left to watch' do
      allow(vm).to receive(:synced_folders).and_return('missing' => { hostpath: missing, guestpath: '/missing' })
      install_watcher(recording_watcher)

      middleware.call(env)

      expect(pidfile).not_to exist
      expect(recorded).not_to exist
    end
  end

  it 'reports a watcher that cannot be started and still finishes the action' do
    expect { middleware.call(env) }.not_to raise_error

    expect(ui).to have_received(:error).with(/could not start.*#{Regexp.escape(binary.to_s)}/i)
    expect(ui).not_to have_received(:detail).with(/forwarding notifications/)
    expect(pidfile).not_to exist
  end
end
