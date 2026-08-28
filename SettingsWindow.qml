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

  // Values crossing a Repeater's modelData boundary arrive as QVariantList,
  // not JS Array: length and indexing work, Array.isArray and join do not.
  function toArray(list) {
    var out = []
    if (list && list.length !== undefined) {
      for (var i = 0; i < list.length; i++) out.push(list[i])
    }
    return out
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
        : control.ui === "equalizer" ? "equalizer"
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
      // BorderSurface does not inset children itself; without these margins
      // the text sits on the border.
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
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
              model: root.groupOf(root.current, "equalizer")
              EqualizerSection { required property var modelData; width: body.width; control: modelData }
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

    // choice cycler
    ChoiceCycler {
      visible: !!(row.control && row.control.ui === "choice")
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: row.control ? String(row.control.value) : ""
      onCycle: function (direction) {
        root.service.cycleDetailChoice(row.deviceKey, row.control.name, direction)
      }
    }

    // slider
    Row {
      visible: !!(row.control && row.control.ui === "slider")
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      HSlider {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        min: row.control ? Number(row.control.min || 0) : 0
        max: row.control ? Number(row.control.max || 100) : 100
        value: row.control ? Number(row.control.value || 0) : 0
        snap: function (raw) { return Model.snapToStep(row.control, raw) }
        onCommitted: function (v) { root.service.setDetail(row.deviceKey, row.control.name, v) }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(64)
        horizontalAlignment: Text.AlignRight
        text: row.control ? Math.round(track.shown) + String(row.control.unit || "") : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  // Draggable horizontal slider: local value while dragging, committed(v) on
  // release. `snap` maps a raw value onto the control's real steps.
  component HSlider: Item {
    id: slider
    property real min: 0
    property real max: 100
    property real value: 0
    property var snap: function (raw) { return Math.round(raw) }
    signal committed(real v)

    width: Style.space(150)
    height: Style.space(20)
    property real localValue: -3e38
    readonly property real shown: localValue > -3e38 ? localValue : value
    readonly property real fraction: max > min ? Math.max(0, Math.min(1, (shown - min) / (max - min))) : 0

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      height: Style.space(5)
      radius: height / 2
      color: root.dim
      opacity: 0.35
    }
    // For a bipolar range the fill grows from the zero point, so a flat EQ
    // band reads as neutral rather than half full.
    readonly property real zeroFraction: min < 0 && max > 0 ? (0 - min) / (max - min) : 0
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      x: parent.width * Math.min(slider.zeroFraction, slider.fraction)
      width: Math.max(Style.space(3), parent.width * Math.abs(slider.fraction - slider.zeroFraction))
      height: Style.space(5)
      radius: height / 2
      color: root.accent
    }
    Rectangle {
      x: Math.max(0, Math.min(parent.width - width, parent.width * slider.fraction - width / 2))
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
        var fraction = Math.max(0, Math.min(1, x / slider.width))
        return slider.snap(slider.min + fraction * (slider.max - slider.min))
      }
      onPressed: function (mouse) { slider.localValue = valueAt(mouse.x) }
      onPositionChanged: function (mouse) { if (pressed) slider.localValue = valueAt(mouse.x) }
      onReleased: function (mouse) {
        slider.committed(valueAt(mouse.x))
        slider.localValue = -3e38
      }
    }
  }

  // The equalizer gets a full section: preset cycler up top, then one slider
  // per band so a custom curve is a drag away. A curve matching no preset
  // shows as Custom.
  component EqualizerSection: Column {
    id: eq
    property var control: null
    readonly property string deviceKey: root.current ? root.current.key : ""
    readonly property var curve: root.toArray(control ? control.value : null)
    spacing: Style.space(4)

    function presetName() {
      var values = eq.control ? eq.control.presetValues : null
      if (!values) return "—"
      var flat = eq.curve.join(",")
      var names = root.toArray(eq.control.presets)
      for (var i = 0; i < names.length; i++) {
        if (root.toArray(values[names[i]]).join(",") === flat) return names[i]
      }
      return "custom"
    }

    SectionHeader { title: eq.control ? eq.control.label : "Equalizer" }


    Item {
      width: parent.width
      implicitHeight: Style.space(30)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "Preset"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      ChoiceCycler {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: eq.presetName()
        onCycle: function (direction) {
          var names = root.toArray(eq.control ? eq.control.presets : null)
          if (names.length === 0) return
          var index = names.indexOf(eq.presetName())
          index = index < 0 ? (direction > 0 ? 0 : names.length - 1)
            : (index + direction + names.length) % names.length
          root.service.setEqualizer(eq.deviceKey, names[index])
        }
      }
    }

    Repeater {
      model: eq.control ? (eq.control.bands || []) : []
      Item {
        id: bandRow
        required property var modelData
        required property int index
        width: eq.width
        implicitHeight: Style.space(26)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: bandRow.modelData
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          HSlider {
            id: bandSlider
            anchors.verticalCenter: parent.verticalCenter
            min: eq.control ? Number(eq.control.min) : -12
            max: eq.control ? Number(eq.control.max) : 12
            value: eq.curve.length > bandRow.index ? Number(eq.curve[bandRow.index]) : 0
            onCommitted: function (v) {
              // Band name ("114Hz") — the daemon matches it case-insensitively.
              root.service.setEqualizerBand(eq.deviceKey, bandRow.index, bandRow.modelData, v)
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(64)
            horizontalAlignment: Text.AlignRight
            text: (bandSlider.shown > 0 ? "+" : "") + Math.round(bandSlider.shown) + " dB"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }

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
