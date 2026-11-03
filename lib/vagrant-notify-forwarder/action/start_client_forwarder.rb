require 'vagrant-notify-forwarder/utils'
require 'vagrant-notify-forwarder/guest_receiver'

module VagrantPlugins
  module VagrantNotifyForwarder
    module Action
      class StartClientForwarder
        def initialize(app, env)
          @app = app
        end

        def ensure_binary_downloaded(env)
          os = :unsupported
          hardware = :unsupported

          env[:machine].communicate.execute('uname -s') do |type, data|
            env[:ui].info "Notify-forwarder: Detected client operating system: #{data}"
            os = Utils.parse_os_name data if type == :stdout
          end

          env[:machine].communicate.execute('uname -m') do |type, data|
            env[:ui].info "Notify-forwarder: Detected client hardware: #{data}"
            hardware = Utils.parse_hardware_name data if type == :stdout
          end

          env[:ui].error "Notify-forwarder: Unsupported client operating system (detected: #{os})" if os == :unsupported
          env[:ui].error "Notify-forwarder: Unsupported client hardware (detected: #{hardware})" if hardware == :unsupported

          if os != :unsupported and hardware != :unsupported
            Utils.ensure_binary_downloaded env, os, hardware
          end
        end

        def call(env)
          @app.call env

          return unless env[:machine].config.notify_forwarder.enable

          path = ensure_binary_downloaded env
          return unless path

          port = Utils.current_port(env)

          env[:ui].output("Starting notify-forwarder ...")
          return unless GuestReceiver.new(env, path, port).ensure_running

          env[:ui].detail("Notify-forwarder: guest listening for file change notifications on 0.0.0.0:#{port}.")
        end
      end
    end
  end
end
