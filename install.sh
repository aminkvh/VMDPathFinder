#!/bin/sh
# VMDPathFinder installer. Checks what is required, reports what is missing, then
# copies the plugin into VMD's user plugin directory.
#
#   ./install.sh              install for the current user
#   ./install.sh --check      report requirements and exit, install nothing
#   ./install.sh --dir DIR    install somewhere other than ~/.vmd/plugins
set -e
SRC=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEST="$HOME/.vmd/plugins"
CHECK_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        --dir)   shift; DEST="$1" ;;
        -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

miss=0
note() { printf '  %-28s %s\n' "$1" "$2"; }

echo "VMDPathFinder requirements"

# VMD itself. Everything else is optional; without VMD there is nothing to load.
VMD=""
for c in vmd vmd2; do command -v "$c" >/dev/null 2>&1 && { VMD=$c; break; }; done
if [ -n "$VMD" ]; then
    note "VMD" "found ($(command -v $VMD))"
else
    note "VMD" "MISSING - required. https://www.ks.uiuc.edu/Research/vmd/"
    miss=1
fi

# HOLE 2. Optional: the plugin ships a pure-Tcl HOLE engine and falls back to it
# automatically, so a missing binary costs speed, not capability.
HOLE=""
for p in "$HOME/hole2/exe/hole" "$(command -v hole 2>/dev/null)"; do
    [ -n "$p" ] && [ -x "$p" ] && { HOLE=$p; break; }
done
if [ -n "$HOLE" ]; then
    note "HOLE 2" "found ($HOLE)"
else
    note "HOLE 2" "not found - optional, the built-in Tcl engine is used instead"
fi

# Accelerators: NOT in the plugin zip. They arrive either as the per-OS
# binaries release asset (unpack it here as ./binaries/), or from a source
# build of the repository (./native/). Detect both.
BINDIR=""
for d in "$SRC/binaries" "$SRC"/vmdpathfinder-binaries-*/ "$SRC/native"; do
    # .exe too: the Windows bundle ships mole_tunnel_engine.exe, and checking
    # only the bare name meant Windows users were told no engine was present
    # while it sat right there.
    for e in "" ".exe"; do
        [ -x "$d/mole_tunnel_engine$e" ] && { BINDIR="${d%/}"; break 2; }
    done
done
if [ -n "$BINDIR" ]; then
    note "tunnel engine" "found ($BINDIR)"
else
    note "tunnel engine" "not present - Tunnel mode falls back to Tcl (slower). Download the vmdpathfinder-binaries asset for your OS and unpack it next to this script."
fi

# Trajectory data is NOT distributed with the plugin - see README.
note "trajectory data" "downloaded separately, see README (not bundled)"

if [ "$CHECK_ONLY" -eq 1 ]; then
    [ "$miss" -eq 0 ] && echo "All required components present." || echo "Required components are missing."
    exit "$miss"
fi
[ "$miss" -eq 0 ] || { echo; echo "Install aborted: VMD is required."; exit 1; }

echo
echo "Installing to $DEST/vmdpathfinder"
mkdir -p "$DEST/vmdpathfinder"
# Only what VMD loads: the plugin package, its licence/notice, and the binaries.
cp "$SRC/vmdpathfinder/vmdpathfinder.tcl"  "$DEST/vmdpathfinder/"
cp "$SRC/vmdpathfinder/pkgIndex.tcl" "$DEST/vmdpathfinder/"
for f in NOTICE.md LICENSE-Apache-2.0.txt; do
    [ -f "$SRC/vmdpathfinder/$f" ] && cp "$SRC/vmdpathfinder/$f" "$DEST/vmdpathfinder/"
done
# radius files the plugin ships (Martini 2 and 3 beads; HOLE's simple.rad)
if [ -d "$SRC/vmdpathfinder/rad" ]; then
    mkdir -p "$DEST/vmdpathfinder/rad"
    cp "$SRC/vmdpathfinder/rad/"*.rad "$DEST/vmdpathfinder/rad/"
fi
echo "Installed."

# Point the plugin AT the binaries rather than telling the user to do it. The
# release README says the installer does this; it did not, and a user following
# that text got a plugin that silently fell back to the Tcl engines.
#
# Conservative on purpose: only keys that are absent or empty, or that name a
# file which no longer exists, are written. A path the user chose deliberately
# is never overwritten, and every other line of the config is preserved.
if [ -n "$BINDIR" ]; then
    CFG="${VMDPATHFINDER_CONFIG_FILE:-$HOME/.vmdpathfinder_config}"
    BINABS=$(cd "$BINDIR" && pwd)
    TMP="$CFG.install.$$"
    : > "$TMP"
    wrote=0
    # config key : file in the bundle
    set -- "mole_engine_exec:mole_tunnel_engine" \
           "sos_triangle_exec:sos_triangle" \
           "conn_lobes_exec:conn_lobes" \
           "mesh_csg_exec:mesh_csg" \
           "nm_search_exec:nm_search" \
           "sph_process_exec:sph_process" \
           "hole_exec:hole"
    if [ -f "$CFG" ]; then cp "$CFG" "$TMP"; fi
    for pair in "$@"; do
        key=${pair%%:*}; file=${pair#*:}
        path=""
        for e in "" ".exe"; do
            [ -x "$BINABS/$file$e" ] && { path="$BINABS/$file$e"; break; }
        done
        [ -n "$path" ] || continue
        cur=$(sed -n "s/^$key = //p" "$TMP" 2>/dev/null | tail -1)
        if [ -n "$cur" ] && [ -x "$cur" ]; then continue; fi   # user's own choice stands
        grep -v "^$key = " "$TMP" > "$TMP.n" 2>/dev/null || : > "$TMP.n"
        mv "$TMP.n" "$TMP"
        echo "$key = $path" >> "$TMP"
        wrote=$((wrote+1))
    done
    if [ "$wrote" -gt 0 ]; then
        [ -f "$CFG" ] && cp "$CFG" "$CFG.bak-$(date +%Y%m%d-%H%M%S)"
        mv "$TMP" "$CFG"
        echo
        echo "Configured $wrote accelerator path(s) in $CFG (previous file kept as .bak-*)."
        echo "  Change them any time under File > Settings."
    else
        rm -f "$TMP"
        echo
        echo "Accelerator binaries found in $BINDIR; your existing paths already point at working files."
    fi
fi
echo
echo "Load it with:  vmd -e /dev/null   then  Extensions > Analysis > VMDPathFinder"
echo "or add to ~/.vmdrc:  vmd_install_extension vmdpathfinder vmdpathfinder_tk \"Analysis/VMDPathFinder\""
