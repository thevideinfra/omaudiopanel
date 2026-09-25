#!/bin/bash
# Run with: bash test/omaudiopanel.test.sh
# Exercises pin handling in bin/omaudiopanel against stubbed pactl/pw-metadata.

set -u
here=$(cd "$(dirname "$0")" && pwd)
helper=$here/../bin/omaudiopanel
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export XDG_STATE_HOME=$work/state XDG_CONFIG_HOME=$work/config
mkdir -p "$work/bin"
export PATH=$work/bin:$PATH
failures=0

# Stubs read fixtures from $work and log metadata writes.
cat >"$work/bin/pactl" <<'EOF'
#!/bin/bash
case "$*" in
  "-f json list sinks") cat "$FIX/sinks.json" ;;
  "-f json list sink-inputs") cat "$FIX/inputs.json" ;;
esac
EOF
cat >"$work/bin/pw-metadata" <<'EOF'
#!/bin/bash
if [[ $# -eq 0 ]]; then cat "$FIX/metadata.txt"; exit 0; fi
echo "$*" >>"$FIX/writes.log"
EOF
chmod +x "$work/bin/"*
export FIX=$work

setup() {
  rm -rf "$XDG_STATE_HOME"; : >"$FIX/writes.log"; : >"$FIX/metadata.txt"
  echo '[{"index":1,"name":"speakers"},{"index":2,"name":"headset"}]' >"$FIX/sinks.json"
  cat >"$FIX/inputs.json" <<'EOF'
[{"index":10,"sink":2,"corked":false,"properties":{"object.id":"60","application.name":"Brave"}},
 {"index":11,"sink":2,"corked":true,"properties":{"object.id":"61","application.name":"Brave"}},
 {"index":12,"sink":2,"corked":false,"properties":{"object.id":"70","application.name":"Firefox"}}]
EOF
}

expect() {
  local name=$1 want=$2 got=$3
  if [[ $got == "$want" ]]; then echo "ok - $name"
  else echo "not ok - $name"; echo "  want: $(printf %q "$want")"; echo "  got:  $(printf %q "$got")"; failures=$((failures + 1)); fi
}

setup
"$helper" pin Brave speakers "Speakers"
expect "pin saves app, sink and label" $'Brave\tspeakers\tSpeakers' "$("$helper" list-pins)"
expect "pin routes the app's unrouted streams" $'60 target.object speakers\n61 target.object speakers' "$(cat "$FIX/writes.log")"

setup
"$helper" pin Brave speakers "Speakers" >/dev/null
: >"$FIX/writes.log"
echo "update: id:61 key:'target.object' value:'headset' type:'(null)'" >"$FIX/metadata.txt"
"$helper" apply-pins
expect "apply-pins leaves streams routed by hand" "60 target.object speakers" "$(cat "$FIX/writes.log")"

setup
"$helper" pin Brave missing "Gone"
expect "apply-pins skips a pin whose sink is unavailable" "" "$(cat "$FIX/writes.log")"

setup
"$helper" pin Brave speakers "Speakers"
"$helper" pin Brave headset "Headset"
expect "re-pinning replaces the old pin" $'Brave\theadset\tHeadset' "$("$helper" list-pins)"

setup
"$helper" pin Brave speakers "Speakers" >/dev/null
printf "update: id:60 key:'target.object' value:'speakers' type:'(null)'\nupdate: id:61 key:'target.object' value:'headset' type:'(null)'\n" >"$FIX/metadata.txt"
: >"$FIX/writes.log"
"$helper" unpin Brave
expect "unpin removes the pin" "" "$("$helper" list-pins)"
expect "unpin returns only pinned streams to default" $'-d 60 target.object\n-d 60 target.node' "$(cat "$FIX/writes.log")"

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
expect "apply-pins routes a stream whose target is -1" \
  $'60 target.object speakers\n61 target.object speakers' "$(cat "$FIX/writes.log")"

(( failures == 0 )) && echo "all passed" || { echo "$failures failed"; exit 1; }
