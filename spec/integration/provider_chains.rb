require 'pathname'
require 'tmpdir'
require 'rspec/autorun'
require 'vagrant'
require 'vagrant/action/hook'

plugin_root = ENV.fetch('NOTIFY_FORWARDER_ROOT', File.expand_path('../..', __dir__))
$LOAD_PATH.unshift(File.join(plugin_root, 'lib'))
require 'vagrant-notify-forwarder/plugin'
require 'vagrant-notify-forwarder/utils'
require ENV.fetch('VAGRANT_QEMU_ACTION')
require ENV.fetch('VAGRANT_VIRTUALBOX_ACTION')

RSpec.describe 'installed provider action chains' do
  providers = {
    'QEMU' => [VagrantPlugins::QEMU::Action, [:halt, :destroy, :reload]],
    'VirtualBox' => [VagrantPlugins::ProviderVirtualBox::Action, [:halt, :suspend, :destroy, :reload]]
  }

  providers.each do |name, (provider, actions)|
    actions.each do |action|
      it "stops watchers before #{name} #{action}, including a provider failure" do
        builder = provider.public_send("action_#{action}")
        hook = Vagrant::Action::Hook.new
        registrations = VagrantPlugins::VagrantNotifyForwarder::Plugin.components.action_hooks.fetch("machine_action_#{action}".to_sym)
        registrations.each { |register| register.call(hook) }
        hook.apply(builder)
        stop = VagrantPlugins::VagrantNotifyForwarder::Action::StopHostForwarder
        expect(builder.stack.first.middleware).to eq(stop)

        Dir.mktmpdir('provider-chain-', ENV.fetch('TEST_TMPDIR')) do |path|
          machine = Struct.new(:data_dir).new(Pathname.new(path))
          env = { machine: machine, ui: double('ui', error: nil) }
          child = Process.spawn('/bin/sleep', '60')
          begin
            utils = VagrantPlugins::VagrantNotifyForwarder::Utils
            expect(utils.record_host_watcher(env, child)).to eq(true)
            provider_action = lambda do |_environment|
              _, status = Process.waitpid2(child)
              expect(status.termsig).to eq(Signal.list.fetch('TERM'))
              raise 'provider failed'
            end

            expect { stop.new(provider_action, env).call(env) }.to raise_error('provider failed')
            expect(utils.host_pidfile(env)).not_to exist
          ensure
            begin
              if Process.waitpid(child, Process::WNOHANG).nil?
                Process.kill('TERM', child)
                Process.waitpid(child)
              end
            rescue Errno::ECHILD, Errno::ESRCH
              nil
            end
          end
        end
      end
    end
  end
end
