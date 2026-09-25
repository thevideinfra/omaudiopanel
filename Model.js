function isPlaybackStream(node) {
  if (!node || !node.isStream) return false
  if (node.isSink === true) return true

  var mediaClass = String(node.type || "")
  return mediaClass.indexOf("Stream/Output/Audio") !== -1
    || mediaClass.indexOf("AudioOutStream") !== -1
    || mediaClass.indexOf("Output") !== -1
}

function isAudioSource(node) {
  if (!node) return false
  if (node.audio) return true

  var mediaClass = String(node.type || "")
  return mediaClass.indexOf("Audio/Source") !== -1
    || mediaClass.indexOf("AudioSource") !== -1
    || mediaClass.indexOf("Source") !== -1
}

function listSnapshot(list) {
  return list && list.slice ? list.slice() : []
}

function outputVolumeName(volume, muted) {
  if (muted) return "Muted"
  var p = Math.round(volume * 100)
  if (p === 0) return "Silenced"
  if (p >= 100) return "Concert hall"
  if (p >= 85) return "Party mode"
  if (p >= 70) return "Cranked up"
  if (p >= 50) return "Steady groove"
  if (p >= 30) return "Easy listening"
  if (p >= 15) return "Murmur"
  return "Whisper"
}

function parseSinkAvailability(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    if (parts.length >= 2) next[parts[0]] = parts[1] !== "0"
  }
  return next
}

function friendlyDeviceLabel(text) {
  var label = String(text || "").trim()
  label = label.replace(/^sof-soundwire\s+/i, "")
  label = label.replace(/^built-?in audio\s+/i, "")
  label = label.replace(/\s+Output$/i, "")
  label = label.replace(/\s+Input$/i, "")
  label = label.replace(/\bMicrophones\b/g, "Microphone")
  return label
}

function nodeProps(node) {
  return node && node.ready && node.properties ? node.properties : {}
}

function nodeLabel(node) {
  if (!node) return "Unknown"
  var p = nodeProps(node)
  var nickname = friendlyDeviceLabel(node.nickname || node.nick || p["node.nick"] || p["device.profile.description"] || "")
  if (nickname) return nickname
  return friendlyDeviceLabel(node.description || p["node.description"] || node.name || "Unknown")
}

function isHeadphones(node) {
  if (!node) return false
  var p = nodeProps(node)
  var blob = String([
    node.name, node.description, node.nickname,
    p["device.icon-name"] || "",
    p["device.product.name"] || "",
    p["node.description"] || "",
    p["node.nick"] || ""
  ].join(" ")).toLowerCase()
  return blob.indexOf("headphone") !== -1
    || blob.indexOf("headset") !== -1
    || blob.indexOf("earbud") !== -1
    || blob.indexOf("earphone") !== -1
    || blob.indexOf("airpod") !== -1
}

function sinkGlyph(node) {
  if (!node) return "󰓃"
  if (isHeadphones(node)) return "󰋋"
  var p = nodeProps(node)
  var blob = String([
    node.name, node.description, node.nickname,
    p["device.icon-name"] || "",
    p["device.product.name"] || ""
  ].join(" ")).toLowerCase()
  if (blob.indexOf("bluetooth") !== -1) return "󰂯"
  if (blob.indexOf("hdmi") !== -1 || blob.indexOf("display") !== -1) return "󰍹"
  return "󰓃"
}

function sourceGlyph(node) {
  if (!node) return "󰍬"
  var p = nodeProps(node)
  var blob = String([
    node.name, node.description, node.nickname,
    p["device.icon-name"] || ""
  ].join(" ")).toLowerCase()
  if (blob.indexOf("headset") !== -1) return "󰋋"
  if (blob.indexOf("bluetooth") !== -1) return "󰂯"
  if (blob.indexOf("webcam") !== -1 || blob.indexOf("camera") !== -1) return "󰄀"
  return "󰍬"
}

function friendlyStreamLabel(label) {
  label = String(label || "").trim()
  if (!label) return ""

  var known = {
    "spotify": "Spotify"
  }
  var normalized = label.toLowerCase()
  return known[normalized] || label
}

function streamLabelKey(label) {
  return String(label || "").trim().toLowerCase()
}

function streamLabelIsGeneric(label) {
  return streamLabelKey(label) === "audio-src"
}

function rawStreamLabel(node) {
  if (!node) return ""
  var p = nodeProps(node)
  return p["application.name"]
    || node.description
    || p["media.name"]
    || p["node.name"]
    || node.name
}

function mprisPlayerLabel(player) {
  if (!player) return ""
  return friendlyStreamLabel(player.identity || player.desktopEntry || "")
}

function mprisPlayerIsProxy(player) {
  var dbusName = String(player && player.dbusName || "").toLowerCase()
  var desktopEntry = String(player && player.desktopEntry || "").toLowerCase()
  return dbusName.indexOf("playerctld") !== -1 || desktopEntry === "playerctld"
}

function streamRepresentsMprisPlayer(streamLabel, playerLabel) {
  var streamKey = streamLabelKey(friendlyStreamLabel(streamLabel))
  var playerKey = streamLabelKey(playerLabel)
  if (!streamKey || !playerKey) return false
  return streamKey === playerKey
    || streamKey.indexOf(playerKey) !== -1
    || playerKey.indexOf(streamKey) !== -1
}

function mprisLabelsFor(players, predicate) {
  var values = Array.isArray(players) ? players : []
  var playingCandidates = []
  var candidates = []
  var playingProxyCandidates = []
  var proxyCandidates = []

  for (var i = 0; i < values.length; i++) {
    var player = values[i]
    if (!player) continue
    if (!player.isPlaying && !player.canPlay) continue

    var playerLabel = mprisPlayerLabel(player)
    if (!playerLabel || !predicate(playerLabel)) continue

    if (mprisPlayerIsProxy(player)) {
      if (player.isPlaying) playingProxyCandidates.push(playerLabel)
      proxyCandidates.push(playerLabel)
    } else {
      if (player.isPlaying) playingCandidates.push(playerLabel)
      candidates.push(playerLabel)
    }
  }

  if (playingCandidates.length === 1) return playingCandidates[0]
  if (playingCandidates.length === 0 && playingProxyCandidates.length === 1) return playingProxyCandidates[0]
  if (candidates.length === 1) return candidates[0]
  if (candidates.length === 0 && proxyCandidates.length === 1) return proxyCandidates[0]
  return ""
}

function matchingMprisStreamLabel(label, players) {
  if (streamLabelIsGeneric(label)) return ""
  return mprisLabelsFor(players, function(playerLabel) {
    return streamRepresentsMprisPlayer(label, playerLabel)
  })
}

function unmatchedMprisStreamLabel(label, players, streams) {
  if (!streamLabelIsGeneric(label)) return ""

  return mprisLabelsFor(players, function(playerLabel) {
    var values = Array.isArray(streams) ? streams : []
    for (var i = 0; i < values.length; i++) {
      var stream = values[i]
      var streamLabel = rawStreamLabel(stream)
      if (!streamLabelIsGeneric(streamLabel) && streamRepresentsMprisPlayer(streamLabel, playerLabel))
        return false
    }
    return true
  })
}

function streamLabel(node, players, streams) {
  if (!node) return "Stream"
  var label = rawStreamLabel(node)
  return friendlyStreamLabel(matchingMprisStreamLabel(label, players)
    || unmatchedMprisStreamLabel(label, players, streams)
    || label) || "Stream"
}

function streamRepresentsPlayer(node, player, players, streams) {
  if (!node || !player) return false
  var playerLabel = mprisPlayerLabel(player)
  if (!playerLabel) return false

  var label = rawStreamLabel(node)
  if (!streamLabelIsGeneric(label)) return streamRepresentsMprisPlayer(label, playerLabel)
  return streamRepresentsMprisPlayer(streamLabel(node, players, streams), playerLabel)
}

// Lines of "name<TAB>kind<TAB>label" from `omaudiopanel list-disabled`.
function parseDisabledDevices(raw) {
  var list = []
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (!parts[0]) continue
    list.push({ name: parts[0], kind: parts[1] || "sink", label: parts[2] || parts[0] })
  }
  return list
}

// Lines of "stream-id<TAB>current-sink<TAB>routed-sink<TAB>app<TAB>paused"
// from `omaudiopanel list-streams`; routed-sink is empty when following the
// default, paused is 1 for a corked stream.
function parseStreams(raw) {
  var streams = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (!parts[0]) continue
    streams[parts[0]] = {
      current: parts[1] || "",
      routed: parts[2] || "",
      app: parts[3] || "",
      paused: parts[4] === "1"
    }
  }
  return streams
}

// Lines of "app<TAB>sink-name<TAB>sink-label" from `omaudiopanel list-pins`.
function parsePins(raw) {
  var pins = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (!parts[0] || !parts[1]) continue
    pins[parts[0]] = { sink: parts[1], label: parts[2] || parts[1] }
  }
  return pins
}

// Chromium-based browsers name every stream "Playback", but each tab playing
// media publishes an MPRIS player with its title. All of a browser's streams
// share one process, so a stream can only be tied to a tab when the pairing is
// certain: one stream and one player, or one playing stream and one playing
// player (and likewise for paused). Anything else gets a number instead of a
// guessed title.
//
// streams: [{ id, app, paused }]; players: MPRIS players.
// Returns { id: { title, index, count } }.
function streamTitles(streams, players) {
  var result = {}
  var groups = {}
  var order = []
  var list = Array.isArray(streams) ? streams : []
  for (var i = 0; i < list.length; i++) {
    var key = streamLabelKey(list[i].app)
    if (!groups[key]) { groups[key] = []; order.push(key) }
    groups[key].push(list[i])
  }

  // Quickshell's player list is array-like rather than an Array.
  var allPlayers = players && players.length !== undefined ? Array.prototype.slice.call(players) : []
  for (var g = 0; g < order.length; g++) {
    var group = groups[order[g]]
    var app = group[0].app
    var matching = []
    for (var p = 0; p < allPlayers.length; p++) {
      var player = allPlayers[p]
      if (!player || mprisPlayerIsProxy(player)) continue
      if (!player.trackTitle) continue
      if (streamRepresentsMprisPlayer(app, mprisPlayerLabel(player))) matching.push(player)
    }

    for (var s = 0; s < group.length; s++)
      result[group[s].id] = { title: "", index: s + 1, count: group.length }

    if (group.length === 1 && matching.length === 1) {
      result[group[0].id].title = matching[0].trackTitle
      continue
    }

    var pairs = [
      [group.filter(function(x) { return !x.paused }), matching.filter(function(x) { return x.isPlaying })],
      [group.filter(function(x) { return x.paused }), matching.filter(function(x) { return !x.isPlaying })]
    ]
    for (var k = 0; k < pairs.length; k++) {
      if (pairs[k][0].length === 1 && pairs[k][1].length === 1)
        result[pairs[k][0][0].id].title = pairs[k][1][0].trackTitle
    }
  }
  return result
}

function streamDisplayName(label, info) {
  if (!info) return label
  if (info.title) return label + " – " + info.title
  if (info.count > 1) return label + " · " + info.index + " of " + info.count
  return label
}

// Where the panel should scroll so a cursor row is visible. Rows already in
// view leave the position alone, so a small overflow can still be scrolled
// by hand. r: { top, bottom, viewTop, viewHeight, maxY, margin }.
function scrollTargetFor(r) {
  if (r.top < r.viewTop + r.margin) return Math.max(0, Math.min(r.maxY, r.top - r.margin))
  if (r.bottom > r.viewTop + r.viewHeight - r.margin)
    return Math.max(0, Math.min(r.maxY, r.bottom + r.margin - r.viewHeight))
  return r.viewTop
}

// Heights (0..1) for the three "playing" bars, from a PipeWire peak level
// and an animation phase that advances while the panel is open. Silence
// flattens them; otherwise each bar swings on its own offset so they read
// as an equalizer, and louder audio makes all of them taller.
function eqBarLevels(peak, phase) {
  if (!(peak >= 0.01)) return [0, 0, 0]
  var base = Math.min(1, Math.sqrt(peak) * 1.3)
  var bars = []
  for (var i = 0; i < 3; i++) {
    var swing = 0.5 + 0.5 * Math.abs(Math.sin(phase + i * 2.1))
    bars.push(Math.max(0.15, Math.min(1, base * swing)))
  }
  return bars
}

// The output a pin should use: the one chosen for the stream, or else the one
// it is playing on now. info is a parseStreams entry.
function pinTarget(info) {
  if (!info) return ""
  return info.routed || info.current || ""
}

// state: { currentLabel, routed, app, pin: { label } | null, pinAvailable }
function routeSummary(state) {
  var where = "Playing on " + state.currentLabel
  if (state.pin && !state.pinAvailable) return where + ", " + state.pin.label + " is unavailable"
  if (state.pin) return where + ", pinned for " + state.app
  return where
}

if (typeof module !== "undefined") {
  module.exports = {
    isPlaybackStream: isPlaybackStream,
    isAudioSource: isAudioSource,
    listSnapshot: listSnapshot,
    outputVolumeName: outputVolumeName,
    parseSinkAvailability: parseSinkAvailability,
    friendlyDeviceLabel: friendlyDeviceLabel,
    nodeProps: nodeProps,
    nodeLabel: nodeLabel,
    isHeadphones: isHeadphones,
    sinkGlyph: sinkGlyph,
    sourceGlyph: sourceGlyph,
    friendlyStreamLabel: friendlyStreamLabel,
    streamLabelKey: streamLabelKey,
    streamLabelIsGeneric: streamLabelIsGeneric,
    rawStreamLabel: rawStreamLabel,
    mprisPlayerLabel: mprisPlayerLabel,
    mprisPlayerIsProxy: mprisPlayerIsProxy,
    streamRepresentsMprisPlayer: streamRepresentsMprisPlayer,
    mprisLabelsFor: mprisLabelsFor,
    matchingMprisStreamLabel: matchingMprisStreamLabel,
    unmatchedMprisStreamLabel: unmatchedMprisStreamLabel,
    streamLabel: streamLabel,
    streamRepresentsPlayer: streamRepresentsPlayer,
    parseDisabledDevices: parseDisabledDevices,
    parseStreams: parseStreams,
    parsePins: parsePins,
    streamTitles: streamTitles,
    streamDisplayName: streamDisplayName,
    routeSummary: routeSummary,
    pinTarget: pinTarget,
    scrollTargetFor: scrollTargetFor,
    eqBarLevels: eqBarLevels
  }
}
