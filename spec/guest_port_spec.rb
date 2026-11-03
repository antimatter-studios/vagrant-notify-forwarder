require_relative 'spec_helper'
require_relative 'support/shell_guest'

module GuestSandbox
  CONSTANTS = {
    'SYSTEM_DIRECTORY' => 'usr local libexec', 'RUNTIME_DIRECTORY' => 'run notify-forwarder',
    'SYSTEMD_RUNTIME' => 'run systemd', 'UNIT_PATH' => 'notify-forwarder.service',
    'LEGACY_BINARY' => 'legacy notify-forwarder'
  }.freeze

  def stub_guest_paths(sandbox)
    CONSTANTS.each do |name, relative|
      stub_const("VagrantPlugins::VagrantNotifyForwarder::GuestReceiver::#{name}", sandbox.join(relative).to_s)
    end
  end

  def write_fixture_binary(path)
    path.write("#!/bin/sh\nsleep 30 &\nchild=$!\ntrap 'kill $child; exit 0' TERM\nwait\n")
    path.chmod(0o755)
  end
end

RSpec.describe 'the port a machine keeps' do
  include_context 'middleware env'
  include GuestSandbox

  let(:port_file) { directory.join('notify_forwarder_port') }
  let(:start_host) { VagrantPlugins::VagrantNotifyForwarder::Action::StartHostForwarder.new(app, env) }
  let(:networks) { [] }
  let(:commands) { [] }

  before do
    allow(settings).to receive(:port).and_return(29326)
    allow(vm).to receive(:network) { |_type, options| networks << options }
    allow(vm).to receive(:synced_folders).and_return('project' => { hostpath: directory.to_s, guestpath: '/guest' })
    allow(VagrantPlugins::VagrantNotifyForwarder::Utils).to receive(:ensure_binary_downloaded).and_return(directory.join('binary'))
    allow(start_host).to receive(:start_watcher) { |_env, command| commands << command; nil }
  end

  [:running, :saved, :paused].each do |machine_state|
    it "stays on the recorded port when the machine is #{machine_state}" do
      port_file.write("29325\n")
      allow(state).to receive(:id).and_return(machine_state)

      start_host.call(env)

      expect(networks.map { |network| network[:host] }).to eq([29325])
      expect(networks.map { |network| network[:guest] }).to eq([29325])
      expect(commands.first).to include('127.0.0.1:29325')
    end
  end

  [:stopped, :poweroff, :not_created].each do |machine_state|
    it "takes the configured port and records it when the machine is #{machine_state}" do
      port_file.write("29325\n")
      allow(state).to receive(:id).and_return(machine_state)

      start_host.call(env)

      expect(networks.map { |network| network[:host] }).to eq([29326])
      expect(commands.first).to include('127.0.0.1:29326')
      expect(port_file.read.strip).to eq('29326')
    end
  end

  it 'takes the configured port when nothing was recorded, and records it' do
    start_host.call(env)

    expect(networks.map { |network| network[:host] }).to eq([29326])
    expect(port_file.read.strip).to eq('29326')
  end

  it 'takes the configured port when the record is not a port' do
    port_file.write("not a port\n")

    start_host.call(env)

    expect(networks.map { |network| network[:host] }).to eq([29326])
  end

  it 'gives the guest receiver the recorded port' do
    sandbox = directory.join('guest')
    sandbox.mkpath
    sandbox.join('run systemd').mkpath
    stub_guest_paths(sandbox)
    binary = directory.join('binary')
    write_fixture_binary(binary)
    guest = ShellGuest.new(sandbox)
    allow(machine).to receive(:communicate).and_return(guest)
    port_file.write("29325\n")
    client = VagrantPlugins::VagrantNotifyForwarder::Action::StartClientForwarder.new(app, env)
    allow(client).to receive(:ensure_binary_downloaded).and_return(binary)

    client.call(env)

    expect(sandbox.join('notify-forwarder.service').read).to include('receive -p 29325')
  end
end

RSpec.describe 'a guest reached through a login shell' do
  include_context 'middleware env'
  include GuestSandbox

  let(:sandbox) { directory.join('guest') }
  let(:binary) { directory.join('binary') }
  let(:client) { VagrantPlugins::VagrantNotifyForwarder::Action::StartClientForwarder.new(app, env) }

  # Debian's skeleton file: clear_console fails without a console, and is the last
  # command of its list, so `set -e` left on in the session ends the shell with 1.
  let(:bash_logout) { "if [ \"$SHLVL\" = 1 ]; then\n  [ -x /bin/false ] && /bin/false\nfi\n" }

  before do
    sandbox.mkpath
    stub_guest_paths(sandbox)
    write_fixture_binary(binary)
    allow(client).to receive(:ensure_binary_downloaded).and_return(binary)
  end

  after do
    Dir.glob(File.join(sandbox.to_s, '**', 'receiver.pid')).each do |pidfile|
      begin
        Process.kill('TERM', File.read(pidfile).to_i)
      rescue Errno::ESRCH, ArgumentError
        nil
      end
    end
  end

  def guest_with(sudo:)
    guest = ShellGuest.new(sandbox, sudo: sudo, login_shell: true)
    sandbox.join('home/.bash_logout').write(bash_logout)
    allow(machine).to receive(:communicate).and_return(guest)
    guest
  end

  it 'installs and starts without sudo' do
    guest_with(sudo: false)

    expect { client.call(env) }.not_to raise_error

    expect(sandbox.join('home/.local/libexec/notify-forwarder/notify-forwarder')).to exist
  end

  it 'installs and starts a service with sudo' do
    sandbox.join('run systemd').mkpath
    guest_with(sudo: true)

    expect { client.call(env) }.not_to raise_error

    expect(sandbox.join('notify-forwarder.service')).to exist
    expect(ui).not_to have_received(:error)
  end
end
