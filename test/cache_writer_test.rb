# frozen_string_literal: true
require File.dirname(__FILE__) + "/test_helper"

class ResponseBankCacheWriterTest < Minitest::Test
  def setup
    @original_cache_store = ResponseBank.cache_store
    ResponseBank.cache_store = ActiveSupport::Cache.lookup_store(:memory_store)
    @env = Rack::MockRequest.env_for("http://example.com/index.html")
    @env['response_bank.server_cache_encoding'] = 'br'
    @env['cacheable.key'] = 'etag_value'
    @env['cacheable.unversioned-key'] = 'store_cache_key'
  end

  def teardown
    ResponseBank.cache_store = @original_cache_store
  end

  def test_store_copies_headers_and_adds_cache_representation_headers
    headers = {
      'Content-Type' => 'text/plain',
      'ETag' => 'caller-etag',
      'Content-Encoding' => 'gzip',
    }.freeze

    stored = cache_writer.store(
      @env,
      status: 200,
      headers: headers,
      body: ['Hi'],
      timestamp: 424242,
      content_encoding: 'br',
    )

    assert_equal('Hi', stored.body)
    assert_equal(ResponseBank.compress('Hi', 'br'), stored.compressed_body)
    payload = MessagePack.load(ResponseBank.cache_store.read('store_cache_key', raw: true))
    assert_equal(
      [
        200,
        { 'Content-Type' => 'text/plain', 'ETag' => '"etag_value"', 'Content-Encoding' => 'br' },
        ResponseBank.compress('Hi', 'br'),
        424242,
        7,
      ],
      payload,
    )
  end

  def test_store_writes_an_empty_body_without_content_encoding
    headers = { 'Location' => 'http://shopify.com', 'Content-Encoding' => 'gzip' }.freeze

    stored = cache_writer.store(
      @env,
      status: 301,
      headers: headers,
      body: [],
      timestamp: 424242,
      content_encoding: 'br',
    )

    assert_nil(stored.compressed_body)
    payload = MessagePack.load(ResponseBank.cache_store.read('store_cache_key', raw: true))
    assert_equal(
      [301, { 'Location' => 'http://shopify.com', 'ETag' => '"etag_value"' }, nil, 424242, nil],
      payload,
    )
  end

  def test_store_keeps_only_cacheable_headers
    cache_writer.store(
      @env,
      status: 200,
      headers: {
        'Content-Type' => 'text/plain',
        'Cache-Tags' => 'tag1',
        'Extra-Headers' => 'not-cached',
      },
      body: ['Hi'],
      timestamp: 424242,
      content_encoding: 'br',
    )

    payload = MessagePack.load(ResponseBank.cache_store.read('store_cache_key', raw: true))
    assert_equal(
      {
        'Content-Type' => 'text/plain',
        'ETag' => '"etag_value"',
        'Content-Encoding' => 'br',
        'Cache-Tags' => 'tag1',
      },
      payload[1],
    )
  end

  private

  def cache_writer
    ResponseBank.const_get(:CacheWriter, false)
  end
end
