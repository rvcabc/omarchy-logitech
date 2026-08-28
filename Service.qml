import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Talks to `logi daemon` over its unix socket.
//
// The daemon exists because building solaar's settings list for a wireless
// device takes seconds; it holds the devices open so a slider drag costs one
// HID++ round trip. This service keeps a single connection for the session and
// pipelines requests down it, correlating replies by id.
Item {
  id: root

  property var settings: ({})
  property string pluginDir: ""

  readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-logitech.sock"
  readonly property string logiPath: pluginDir + "/bin/logi"

  property var devices: []
  property bool connected: false
  property bool everConnected: false
  property string lastError: ""
  property string actionStatus: ""
  property int pendingWrites: 0
  property string accent: "#2bb3e6"

  readonly property bool busy: pendingWrites > 0
  readonly property var weakest: Model.weakest(devices)
  readonly property bool anyLow: Model.anyLow(devices, warnBelowPercent)

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 90, 15, 900)
  readonly property int warnBelowPercent: intSetting("warnBelowPercent", 20, 5, 50)

  property int _nextId: 1
  property var _pending: ({})

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // --- transport ----------------------------------------------------------

  function send(request, callback) {
    if (!link.connected) {
      lastError = "device daemon is not running"
      ensureDaemon()
      return false
    }
    var id = _nextId++
    request.id = id
    if (callback) _pending[id] = callback
    link.write(JSON.stringify(request) + "\n")
    link.flush()
    return true
  }

  function handleLine(line) {
    var text = String(line || "").trim()
    if (text === "") return
    var message
    try {
      message = JSON.parse(text)
    } catch (e) {
      lastError = "could not parse a daemon reply"
      return
    }
    var callback = message.id !== undefined ? _pending[message.id] : null
    if (callback) delete _pending[message.id]
    if (message.ok === false) {
      lastError = String(message.error || "device command failed")
      actionStatus = lastError
      statusResetTimer.restart()
    } else if (message.devices !== undefined) {
      lastError = ""
    }
    if (callback) callback(message)
  }

  // The daemon is a user service; if it is not up, start it. A plain spawn is
  // the fallback for a machine where the unit was never installed.
  function ensureDaemon() {
    if (starter.running) return
    starter.command = ["sh", "-c",
      "systemctl --user start omarchy-logitech.service 2>/dev/null || " +
      "setsid '" + logiPath + "' daemon >/dev/null 2>&1 < /dev/null &"]
    starter.running = true
  }

  // --- reads --------------------------------------------------------------

  function refresh(rescan) {
    send({ action: "status", rescan: rescan === true }, function (message) {
      if (message.devices) devices = message.devices
    })
  }

  // The full settings window works from its own model carrying every setting
  // (all: true), fetched on demand so the bar's 90s heartbeat stays lean.
  property var detailedDevices: []
  property bool detailLoading: false

  function refreshDetailed() {
    detailLoading = true
    send({ action: "status", all: true }, function (message) {
      detailLoading = false
      if (message.devices) detailedDevices = message.devices
    })
  }

  function detailedControlFor(key, name) {
    for (var i = 0; i < detailedDevices.length; i++) {
      if (detailedDevices[i].key !== key) continue
      var controls = detailedDevices[i].controls
      for (var j = 0; j < controls.length; j++) if (controls[j].name === name) return controls[j]
    }
    return null
  }

  // Rewrite one control in the detailed model, mirroring applyLocally.
  function applyDetailLocally(key, name, patch) {
    var copy = detailedDevices.slice()
    for (var i = 0; i < copy.length; i++) {
      if (copy[i].key !== key) continue
      var device = JSON.parse(JSON.stringify(copy[i]))
      for (var j = 0; j < device.controls.length; j++) {
        if (device.controls[j].name === name) { patch(device.controls[j]); break }
      }
      copy[i] = device
      break
    }
    detailedDevices = copy
  }

  // Write a whole-setting value from the settings window: the detailed model
  // updates optimistically, the reply reconciles it, and the bar model
  // refreshes so curated controls stay in step.
  function setDetail(key, name, value) {
    applyDetailLocally(key, name, function (control) { control.value = value })
    pendingWrites++
    send({ action: "set", device: key, setting: name, value: String(value) }, function (message) {
      pendingWrites = Math.max(0, pendingWrites - 1)
      if (message.ok && message.value !== undefined && message.value !== null) {
        applyDetailLocally(key, name, function (control) { control.value = message.value })
        applyLocally(key, name, message.value)
      } else if (!message.ok) {
        refreshDetailed()
      }
    })
  }

  function toggleDetail(key, name) {
    var control = detailedControlFor(key, name)
    if (control) setDetail(key, name, control.value ? "false" : "true")
  }

  function cycleDetailChoice(key, name, direction) {
    var control = detailedControlFor(key, name)
    var next = Model.nextChoice(control, direction)
    if (next !== null) setDetail(key, name, next)
  }

  // Write one equalizer band (daemon syntax "band=dB"); the reply carries the
  // whole curve back.
  function setEqualizerBand(key, bandIndex, band, db) {
    applyDetailLocally(key, "equalizer", function (control) {
      if (Array.isArray(control.value)) control.value[bandIndex] = db
    })
    pendingWrites++
    send({ action: "set", device: key, setting: "equalizer", value: band + "=" + db }, function (message) {
      pendingWrites = Math.max(0, pendingWrites - 1)
      if (message.ok && message.value) {
        applyDetailLocally(key, "equalizer", function (control) { control.value = message.value })
        applyLocally(key, "equalizer", message.value)
      } else if (!message.ok) {
        refreshDetailed()
      }
    })
  }

  // Write one key of a per-key map (button assignments, diversion). The reply
  // carries the whole map back, which lands in the detailed model.
  function setMapItem(key, name, itemId, value) {
    applyDetailLocally(key, name, function (control) {
      for (var i = 0; i < (control.items || []).length; i++) {
        if (control.items[i].id === itemId) { control.items[i].value = value; break }
      }
    })
    pendingWrites++
    send({ action: "set", device: key, setting: name, item: itemId, value: String(value) }, function (message) {
      pendingWrites = Math.max(0, pendingWrites - 1)
      if (message.ok && message.items) {
        applyDetailLocally(key, name, function (control) {
          for (var i = 0; i < (control.items || []).length; i++) {
            var held = message.items[String(control.items[i].id)]
            if (held !== undefined) control.items[i].value = held
          }
        })
      } else if (!message.ok) {
        refreshDetailed()
      }
    })
  }

  function deviceFor(key) {
    for (var i = 0; i < devices.length; i++) if (devices[i].key === key) return devices[i]
    return null
  }

  function controlFor(key, name) {
    var device = deviceFor(key)
    if (!device) return null
    for (var i = 0; i < device.controls.length; i++) {
      if (device.controls[i].name === name) return device.controls[i]
    }
    return null
  }

  // Rewrite one control's value in the local model so the UI moves with the
  // pointer instead of waiting on the device round trip. The reply reconciles.
  function applyLocally(key, name, value) {
    var copy = devices.slice()
    for (var i = 0; i < copy.length; i++) {
      if (copy[i].key !== key) continue
      var device = JSON.parse(JSON.stringify(copy[i]))
      for (var j = 0; j < device.controls.length; j++) {
        if (device.controls[j].name === name) {
          device.controls[j].value = value
          break
        }
      }
      copy[i] = device
      break
    }
    devices = copy
  }

  // --- writes -------------------------------------------------------------

  function setControl(key, name, value) {
    applyLocally(key, name, value)
    pendingWrites++
    send({ action: "set", device: key, setting: name, value: String(value) }, function (message) {
      pendingWrites = Math.max(0, pendingWrites - 1)
      // The device may snap to its own steps (keyboard brightness has four
      // levels, not a hundred), so trust the readback over what we asked for.
      if (message.ok && message.value !== undefined && message.value !== null) {
        applyLocally(key, name, message.value)
      }
    })
  }

  function toggleControl(key, name) {
    var control = controlFor(key, name)
    if (!control) return
    setControl(key, name, control.value ? "false" : "true")
  }

  function cycleChoice(key, name, direction) {
    var control = controlFor(key, name)
    var next = Model.nextChoice(control, direction)
    if (next !== null) setControl(key, name, next)
  }

  function nudgeSlider(key, name, direction) {
    var control = controlFor(key, name)
    if (!control) return
    var step = Number(control.step || 1)
    setControl(key, name, Model.snapToStep(control, Number(control.value) + step * (direction < 0 ? -1 : 1)))
  }

  function setEqualizer(key, preset) {
    applyLocally(key, "equalizer", null)
    pendingWrites++
    send({ action: "set", device: key, setting: "equalizer", value: preset }, function (message) {
      pendingWrites = Math.max(0, pendingWrites - 1)
      if (message.ok && message.value) {
        applyLocally(key, "equalizer", message.value)
        // The settings window renders from the detailed model; keep it live.
        applyDetailLocally(key, "equalizer", function (control) { control.value = message.value })
      }
      actionStatus = message.ok ? "Equalizer: " + preset : actionStatus
      statusResetTimer.restart()
    })
  }

  function setLighting(key, effect, color) {
    pendingWrites++
    var request = { action: "rgb", device: key, effect: effect }
    if (color) request.color = Model.hexOf(color)
    send(request, function (message) {
      pendingWrites = Math.max(0, pendingWrites - 1)
      if (message.ok) {
        actionStatus = "Lighting: " + effect
        statusResetTimer.restart()
        refresh(false)
      }
    })
  }

  function matchTheme() {
    pendingWrites++
    send({ action: "theme" }, function (message) {
      pendingWrites = Math.max(0, pendingWrites - 1)
      actionStatus = message.ok ? "Lighting matched to the theme" : actionStatus
      statusResetTimer.restart()
    })
  }

  // --- plumbing -----------------------------------------------------------

  Socket {
    id: link
    path: root.socketPath
    connected: true

    parser: SplitParser {
      splitMarker: "\n"
      onRead: function (line) { root.handleLine(line) }
    }

    onConnectionStateChanged: {
      root.connected = link.connected
      if (link.connected) {
        root.everConnected = true
        root.lastError = ""
        root.refresh(false)
      } else if (root.everConnected) {
        // The daemon restarted (or was updated) — reconnect and resync.
        reconnectTimer.restart()
      }
    }

    onError: function (error) {
      root.connected = false
      if (!root.everConnected) root.ensureDaemon()
      reconnectTimer.restart()
    }
  }

  Process {
    id: starter
    running: false
    command: []
    onExited: reconnectTimer.restart()
  }

  Timer {
    id: reconnectTimer
    interval: 2500
    repeat: false
    onTriggered: if (!link.connected) link.connected = true
  }

  Timer {
    // A slow heartbeat: battery levels move over hours, and the daemon pushes
    // nothing on its own. Everything the user touches updates optimistically.
    id: pollTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    onTriggered: if (link.connected) root.refresh(false)
  }

  Timer {
    id: statusResetTimer
    interval: 2600
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Timer {
    // First connection attempt can land before the daemon's socket exists.
    id: bootTimer
    interval: 400
    repeat: false
    running: true
    onTriggered: if (!link.connected) root.ensureDaemon()
  }

  Process {
    // The accent color for the "Theme" swatch. Cheap, and only read at start
    // and on demand, so a theme switch is picked up by reopening the panel.
    id: accentProbe
    running: true
    command: ["sh", "-c",
      "sed -n 's/^ *accent *= *\"\\?#\\?\\([0-9a-fA-F]\\{6\\}\\).*/\\1/p' " +
      "\"$(omarchy theme dir \"$(omarchy theme current)\" 2>/dev/null)/colors.toml\" 2>/dev/null | head -1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var hex = String(text || "").trim()
        if (hex.length === 6) root.accent = "#" + hex
      }
    }
  }

  function refreshAccent() {
    if (!accentProbe.running) accentProbe.running = true
  }
}
