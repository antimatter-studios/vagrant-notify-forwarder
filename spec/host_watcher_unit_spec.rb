require_relative 'spec_helper'
require_relative '../lib/vagrant-notify-forwarder/host_watcher'

RSpec.describe VagrantPlugins::VagrantNotifyForwarder::HostWatcher do
  include_context 'middleware env'

  subject(:watcher) do
    described_class.new(
      command: ['/test/notify-forwarder', 'watch'], host: '127.0.0.1', port: 2222,
      machine_id_path: directory.join('id').to_s, machine_id: 'test-machine'
    )
  end

  it 'recognizes only the original machine ID' do
    expect(watcher.same_machine?).to eq(false)
    directory.join('id').write('test-machine')
    expect(watcher.same_machine?).to eq(true)
    directory.join('id').write('replacement')
    expect(watcher.same_machine?).to eq(false)
  end

  it 'requires an SSH banner rather than just an open port' do
    socket = double('socket', gets: "SSH-2.0-test\r\n", close: nil)
    allow(Socket).to receive(:tcp).with('127.0.0.1', 2222, connect_timeout: 2).and_return(socket)
    expect(watcher.endpoint_alive?).to eq(true)
    allow(socket).to receive(:gets).and_return('not the VM')
    expect(watcher.endpoint_alive?).to eq(false)
    expect(socket).to have_received(:close).twice
  end

  it 'treats a refused connection or a banner timeout as a failed probe' do
    allow(Socket).to receive(:tcp).and_raise(Errno::ECONNREFUSED)
    expect(watcher.endpoint_alive?).to eq(false)
    socket = double('socket', close: nil)
    allow(Socket).to receive(:tcp).and_return(socket)
    allow(socket).to receive(:gets).and_raise(Timeout::Error)
    expect(watcher.endpoint_alive?).to eq(false)
    expect(socket).to have_received(:close)
  end

  context 'while supervising its own child' do
    let(:pid) { 424242 }

    before do
      allow(Process).to receive(:spawn).and_return(pid)
      allow(Process).to receive(:waitpid2).with(pid, Process::WNOHANG).and_return(nil)
      allow(Process).to receive(:waitpid).with(pid, Process::WNOHANG).and_return(nil)
      allow(Process).to receive(:waitpid).with(pid).and_return(pid)
      allow(Process).to receive(:kill)
      allow(IO).to receive(:select)
      allow(watcher).to receive(:same_machine?).and_return(true)
    end

    it 'stops after three failed probes, allowing a transient failure to recover' do
      allow(watcher).to receive(:endpoint_alive?).and_return(false, true, false, false, false)

      expect(watcher.run).to eq(0)

      expect(watcher).to have_received(:endpoint_alive?).exactly(5).times
      expect(Process).to have_received(:kill).with('TERM', pid).once
    end

    it 'stops immediately when its machine disappears' do
      allow(watcher).to receive(:same_machine?).and_return(false)
      expect(watcher).not_to receive(:endpoint_alive?)

      expect(watcher.run).to eq(0)
      expect(Process).to have_received(:kill).with('TERM', pid)
    end

    it 'wakes immediately for a stop signal rather than waiting for the next probe' do
      handlers = {}
      allow(Signal).to receive(:trap) do |signal, _previous = nil, &handler|
        handlers[signal] = handler if handler
        'DEFAULT'
      end
      allow(watcher).to receive(:endpoint_alive?).and_return(true)
      allow(IO).to receive(:select) { handlers.fetch('TERM').call }

      expect(watcher.run).to eq(0)
      expect(watcher).to have_received(:endpoint_alive?).once
      expect(Process).to have_received(:kill).with('TERM', pid)
    end

    it 'wakes to report a child exit during startup' do
      handlers = {}
      allow(Signal).to receive(:trap) do |signal, _previous = nil, &handler|
        handlers[signal] = handler if handler
        'DEFAULT'
      end
      allow(watcher).to receive(:endpoint_alive?).and_return(true)
      status = double('status', exitstatus: 3)
      allow(Process).to receive(:waitpid2).and_return(nil, [pid, status])
      allow(IO).to receive(:select) { handlers.fetch('CHLD').call }

      expect(watcher.run).to eq(3)
      expect(Process).not_to have_received(:kill)
    end

    it 'propagates a child exit without signalling a reaped PID' do
      status = double('status', exitstatus: 3, termsig: nil)
      allow(Process).to receive(:waitpid2).and_return([pid, status])

      expect(watcher.run).to eq(3)
      expect(Process).not_to have_received(:kill)
    end

    it 'propagates a child signal as an unsuccessful exit' do
      status = double('status', exitstatus: nil, termsig: 15)
      allow(Process).to receive(:waitpid2).and_return([pid, status])

      expect(watcher.run).to eq(143)
    end

    it 'reaps an uncooperative child after escalating to KILL' do
      allow(watcher).to receive(:same_machine?).and_return(false)
      allow(Timeout).to receive(:timeout).with(2).and_raise(Timeout::Error)

      expect(watcher.run).to eq(0)
      expect(Process).to have_received(:kill).with('TERM', pid).ordered
      expect(Process).to have_received(:kill).with('KILL', pid).ordered
      expect(Process).to have_received(:waitpid).with(pid)
    end

    it 'does not signal a child already reaped by the nonblocking wait' do
      allow(watcher).to receive(:same_machine?).and_return(false)
      allow(Process).to receive(:waitpid).with(pid, Process::WNOHANG).and_return(pid)

      expect(watcher.run).to eq(0)
      expect(Process).not_to have_received(:kill)
    end

    it 'reports spawn failures and exits unsuccessfully' do
      allow(Process).to receive(:spawn).and_raise(Errno::ENOENT)
      expect(watcher).to receive(:warn).with(/Watcher failed/)

      expect(watcher.run).to eq(1)
    end
  end
end

RSpec.describe 'supervised watcher startup validation' do
  include_context 'middleware env'

  it 'does not launch a watcher without a usable SSH endpoint' do
    allow(machine).to receive(:ssh_info).and_return(nil)
    expect(Process).not_to receive(:spawn)
    action = VagrantPlugins::VagrantNotifyForwarder::Action::StartHostForwarder.new(app, env)

    expect(action.start_watcher(env, ['/bin/sleep', '60'])).to be_nil
    expect(ui).to have_received(:error).with(/without its ID and SSH endpoint/)
  end

  it 'does not launch a watcher without an identified VM' do
    allow(machine).to receive(:id).and_return(nil)
    expect(Process).not_to receive(:spawn)
    action = VagrantPlugins::VagrantNotifyForwarder::Action::StartHostForwarder.new(app, env)

    expect(action.start_watcher(env, ['/bin/sleep', '60'])).to be_nil
    expect(ui).to have_received(:error).with(/without its ID and SSH endpoint/)
  end

  it 'reports a binary that exists but is not executable' do
    binary = directory.join('not-executable')
    binary.write('not executable')
    binary.chmod(0o600)
    expect(Process).not_to receive(:spawn)
    action = VagrantPlugins::VagrantNotifyForwarder::Action::StartHostForwarder.new(app, env)

    expect(action.start_watcher(env, [binary.to_s])).to be_nil
    expect(ui).to have_received(:error).with(/Could not start.*Permission denied/)
  end
end
