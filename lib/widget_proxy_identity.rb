require 'openssl'
require 'digest'

# Authenticated server proxy identity for the conversation-creation throttle only.
# Public clients, invalid signatures and replays keep the original IP bucket.
module WidgetProxyIdentity
  CLOCK_SKEW = 120
  MAX_BODY_BYTES = 256 * 1024

  def self.verify(request, cache:, secret: ENV.fetch('CHATWOOT_WIDGET_PROXY_SECRET', ''),
                  websites: ENV.fetch('CHATWOOT_WIDGET_PROXY_WEBSITE_TOKENS', ''), now: Time.now.to_i)
    return if secret.bytesize < 32
    return unless request.post? && request.path == '/api/v1/widget/conversations'

    website = request.params['website_token'].to_s
    return unless websites.split(',').map(&:strip).reject(&:empty?).include?(website)

    identity = request.get_header('HTTP_X_WIDGET_PROXY_IDENTITY').to_s
    timestamp = request.get_header('HTTP_X_WIDGET_PROXY_TIMESTAMP').to_s
    nonce = request.get_header('HTTP_X_WIDGET_PROXY_NONCE').to_s
    signature = request.get_header('HTTP_X_WIDGET_PROXY_SIGNATURE').to_s
    return unless identity.match?(/\A[0-9a-f]{64}\z/) && signature.match?(/\A[0-9a-f]{64}\z/)
    return unless nonce.match?(/\A[0-9a-f]{32}\z/) && timestamp.match?(/\A\d{10}\z/)
    return if (now - timestamp.to_i).abs > CLOCK_SKEW

    body = request.body.read(MAX_BODY_BYTES + 1)
    request.body.rewind
    return if body.bytesize > MAX_BODY_BYTES

    session = request.get_header('HTTP_X_AUTH_TOKEN').to_s
    payload = ['widget-proxy-v1', timestamp, nonce, 'POST', request.path, website,
               identity, Digest::SHA256.hexdigest(session), Digest::SHA256.hexdigest(body)].join("\n")
    expected = OpenSSL::HMAC.hexdigest('SHA256', secret, payload)
    return unless OpenSSL.fixed_length_secure_compare(expected, signature)

    # Atomic SET NX prevents concurrent replay across Rails replicas.
    return unless cache.write("widget-proxy-nonce:#{signature}", true, expires_in: CLOCK_SKEW * 2 + 1, unless_exist: true)

    "proxy:#{website}:#{identity}"
  end
end
