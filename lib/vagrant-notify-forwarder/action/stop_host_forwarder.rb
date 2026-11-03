require 'vagrant-notify-forwarder/utils'

module VagrantPlugins
  module VagrantNotifyForwarder
    module Action
      class StopHostForwarder
        def initialize(app, env)
          @app = app
        end

        def call(env)
          Utils.stop_host_watchers(env)

          @app.call env
        end
      end
    end
  end
end
