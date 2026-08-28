import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The full settings window: every writable setting the daemon can see, not
// just the curated popup set. Same overlay idiom as the clipboard and emoji
// pickers — scrim, centered card, Esc or the scrim to leave — with a tab per
// device and the fine-tuning maps (button assignments, key diversion) that
// would drown the quick panel.
PanelWindow {
  id: root

  property var service: null
  property var anchorItem: null
  property string fontFamily: Style.font.family
  property bool open: false
  property string selectedKey: ""

  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  // Resolved at show() time: the window belongs on the monitor the user is
  // looking at, not on whichever bar instance happens to own it (IPC lands on
  // one instance only, and its screen may be across the room). Held by NAME
  // and re-resolved in the binding — a held ShellScreen object goes stale
  // after a while, nulls the binding, and the window silently migrates back
  // to the owning instance's monitor.
  property string targetScreenName: ""
  screen: {
    if (targetScreenName !== "") {
      var screens = Quickshell.screens
      for (var i = 0; i < screens.length; i++) {
        if (screens[i].name === targetScreenName) return screens[i]
      }
    }
    return anchorWindow ? anchorWindow.screen : null
  }

  visible: open
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  WlrLayershell.namespace: "omarchy-logitech-settings"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore

  // Menu surface tokens, like the clipboard picker — themes that style the
  // menu style this window too.
  readonly property color foreground: Color.menu.text
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color faint: Qt.darker(foreground, 2.2)
  readonly property color urgent: Color.urgent
  readonly property color accent: service && service.accent ? service.accent : Color.foreground

  readonly property var devices: service ? service.detailedDevices : []
  readonly property var current: {
    for (var i = 0; i < devices.length; i++) if (devices[i].key === selectedKey) return devices[i]
    return devices.length > 0 ? devices[0] : null
  }

  function show(key) {
    if (key) selectedKey = key
    targetScreenName = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    if (service) service.refreshDetailed()
    open = true
  }
  function hide() { open = false }
  // refreshDetailed() replaces the model and rebuilds every Repeater, which
  // can leave the Flickable scrolled to wherever the rebuild landed — reset
  // to the top whenever the window opens or the device tab changes.
  onOpenChanged: if (open) Qt.callLater(function () { keys.forceActiveFocus(); flick.contentY = 0 })
  onSelectedKeyChanged: if (flick) flick.contentY = 0
  function toggle(key) { open ? hide() : show(key) }

  function cycleDevice(direction) {
    if (devices.length < 2 || !current) return
    var index = 0
    for (var i = 0; i < devices.length; i++) if (devices[i].key === current.key) index = i
    selectedKey = devices[(index + direction + devices.length) % devices.length].key
  }

  // Rows are grouped by weight: the curated set first, then everything else
  // writable, with read-only values tucked at the bottom for reference.
  function groupOf(device, wanted) {
    var out = []
    if (!device) return out
    for (var i = 0; i < device.controls.length; i++) {
      var control = device.controls[i]
      var group = control.ui === "readonly" ? "info"
        : control.ui === "keymap" ? "keymap"
        : control.advanced ? "tuning" : "controls"
      if (group === wanted) out.push(control)
    }
    return out
  }

  Rectangle {
    anchors.fill: parent
    color: Color.menu.scrim
  }

  MouseArea {
    anchors.fill: parent
    onClicked: root.hide()
  }

  BorderSurface {
    id: card
    width: Math.min(Style.space(560), root.width - Style.gapsOut * 2)
    height: Math.min(cardColumn.implicitHeight + contentTopInset + contentBottomInset,
                     root.height - Style.gapsOut * 4)
    radius: Style.cornerRadius
    anchors.centerIn: parent
    color: Color.menu.background
    borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
    padding: Style.spacing.panelPadding

    MouseArea { anchors.fill: parent; onClicked: {} }

    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) { root.hide(); event.accepted = true }
        else if (event.key === Qt.Key_Tab) { root.cycleDevice(1); event.accepted = true }
        else if (event.key === Qt.Key_Backtab) { root.cycleDevice(-1); event.accepted = true }
      }

      ColumnLayout {
        id: cardColumn
        width: parent.width
        spacing: Style.space(10)

        // --- header: title, device tabs, close --------------------------
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)

          Text {
            text: "󰒓"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
          Text {
            text: "Logitech Settings"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
          Item { Layout.fillWidth: true }
          PanelActionButton {
            iconText: "󰑐"
            tooltipText: "Re-read every setting"
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: !(root.service && root.service.detailLoading)
            onClicked: root.service.refreshDetailed()
          }
          PanelActionButton {
            iconText: "󰅖"
            tooltipText: "Close (Esc)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.hide()
          }
        }

        Row {
          Layout.fillWidth: true
          spacing: Style.space(6)
          visible: root.devices.length > 1

          Repeater {
            model: root.devices
            Rectangle {
              required property var modelData
              readonly property bool active: root.current && root.current.key === modelData.key
              width: tabRow.implicitWidth + Style.space(20)
              height: tabRow.implicitHeight + Style.space(10)
              radius: height / 2
              color: active ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12) : "transparent"
              border.color: active ? root.foreground : root.faint
              border.width: 1

              Row {
                id: tabRow
                anchors.centerIn: parent
                spacing: Style.space(6)
                Text {
                  text: Model.deviceGlyph(parent.parent.modelData)
                  color: parent.parent.active ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  text: parent.parent.modelData.name
                  color: parent.parent.active ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.selectedKey = parent.modelData.key
              }
            }
          }
        }

        Text {
          visible: root.devices.length === 0
          Layout.fillWidth: true
          text: root.service && root.service.detailLoading
            ? "Reading device settings…" : "No Logitech devices found."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
        }

        // --- body --------------------------------------------------------
        Flickable {
          id: flick
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(body.implicitHeight, Style.space(680))
          contentWidth: width
          contentHeight: body.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          // interactive: false — a hidden AsNeeded scrollbar is transparent
          // but still hit-testable, and it sits exactly over the row
          // controls' right edge, silently eating their clicks.
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded; interactive: false }

          Column {
            id: body
            // Keep the rows clear of the scrollbar overlay.
            width: flick.width - Style.spaceReal(10)
            spacing: Style.space(6)

            SectionHeader { title: "Controls"; visible: root.groupOf(root.current, "controls").length > 0 }
            Repeater {
              model: root.groupOf(root.current, "controls")
              SettingRow { required property var modelData; width: body.width; control: modelData }
            }

            SectionHeader { title: "Fine tuning"; visible: root.groupOf(root.current, "tuning").length > 0 }
            Repeater {
              model: root.groupOf(root.current, "tuning")
              SettingRow { required property var modelData; width: body.width; control: modelData }
            }

            Repeater {
              model: root.groupOf(root.current, "keymap")
              KeymapSection { required property var modelData; width: body.width; control: modelData }
            }

            SectionHeader { title: "Device info"; visible: root.groupOf(root.current, "info").length > 0 }
            Repeater {
              model: root.groupOf(root.current, "info")
              RowLayout {
                required property var modelData
                width: body.width
                spacing: Style.space(8)
                Text {
                  text: modelData.label
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Item { Layout.fillWidth: true }
                Text {
                  Layout.maximumWidth: body.width * 0.55
                  text: String(modelData.value)
                  color: root.faint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }
            }
          }
        }

        Text {
          Layout.fillWidth: true
          visible: !!(root.service && (root.service.actionStatus !== "" || root.service.lastError !== ""))
          text: root.service ? (root.service.actionStatus !== "" ? root.service.actionStatus : root.service.lastError) : ""
          color: root.service && root.service.lastError !== "" && root.service.actionStatus === "" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // --- building blocks ------------------------------------------------------

  component SectionHeader: Column {
    property string title: ""
    width: parent ? parent.width : 0
    topPadding: Style.space(8)
    spacing: Style.space(4)
    Text {
      text: parent.title
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1.2
      font.capitalization: Font.AllUppercase
    }
    Rectangle { width: parent.width; height: 1; color: root.faint; opacity: 0.5 }
  }

  // One writable setting: label (plus optional help line) left, the control
  // that fits its kind right.
  component SettingRow: Item {
    id: row
    property var control: null
    readonly property string deviceKey: root.current ? root.current.key : ""
    implicitHeight: Math.max(labels.implicitHeight, Style.space(30)) + Style.space(6)

    Column {
      id: labels
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width * 0.45
      spacing: Style.space(1)
      Text {
        width: parent.width
        text: row.control ? row.control.label : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        visible: !!(row.control && row.control.help)
        width: parent.width
        text: row.control ? row.control.help : ""
        color: root.faint
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    // toggle
    Rectangle {
      visible: !!(row.control && row.control.ui === "toggle")
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(38)
      height: Style.space(20)
      radius: height / 2
      color: row.control && row.control.value
        ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.55) : "transparent"
      border.color: row.control && row.control.value ? root.accent : root.dim
      border.width: 1

      Rectangle {
        width: parent.height - Style.space(6)
        height: width
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        x: row.control && row.control.value ? parent.width - width - Style.space(3) : Style.space(3)
        color: row.control && row.control.value ? root.foreground : root.dim
        Behavior on x { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.service.toggleDetail(row.deviceKey, row.control.name)
      }
    }

    // choice / equalizer preset cycler
    ChoiceCycler {
      visible: !!(row.control && (row.control.ui === "choice" || row.control.ui === "equalizer"))
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: {
        if (!row.control) return ""
        if (row.control.ui === "equalizer") return "Preset…"
        return String(row.control.value)
      }
      onCycle: function (direction) {
        if (row.control.ui === "equalizer") {
          var presets = row.control.presets || []
          if (presets.length === 0) return
          // Cycle through presets from wherever the panel last left it.
          var index = Math.max(0, presets.indexOf(root._eqCursor))
          index = (index + direction + presets.length) % presets.length
          root._eqCursor = presets[index]
          root.service.setEqualizer(row.deviceKey, presets[index])
        } else {
          root.service.cycleDetailChoice(row.deviceKey, row.control.name, direction)
        }
      }
    }

    // slider
    Row {
      visible: !!(row.control && row.control.ui === "slider")
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Item {
        id: track
        width: Style.space(150)
        height: Style.space(20)
        anchors.verticalCenter: parent.verticalCenter
        readonly property real min: row.control ? Number(row.control.min || 0) : 0
        readonly property real max: row.control ? Number(row.control.max || 100) : 100
        property real localValue: -1
        readonly property real shown: localValue >= 0 ? localValue
          : (row.control ? Number(row.control.value || 0) : 0)
        readonly property real fraction: max > min ? Math.max(0, Math.min(1, (shown - min) / (max - min))) : 0

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          height: Style.space(5)
          radius: height / 2
          color: root.dim
          opacity: 0.35
        }
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(height, parent.width * parent.fraction)
          height: Style.space(5)
          radius: height / 2
          color: root.accent
        }
        Rectangle {
          x: Math.max(0, Math.min(parent.width - width, parent.width * parent.fraction - width / 2))
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(12)
          height: width
          radius: width / 2
          color: root.foreground
        }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          function valueAt(x) {
            var fraction = Math.max(0, Math.min(1, x / track.width))
            return Model.snapToStep(row.control, track.min + fraction * (track.max - track.min))
          }
          onPressed: function (mouse) { track.localValue = valueAt(mouse.x) }
          onPositionChanged: function (mouse) { if (pressed) track.localValue = valueAt(mouse.x) }
          onReleased: function (mouse) {
            root.service.setDetail(row.deviceKey, row.control.name, valueAt(mouse.x))
            track.localValue = -1
          }
        }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(52)
        horizontalAlignment: Text.AlignRight
        text: row.control ? Math.round(track.shown) + String(row.control.unit || "") : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  property string _eqCursor: "flat"

  // ‹ value › — cycles through a closed set of options.
  component ChoiceCycler: Row {
    id: cycler
    property string text: ""
    signal cycle(int direction)
    spacing: Style.space(4)

    PanelActionButton {
      iconText: "󰅁"
      foreground: root.dim
      fontFamily: root.fontFamily
      onClicked: cycler.cycle(-1)
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(110)
      horizontalAlignment: Text.AlignHCenter
      text: cycler.text
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideMiddle
    }
    PanelActionButton {
      iconText: "󰅂"
      foreground: root.dim
      fontFamily: root.fontFamily
      onClicked: cycler.cycle(1)
    }
  }

  // A per-key map (button assignments, diversion): its own header plus one
  // cycler row per key.
  component KeymapSection: Column {
    id: keymap
    property var control: null
    readonly property string deviceKey: root.current ? root.current.key : ""
    spacing: Style.space(2)

    SectionHeader { title: keymap.control ? keymap.control.label : "" }

    Text {
      visible: !!(keymap.control && keymap.control.help)
      width: parent.width
      text: keymap.control ? keymap.control.help : ""
      color: root.faint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Repeater {
      model: keymap.control ? keymap.control.items : []
      Item {
        required property var modelData
        width: keymap.width
        implicitHeight: Style.space(30)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: modelData.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        ChoiceCycler {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: {
            var options = modelData.choices || []
            for (var i = 0; i < options.length; i++) {
              if (options[i].id === modelData.value) return options[i].label
            }
            return modelData.value === null ? "—" : String(modelData.value)
          }
          onCycle: function (direction) {
            var options = modelData.choices || []
            if (options.length === 0) return
            var index = 0
            for (var i = 0; i < options.length; i++) if (options[i].id === modelData.value) index = i
            index = (index + direction + options.length) % options.length
            root.service.setMapItem(keymap.deviceKey, keymap.control.name, modelData.id, options[index].id)
          }
        }
      }
    }
  }
}
