pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// One UniFi device in the list: role glyph, name and state, model and address,
// and a firmware notice when an update waits. Clicking the header expands
// per-device detail (load, ports, radios) underneath. The gateway
// additionally carries its statistics block.
//
// `host` is the widget root, which owns the formatting helpers, the theme
// colours and the expansion state; the row itself keeps no state beyond what
// it is given.
//
// The root is an Item rather than a Column so the header MouseArea can sit
// beside the content instead of inside the positioned layout — the same
// shape as the shell's own network panel rows.
Item {
  id: row

  required property var device
  required property var host

  // Set only on the gateway row; null everywhere else.
  property var gatewayStats: null
  property var rateHistory: []
  property var rateReport: null
  property var wanState: null
  // Devices-tab gateway rows set this: the WAN address block appears only
  // once the row is clicked open, like the ports below it — never on the
  // Overview row, which keeps the graphs and hides the public address.
  property bool showWanOnExpand: false
  // The Overview gateway row hides the role glyph so the text takes the full
  // width; the Devices list keeps it to tell roles apart at a glance.
  property bool showGlyph: true
  property bool expanded: false

  height: body.implicitHeight

  Column {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: Style.space(6)

    Row {
      id: headerRow
      width: parent.width
      spacing: Style.space(10)

      Text {

        textFormat: Text.PlainText
        id: glyph
        visible: row.showGlyph
        anchors.verticalCenter: parent.verticalCenter
        width: row.showGlyph ? Style.space(22) : 0
        horizontalAlignment: Text.AlignHCenter
        text: row.host.kindGlyph(row.device.kind)
        color: row.host.bucketColor(row.device.bucket)
        font.family: Style.font.family
        font.pixelSize: Style.font.body + 4
      }

      Column {
        width: parent.width - (row.showGlyph ? glyph.width + Style.space(10) : 0)
        spacing: Style.space(2)

        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {

            textFormat: Text.PlainText
            width: parent.width - stateText.implicitWidth - Style.space(8)
            elide: Text.ElideRight
            text: row.device.name
            color: Color.popups.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {

            textFormat: Text.PlainText
            id: stateText
            text: row.host.stateLabel(row.device.state)
            color: row.host.bucketColor(row.device.bucket)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {

            textFormat: Text.PlainText
            width: parent.width - clientText.implicitWidth - Style.space(8)
            elide: Text.ElideRight
            text: [row.device.model, row.device.ip,
                 row.device.clients > 0 ? row.device.clients + " clients" : ""]
            .filter(function(s) { return s !== "" }).join("  ·  ")
            color: row.host.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {

            textFormat: Text.PlainText
            id: clientText
          text: row.device.firmwareUpdatable ? "Update available" : ""
          // Actionable, so it takes the accent rather than dim detail text.
          color: row.device.firmwareUpdatable ? Color.accent : row.host.detailColor
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    GatewayStats {
      // Indented under the name, past the glyph column (flush on rows
      // without the glyph).
      x: row.showGlyph ? Style.space(22) + Style.space(10) : 0
      width: parent.width - x
      visible: row.gatewayStats !== null
      host: row.host
      latest: row.gatewayStats
      history: row.rateHistory
      report: row.rateReport
      wan: null
      showGraphs: true
      showWan: false
    }

    GatewayStats {
      // The Devices-tab gateway detail: addresses and ISP, no graphs.
      // Visible only once the row is clicked open.
      x: row.showGlyph ? Style.space(22) + Style.space(10) : 0
      width: parent.width - x
      visible: row.showWanOnExpand && row.expanded && row.wanState !== null
      host: row.host
      latest: null
      history: []
      report: null
      wan: row.wanState
      showGraphs: false
      showWan: true
    }

    DeviceDetail {
      // Indented with the statistics block (flush on rows without the glyph).
      x: row.showGlyph ? Style.space(22) + Style.space(10) : 0
      width: parent.width - x
      visible: row.expanded
      host: row.host
      bundle: row.host.deviceBundle(String(row.device.id))
      // The gateway row already shows its figures above.
      showStats: row.gatewayStats === null
      loading: row.host.deviceLoading(String(row.device.id))
      loadError: row.host.deviceBundleError(String(row.device.id))
    }

    // A rule keeps what follows the row (the graph's caption, the detail
    // block, the device list) from reading as part of the row above it.
    PanelSeparator {
      visible: row.gatewayStats !== null || row.expanded
      width: parent.width
      foreground: Color.popups.text
    }
  }

  // Clicks only: drags still reach the ListView because the flickable
  // steals the gesture, like the shell's own panel rows.
  MouseArea {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    height: headerRow.height
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton
    cursorShape: Qt.PointingHandCursor
    onClicked: row.host.toggleDeviceExpand(String(row.device.id))
  }
}
