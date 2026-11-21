# Per-traveller conversation throttling for trusted widget proxies

The widget conversation-creation rule still allows 20 new conversations per 12 hours. Direct/public widget clients keep the original IP bucket. A trusted server can instead submit a signed, opaque traveller identity, giving each authenticated traveller an independent quota even when requests share one server egress IP.

The general request/IP throttle and every other Rack::Attack rule remain unchanged. This is not an IP safelist or a switch that disables widget protection.

## Configuration and rollout

Configure through deployment secrets/configuration:

- `CHATWOOT_WIDGET_PROXY_SECRET`: the same random secret of at least 32 bytes in the Next.js server and the Chatwoot Rails service. This must never be a `NEXT_PUBLIC_` variable. A suitable value can be generated with `openssl rand -base64 32`; store it in the deployment secret manager rather than source control.
- `CHATWOOT_WIDGET_PROXY_WEBSITE_TOKENS`: Chatwoot-only comma-separated allowlist containing the existing tours website token. A signing key alone does not enable trusted proxy identities for other widgets.

Deploy Chatwoot with the verifier and configured secret/allowlist first, then deploy the matching Next.js signer with its secret. Until both sides are configured, requests retain the public IP quota. No Redis rate-limit reset is needed: valid proxy identities use separate keys. Canary and production web servers can roll out independently when configured for the same trusted widget.

The code changes do not provision live secrets or change running services. The separately identified canary request-index prerequisites (`SSR_INTERNAL_API_KEY` in web/Java, `CH_TOKEN_ENC_KEY` in Java) still need provisioning before successful conversations can be saved into My Plans.

## Protocol v1

The Next.js server supplies the traveller ID from authenticated `get_user().subject`; posted subjects and incoming proxy headers are ignored. The identity header is an HMAC of `widget-proxy-identity-v1\n{subject}` and exposes no raw account ID, email or name.

Headers:

- `X-Widget-Proxy-Identity`: 64 lowercase hex characters.
- `X-Widget-Proxy-Timestamp`: Unix seconds.
- `X-Widget-Proxy-Nonce`: 16 random bytes represented as 32 lowercase hex characters, fresh for each attempt.
- `X-Widget-Proxy-Signature`: HMAC-SHA256 hex of the following newline-separated fields, with no final newline:

```text
widget-proxy-v1
{timestamp}
{nonce}
POST
/api/v1/widget/conversations
{website_token}
{identity}
{SHA256 of X-Auth-Token}
{SHA256 of exact UTF-8 request body bytes}
```

Chatwoot accepts identities only on POST `/api/v1/widget/conversations`, for an allowlisted website token, with a valid constant-time signature comparison and timestamp within 120 seconds. Bodies larger than 256 KiB do not qualify. An atomic nonce claim in the existing Rack::Attack cache (`unless_exist: true`, 241-second TTL) prevents concurrent reuse of the trusted claim. The verified bucket is `proxy:{website_token}:{identity}`. Invalid, expired, tampered, replayed or unconfigured claims fall back to the ordinary IP bucket and do not obtain the trusted per-traveller quota. Replayed public requests are still subject to existing widget authentication and IP controls; this protocol does not add conversation-creation idempotency.

The original widget credential, contact scoping and conversation authorization remain necessary. The signature only selects the conversation-creation rate-limit bucket; it grants no agent/account access or participant role. Proxy fields are filtered from Rails parameter/environment logging. Next.js infrastructure logging continues to omit identities, request bodies and credentials.

## Validation

- `bundle exec ruby test/widget_proxy_identity_test.rb`: six tests / 81 assertions pass on Chatwoot's Ruby 3.4.4 runtime. Tests use synthetic fixture data and a process-local memory cache, without Rails boot, database access or shared Redis writes.
- The fixed Node-generated signature in `test/fixtures/widget-proxy-v1.json` verifies in Ruby. Tests cover body rewind, body/session/identity/widget tampering, expiry, missing configuration, replay, concurrent nonce claims, real Rack::Attack middleware quotas for two travellers sharing one IP, and unchanged unsigned IP quotas.
- Next.js `tests/widget-proxy.test.cjs` checks the matching fixed vector, opaque stable traveller identity, nonce freshness, exact-body signing and conversation-only header injection. The request route regression also verifies that the signer receives the server subject rather than a posted subject.
- No real conversation or message was created during these tests. Live behaviour requires the coordinated rollout above.
