module VagrantPlugins
  module VagrantNotifyForwarder
    module Action
      class CheckBootState
        def initialize(app, env)
          @app = app
        end

        def call(env)
          if env[:machine].config.notify_forwarder.enable
            $BOOT_SAVED = env[:machine].state.id == :saved
          end

          @app.call env
        end
      end
    end
  end
end
