# Working notes for agents

Omarchy bar-widget plugin. This checkout *is* the installed plugin
(`~/.config/omarchy/plugins/dizziee.unifi-panel`), so edits are live.

## Verifying changes

- `test/lint` (qmllint), `test/test-normalize`, `test/test-fetch` (stub
  controller, checks hostile ids), `test/test-manifest`,
  `omarchy-plugin-validate .`, and the shellcheck line from
  `.github/workflows/ci.yml` (`shellcheck --severity=warning unifi-fetch
  unifi-login lib/unifi-common.sh test/test-normalize test/test-manifest
  test/test-fetch test/lint`). Run all of them before pushing.
- The shell hot-reloads the plugin on file change, but not reliably for
  everything. For a trustworthy check run `omarchy-restart-shell`, wait ~7 s,
  then read `journalctl --user --since "30 sec ago" | grep -i unifi`.
- IPC: `omarchy-shell dizziee.unifi-panel open|close|toggle|refresh`.
- No live controller is needed to test the scripts: serve
  `test/fixtures/network.json` from a stub that answers
  `/proxy/network/integration/v1/sites`, `.../devices`, `.../clients` under
  `{"data":[…],"totalCount":n}` and requires `X-API-KEY`, point `unifi-login`
  at it with `XDG_STATE_HOME` set to a scratch dir, and store a throwaway key.
  Clear the key afterwards: `secret-tool clear application dizziee.unifi-panel type api-key`.

## API reference

- The controller documents its own Integration API at
  `https://<console>/unifi-api/network` (here: https://192.168.95.1/unifi-api/network).
  It is a UniFi OS web app; the JSON it renders, like every
  `/proxy/network/integration/v1/…` endpoint, needs the API key
  (`X-API-KEY`), so read it in a browser signed in to the console. Prefer it
  over memory when a field name or `state` value is in doubt; `normalize.jq`
  and `test/fixtures/network.json` must agree with it. The OpenAPI document
  behind that page is `/proxy/network/api-docs/integration.json` (found via
  `/api/apps` → `integrationApis[].apiDocsLocation`). It is served to a
  UniFi OS browser session, not to the API key: copy the request from the
  browser's dev tools as curl (cookies `TOKEN` and `JSESSIONID`) and pipe it
  to a file. Do not commit it or the cookies.
- Checked live against Network 10.5.67 (UCG Fiber) on 2026-08-18: device
  keys are `features, firmwareUpdatable, firmwareVersion, id, interfaces,
  ipAddress, macAddress, model, name, state, supported`; client keys are
  `access, connectedAt, id, ipAddress, macAddress, name, type,
  uplinkDeviceId`; `features` seen: `accessPoint`, `switching` (the gateway
  reports only `switching`, hence the model-name test); the spec's enums are
  features `switching|accessPoint|gateway`, interfaces `ports|radios`,
  client `type` `WIRED|WIRELESS|VPN|TELEPORT` (only the first two carry
  `uplinkDeviceId`); `/info` returns
   `{"applicationVersion": …}`. A gateway's `ipAddress` is its WAN address,
   so the widget shows the host part of the default network's `ip_subnet`
   (from the classic config) in its row instead; the public address lives
   only in the Devices-tab expansion.

## The report API

- `unifi-fetch` also POSTs to the classic
  `…/proxy/network/api/s/<internalReference>/stat/report/5minutes.gw` with
  `{attrs:[time, wan-rx_bytes, wan-tx_bytes], start, end}` (ms). It accepts
  the same API key. Rows are per gateway MAC (`gw`); bytes are per 5-min
  bucket, so rate = bytes × 8 / 300. Retention here: 5minutes ≈ 24 h, hourly
  ≈ 7 d, daily ≈ 3 months. Cached 4 min in `$XDG_RUNTIME_DIR/omarchy-unifi/`.
  Any failure leaves `gateway.history` null and the widget graphs its own
  heartbeat samples instead — never let it become fatal.

- Client counts come solely from the classic stat/health rows (wlan and lan
  `num_user + num_guest + num_iot`; no VPN figure exists there). The
  Integration `/clients` endpoint is opt-in only (`--clients`, when the
  widget's showClients setting is on): type breakdown, guest split, VPN
  names and per-device counts by `uplinkDeviceId`. The same flag fetches
  classic `stat/sta` for live radio health — `signal` (dBm) and
  `satisfaction` (0–100; anything else is "unknown" and stays null) —
  joined by MAC, so unjoined rows simply show none. Live, uncached, small
  on a small site; bounded by the shared 1 MB budget and never fatal.
  Past the row cap only the claimed total survives.

- WiFi bands come from each broadcast's `broadcastingFrequenciesGHz`; the
  APs and channels come from the cached device table's `vap_table`,
  grouped by ESSID (`radio` ng/na/6e → 2.4/5/6, actual `channel`, `num_sta`
  per radio). Empty until that hourly table answers.

- WAN state comes from classic `…/api/s/<site>/stat/health` (GET, same key):
  the `wan` subsystem row has `status, wan_ip, gateways[], netmask,
  nameservers[] (usually empty), isp_name, asn, uptime_stats{WAN, WAN2, …}`
  (availability, latency_average, uptime or downtime, time_period 86400) and
  the `www` row has `latency, uptime`. The upstream shown is the first IPv4
  entry in `gateways[]` — the controller lists the link-local IPv6 first.
  The public IPv6 lives only in the classic device table (`stat/device`,
  `wan1.ipv6[]`, first non-`fe80:` entry winning); the health row carries
  none, so `ipv6` stays null (shown blank) until the table answers. That
  table is tens of KB per device, so it is cached an hour in
  `$XDG_RUNTIME_DIR/omarchy-unifi/device-<site>.json` with a stale-cache
  fallback — a failed refresh never blanks a known address. The same table
  lends the gateway row its LAN address (`lan_ip`, ahead of the subnet
  fallback). Link names come from the documented
  `/sites/{id}/wans`, matched by position only when the counts agree, with
  the classic `rest/networkconf` names (via `wan_networkgroup`) winning per
  key — a site with two WANs defined but one monitored still names its link.
  The same config lends the WAN detail its DNS (`wan_dns1/2`,
  `wan_ipv6_dns1/2` from the `purpose == "wan"` rows) and the Networks tab
  its subnets (`ip_subnet` matched by network name). Fetched every poll;
  small. Failure → `wan` null → no WAN lines, `subnet` null → no subnet.
  The WAN block renders only in the Devices-tab gateway expansion (gated
  behind a click, like the ports); Overview keeps the graphs and health
  line with no addresses. A link is `unused` (shown muted as "Not connected")
  when it has no uptime and its downtime reaches back to the gateway's boot
  (`gw_system-stats.uptime`, ±10 min): an empty second WAN port looks like
  that and is not a fault. A link that was up and dropped is `down`.
  Checked live against Network 10.6.101 (UDR7) on 2026-09-09.

## Testing the graph

- The graph needs samples, one per controller heartbeat (~24 s). To see it
  quickly, point `backendPath` at a stub that prints the fixture with a
  synthetic `stats` block and a fresh `lastHeartbeatAt` each call, then
  `omarchy-shell dizziee.unifi-panel refresh` in a loop. Swap the file back from a
  copy — **not** `git checkout`, which discards every uncommitted edit in it.

## Things to keep

- The API key never reaches argv: it goes to curl as a header line in a
  config on stdin (`unifi_http`), and `secret-tool` reads it from stdin.
- `fetch_all` sets `FETCHED` rather than printing, because `die` inside a
  `$(...)` would end only the subshell and its JSON would be captured as data.
- The plugin id (`dizziee.unifi-panel`, `hegjon.unifi` before the 0.6.0 rebrand) is also the keyring `application` attribute
  and the IPC target. Renaming it orphans the stored key — `unifi-login` adopts the
  pre-rebrand entry once and clears it; `unifi-login --forget` clears both.
- unifi-login stores only the site id — deliberate: a rename or typo fix on
  the controller must keep polling the same site. unifi-fetch resolves the
  name and internalReference from /sites only when not told them: the widget
  holds the last poll's site and hands it back as `--site=<id>
  --site-ref=<ref>`, so the lookup runs once per widget lifetime. The pair
  counts only when the id matches the config, the ref only if it is a plain
  token, and the ref the widget passes is the one the fetch vetted
  (`site.ref` in the output) — never the controller's raw string. There is
  no `GET /sites/{id}`; the lookup is `/sites?filter=id.eq(<uuid>)&limit=1`
  — the UUID goes **unquoted** (quoted means STRING and the filter wants
  UUID; checked against Network 10.5.67), with one plain /sites page (the
  API's default limit, 25) as fallback for controllers without filtering.
  The gateway id rides the same way (`--gateway=<id>`): an oversized poll
  fetches it via `GET /sites/{id}/devices/{deviceId}` (bare device object)
  and re-verifies it still normalizes as a gateway; the page hunt runs only
  when that is missing or stale.
- Style follows hegjon.prusa-connect: comments explain *why*; imperative
  commit subjects; version lives in `manifest.json`; annotated `vX.Y.Z` tags.
