pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui
import "./components"

// Bar widget and popup for a UniFi Network controller.
//
// All network work happens in unifi-fetch, which prints the normalized model
// on stdout and reports failures as {"error":…} rather than dying, so the panel
// can always render a reason. Nothing here ever touches the API key.
//
// Names, models, ISP and link names are controller data, so every Text in
// this plugin is PlainText: AutoText would render markup found in them, and
// an <img> tag would make the shell fetch whatever URL it names. That goes
// for the shell's own Text-derived components too (PanelSectionHeader keeps
// the AutoText default), so any of them showing controller data sets it.
Panel {
  id: root

  readonly property string pluginId: "dizziee.unifi-panel"

  moduleName: pluginId
  ipcTarget: pluginId

  // --- state ------------------------------------------------------------

  property var devices: []
  property var site: ({ id: "", name: "", ref: "" })
  property var gateway: null
  // A site past the fetcher's device cap: `devices` holds at most the
  // gateway and summary.devices is the controller's claim. controllerInfo
  // carries the configured controller address ({url}).
  property bool oversized: false
  property var controllerInfo: null
  // Network application version from /v1/info, for the footer and for gating
  // version-dependent calls. Empty while unknown; kept across failed polls.
  property string networkVersion: ""

  // The controller's own device list, for the oversized view. UniFi OS
  // consoles serve the Network app at /network/<site>/devices; without a
  // site reference the console root still gets the user there.
  readonly property string deviceListUrl: {
    if (!controllerInfo || !controllerInfo.url) return ""
    return site && site.ref
      ? controllerInfo.url + "/network/" + site.ref + "/devices"
      : controllerInfo.url
  }

  // WAN rate samples for the graph, oldest first: {t, rx, tx}. One entry per
  // controller heartbeat, so consecutive polls that see the same heartbeat
  // add nothing — the rates would just be repeated. Capped so a shell that
  // has been up for a week does not drag a week of points into every paint.
  property var rateHistory: []
  property string lastHeartbeatAt: ""
  readonly property int rateHistoryCap: 120

  // The panel's height ceiling. The device list takes whatever of it the
  // gateway block, headers and footer leave over, so the panel never grows
  // past this and the gateway is never pushed out of view.
  readonly property real panelMaxHeight: Style.space(760)
  property var summary: ({ devices: 0, online: 0, offline: 0, busy: 0, updatable: 0, clients: null, wired: null, wireless: null })
  property string lastError: ""
  property bool needsLogin: false
  property bool initialized: false
  property bool refreshing: false
  property real lastUpdatedAt: 0

  // Notification bookkeeping, keyed by device id: what each device looked
  // like last poll, so only genuine transitions announce themselves.
  property var lastSeenById: ({})
  property var notifiedAt: ({})
  // WAN link states keyed by link key, mirroring lastSeenById for devices.
  property var lastWanByKey: ({})
  // Devices waiting for adoption ({count, devices} or null while unknown),
  // and the count at the last poll so only genuine arrivals announce.
  property var pending: null
  property int lastPendingCount: -1
  // WiFi broadcasts ({count, networks} or null while unknown). Inventory
  // only: networks appear and disappear by configuration, which is not
  // an event worth announcing.
  property var wifi: null
  // Networks ({count, networks} or null while unknown). Inventory only,
  // like WiFi: configuration, not events.
  property var networks: null
  // VPN servers and tunnels ({servers, tunnels} or null while unknown).
  // The overviews carry no live status, so this is configuration only.
  property var vpn: null

  // --- settings ---------------------------------------------------------

  // `omarchy bar set` stores booleans as strings unless given --json, so a
  // boolean setting has to be coerced rather than read straight through.
  function boolSetting(key, fallback) {
    var value = settings ? settings[key] : undefined
    if (value === undefined || value === null) return fallback
    if (typeof value === "string") return value !== "false" && value !== "0" && value !== ""
    return value !== false
  }

  function intSetting(key, fallback, min, max) {
    var value = parseInt(setting(key, fallback), 10)
    if (!isFinite(value)) return fallback
    return Math.max(min, Math.min(max, value))
  }

  readonly property bool showBarClients: boolSetting("showBarClients", false)
  readonly property bool showGatewayStats: boolSetting("showGatewayStats", true)
  readonly property bool showWifi: boolSetting("showWifi", true)
  readonly property bool showNetworks: boolSetting("showNetworks", true)
  readonly property bool showVpn: boolSetting("showVpn", true)
  // Fast while the panel is open so the gateway's rates and load feel live:
  // the controller heartbeats every ~20 s, so most polls repeat the last
  // sample, but each is four small LAN requests (the report is cached).
  readonly property int refreshIntervalMs: intSetting("refreshIntervalSec", 5, 1, 300) * 1000
  readonly property bool watchEnabled: boolSetting("watch", true)
  readonly property int watchIntervalMs: intSetting("watchIntervalSec", 120, 30, 3600) * 1000
  readonly property bool notifyOffline: boolSetting("notifyOffline", true)
  readonly property bool notifyOnline: boolSetting("notifyOnline", true)
  readonly property bool notifyWan: boolSetting("notifyWan", true)
  readonly property bool notifyPending: boolSetting("notifyPending", true)
  readonly property int notifyCooldownMs: intSetting("notifyCooldownMin", 10, 1, 240) * 60000

  // Qt.resolvedUrl yields a file:// URL; Process wants a plain path.
  readonly property string backendPath:
    Qt.resolvedUrl("unifi-fetch").toString().replace(/^file:\/\//, "")

  readonly property string loginPath:
    Qt.resolvedUrl("unifi-login").toString().replace(/^file:\/\//, "")

  // The bar shows the Ubiquiti mark (components/UbiquitiIcon.qml) rather than
  // a font glyph, so it cannot be confused with the shell's own network widget.
  // The glyph below is only the fallback text should the icon fail to load.
  readonly property string barGlyph: String.fromCodePoint(0xF0002)   // md-access_point_network

  // --- formatting -------------------------------------------------------

  function kindGlyph(kind) {
    switch (kind) {
      case "ap": return String.fromCodePoint(0xF0003)        // md-access_point
      case "switch": return String.fromCodePoint(0xF0318)    // md-lan_connect
      default: return String.fromCodePoint(0xF1087)          // md-router_network
    }
  }

  function stateLabel(state) {
    switch (state) {
      case "ONLINE": return "Online"
      case "OFFLINE": return "Offline"
      case "CONNECTION_INTERRUPTED": return "Unreachable"
      case "PENDING_ADOPTION": return "Pending adoption"
      case "ADOPTING": return "Adopting"
      case "GETTING_READY": return "Getting ready"
      case "UPDATING": return "Updating"
      case "ISOLATED": return "Isolated"
      case "DELETING": return "Removing"
      case "U5G_INCORRECT_TOPOLOGY": return "Incorrect topology"
      default:
        return state ? state.charAt(0) + state.slice(1).toLowerCase().replace(/_/g, " ") : "Unknown"
    }
  }

  // Secondary text. The `muted` theme token is not a text colour — a theme is
  // free to set it near the background — so dim the readable popup foreground
  // instead. 0.75 keeps caption-sized text above 4.5:1 on a dark panel.
  readonly property color detailColor:
    Qt.rgba(Color.popups.text.r, Color.popups.text.g, Color.popups.text.b, 0.75)

  function bucketColor(bucket) {
    switch (bucket) {
      case "offline": return Color.urgent
      case "busy": return Color.accent
      case "online": return Color.popups.text
      default: return detailColor
    }
  }

  function formatAgo(epochSeconds) {
    if (!epochSeconds) return "never"
    var deltaSeconds = Date.now() / 1000 - epochSeconds
    if (deltaSeconds < 90) return "just now"
    if (deltaSeconds < 3600) return Math.round(deltaSeconds / 60) + " min ago"
    if (deltaSeconds < 86400) return Math.round(deltaSeconds / 3600) + " h ago"
    return Math.round(deltaSeconds / 86400) + " d ago"
  }

  readonly property int pollIntervalMs: opened ? refreshIntervalMs : watchIntervalMs

  // Re-evaluated on a timer: a binding on Date.now() alone would never update.
  property real nowMs: 0

  // A failed poll leaves the previous list in place, which is right for the
  // panel. The bar badge is a claim about right now, so once the data is older
  // than three polls it says nothing rather than something wrong.
  readonly property bool dataIsStale: {
    if (lastUpdatedAt <= 0) return true
    return (nowMs - lastUpdatedAt) > Math.max(pollIntervalMs * 3, 30000)
  }

  // BarIconButton pins its width to one slot, so this must stay glyph-short.
  readonly property string barSummary: {
    if (!showBarClients || !initialized) return ""
    if (lastError !== "" || dataIsStale) return ""
    // The client count is health-derived and can be missing (no gateway, or
    // the report failed); the device count stands in whenever it is.
    if (oversized || summary.clients === null || summary.clients === undefined)
      return String(summary.devices)
    return String(summary.clients)
  }

  // The API's security enum, shortened. Unknown values pass through raw —
  // every text showing them sets PlainText, like the other controller data.
  function wifiSecurityLabel(security) {
    switch (security) {
      case "OPEN": return "Open"
      case "WPA2_PERSONAL": return "WPA2"
      case "WPA3_PERSONAL": return "WPA3"
      case "WPA2_WPA3_PERSONAL": return "WPA2/WPA3"
      case "WPA2_ENTERPRISE": return "WPA2 Enterprise"
      case "WPA3_ENTERPRISE": return "WPA3 Enterprise"
      case "WPA2_WPA3_ENTERPRISE": return "WPA2/WPA3 Enterprise"
      default: return security ? String(security) : ""
    }
  }

  // Short claim about devices waiting for adoption, or "" when there are
  // none known. Shared by the tooltip and the panel section header.
  readonly property string pendingSummary: {
    if (!pending || !(pending.count > 0)) return ""
    return pending.count + (pending.count === 1 ? " device" : " devices")
      + " waiting for adoption"
  }

  readonly property string wifiSummary: {
    if (!wifi || !(wifi.count > 0)) return ""
    return wifi.count + (wifi.count === 1 ? " WiFi network" : " WiFi networks")
  }

  // Gateway-managed, switch-managed or unmanaged; default network tagged.
  function networkDetailLabel(net) {
    var parts = []
    if (net.standard) parts.push("default")
    if (net.vlanId !== null && net.vlanId !== undefined) parts.push("VLAN " + net.vlanId)
    if (!net.enabled) parts.push("Off")
    return parts.join("  ·  ")
  }

  readonly property string networksSummary: {
    if (!networks || !(networks.count > 0)) return ""
    return networks.count + (networks.count === 1 ? " network" : " networks")
  }

  // The API's VPN type enum, shortened. Unknown values pass through raw —
  // every text showing them sets PlainText, like the other controller data.
  function vpnTypeLabel(vpnType) {
    switch (vpnType) {
      case "WIREGUARD": return "WireGuard"
      case "OPENVPN": return "OpenVPN"
      case "L2TP": return "L2TP"
      case "PPTP": return "PPTP"
      case "IPSEC": return "IPsec"
      case "UID": return "UID"
      default: return vpnType ? String(vpnType) : ""
    }
  }

  readonly property int vpnRowCount: {
    if (!vpn) return 0
    return (vpn.servers ? vpn.servers.length : 0) + (vpn.tunnels ? vpn.tunnels.length : 0)
  }

  readonly property string vpnSummary: {
    if (!vpn) return ""
    var parts = []
    var serverCount = vpn.servers ? vpn.servers.length : 0
    var tunnelCount = vpn.tunnels ? vpn.tunnels.length : 0
    if (serverCount > 0) parts.push(serverCount + (serverCount === 1 ? " server" : " servers"))
    if (tunnelCount > 0) parts.push(tunnelCount + (tunnelCount === 1 ? " tunnel" : " tunnels"))
    if (parts.length === 0) return ""
    return "VPN  ·  " + parts.join("  ·  ")
  }

  // Servers first, then tunnels, as flat rows: {name, dimmed, detail}.
  // A disabled server dims its name and reads Off; tunnels have no
  // enabled flag in the overview, so their type names the row instead.
  readonly property var vpnRows: {
    var rows = []
    if (!vpn) return rows
    var servers = vpn.servers || []
    for (var i = 0; i < servers.length; i++) {
      var server = servers[i]
      rows.push({ name: server.name || "Unnamed server",
                  dimmed: !server.enabled,
                  detail: server.enabled ? vpnTypeLabel(server.type) : "Off" })
    }
    var tunnels = vpn.tunnels || []
    for (var j = 0; j < tunnels.length; j++) {
      var tunnel = tunnels[j]
      var label = vpnTypeLabel(tunnel.type)
      rows.push({ name: tunnel.name || "Unnamed tunnel",
                  dimmed: false,
                  detail: label !== "" ? label + " tunnel" : "" })
    }
    return rows
  }

  readonly property string tooltipSummary: {
    if (needsLogin) return "UniFi: not signed in"
    if (dataIsStale && lastUpdatedAt > 0)
      return "UniFi: last updated " + formatAgo(lastUpdatedAt / 1000)
    if (lastError !== "") return "UniFi: " + lastError
    if (!initialized) return "UniFi: loading…"
    if (oversized) {
      var head = summary.devices + " devices"
      if (summary.clients !== null && summary.clients !== undefined)
        head += " · " + summary.clients + " clients"
      if (pendingSummary !== "") head += " · " + pendingSummary
      return head + " — full list in the UniFi web UI"
    }
    var parts = []
    if (summary.offline > 0) parts.push(summary.offline + " offline")
    parts.push(summary.online + "/" + summary.devices + " devices online")
    if (summary.clients !== null && summary.clients !== undefined)
      parts.push(summary.clients + " clients")
    if (pendingSummary !== "") parts.push(pendingSummary)
    return parts.join(" · ")
  }

  // --- sign-in ----------------------------------------------------------

  // Setup asks for an API key without echo, so it runs in a terminal rather
  // than in the panel. The script pokes `refresh` over IPC when it succeeds.
  function signIn() {
    if (!bar) return
    bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(loginPath))
    close()
  }

  // Panel's own IpcHandler is replaced so that `refresh` can sit next to
  // open/close/toggle under the one target the plugin already publishes.
  manageIpc: false

  IpcHandler {
    target: root.pluginId

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  // --- fetching ---------------------------------------------------------

  function refresh() {
    if (fetchProcess.running) return
    refreshing = true
    // Hand the site from the last poll back so the fetch skips its /sites
    // lookup. The ref is the token the fetch itself vetted — a raw
    // controller string never reaches argv — and the fetch re-checks both
    // against its config before trusting them.
    var cmd = [backendPath]
    if (site && site.id) {
      cmd.push("--site=" + site.id, "--site-ref=" + (site.ref || ""))
      // On an oversized site this lets the fetch get the gateway by id
      // instead of hunting the device pages again.
      if (gateway && gateway.id) cmd.push("--gateway=" + gateway.id)
    }
    fetchProcess.command = cmd
    fetchProcess.running = true
  }

  function applyOutput(text) {
    refreshing = false
    initialized = true

    var parsed
    try {
      parsed = JSON.parse(String(text || ""))
    } catch (error) {
      lastError = "The UniFi helper returned something unreadable"
      return
    }

    if (parsed && parsed.error) {
      lastError = String(parsed.error)
      console.warn("unifi: poll failed:", lastError)
      needsLogin = parsed.needsLogin === true
      return
    }

    lastError = ""
    needsLogin = false
    devices = (parsed && parsed.devices) ? parsed.devices : []
    if (parsed && parsed.site) {
      // A poll launched with --site-ref skipped the site lookup and reports
      // an empty name; keep the one from the poll that resolved it.
      if (parsed.site.name === "" && parsed.site.id === site.id && site.name)
        parsed.site.name = site.name
      site = parsed.site
    }
    if (parsed && parsed.summary) summary = parsed.summary
    gateway = (parsed && parsed.gateway) ? parsed.gateway : null
    oversized = (parsed && parsed.oversized === true)
    controllerInfo = (parsed && parsed.controller) ? parsed.controller : null
    if (parsed && typeof parsed.networkVersion === "string" && parsed.networkVersion !== "")
      networkVersion = parsed.networkVersion
    // A failed poll leaves the previous answer in place: without it a single
    // failed request would announce every pending device as new on recovery.
    if (parsed && parsed.pending && typeof parsed.pending.count === "number")
      pending = parsed.pending
    if (parsed && parsed.wifi && typeof parsed.wifi.count === "number")
      wifi = parsed.wifi
    if (parsed && parsed.networks && typeof parsed.networks.count === "number")
      networks = parsed.networks
    if (parsed && parsed.vpn && parsed.vpn.servers && parsed.vpn.tunnels)
      vpn = parsed.vpn
    lastUpdatedAt = Date.now()
    recordRates()

    evaluateNotifications()
    evaluateWanNotifications()
    evaluatePendingNotifications()
  }

  function recordRates() {
    if (!gateway || !gateway.stats) return
    var st = gateway.stats
    if (st.rxBps === null || st.txBps === null) return
    var stamp = String(st.heartbeatAt || "")
    if (stamp !== "" && stamp === lastHeartbeatAt) return
    lastHeartbeatAt = stamp
    var next = rateHistory.slice()
    next.push({ t: Date.now(), rx: st.rxBps, tx: st.txBps })
    if (next.length > rateHistoryCap) next.splice(0, next.length - rateHistoryCap)
    rateHistory = next
  }

  // --- notifications ----------------------------------------------------

  // Only a transition is worth announcing. `previous` is undefined on the
  // first poll of a session, which deliberately announces nothing — the
  // widget starting up is not an event.
  function notificationFor(device, previous) {
    if (previous === undefined) return null
    if (device.bucket === previous.bucket) return null
    if (device.bucket === "offline" && notifyOffline)
      return { urgency: "critical", body: stateLabel(device.state) }
    if (device.bucket === "online" && previous.bucket === "offline" && notifyOnline)
      return { urgency: "normal", body: "Back online" }
    return null
  }

  function evaluateNotifications() {
    var seen = {}
    var stamps = notifiedAt
    var now = Date.now()

    for (var i = 0; i < devices.length; i++) {
      var device = devices[i]
      if (!device.id) continue
      seen[device.id] = { bucket: device.bucket }

      var notification = notificationFor(device, lastSeenById[device.id])
      if (!notification) continue

      var last = stamps[device.id] || 0
      if (now - last < notifyCooldownMs) continue
      stamps[device.id] = now

      notify(device.name, notification.body, notification.urgency)
    }

    lastSeenById = seen
    notifiedAt = stamps
  }

  // WAN link transitions worth announcing: up<->down only. Anything involving
  // "unused" is setup noise rather than an outage — a port with nothing ever
  // plugged in, or a just-rebooted gateway whose uptime makes every link look
  // fresh — so it never notifies, whichever direction it moves.
  function wanNotificationFor(link, previous) {
    if (!notifyWan) return null
    if (previous === undefined || link.state === previous) return null
    if (link.state === "down" && previous === "up")
      return { urgency: "critical", body: "WAN link down" }
    if (link.state === "up" && previous === "down")
      return { urgency: "normal", body: "WAN link back up" }
    return null
  }

  function evaluateWanNotifications() {
    var links = (gateway && gateway.wan && gateway.wan.links) ? gateway.wan.links : []
    var seen = {}
    var stamps = notifiedAt
    var now = Date.now()

    for (var i = 0; i < links.length; i++) {
      var link = links[i]
      if (!link.key) continue
      seen[link.key] = link.state

      var notification = wanNotificationFor(link, lastWanByKey[link.key])
      if (!notification) continue

      // Shares the device cooldown map under a prefixed key: one setting,
      // one throttle for every announcement this widget makes.
      var stampKey = "wan:" + link.key
      var last = stamps[stampKey] || 0
      if (now - last < notifyCooldownMs) continue
      stamps[stampKey] = now

      // Link names are controller data: same dash-guard as device names.
      notify(notificationArg(link.name || link.key, "WAN link"),
             notificationArg(notification.body, ""))
    }

    lastWanByKey = seen
    notifiedAt = stamps
  }

  // A device appearing in the pending list is news; one disappearing was
  // adopted (or unplugged) and needs no announcement. Counts only: the first
  // poll of a session records and stays silent, like device transitions.
  function evaluatePendingNotifications() {
    var count = (pending && typeof pending.count === "number") ? pending.count : -1
    var previous = lastPendingCount
    lastPendingCount = count

    if (!notifyPending || previous < 0 || count < 0 || count <= previous) return

    var stampKey = "pending"
    var now = Date.now()
    if (now - (notifiedAt[stampKey] || 0) < notifyCooldownMs) return
    var stamps = notifiedAt
    stamps[stampKey] = now
    notifiedAt = stamps

    notify(count === 1 ? "Device waiting for adoption" : count + " devices waiting for adoption",
           "Adopt them in the UniFi console")
  }

  // The title is a device name the controller chose. omarchy-notification-send
  // option-parses every argument, including the ones after the headline, and
  // hands unknown ones to notify-send — so a name that begins with a dash
  // could smuggle in a hint such as omarchy-exec, which the shell runs on
  // click. A leading dash is therefore swapped out before it becomes argv.
  function notificationArg(text, fallback) {
    var s = String(text || fallback)
    return s.charAt(0) === "-" ? "\u2011" + s.slice(1) : s   // U+2011 looks the same, is not an option
  }

  function notify(title, body, urgency) {
    notifyProcess.running = false
    notifyProcess.command = [
      "omarchy-notification-send",
      "--app-name", "UniFi",
      "-u", urgency || "normal",
      notificationArg(title, "Device"), notificationArg(body, "")
    ]
    notifyProcess.running = true
  }

  // --- processes and timers ---------------------------------------------

  Process {
    id: fetchProcess
    running: false
    command: []

    stdout: StdioCollector { id: fetchStdout; waitForEnd: true }
    stderr: StdioCollector { id: fetchStderr; waitForEnd: true }

    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.applyOutput(fetchStdout.text)
        return
      }
      root.refreshing = false
      root.initialized = true
      var detail = String(fetchStderr.text || "").replace(/\s+/g, " ").trim()
      root.lastError = detail !== ""
        ? detail
        : "The UniFi helper exited with code " + exitCode
    }
  }

  Process {
    id: notifyProcess
    running: false
    command: []
  }

  Timer {
    interval: root.pollIntervalMs
    running: root.opened || root.watchEnabled
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // Drives dataIsStale, independent of the poll timer so a wedged poll
    // cannot also freeze the staleness check that reveals it.
    interval: 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  // The gateway (with its statistics block) stays put at the top; every
  // other device scrolls in a list below it, so a large fleet cannot push
  // the panel off the screen or the gateway out of view.
  readonly property var gatewayDevices: devices.filter(function(d) { return d.kind === "gateway" })
  readonly property var otherDevices: devices.filter(function(d) { return d.kind !== "gateway" })

  // A newly opened panel should not show data from twenty minutes ago.
  onOpenedChanged: if (opened) refresh()

  // --- bar button -------------------------------------------------------

  Component {
    id: ubiquitiMark
    Item {
      UbiquitiIcon {
        anchors.centerIn: parent
        // The mark fills its 24-unit box edge to edge, while a font glyph
        // at the bar's icon size leaves margins inside its em box: measured
        // against the neighbouring icons, their ink is about 11 px to the
        // canvas's 16. Scale to the icon font size, then a little under.
        iconSize: Math.round(Style.bar.iconFont * 0.85)
        // The offline badge sits over the top-right corner, which is where
        // the mark's pixel dots are — the one part that says "Ubiquiti"
        // rather than "a U". Mirror the mark while the badge shows so the
        // dots swap to the uncovered side.
        transform: Scale {
          origin.x: Math.round(Style.bar.iconFont * 0.85) / 2
          xScale: offlineBadge.visible ? -1 : 1
        }
        // Same rule as the text glyph: urgent while something is offline.
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        Behavior on color { ColorAnimation { duration: 160 } }
      }
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barSummary !== "" ? root.barSummary : root.barGlyph
    // The client count, when shown, replaces the mark: BarIconButton renders
    // either the component or the text, never both.
    iconComponent: root.barSummary !== "" ? null : ubiquitiMark
    dimmed: root.needsLogin || root.lastError !== ""
    // Not being set up yet is dimmed, not urgent: nothing is wrong with the
    // network, the plugin just has nothing to say.
    active: root.summary.offline > 0 || (root.lastError !== "" && !root.needsLogin)
    activeColor: Color.urgent
    tooltipText: root.tooltipSummary
    slotSize: Style.bar.statusSlot

    // Count of offline devices, drawn in the slot corner so the bar width
    // never changes. Same idiom as the first-party widgets.
    Rectangle {
      id: offlineBadge
      visible: root.summary.offline > 0 && root.lastError === "" && !root.dataIsStale
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
      anchors.horizontalCenterOffset: button.opticalSize / 2 - Style.space(1)
      anchors.verticalCenterOffset: -(button.opticalSize / 2 - Style.space(2))
      height: badgeLabel.implicitHeight + Style.spaceReal(1)
      width: Math.max(height, badgeLabel.implicitWidth + Style.spaceReal(3))
      radius: height / 2
      color: Color.urgent
      border.width: 1
      border.color: Color.bar.background

      Text {

        textFormat: Text.PlainText
        id: badgeLabel
        anchors.centerIn: parent
        text: String(root.summary.offline)
        color: Color.bar.background
        font.family: Style.font.family
        font.pixelSize: Math.max(7, Math.round(Style.font.caption * 0.78))
        font.bold: true
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // --- popup ------------------------------------------------------------

  KeyboardPanel {
    id: networkPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: networkPanel.fittedContentWidth(Style.space(400))
    contentHeight: networkPanel.fittedContentHeight(column.implicitHeight, root.panelMaxHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // j/k and the arrow keys scroll the device list, one row at a time.
      onMoveRequested: function(dx, dy) {
        if (dy === 0 || !deviceList.interactive) return
        var step = deviceList.rowHeight * dy
        deviceList.contentY = Math.max(0, Math.min(deviceList.contentHeight - deviceList.height,
                                                    deviceList.contentY + step))
      }

      // One action per press: a held key would otherwise refetch every repeat.
      property string heldKey: ""
      Keys.onReleased: function(event) { if (!event.isAutoRepeat) keyCatcher.heldKey = "" }
      onTextKey: function(text) {
        var key = text.toLowerCase()
        if (heldKey === key) return
        heldKey = key
        if (key === "r") root.refresh()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        // Height of everything in this column except the device list, so the
        // list can be sized to the space that remains. Reading each child's
        // height here binds to it, so this follows the gateway block as it
        // grows and shrinks. The list is skipped, which is what keeps this
        // from being a binding loop.
        readonly property real fixedHeight: {
          var total = 0
          for (var i = 0; i < children.length; i++) {
            var child = children[i]
            if (child === deviceList || !child.visible) continue
            total += child.height + spacing
          }
          return total
        }

        PanelSectionHeader {
          textFormat: Text.PlainText   // the site name is controller data
          width: parent.width
          text: root.site.name !== "" ? "UniFi · " + root.site.name : "UniFi"
        }

        // Sign-in prompt takes over the panel: nothing else can work without it.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.needsLogin

          Text {

            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.lastError !== "" ? root.lastError : "No UniFi controller configured."
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {

            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Enter your controller's address and an API key from "
              + "Settings → Control Plane → Integrations. The key is stored in the keyring."
            color: root.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Button {
            text: "Set up"
            bordered: true
            fontSize: Style.font.caption
            onClicked: root.signIn()
          }

          Text {

            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Or run unifi-login in a terminal."
            color: root.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Text {

          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          visible: !root.needsLogin && root.lastError !== ""
          text: root.lastError
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Text {

          textFormat: Text.PlainText
          width: parent.width
          visible: !root.initialized && root.lastError === ""
          text: "Loading…"
          color: root.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        // Client summary. The counts come from the controller's health
        // report — the client list is never fetched — and when the report
        // is missing they are null and the line disappears rather than
        // showing them.
        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.initialized && !root.needsLogin && root.lastError === ""
            && root.summary.clients !== null && root.summary.clients !== undefined
          text: {
            var parts = [root.summary.clients + " clients"]
            if (root.summary.wireless !== null && root.summary.wireless !== undefined)
              parts.push(root.summary.wireless + " wireless")
            if (root.summary.wired !== null && root.summary.wired !== undefined)
              parts.push(root.summary.wired + " wired")
            return parts.join("  ·  ")
          }
          color: root.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        // Devices waiting for adoption. The rows are capped so a stack of
        // new hardware cannot push the gateway block out of view; the header
        // carries the controller's full count either way.
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.initialized && !root.needsLogin && root.lastError === ""
            && root.pendingSummary !== ""

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.pendingSummary
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.pending && root.pending.devices
              ? root.pending.devices.slice(0, 5) : []

            Text {
              textFormat: Text.PlainText
              required property var modelData
              width: parent.width
              elide: Text.ElideRight
              text: [modelData.model, modelData.ip, modelData.mac].filter(function(s) { return s !== "" }).join("  ·  ")
              color: root.detailColor
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            // The header already carries the controller's full count; this
            // only appears when rows were held back (panel cap or page cap).
            visible: {
              if (!root.pending || typeof root.pending.count !== "number") return false
              var shown = root.pending.devices ? Math.min(root.pending.devices.length, 5) : 0
              return root.pending.count > shown
            }
            text: {
              // Evaluated even while hidden, so the null guard repeats here.
              if (!root.pending || typeof root.pending.count !== "number") return ""
              var shown = root.pending.devices ? Math.min(root.pending.devices.length, 5) : 0
              return "+" + (root.pending.count - shown) + " more"
            }
            color: root.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // WiFi inventory: every broadcast with its security, or Off when
        // disabled. Rows are capped like the pending list; the header
        // carries the controller's full count either way.
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.showWifi && root.initialized && !root.needsLogin && root.lastError === ""
            && root.wifiSummary !== ""

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.wifiSummary
            color: root.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.wifi && root.wifi.networks
              ? root.wifi.networks.slice(0, 8) : []

            Row {
              id: wifiRow
              required property var modelData
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                id: wifiName
                width: parent.width - wifiDetail.implicitWidth - Style.space(8)
                elide: Text.ElideRight
                text: (wifiRow.modelData.name !== "" ? wifiRow.modelData.name : "Unnamed network")
                  + (wifiRow.modelData.iot ? "  ·  IoT" : "")
                color: wifiRow.modelData.enabled ? Color.popups.text : root.detailColor
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                id: wifiDetail
                text: wifiRow.modelData.enabled ? root.wifiSecurityLabel(wifiRow.modelData.security) : "Off"
                color: root.detailColor
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            // Evaluated even while hidden, so the null guard comes first.
            visible: {
              if (!root.wifi || typeof root.wifi.count !== "number") return false
              var shown = root.wifi.networks ? Math.min(root.wifi.networks.length, 8) : 0
              return root.wifi.count > shown
            }
            text: {
              if (!root.wifi || typeof root.wifi.count !== "number") return ""
              var shown = root.wifi.networks ? Math.min(root.wifi.networks.length, 8) : 0
              return "+" + (root.wifi.count - shown) + " more"
            }
            color: root.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // Networks inventory: every network with its VLAN id. Rows are
        // capped like the lists above; the header carries the full count.
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.showNetworks && root.initialized && !root.needsLogin && root.lastError === ""
            && root.networksSummary !== ""

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.networksSummary
            color: root.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.networks && root.networks.networks
              ? root.networks.networks.slice(0, 8) : []

            Row {
              id: networkRow
              required property var modelData
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                id: networkName
                width: parent.width - networkDetail.implicitWidth - Style.space(8)
                elide: Text.ElideRight
                text: networkRow.modelData.name !== "" ? networkRow.modelData.name : "Unnamed network"
                color: networkRow.modelData.enabled ? Color.popups.text : root.detailColor
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                id: networkDetail
                text: root.networkDetailLabel(networkRow.modelData)
                color: root.detailColor
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            // Evaluated even while hidden, so the null guard comes first.
            visible: {
              if (!root.networks || typeof root.networks.count !== "number") return false
              var shown = root.networks.networks ? Math.min(root.networks.networks.length, 8) : 0
              return root.networks.count > shown
            }
            text: {
              if (!root.networks || typeof root.networks.count !== "number") return ""
              var shown = root.networks.networks ? Math.min(root.networks.networks.length, 8) : 0
              return "+" + (root.networks.count - shown) + " more"
            }
            color: root.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // VPN inventory: servers, then site-to-site tunnels. Configuration
        // only — the overviews carry no live status. Rows are capped like
        // the lists above; the header carries the full breakdown.
        Column {
          width: parent.width
          spacing: Style.space(2)
          visible: root.showVpn && root.initialized && !root.needsLogin && root.lastError === ""
            && root.vpnSummary !== ""

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.vpnSummary
            color: root.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.vpnRows.slice(0, 8)

            Row {
              id: vpnRow
              required property var modelData
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                id: vpnName
                width: parent.width - vpnDetail.implicitWidth - Style.space(8)
                elide: Text.ElideRight
                text: vpnRow.modelData.name
                color: vpnRow.modelData.dimmed ? root.detailColor : Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                id: vpnDetail
                text: vpnRow.modelData.detail
                color: root.detailColor
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            // Evaluated even while hidden, so the null guard comes first.
            visible: root.vpnRows.length > 8
            text: "+" + (root.vpnRows.length - 8) + " more"
            color: root.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Text {

          textFormat: Text.PlainText
          width: parent.width
          visible: root.initialized && !root.needsLogin && root.lastError === ""
            && root.devices.length === 0 && !root.oversized
          text: "No devices on this site."
          color: root.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Repeater {
          model: root.gatewayDevices

          DeviceRow {
            id: gatewayEntry

            required property var modelData

            width: column.width
            device: gatewayEntry.modelData
            host: root
            gatewayStats: root.showGatewayStats && root.gateway && root.gateway.stats
              && String(gatewayEntry.modelData.id) === String(root.gateway.id)
              ? root.gateway.stats : null
            rateHistory: root.rateHistory
            rateReport: root.gateway ? (root.gateway.history || null) : null
            wanState: root.gateway ? (root.gateway.wan || null) : null
          }
        }

        // Where the device list would scroll, a site past the cap gets the
        // count and a door to the controller's own list instead.
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.initialized && !root.needsLogin && root.lastError === "" && root.oversized

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.summary.devices + " devices — more than this widget lists."
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Button {
            text: "Open the device list"
            bordered: true
            fontSize: Style.font.caption
            visible: root.deviceListUrl !== ""
            onClicked: Qt.openUrlExternally(root.deviceListUrl)
          }
        }

        // ListView rather than Repeater so a long fleet scrolls inside a
        // fixed box instead of growing the panel. Same idiom as the network
        // panel's station list.
        ListView {
          id: deviceList
          width: parent.width
          // Whatever the panel ceiling leaves after the fixed content, but
          // never less than about two rows so the list stays usable.
          height: Math.min(contentHeight, Math.max(Style.space(96),
            Math.min(root.panelMaxHeight, networkPanel.availableCardHeight)
              - networkPanel.verticalContentInset - column.fixedHeight))
          spacing: Style.space(10)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          visible: count > 0

          // One row plus spacing, for keyboard stepping.
          readonly property real rowHeight: (contentItem.children.length > 0
            ? contentItem.children[0].height : Style.space(40)) + spacing

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.otherDevices

          delegate: DeviceRow {
            id: deviceEntry

            required property var modelData

            width: ListView.view.width - Style.space(6)   // room for the scrollbar
            device: deviceEntry.modelData
            host: root
          }
        }

        Text {

          textFormat: Text.PlainText
          width: parent.width
          text: root.refreshing
            ? "Refreshing…"
            : (root.lastUpdatedAt > 0
               ? "Updated " + root.formatAgo(root.lastUpdatedAt / 1000)
                 + (root.networkVersion !== "" ? "   ·   Network " + root.networkVersion : "")
                 + "   ·   R to refresh"
               : "")
          color: root.detailColor
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
