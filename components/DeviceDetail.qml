pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// Expanded detail under a device row: load figures, switch ports and AP
// radios. `bundle` is {detail, stats} from unifi-device — either side null
// when its request failed. `showStats` hides the figures when the row above
// already shows them (the gateway's own statistics block).
//
// All controller data renders as PlainText, like the rows above.
Column {
  id: detail

  required property var host
  property var bundle: null
  property bool showStats: true
  property bool loading: false
  property string loadError: ""

  spacing: Style.space(4)

  function formatPct(value) {
    if (value === null || value === undefined || !isFinite(value)) return "--"
    return Math.round(value) + "%"
  }

  function formatUptime(seconds) {
    if (seconds === null || seconds === undefined || !isFinite(seconds)) return "--"
    var days = Math.floor(seconds / 86400)
    var hours = Math.floor((seconds % 86400) / 3600)
    var minutes = Math.floor((seconds % 3600) / 60)
    if (days > 0) return days + "d " + hours + "h"
    if (hours > 0) return hours + "h " + minutes + "m"
    return minutes + "m"
  }

  function formatSpeed(mbps) {
    if (mbps === null || mbps === undefined || !isFinite(mbps)) return ""
    if (mbps >= 1000) {
      var gbps = mbps / 1000
      return (Number.isInteger(gbps) ? gbps : gbps.toFixed(1)) + " Gbit/s"
    }
    return Math.round(mbps) + " Mbit/s"
  }

  function portStateLabel(state) {
    switch (state) {
      case "UP": return "Up"
      case "DOWN": return "Down"
      case "UNKNOWN": return "Unknown"
      default: return state ? String(state) : "Unknown"
    }
  }

  function connectorLabel(connector) {
    switch (connector) {
      case "SFP": return "SFP"
      case "SFPPLUS": return "SFP+"
      case "SFP28": return "SFP28"
      case "QSFP28": return "QSFP28"
      default: return ""
    }
  }

  function portDetail(port) {
    var parts = [portStateLabel(port.state)]
    if (port.state === "UP") {
      var speed = formatSpeed(port.speedMbps)
      if (speed !== "") parts.push(speed)
    }
    if (port.poe && port.poe.state === "UP") parts.push("PoE")
    return parts.join("  ·  ")
  }

  function retriesFor(frequencyGHz) {
    var radios = (detail.bundle && detail.bundle.stats && detail.bundle.stats.radios)
      ? detail.bundle.stats.radios : []
    for (var i = 0; i < radios.length; i++) {
      if (radios[i].frequencyGHz === frequencyGHz) return radios[i].txRetriesPct
    }
    return null
  }

  function radioDetail(radio) {
    var parts = []
    if (radio.standard !== "") parts.push(radio.standard)
    if (radio.channel !== null && radio.channel !== undefined) parts.push("ch " + radio.channel)
    if (radio.channelWidthMHz !== null && radio.channelWidthMHz !== undefined)
      parts.push(radio.channelWidthMHz + " MHz")
    return parts.join("  ·  ")
  }

  // Retry rate for one radio, or "" when the controller sent none.
  function retriesText(frequencyGHz) {
    var retries = retriesFor(frequencyGHz)
    if (retries === null || retries === undefined || !isFinite(retries)) return ""
    return (Math.round(retries * 10) / 10) + "% retries"
  }

  // Past this sustained retry rate the band is struggling and the figure
  // alarms in the theme's urgent token.
  readonly property real retryAlarmPct: 10

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: detail.loading && !detail.bundle
    text: "Loading…"
    color: detail.host.detailColor
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    visible: detail.loadError !== "" && !detail.bundle
    text: detail.loadError
    color: Color.urgent
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    elide: Text.ElideRight
    visible: detail.showStats && detail.bundle && detail.bundle.stats !== null
    text: {
      var st = detail.bundle ? detail.bundle.stats : null
      if (!st) return ""
      return "CPU " + detail.formatPct(st.cpuPct)
        + "  ·  Memory " + detail.formatPct(st.memPct)
        + "  ·  Load " + (st.load1 !== null && st.load1 !== undefined ? st.load1.toFixed(2) : "--")
        + "  ·  Up " + detail.formatUptime(st.uptimeSec)
    }
    color: detail.host.detailColor
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: (detail.bundle && detail.bundle.detail && detail.bundle.detail.ports)
      ? detail.bundle.detail.ports : []

    Row {
      id: portRow
      required property var modelData
      width: parent.width
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        id: portName
        width: parent.width - portDetail.implicitWidth - Style.space(8)
        elide: Text.ElideRight
        text: {
          var name = portRow.modelData.idx !== null && portRow.modelData.idx !== undefined
            ? "Port " + portRow.modelData.idx : "Port ?"
          var connector = detail.connectorLabel(portRow.modelData.connector)
          return connector !== "" ? name + "  ·  " + connector : name
        }
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        id: portDetail
        text: detail.portDetail(portRow.modelData)
        color: detail.host.detailColor
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  Repeater {
    model: (detail.bundle && detail.bundle.detail && detail.bundle.detail.radios)
      ? detail.bundle.detail.radios : []

    Row {
      id: radioRow
      required property var modelData
      width: parent.width
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        id: radioName
        width: parent.width - radioInfo.implicitWidth - Style.space(8)
          - (radioRetries.visible ? radioRetries.implicitWidth + Style.space(8) : 0)
        elide: Text.ElideRight
        text: {
          var freq = radioRow.modelData.frequencyGHz
          return (freq !== null && freq !== undefined && isFinite(freq)) ? freq + " GHz" : "Radio"
        }
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        id: radioInfo
        text: detail.radioDetail(radioRow.modelData)
        color: detail.host.detailColor
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Text {
        textFormat: Text.PlainText
        id: radioRetries
        visible: text !== ""
        text: {
          var retries = detail.retriesText(radioRow.modelData.frequencyGHz)
          return retries !== "" ? "·  " + retries : ""
        }
        color: {
          var rate = detail.retriesFor(radioRow.modelData.frequencyGHz)
          return (rate !== null && rate !== undefined && rate >= detail.retryAlarmPct)
            ? Color.urgent : detail.host.detailColor
        }
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
