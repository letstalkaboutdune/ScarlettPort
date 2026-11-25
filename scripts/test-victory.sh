#!/usr/bin/env bash
# Unattended test run of play-victory.sh on Linux: buttons pressed automatically, no sound, window
# pictures and a summary at the end. Needs ffmpeg and xwininfo (and gamescope with -H).
#
# Usage: scripts/test-victory.sh [options] <dump folder>
#   -t <seconds>   stop after this long (default 600)
#   -i <seconds>   time between pictures (default 30)
#   -w <seconds>   stop this long after the world is reached (default 120)
#   -k             press A on a timer only (VICTORY_AUTO_INPUT) instead of fast boot
#   -H             hidden: run in a headless gamescope instead of on the desktop
#   -n <name>      name of the run, added to its folder
#   -o <dir>       results folder (default screenshots/<time>[-name])
#   -v, -p         passed to play-victory.sh
#
# Uses the save slot "autotest", copied from "default" on first use, so automatic presses never
# touch a real save. It refuses to run without one: whoever plays must have gone through the
# title's first-boot screens by hand.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
state=${XDG_DATA_HOME:-$HOME/.local/share}/scarlettport
limit=600; every=30; after=120; out=; pass=(); keys=fast; hidden=0; name=
while getopts 't:i:w:kHn:o:v:p:h' o; do
    case $o in
        t) limit=$OPTARG ;;
        i) every=$OPTARG ;;
        w) after=$OPTARG ;;
        k) keys=timer ;;
        H) hidden=1 ;;
        n) name=-$OPTARG ;;
        o) out=$OPTARG ;;
        v|p) pass+=("-$o" "$OPTARG") ;;
        *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
    esac
done
shift $((OPTIND - 1))
[[ $# -eq 1 ]] || { echo 'Usage: test-victory.sh [options] <dump folder>' >&2; exit 1; }
game=$1
out=${out:-$root/screenshots/$(date +%Y%m%d-%H%M%S)$name}
mkdir -p "$out"

if pgrep -f 'release[\\/]victory\.exe' >/dev/null; then
    echo 'The runtime is already running; close it first.' >&2; exit 1
fi

for title in "$state"/data/*/slots/default; do
    [[ -n $(find "$title" -type f -print -quit 2>/dev/null) ]] ||
        { echo 'No "default" save slot yet: go through the first-boot screens by hand first.' >&2; exit 1; }
    slot=$(dirname "$title")/autotest
    [[ -d $slot ]] || cp -r "$title" "$slot"
done

pids=()
cleanup() {
    for p in "${pids[@]}"; do kill -TERM "$p" 2>/dev/null || true; done
    for _ in 1 2 3 4 5 6 7 8; do
        pgrep -f 'release[\\/]victory\.exe' >/dev/null || break; sleep 1
    done
    pkill -KILL -f 'release[\\/]victory\.exe' 2>/dev/null || true
}
trap cleanup EXIT

# A sink of our own that plays nowhere; it disappears with the process.
if command -v pw-loopback >/dev/null; then
    pw-loopback --capture-props='media.class=Audio/Sink node.name=scarlettport-null' \
        --playback-props='node.autoconnect=false node.passive=true' >/dev/null 2>&1 &
    pids+=($!)
    export PULSE_SINK=scarlettport-null
fi

if [[ $keys == fast ]]; then
    export VICTORY_FAST_BOOT=1 VICTORY_SKIP_CUTSCENES=1 VICTORY_FAST_BOOT_MAX_S=$limit
else
    export VICTORY_AUTO_INPUT=1
fi
export VICTORY_LOG=${VICTORY_LOG:-info}
export MESA_SPIRV_LOG_LEVEL=warning MESA_SPIRV_FAIL_DUMP_PATH=$out

# ENABLE_GAMESCOPE_WSI=0: frames go through the X window, where pictures can be taken of them.
if [[ $hidden == 1 ]]; then
    wrap=(env -u WAYLAND_DISPLAY gamescope --backend headless -W 1920 -H 1080 -w 1920 -h 1080 --
          env ENABLE_GAMESCOPE_WSI=0)
else
    wrap=(env)
fi
"${wrap[@]}" bash -c 'echo "$DISPLAY" >"$1/display"; shift; exec "$@"' _ "$out" \
    "$root/scripts/play-victory.sh" -s autotest "${pass[@]}" "$game" >"$out/launch.log" 2>&1 &
run=$!
pids+=("$run")

start=$SECONDS; shot=0; world=; log=; reason='time limit'
while (( SECONDS - start < limit )); do
    sleep 2
    if ! kill -0 "$run" 2>/dev/null; then reason='the program ended'; break; fi
    log=$(sed -n 's/^Log: *//p' "$out/launch.log")
    [[ -f $log ]] || continue
    if [[ -z $world ]] && grep -aq 'fast boot: in world' "$log"; then
        world=$SECONDS; echo "$((world - start)) s: in world"
    fi
    if [[ -n $world ]] && (( SECONDS - world >= after )); then reason='world time done'; break; fi
    if (( SECONDS - start >= shot )) && [[ -s $out/display ]]; then
        shot=$((SECONDS - start + every))
        disp=$(<"$out/display")
        # The game's own window: gamescope's root window has no picture.
        win=$(DISPLAY=$disp xwininfo -root -tree 2>/dev/null | grep -m1 '| VIctory' | grep -oE '0x[0-9a-f]+' | head -1 || true)
        [[ -z $win ]] || timeout 10 ffmpeg -v error -y -f x11grab -window_id "$win" -i "$disp" -frames:v 1 \
            -vf scale=960:-1 "$out/$(printf %04d $((SECONDS - start)))s.png" 2>>"$out/ffmpeg.log" || true
    fi
done
code=-
if [[ $reason == 'the program ended' ]]; then code=0; wait "$run" || code=$?; fi

plain() { sed 's/\x1b\[[0-9;]*m//g' "$log"; }
{
    echo "ended:     $reason after $((SECONDS - start)) s (exit $code)"
    if [[ -n $world ]]; then echo "world:     reached after $((world - start)) s"; else echo 'world:     not reached'; fi
    echo "log:       $log"
    [[ -f $log ]] && {
        plain | grep -aoE '[0-9.]+ fps,' | tail -20 | paste -sd' ' | sed 's/^/last fps:  /' || true
        echo '--- errors'
        plain | grep -aE 'ERROR|panick|overflowed|fatal|Exception 0x|device removed|DEVICE_(REMOVED|HUNG)|err:' |
            sed -E 's/^[0-9T:.Z-]+ +//' | cut -c1-220 | sort | uniq -c | sort -rn | head -15 || true
        echo '--- last lines'
        plain | grep -avE 'copystat|regions|Flushing|marked dirty|DSV format|victory_gpu::host:' | tail -8 | cut -c1-220 || true
    }
    ls "$out"/*fail* 2>/dev/null | sed 's/^/rejected shader: /' || true
} | tee "$out/summary.txt"
echo "results:   $out"
