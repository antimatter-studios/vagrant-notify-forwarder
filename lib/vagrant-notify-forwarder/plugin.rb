require 'vagrant'

module VagrantPlugins
  module VagrantNotifyForwarder
    class Plugin < Vagrant.plugin('2')
      name 'vagrant-notify-forwarder'
      description 'Wrapper around the notify-forwarder file system event forwarder'

      # Boot and resume: start host watcher, then start guest receiver.
      # All hooks use provider-agnostic Vagrant::Action::Builtin classes so this
      # works with VirtualBox, VMware, libvirt, QEMU, etc.
      register_boot_hooks = lambda do |hook|
        require_relative 'action/start_host_forwarder'
        require_relative 'action/start_client_forwarder'

        hook.after Vagrant::Action::Builtin::Provision,
                   VagrantPlugins::VagrantNotifyForwarder::Action::StartHostForwarder
        hook.after VagrantPlugins::VagrantNotifyForwarder::Action::StartHostForwarder,
                   VagrantPlugins::VagrantNotifyForwarder::Action::StartClientForwarder
      end

      register_stop_hooks = lambda do |hook|
        require_relative 'action/stop_host_forwarder'

        hook.prepend VagrantPlugins::VagrantNotifyForwarder::Action::StopHostForwarder
      end

      register_resume_hooks = lambda do |hook|
        require_relative 'action/start_host_forwarder'
        require_relative 'action/start_client_forwarder'

        hook.after Vagrant::Action::Builtin::Provision,
                   VagrantPlugins::VagrantNotifyForwarder::Action::StartHostForwarder
        hook.after VagrantPlugins::VagrantNotifyForwarder::Action::StartHostForwarder,
                   VagrantPlugins::VagrantNotifyForwarder::Action::StartClientForwarder
      end

      config(:notify_forwarder) do
        require_relative 'config'
        Config
      end

      action_hook :start_notify_forwarder, :machine_action_up, &register_boot_hooks
      action_hook :start_notify_forwarder, :machine_action_reload, &register_boot_hooks

      action_hook :stop_notify_forwarder, :machine_action_suspend, &register_stop_hooks
      action_hook :start_notify_forwarder, :machine_action_resume, &register_resume_hooks

      action_hook :stop_notify_forwarder, :machine_action_halt, &register_stop_hooks
      action_hook :stop_notify_forwarder, :machine_action_reload, &register_stop_hooks

      action_hook :stop_notify_forwarder, :machine_action_destroy, &register_stop_hooks

    end
  end
end
