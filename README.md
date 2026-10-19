# openproxy

A macOS menu bar app that transparently sits between your coding agents (opencode, pi, aider, …) and `openrouter.ai`. It adds a **provider sort** and **service tier** policy to every chat request, so you configure routing once for all clients instead of in each one.

- **Transparent for keychain-based clients:** curl, Apple Python and opencode need no configuration changes; Rust is expected to (not re-verified with per-user trust). Node, Bun and Homebrew Python need the CA supplied once — see [Client trust](#client-trust).
- **Sort:** Balanced, Throughput (`:nitro`), Price (`:floor`), Exacto (`:exacto`) — applied by OpenRouter itself via the model-id variant — and **Smart price**, which ranks the endpoints here and pins them with `provider.order` (see [Smart price](#smart-price)).
- **Service tier:** Auto, Default, Priority, Flex. Flex has retry, timeout and "fall back without flex" settings.
- **Never overrides the client:** if a request already sets `service_tier`, `speed`, `provider.order|sort|only` (or, for Smart price, `provider.quantizations`), a `:variant` or an `@preset/…` model, nothing is changed.
- **Stats** (requests, provider, actual tier, the Smart-price endpoint chosen, cost) are kept locally in SQLite and shown in the menu.

macOS 14+ only.

## How it works

1. First launch sets up a local CA (name-constrained to `openrouter.ai`) as a **per-user** trusted root in your **login keychain**. While the app runs, a line `127.0.0.1 openrouter.ai # openproxy` is in `/etc/hosts`; quitting the app removes it.
2. The app listens on `0.0.0.0:443` (no root needed on macOS), accepts loopback peers only, terminates TLS with a leaf for `openrouter.ai`, rewrites the JSON body, and forwards to the real OpenRouter. The upstream address is resolved over DoH so it never loops back to itself.
3. Responses (including SSE) are streamed through without buffering.

## Smart price

OpenRouter's own `:floor` (the **Price** sort) ranks endpoints by **input** price alone and does not filter quantization. For `deepseek/deepseek-v4.1-flash` it picks an fp4 endpoint even though an fp8 one is cheaper on output. **Smart price** ranks the model's endpoints itself and pins the winner with `provider.order`:

1. Fetch the model's endpoint list (`GET /api/v1/models/{id}/endpoints`, no key needed). It is cached per model for **Refresh endpoint data every N min** (1–60, default 10): a cached list is served at once and refreshed in the background when it is older than the TTL.
2. Keep only endpoints that are **unquantized**: `quantization` must be `unknown` or absent. Anything with a declared precision (`fp4`, `mxfp4`, `nvfp4`, `int4`, `fp6`, `int8`, `fp8`, `fp16`, `bf16`, `fp32`, …) is dropped. Also drop endpoints whose `uptime_last_30m` is below 90.
3. Group by the Tier setting: Auto/Default → standard endpoints; Priority → priority first, then standard; Flex → flex endpoints only.
4. Sort by `max(pricing.prompt, pricing.completion)` in USD per million tokens — the more expensive side decides. Ties break by **speed**: higher `throughput_last_30m` (tokens/s, nil last), then lower `latency_last_30m`, then higher `uptime_last_1d` (falling back to `uptime_last_30m`), then lower `prompt + completion`, then name.
5. Inject `provider: {order: [<top 5 endpoint tags>], quantizations: ["unknown"], allow_fallbacks: true}` and add **no** model suffix. The previously chosen endpoint keeps its place unless a new one is at least 10% cheaper, which keeps prompt caching warm.
6. Skip the whole thing when the client sent `provider.order|sort|only|quantizations` or the model id has a `:variant`/`@preset/`. On any failure the request is forwarded unchanged, and the reason (`no_endpoint_data` or `no_eligible_endpoint`) is recorded in the stats.

The `order` values are the endpoint tags from the `/endpoints` response (`provider[/variant][/region][/tier]`, e.g. `deepinfra/fp8/flex`), which is exactly what OpenRouter's provider `order` accepts. The endpoint Smart price chose is recorded with each request in the stats.

Aliases (`~vendor/name-latest`) work too: the `~` id names no model, so the ranking uses the concrete model the previous response reported in its `model` field. That mapping is kept in memory only (last 64 aliases, never written to disk), so the first request after launch goes unranked and records `alias_unresolved`; every later request for the same alias is ranked and still sends the alias in the body.

Speed needs the client's key. `throughput_last_30m` and `latency_last_30m` come back only when the `/endpoints` call carries an API key, so the catalog sends the most recent client `Authorization` header it has seen. That value is kept **in memory only** — never logged and never written to disk — and is used solely for the openrouter.ai endpoints request. A model first cached without a key is refetched in the background once a key appears, at most once per TTL window; with no key the speed criteria are skipped and the tie-break falls straight to uptime.

## First launch

Left click the menu bar icon for a native menu with **Sort**, **Tier** (which holds the Flex settings while that tier is selected), **Refresh** (endpoint data interval), **Stats** and **Status**; right click (or control-click) for **Enabled**, **Start at login**, **Uninstall OpenProxy…** and **Quit OpenProxy**.

Build: `scripts/build-app.sh` → `build/OpenProxy.app` (ad-hoc signed). Open it. On the first launch a welcome dialog explains what will be set up; **Continue** does everything, there is no Install button:

1. A trust dialog for the CA (Touch ID or password). Trust is **per-user**: the CA certificate is imported into your **login keychain**, not the System keychain. It is skipped when the CA is already trusted.
2. A small root helper (`dev.openproxy.helper`, a launch daemon registered with `SMAppService`) edits `/etc/hosts` without a password prompt. macOS asks you once to approve it in **System Settings → Login Items**; the app opens that pane and continues by itself when approval arrives. The helper has exactly one operation: add or remove the managed hosts line. Uninstall keeps it registered but idle; it is dropped when you delete the app, or by switching OpenProxy off in **System Settings → Login Items**.
3. Autostart is the app's login item (`SMAppService.mainApp`), and the approved root helper removes the managed `/etc/hosts` line if the app exits or crashes, so clients are not left routed to a dead proxy; `NODE_EXTRA_CA_CERTS` is set for processes started afterwards (see [Client trust](#client-trust)); if the last step fails it only shows a warning.

The hosts entry is written only after the CA is verified as trusted, the helper and autostart are enabled, so clients are never routed to a proxy that will not come back after login. **Not now** in the welcome dialog skips only the system setup (CA trust, root helper, hosts entry, autostart, Node env): the app still creates its local data (the CA files and the stats database) and runs the proxy, which stays idle because nothing routes to it. The welcome dialog asks again on the next launch. When a step stops waiting for approval or fails, the menu shows **Retry setup**, which runs the setup again without the welcome dialog.

Later launches add the hosts line back silently. **Quit** removes it again without any prompt when the helper works; if the helper cannot be used, Quit falls back to a confirmation dialog so you are never left routed to a dead proxy.

If macOS cannot show the trust dialog, trust the CA manually in Keychain Access: **login** keychain → `OpenProxy Local CA` → *Get Info* → *Always Trust*. The certificate lives in the login keychain; the private key stays in `~/Library/Application Support/openproxy/ca.key` (mode 600).

Notes for ad-hoc builds: macOS ties the helper approval to its code signature, so after **rebuilding** the app the helper may stop answering ("The OpenProxy helper is not responding"). Switch OpenProxy off and on again in Login Items (with Touch ID) to refresh it. A signed release build does not have this churn, and it also pins the Team ID in the helper's code-signing requirement (ad-hoc builds can only pin the bundle identifier).

### Client trust

Whether a client trusts the proxy CA without changes depends on which trust store it uses. Measured against the running app (2026-10-16); `<ca.pem>` is `~/Library/Application Support/openproxy/ca.pem`:

| Client | Works with no changes? | What it needs |
|---|---|---|
| `curl` (`/usr/bin/curl`) | yes | uses Secure Transport, so it sees the keychain-trusted CA |
| Apple Python 3 | yes | uses the system keychain (measured with per-user trust) |
| Rust (native roots) | expected | uses the native trust store; expected to work, but not re-verified with the per-user CA |
| `opencode` (started fresh) | yes | sees the keychain-trusted CA |
| Node (`node`, `pi`) | no | `NODE_EXTRA_CA_CERTS=<ca.pem>`, or `NODE_OPTIONS='--use-system-ca --use-bundled-ca'` |
| Bun | no | `bun --use-system-ca` (or `BUN_OPTIONS=--use-system-ca`); `NODE_EXTRA_CA_CERTS` also works |
| Homebrew Python 3, `requests`, `httpx` | no | `SSL_CERT_FILE=<ca.pem>` or `REQUESTS_CA_BUNDLE=<ca.pem>` |

Measured on macOS 27 with per-user trust: curl, Apple Python 3 and opencode (fresh process) pass; Bun needs `--use-system-ca`; Node/`pi` need `NODE_EXTRA_CA_CERTS`; Homebrew Python needs `SSL_CERT_FILE`. Rust is listed as expected only — it was measured in the earlier spike with the CA in the System keychain, not with the current per-user trust.

In Node, `--use-system-ca` alone does not pick up the login-keychain CA; use `NODE_EXTRA_CA_CERTS` or the `--use-system-ca --use-bundled-ca` pair. Python 3.13+ strict verification now works with this CA because it carries the Subject and Authority Key Identifier extensions.

**First launch** already sets `NODE_EXTRA_CA_CERTS` to this app's `ca.pem` (`launchctl setenv`), so Node clients started afterwards trust the CA with no shell configuration. The value only reaches processes started afterwards: **restart your terminal app and any running agents** so they pick it up. If a client is launched by a path that does not inherit the launchd environment, set the variable yourself:

```sh
export NODE_EXTRA_CA_CERTS="$HOME/Library/Application Support/openproxy/ca.pem"
```

The app never edits a shell profile.

### Long-running clients

A process that started before setup keeps the trust store it loaded at startup, so it must be restarted to pick up the new CA. For `opencode`:

```sh
opencode service restart
```

Restart any other long-running client the same way.

## Uninstall / emergency removal

macOS has no hook for deleting an app, so use **Uninstall OpenProxy…** from the right-click menu *before* you delete it. After a confirmation it removes the hosts line first (the safety-critical step), then autostart, the per-user trust and the certificate from your login keychain, the `NODE_EXTRA_CA_CERTS` variable (only when it still points at our `ca.pem`), best-effort any certificate an older install left in the System keychain, and finally all OpenProxy data (`~/Library/Application Support/openproxy`), then quits. A normal per-user uninstall shows only the system trust-settings authorization that removing the login-keychain trust needs; the admin password prompt appears only when an older install left a certificate or admin-domain trust in the System keychain. The root helper stays registered but idle — it only edits the one hosts line and watches the app's session — and is dropped when you delete the app, or by switching OpenProxy off in **System Settings → Login Items**.

If the helper is unavailable (not approved, or the app was removed without uninstalling), the managed hosts line can outlive the app. Remove it manually, then remove the trust and the certificate:

```sh
# 1. unblock openrouter.ai
sudo sed -i '' '/# openproxy/d' /etc/hosts && sudo dscacheutil -flushcache

# 2. drop the CA from the launchd environment (setup set it)
launchctl getenv NODE_EXTRA_CA_CERTS | grep -Fq "$HOME/Library/Application Support/openproxy/ca.pem" \
  && launchctl unsetenv NODE_EXTRA_CA_CERTS

# 3. remove the per-user trust and the certificate from your login keychain
security remove-trusted-cert "$HOME/Library/Application Support/openproxy/ca.pem"
security find-certificate -a -Z -c "OpenProxy Local CA" ~/Library/Keychains/login.keychain-db \
  | awk '/SHA-1 hash:/ { print $NF }' \
  | while read -r hash; do security delete-certificate -Z "$hash" ~/Library/Keychains/login.keychain-db; done

# 4. best-effort: a certificate left in the System keychain by an older install
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
- While the hosts entry is present and the app is not running, `openrouter.ai` is unreachable from this Mac. The helper removes the line when the app exits or crashes, so this window is short.
- The root helper accepts connections only from a process signed with the OpenProxy app's own signing identifier (and, for a signed release build, the same Team ID) and can only add or remove the one managed hosts line. With ad-hoc signing that identifier is not a strong secret: any local process can sign itself with it, so the worst case is toggling that single hosts line.

## License

MIT, see [LICENSE](LICENSE).
