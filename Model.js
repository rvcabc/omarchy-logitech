// Pure formatting helpers for the Logitech panel. No device access here — the
// daemon owns all of that; this file only turns its JSON into glyphs and text.

.pragma library

var DEVICE_GLYPHS = {
  mouse: "󰍽",
  keyboard: "󰌌",
  headset: "󰋎",
  touchpad: "󰟸",
  trackball: "󰆽",
  device: "󰃟"
}

function deviceGlyph(device) {
  if (!device) return DEVICE_GLYPHS.device
  var kind = String(device.kind || "").toLowerCase()
  return DEVICE_GLYPHS[kind] || DEVICE_GLYPHS.device
}

// Battery glyphs run empty → full; charging has its own ramp so a charging
// device never looks like a dying one.
var BATTERY_EMPTY = ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
var BATTERY_CHARGING = ["󰢟", "󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]

function batteryGlyph(battery) {
  if (!battery || battery.level === null || battery.level === undefined) return "󰂑"
  var index = Math.max(0, Math.min(10, Math.round(Number(battery.level) / 10)))
  return battery.charging ? BATTERY_CHARGING[index] : BATTERY_EMPTY[index]
}

// Daemon and device strings can end up in shared shell components (the bar
// tooltip, PanelHero's meta) whose Text sinks default to AutoText and are not
// ours to change — swap angle brackets for lookalikes so nothing tag-shaped
// survives. The plugin's own Text sinks force Text.PlainText as well.
function plain(text) {
  return String(text).replace(/</g, "‹").replace(/>/g, "›")
}

function batteryText(battery) {
  if (!battery) return ""
  if (battery.level === null || battery.level === undefined) return plain(battery.status || "")
  return Math.round(Number(battery.level)) + "%"
}

function batteryDetail(battery) {
  if (!battery) return "No battery reporting"
  var text = batteryText(battery)
  var status = String(battery.status || "")
  if (!status || status === "unknown") return text
  return text + " · " + plain(status)
}

// Devices that report a battery, weakest first — the bar shows the one most
// likely to strand you mid-task.
function batteryDevices(devices) {
  var withBattery = (devices || []).filter(function (d) {
    return d.battery && d.battery.level !== null && d.battery.level !== undefined
  })
  withBattery.sort(function (a, b) { return Number(a.battery.level) - Number(b.battery.level) })
  return withBattery
}

function weakest(devices) {
  var ranked = batteryDevices(devices)
  return ranked.length > 0 ? ranked[0] : null
}

function anyLow(devices, threshold) {
  var limit = threshold === undefined ? 20 : threshold
  return batteryDevices(devices).some(function (d) {
    return Number(d.battery.level) <= limit && !d.battery.charging
  })
}

function barTooltip(devices, connected, error) {
  if (error) return "Logitech — " + plain(error)
  if (!connected) return "Logitech — connecting to the device daemon…"
  if (!devices || devices.length === 0) return "Logitech — no devices connected"
  var lines = devices.map(function (d) {
    var battery = d.battery ? "  " + batteryDetail(d.battery) : ""
    return plain(d.name) + battery
  })
  lines.push("")
  lines.push("Click to open · right-click to match lighting to the theme")
  return lines.join("\n")
}

function controlValueText(control) {
  if (!control) return ""
  if (control.ui === "toggle") return control.value ? "On" : "Off"
  if (control.ui === "equalizer") return (control.value || []).join(", ")
  return String(control.value) + String(control.unit || "")
}

// Choice settings are cycled rather than shown in a dropdown; this picks the
// next value, wrapping at the end.
function nextChoice(control, direction) {
  var choices = control && control.choices ? control.choices : []
  if (choices.length === 0) return null
  var index = choices.indexOf(String(control.value))
  if (index < 0) index = 0
  var step = direction < 0 ? -1 : 1
  return choices[(index + step + choices.length) % choices.length]
}

// Slider values must land on the device's own steps, or the write bounces back
// to the nearest supported value and the knob visibly jumps.
function snapToStep(control, value) {
  var min = Number(control.min || 0)
  var max = Number(control.max || 100)
  var step = Number(control.step || 1)
  var snapped = min + Math.round((value - min) / step) * step
  return Math.max(min, Math.min(max, snapped))
}

function zoneSettingName(zone) {
  return "rgb_zone_" + zone.index
}

function effectLabel(effect) {
  return effect && effect.name ? effect.name : ""
}

// Swatches offered next to the lighting effects. "Theme" resolves at click
// time from the live Omarchy accent, so it follows theme switches.
function swatches(accent) {
  return [
    { label: "Theme", color: accent, theme: true },
    { label: "White", color: "#ffffff" },
    { label: "Cyan", color: "#2bb3e6" },
    { label: "Magenta", color: "#e0446b" },
    { label: "Amber", color: "#f2b544" },
    { label: "Green", color: "#4bd07a" }
  ]
}

function hexOf(color) {
  var text = String(color || "").trim()
  if (text.indexOf("#") === 0) text = text.substring(1)
  if (text.length === 8) text = text.substring(2)  // strip an alpha prefix
  return text.toLowerCase()
}

// Quartile fill for the drawn battery outline: no bars below 25%, one more
// per quarter crossed, all four only when actually full.
function batterySegments(battery) {
  if (!battery || battery.level === null || battery.level === undefined) return 0
  return Math.max(0, Math.min(4, Math.floor(Number(battery.level) / 25)))
}

// Fill fraction for the level-bar style; null when the device reports a
// battery but no usable level.
function batteryFraction(battery) {
  if (!battery || battery.level === null || battery.level === undefined) return 0
  return Math.max(0, Math.min(1, Number(battery.level) / 100))
}
