# UniFi Panel for Omarchy

Watch your UniFi network from the Omarchy bar. The panel opens on an
Overview with your gateway's live WAN rates — download and upload, each with
a graph of the last twelve hours — plus CPU, memory, load and uptime. Five
more tabs cover the rest of the site:

- **Devices** — every access point, switch and gateway with online state,
  model, LAN address and client count. Click the gateway for its WAN detail:
  public IPv4 and IPv6, upstream gateway, IPv4 and IPv6 DNS, ISP, and each
  WAN link's latency, uptime and 24-hour availability, so a failed-over or
  dead backup link is visible. Click any other device for its load figures,
  switch ports and radio details.
- **WiFi** — every SSID with its security and bands, plus which access
  point broadcasts it on what channel.
- **Networks** — every network with its subnet and VLAN id.
- **VPN** — VPN servers and site-to-site tunnels.
- **Clients** — connected clients with type, signal strength, satisfaction
  and address (opt-in; the bar can show the count too).

The bar icon carries a badge with the number of offline devices, and
notifications fire when a device drops or comes back, a WAN link fails over,
a device waits for adoption, or a firmware update appears. It is read-only:
it never changes anything on the controller.

<img width="608" height="593" alt="dizziee unifi-panel-1" src="https://github.com/user-attachments/assets/11e7e38c-0cc0-4f36-805d-1a691c4b866a" />

It talks to the UniFi Network application's official **Integration API**
(Network 9.0 or newer) with an API key, so it works with UniFi OS consoles
(UDM, UCG, Cloud Key Gen2+) and self-hosted controllers alike, on your LAN or
over a VPN. A few details the documented API omits — the traffic graph, WAN
addresses and DNS, subnets, radio channels, client signal — come from the
controller's classic endpoints, which accept the same key; if those stop
answering, the graphs fall back to samples the widget collects itself and
the extra lines simply disappear.

## Install

```bash
omarchy plugin add https://github.com/JJDizz1L/dizziee.unifi-panel.git --enable
```

If the widget is enabled but not visible, place it explicitly:

```bash
omarchy plugin enable dizziee.unifi-panel --section right
omarchy restart shell
```

Update or remove:

```bash
omarchy plugin update dizziee.unifi-panel --yes
omarchy plugin remove dizziee.unifi-panel
```

Requires `curl`, `jq` and `secret-tool` (package `libsecret`), all present on a
stock Omarchy system.

## Setup

1. In the UniFi Network application go to **Settings → Control Plane →
   Integrations** and create an API key.
2. Click the widget and press **Set up**, or run
   `~/.config/omarchy/plugins/dizziee.unifi-panel/unifi-login` in a terminal.
3. Enter the controller address (your default gateway is offered, which on a
   UniFi network is usually the console), say whether to accept its
   self-signed certificate (the default is to allow it), and paste the key.
   If the controller has more than one site you then pick one from a list.

The address and site are kept in `~/.local/state/omarchy/unifi/config`; the
key goes into the keyring under the plugin id and is never written anywhere
else or passed on a command line. `unifi-login --status` shows what is
configured, `unifi-login --forget` removes it all.

The controller URL is normally the console root: the plugin appends
`/proxy/network/integration/v1`. If your deployment serves the API somewhere
else, give the full URL ending in `/integration/v1` and it is used as given.

## Settings

Under the widget's settings in the bar — or right-click the bar icon (S in
the panel) to edit them in the panel itself, where S saves:

- Show the connected client count on the bar icon
- Fetch the client list for type breakdown, signal strength, satisfaction and per-device counts
- Show the gateway's WAN graph, CPU, memory and uptime
- Show WiFi networks with their security, bands and channels in the panel
- Show networks with their subnets and VLAN ids in the panel
- Show VPN servers and tunnels in the panel
- Refresh interval while the panel is open (3 minutes), and the background poll interval
- Notify when a device goes offline / comes back online, with a per-device
  cooldown (both off by default)
- Notify when a WAN link goes down / recovers (same cooldown)
- Notify when a device waits for adoption
- Notify when a firmware update becomes available for a device

Middle-click the icon, or press **R** in the panel, to refresh. IPC:
`omarchy-shell dizziee.unifi-panel open|close|toggle|refresh` or
`omarchy-shell dizziee.unifi-panel tab clients` (overview, devices, wifi,
networks, vpn, clients).

## Development

`test/test-normalize` (fixtures under `test/fixtures/`), `test/test-fetch`
(stub controller, hostile-id cases), `test/test-manifest`,
`test/lint` (qmllint; needs an Omarchy machine), `omarchy-plugin-validate .`,
and `shellcheck --severity=warning unifi-fetch unifi-login lib/unifi-common.sh
test/test-normalize test/test-manifest test/test-fetch test/lint`.

## Gallery

<img width="603" height="781" alt="dizziee unifi-panel-2" src="https://github.com/user-attachments/assets/8a4bd552-0f2d-4489-a3d5-b5ba50e575e6" />
<img width="600" height="331" alt="dizziee unifi-panel-3" src="https://github.com/user-attachments/assets/c8f34284-cac8-4eb3-9e85-786723b584ea" />
<img width="605" height="772" alt="dizziee unifi-panel-4" src="https://github.com/user-attachments/assets/bb174a8f-eb19-43de-96b9-101271c52428" />
<img width="603" height="440" alt="dizziee unifi-panel-5" src="https://github.com/user-attachments/assets/c0c54999-f578-4299-abe8-bca78672ed2f" />
<img width="602" height="398" alt="dizziee unifi-panel-6" src="https://github.com/user-attachments/assets/49879ef8-30cb-4ae7-9518-4fbc67cd5b8f" />
<img width="602" height="327" alt="dizziee unifi-panel-7" src="https://github.com/user-attachments/assets/d6c2ac62-a982-4cf7-8e50-3b4755e2069d" />
<img width="598" height="515" alt="dizziee unifi-panel-8" src="https://github.com/user-attachments/assets/abe1e2ab-76ec-4582-9103-dd10e35bbbcd" />


## License

MIT. Not affiliated with, endorsed by, or supported by Ubiquiti Inc.; UniFi is
their trade mark.

---

Inspired by [hegjon/omarchy-unifi](https://github.com/hegjon/omarchy-unifi).
