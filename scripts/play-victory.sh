#!/usr/bin/env bash
# Launches a title on the VIctory-based runtime through Proton, from your own dump (you need your
# own legally obtained copy; nothing is included in this repository).
# Linux counterpart of play-victory.ps1.
#
# Usage: scripts/play-victory.sh [options] <dump folder> [-- extra victory args]
#   -c series-s|series-x   console profile (default series-s)
#   -a                     press A on a timer (VICTORY_AUTO_INPUT=1)
#   -f                     testing only: VICTORY_FAST_BOOT=1
#   -s <name>              save slot
#   -p <proton dir>        Proton to use (default: newest GE-Proton, else Proton Experimental)
#   -r <dir>               state folder: prefix, cache, saves (default ~/.local/share/scarlettport)
#   -v <dir>               use this folder's vkd3d-proton DLLs (d3d12.dll, d3d12core.dll) instead of Proton's
#   -d                     Wine/vkd3d diagnostics (PROTON_LOG)
#   -n                     do not start the title: prepare, map and bind only
#
# Stock Proton aborts outside Steam (its steam.exe helper); run it with PROTON_VERB=runinprefix
# once its prefix exists. GE-Proton needs nothing.
# Any VICTORY_* variable already set in the environment is passed through.
set -euo pipefail

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

root=$(cd "$(dirname "$0")/.." && pwd)
exe=$root/runtime/victory/target/x86_64-pc-windows-msvc/release/victory.exe
console=series-s; proton=; state=${XDG_DATA_HOME:-$HOME/.local/share}/scarlettport
vkd3d=; debug=0; execute=(--execute)
while getopts 'c:afs:p:r:v:dnh' o; do
    case $o in
        c) console=$OPTARG ;;
        a) export VICTORY_AUTO_INPUT=1 ;;
        f) export VICTORY_FAST_BOOT=1 ;;
        s) export VICTORY_SAVE_SLOT=$OPTARG ;;
        p) proton=$OPTARG ;;
        r) state=$OPTARG ;;
        v) vkd3d=$(realpath "$OPTARG") ;;
        d) debug=1 ;;
        n) execute=() ;;
        h) usage ;;
        *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))
[[ $# -ge 1 ]] || usage 1
game=$(realpath "$1"); shift
[[ ${1:-} == -- ]] && shift

# Steam root: native package, then Flatpak-less defaults, then snap.
for d in "${STEAM_ROOT:-}" "$HOME/.local/share/Steam" "$HOME/.steam/root" \
         "$HOME/snap/steam/common/.local/share/Steam"; do
    [[ -n $d && -d $d/steamapps ]] && { steam=$(realpath "$d"); break; }
done
[[ -n ${steam:-} ]] || { echo 'No Steam folder found; set STEAM_ROOT.' >&2; exit 1; }

if [[ -z $proton ]]; then
    proton=$(ls -d "$steam"/compatibilitytools.d/GE-Proton* 2>/dev/null | sort -V | tail -1 || true)
    [[ -n $proton ]] || proton="$steam/steamapps/common/Proton - Experimental"
fi
[[ -x $proton/proton ]] || { echo "No proton script in '$proton'." >&2; exit 1; }
runtime=$steam/steamapps/common/SteamLinuxRuntime_4/run
[[ -x $runtime ]] || { echo 'SteamLinuxRuntime_4 is not installed.' >&2; exit 1; }
[[ -f $exe ]] || { echo "Not built: $exe" >&2; exit 1; }
[[ -f $game/game_scarlett_master.exe ]] || { echo "No game_scarlett_master.exe in '$game'." >&2; exit 1; }

z() { printf 'Z:%s' "${1//\//\\}"; }   # host path -> path inside the prefix

mkdir -p "$state"/{prefix,cache,data} "$root/logs"
: >"$root/press.txt"
stamp=$(date +%Y%m%d-%H%M%S)
log=$root/logs/victory-$stamp.log

export VICTORY_GAME_DIR VICTORY_CACHE_DIR VICTORY_DATA_DIR VICTORY_PRESS_FILE
VICTORY_GAME_DIR=$(z "$game")
VICTORY_CACHE_DIR=$(z "$state/cache")
VICTORY_DATA_DIR=$(z "$state/data")
VICTORY_PRESS_FILE=$(z "$root/press.txt")
export VICTORY_OWN_UPSCALER=${VICTORY_OWN_UPSCALER-1}
export VICTORY_NO_WATCHDOG=${VICTORY_NO_WATCHDOG-1}
# vkd3d-proton translates shaders on the calling thread: the pipeline threads' default 2 MB stack
# overflows on the larger ones.
export RUST_MIN_STACK=${RUST_MIN_STACK-67108864}

export STEAM_COMPAT_DATA_PATH=$state/prefix
export STEAM_COMPAT_CLIENT_INSTALL_PATH=$steam
# Folders the container must see besides the home folder's defaults.
export STEAM_COMPAT_MOUNTS=$game:$root:$state:$proton
export STEAM_COMPAT_INSTALL_PATH=$game
export SteamAppId=${SteamAppId:-0} SteamGameId=${SteamGameId:-0}
export UMU_ID=${UMU_ID:-0}
# No Steam overlay or Proton-side game fixes: this is not a Steam title.
export PROTONFIXES_DISABLE=1
if [[ $debug == 1 ]]; then
    export PROTON_LOG=1 PROTON_LOG_DIR=$root/logs
    export VKD3D_DEBUG=${VKD3D_DEBUG:-warn}
fi

# DLLs beside the program win over the prefix's; plain copies, removed when -v is not given.
# d3dcompiler_47.dll (Microsoft's own) is optional: Wine's refuses some of the runtime's shaders.
for dll in d3d12.dll d3d12core.dll d3dcompiler_47.dll; do
    rm -f "$(dirname "$exe")/$dll"
    [[ ! -f $vkd3d/$dll ]] || cp "$vkd3d/$dll" "$(dirname "$exe")/$dll"
done

echo "Proton:  $(basename "$proton")"
echo "Profile: $console"
echo "Log:     $log"
cd "$(dirname "$exe")"
# A Windows path makes Proton start the program directly; a host path goes through a helper that
# drops its console output.
exec "$runtime" -- "$proton/proton" "${PROTON_VERB:-waitforexitandrun}" "$(z "$exe")" \
    run "$(z "$game/game_scarlett_master.exe")" "${execute[@]}" --console "$console" "$@" >"$log" 2>&1
