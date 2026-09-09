# Reshape {site, devices, clients} from the UniFi Network Integration API into
# the flat model the widget renders. Every field is optional here so a sparse
# object normalizes without error rather than throwing.
#
#   jq -f normalize.jq < raw.json

def as_number($v): if ($v | type) == "number" then $v else null end;

# A non-empty string, or null: controller strings render empty downstream,
# so blank and missing stay blank rather than "null".
def as_string($v): if ($v | type) == "string" and ($v | length) > 0 then $v else null end;

# The classic networkconf (one small array, fetched beside stat/health):
# WAN rows carry the configured DNS the health report omits, and every
# corporate row carries its subnet for the Networks tab. Null when unfetched.
# Takes the conf array as an argument: call sites inside map() see the row
# as `.`, not the top document.
def wan_dns($conf; $ver):
  [$conf[]?
    | select(.purpose == "wan")
    | (if $ver == 6 then [.wan_ipv6_dns1, .wan_ipv6_dns2] else [.wan_dns1, .wan_dns2] end)[]
    | select(type == "string" and length > 0)]
  | unique;

# Subnet for one Integration network, matched to its classic row by name.
# The Integration list and the classic config share names but not ids.
def network_subnet($conf; $name):
  (($conf | map(select(.name == $name)) | .[0].ip_subnet // null)
   | if type == "string" and length > 0 then . else null end);

# Configured names for the WAN keys (via wan_networkgroup), so a monitored
# link keeps its name even when the /wans count and the health keys disagree.
def wan_group_names($conf):
  [($conf[]?
    | select(.purpose == "wan" and (.wan_networkgroup | type) == "string")
    | {key: .wan_networkgroup, value: .name})] | from_entries;

# The gateway's row in the classic device table, matched by MAC: the only
# source of its LAN address and public IPv6. Null when unfetched or unmatched
# (an empty MAC never matches, so a degenerate row cannot stand in).
def gateway_stat_row($table; $mac):
  (if $mac == "" then null
   else ((($table // []) | map(select((.mac // "" | ascii_downcase) == $mac)) | .[0]) // null) end);

# First globally-routable IPv6 across the uplink blocks; a link-local fe80::/10
# address is the neighbour on the wire, not the site, so it never counts.
def public_ipv6($addrs):
  ([(($addrs // [])[] | select(type == "string" and length > 0 and (test("^fe80:") | not)))] | .[0] // null);

# Lowercased MAC or "": controller ids are matched case-insensitively, and a
# non-string never reaches ascii_downcase to throw.
def lower_mac: if type == "string" and length > 0 then ascii_downcase else "" end;

# Classic stat/sta rows keyed by lowercase MAC: live radio health for the
# Clients tab. Satisfaction outside 0–100 is the controller's "unknown" and
# stays null rather than rendering "-1%".
def sta_health($rows):
  ([((($rows // [])[]
      | select((.mac | type) == "string" and (.mac | length) > 0))
     | {key: (.mac | ascii_downcase),
        value: {signal: as_number(.signal),
                satisfaction: (as_number(.satisfaction)
                               | if type == "number" and . >= 0 and . <= 100
                                 then . else null end)}})]
   | from_entries);

# Classic vap_table rows grouped by SSID: which AP broadcasts what, on which
# radio and channel, with how many clients. The AP name rides from the table
# row itself; rows without an ESSID (stale VAPs) are skipped.
def vap_by_essid($table):
  ([(($table // [])[] | {ap: (.name // ""), vap: ((.vap_table // [])[])})
     | select((.vap.essid | type) == "string" and (.vap.essid | length) > 0)
     | {essid: .vap.essid,
        entry: {ap: (if .ap != "" then .ap else null end),
                radio: (if (.vap.radio | type) == "string" then .vap.radio else "" end),
                channel: as_number(.vap.channel),
                clients: (as_number(.vap.num_sta) // 0)}}]
   | group_by(.essid)
   | map({key: .[0].essid, value: map(.entry)})
   | from_entries);

# The API's device.state values (the enum in the controller's OpenAPI document:
# ONLINE, OFFLINE, PENDING_ADOPTION, UPDATING, GETTING_READY, ADOPTING,
# DELETING, CONNECTION_INTERRUPTED, ISOLATED, U5G_INCORRECT_TOPOLOGY), folded
# to what the panel distinguishes.
# CONNECTION_INTERRUPTED is a device the controller can no longer hear from,
# so it is treated as offline for the badge and notifications.
def bucket:
  . as $s
  | if $s == "ONLINE" then "online"
    elif $s == "OFFLINE" or $s == "CONNECTION_INTERRUPTED" then "offline"
    elif $s == "UPDATING" or $s == "GETTING_READY" or $s == "ADOPTING" or $s == "PENDING_ADOPTION" then "busy"
    else "other" end;

# Which role a device plays. The API's features enum is switching, accessPoint
# and gateway, but a UCG Fiber on Network 10.5 reports only "switching", so
# the model name is the fallback tell for Ubiquiti's gateway lines (Dream
# Machine, Cloud Gateway, Security Gateway, Express, …). A generation digit
# can follow the prefix with no separator — a Dream Router 7 reports "UDR7" —
# so a bare digit counts as a boundary too.
def is_gateway:
  ((.features // []) | index("gateway")) != null
  or ((.model // "") | test("^(UDM|UCG|UXG|USG|UDR|UDW|UX|EFG)([- ]|[0-9]|$)|Dream|Gateway|Fortress|Express"; "i"));

def kind:
  if is_gateway then "gateway"
  elif ((.features // []) | index("accessPoint")) != null then "ap"
  elif ((.features // []) | index("switching")) != null then "switch"
  else "other" end;

# The gateway leads the list because it is what everything else hangs off,
# then everything reachable, with offline devices last where they do not push
# the working network out of view. Within a group: access points, switches,
# then by name.
def sort_key:
  [ (if .kind == "gateway" then 0 else 1 end),
    (if .bucket == "online" then 0 elif .bucket == "busy" then 1 else 2 end),
    (if .kind == "ap" then 0 elif .kind == "switch" then 1 else 2 end),
    .name ];

def display_name: (.name // .model // .macAddress // "Device") | tostring;

# The gateway's latest statistics, when the caller fetched them: rates on its
# uplink (the WAN), load and uptime. Bits per second are kept as the API gives
# them; the panel chooses the unit.
def gateway_stats:
  if (.stats // null) == null then null else
    {
      uptimeSec: as_number(.stats.uptimeSec),
      heartbeatAt: (.stats.lastHeartbeatAt // null),
      cpuPct: as_number(.stats.cpuUtilizationPct),
      memPct: as_number(.stats.memoryUtilizationPct),
      load1: as_number(.stats.loadAverage1Min),
      load5: as_number(.stats.loadAverage5Min),
      load15: as_number(.stats.loadAverage15Min),
      rxBps: as_number(.stats.uplink?.rxRateBps),
      txBps: as_number(.stats.uplink?.txRateBps)
    }
  end;

# Five-minute WAN buckets from the classic report API, turned into average
# bits per second per bucket. Rows are per gateway (keyed by MAC in `gw`); the
# caller's gateway is matched when the MAC is known, otherwise all rows count.
def report_history($mac):
  if (.report // null) == null then null else
    (.report
     | map(select((.time | type) == "number"))
     | (if $mac != "" and (map(select(.gw == $mac)) | length) > 0
        then map(select(.gw == $mac)) else . end)
     | sort_by(.time)
     | map({
         t: .time,
         rxBps: ((as_number(.["wan-rx_bytes"]) // 0) * 8 / 300),
         txBps: ((as_number(.["wan-tx_bytes"]) // 0) * 8 / 300)
       }))
  end;

# WAN state from the classic stat/health "wan" subsystem, with link names from
# the documented /wans list and DNS from the classic networkconf (the health
# row's own nameservers are usually empty). uptime_stats is keyed WAN, WAN2, …
# in the same order the controller lists the links, so the names are matched
# by position when the counts agree and the key is used as the name otherwise.
# The classic config also maps each key (via wan_networkgroup) to its
# configured name, which wins whenever it names that exact key.
def wan_state:
  if (.health // null) == null then null else
    ((.health // []) | map(select(.subsystem == "wan")) | .[0] // null) as $wan
    | ((.health // []) | map(select(.subsystem == "www")) | .[0] // null) as $www
    | (.networkConf // []) as $network_conf
    | if $wan == null then null else
      ((.wans // []) | map(.name // "")) as $names
      | wan_group_names($network_conf) as $group_names
      | (($wan.uptime_stats // {}) | to_entries | sort_by(.key)) as $links
      # The gateway's own uptime, to tell an unused port from a failed link:
      # a link whose downtime is as old as the gateway has never been up.
      | (($wan["gw_system-stats"].uptime // null) | if type == "string" then (tonumber? // null) else . end) as $gw_uptime
      | (($wan.gateways // []) | map(select(type == "string"))) as $gateways
      | ([($gateways[] | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")))] | .[0] // null) as $gateway_v4
      | ([(($wan.nameservers // [])[] | select(type == "string" and length > 0))] | unique) as $health_dns
      | ([($health_dns[] | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$")))] + wan_dns($network_conf; 4) | unique) as $dns4
      | ([($health_dns[] | select(contains(":")))] + wan_dns($network_conf; 6) | unique) as $dns6
      | {
          status: ($wan.status // "unknown"),
          ip: ($wan.wan_ip // null),
          ipv6: ($wan.wan_ipv6 // $wan.ipv6 // null),
          gateway: ($gateway_v4 // ($gateways[0] // null)),
          gateways: $gateways,
          netmask: as_string($wan.netmask),
          dns4: $dns4,
          dns6: $dns6,
          isp: ($wan.isp_name // $wan.isp_organization // null),
          asn: as_number($wan.asn),
          latencyMs: as_number($www.latency),
          uptimeSec: as_number($www.uptime),
          links: ($links | to_entries | map(
            .key as $i | .value.key as $key | .value.value as $u
            | (($u.uptime // 0) > 0 and (($u.downtime // 0) == 0 or ($u.availability // 0) > 0)) as $up
            # Never up: no uptime, and either no downtime figure at all or one
            # that reaches back to (within ten minutes of) the gateway's boot.
            # A second WAN port with nothing plugged in looks exactly like
            # this, and it is not a fault.
            | ((($u.uptime // 0) == 0)
               and (($u.availability // 0) == 0)
               and (($u.downtime // null) == null
                    or ($gw_uptime != null and ($u.downtime // 0) >= $gw_uptime - 600))) as $never_up
            | {
                key: $key,
                name: (as_string($group_names[$key])
                       // (if ($names | length) == ($links | length) then ($names[$i] // $key) else $key end)),
                up: $up,
                state: (if $up then "up" elif $never_up then "unused" else "down" end),
                availabilityPct: as_number($u.availability),
                latencyMs: as_number($u.latency_average),
                uptimeSec: as_number($u.uptime),
                downtimeSec: as_number($u.downtime),
                periodSec: as_number($u.time_period)
              }))
        }
      end
  end;

# Client counts, taken from the classic health rows the fetch already has —
# the client list itself is never requested. wlan and lan each count users,
# guests and IoT; their sum is shown as the total so the line always adds up
# (the controller's own num_sta can differ by its own accounting). The rows
# carry no VPN figure. Null when the health report is missing or countless.
def health_clients:
  if (.health // null) == null then null else
    ((.health // []) | map(select(.subsystem == "wlan")) | .[0] // null) as $wlan
    | ((.health // []) | map(select(.subsystem == "lan")) | .[0] // null) as $lan
    | (if $wlan == null then null
       else (as_number($wlan.num_user) // 0) + (as_number($wlan.num_guest) // 0)
            + (as_number($wlan.num_iot) // 0) end) as $wireless
    | (if $lan == null then null
       else (as_number($lan.num_user) // 0) + (as_number($lan.num_guest) // 0)
            + (as_number($lan.num_iot) // 0) end) as $wired
    | if $wireless == null and $wired == null then null
      else {clients: (($wireless // 0) + ($wired // 0)), wireless: $wireless, wired: $wired} end
  end;

# Client type for the breakdown: the API's enum, folded to the four kinds
# the panel distinguishes. Anything else counts toward the total only.
def client_kind:
  . as $t
  | if $t == "WIRED" then "wired"
    elif $t == "WIRELESS" then "wireless"
    elif $t == "VPN" then "vpn"
    elif $t == "TELEPORT" then "teleport"
    else "other" end;

# Per-device client counts from the uplinkDeviceId the wired and wireless
# rows carry. Keys are controller ids; rows without one (VPN, Teleport)
# belong to no device.
def clients_per_device:
  reduce (.[] | select((.uplinkDeviceId // "") != "")) as $c ({};
    .[$c.uplinkDeviceId] += 1);

(.site // {}) as $site
| gateway_stats as $stats
| wan_state as $wan
| (.clients // []) as $client_rows
| (.clientsRequested // false) as $clients_requested
| (as_number(.clientsTotal) // 0) as $clients_total
| (if $clients_requested and $clients_total == 0
   then ($client_rows | clients_per_device) else {} end) as $per_device
| ((.networks.data // []) | map(select(.["default"] == true)) | .[0].name // null) as $std_name
| (.networkConf // []) as $network_conf_early
| (.statDevice // []) as $stat_device
| sta_health(.staClients) as $sta_by_mac
| vap_by_essid($stat_device) as $vap_by_ssid
# The gateway's own ipAddress is its WAN address, so its row would leak the
# public IP. Its LAN address comes from the classic device table, falling
# back to the host part of the default network's subnet (usually the
# Management network's gateway); corporate rows share that fallback when
# nothing is flagged default.
| (((.devices // []) | map(select(kind == "gateway")) | .[0].macAddress // "" | ascii_downcase)) as $gw_mac
| gateway_stat_row($stat_device; $gw_mac) as $gw_row
| (as_string($gw_row.lan_ip)
   // ((($network_conf_early | map(select(.name == $std_name)) | .[0].ip_subnet // null)
      // ($network_conf_early | map(select(.purpose == "corporate"))
         | map(.ip_subnet) | map(select(type == "string" and length > 0)) | .[0] // null))
      | if type == "string" and length > 0 then (split("/")[0]) else null end)) as $gateway_lan_ip
# The public IPv6 lives only in the classic device table's uplink blocks;
# the health row carries none. Link-local stays out (see public_ipv6).
| (public_ipv6((($gw_row.wan1.ipv6 // []) + ($gw_row.wan2.ipv6 // [])))) as $wan_ipv6
| ((.devices // []) | map(
    (.state // "OFFLINE" | tostring) as $state
    | {
        id: (.id // .macAddress // ""),
        name: display_name,
        model: (.model // ""),
        mac: (.macAddress // ""),
        ip: (if kind == "gateway" and $gateway_lan_ip != null
             then $gateway_lan_ip else (.ipAddress // "") end),
        state: $state,
        bucket: ($state | bucket),
        online: (($state | bucket) == "online"),
        features: (.features // []),
        kind: kind,
        firmwareUpdatable: (.firmwareUpdatable // false),
        clients: ($per_device[.id // .macAddress // ""] // 0)
      }
  ) | sort_by(sort_key)) as $devices
| ($devices | map(select(.kind == "gateway")) | .[0] // null) as $gateway
| (as_number(.deviceTotal) // 0) as $device_total
| (health_clients // {clients: null, wireless: null, wired: null}) as $hc
| (.pending // null) as $pending
| (.wifi // null) as $wifi
| (.networks // null) as $networks
| (.networkConf // []) as $network_conf
| (.vpnServers // null) as $vpn_servers
| (.vpnTunnels // null) as $vpn_tunnels
| {
    # ref is the classic-API reference as vetted by the fetch; the widget
    # hands it back on the next poll so the site lookup runs only once.
    site: {id: ($site.id // ""), name: ($site.name // $site.internalReference // ""),
           ref: (.siteRef // "")},
    devices: $devices,
    # A site past the fetcher's device cap: devices holds at most the
    # gateway, the count below is the controller's claim, and clients were
    # never asked for.
    oversized: ($device_total > 0),
    # The url is the user's configured controller address (not controller
    # data); the oversized view links to its device list.
    controller: (if $device_total > 0 then {url: (.controllerUrl // "")} else null end),
    # The first gateway is the one whose statistics are fetched and graphed.
    # The device table's public IPv6 wins over the health row's (which has
    # none); either way a missing address stays null and renders blank.
    gateway: (if $gateway == null then null
              else {id: $gateway.id, name: $gateway.name, stats: $stats,
                    history: report_history($gateway.mac),
                    wan: (if $wan == null then null
                          elif $wan_ipv6 != null then ($wan + {ipv6: $wan_ipv6})
                          else $wan end)} end),
    # The controller's Network application version from /v1/info, for the
    # panel footer and for gating version-dependent calls. Null when unfetched.
    networkVersion: (if (.info.applicationVersion | type) == "string"
                     then .info.applicationVersion else null end),
    # Devices waiting for adoption from /v1/pending-devices. The count is the
    # controller's claim; the rows are whatever page the fetch brought back.
    # Null when the request failed, so the widget keeps its last answer.
    pending: (if $pending == null then null else
      ($pending.data // [] | map({
        model: (.model // ""),
        mac: (.macAddress // ""),
        ip: (.ipAddress // "")
      })) as $rows
      | {count: (as_number($pending.totalCount) // ($rows | length)), devices: $rows} end),
    # WiFi broadcasts from /v1/sites/<id>/wifi/broadcasts. Security is the
    # API's raw enum (OPEN, WPA3_PERSONAL, …); the panel shortens it. Bands
    # come from the broadcast itself; the APs, channels and per-radio client
    # counts come from the classic device table's vap_table, matched by SSID
    # name — empty until that hourly table answers. Null when the request
    # failed, so the widget keeps its last answer.
    wifi: (if $wifi == null then null else
      ($wifi.data // [] | map({
        name: (.name // ""),
        enabled: (.enabled // false),
        security: (if (.securityConfiguration.type | type) == "string"
                   then .securityConfiguration.type else "" end),
        iot: ((.type // "") == "IOT_OPTIMIZED"),
        bands: ([(.broadcastingFrequenciesGHz // [])[]
                 | select(type == "number")] | unique | sort),
        radios: ($vap_by_ssid[.name // ""] // [])
      })) as $rows
      | {count: (as_number($wifi.totalCount) // ($rows | length)), networks: $rows} end),
    # Networks from /v1/sites/<id>/networks. Management is the API's raw enum
    # (GATEWAY, SWITCH, UNMANAGED); the panel shortens it. The overview rows
    # carry no addresses, so each row's subnet is merged from the classic
    # networkconf by name (its ip_subnet, e.g. "10.24.1.1/27"). Null when the
    # request failed, so the widget keeps its last answer.
    networks: (if $networks == null then null else
      ($networks.data // [] | map({
        name: (.name // ""),
        vlanId: as_number(.vlanId),
        enabled: (.enabled // false),
        management: (if (.management | type) == "string" then .management else "" end),
        standard: (.["default"] // false),
        subnet: network_subnet($network_conf; (.name // ""))
      })) as $rows
      | {count: (as_number($networks.totalCount) // ($rows | length)), networks: $rows} end),
    # VPN servers and site-to-site tunnels. The overviews carry no live
    # status, so this is configuration only: names, types and (for servers)
    # enabled state. Each side normalizes alone; the block is null only when
    # both requests failed, so the widget keeps its last answer.
    vpn: (
      (if $vpn_servers == null then null else
        ($vpn_servers.data // [] | map({
          name: (.name // ""),
          enabled: (.enabled // false),
          type: (if (.type | type) == "string" then .type else "" end)
        })) end) as $servers
      | (if $vpn_tunnels == null then null else
        ($vpn_tunnels.data // [] | map({
          name: (.name // ""),
          type: (if (.type | type) == "string" then .type else "" end)
        })) end) as $tunnels
      | if $servers == null and $tunnels == null then null
        else {servers: ($servers // []), tunnels: ($tunnels // [])} end),
    # Connected clients from the opt-in /clients fetch, with live radio
    # health (signal, satisfaction) from classic stat/sta joined by MAC —
    # the Integration list carries neither. Unrequested, the block is null
    # and the panel keeps its health-report totals. Past the row cap only
    # the claimed count survives and the breakdown is nulls.
    clientsDetail: (
      if ($clients_requested | not) then null
      elif $clients_total > 0 then
        {count: $clients_total, wired: null, wireless: null, vpn: null,
         teleport: null, guests: null, vpnClients: []}
      else
        ($client_rows | map(.type as $t | (.macAddress | lower_mac) as $mac | {
           kind: ($t | client_kind),
           guest: ((.access.type // "") == "GUEST"),
           uplink: (.uplinkDeviceId // ""),
           name: (.name // ""),
           ip: (.ipAddress // ""),
           signal: ($sta_by_mac[$mac].signal // null),
           satisfaction: ($sta_by_mac[$mac].satisfaction // null)
         })) as $rows
        | {count: ($rows | length),
           wired: ($rows | map(select(.kind == "wired")) | length),
           wireless: ($rows | map(select(.kind == "wireless")) | length),
           vpn: ($rows | map(select(.kind == "vpn")) | length),
           teleport: ($rows | map(select(.kind == "teleport")) | length),
           guests: ($rows | map(select(.guest)) | length),
           vpnClients: ($rows | map(select(.kind == "vpn"))
                        | map({name: .name, ip: .ip})[:10]),
           list: ($rows | map({name: .name, kind: .kind, guest: .guest,
                               ip: .ip, signal: .signal,
                               satisfaction: .satisfaction}))} end),
    summary: {
      devices: (if $device_total > 0 then $device_total else ($devices | length) end),
      online: ($devices | map(select(.bucket == "online")) | length),
      offline: ($devices | map(select(.bucket == "offline")) | length),
      busy: ($devices | map(select(.bucket == "busy")) | length),
      updatable: ($devices | map(select(.firmwareUpdatable)) | length),
      clients: $hc.clients,
      wired: $hc.wired,
      wireless: $hc.wireless
    }
  }
