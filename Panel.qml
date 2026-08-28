import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar button plus a popup for every connected Logitech device: battery at a
// glance, and the controls that are actually worth reaching for — DPI, scroll
// behavior, keyboard brightness and lighting, headset sidetone and EQ.
Panel {
  id: root
  moduleName: "io.github.rvcabc.logitech"
  ipcTarget: "io.github.rvcabc.logitech"
  manageIpc: false

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/$/, "")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var devices: logitech.devices
  readonly property bool showBatteryText: setting("showBatteryText", true) !== false

  // How the bar renders each device's charge: "percent" (a number), "icon"
  // (the nerd-font battery ramp), "bar" (a drawn level bar), "battery" (a
  // drawn outline with one segment per quarter), or "off". The pre-1.1
  // showBatteryText toggle is honored when the style was never changed from
  // its default, so old configs that hid the text keep hiding it.
  readonly property string batteryStyle: {
    var style = String(setting("batteryStyle", "Percent")).toLowerCase()
    if (!showBatteryText && style === "percent") return "off"
    return style
  }
  // "Weakest device" keeps the old single-entry bar; "All devices" gives every
  // connected device its own glyph and charge indicator.
  readonly property bool showAllDevices:
    String(setting("batteryScope", "Weakest device")).toLowerCase().indexOf("all") === 0

  // What the bar button actually renders: one cell per device, or a single
  // weakest-battery cell. Always at least one cell so the widget never
  // vanishes from the bar.
  readonly property var barCells: {
    if (showAllDevices && devices.length > 0) return devices
    if (weakest) return [weakest]
    return devices.length > 0 ? [devices[0]] : [null]
  }

  // --- cursor -------------------------------------------------------------
  // One flat list of navigable rows across every device, so up/down walks the
  // whole panel and each row knows its own index without counting delegates.
  readonly property var rows: {
    var out = []
    for (var i = 0; i < devices.length; i++) {
      var device = devices[i]
      for (var j = 0; j < device.controls.length; j++) {
        out.push({ key: device.key, name: device.controls[j].name, ui: device.controls[j].ui })
      }
      if (device.rgb && device.rgb.zones && device.rgb.zones.length > 0) {
        out.push({ key: device.key, name: "__lighting", ui: "lighting" })
      }
    }
    return out
  }

  property int selectedIndex: 0
  property bool cursorActive: false

  function rowIndex(key, name) {
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].key === key && rows[i].name === name) return i
    }
    return -1
  }

  function hasCursorAt(key, name) {
    return cursorActive && selectedIndex === rowIndex(key, name)
  }

  function setCursor(key, name) {
    cursorActive = true
    var index = rowIndex(key, name)
    if (index >= 0) selectedIndex = index
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (rows.length === 0) return
    if (dy !== 0) {
      selectedIndex = Math.max(0, Math.min(rows.length - 1, selectedIndex + dy))
      scrollCursorIntoView()
      return
    }
    if (dx !== 0) adjustSelected(dx)
  }

  function selectedRow() {
    if (selectedIndex < 0 || selectedIndex >= rows.length) return null
    return rows[selectedIndex]
  }

  // Left/right means "more or less of this", whatever the row happens to be —
  // except where the change is disruptive (host switching drops the device off
  // this machine), which takes a deliberate Enter instead.
  function adjustSelected(direction) {
    var row = selectedRow()
    if (!row) return
    var control = logitech.controlFor(row.key, row.name)
    if (control && control.disruptive) return
    if (row.ui === "slider") logitech.nudgeSlider(row.key, row.name, direction)
    else if (row.ui === "choice") logitech.cycleChoice(row.key, row.name, direction)
    else if (row.ui === "toggle") logitech.toggleControl(row.key, row.name)
    else if (row.ui === "equalizer") cycleEqualizer(row.key, direction)
    else if (row.ui === "lighting") cycleLighting(row.key, direction)
  }

  function activateSelected() {
    var row = selectedRow()
    if (!row) return
    if (row.ui === "toggle") logitech.toggleControl(row.key, row.name)
    else if (row.ui === "choice") logitech.cycleChoice(row.key, row.name, 1)
    else if (row.ui === "lighting") logitech.matchTheme()
    else if (row.ui === "equalizer") cycleEqualizer(row.key, 1)
  }

  function cycleEqualizer(key, direction) {
    var control = logitech.controlFor(key, "equalizer")
    if (!control || !control.presets || control.presets.length === 0) return
    var index = control.presets.indexOf(eqPreset)
    if (index < 0) index = 0
    index = (index + (direction < 0 ? -1 : 1) + control.presets.length) % control.presets.length
    eqPreset = control.presets[index]
    logitech.setEqualizer(key, eqPreset)
  }

  function cycleLighting(key, direction) {
    var device = logitech.deviceFor(key)
    if (!device || !device.rgb || device.rgb.zones.length === 0) return
    var effects = device.rgb.zones[0].effects
    var index = 0
    for (var i = 0; i < effects.length; i++) if (effects[i].slug === lightingEffect) index = i
    index = (index + (direction < 0 ? -1 : 1) + effects.length) % effects.length
    lightingEffect = effects[index].slug
    logitech.setLighting(key, lightingEffect, lightingColor)
  }

  // The panel remembers the last lighting choice so the swatches and effect
  // chips agree with each other; the device itself only stores the result.
  property string lightingEffect: "static"
  property string lightingColor: ""
  property string eqPreset: "flat"

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function () {
      if (!item) return
      var margin = Style.space(8)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin) {
        panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
      }
    })
  }

  function scrollCursorIntoView() {
    var row = selectedRow()
    if (!row) return
    var item = rowItems[row.key + "/" + row.name]
    if (item) scrollItemIntoView(item)
  }

  // Row delegates register themselves here so the cursor can scroll to them.
  property var rowItems: ({})
  function registerRow(key, name, item) { rowItems[key + "/" + name] = item }

  // --- bar button ---------------------------------------------------------

  readonly property var weakest: logitech.weakest
  readonly property string barGlyph: weakest ? Model.deviceGlyph(weakest) : "󰍽"
  readonly property color barIconColor: {
    if (!logitech.connected || devices.length === 0) return Qt.darker(barForeground, 1.6)
    if (logitech.anyLow) return bar ? bar.urgent : Color.urgent
    return barForeground
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    if (panelFlick) panelFlick.contentY = 0
    logitech.refresh(false)
    logitech.refreshAccent()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: logitech
    settings: root.settings
    pluginDir: root.pluginDir
  }

  SettingsWindow {
    id: settingsWindow
    service: logitech
    anchorItem: button
    fontFamily: root.fontFamily
  }

  function openSettings() {
    root.close()
    settingsWindow.show("")
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { logitech.refresh(true); return "ok" }
    function theme(): string { logitech.matchTheme(); return "ok" }
    function settings(): string {
      if (settingsWindow.open) settingsWindow.hide()
      else root.openSettings()
      return "ok"
    }
    function status(): string { return JSON.stringify(logitech.devices) }
  }

  // Color for one bar cell: the button-wide states (opened, disconnected)
  // win, then a low battery goes urgent per device.
  function cellColor(device) {
    if (root.opened) return root.bar ? root.bar.urgent : Color.urgent
    if (!logitech.connected || root.devices.length === 0) return Qt.darker(root.barForeground, 1.6)
    if (device && device.battery && device.battery.low) return root.bar ? root.bar.urgent : Color.urgent
    return root.barForeground
  }

  readonly property bool verticalBar: bar ? bar.vertical : false

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Vertical bars keep the old single text label; horizontal bars render
    // one cell per device below, sized through fixedWidth so the bar still
    // lays the whole thing out as one widget (see #2).
    labelVisible: root.verticalBar
    hasVisualContent: true
    text: root.barGlyph + (root.batteryStyle !== "off" && root.weakest
      ? " " + Model.batteryText(root.weakest.battery) : "")
    fixedWidth: root.verticalBar ? -1 : cellRow.implicitWidth + button.scaledHorizontalMargin * 2
    foreground: root.barIconColor
    active: root.opened
    dimmed: !logitech.connected || root.devices.length === 0
    tooltipText: Model.barTooltip(root.devices, logitech.connected, logitech.lastError)

    Row {
      id: cellRow
      visible: !root.verticalBar
      anchors.centerIn: parent
      spacing: Style.spaceReal(9)

      Repeater {
        model: root.verticalBar ? [] : root.barCells

        Row {
          id: cell
          required property var modelData
          readonly property var battery: modelData ? modelData.battery : null
          readonly property color tint: root.cellColor(modelData)
          // Hide the indicator when there is nothing to say: style off, no
          // battery reporting, or no usable level for the drawn styles.
          readonly property bool hasLevel: !!battery
            && battery.level !== null && battery.level !== undefined
          spacing: Style.spaceReal(4)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: modelData ? Model.deviceGlyph(modelData) : "󰍽"
            textFormat: Text.PlainText
            color: cell.tint
            font.family: button.fontFamily
            font.pixelSize: button.fontSize
            renderType: Text.NativeRendering
          }

          // A charging device never looks like a dying one: the icon style
          // has its own charging ramp, the drawn styles get a bolt.
          Text {
            visible: cell.battery && cell.battery.charging
              && (root.batteryStyle === "bar" || root.batteryStyle === "battery")
            anchors.verticalCenter: parent.verticalCenter
            text: "󱐋"
            color: cell.tint
            font.family: button.fontFamily
            font.pixelSize: Style.font.bodySmall
            renderType: Text.NativeRendering
          }

          Text {
            visible: root.batteryStyle === "percent" && !!cell.battery
            anchors.verticalCenter: parent.verticalCenter
            text: Model.batteryText(cell.battery)
            textFormat: Text.PlainText
            color: cell.tint
            font.family: button.fontFamily
            font.pixelSize: button.fontSize
            renderType: Text.NativeRendering
          }

          Text {
            visible: root.batteryStyle === "icon" && !!cell.battery
            anchors.verticalCenter: parent.verticalCenter
            text: Model.batteryGlyph(cell.battery)
            textFormat: Text.PlainText
            color: cell.tint
            font.family: button.fontFamily
            font.pixelSize: button.fontSize
            renderType: Text.NativeRendering
          }

          // Level bar: a rounded track with the charge as its fill.
          Item {
            visible: root.batteryStyle === "bar" && cell.hasLevel
            anchors.verticalCenter: parent.verticalCenter
            width: Style.spaceReal(24)
            height: Style.spaceReal(6)

            Rectangle {
              anchors.fill: parent
              radius: height / 2
              color: cell.tint
              opacity: 0.25
            }
            Rectangle {
              width: Math.max(height, parent.width * Model.batteryFraction(cell.battery))
              height: parent.height
              radius: height / 2
              color: cell.tint
            }
          }

          // Battery outline with one segment lit per quarter crossed.
          Row {
            visible: root.batteryStyle === "battery" && cell.hasLevel
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            Rectangle {
              width: Style.spaceReal(21)
              height: Style.spaceReal(11)
              radius: Style.spaceReal(2)
              color: "transparent"
              border.color: cell.tint
              border.width: 1

              Row {
                anchors.fill: parent
                anchors.margins: Style.spaceReal(2)
                spacing: Style.spaceReal(1)

                Repeater {
                  model: 4
                  Rectangle {
                    required property int index
                    width: (parent.width - Style.spaceReal(1) * 3) / 4
                    height: parent.height
                    radius: 1
                    color: cell.tint
                    opacity: index < Model.batterySegments(cell.battery) ? 1 : 0.15
                  }
                }
              }
            }
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.spaceReal(2)
              height: Style.spaceReal(5)
              color: cell.tint
            }
          }
        }
      }
    }

    onPressed: function (mouseButton) {
      if (mouseButton === Qt.RightButton) { logitech.matchTheme(); return }
      if (mouseButton === Qt.MiddleButton) { logitech.refresh(true); return }
      root.toggle()
    }

    // Scrolling over the bar button rides the keyboard's backlight, which is
    // the one control worth having without opening anything.
    onWheelMoved: function (delta) {
      for (var i = 0; i < root.devices.length; i++) {
        var control = logitech.controlFor(root.devices[i].key, "brightness_control")
        if (control) {
          logitech.nudgeSlider(root.devices[i].key, "brightness_control", delta > 0 ? 1 : -1)
          return
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    // Three devices with lighting run tall; the helper still clamps this to
    // whatever the screen actually has.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(1180))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelected()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        if (t === "r" || t === "R") logitech.refresh(true)
        else if (t === "t" || t === "T") logitech.matchTheme()
        else if (t === "s" || t === "S") root.openSettings()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "Logitech"
            meta: {
              if (!logitech.connected) return "Starting device daemon…"
              if (root.devices.length === 0) return "No devices connected"
              var count = root.devices.length + (root.devices.length === 1 ? " device" : " devices")
              return root.weakest ? count + " · lowest " + Model.batteryText(root.weakest.battery) : count
            }
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: logitech.connected ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: root.barGlyph
                textFormat: Text.PlainText
                color: logitech.anyLow ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Row {
                spacing: Style.space(2)
                PanelActionButton {
                  iconText: "󰒓"
                  tooltipText: "All settings (S)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.openSettings()
                }
                PanelActionButton {
                  iconText: "󰑐"
                  tooltipText: "Rescan devices"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !logitech.busy
                  onClicked: logitech.refresh(true)
                }
              }
            }
          }

          Text {
            visible: logitech.actionStatus !== "" || logitech.lastError !== ""
            width: parent.width
            text: logitech.actionStatus !== "" ? logitech.actionStatus : logitech.lastError
            textFormat: Text.PlainText
            color: logitech.lastError !== "" && logitech.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: logitech.connected && root.devices.length === 0
            width: parent.width
            text: "No Logitech devices found.\nPlug one in, or switch a wireless device on."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.devices
            DeviceSection {
              required property var modelData
              width: column.width
              device: modelData
            }
          }
        }
      }
    }
  }

  // --- device section -----------------------------------------------------

  component DeviceSection: Column {
    id: section
    property var device: null
    readonly property var battery: device ? device.battery : null

    spacing: Style.space(8)

    Item { width: 1; height: Style.space(2) }

    RowLayout {
      width: parent.width
      spacing: Style.space(8)

      Text {
        text: Model.deviceGlyph(section.device)
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: section.device ? section.device.name : ""
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: section.device ? (section.device.via === "USB" ? "USB" : section.device.via) : ""
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        visible: !!section.battery
        text: Model.batteryGlyph(section.battery)
        textFormat: Text.PlainText
        color: section.battery && section.battery.low ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        visible: !!section.battery
        text: Model.batteryText(section.battery)
        textFormat: Text.PlainText
        color: section.battery && section.battery.low ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
      }
    }

    Repeater {
      model: section.device ? section.device.controls : []
      ControlRow {
        required property var modelData
        width: section.width
        deviceKey: section.device.key
        control: modelData
      }
    }

    LightingRow {
      visible: !!(section.device && section.device.rgb && section.device.rgb.zones.length > 0)
      width: section.width
      device: section.device
    }

    PanelSeparator {
      width: section.width
      foreground: root.foreground
      visible: root.devices.length > 1 && section.device
        && root.devices[root.devices.length - 1].key !== section.device.key
    }
  }

  // --- control rows -------------------------------------------------------

  component ControlRow: CursorSurface {
    id: row
    property string deviceKey: ""
    property var control: null
    readonly property string controlName: control ? control.name : ""

    hasCursor: root.hasCursorAt(deviceKey, controlName)
    foreground: root.foreground
    implicitHeight: body.implicitHeight + Style.spacing.rowPaddingX

    Component.onCompleted: root.registerRow(deviceKey, controlName, row)

    // Hover moves the cursor; clicking the row flips a toggle. Choices are left
    // to their own chips — a stray click on the "Connected to" row would
    // otherwise hand the mouse to another machine. Wheel events are left alone
    // so scrolling past a row scrolls the panel instead of changing a setting.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton
      cursorShape: row.control && row.control.ui === "toggle" ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: root.setCursor(row.deviceKey, row.controlName)
      onClicked: {
        if (row.control && row.control.ui === "toggle") {
          logitech.toggleControl(row.deviceKey, row.controlName)
        }
      }
    }

    ColumnLayout {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(4)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          visible: !!(row.control && row.control.icon)
          text: row.control ? row.control.icon : ""
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          Layout.fillWidth: true
          text: row.control ? row.control.label : ""
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        // Sliders and choices show their value here; toggles get a switch.
        Text {
          visible: !!row.control && row.control.ui !== "toggle" && row.control.ui !== "equalizer"
          text: Model.controlValueText(row.control)
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        ToggleSwitch {
          visible: !!row.control && row.control.ui === "toggle"
          checked: !!(row.control && row.control.value)
          hasCursor: row.hasCursor
          foreground: root.foreground
          onHovered: function (on) { if (on) root.setCursor(row.deviceKey, row.controlName) }
          onToggled: logitech.toggleControl(row.deviceKey, row.controlName)
        }
      }

      PanelSlider {
        visible: !!row.control && row.control.ui === "slider"
        Layout.fillWidth: true
        bar: root.bar
        minimum: row.control && row.control.ui === "slider" ? Number(row.control.min) : 0
        maximum: row.control && row.control.ui === "slider" ? Number(row.control.max) : 100
        step: row.control && row.control.ui === "slider" ? Number(row.control.step) : 1
        integer: true
        value: row.control && row.control.ui === "slider" ? Number(row.control.value) : 0
        onMoved: function (v) {
          logitech.setControl(row.deviceKey, row.controlName, Model.snapToStep(row.control, v))
        }
      }

      // Choice settings become a strip of chips when they are few, so the
      // options are visible rather than hidden behind repeated clicking.
      Flow {
        visible: !!row.control && row.control.ui === "choice"
        Layout.fillWidth: true
        spacing: Style.space(6)

        Repeater {
          model: row.control && row.control.ui === "choice" ? row.control.choices : []
          Chip {
            required property var modelData
            text: String(modelData)
            selected: row.control && String(row.control.value) === String(modelData)
            warn: !!(row.control && row.control.disruptive)
            onClicked: {
              root.setCursor(row.deviceKey, row.controlName)
              logitech.setControl(row.deviceKey, row.controlName, String(modelData))
            }
          }
        }
      }

      // Equalizer: presets plus a read-only view of the current curve. Band by
      // band editing belongs in a bigger window than a bar popup.
      Flow {
        visible: !!row.control && row.control.ui === "equalizer"
        Layout.fillWidth: true
        spacing: Style.space(6)

        Repeater {
          model: row.control && row.control.ui === "equalizer" ? row.control.presets : []
          Chip {
            required property var modelData
            text: String(modelData)
            selected: root.eqPreset === String(modelData)
            onClicked: {
              root.setCursor(row.deviceKey, row.controlName)
              root.eqPreset = String(modelData)
              logitech.setEqualizer(row.deviceKey, String(modelData))
            }
          }
        }
      }

      Row {
        visible: !!row.control && row.control.ui === "equalizer"
        Layout.fillWidth: true
        spacing: Style.space(4)

        Repeater {
          model: row.control && row.control.ui === "equalizer" ? row.control.value : []
          Item {
            id: band
            required property var modelData
            required property int index
            width: Style.space(8)
            height: Style.space(28)

            readonly property real span: Math.max(1, Number(row.control.max) - Number(row.control.min))
            readonly property real fraction: (Number(modelData) - Number(row.control.min)) / span

            // Faint full-height track, so a band at 0 dB still reads as "half"
            // rather than as an empty slot.
            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius > 0 ? width / 2 : 0
              color: Util.alpha(root.foreground, 0.12)
            }

            Rectangle {
              anchors.bottom: parent.bottom
              width: parent.width
              height: Math.max(Style.space(3), parent.height * band.fraction)
              radius: Style.cornerRadius > 0 ? width / 2 : 0
              color: Util.alpha(root.foreground, 0.6)
            }
          }
        }

        Text {
          text: row.control && row.control.bands ? row.control.bands.join(" · ") : ""
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
  }

  // --- lighting -----------------------------------------------------------

  component LightingRow: CursorSurface {
    id: lighting
    property var device: null
    readonly property string deviceKey: device ? device.key : ""
    readonly property var effects: device && device.rgb && device.rgb.zones.length > 0
      ? device.rgb.zones[0].effects : []

    // What the first zone is actually playing, as reported by the device. The
    // panel's own memory is only a fallback for the moment between a click and
    // the next refresh.
    readonly property var current: device && device.rgb && device.rgb.zones.length > 0
      ? device.rgb.zones[0].current : null
    readonly property string activeEffect: current && current.slug ? current.slug : root.lightingEffect
    readonly property string activeColor: current && current.color ? "#" + current.color : root.lightingColor

    hasCursor: root.hasCursorAt(deviceKey, "__lighting")
    foreground: root.foreground
    implicitHeight: lightingBody.implicitHeight + Style.spacing.rowPaddingX

    Component.onCompleted: root.registerRow(deviceKey, "__lighting", lighting)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onEntered: root.setCursor(lighting.deviceKey, "__lighting")
    }

    ColumnLayout {
      id: lightingBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(6)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Text {
          text: "󰌵"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          Layout.fillWidth: true
          text: "Lighting"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        PanelActionButton {
          iconText: "󰸌"
          tooltipText: "Match the current Omarchy theme"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !logitech.busy
          onClicked: {
            root.lightingEffect = "static"
            root.lightingColor = logitech.accent
            logitech.matchTheme()
          }
        }
      }

      Flow {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Repeater {
          model: lighting.effects
          Chip {
            required property var modelData
            text: modelData.name
            selected: lighting.activeEffect === modelData.slug
            onClicked: {
              root.setCursor(lighting.deviceKey, "__lighting")
              root.lightingEffect = modelData.slug
              logitech.setLighting(lighting.deviceKey, modelData.slug, root.lightingColor)
            }
          }
        }
      }

      Row {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Repeater {
          model: Model.swatches(logitech.accent)
          Rectangle {
            required property var modelData
            width: Style.space(18)
            height: Style.space(18)
            radius: Style.cornerRadius > 0 ? width / 2 : 0
            readonly property bool picked:
              Model.hexOf(lighting.activeColor) === Model.hexOf(modelData.color)
            color: modelData.color
            border.width: picked ? Style.normalBorderWidth * 2 : Style.normalBorderWidth
            border.color: picked ? root.foreground : Util.alpha(root.foreground, 0.35)

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.setCursor(lighting.deviceKey, "__lighting")
              onClicked: {
                root.lightingColor = modelData.color
                // Only color-bearing effects can show a swatch; nudge the
                // effect to Static so a click always does something visible.
                var slug = lighting.activeEffect
                var supportsColor = slug === "static" || slug === "breathe" || slug === "ripple"
                if (!supportsColor) slug = "static"
                root.lightingEffect = slug
                logitech.setLighting(lighting.deviceKey, slug, modelData.color)
              }
            }
          }
        }
      }
    }
  }

  // --- small parts --------------------------------------------------------

  component Chip: Rectangle {
    id: chip
    property string text: ""
    property bool selected: false
    property bool warn: false
    signal clicked()

    readonly property bool hot: chipMouse.containsMouse

    implicitWidth: chipLabel.implicitWidth + Style.space(16)
    implicitHeight: Math.max(Style.space(22), chipLabel.implicitHeight + Style.space(8))
    radius: Style.cornerRadius > 0 ? height / 2 : 0
    color: selected
      ? Style.selectedFillFor(root.foreground, Color.accent)
      : (hot ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent")
    border.width: Style.normalBorderWidth
    border.color: selected ? Util.alpha(root.foreground, 0.55) : Util.alpha(root.foreground, 0.22)

    Text {
      id: chipLabel
      anchors.centerIn: parent
      text: chip.text
      textFormat: Text.PlainText
      color: chip.warn && !chip.selected ? root.urgent : root.foreground
      opacity: chip.selected ? 1.0 : 0.85
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }
  }
}
