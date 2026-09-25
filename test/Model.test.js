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

test("pinTarget prefers the chosen output, then the current one", () => {
  assert.equal(M.pinTarget({ routed: "codec", current: "hs80" }), "codec")
  assert.equal(M.pinTarget({ routed: "", current: "hs80" }), "hs80")
  assert.equal(M.pinTarget(null), "")
})

test("streamTitles accepts Quickshell's array-like player list", () => {
  // Mpris.players.values reaches JS as a list-like object, not an Array.
  const players = { length: 1, 0: player("Brave Origin", "Houston vs Texas Tech", true) }
  const titles = M.streamTitles([{ id: "71", app: "Brave", paused: false }], players)
  assert.equal(titles["71"].title, "Houston vs Texas Tech")
})

test("scrollTargetFor leaves a visible row alone even when the scroll range is tiny", () => {
  // 27px of overflow, scrolled to the bottom, cursor lands on a row that is in view.
  assert.equal(M.scrollTargetFor({ top: 700, bottom: 740, viewTop: 27, viewHeight: 851, maxY: 27, margin: 6 }), 27)
})

test("scrollTargetFor scrolls just enough to reveal a row above or below the view", () => {
  assert.equal(M.scrollTargetFor({ top: 10, bottom: 50, viewTop: 100, viewHeight: 400, maxY: 600, margin: 6 }), 4)
  assert.equal(M.scrollTargetFor({ top: 520, bottom: 560, viewTop: 100, viewHeight: 400, maxY: 600, margin: 6 }), 166)
  assert.equal(M.scrollTargetFor({ top: 900, bottom: 990, viewTop: 100, viewHeight: 400, maxY: 600, margin: 6 }), 596)
})

test("eqBarLevels is flat when silent", () => {
  assert.deepEqual(M.eqBarLevels(0, 0), [0, 0, 0])
  assert.deepEqual(M.eqBarLevels(0.005, 1.3), [0, 0, 0])
})

test("eqBarLevels gives three distinct visible heights while playing", () => {
  const bars = M.eqBarLevels(0.3, 0.7)
  assert.equal(bars.length, 3)
  for (const h of bars) assert.ok(h >= 0.15 && h <= 1, `height ${h} out of range`)
  assert.ok(new Set(bars.map(h => h.toFixed(3))).size > 1, "bars should not all match")
})

test("eqBarLevels grows with the level at the same phase", () => {
  const quiet = M.eqBarLevels(0.05, 2)
  const loud = M.eqBarLevels(0.6, 2)
  for (let i = 0; i < 3; i++) assert.ok(loud[i] >= quiet[i])
})

test("densityScale shrinks from comfortable to compact and defaults to normal", () => {
  const c = M.densityScale("compact"), n = M.densityScale("normal"), f = M.densityScale("comfortable")
  assert.equal(f, 1)
  assert.ok(c < n && n < f)
  assert.equal(M.densityScale("bogus"), n)
  assert.equal(M.densityScale(undefined), n)
})

test("settingBool reads booleans and their string forms with a fallback", () => {
  assert.equal(M.settingBool(true, false), true)
  assert.equal(M.settingBool("false", true), false)
  assert.equal(M.settingBool("true", false), true)
  assert.equal(M.settingBool(undefined, true), true)
  assert.equal(M.settingBool(null, false), false)
})

test("eqBarLevels keeps quiet audio clearly visible", () => {
  // Speech often peaks around 0.05; the bars should still read as bars.
  for (const phase of [0, 0.7, 1.9, 3.1]) {
    const bars = M.eqBarLevels(0.05, phase)
    assert.ok(Math.max(...bars) >= 0.5, `tallest bar ${Math.max(...bars)} at phase ${phase}`)
    for (const h of bars) assert.ok(h >= 0.3, `bar ${h} too short at phase ${phase}`)
  }
})

test("fontSizeScale orders small < normal < large and defaults to normal", () => {
  assert.equal(M.fontSizeScale("normal"), 1)
  assert.ok(M.fontSizeScale("small") < 1)
  assert.ok(M.fontSizeScale("large") > 1)
  assert.equal(M.fontSizeScale("huge"), 1)
  assert.equal(M.fontSizeScale(undefined), 1)
})
