import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Keyboard backlight control. Left click cycles the backlight through its
// brightness levels (0 → 1 → 2 → … → max → 0); right click steps down. The
// first level off the 0 → max range lights the keyboard at the lowest step.
//
// The asus-nb-wmi kernel driver exposes the backlight as a LEDs-class device
// (asus::kbd_backlight) but its sysfs brightness read always reports 0, so the
// current level can't be probed back from hardware. Instead the widget keeps
// its own last-known level in a file under XDG_STATE_HOME and refreshes it on
// every change.
BarWidget {
  id: root
  moduleName: "gnosis.kbd-backlight"

  readonly property string device: "asus::kbd_backlight"
  property int level: 0
  property int maxLevel: 3

  function stateFile() {
    var dir = Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"
    return dir + "/gnosis-kbd-backlight"
  }

  readonly property int percent: maxLevel > 0 ? Math.round(level * 100 / maxLevel) : 0

  function applyLevel(value) {
    value = Math.max(0, Math.min(root.maxLevel, value))
    root.level = value
    if (root.bar) {
      root.bar.run("brightnessctl -d " + root.device + " set " + value + " >/dev/null && omarchy-osd -i keyboard -p " + root.percent)
      root.bar.run("printf '%s\\n' " + value + " > " + Util.shellQuote(root.stateFile()))
    }
  }

  function step(delta) {
    var count = root.maxLevel + 1
    root.applyLevel((root.level + delta + count) % count)
  }

  Component.onCompleted: {
    readProc.running = true
    maxProc.running = true
  }

  // Persisted level (or the old on/off format from the toggle version).
  Process {
    id: readProc
    command: ["cat", root.stateFile()]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = String(text || "").trim().toLowerCase()
        if (value === "on") root.level = root.maxLevel
        else if (value === "off") root.level = 0
        else if (/^\d+$/.test(value)) {
          var n = parseInt(value, 10)
          root.level = Math.max(0, Math.min(root.maxLevel, n))
        }
      }
    }
  }

  // Highest supported brightness level, so the cycle covers the real range.
  Process {
    id: maxProc
    command: ["brightnessctl", "-d", root.device, "max"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var n = parseInt(String(text || "").trim(), 10)
        if (Number.isFinite(n) && n > 0) root.maxLevel = n
      }
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰌌"
    active: root.level > 0
    dimmed: root.level === 0
    tooltipText: root.level === 0 ? "Keyboard backlight off" : "Keyboard backlight " + root.level + "/" + root.maxLevel
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.step(1)
      else if (b === Qt.RightButton) root.step(-1)
    }
  }
}