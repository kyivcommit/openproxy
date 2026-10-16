# openproxy

A macOS menu bar app that transparently sits between your coding agents (opencode, pi, aider, …) and `openrouter.ai`. It adds a **provider sort** and **service tier** policy to every chat request, so you configure routing once for all clients instead of in each one.

- **Transparent:** no client configuration changes. Clients keep talking to `https://openrouter.ai`.
- **Sort:** Balanced, Throughput (`:nitro`), Price (`:floor`), Exacto (`:exacto`) — applied by OpenRouter itself via the model-id variant.
- **Service tier:** Auto, Default, Priority, Flex. Flex has retry, timeout and "fall back without flex" settings.
- **Never overrides the client:** if a request already sets `service_tier`, `speed`, `provider.order|sort|only`, a `:variant` or an `@preset/…` model, nothing is changed.
- **Stats** (requests, provider, actual tier, cost) are kept locally in SQLite and shown in the menu.

macOS 14+ only.

## How it works

1. Install adds a local CA to the System keychain (name-constrained to `openrouter.ai`) and a line `127.0.0.1 openrouter.ai # openproxy` to `/etc/hosts`.
2. The app listens on `0.0.0.0:443` (no root needed on macOS), accepts loopback peers only, terminates TLS with a leaf for `openrouter.ai`, rewrites the JSON body, and forwards to the real OpenRouter. The upstream address is resolved over DoH so it never loops back to itself.
3. Responses (including SSE) are streamed through without buffering.

## Install

Build: `scripts/build-app.sh` → `build/OpenProxy.app` (ad-hoc signed). Open it, then press **Install** in the menu bar and approve the admin prompt. If macOS refuses to trust the CA from the script, trust `~/Library/Application Support/openproxy/ca.pem` manually in Keychain Access (System keychain → Always Trust).

### Node-based clients

Node ignores the macOS keychain. Clients built on Node (for example pi) need the CA once:

```sh
launchctl setenv NODE_EXTRA_CA_CERTS "$HOME/Library/Application Support/openproxy/ca.pem"
```

(or `NODE_OPTIONS='--use-system-ca --use-bundled-ca'`) and a restart of the client. Python with `certifi` (requests, httpx) needs `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` similarly. curl, Bun, opencode, Apple Python and Rust (native roots) work without changes.

## Uninstall / emergency removal

Press **Uninstall** in the menu. If the app is gone or crashed, `openrouter.ai` stays unreachable until the hosts line is removed:

```sh
sudo sed -i '' '/# openproxy/d' /etc/hosts && sudo dscacheutil -flushcache
sudo security delete-certificate -c "OpenProxy Local CA" /Library/Keychains/System.keychain
```

## Development

```sh
swift build
swift test
scripts/build-app.sh
```

CI (`.github/workflows/ci.yml`) builds, tests and packages on macOS.

## Security notes

- The CA private key is stored as a file (`ca.key`, mode 600) under `~/Library/Application Support/openproxy/`. The CA is name-constrained to `openrouter.ai`, but anyone who can read the key could impersonate that one host to this Mac. Treat the directory as sensitive.
- `Authorization` headers are forwarded to OpenRouter only and never logged or stored.
- While the hosts entry is installed and the app is not running, `openrouter.ai` is unreachable from this Mac.
