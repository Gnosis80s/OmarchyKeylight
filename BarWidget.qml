import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Keyboard backlight control. Left click cycles the backlight through its
// brightness levels (0 → 1 → 2 → … → max → 0); right click cycles down; the
// scroll wheel steps up/down without wrapping; middle click toggles between
// off and the last lit level.
//
// Some drivers (e.g. asus-nb-wmi's asus::kbd_backlight) always report 0 from
// the sysfs `brightness` file, so the current level can't be probed back from
// hardware. The widget therefore keeps its own last-known level in a file
// under XDG_STATE_HOME and refreshes it on every change. On top of that it
// polls sysfs so changes made outside the widget still show up:
//   - `brightness`, once it has ever read back non-zero (the driver is honest);
//   - `brightness_hw_changed`, which firmware-handled Fn keys update even on
//     drivers whose `brightness` read is stuck at 0.
// The state file is watched too, so every bar instance (one per monitor) and
// the IPC target stay in sync with whichever one made the change.
BarWidget {
  id: root
  moduleName: "gnosis.kbd-backlight"

  // LEDs-class device name. Auto-detected (first *kbd_backlight* LED) unless
  // overridden with a `device` setting on this widget's shell.json entry.
  property string device: ""
  readonly property string sysDir: device ? "/sys/class/leds/" + device : ""
  readonly property bool available: device !== "" && maxLevel > 0

  property int level: 0
  property int maxLevel: 0
  // Level a middle-click toggle restores to; 0 means "use max".
  property int lastLit: 0

  // Lit-state icon color. The bar's default active color is the theme's
  // urgent (orange), which reads as a warning; the backlight is neutral, so
  // use a light blue glow instead.
  readonly property color glowColor: "#8fd8ff"
  // Scale the glow with the step so the icon mirrors the physical light:
  // a dim halo at the lowest level, a bright one at the highest.
  readonly property real glowStrength: maxLevel > 0 ? level / maxLevel : 0
  readonly property real glowOpacity: level > 0 ? 0.35 + 0.6 * glowStrength : 0

  readonly property int percent: maxLevel > 0 ? Math.round(level * 100 / maxLevel) : 0

  // Polling bookkeeping. `hwReadable` flips on the first non-zero `brightness`
  // read; `lastHwChanged` is null until the first read so a stale value from
  // before the shell started isn't mistaken for a fresh key press.
  property bool hwReadable: false
  property var lastHwChanged: null
  // Ignore sysfs reads until our own brightnessctl write has landed, so a poll
  // racing the write can't snap the level back to the old value.
  property real quietUntil: 0
  property bool startupApplied: false
  property bool stateLoaded: false
  property real wheelAccumulator: 0

  function stateFile() {
    var dir = Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"
    return dir + "/gnosis-kbd-backlight"
  }

  function clampLevel(value) {
    return Math.round(Util.clamp(value, 0, root.maxLevel))
  }

  function setLocal(value) {
    root.level = value
    if (value > 0) root.lastLit = value
  }

  function persist(value) {
    stateView.setText(value + "\n")
  }

  // Set the hardware level; `notify` also pops the OSD with the new percent.
  function setLevel(value, notify) {
    if (!root.available) return
    value = root.clampLevel(value)
    root.setLocal(value)
    root.quietUntil = Date.now() + 1500
    var cmd = "brightnessctl -d " + Util.shellQuote(root.device) + " set " + value + " >/dev/null"
    if (notify) cmd += " && omarchy-osd -i keyboard -p " + root.percent
    if (root.bar) root.bar.run(cmd)
    root.persist(value)
  }

  // A change made outside the widget (Fn key, another tool): mirror it and
  // persist it, but don't write the hardware back.
  function adopt(value) {
    value = root.clampLevel(value)
    if (value === root.level) return
    root.setLocal(value)
    root.persist(value)
  }

  function step(delta) {
    var count = root.maxLevel + 1
    root.setLevel((root.level + delta + count) % count, true)
  }

  function nudge(delta) {
    var next = root.clampLevel(root.level + delta)
    if (next !== root.level) root.setLevel(next, true)
  }

  function toggle() {
    root.setLevel(root.level > 0 ? 0 : (root.lastLit > 0 ? root.lastLit : root.maxLevel), true)
  }

  function parseState(raw) {
    var value = String(raw || "").trim().toLowerCase()
    if (value === "on") return root.maxLevel
    if (value === "off") return 0
    if (/^\d+$/.test(value)) return parseInt(value, 10)
    return -1
  }

  // Re-apply the persisted level once the saved state and the real max are both
  // known. Many laptops boot with the keyboard backlight off, so this restores
  // last session's brightness; skipped when the level is 0/off.
  function maybeApplyStartup() {
    if (root.startupApplied || !root.stateLoaded || !root.available) return
    root.startupApplied = true
    root.level = root.clampLevel(root.level)
    if (root.level > 0) {
      root.lastLit = root.level
      root.setLevel(root.level, false)
    }
  }

  function readSysInt(view) {
    var n = parseInt(String(view.text() || "").trim(), 10)
    return Number.isFinite(n) ? n : -1
  }

  function onBrightnessRead() {
    var n = root.readSysInt(brightnessView)
    if (n < 0 || !root.startupApplied || Date.now() < root.quietUntil) return
    if (n > 0) root.hwReadable = true
    if (root.hwReadable) root.adopt(n)
  }

  function onHwChangedRead() {
    var n = root.readSysInt(hwChangedView)
    if (n < 0) return
    var previous = root.lastHwChanged
    root.lastHwChanged = n
    if (previous === null || n === previous || !root.startupApplied) return
    root.adopt(n)
  }

  function refresh() {
    if (!root.sysDir) return
    brightnessView.reload()
    hwChangedView.reload()
  }

  Component.onCompleted: {
    var configured = String(root.setting("device", "") || "").trim()
    if (configured) root.device = configured
    else detectProc.running = true
  }

  IpcHandler {
    target: "gnosis.kbd-backlight"

    function up(): void { root.nudge(1) }
    function down(): void { root.nudge(-1) }
    function cycle(): void { root.step(1) }
    function toggle(): void { root.toggle() }
    function set(value: int): void { root.setLevel(value, true) }
    function get(): string { return root.level + "/" + root.maxLevel }
  }

  // First LEDs-class device that looks like a keyboard backlight.
  Process {
    id: detectProc
    command: ["bash", "-c", "for d in /sys/class/leds/*kbd_backlight*; do [ -e \"$d\" ] && { basename \"$d\"; break; }; done"]
    stdout: StdioCollector {
      onStreamFinished: root.device = String(text || "").trim()
    }
  }

  FileView {
    id: maxView
    path: root.sysDir ? root.sysDir + "/max_brightness" : ""
    printErrors: false
    onLoaded: {
      var n = root.readSysInt(maxView)
      if (n > 0) root.maxLevel = n
      root.maybeApplyStartup()
    }
  }

  // Persisted level (or the old on/off format from the toggle version).
  // Watched so a change from any bar instance or IPC call shows everywhere.
  FileView {
    id: stateView
    path: root.stateFile()
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var n = root.parseState(text())
      if (!root.startupApplied) {
        if (n >= 0) root.level = n
        root.stateLoaded = true
        root.maybeApplyStartup()
      } else if (n >= 0 && root.clampLevel(n) !== root.level) {
        root.setLocal(root.clampLevel(n))
      }
    }
    onLoadFailed: {
      root.stateLoaded = true
      root.maybeApplyStartup()
    }
  }

  FileView {
    id: brightnessView
    path: root.sysDir ? root.sysDir + "/brightness" : ""
    printErrors: false
    onLoaded: root.onBrightnessRead()
  }

  FileView {
    id: hwChangedView
    path: root.sysDir ? root.sysDir + "/brightness_hw_changed" : ""
    printErrors: false
    onLoaded: root.onHwChangedRead()
  }

  // sysfs attributes don't raise inotify events, so poll them.
  Timer {
    interval: 1000
    repeat: true
    running: root.available && root.startupApplied
    onTriggered: root.refresh()
  }

  visible: root.available
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰌌"
    active: root.level > 0
    activeColor: root.glowColor
    dimmed: root.level === 0
    tooltipText: (root.level === 0
      ? "Keyboard backlight off"
      : "Keyboard backlight " + root.level + "/" + root.maxLevel + " (" + root.percent + "%)")
      + "\nClick/scroll to adjust · middle click to toggle"
    // When lit, run the glyph through a MultiEffect and simulate a glow with a
    // zero-offset shadow in the lit blue. The shadow opacity tracks the
    // brightness step, so the halo grows with the real backlight level.
    layer.enabled: root.level > 0
    layer.effect: MultiEffect {
      shadowEnabled: true
      shadowColor: root.glowColor
      shadowOpacity: root.glowOpacity
      shadowBlur: 1.0
      shadowHorizontalOffset: 0
      shadowVerticalOffset: 0
      shadowScale: 1.0
      blurMax: 12
    }
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.step(1)
      else if (b === Qt.RightButton) root.step(-1)
      else if (b === Qt.MiddleButton) root.toggle()
    }
    onWheelMoved: function(delta) {
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps !== 0) root.nudge(wheel.steps)
    }
  }
}
