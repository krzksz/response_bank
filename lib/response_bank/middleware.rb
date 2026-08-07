# frozen_string_literal: true
require 'response_bank/brotli_splice_slot'
require 'response_bank/cache_writer'

module ResponseBank
  class Middleware
    # Limit the cached headers
    # TODO: Make this lowercase/case-insentitive as per rfc2616 §4.2
    CACHEABLE_HEADERS = ["Location", "Content-Type", "ETag", "Content-Encoding", "Last-Modified", "Cache-Control", "Expires", "Link", "Surrogate-Keys", "Cache-Tags", "Speculation-Rules"].freeze

    REQUESTED_WITH = "HTTP_X_REQUESTED_WITH"
    ACCEPT = "HTTP_ACCEPT"
    USER_AGENT = "HTTP_USER_AGENT"

    def initialize(app, brotli_splice_injector = nil)
      @app = app
      @brotli_splice_injector = brotli_splice_injector
    end

    def call(env)
      env['cacheable.cache'] = false
      install_brotli_splice_injector(env)

      content_encoding = env['response_bank.server_cache_encoding'] = ResponseBank.check_encoding(env)

      status, headers, body = @app.call(env)

      if env['cacheable.cache']
        if [200, 404, 301, 304].include?(status)
          headers['ETag'] = %{"#{env['cacheable.key']}"}
        end

        if [200, 404, 301].include?(status) && env['cacheable.miss']
          body_string = CacheWriter.flatten(body)
          stored = nil
          begin
            stored = CacheWriter.store(
              env,
              status: status,
              headers: headers,
              body: body_string,
              timestamp: -> { timestamp },
              content_encoding: content_encoding,
              cacheable_headers: CACHEABLE_HEADERS,
              on_prepared: ->(result) { stored = result },
            )

            if stored.compressed_body
              if env['HTTP_ACCEPT_ENCODING'].to_s.include?(content_encoding)
                if content_encoding == 'br'
                  body = [ResponseBank::BrotliSpliceSlot.replace_compressed_secret(env, stored.compressed_body, stored.metadata)]
                else
                  body = [stored.compressed_body]
                end
              else
                # Remove content-encoding header for response with compressed content
                headers.delete('Content-Encoding')
                body = [ResponseBank::BrotliSpliceSlot.replace_plain_body(env, stored.body, stored.metadata)] if stored.metadata
              end
            end
          rescue => exception
            headers.delete('Content-Encoding') if stored&.compressed_body
            ResponseBank.log("Failed to write to cache: #{exception.class} - #{exception.message}")
            if env['response_bank.on_exception']
              begin
                env['response_bank.on_exception'].call(exception)
              rescue => handler_exception
                ResponseBank.log("Exception handler failed: #{handler_exception.class} - #{handler_exception.message}")
              end
            end
          end
        end

        # Add X-Cache header
        miss = env['cacheable.miss']
        x_cache = miss ? 'miss' : 'hit'
        x_cache += ", #{env['cacheable.store']}" unless miss
        headers['X-Cache'] = x_cache
      end

      [status, headers, body]
    end

    private

    def install_brotli_splice_injector(env)
      return unless @brotli_splice_injector
      return if env.key?(ResponseBank::BrotliSpliceSlot::INJECTOR_ENV_KEY)

      injector = if @brotli_splice_injector.respond_to?(:call)
        @brotli_splice_injector.call(env)
      else
        @brotli_splice_injector
      end

      env[ResponseBank::BrotliSpliceSlot::INJECTOR_ENV_KEY] = injector if injector
    end

    def timestamp
      Time.now.to_i
    end

  end
end
