# frozen_string_literal: true

module ResponseBank
  CACHEABLE_HEADERS = ["Location", "Content-Type", "ETag", "Content-Encoding", "Last-Modified", "Cache-Control", "Expires", "Link", "Surrogate-Keys", "Cache-Tags", "Speculation-Rules"].freeze
  CACHEABLE_STATUSES = [200, 404, 301].freeze
end
