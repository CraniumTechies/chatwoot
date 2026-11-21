# Standalone security/contract checks: no Rails boot, database or shared Redis.
require 'minitest/autorun'
require 'json'
require 'stringio'
require 'rack'
require 'rack/attack'
require 'active_support'
require 'active_support/cache'
require_relative '../lib/widget_proxy_identity'

class WidgetProxyIdentityTest < Minitest::Test
  VECTOR = JSON.parse(File.read(File.join(__dir__, 'fixtures/widget-proxy-v1.json'))).freeze

  def setup
    @cache = ActiveSupport::Cache::MemoryStore.new
  end

  def request(body: VECTOR['body'], headers: VECTOR['headers'], website: VECTOR['website'], path: '/api/v1/widget/conversations', method: 'POST')
    env = Rack::MockRequest.env_for("#{path}?website_token=#{website}", method: method, input: body, 'CONTENT_TYPE' => 'application/json')
    env['HTTP_X_AUTH_TOKEN'] = VECTOR['session']
    headers.each { |name, value| env["HTTP_#{name.upcase.tr('-', '_')}"] = value }
    Rack::Request.new(env)
  end

  def verify(req = request, **options)
    WidgetProxyIdentity.verify(req, cache: @cache, secret: VECTOR['secret'], websites: VECTOR['website'], now: VECTOR['now'], **options)
  end

  def sign_for(subject, nonce)
    identity = OpenSSL::HMAC.hexdigest('SHA256', VECTOR['secret'], "widget-proxy-identity-v1\n#{subject}")
    headers = VECTOR['headers'].merge('X-Widget-Proxy-Identity' => identity, 'X-Widget-Proxy-Nonce' => nonce)
    payload = ['widget-proxy-v1', headers['X-Widget-Proxy-Timestamp'], nonce, 'POST', '/api/v1/widget/conversations',
               VECTOR['website'], identity, Digest::SHA256.hexdigest(VECTOR['session']), Digest::SHA256.hexdigest(VECTOR['body'])].join("\n")
    headers.merge('X-Widget-Proxy-Signature' => OpenSSL::HMAC.hexdigest('SHA256', VECTOR['secret'], payload))
  end

  def test_accepts_node_generated_signature_and_restores_request_body
    req = request
    assert_equal "proxy:#{VECTOR['website']}:#{VECTOR['headers']['X-Widget-Proxy-Identity']}", verify(req)
    assert_equal VECTOR['body'], req.body.read
  end

  def test_replay_does_not_reuse_the_signed_bucket
    refute_nil verify
    assert_nil verify
  end

  def test_tampered_body_session_website_and_identity_fail_closed
    assert_nil verify(request(body: VECTOR['body'] + ' '))
    req = request
    req.env['HTTP_X_AUTH_TOKEN'] = 'different-session'
    assert_nil verify(req)
    assert_nil verify(request(website: 'other-widget'))
    assert_nil verify(request(headers: VECTOR['headers'].merge('X-Widget-Proxy-Identity' => '0' * 64)))
    assert_nil verify(request(headers: {}))
  end

  def test_expired_future_malformed_and_missing_configuration_fail_closed
    assert_nil verify(now: VECTOR['now'] + 121)
    assert_nil verify(now: VECTOR['now'] - 121)
    assert_nil verify(secret: '')
    assert_nil verify(websites: '')
    assert_nil verify(request(headers: VECTOR['headers'].merge('X-Widget-Proxy-Timestamp' => 'bad')))
    assert_nil verify(request(path: '/api/v1/widget/config'))
    assert_nil verify(request(method: 'GET'))
    assert_nil verify(request(body: 'x' * (WidgetProxyIdentity::MAX_BODY_BYTES + 1)))
  end

  def test_atomic_cache_prevents_simultaneous_claim_reuse
    results = 8.times.map { Thread.new { verify } }.map(&:value)
    assert_equal 1, results.compact.length
  end

  def test_rack_throttle_separates_travellers_on_one_ip_and_retains_public_limit
    Rack::Attack.clear_configuration
    Rack::Attack.enabled = true
    Rack::Attack.cache.store = @cache
    now = VECTOR['now']
    Rack::Attack.throttle('test/conversations', limit: 20, period: 43_200) do |req|
      WidgetProxyIdentity.verify(req, cache: Rack::Attack.cache.store, secret: VECTOR['secret'], websites: VECTOR['website'], now: now) || req.ip
    end
    app = Rack::Attack.new(->(_env) { [204, {}, []] })
    %w[traveller-a traveller-b].each do |subject|
      21.times do |index|
        headers = sign_for(subject, Digest::MD5.hexdigest("#{subject}-#{index}"))
        env = request(headers: headers).env.merge('REMOTE_ADDR' => '203.0.113.10')
        assert_equal(index < 20 ? 204 : 429, app.call(env).first)
      end
    end
    21.times do |index|
      env = request(headers: {}).env.merge('REMOTE_ADDR' => '203.0.113.10')
      assert_equal(index < 20 ? 204 : 429, app.call(env).first)
    end
  ensure
    Rack::Attack.clear_configuration
  end
end
