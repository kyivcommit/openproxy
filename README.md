# openproxy

A macOS menu bar app that transparently sits between your coding agents (opencode, pi, aider, …) and `openrouter.ai`. It adds a **provider sort** and **service tier** policy to every chat request, so you configure routing once for all clients instead of in each one.

- **Transparent:** no client configuration changes. Clients keep talking to `https://openrouter.ai`.
- **Sort:** Balanced, Throughput (`:nitro`), Price (`:floor`), Exacto (`:exacto`) — applied by OpenRouter itself via the model-id variant.
- **Service tier:** Auto, Default, Priority, Flex. Flex has retry, timeout and "fall back without flex" settings.
- **Never overrides the client:** if a request already sets `service_tier`, `speed`, `provider.order|sort|only`, a `:variant` or an `@preset/…` model, nothing is changed.
- **Stats** (requests, provider, actual tier, cost) are kept locally in SQLite and shown in the menu.

macOS 14+ only.

## How it works

1. Install adds a local CA (name-constrained to `openrouter.ai`) as a **per-user** trusted root in your **login keychain**, and a line `127.0.0.1 openrouter.ai # openproxy` to `/etc/hosts`.
2. The app listens on `0.0.0.0:443` (no root needed on macOS), accepts loopback peers only, terminates TLS with a leaf for `openrouter.ai`, rewrites the JSON body, and forwards to the real OpenRouter. The upstream address is resolved over DoH so it never loops back to itself.
3. Responses (including SSE) are streamed through without buffering.

## Install

Build: `scripts/build-app.sh` → `build/OpenProxy.app` (ad-hoc signed). Open it, then press **Install** in the menu bar. Install shows **two** authorization prompts:

1. A trust dialog for the CA. Trust is **per-user**: the CA certificate is imported into your **login keychain**, not the System keychain.
2. The admin password prompt for the `/etc/hosts` change and the DNS cache flush.

Dismissing either prompt stops the install and changes nothing: the hosts entry is written only after the CA is verified as trusted, so clients are never routed to a proxy they cannot trust.

If macOS cannot show the trust dialog, trust the CA manually in Keychain Access: **login** keychain → `OpenProxy Local CA` → *Get Info* → *Always Trust*. The certificate lives in the login keychain; the private key stays in `~/Library/Application Support/openproxy/ca.key` (mode 600).

### Node-based clients

Node ignores the macOS keychain. Clients built on Node (for example pi) need the CA once:

```sh
launchctl setenv NODE_EXTRA_CA_CERTS "$HOME/Library/Application Support/openproxy/ca.pem"
```

(or `NODE_OPTIONS='--use-system-ca --use-bundled-ca'`) and a restart of the client. Python with `certifi` (requests, httpx) needs `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` similarly. curl, Bun, opencode, Apple Python and Rust (native roots) work without changes.

## Uninstall / emergency removal

Press **Uninstall** in the menu. It removes the hosts line first (the safety-critical step), then the per-user trust and the certificate from your login keychain, and best-effort sweeps any certificate an older install left in the System keychain.

If the app is gone or crashed, `openrouter.ai` stays unreachable until the hosts line is removed. Do it manually, then remove the trust and the certificate:

```sh
# 1. unblock openrouter.ai
sudo sed -i '' '/# openproxy/d' /etc/hosts && sudo dscacheutil -flushcache

# 2. remove the per-user trust and the certificate from your login keychain
security remove-trusted-cert "$HOME/Library/Application Support/openproxy/ca.pem"
security find-certificate -a -Z -c "OpenProxy Local CA" ~/Library/Keychains/login.keychain-db \
  | awk '/SHA-1 hash:/ { print $NF }' \
  | while read -r hash; do security delete-certificate -Z "$hash" ~/Library/Keychains/login.keychain-db; done

# 3. best-effort: a certificate left in the System keychain by an older install
sudo security find-certificate -a -Z -c "OpenProxy Local CA" /Library/Keychains/System.keychain \
  | awk '/SHA-1 hash:/ { print $NF }' \
  | while read -r hash; do sudo security delete-certificate -Z "$hash" /Library/Keychains/System.keychain; done
```

## Development

```sh
swift build
swift test
scripts/build-app.sh
```

CI (`.github/workflows/ci.yml`) builds, tests and packages on macOS.

## Security notes

- Trust is **per-user**: the CA is trusted and stored only in your login keychain, not system-wide, and the private key is a file (`ca.key`, mode 600) under `~/Library/Application Support/openproxy/`. The CA is name-constrained to `openrouter.ai`, but anyone who can read the key could impersonate that one host to this Mac. Treat the directory as sensitive.
- `Authorization` headers are forwarded to OpenRouter only and never logged or stored.
- While the hosts entry is installed and the app is not running, `openrouter.ai` is unreachable from this Mac.
