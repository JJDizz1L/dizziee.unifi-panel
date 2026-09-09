# Reshape one adopted device's detail + latest statistics into the small
# model DeviceDetail renders. Every field is optional here so a sparse
# object normalizes without error rather than throwing.
#
#   unifi-device --device=<id>
#   jq -f normalize-device.jq < raw.json    # raw.json is {detail, stats}

# Same shape as gateway_stats in normalize.jq, plus per-radio retry rates.
# Kept in sync with it by hand; the two filters run in different scripts.
def as_number($v): if ($v | type) == "number" then $v else null end;

def device_stats:
  if (.stats // null) == null then null else
    {
      uptimeSec: as_number(.stats.uptimeSec),
      heartbeatAt: (.stats.lastHeartbeatAt // null),
      cpuPct: as_number(.stats.cpuUtilizationPct),
      memPct: as_number(.stats.memoryUtilizationPct),
      load1: as_number(.stats.loadAverage1Min),
      radios: ((.stats.interfaces.radios // []) | map({
        frequencyGHz: .frequencyGHz,
        txRetriesPct: as_number(.txRetriesPct)
      }))
    }
  end;

{
  detail: (if (.detail // null) == null then null else {
    ports: ((.detail.interfaces.ports // []) | map({
      idx: as_number(.idx),
      state: (if (.state | type) == "string" then .state else "" end),
      connector: (if (.connector | type) == "string" then .connector else "" end),
      speedMbps: as_number(.speedMbps),
      maxSpeedMbps: as_number(.maxSpeedMbps),
      poe: (if (.poe // null) == null then null else {
        enabled: (.poe.enabled // false),
        state: (if (.poe.state | type) == "string" then .poe.state else "" end)
      } end)
    })),
    radios: ((.detail.interfaces.radios // []) | map({
      standard: (if (.wlanStandard | type) == "string" then .wlanStandard else "" end),
      frequencyGHz: .frequencyGHz,
      channelWidthMHz: as_number(.channelWidthMHz),
      channel: as_number(.channel)
    }))
  } end),
  stats: device_stats
}
