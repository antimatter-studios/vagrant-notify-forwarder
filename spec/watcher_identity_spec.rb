require_relative 'spec_helper'
require 'rbconfig'

RSpec.describe 'watcher ownership' do
  include_context 'middleware env'

  let(:utils) { VagrantPlugins::VagrantNotifyForwarder::Utils }
  let(:pidfile) { directory.join('notify_watcher_host_pid') }
  let(:pid) { 424242 }
  let(:identity) { 'Tue Nov  3 10:00:00 2026 /tmp/notify-forwarder watch /host /guest' }

  it 'records the process start time and complete command line' do
    allow(utils).to receive(:watcher_identity).with(pid).and_return(identity)

    expect(utils.record_host_watcher(env, pid)).to eq(true)
    recorded_pid, metadata = pidfile.read.split(' ', 2)
    expect(recorded_pid).to eq(pid.to_s)
    expect(JSON.parse(metadata)).to eq('identity' => identity)
  end

  it 'signals a watcher only when both start time and command line match' do
    allow(utils).to receive(:watcher_identity).with(pid).and_return(identity)
    utils.record_host_watcher(env, pid)
    expect(Process).to receive(:kill).with('TERM', pid)

    utils.stop_host_watchers(env)

    expect(pidfile).not_to exist
  end

  it 'does not signal a PID whose command line changed' do
    allow(utils).to receive(:watcher_identity).with(pid).and_return(identity)
    utils.record_host_watcher(env, pid)
    allow(utils).to receive(:watcher_identity).with(pid).and_return(identity.sub('notify-forwarder', 'unrelated'))
    expect(Process).not_to receive(:kill)

    utils.stop_host_watchers(env)
  end

  it 'does not record a process that cannot be identified' do
    allow(utils).to receive(:watcher_identity).with(pid).and_return(nil)

    expect(utils.record_host_watcher(env, pid)).to eq(false)
    expect(ui).to have_received(:error).with(/Could not verify watcher/)
    expect(pidfile).not_to exist
  end

  it 'ignores missing processes, invalid JSON, non-object metadata and unsafe PIDs' do
    allow(utils).to receive(:watcher_identity).and_return(nil)
    pidfile.write("#{pid} {}\n#{pid} invalid\n#{pid} []\n-1 {}\n0 {}\n1 {}\n")
    expect(Process).not_to receive(:kill)

    utils.stop_host_watchers(env)

    expect(pidfile).not_to exist
  end

  it 'tolerates a verified watcher exiting just before the signal' do
    allow(utils).to receive(:watcher_identity).with(pid).and_return(identity)
    utils.record_host_watcher(env, pid)
    allow(Process).to receive(:kill).with('TERM', pid).and_raise(Errno::ESRCH)

    expect { utils.stop_host_watchers(env) }.not_to raise_error
    expect(pidfile).not_to exist
  end

  it 'fails closed if process inspection is unavailable' do
    allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

    expect(utils.watcher_identity(pid)).to be_nil
    expect(utils.watcher_identity(-1)).to be_nil
  end

  it 'identifies and stops a real child without signalling another child' do
    watcher = Process.spawn('/bin/sleep', '60')
    unrelated = Process.spawn('/bin/sleep', '60')
    begin
      expect(utils.record_host_watcher(env, watcher)).to eq(true)
      expect(utils.watcher_identity(watcher)).to include('/bin/sleep 60')
      pidfile.open('a') { |file| file.puts("#{unrelated} #{JSON.generate(identity: 'stale identity')}") }

      utils.stop_host_watchers(env)

      _, result = Process.waitpid2(watcher)
      expect(result.termsig).to eq(Signal.list.fetch('TERM'))
      expect(Process.waitpid(unrelated, Process::WNOHANG)).to be_nil
    ensure
      [watcher, unrelated].each do |child|
        begin
          next if Process.waitpid(child, Process::WNOHANG)
          Process.kill('TERM', child)
          Process.waitpid(child)
        rescue Errno::ECHILD, Errno::ESRCH
          nil
        end
      end
    end
  end
end
