// Run with: npm test (node --test test/*.test.js)
const test = require("node:test")
const assert = require("node:assert/strict")
const M = require("../Model.js")

function player(identity, title, isPlaying, extra) {
  return Object.assign({ identity: identity, trackTitle: title, isPlaying: isPlaying, canPlay: true }, extra || {})
}

test("parseStreams reads app name and paused state", () => {
  const s = M.parseStreams("60\tsinkA\t\tBrave\t1\n61\tsinkB\tsinkB\tFirefox\t0\n")
  assert.deepEqual(s["60"], { current: "sinkA", routed: "", app: "Brave", paused: true })
  assert.deepEqual(s["61"], { current: "sinkB", routed: "sinkB", app: "Firefox", paused: false })
})

test("parsePins maps app to sink and label", () => {
  assert.deepEqual(M.parsePins("Brave\talsa_out.speakers\tUSB AUDIO CODEC\n\n"),
    { Brave: { sink: "alsa_out.speakers", label: "USB AUDIO CODEC" } })
})

test("single stream with single player gets the tab title", () => {
  const titles = M.streamTitles(
    [{ id: "60", app: "Brave", paused: false }],
    [player("Brave", "Lions vs Bills Highlights", true)])
  assert.deepEqual(titles["60"], { title: "Lions vs Bills Highlights", index: 1, count: 1 })
})

test("only playing stream matches only playing player; paused pair matches too", () => {
  const titles = M.streamTitles(
    [{ id: "60", app: "Brave", paused: true }, { id: "61", app: "Brave", paused: false }],
    [player("Brave", "YouTube video", false), player("Brave", "Twitch stream", true)])
  assert.equal(titles["61"].title, "Twitch stream")
  assert.equal(titles["60"].title, "YouTube video")
})

test("ambiguous streams get no title but a number", () => {
  const titles = M.streamTitles(
    [{ id: "60", app: "Brave", paused: false }, { id: "61", app: "Brave", paused: false }],
    [player("Brave", "YouTube video", true), player("Brave", "Twitch stream", true)])
  assert.deepEqual(titles["60"], { title: "", index: 1, count: 2 })
  assert.deepEqual(titles["61"], { title: "", index: 2, count: 2 })
})

test("players from other apps and playerctld proxies are ignored", () => {
  const titles = M.streamTitles(
    [{ id: "60", app: "Brave", paused: false }],
    [player("Brave", "Real tab", true),
     player("Chromium", "Other browser", true),
     player("Brave", "Proxy copy", true, { dbusName: "org.mpris.MediaPlayer2.playerctld" })])
  assert.equal(titles["60"].title, "Real tab")
})

test("streamDisplayName joins app label with title or number", () => {
  assert.equal(M.streamDisplayName("Brave", { title: "Twitch", index: 1, count: 1 }), "Brave – Twitch")
  assert.equal(M.streamDisplayName("Brave", { title: "", index: 2, count: 3 }), "Brave · 2 of 3")
  assert.equal(M.streamDisplayName("Brave", null), "Brave")
})

test("routeSummary describes default, chosen, pinned, and unavailable pin", () => {
  assert.equal(M.routeSummary({ currentLabel: "HS80", routed: false, app: "Brave", pin: null, pinAvailable: false }),
    "Playing on HS80")
  assert.equal(M.routeSummary({ currentLabel: "Codec", routed: true, app: "Brave", pin: null, pinAvailable: false }),
    "Playing on Codec")
  assert.equal(M.routeSummary({ currentLabel: "Codec", routed: true, app: "Brave", pin: { label: "Codec" }, pinAvailable: true }),
    "Playing on Codec, pinned for Brave")
  assert.equal(M.routeSummary({ currentLabel: "HS80", routed: true, app: "Brave", pin: { label: "Codec" }, pinAvailable: false }),
    "Playing on HS80, Codec is unavailable")
})
