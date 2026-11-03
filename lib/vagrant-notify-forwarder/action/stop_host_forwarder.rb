require 'vagrant-notify-forwarder/utils'

module VagrantPlugins
  module VagrantNotifyForwarder
    module Action
      class StopHostForwarder
        def initialize(app, env)
          @app = app
        end

        def call(env)
          @app.call env

          return unless env[:machine].config.notify_forwarder.enable

          Utils.stop_host_watchers(env)
        end
      end
    end
  end
end
