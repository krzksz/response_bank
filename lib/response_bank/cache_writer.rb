# frozen_string_literal: true

require 'response_bank/brotli_splice_slot'
require 'msgpack'

module ResponseBank
  class CacheWriter
    Stored = Struct.new(:body, :compressed_body, :metadata, keyword_init: true)

    class << self
      def flatten(body)
        return body if body.is_a?(String)

        result = +""
        body.each { |part| result << part }
        result
      end

      def store(env, status:, headers:, body:, timestamp:, content_encoding:, cacheable_headers:, on_prepared: nil)
        body_compressed = nil
        metadata = nil
        if body && body != ""
          env["cacheable.compression_level"] = ResponseBank.compression_level_for_request(env, headers)
          time = ResponseBank.measure do
            encoded_body = if content_encoding == 'br'
              ResponseBank::BrotliSpliceSlot.encode_body(
                env,
                body,
                headers,
                compression_level: env["cacheable.compression_level"],
              )
            end

            if encoded_body
              body = encoded_body.body
              body_compressed = encoded_body.compressed_body
              metadata = encoded_body.metadata
            else
              body_compressed = ResponseBank.compress(
                body,
                content_encoding,
                compression_level: env["cacheable.compression_level"],
              )
            end
          end
          ResponseBank.log("Compression time: #{time}ms")
          env["cacheable.compression_time"] = time
          headers['Content-Encoding'] = content_encoding
        end

        cached_headers = headers.slice(*cacheable_headers)
        generated_at = timestamp.respond_to?(:call) ? timestamp.call : timestamp
        cache_data = [status, cached_headers, body_compressed, generated_at, env["cacheable.compression_level"]]
        cache_data << metadata if metadata

        stored = Stored.new(body: body, compressed_body: body_compressed, metadata: metadata)
        on_prepared&.call(stored)
        ResponseBank.write_to_cache(env['cacheable.key']) do
          payload = MessagePack.dump(cache_data)
          ResponseBank.write_to_backing_cache_store(
            env,
            env['cacheable.unversioned-key'],
            payload,
            expires_in: env['cacheable.versioned-cache-expiry'],
          )
        end

        stored
      end
    end
  end
end
