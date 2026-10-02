import QtQuick
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// The colour the panel highlights with: the theme's own accent, or another
// colour from the current theme's palette (blue, cyan, ...), read from the
// theme's colors.toml. The choice is stored by name, so it follows a theme
// change, and falls back to the theme accent where the new theme lacks it.
Item {
  id: root

  // "theme" or a palette name.
  property string choice: "theme"
  property var palette: ({})

  readonly property var available: Model.accentChoices(root.palette)
  readonly property color value: root.colorOf(root.choice)

  function colorOf(name) {
    var picked = Model.accentColor(name, root.palette)
    return picked !== null ? picked : Color.accent
  }

  FileView {
    id: colors
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.palette = Model.parsePalette(text())
    onFileChanged: reload()
  }

  // A theme switch reaches the shell as a pushed payload, and the file may be
  // swapped under the watch, so also re-read shortly after the accent moves.
  Connections {
    target: Color
    function onAccentChanged() { refresh.restart() }
  }

  Timer {
    id: refresh
    interval: 400
    onTriggered: colors.reload()
  }
}
