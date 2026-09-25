import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "videinfra.omaudiopanel"
  ipcTarget: "videinfra.omaudiopanel"

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var source: Pipewire.defaultAudioSource
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  readonly property var mediaService: bar?.shell?.firstPartyServiceFor("omarchy.media")
  readonly property var activeMediaPlayer: mediaService ? mediaService.activePlayer : null

  readonly property var candidateSinks: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream) list.push(n)
    }
    return list
  }

  readonly property var candidateSources: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && !n.isSink && !n.isStream && isAudioSource(n)) {
        var name = n.name || ""
        if (name === "quickshell") continue
        list.push(n)
      }
    }
    return list
  }

  readonly property var candidateStreams: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isStream || !isPlaybackStream(n)) continue
      // A tuning's output is a playback stream too, but it is the processing
      // itself rather than an application, so it does not belong in the list.
      if (String(n.name || "").indexOf("omarchy_speaker_tuning") === 0) continue
      list.push(n)
    }
    return list
  }

  property var sinkAvailability: ({})
  property bool sinkAvailabilityLoaded: false

  // Identify true playback streams without reading node.properties here:
  // PwNode.properties is invalid until the node is bound, and reading it while
  // capture streams are appearing (for example, when Voxtype starts recording)
  // can destabilize Quickshell's Pipewire service. Quickshell versions differ
  // in how `type` is exposed (media.class, enum name, or numeric enum), but
  // playback streams consistently accept audio input from clients and publish
  // `isSink: true`; capture streams publish as stream sources.
  function isPlaybackStream(node) {
    return Model.isPlaybackStream(node)
  }

  function isAudioSource(node) {
    return Model.isAudioSource(node)
  }

  property var cachedAudioSinks: []
  property var cachedAudioSources: []

  readonly property var rawAudioSinks: {
    var list = []
    for (var i = 0; i < candidateSinks.length; i++)
      if (sinkAvailable(candidateSinks[i])) list.push(candidateSinks[i])
    if (sink && list.indexOf(sink) < 0) list.unshift(sink)
    return list
  }

  readonly property var rawAudioSources: {
    var list = candidateSources.slice()
    if (source && list.indexOf(source) < 0) list.unshift(source)
    return list
  }

  readonly property var audioSinks: rawAudioSinks.length > 0 ? rawAudioSinks : cachedAudioSinks
  readonly property var audioSources: rawAudioSources.length > 0 ? rawAudioSources : cachedAudioSources

  readonly property var audioStreams: {
    var list = []
    for (var i = 0; i < candidateStreams.length; i++)
      if (candidateStreams[i].audio) list.push(candidateStreams[i])
    return list
  }

  // Feed Repeaters with panel-local snapshots instead of the live PipeWire
  // model. PipeWire can remove nodes while Quickshell is dispatching the
  // removal signal; rebuilding a Repeater from that signal path has crashed
  // in Quickshell's PipeWire service. The snapshot timer lets that mutation
  // settle first, and closed panels keep their repeaters detached entirely.
  property var displayAudioSinks: []
  property var displayAudioSources: []
  property var displayAudioStreams: []

  // A DSP sink -- a speaker tuning, or EasyEffects -- can be the selected output
  // without being where loudness lives: changing its volume alters the level going
  // *into* the processing, so the slider would move while the speakers did not,
  // and on a chain with a limiter it would change the tone as well.
  //
  // omarchy-audio-output-sink resolves the *current* default output through any
  // such sink to the physical one, which is the same definition the volume keys
  // and the output switcher use. Resolving the default (rather than "whatever a
  // tuning fronts") is what keeps this correct when headphones or HDMI are
  // selected while a tuning still exists.
  property string volumeSinkName: ""

  // ---- Display settings (shell.json, set from the gear view) ----
  readonly property string density: String(setting("density", "normal"))
  readonly property real densityScale: Model.densityScale(density)
  readonly property string fontSize: String(setting("fontSize", "normal"))
  // Text shrinks half as fast as spacing so compact stays readable, then the
  // font size setting scales it on top.
  readonly property real fontScale: (0.5 + 0.5 * densityScale) * Model.fontSizeScale(fontSize)
  readonly property real fontTitle: Math.round(Style.font.title * fontScale)
  readonly property real fontBody: Math.round(Style.font.body * fontScale)
  readonly property real fontCaption: Math.max(9, Math.round(Style.font.caption * fontScale))
  readonly property real fontDisplay: Math.round(Style.font.display * fontScale)
  readonly property bool showPlayingBars: Model.settingBool(setting("showPlayingBars", true), true)
  readonly property bool showRouting: Model.settingBool(setting("showRouting", true), true)
  readonly property bool showDisabled: Model.settingBool(setting("showDisabled", true), true)
  readonly property bool showStepFooter: Model.settingBool(setting("showStepFooter", true), true)
  property bool settingsOpen: false

  // Style.space scaled by the chosen density.
  function sp(px) {
    return Style.space(px * densityScale)
  }

  function setSetting(key, value) {
    Quickshell.execDetached(["omarchy", "bar", "set", "videinfra.omaudiopanel", key, JSON.stringify(value), "--json"])
  }

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // Percent one volume step changes: the bar icon's scroll wheel, the panel
  // sliders, h/l in the panel, and (through `omaudiopanel volume`) the volume keys. Set with
  // `omarchy bar set videinfra.omaudiopanel scrollStep 2 --json` or from the panel footer.
  readonly property var scrollStepChoices: [1, 2, 5, 10]
  readonly property int scrollStep: Math.max(1, Math.min(25, parseInt(setting("scrollStep", 5), 10) || 5))

  function setScrollStep(percent) {
    Quickshell.execDetached(["omarchy", "bar", "set", "videinfra.omaudiopanel", "scrollStep", String(percent), "--json"])
  }

  readonly property var volumeSink: {
    if (volumeSinkName === "" || !sink) return sink
    if (volumeSinkName === String(sink.name)) return sink
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream && String(n.name) === volumeSinkName && n.audio)
        return n
    }
    return sink
  }

  // Re-resolve whenever the selected output changes; the timer below is only a
  // safety net for the tuning being applied or removed underneath us.
  onSinkChanged: resolveVolumeSink()

  function resolveVolumeSink() {
    if (!volumeSinkProc.running) volumeSinkProc.running = true
  }

  readonly property real outputVolume: volumeSink && volumeSink.audio ? volumeSink.audio.volume : 0
  readonly property bool outputMuted: volumeSink && volumeSink.audio ? volumeSink.audio.muted : false
  readonly property real inputVolume: source && source.audio ? source.audio.volume : 0
  readonly property bool inputMuted: source && source.audio ? source.audio.muted : false

  onRawAudioSinksChanged: if (rawAudioSinks.length > 0) cachedAudioSinks = rawAudioSinks
  onRawAudioSourcesChanged: if (rawAudioSources.length > 0) cachedAudioSources = rawAudioSources

  // Single cursor model shared by keyboard and mouse. Sections:
  //   "output"  — output slider + sink device list
  //   "input"   — input slider + source device list
  //   "streams" — per-app playback streams
  //   "disabled" — devices disabled from this panel; -1 is the Show/Hide
  //                field, rows appear once it is open (Enter re-enables)
  // selectedIndex semantics within a section:
  //   -1            → on the slider row (h/l adjusts volume, m/Enter mute)
  //   0..N-1        → on the Nth device/stream row
  // Visuals derive from hasCursor/current via CursorSurface, never
  // from containsMouse — that's what keeps the highlight unique across
  // keyboard + mouse like wifi does.
  property string focusSection: "output"
  property int selectedIndex: -1
  property bool cursorActive: false

  // "header" is a virtual section for the hero output mute toggle; it sits
  // above the output section so the speaker can be muted from the keyboard.
  readonly property bool headerHasCursor: cursorActive && focusSection === "header"
  // Only channels that actually exist get a vote. A box with no default source
  // would otherwise report "input unmuted" forever, leaving the hero switch
  // able to mute but never to unmute.
  readonly property bool hasOutput: !!(volumeSink && volumeSink.audio)
  readonly property bool hasInput: !!(source && source.audio)
  readonly property bool anyAudible: (hasOutput && !outputMuted) || (hasInput && !inputMuted)
  readonly property string toggleHint: anyAudible ? "Mute" : "Unmute"

  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.foreground, Color.accent)
    : "transparent"
  readonly property color selectedFill: bar
    ? Style.selectedFillFor(bar.foreground, Color.accent)
    : "transparent"

  function sectionCount(section) {
    if (section === "output") return displayAudioSinks.length
    if (section === "input") return displayAudioSources.length
    if (section === "streams") return displayAudioStreams.length
    if (section === "disabled") return disabledExpanded ? disabledDevices.length : 0
    return 0
  }

  function sectionVisible(section) {
    if (section === "output") return true
    if (section === "input") return displayAudioSources.length > 0 || !!source
    if (section === "streams") return displayAudioStreams.length > 0
    if (section === "disabled") return disabledDevices.length > 0
    return false
  }

  function sectionHasSlider(section) {
    if (section === "output") return true
    if (section === "input") return !!source
    if (section === "disabled") return true  // index -1 is the Show/Hide field
    return false  // stream rows carry their own sliders inline; not a section-level slider
  }

  // Order of visible sections, recomputed reactively so dropping a section
  // (e.g. no input devices) doesn't leave the cursor pointing at it.
  readonly property var visibleSections: {
    var list = []
    if (sectionVisible("output")) list.push("output")
    if (sectionVisible("input")) list.push("input")
    if (sectionVisible("streams")) list.push("streams")
    if (sectionVisible("disabled")) list.push("disabled")
    return list
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (sections.length === 0) return
    if (focusSection === "header") {
      if (delta > 0) { focusSection = sections[0]; selectedIndex = sectionHasSlider(sections[0]) ? -1 : 0 }
      return
    }
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) { focusSection = sections[0]; selectedIndex = sectionHasSlider(focusSection) ? -1 : 0; return }

    var idx = selectedIndex
    var max = sectionCount(focusSection) - 1  // last device index
    var hasSlider = sectionHasSlider(focusSection)
    var floor = hasSlider ? -1 : 0  // -1 = slider row

    if (delta > 0) {
      if (idx < max) { selectedIndex = idx + 1; return }
      // Fall through to next section.
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionHasSlider(focusSection) ? -1 : 0
      }
    } else {
      if (idx > floor) { selectedIndex = idx - 1; return }
      // Escape upward.
      if (sIdx > 0) {
        focusSection = sections[sIdx - 1]
        var prevMax = sectionCount(focusSection) - 1
        selectedIndex = prevMax >= 0 ? prevMax : (sectionHasSlider(focusSection) ? -1 : 0)
      } else {
        focusSection = "header"
      }
    }
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
    selectedIndex = -1
  }

  function moveSection(delta) {
    var sections = visibleSections
    if (sections.length === 0) return
    var current = sections.indexOf(focusSection)
    if (current < 0) current = delta > 0 ? -1 : 0
    var next = (current + delta + sections.length) % sections.length
    focusSection = sections[next]
    selectedIndex = sectionHasSlider(focusSection) ? -1 : 0
    cursorActive = true
  }

  // Adjust the slider associated with the focused section. Output and
  // input sliders are real volume controls; on stream rows h/l adjusts
  // that stream's volume (so keyboard parity with the inline slider).
  // For device rows (selectedIndex >= 0 in output/input) h/l is a no-op
  // — the cursor is on a discrete row, not on the slider, and silently
  // moving the global slider would surprise the user.
  function adjustVolume(delta) {
    if (focusSection === "output" && selectedIndex === -1) {
      setOutputVolume(outputVolume + delta)
      return
    }
    if (focusSection === "input" && selectedIndex === -1) {
      setInputVolume(inputVolume + delta)
      return
    }
    if (focusSection === "streams" && selectedIndex >= 0 && selectedIndex < displayAudioStreams.length) {
      var s = displayAudioStreams[selectedIndex]
      if (s && s.audio) s.audio.volume = Math.max(0, Math.min(1.5, s.audio.volume + delta))
    }
  }

  // Enter/Space: activate whatever the cursor is on.
  function activateCursor() {
    if (focusSection === "header") { toggleAllMuted(); return }
    if (focusSection === "output") {
      if (selectedIndex === -1) { toggleOutputMute(); return }
      var sink = displayAudioSinks[selectedIndex]
      if (sink) setDefaultSink(sink)
      return
    }
    if (focusSection === "input") {
      if (selectedIndex === -1) { toggleInputMute(); return }
      var src = displayAudioSources[selectedIndex]
      if (src) setDefaultSource(src)
      return
    }
    if (focusSection === "streams" && selectedIndex >= 0) {
      var st = displayAudioStreams[selectedIndex]
      if (st && st.audio) st.audio.muted = !st.audio.muted
      return
    }
    if (focusSection === "disabled" && selectedIndex === -1) disabledExpanded = !disabledExpanded
    else if (focusSection === "disabled" && selectedIndex >= 0 && selectedIndex < disabledDevices.length)
      enableDevice(disabledDevices[selectedIndex])
  }

  onOpenedChanged: {
    if (opened) {
      refreshDisplayAudioModels()
      refreshHelperState()
      expandedStreamId = -1
      disabledExpanded = false
      settingsOpen = false
      focusSection = "output"
      selectedIndex = -1  // first keyboard cursor reveal starts on the output slider
      cursorActive = false
      Qt.callLater(resetScroll)
    } else {
      clearDisplayAudioModels()
    }
  }

  // Clamp / repair the cursor whenever any list refreshes underneath us.
  onAudioSinksChanged: scheduleDisplayAudioModelRefresh()
  onAudioSourcesChanged: scheduleDisplayAudioModelRefresh()
  onAudioStreamsChanged: {
    scheduleDisplayAudioModelRefresh()
    if (hasPins) pinApplyTimer.restart()
  }

  function listSnapshot(list) {
    return Model.listSnapshot(list)
  }

  function refreshDisplayAudioModels() {
    if (!opened) return
    displayAudioSinks = listSnapshot(audioSinks)
    displayAudioSources = listSnapshot(audioSources)
    displayAudioStreams = listSnapshot(audioStreams)
    streamsRefreshTimer.restart()
    clampCursor()
  }

  function scheduleDisplayAudioModelRefresh() {
    if (!opened) return
    audioModelRefreshTimer.restart()
  }

  function clearDisplayAudioModels() {
    audioModelRefreshTimer.stop()
    displayAudioSinks = []
    displayAudioSources = []
    displayAudioStreams = []
  }

  // Keep the keyboard-focused row inside the visible viewport of the
  // ScrollView. Each cursor target (slider rows, SinkRow, SourceRow,
  // StreamRow) calls this when it gains hasCursor. Without it, j/k can
  // walk the selection off-screen — wifi uses ListView.positionViewAtIndex
  // for this; we don't have that affordance with a multi-section Column.
  function resetScroll() {
    if (!scrollArea) return
    var flick = scrollArea.contentItem
    if (flick && flick.contentY !== undefined) flick.contentY = 0
  }

  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    // Stock snapped to the top whenever the overflow was under
    // root.sp(24), or whenever the cursor touched the output slider.
    // Hover handlers pass through the output slider on their way to a row,
    // and this panel's extra sections overflow only a little, so both made
    // the footer unreachable. Only move when the row is out of view.
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var target = Model.scrollTargetFor({
      top: pt.y,
      bottom: pt.y + (item.height || 0),
      viewTop: flick.contentY,
      viewHeight: flick.height,
      maxY: Math.max(0, (flick.contentHeight || 0) - flick.height),
      margin: 6
    })
    // Revealing the output slider shows the header above it too.
    if (target !== flick.contentY && root.focusSection === "output" && root.selectedIndex === -1) target = 0
    flick.contentY = target
  }


  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    // "header" is virtual and never appears in visibleSections, so it has to
    // be let through: muting republishes the PipeWire snapshot, and clamping
    // would knock the cursor off the hero switch on every toggle.
    if (focusSection === "header") return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = visibleSections[0]
      selectedIndex = sectionHasSlider(focusSection) ? -1 : 0
      return
    }
    var count = sectionCount(focusSection)
    var hasSlider = sectionHasSlider(focusSection)
    var floor = hasSlider ? -1 : 0
    if (selectedIndex > count - 1) selectedIndex = Math.max(floor, count - 1)
    if (selectedIndex < floor) selectedIndex = floor
  }

  function outputIcon(volume) {
    // Match the old Waybar pulseaudio glyph set. The Material Design speaker
    // icons render visually smaller in JetBrainsMono Nerd Font.
    if (!sink || !sink.audio) return ""
    if (isHeadphones(sink)) return "󰋋"
    if (outputMuted) return ""
    var v = volume === undefined ? outputVolume : volume
    if (v >= 0.67) return ""
    if (v >= 0.34) return ""
    if (v > 0) return ""
    return ""
  }

  function inputIcon() {
    if (!source || !source.audio) return "󰍭"
    return inputMuted ? "󰍭" : "󰍬"
  }

  // Playful mood-name for a given output volume. Mirrors the brightness
  // panel's brightnessName ladder; bands are wide enough that small
  // tweaks don't rename the room you're in.
  function outputVolumeName(volume, muted) {
    return Model.outputVolumeName(volume, muted)
  }

  function setOutputVolume(v) {
    if (!volumeSink || !volumeSink.audio) return outputVolume
    var volume = Math.max(0, Math.min(1, v))
    volumeSink.audio.volume = volume
    return volume
  }

  function showVolumeOsd(volume) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: outputIcon(volume),
      value: Math.round(volume * 100)
    }))
  }

  function setInputVolume(v) {
    if (!source || !source.audio) return
    source.audio.volume = Math.max(0, Math.min(1, v))
  }

  function toggleOutputMute() {
    if (volumeSink && volumeSink.audio) volumeSink.audio.muted = !volumeSink.audio.muted
  }

  function toggleInputMute() {
    if (source && source.audio) source.audio.muted = !source.audio.muted
  }

  // The hero switch is the whole panel's on/off, so it carries both channels
  // at once. It reads as on while anything is still audible, which keeps
  // muting a single channel from the row below flipping the master switch.
  function toggleAllMuted() {
    var mute = anyAudible
    if (hasOutput) volumeSink.audio.muted = mute
    if (hasInput) source.audio.muted = mute
  }

  function setDefaultSink(node) {
    if (!node) return
    Pipewire.preferredDefaultAudioSink = node
    // Unlike omarchy-audio-output-set-default, the helper leaves streams that
    // were routed to a specific output where they are.
    if (node.id !== undefined && node.name)
      runHelper(["set-default-sink", String(node.id), String(node.name)])
  }

  // ---- Device disabling and per-app routing ----
  // Both go through bin/omaudiopanel: disabling switches the device's card
  // profile; routing sets target.object in the default metadata.
  readonly property string helperPath: decodeURIComponent(
    String(Qt.resolvedUrl("bin/omaudiopanel")).replace(/^file:\/\//, ""))

  property var disabledDevices: []  // [{ name, kind, label }]
  property bool disabledExpanded: false
  property var streamInfo: ({})     // stream node id -> { current, routed } sink names
  property int expandedStreamId: -1

  function runHelper(args) {
    Quickshell.execDetached([helperPath].concat(args))
  }

  function refreshHelperState() {
    if (!disabledListProc.running) disabledListProc.running = true
    if (!streamsProc.running) streamsProc.running = true
    if (!pinsProc.running) pinsProc.running = true
  }

  // ---- Pins: always play an app on one output ----
  // app name -> { sink, label }. Loaded at startup, since pins are applied to
  // new streams whether or not the panel is open.
  property var pins: ({})
  readonly property bool hasPins: Object.keys(pins).length > 0

  Component.onCompleted: pinsProc.running = true

  // New streams, and outputs coming or going, can each need a pin applied.
  // Both instances of the panel (one per monitor) may do this; it is idempotent.
  onCandidateSinksChanged: if (hasPins) pinApplyTimer.restart()

  function streamApp(stream) {
    var info = stream ? streamInfo[stream.id] : null
    return info ? info.app : ""
  }

  function streamPin(stream) {
    var app = streamApp(stream)
    return app && pins[app] ? pins[app] : null
  }

  function sinkPresent(name) {
    for (var i = 0; i < candidateSinks.length; i++)
      if (String(candidateSinks[i].name) === name) return true
    return false
  }

  function pinStream(stream, sinkName, label) {
    var app = streamApp(stream)
    if (!app || !sinkName) return
    var next = Object.assign({}, pins)
    next[app] = { sink: sinkName, label: label }
    pins = next
    pinsCommand(["pin", app, sinkName, label])
  }

  function unpinStream(stream) {
    var app = streamApp(stream)
    if (!app || !pins[app]) return
    var next = Object.assign({}, pins)
    delete next[app]
    pins = next
    pinsCommand(["unpin", app])
  }

  function pinsCommand(args) {
    pinCommandProc.command = [helperPath].concat(args)
    pinCommandProc.running = true
  }

  // Tab titles for browser streams; see Model.streamTitles.
  readonly property var streamTitleInfo: {
    var list = []
    for (var i = 0; i < displayAudioStreams.length; i++) {
      var id = displayAudioStreams[i].id
      var info = streamInfo[id]
      list.push({ id: id, app: info ? info.app : streamLabel(displayAudioStreams[i]), paused: info ? info.paused : false })
    }
    return Model.streamTitles(list, mprisPlayers)
  }

  function streamDisplayName(stream) {
    return stream ? Model.streamDisplayName(streamLabel(stream), streamTitleInfo[stream.id]) : "Stream"
  }

  function streamRouteSummary(stream) {
    var pin = streamPin(stream)
    return Model.routeSummary({
      currentLabel: streamCurrentSinkLabel(stream),
      routed: streamRouteName(stream) !== "",
      app: streamApp(stream) || streamLabel(stream),
      pin: pin,
      pinAvailable: !!pin && sinkPresent(pin.sink)
    })
  }

  // Disabling switches only that device's card profile, so the node goes
  // away the same way an unplugged device does and everything else keeps
  // playing. The list is updated right away and re-read when the helper exits.
  function disableDevice(node, kind) {
    if (!node || !node.name || deviceProc.running) return
    var label = nodeLabel(node)
    disabledDevices = disabledDevices.concat([{ name: String(node.name), kind: kind, label: label }])
    deviceProc.command = [helperPath, "disable", String(node.name), kind, label]
    deviceProc.running = true
  }

  function enableDevice(entry) {
    if (!entry || !entry.name || deviceProc.running) return
    disabledDevices = disabledDevices.filter(function(d) { return d.name !== entry.name })
    deviceProc.command = [helperPath, "enable", entry.name]
    deviceProc.running = true
  }

  function streamRouteName(stream) {
    var info = stream ? streamInfo[stream.id] : null
    return info ? info.routed : ""
  }

  function sinkLabelFor(name) {
    for (var i = 0; i < displayAudioSinks.length; i++)
      if (String(displayAudioSinks[i].name) === name) return nodeLabel(displayAudioSinks[i])
    return name
  }

  function streamCurrentSinkLabel(stream) {
    var info = stream ? streamInfo[stream.id] : null
    if (!info || !info.current) return "Default output"
    return sinkLabelFor(info.current)
  }

  // sinkNode null means follow the default output again.
  function routeStream(stream, sinkNode) {
    if (!stream) return
    var next = Object.assign({}, streamInfo)
    var name = sinkNode ? String(sinkNode.name) : ""
    var old = next[stream.id] || { current: "", app: "", paused: false }
    next[stream.id] = { current: name || old.current, routed: name, app: old.app, paused: old.paused }
    if (sinkNode) runHelper(["route", String(stream.id), name])
    else runHelper(["unroute", String(stream.id)])
    streamInfo = next
    streamsRefreshTimer.restart()

    // A pin follows the chosen output; going back to the default ends it.
    if (streamPin(stream)) {
      if (sinkNode) pinStream(stream, name, nodeLabel(sinkNode))
      else unpinStream(stream)
    }
  }

  // Keyboard: step default -> each output -> default.
  function cycleStreamRoute(stream) {
    var sinks = displayAudioSinks
    var current = streamRouteName(stream)
    var idx = -1
    for (var i = 0; i < sinks.length; i++)
      if (String(sinks[i].name) === current) idx = i
    routeStream(stream, idx + 1 < sinks.length ? sinks[idx + 1] : null)
  }

  function setDefaultSource(node) {
    if (!node) return
    Pipewire.preferredDefaultAudioSource = node
    if (node.id !== undefined && node.name) {
      Quickshell.execDetached([
        "omarchy-audio-input-set-default",
        String(node.id),
        String(node.name)
      ])
    }
  }

  function sinkAvailable(node) {
    if (!node || !node.name || !sinkAvailabilityLoaded) return true
    var name = String(node.name)
    return sinkAvailability[name] !== false
  }

  function updateSinkAvailability(raw) {
    sinkAvailability = Model.parseSinkAvailability(raw)
    sinkAvailabilityLoaded = true
  }

  function friendlyDeviceLabel(text) {
    return Model.friendlyDeviceLabel(text)
  }

  function nodeLabel(node) {
    return Model.nodeLabel(node)
  }

  function nodeProps(node) {
    return Model.nodeProps(node)
  }

  function isHeadphones(node) {
    return Model.isHeadphones(node)
  }

  function sinkGlyph(node) {
    return Model.sinkGlyph(node)
  }

  function sourceGlyph(node) {
    return Model.sourceGlyph(node)
  }

  function friendlyStreamLabel(label) {
    return Model.friendlyStreamLabel(label)
  }

  function streamLabelKey(label) {
    return Model.streamLabelKey(label)
  }

  function streamLabelIsGeneric(label) {
    return Model.streamLabelIsGeneric(label)
  }

  function rawStreamLabel(node) {
    return Model.rawStreamLabel(node)
  }

  function mprisPlayerLabel(player) {
    return Model.mprisPlayerLabel(player)
  }

  function mprisPlayerIsProxy(player) {
    return Model.mprisPlayerIsProxy(player)
  }

  function streamRepresentsMprisPlayer(streamLabel, playerLabel) {
    return Model.streamRepresentsMprisPlayer(streamLabel, playerLabel)
  }

  function mprisLabelsFor(predicate) {
    return Model.mprisLabelsFor(mprisPlayers, predicate)
  }

  function matchingMprisStreamLabel(label) {
    return Model.matchingMprisStreamLabel(label, mprisPlayers)
  }

  function unmatchedMprisStreamLabel(label) {
    // Spotify exposes its PipeWire stream as "audio-src". For generic stream
    // names, use the one MPRIS player not already represented by another audio
    // stream (e.g. Chromium, or ALSA apps like cliamp).
    return Model.unmatchedMprisStreamLabel(label, mprisPlayers, displayAudioStreams)
  }

  function streamLabel(node) {
    return Model.streamLabel(node, mprisPlayers, displayAudioStreams)
  }

  function streamRepresentsPlayer(node, player) {
    return Model.streamRepresentsPlayer(node, player, mprisPlayers, displayAudioStreams)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  PwObjectTracker { objects: root.candidateSinks }
  PwObjectTracker { objects: root.candidateSources }
  PwObjectTracker { objects: root.audioStreams }

  PwNodePeakMonitor {
    id: inputPeakMonitor
    node: root.source
    enabled: root.opened && !!root.source
  }

  // Drives the "playing" bars next to OUTPUT; the per-app bars have their own.
  PwNodePeakMonitor {
    id: outputPeakMonitor
    node: root.volumeSink
    enabled: root.opened && root.showPlayingBars && !!root.volumeSink
  }

  // Animation phase shared by every EqBars, advanced only while open.
  property real eqPhase: 0
  Timer {
    interval: 90
    running: root.opened && root.showPlayingBars
    repeat: true
    onTriggered: root.eqPhase = (root.eqPhase + 0.55) % (Math.PI * 2)
  }

  Process {
    id: sinkAvailabilityProc
    command: ["omarchy-audio-sink-availability"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateSinkAvailability(text)
    }
  }

  Process {
    id: volumeSinkProc
    command: ["omarchy-audio-output-sink"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.volumeSinkName = String(text).trim()
    }
  }

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!sinkAvailabilityProc.running) sinkAvailabilityProc.running = true
      if (!streamsProc.running) streamsProc.running = true
    }
  }

  // Runs whether or not the panel is open: the bar shows and scrolls the output
  // volume too, so an unresolved sink there would read and change the virtual
  // tuning sink instead of the speakers.
  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.resolveVolumeSink()
  }

  Process {
    id: disabledListProc
    command: [root.helperPath, "list-disabled"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.disabledDevices = Model.parseDisabledDevices(text)
    }
  }

  Process {
    id: deviceProc
    onExited: root.refreshHelperState()
  }

  Process {
    id: pinsProc
    command: [root.helperPath, "list-pins"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.pins = Model.parsePins(text)
    }
  }

  Process {
    id: pinCommandProc
    onExited: streamsRefreshTimer.restart()
  }

  Timer {
    id: pinApplyTimer
    interval: 600
    repeat: false
    onTriggered: {
      root.runHelper(["apply-pins"])
      streamsRefreshTimer.restart()
    }
  }

  Process {
    id: streamsProc
    command: [root.helperPath, "list-streams"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.streamInfo = Model.parseStreams(text)
    }
  }

  // Re-read the metadata shortly after routing so the panel reflects what
  // WirePlumber actually kept.
  Timer {
    id: streamsRefreshTimer
    interval: 400
    repeat: false
    onTriggered: if (!streamsProc.running) streamsProc.running = true
  }

  Timer {
    id: audioModelRefreshTimer
    interval: 75
    repeat: false
    onTriggered: root.refreshDisplayAudioModels()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.outputIcon()
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleAllMuted()
      else root.toggle()
    }

    onWheelMoved: function(delta) {
      if (!root.hasOutput) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      // Snap to the step grid so 2% steps land on 60, 62, 64 rather than drifting.
      var step = root.scrollStep / 100
      var target = Math.round((root.outputVolume + wheel.steps * step) / step) * step
      var volume = root.setOutputVolume(target)
      root.showVolumeOsd(volume)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.sp(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, root.sp(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustVolume(dx * root.scrollStep / 100)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        // 'm' mutes whatever the cursor is on: focused section's slider
        // for output/input, the focused stream for streams.
        if (t === "m" || t === "M") {
          if (!root.cursorActive) return
          if (root.focusSection === "streams" && root.selectedIndex >= 0
              && root.selectedIndex < root.displayAudioStreams.length) {
            var s = root.displayAudioStreams[root.selectedIndex]
            if (s && s.audio) s.audio.muted = !s.audio.muted
          } else if (root.focusSection === "input") {
            root.toggleInputMute()
          } else {
            root.toggleOutputMute()
          }
        }
        // 'd' disables the focused output/input device.
        if (t === "d" || t === "D") {
          if (!root.cursorActive || root.selectedIndex < 0) return
          if (root.focusSection === "output")
            root.disableDevice(root.displayAudioSinks[root.selectedIndex], "sink")
          else if (root.focusSection === "input")
            root.disableDevice(root.displayAudioSources[root.selectedIndex], "source")
        }
        // 'r' steps the focused stream through the outputs.
        if (t === "r" || t === "R") {
          if (!root.cursorActive || root.focusSection !== "streams") return
          if (root.selectedIndex >= 0 && root.selectedIndex < root.displayAudioStreams.length)
            root.cycleStreamRoute(root.displayAudioStreams[root.selectedIndex])
        }
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: root.sp(14)

          // ---------- Hero: speaker icon · title/status ----------
          Item {
            id: heroItem
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, powerSwitch.implicitHeight)

            // Status only — the switch owns muting, mouse and keyboard alike.
            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.outputIcon()
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontDisplay
              opacity: root.outputMuted ? 0.5 : 1.0
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            // Compact on/off switch on the trailing edge of the hero, and the
            // header's only cursor target. Checked means something is still
            // audible, so muting everything reads as switching audio off.
            AccentSwitch {
              id: powerSwitch
              checked: root.anyAudible
              // Keyboard focus only; hovering no longer moves the cursor here,
              // so the pointer never triggers the focus look.
              focused: root.headerHasCursor
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.toggleAllMuted()

              PanelToolTip {
                visible: powerSwitch.containsMouse
                text: root.toggleHint
                fontFamily: root.bar.fontFamily
              }
            }

            // Opens the settings view in place of the panel content.
            Text {
              id: gearButton
              anchors.right: powerSwitch.left
              anchors.rightMargin: root.sp(12)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.settingsOpen ? "󰅖" : "󰒓"
              // Larger than the header text and accent on hover, so it reads
              // as a control rather than decoration.
              color: gearMouse.containsMouse || root.settingsOpen ? Color.accent : root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Math.round(root.fontTitle * 1.45)
              opacity: gearMouse.containsMouse || root.settingsOpen ? 1.0 : 0.85

              MouseArea {
                id: gearMouse
                anchors.fill: parent
                anchors.margins: -root.sp(4)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.settingsOpen = !root.settingsOpen
                  root.cursorActive = false
                }
              }

              PanelToolTip {
                visible: gearMouse.containsMouse
                text: root.settingsOpen ? "Close settings" : "Panel settings"
                fontFamily: root.bar.fontFamily
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: root.sp(14)
              anchors.right: parent.right
              anchors.rightMargin: powerSwitch.width + gearButton.width + root.sp(24)
              anchors.verticalCenter: parent.verticalCenter
              spacing: root.sp(2)

              Text {
                text: "Audio"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontTitle
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                textFormat: Text.PlainText
                text: root.outputVolumeName(
                  outputSlider.dragging ? outputSlider.liveValue : root.outputVolume,
                  root.outputMuted
                ).toUpperCase()
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontCaption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // Everything below the header; the gear swaps it for the settings view.
          Column {
            id: mainView
            width: parent.width
            spacing: root.sp(14)
            visible: !root.settingsOpen

            // ---- Output devices ----
            PanelSeparator {
              foreground: root.bar.foreground
            }

            Column {
              width: parent.width
              spacing: root.sp(6)

              Item {
                width: parent.width
                implicitHeight: Math.max(outputHeader.implicitHeight, outputPercent.implicitHeight)

                PanelSectionHeader {
                  id: outputHeader
                  text: "OUTPUT"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                EqBars {
                  peak: outputPeakMonitor.peak
                  anchors.left: outputHeader.right
                  anchors.leftMargin: root.sp(8)
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: outputPercent
                  textFormat: Text.PlainText
                  text: Math.round((outputSlider.dragging ? outputSlider.liveValue : root.outputVolume) * 100) + "%"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontCaption
                  font.bold: true
                  anchors.right: parent.right
                  anchors.rightMargin: root.sp(6)
                  anchors.verticalCenter: parent.verticalCenter
                  opacity: root.outputMuted ? 0.5 : 1.0
                }
              }

              CursorSurface {
                id: outputSliderRow
                width: parent.width
                height: outputSlider.implicitHeight + (Style.spacing.controlGap * root.densityScale)
                hasCursor: root.cursorActive && root.focusSection === "output" && root.selectedIndex === -1
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(outputSliderRow)
                foreground: root.bar.foreground
                outline: true

                PanelSlider {
                  id: outputSlider
                  bar: root.bar
                  fillColor: Color.accent
                  knobColor: Color.accent
                  anchors.fill: parent
                  anchors.leftMargin: root.sp(6)
                  anchors.rightMargin: root.sp(6)
                  minimum: 0
                  maximum: 1
                  step: root.scrollStep / 100
                  value: root.outputVolume
                  opacity: root.outputMuted ? 0.5 : 1.0
                  enabled: !!root.sink

                  onMoved: function(v) { root.setOutputVolume(v) }
                  onRightClicked: root.toggleOutputMute()
                }

                HoverHandler {
                  onHoveredChanged: if (hovered) {
                    root.cursorActive = true
                    root.focusSection = "output"
                    root.selectedIndex = -1
                  }
                }
              }

              Repeater {
                model: root.displayAudioSinks

                SinkRow {
                  required property var modelData
                  required property int index
                  width: panelColumn.width
                  node: modelData
                  rowIndex: index
                }
              }
            }

            // ---- Input ----
            PanelSeparator {
              visible: root.displayAudioSources.length > 0 || !!root.source
              foreground: root.bar.foreground
            }

            Column {
              width: parent.width
              spacing: root.sp(6)
              visible: root.displayAudioSources.length > 0 || !!root.source

              Item {
                width: parent.width
                implicitHeight: Math.max(microphoneHeader.implicitHeight, microphonePercent.implicitHeight)

                PanelSectionHeader {
                  id: microphoneHeader
                  text: "INPUT"
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: microphonePercent
                  textFormat: Text.PlainText
                  text: Math.round((inputSlider.dragging ? inputSlider.liveValue : root.inputVolume) * 100) + "%"
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: root.fontCaption
                  font.bold: true
                  anchors.right: parent.right
                  anchors.rightMargin: root.sp(6)
                  anchors.verticalCenter: parent.verticalCenter
                  opacity: root.inputMuted ? 0.5 : 1.0
                }
              }

              CursorSurface {
                id: inputSliderRow
                visible: !!root.source
                width: parent.width
                height: inputControls.implicitHeight + (Style.spacing.controlGap * root.densityScale)
                hasCursor: root.cursorActive && root.focusSection === "input" && root.selectedIndex === -1
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(inputSliderRow)
                foreground: root.bar.foreground
                outline: true

                Column {
                  id: inputControls
                  anchors.fill: parent
                  anchors.leftMargin: root.sp(6)
                  anchors.rightMargin: root.sp(6)
                  spacing: root.sp(5)

                  PanelSlider {
                    id: inputSlider
                    bar: root.bar
                    fillColor: Color.accent
                    knobColor: Color.accent
                    width: parent.width
                    minimum: 0
                    maximum: 1
                    step: root.scrollStep / 100
                    value: root.inputVolume
                    opacity: root.inputMuted ? 0.5 : 1.0
                    enabled: !!root.source

                    onMoved: function(v) { root.setInputVolume(v) }
                    onRightClicked: root.toggleInputMute()
                  }

                  Rectangle {
                    width: parent.width
                    height: Math.max(root.sp(5), (Style.spacing.xs * root.densityScale))
                    color: Util.alpha(root.bar.foreground, 0.18)
                    opacity: root.inputMuted ? 0.35 : 1.0

                    Rectangle {
                      height: parent.height
                      width: parent.width * Math.max(0, Math.min(1, inputPeakMonitor.peak))
                      color: Color.accent
                      Behavior on width { NumberAnimation { duration: 70 } }
                    }
                  }
                }

                HoverHandler {
                  onHoveredChanged: if (hovered) {
                    root.cursorActive = true
                    root.focusSection = "input"
                    root.selectedIndex = -1
                  }
                }
              }

              Repeater {
                model: root.displayAudioSources

                SourceRow {
                  required property var modelData
                  required property int index
                  width: panelColumn.width
                  node: modelData
                  rowIndex: index
                }
              }
            }

            // ---- Per-app streams ----
            PanelSeparator {
              visible: root.displayAudioStreams.length > 0
              foreground: root.bar.foreground
            }

            Column {
              width: parent.width
              spacing: root.sp(10)
              visible: root.displayAudioStreams.length > 0

              PanelSectionHeader {
                text: "SOURCES"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              Repeater {
                model: root.displayAudioStreams

                StreamRow {
                  required property var modelData
                  required property int index
                  width: panelColumn.width
                  node: modelData
                  rowIndex: index
                }
              }
            }

            // ---- Disabled devices ----
            PanelSeparator {
              visible: root.showDisabled && root.disabledDevices.length > 0
              foreground: root.bar.foreground
            }

            Column {
              width: parent.width
              spacing: root.sp(6)
              visible: root.showDisabled && root.disabledDevices.length > 0

              PanelSectionHeader {
                text: "DISABLED"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              // Collapsed by default: the devices matter only when turning one
              // back on.
              DropdownField {
                id: disabledField
                width: parent.width
                glyph: "󰐥"
                summary: root.disabledDevices.length === 1
                  ? "1 device turned off"
                  : root.disabledDevices.length + " devices turned off"
                actionText: root.disabledExpanded ? "Hide" : "Show"
                expanded: root.disabledExpanded
                hasCursor: root.cursorActive && root.focusSection === "disabled" && root.selectedIndex === -1
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(disabledField)
                onToggled: root.disabledExpanded = !root.disabledExpanded
                onHeaderHovered: {
                  root.cursorActive = true
                  root.focusSection = "disabled"
                  root.selectedIndex = -1
                }

                Repeater {
                  model: root.disabledExpanded ? root.disabledDevices : []

                  DisabledRow {
                    required property var modelData
                    required property int index
                    width: disabledField.bodyWidth
                    entry: modelData
                    rowIndex: index
                  }
                }
              }
            }

            // ---- Scroll step ----
            PanelSeparator {
              visible: root.showStepFooter
              foreground: root.bar.foreground
            }

            Item {
              visible: root.showStepFooter
              width: parent.width
              implicitHeight: Math.max(scrollStepLabel.implicitHeight, scrollStepChips.implicitHeight)

              Text {
                id: scrollStepLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "Volume step (scroll, keys)"
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontCaption
                elide: Text.ElideRight
                width: parent.width - scrollStepChips.width - root.sp(8)
              }

              ChoiceChips {
                id: scrollStepChips
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                choices: root.scrollStepChoices.map(function(v) { return { value: v, label: v + "%" } })
                selected: root.scrollStep
                onPicked: function(value) { root.setScrollStep(value) }
              }
            }
          }

          SettingsView {
            width: parent.width
            visible: root.settingsOpen
          }
        }
      }
    }
  }

  // ---- Reusable inline components ----

  // Output device row — cursor target inside the "output" section. Mouse
  // hover updates the panel cursor at the root; visuals come entirely
  // from hasCursor/current via CursorSurface, never from containsMouse.
  component SinkRow: CursorSurface {
    id: sinkRow
    required property var node
    required property int rowIndex

    readonly property bool isActive: root.sink && node && root.sink.id === node.id

    // Accent stripe marking the device in use.
    Rectangle {
      visible: sinkRow.isActive
      anchors.left: parent.left
      anchors.leftMargin: root.sp(2)
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(2, root.sp(3))
      height: parent.height * 0.55
      radius: width / 2
      color: Color.accent
    }
    hasCursor: root.cursorActive && root.focusSection === "output" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sinkRow)
    current: isActive
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: sinkInner.implicitHeight + (Style.spacing.xl * root.densityScale)

    Row {
      id: sinkInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: root.sp(6)
      anchors.rightMargin: root.sp(6)
      spacing: root.sp(8)

      Text {
        textFormat: Text.PlainText
        text: root.sinkGlyph(sinkRow.node)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontTitle
        width: root.sp(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: root.nodeLabel(sinkRow.node)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontBody
        font.bold: sinkRow.isActive
        elide: Text.ElideRight
        width: parent.width - 2 * (root.sp(22) + root.sp(8))
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = "output"
        root.selectedIndex = sinkRow.rowIndex
      }
      onClicked: root.setDefaultSink(sinkRow.node)
    }

    DisableButton {
      node: sinkRow.node
      kind: "sink"
      shown: sinkRow.hasCursor
      anchors.right: parent.right
      anchors.rightMargin: root.sp(6)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // Input device row — sibling of SinkRow for the "input" section.
  component SourceRow: CursorSurface {
    id: sourceRow
    required property var node
    required property int rowIndex

    readonly property bool isActive: root.source && node && root.source.id === node.id

    // Accent stripe marking the device in use.
    Rectangle {
      visible: sourceRow.isActive
      anchors.left: parent.left
      anchors.leftMargin: root.sp(2)
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(2, root.sp(3))
      height: parent.height * 0.55
      radius: width / 2
      color: Color.accent
    }
    hasCursor: root.cursorActive && root.focusSection === "input" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sourceRow)
    current: isActive
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: sourceInner.implicitHeight + (Style.spacing.xl * root.densityScale)

    Row {
      id: sourceInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: root.sp(6)
      anchors.rightMargin: root.sp(6)
      spacing: root.sp(8)

      Text {
        textFormat: Text.PlainText
        text: root.sourceGlyph(sourceRow.node)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontTitle
        width: root.sp(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: root.nodeLabel(sourceRow.node)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontBody
        font.bold: sourceRow.isActive
        elide: Text.ElideRight
        width: parent.width - 2 * (root.sp(22) + root.sp(8))
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = "input"
        root.selectedIndex = sourceRow.rowIndex
      }
      onClicked: root.setDefaultSource(sourceRow.node)
    }

    DisableButton {
      node: sourceRow.node
      kind: "source"
      shown: sourceRow.hasCursor
      anchors.right: parent.right
      anchors.rightMargin: root.sp(6)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // Per-app stream row — cursor target inside the "streams" section.
  // The stream has its own slider inline, so h/l from the keyboard
  // adjusts THIS stream's volume (not the global output) when the cursor
  // sits on this row. Enter/Space mutes the stream.
  component StreamRow: CursorSurface {
    id: streamRow
    required property var node
    required property int rowIndex

    readonly property real streamVolume: node && node.audio ? node.audio.volume : 0

    PwNodePeakMonitor {
      id: streamPeak
      node: streamRow.node
      enabled: root.opened && root.showPlayingBars && !!streamRow.node
    }
    readonly property bool streamMuted: node && node.audio ? node.audio.muted : false
    readonly property bool isActive: root.streamRepresentsPlayer(node, root.activeMediaPlayer)

    readonly property bool routed: root.streamRouteName(node) !== ""
    readonly property bool routeExpanded: !!node && root.expandedStreamId === node.id
    readonly property var routeChoices: {
      if (!routeExpanded) return []
      var list = [{ sink: null }]
      for (var i = 0; i < root.displayAudioSinks.length; i++)
        list.push({ sink: root.displayAudioSinks[i] })
      return list
    }

    hasCursor: root.cursorActive && root.focusSection === "streams" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(streamRow)
    current: isActive
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: streamColumn.implicitHeight + (Style.spacing.xl * root.densityScale)

    Column {
      id: streamColumn
      // Apps play into the output, so they fade with it when it is muted,
      // like the output and input rows do.
      opacity: root.outputMuted ? 0.5 : 1.0
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: root.sp(6)
      anchors.rightMargin: root.sp(6)
      spacing: root.sp(2)

      Row {
        width: parent.width
        spacing: root.sp(8)

        Text {
          id: streamMuteIcon
          textFormat: Text.PlainText
          text: streamRow.streamMuted ? "󰝟" : "󰕾"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: root.fontTitle
          width: root.sp(22)
          horizontalAlignment: Text.AlignHCenter
          anchors.verticalCenter: parent.verticalCenter
          opacity: streamRow.streamMuted ? 0.5 : 1.0

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (streamRow.node && streamRow.node.audio)
                streamRow.node.audio.muted = !streamRow.node.audio.muted
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          text: root.streamDisplayName(streamRow.node)
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: root.fontBody
          font.bold: streamRow.isActive
          elide: Text.ElideRight
          width: parent.width - streamMuteIcon.width - streamPct.width - root.sp(16)
            - (streamEq.visible ? streamEq.width + root.sp(8) : 0)
          anchors.verticalCenter: parent.verticalCenter
        }

        EqBars {
          id: streamEq
          peak: streamPeak.peak
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: streamPct
          textFormat: Text.PlainText
          text: Math.round(streamRow.streamVolume * 100) + "%"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: root.fontCaption
          font.bold: true
          width: root.sp(36)
          horizontalAlignment: Text.AlignRight
          anchors.verticalCenter: parent.verticalCenter
          opacity: streamRow.streamMuted ? 0.5 : 1.0
        }
      }

      PanelSlider {
        bar: root.bar
        width: parent.width
        minimum: 0
        maximum: 1.5
        step: root.scrollStep / 100
        value: streamRow.streamVolume
        fillColor: Color.accent
        knobColor: Color.accent
        opacity: streamRow.streamMuted ? 0.5 : 1.0

        onMoved: function(v) {
          if (streamRow.node && streamRow.node.audio) streamRow.node.audio.volume = v
        }
        onRightClicked: {
          if (streamRow.node && streamRow.node.audio)
            streamRow.node.audio.muted = !streamRow.node.audio.muted
        }
      }

      // Where this app plays, as a field that opens to the output choices,
      // with a mute switch beside it (on = playing).
      Item {
        width: parent.width
        implicitHeight: Math.max(streamField.visible ? streamField.implicitHeight : 0, streamMuteSwitch.implicitHeight)

        AccentSwitch {
          id: streamMuteSwitch
          anchors.right: parent.right
          y: streamField.visible ? streamField.headerCenterY - height / 2 : 0
          checked: !streamRow.streamMuted
          onToggled: {
            if (streamRow.node && streamRow.node.audio)
              streamRow.node.audio.muted = !streamRow.node.audio.muted
          }

          PanelToolTip {
            visible: streamMuteSwitch.containsMouse
            text: (streamRow.streamMuted ? "Unmute " : "Mute ") + (root.streamApp(streamRow.node) || root.streamLabel(streamRow.node))
            fontFamily: root.bar.fontFamily
          }
        }

        DropdownField {
          id: streamField
          visible: root.showRouting
          anchors.left: parent.left
          anchors.right: streamMuteSwitch.left
          anchors.rightMargin: root.sp(8)
          glyph: "󰓃"
          summary: root.streamRouteSummary(streamRow.node)
          expanded: streamRow.routeExpanded
          onToggled: root.expandedStreamId = streamRow.routeExpanded ? -1 : streamRow.node.id

          Column {
            width: parent.width
            spacing: root.sp(3)

            Text {
              textFormat: Text.PlainText
              text: "Where should " + (root.streamApp(streamRow.node) || root.streamLabel(streamRow.node)) + " play?"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontCaption
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Repeater {
              model: streamRow.routeChoices

              Text {
                required property var modelData
                readonly property bool chosen: modelData.sink
                  ? root.streamRouteName(streamRow.node) === String(modelData.sink.name)
                  : !streamRow.routed
                textFormat: Text.PlainText
                text: (chosen ? "󰐾  " : "󰄰  ")
                  + (modelData.sink
                    ? root.nodeLabel(modelData.sink)
                    : "Default output (" + root.nodeLabel(root.sink) + ")")
                color: chosen ? Color.accent : (choiceMouse.containsMouse ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.25))
                font.family: root.bar.fontFamily
                font.pixelSize: root.fontCaption
                font.bold: chosen
                elide: Text.ElideRight
                width: parent.width
                leftPadding: root.sp(6)

                MouseArea {
                  id: choiceMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  // The picker stays open so the pin checkbox below can follow.
                  onClicked: root.routeStream(streamRow.node, parent.modelData.sink)
                }
              }
            }

            // Pins the app to the output chosen above, or to the one it is on now.
            Text {
              id: pinToggle
              readonly property var pin: root.streamPin(streamRow.node)
              readonly property string targetName: Model.pinTarget(root.streamInfo[streamRow.node ? streamRow.node.id : -1])
              readonly property bool checked: !!pin && pin.sink === targetName
              visible: targetName !== ""
              textFormat: Text.PlainText
              text: (checked ? "󰄲  " : "󰄱  ") + "Always play " + (root.streamApp(streamRow.node) || root.streamLabel(streamRow.node))
                + " on " + root.sinkLabelFor(targetName)
              color: checked ? Color.accent : (pinMouse.containsMouse ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.25))
              font.family: root.bar.fontFamily
              font.pixelSize: root.fontCaption
              font.bold: checked
              elide: Text.ElideRight
              width: parent.width
              leftPadding: root.sp(6)
              topPadding: root.sp(4)

              MouseArea {
                id: pinMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (pinToggle.checked) {
                    root.unpinStream(streamRow.node)
                    return
                  }
                  root.pinStream(streamRow.node, pinToggle.targetName, root.sinkLabelFor(pinToggle.targetName))
                }
              }
            }
          }
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      propagateComposedEvents: true
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = "streams"
        root.selectedIndex = streamRow.rowIndex
      }
    }
  }

  // Trailing power glyph on a device row; appears with the row's cursor.
  component DisableButton: Text {
    id: disableButton
    required property var node
    required property string kind
    property bool shown: false

    textFormat: Text.PlainText
    text: "󰐥"
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: root.fontBody
    width: root.sp(22)
    horizontalAlignment: Text.AlignHCenter
    opacity: shown ? (disableMouse.containsMouse ? 1.0 : 0.55) : 0

    MouseArea {
      id: disableMouse
      anchors.fill: parent
      enabled: disableButton.shown
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.disableDevice(disableButton.node, disableButton.kind)
    }

    PanelToolTip {
      visible: disableMouse.containsMouse && disableButton.shown
      text: "Disable device (d)"
      fontFamily: root.bar.fontFamily
    }
  }

  // Row in the "disabled" section. The device no longer exists in PipeWire,
  // so this works from the saved name and label; clicking re-enables it.
  component DisabledRow: CursorSurface {
    id: disabledRow
    required property var entry
    required property int rowIndex

    hasCursor: root.cursorActive && root.focusSection === "disabled" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(disabledRow)
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: disabledInner.implicitHeight + (Style.spacing.xl * root.densityScale)

    Row {
      id: disabledInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: root.sp(6)
      anchors.rightMargin: root.sp(6)
      spacing: root.sp(8)
      opacity: 0.55

      Text {
        textFormat: Text.PlainText
        text: disabledRow.entry.kind === "source" ? "󰍭" : "󰓄"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontTitle
        width: root.sp(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: disabledRow.entry.label
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontBody
        elide: Text.ElideRight
        width: parent.width - root.sp(22) - root.sp(8) - enableHint.width - root.sp(8)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: enableHint
        textFormat: Text.PlainText
        text: "ENABLE"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontCaption
        font.bold: true
        opacity: disabledRow.hasCursor ? 1.0 : 0
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = "disabled"
        root.selectedIndex = disabledRow.rowIndex
      }
      onClicked: root.enableDevice(disabledRow.entry)
    }
  }

  // An outlined field that reads as "click to choose": an icon, a summary and
  // a chevron. Its content (options) opens inside the same outline.
  component DropdownField: CursorSurface {
    id: field
    property bool expanded: false
    property string summary: ""
    property string glyph: ""
    property string actionText: ""
    readonly property real bodyWidth: width - 2 * root.sp(8)
    // Vertical middle of the summary line, for aligning controls beside it.
    readonly property real headerCenterY: fieldColumn.y + fieldHeader.y + fieldHeader.height / 2
    default property alias content: fieldBody.data
    signal toggled()
    signal headerHovered()

    bordered: true
    foreground: root.bar.foreground
    fill: root.hoverFill
    implicitHeight: fieldColumn.implicitHeight + 2 * root.sp(6)

    Column {
      id: fieldColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: root.sp(8)
      anchors.topMargin: root.sp(6)
      spacing: root.sp(6)

      Item {
        id: fieldHeader
        width: parent.width
        implicitHeight: Math.max(fieldSummary.implicitHeight, fieldAction.implicitHeight)
        opacity: fieldMouse.containsMouse || field.expanded || field.hasCursor ? 1.0 : 0.8

        Text {
          id: fieldGlyph
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: field.glyph
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: root.fontCaption
          width: text ? root.sp(18) : 0
        }

        Text {
          id: fieldSummary
          anchors.left: fieldGlyph.right
          anchors.right: fieldAction.left
          anchors.rightMargin: root.sp(8)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: field.summary
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: root.fontCaption
          elide: Text.ElideRight
        }

        Text {
          id: fieldAction
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: (field.actionText ? field.actionText + " " : "") + (field.expanded ? "󰅃" : "󰅀")
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: root.fontCaption
          font.bold: true
        }

        MouseArea {
          id: fieldMouse
          anchors.fill: parent
          anchors.margins: -root.sp(6)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onContainsMouseChanged: if (containsMouse) field.headerHovered()
          onClicked: field.toggled()
        }
      }

      Rectangle {
        visible: field.expanded
        width: parent.width
        height: 1
        color: Util.alpha(root.bar.foreground, 0.15)
      }

      Column {
        id: fieldBody
        visible: field.expanded
        width: parent.width
        spacing: root.sp(3)
      }
    }
  }

  // Three accent bars that move with a PipeWire peak level, in the spirit of
  // a "now playing" equalizer. Hidden while silent.
  component EqBars: Row {
    id: eq
    property real peak: 0
    readonly property var levels: Model.eqBarLevels(peak, root.eqPhase)
    readonly property real barHeight: Math.round(root.fontBody * 0.85)

    visible: root.showPlayingBars && levels[0] > 0
    spacing: Math.max(1, root.sp(2))
    height: barHeight

    Repeater {
      model: 3

      Rectangle {
        required property int index
        anchors.bottom: parent.bottom
        width: Math.max(2, root.sp(3))
        height: Math.max(2, eq.barHeight * eq.levels[index])
        radius: width / 2
        color: Color.accent
        Behavior on height { NumberAnimation { duration: 90 } }
      }
    }
  }

  // A row of text choices; the selected one is accent, bold and underlined.
  // choices: [{ value, label }].
  component ChoiceChips: Row {
    id: chips
    property var choices: []
    property var selected
    signal picked(var value)

    spacing: root.sp(8)

    Repeater {
      model: chips.choices

      Text {
        required property var modelData
        readonly property bool chosen: chips.selected === modelData.value
        textFormat: Text.PlainText
        text: modelData.label
        color: chosen ? Color.accent : root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontCaption
        font.bold: chosen
        font.underline: chosen
        opacity: chosen || chipMouse.containsMouse ? 1.0 : 0.55

        MouseArea {
          id: chipMouse
          anchors.fill: parent
          anchors.margins: -root.sp(3)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: chips.picked(parent.modelData.value)
        }
      }
    }
  }

  // A labelled on/off switch row for the settings view.
  component SettingSwitch: Item {
    id: settingRow
    property string label: ""
    property bool checked: false
    signal toggled()

    implicitHeight: Math.max(settingLabel.implicitHeight, settingToggle.implicitHeight)

    Text {
      id: settingLabel
      anchors.left: parent.left
      anchors.right: settingToggle.left
      anchors.rightMargin: root.sp(8)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: settingRow.label
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Math.round(root.fontBody * 0.92)
      elide: Text.ElideRight
    }

    AccentSwitch {
      id: settingToggle
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: settingRow.checked
      onToggled: settingRow.toggled()
    }
  }

  // Replaces the panel content while the gear is on. Every change is saved
  // to shell.json straight away and read back through setting().
  component SettingsView: Column {
    spacing: root.sp(12)

    PanelSeparator {
      foreground: root.bar.foreground
    }

    Item {
      width: parent.width
      implicitHeight: settingsBack.implicitHeight

      Text {
        id: settingsBack
        textFormat: Text.PlainText
        text: "󰁍 Back"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: root.fontCaption
        font.bold: true
        opacity: backMouse.containsMouse ? 1.0 : 0.75

        MouseArea {
          id: backMouse
          anchors.fill: parent
          anchors.margins: -root.sp(4)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.settingsOpen = false
        }
      }
    }

    PanelSectionHeader {
      text: "DENSITY"
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
    }

    ChoiceChips {
      choices: [
        { value: "compact", label: "Compact" },
        { value: "normal", label: "Normal" },
        { value: "comfortable", label: "Comfortable" }
      ]
      selected: root.density
      onPicked: function(value) { root.setSetting("density", value) }
    }

    PanelSectionHeader {
      text: "FONT SIZE"
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
    }

    ChoiceChips {
      choices: [
        { value: "small", label: "Small" },
        { value: "normal", label: "Normal" },
        { value: "large", label: "Large" }
      ]
      selected: root.fontSize
      onPicked: function(value) { root.setSetting("fontSize", value) }
    }

    PanelSeparator {
      foreground: root.bar.foreground
    }

    PanelSectionHeader {
      text: "SHOW"
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
    }

    // The switches sit closer together than the view's sections.
    Column {
      width: parent.width
      spacing: root.sp(6)

      SettingSwitch {
        width: parent.width
        label: "Playing bars"
        checked: root.showPlayingBars
        onToggled: root.setSetting("showPlayingBars", !root.showPlayingBars)
      }

      SettingSwitch {
        width: parent.width
        label: "Output field under each app"
        checked: root.showRouting
        onToggled: root.setSetting("showRouting", !root.showRouting)
      }

      SettingSwitch {
        width: parent.width
        label: "Disabled devices section"
        checked: root.showDisabled
        onToggled: root.setSetting("showDisabled", !root.showDisabled)
      }

      SettingSwitch {
        width: parent.width
        label: "Volume step footer"
        checked: root.showStepFooter
        onToggled: root.setSetting("showStepFooter", !root.showStepFooter)
      }
    }

    PanelSeparator {
      foreground: root.bar.foreground
    }

    PanelSectionHeader {
      text: "VOLUME STEP"
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
    }

    ChoiceChips {
      choices: root.scrollStepChoices.map(function(v) { return { value: v, label: v + "%" } })
      selected: root.scrollStep
      onPicked: function(value) { root.setScrollStep(value) }
    }
  }

  // On/off switch in the theme accent: accent track and knob when on, a dim
  // neutral track when off. No outline on hover. `focused` marks the keyboard
  // cursor with a brighter track and a larger knob instead of a ring.
  component AccentSwitch: Item {
    id: sw
    property bool checked: false
    property bool focused: false
    readonly property bool containsMouse: swMouse.containsMouse
    signal toggled()
    signal hovered(bool on)

    implicitWidth: root.sp(34)
    implicitHeight: root.sp(18)

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: sw.checked
        ? Util.alpha(Color.accent, sw.focused ? 0.55 : 0.3)
        : Util.alpha(root.bar.foreground, sw.focused ? 0.25 : 0.1)
      border.width: 1
      border.color: sw.checked ? Color.accent : Util.alpha(root.bar.foreground, sw.focused ? 0.6 : 0.25)
      Behavior on color { ColorAnimation { duration: 120 } }

      Rectangle {
        width: parent.height - root.sp(sw.focused ? 3 : 6)
        height: width
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        x: sw.checked ? parent.width - width - (parent.height - height) / 2 : (parent.height - height) / 2
        color: sw.checked ? Color.accent : Qt.darker(root.bar.foreground, 1.4)
        Behavior on x { NumberAnimation { duration: 120 } }
        Behavior on color { ColorAnimation { duration: 120 } }
      }
    }

    MouseArea {
      id: swMouse
      anchors.fill: parent
      anchors.margins: -root.sp(3)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: sw.hovered(containsMouse)
      onClicked: sw.toggled()
    }
  }
}
