#!/bin/bash
# Run with: bash test/omaudiopanel.test.sh
# Exercises pin handling in bin/omaudiopanel against stubbed pactl/pw-metadata.

set -u
here=$(cd "$(dirname "$0")" && pwd)
helper=$here/../bin/omaudiopanel
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export XDG_STATE_HOME=$work/state XDG_CONFIG_HOME=$work/config XDG_RUNTIME_DIR=$work/run
mkdir -p "$work/run"
mkdir -p "$work/bin"
export PATH=$work/bin:$PATH
failures=0

# Stubs read fixtures from $work and log metadata writes.
cat >"$work/bin/pactl" <<'EOF'
#!/bin/bash
case "$*" in
  "-f json list sinks") [[ -e $FIX/fail-sinks ]] && exit 1; cat "$FIX/sinks.json" ;;
  "-f json list sink-inputs") echo x >>"$FIX/sink-input-calls"; [[ -e $FIX/fail-pactl ]] && exit 1; cat "$FIX/inputs.json" ;;
  "-f json list cards") cat "$FIX/cards.json" ;;
  set-card-profile*) echo "$*" >>"$FIX/writes.log" ;;
esac
EOF
cat >"$work/bin/pw-metadata" <<'EOF'
#!/bin/bash
# Behaves like the default metadata: writes replace the entry, -d removes it,
# and a later read shows the result. $FIX/fail-writes makes every write fail.
m=$FIX/metadata.txt
if [[ $# -eq 0 ]]; then cat "$m"; exit 0; fi
[[ -e $FIX/fail-writes ]] && exit 1
echo "$*" >>"$FIX/writes.log"
if [[ $1 == -d ]]; then
  grep -v "^update: id:$2 key:'$3' " "$m" >"$m.tmp"; mv "$m.tmp" "$m"
else
  grep -v "^update: id:$1 key:'$2' " "$m" >"$m.tmp"; mv "$m.tmp" "$m"
  echo "update: id:$1 key:'$2' value:'$3' type:'(null)'" >>"$m"
fi
EOF
chmod +x "$work/bin/"*
export FIX=$work

setup() {
  rm -rf "$XDG_STATE_HOME" "$FIX/fail-writes" "$FIX/fail-pactl" "$FIX/fail-sinks" "$FIX/sink-input-calls"; : >"$FIX/writes.log"; : >"$FIX/metadata.txt"
  echo '[{"index":1,"name":"speakers"},{"index":2,"name":"headset"}]' >"$FIX/sinks.json"
  cat >"$FIX/inputs.json" <<'EOF'
[{"index":10,"sink":2,"corked":false,"properties":{"object.id":"60","object.serial":"160","application.name":"Brave"}},
 {"index":11,"sink":2,"corked":true,"properties":{"object.id":"61","object.serial":"161","application.name":"Brave"}},
 {"index":12,"sink":2,"corked":false,"properties":{"object.id":"70","object.serial":"170","application.name":"Firefox"}}]
EOF
}

expect() {
  local name=$1 want=$2 got=$3
  if [[ $got == "$want" ]]; then echo "ok - $name"
  else echo "not ok - $name"; echo "  want: $(printf %q "$want")"; echo "  got:  $(printf %q "$got")"; failures=$((failures + 1)); fi
}

target_of() { sed -n "s/^update: id:$1 key:'target.object' value:'\(.*\)' type:.*/\1/p" "$FIX/metadata.txt"; }
marker_of() { sed -n "s/^update: id:$1 key:'omaudiopanel.pin' value:'\(.*\)' type:.*/\1/p" "$FIX/metadata.txt"; }

setup
"$helper" pin Brave speakers "Speakers"
expect "pin saves app, sink and label" $'Brave\tspeakers\tSpeakers' "$("$helper" list-pins)"
expect "pin routes the app's unrouted streams" "speakers speakers" "$(target_of 60) $(target_of 61)"
expect "pin marks its routes with app and sink" "Brave|speakers Brave|speakers" "$(marker_of 60) $(marker_of 61)"

setup
echo "update: id:61 key:'target.object' value:'headset' type:'(null)'" >"$FIX/metadata.txt"
"$helper" pin Brave speakers "Speakers" >/dev/null
expect "apply-pins leaves streams routed by hand" "speakers headset" "$(target_of 60) $(target_of 61)"
expect "apply-pins marks only its own routes" "Brave|speakers " "$(marker_of 60) $(marker_of 61)"

setup
# An unplugged pinned output still gets the route: WirePlumber plays the
# stream on the default meanwhile and moves it back when the output returns.
"$helper" pin Brave missing "Gone"
expect "apply-pins routes to an unplugged pinned output" "missing missing" "$(target_of 60) $(target_of 61)"

setup
"$helper" pin Brave speakers "Speakers"
"$helper" pin Brave headset "Headset"
expect "re-pinning replaces the old pin" $'Brave\theadset\tHeadset' "$("$helper" list-pins)"
expect "re-pinning moves the pin's routes to the new output" "headset headset" "$(target_of 60) $(target_of 61)"
expect "re-pinning re-marks them" "Brave|headset Brave|headset" "$(marker_of 60) $(marker_of 61)"

setup
# Picking an output for a stream, then ticking "Always play": the stream the
# user is looking at joins the pin, so unticking returns it to the default.
"$helper" route 60 speakers
"$helper" pin Brave speakers "Speakers" 60
expect "pin adopts the given stream" "Brave|speakers" "$(marker_of 60)"
"$helper" unpin Brave
expect "unpin returns an adopted stream to the default" "" "$(target_of 60)"

setup
# Choosing another output for a pinned stream moves the pin with it; the
# stream stays part of the pin.
"$helper" pin Brave speakers "Speakers" >/dev/null
"$helper" pin Brave headset "Headset" 60
expect "pin with a stream routes it to the new output" "headset" "$(target_of 60)"
expect "that stream stays marked" "Brave|headset" "$(marker_of 60)"

setup
touch "$FIX/fail-writes"
"$helper" pin Brave speakers "Speakers" >/dev/null
rm "$FIX/fail-writes"
expect "a failed route write leaves no marker" "" "$(marker_of 60)$(marker_of 61)"

setup
"$helper" pin Brave speakers "Speakers" >/dev/null
"$helper" unpin Brave
expect "unpin removes the pin" "" "$("$helper" list-pins)"
expect "unpin returns the pin's streams to the default" "" "$(target_of 60)$(target_of 61)$(marker_of 60)$(marker_of 61)"

setup
# A stream routed by hand to the pin's own output is a manual route: unpinning
# must leave it, and reset only the routes the pin created.
"$helper" pin Brave speakers "Speakers" >/dev/null
"$helper" route 61 speakers
"$helper" unpin Brave
expect "unpin resets the pin's route" "" "$(target_of 60)"
expect "unpin keeps a manual route to the pinned output" "speakers" "$(target_of 61)"

setup
"$helper" pin Brave speakers "Speakers" >/dev/null
"$helper" route 61 headset
"$helper" unpin Brave
expect "unpin keeps a manual reroute" "headset" "$(target_of 61)"

setup
# Another app pinned to the same output keeps its routes when Brave is unpinned.
"$helper" pin Brave speakers "Speakers" >/dev/null
"$helper" pin Firefox speakers "Speakers" >/dev/null
"$helper" unpin Brave
expect "unpin leaves other apps' pin routes" "speakers Firefox|speakers" "$(target_of 70) $(marker_of 70)"

setup
# A failed hand route keeps the pin's marker, so unpin can still undo the route.
"$helper" pin Brave speakers "Speakers" >/dev/null
touch "$FIX/fail-writes"
"$helper" route 61 headset
rm "$FIX/fail-writes"
"$helper" unpin Brave
expect "a failed hand route does not orphan the pin's route" "" "$(target_of 61)"

setup
# If resetting a route fails, the marker stays, and unpinning again (with the
# pin already gone) still finishes the job.
"$helper" pin Brave speakers "Speakers" >/dev/null
touch "$FIX/fail-writes"
"$helper" unpin Brave
rm "$FIX/fail-writes"
expect "a failed reset keeps the marker" "Brave|speakers" "$(marker_of 60)"
"$helper" unpin Brave
expect "unpin again finishes the reset" "" "$(target_of 60)$(marker_of 60)"

setup
# unpin reads the app from the marker, so it does not need pactl.
"$helper" pin Brave speakers "Speakers" >/dev/null
touch "$FIX/fail-pactl"
"$helper" unpin Brave
rm "$FIX/fail-pactl"
expect "unpin works when pactl fails" "" "$(target_of 60)$(target_of 61)"

setup
# Only the exact key counts as a marker.
"$helper" pin Brave speakers "Speakers" >/dev/null
"$helper" route 61 speakers
echo "update: id:61 key:'omaudiopanelXpin' value:'Brave|speakers' type:'(null)'" >>"$FIX/metadata.txt"
"$helper" unpin Brave
expect "unpin ignores lookalike keys" "speakers" "$(target_of 61)"

setup
# Route-changing commands wait for each other through one lock.
flock "$XDG_RUNTIME_DIR/omaudiopanel.lock" sh -c ': >"$1"; sleep 1' _ "$FIX/locked" &
while [[ ! -e $FIX/locked ]]; do sleep 0.02; done
rm -f "$FIX/locked"
start=$(date +%s%N)
"$helper" route 60 speakers
waited=$(( ($(date +%s%N) - start) / 1000000 ))
wait
expect "route waits for the lock" "yes" "$( (( waited >= 600 )) && echo yes || echo "no (${waited}ms)")"

setup
# Re-pinning to an unplugged output moves the pin's routes there too, so they
# follow the pin once it is plugged in.
"$helper" pin Brave speakers "Speakers" >/dev/null
"$helper" pin Brave missing "Gone" 60
expect "re-pin to an unplugged output moves the routes" "missing missing" "$(target_of 60) $(target_of 61)"

setup
# Choosing an output for a pinned stream does not depend on pactl's sink list.
"$helper" pin Brave speakers "Speakers" >/dev/null
touch "$FIX/fail-sinks"
"$helper" pin Brave headset "Headset" 60
expect "pin with a stream works when pactl sinks fails" "headset" "$(target_of 60)"

setup
# The stream on screen is routed once, even when it is also one of the moved routes.
"$helper" pin Brave speakers "Speakers" >/dev/null
: >"$FIX/writes.log"
"$helper" pin Brave headset "Headset" 60
expect "pin writes the on-screen stream once" "2" "$(grep -c '^60 ' "$FIX/writes.log")"

setup
# Old sink-only markers look up app names with a single pactl call.
mkdir -p "$XDG_STATE_HOME/omaudiopanel"
printf 'Brave\tspeakers\tSpeakers\n' >"$XDG_STATE_HOME/omaudiopanel/pins"
printf "update: id:60 key:'target.object' value:'speakers' type:'(null)'\nupdate: id:60 key:'omaudiopanel.pin' value:'speakers' type:'(null)'\nupdate: id:61 key:'target.object' value:'speakers' type:'(null)'\nupdate: id:61 key:'omaudiopanel.pin' value:'speakers' type:'(null)'\n" >"$FIX/metadata.txt"
"$helper" unpin Brave
expect "old markers need one pactl call" "1" "$(wc -l <"$FIX/sink-input-calls" | tr -d ' ')"

setup
# App names can contain an apostrophe; pw-metadata prints it unescaped.
cat >"$FIX/inputs.json" <<'JSON'
[{"index":20,"sink":2,"corked":false,"properties":{"object.id":"80","application.name":"Baldur's Gate 3"}}]
JSON
"$helper" pin "Baldur's Gate 3" speakers "Speakers" >/dev/null
expect "marker keeps an apostrophe in the app name" "Baldur's Gate 3|speakers" "$(marker_of 80)"
"$helper" unpin "Baldur's Gate 3"
expect "unpin works for an app name with an apostrophe" "" "$(target_of 80)$(marker_of 80)"

setup
# Markers from the previous version hold only the sink; unpin still resets them.
mkdir -p "$XDG_STATE_HOME/omaudiopanel"
printf 'Brave\tspeakers\tSpeakers\n' >"$XDG_STATE_HOME/omaudiopanel/pins"
printf "update: id:60 key:'target.object' value:'speakers' type:'(null)'\nupdate: id:60 key:'omaudiopanel.pin' value:'speakers' type:'(null)'\nupdate: id:70 key:'target.object' value:'speakers' type:'(null)'\nupdate: id:70 key:'omaudiopanel.pin' value:'speakers' type:'(null)'\n" >"$FIX/metadata.txt"
"$helper" unpin Brave
expect "unpin resets a marker from the previous version" "" "$(target_of 60)$(marker_of 60)"
expect "an old marker on another app's stream stays" "speakers speakers" "$(target_of 70) $(marker_of 70)"

setup
expect "list-streams reports app and paused state" \
  $'60\theadset\t\tBrave\t0\n61\theadset\t\tBrave\t1\n70\theadset\t\tFirefox\t0' \
  "$("$helper" list-streams)"

setup
# WirePlumber writes target.object = -1 (Spa:Id) for "no specific target".
printf "update: id:60 key:'target.object' value:'-1' type:'Spa:Id'\nupdate: id:60 key:'target.node' value:'-1' type:'Spa:Id'\n" >"$FIX/metadata.txt"
expect "list-streams treats a -1 target as following the default" \
  $'60\theadset\t\tBrave\t0' "$("$helper" list-streams | head -1)"
"$helper" pin Brave speakers "Speakers" >/dev/null
expect "apply-pins routes a stream whose target is -1" "speakers speakers" "$(target_of 60) $(target_of 61)"

setup
# Bluetooth nodes have no device.profile.name and their card profiles are
# plain names (a2dp-sink), so disabling switches the card off and enabling
# restores the profile it had.
cat >"$FIX/sinks.json" <<'JSON'
[{"index":7,"name":"bluez_output.AA_BB.1","properties":{"device.name":"bluez_card.AA_BB","device.api":"bluez5"}}]
JSON
cat >"$FIX/cards.json" <<'JSON'
[{"name":"bluez_card.AA_BB","active_profile":"a2dp-sink","profiles":{
  "off":{"sinks":0,"sources":0,"priority":0,"available":true},
  "a2dp-sink":{"sinks":1,"sources":0,"priority":10,"available":true}}}]
JSON
"$helper" disable bluez_output.AA_BB.1 sink "Pebble V3"
expect "disable turns a Bluetooth card off" "set-card-profile bluez_card.AA_BB off" "$(cat "$FIX/writes.log")"
expect "disable remembers the Bluetooth profile" \
  $'bluez_output.AA_BB.1\tsink\tPebble V3\tbluez_card.AA_BB\tprofile:a2dp-sink' "$("$helper" list-disabled)"
: >"$FIX/writes.log"
"$helper" enable bluez_output.AA_BB.1
expect "enable restores the Bluetooth profile" "set-card-profile bluez_card.AA_BB a2dp-sink" "$(cat "$FIX/writes.log")"

(( failures == 0 )) && echo "all passed" || { echo "$failures failed"; exit 1; }
