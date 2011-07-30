module Goliath
  module Rack
    class AsyncAroundware
      include Goliath::Rack::Validator

      # Called by the framework to create the middleware.
      #
      # Any extra args passed to the use statement are sent to each
      # aroundware_klass as it is created.
      #
      # @example
      #   class Awesomizer2011 < Goliath::Rack::MultiReceiver
      #     def initialize(env, aq)
      #       @awesomeness_quotient = aq
      #       super(env)
      #     end
      #     # ... define pre_process and post_process ...
      #   end
      #
      #   class AwesomeApiWithShortening < Goliath::API
      #     use Goliath::Rack::AsyncAroundware, Awesomizer2011, 3
      #     # ... stuff ...
      #   end
      #
      # @param app [#call] the downstream app
      # @param aroundware_klass a class that quacks like a
      #   Goliath::Rack::ResponseReceiver and an EM::Deferrable
      # @param *args [Array] extra args to pass to the aroundware
      # @return [Goliath::Rack::AsyncAroundware]
      def initialize app, aroundware_klass, *args
        @app = app
        @aroundware_klass = aroundware_klass
        @aroundware_args  = args
      end

      # Coordinates aroundware to process a request.
      #
      # We hook the aroundware in the middle of the async_callback chain:
      # * send the downstream response to the aroundware, whether received directly
      #   from @app.call or via async callback
      # * have the upstream callback chain be invoked when the aroundware completes
      #
      # @param env [Goliath::Env] The goliath environment
      # @return [Array] The [status_code, headers, body] tuple
      def call(env)
        aroundware = new_aroundware(env)

        aroundware_resp = aroundware.pre_process

        hook_into_callback_chain(env, aroundware)

        downstream_resp = @app.call(env)

        # if downstream resp is final, pass it to the aroundware; it will invoke
        # the callback chain at its leisure. Our response is *always* async.
        if final_response?(downstream_resp)
          aroundware.call(downstream_resp)
        end
        return Goliath::Connection::AsyncResponse
      end

      # Put aroundware in the middle of the async_callback chain:
      # * save the old callback chain;
      # * have the downstream callback send results to the aroundware (possibly
      #   completing it)
      # * set the old callback chain to fire when the aroundware completes
      def hook_into_callback_chain(env, aroundware)
        async_callback = env['async.callback']

        # The response from the downstream app is accepted by the aroundware...
        downstream_callback = Proc.new do |resp|
          safely(env){ aroundware.call(resp) }
        end
        env['async.callback'] = downstream_callback

        # .. but the upstream chain is only invoked when the aroundware completes
        invoke_upstream_chain = Proc.new do
          new_resp = safely(env){ aroundware.post_process }
          async_callback.call(new_resp)
        end
        aroundware.callback(&invoke_upstream_chain)
        aroundware.errback(&invoke_upstream_chain)
      end

      def final_response?(resp)
        resp != Goliath::Connection::AsyncResponse
      end

      # Generate a aroundware to process the request, using request env & any args
      # passed to this AsyncAroundware at creation
      #
      # @param env [Goliath::Env] The goliath environment
      # @return [Goliath::Rack::ResponseReceiver] The response_receiver to process this request
      def new_aroundware(env)
        @aroundware_klass.new(env, *@aroundware_args)
      end

    end
  end
end
