require 'rspec'
require 'digest'
require 'fileutils'
require 'pathname'
require 'tmpdir'

$LOAD_PATH.unshift(File.expand_path('support', __dir__))
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'vagrant'
require 'vagrant-notify-forwarder/config'
require 'vagrant-notify-forwarder/utils'
require 'vagrant-notify-forwarder/action/start_host_forwarder'
require 'vagrant-notify-forwarder/action/start_client_forwarder'
require 'vagrant-notify-forwarder/action/stop_host_forwarder'

RSpec.shared_context 'middleware env' do
  let(:settings) { double('settings', enable: true, port: 29324, run_as_root: false, binaries: {}) }
  let(:vm) { double('vm', synced_folders: {}) }
  let(:config) { double('config', notify_forwarder: settings, vm: vm) }
  let(:state) { double('state', id: :running) }
  let(:communicator) { double('communicator') }
  let(:machine) { double('machine', config: config, state: state, data_dir: directory, communicate: communicator, id: 'test-machine', ssh_info: { host: '127.0.0.1', port: 22 }) }
  let(:ui) { double('ui', error: nil, info: nil, detail: nil, output: nil) }
  let(:app) { double('app', call: nil) }
  let(:directory) { Pathname.new(@temporary_directory) }
  let(:env) { { machine: machine, ui: ui, tmp_path: directory, root_path: directory } }

  around do |example|
    Dir.mktmpdir('notify-forwarder-spec') do |path|
      @temporary_directory = path
      example.run
    end
  end
end

RSpec.configure do |config|
  # A port the host happens to be using must not change what an example sees.
  config.before do |example|
    next if example.metadata[:real_ports]

    allow(VagrantPlugins::VagrantNotifyForwarder::Utils).to receive(:udp_port_free?).and_return(true)
  end
  config.order = :random
  config.disable_monkey_patching!
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
end
