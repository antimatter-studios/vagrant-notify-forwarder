require_relative 'spec_helper'

RSpec.describe 'watcher lifecycle actions' do
  include_context 'middleware env'

  let(:utils) { VagrantPlugins::VagrantNotifyForwarder::Utils }
  let(:stop) { VagrantPlugins::VagrantNotifyForwarder::Action::StopHostForwarder.new(app, env) }
  let(:start) { VagrantPlugins::VagrantNotifyForwarder::Action::StartHostForwarder.new(app, env) }

  it 'stops watchers before entering the provider action' do
    expect(utils).to receive(:stop_host_watchers).with(env).ordered
    expect(app).to receive(:call).with(env).ordered

    stop.call(env)
  end

  it 'still stops watchers when the provider action raises' do
    expect(utils).to receive(:stop_host_watchers).with(env)
    allow(app).to receive(:call).and_raise('provider failed')

    expect { stop.call(env) }.to raise_error('provider failed')
  end

  it 'cleans existing watchers even after the plugin has been disabled' do
    allow(settings).to receive(:enable).and_return(false)
    expect(utils).to receive(:stop_host_watchers).with(env)

    stop.call(env)
  end

  it 'stops leftovers at the next start before the provider can fail' do
    allow(vm).to receive(:network)
    expect(utils).to receive(:stop_host_watchers).with(env).ordered
    expect(app).to receive(:call).with(env).ordered.and_raise('boot failed')

    expect { start.call(env) }.to raise_error('boot failed')
  end

  it 'cleans leftovers on a disabled start too' do
    allow(settings).to receive(:enable).and_return(false)
    expect(utils).to receive(:stop_host_watchers).with(env)

    start.call(env)
  end
end

RSpec.describe 'provider-independent stop hooks' do
  let(:hooks) { Hash.new { |entries, key| entries[key] = [] } }

  before do
    registry = hooks
    plugin_base = Class.new do
      define_singleton_method(:name) { |_value| }
      define_singleton_method(:description) { |_value| }
      define_singleton_method(:config) { |*_arguments, &_block| }
      define_singleton_method(:action_hook) do |_name, event, &block|
        registry[event] << block
      end
    end
    allow(Vagrant).to receive(:plugin).with('2').and_return(plugin_base)
    stub_const('Vagrant::Action::Builtin::Provision', Class.new)
    stub_const('Vagrant::Action::Builtin::GracefulHalt', Class.new)
    hide_const('VagrantPlugins::VagrantNotifyForwarder::Plugin')
    load File.expand_path('../lib/vagrant-notify-forwarder/plugin.rb', __dir__)
  end

  [:halt, :suspend, :destroy, :reload].each do |action|
    it "prepends cleanup to #{action} without requiring a provider middleware" do
      hook = double('hook', before: nil, after: nil, prepend: nil)

      hooks.fetch("machine_action_#{action}".to_sym).each { |register| register.call(hook) }

      expect(hook).to have_received(:prepend).with(
        VagrantPlugins::VagrantNotifyForwarder::Action::StopHostForwarder
      )
      expect(hook).not_to have_received(:before).with(
        Vagrant::Action::Builtin::GracefulHalt, anything
      )
    end
  end
end
