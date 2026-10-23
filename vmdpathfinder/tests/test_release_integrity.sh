#!/bin/sh
# Release-integrity check.
#
# Builds packaging/vmdpathfinder.zip fresh from source (packaging/make_zip.sh) and checks
# what a "does it run?" test cannot see:
#   * no file shipped twice under a different name;
#   * the version string agrees with itself inside the shipped vmdpathfinder.tcl;
#   * pkgIndex.tcl points at a file that is actually there, at the right version;
#   * the ZIP really contains what was just built (nothing dropped in transit),
#     and carries the Apache notice.
#
# There is no "release copy behind dev" check any more: since the archive is
# built directly from `git ls-files` on every run, drift between "the release"
# and "the dev tree" is no longer a state that exists to check for - there is
# one source tree, not two kept in sync by hand.
#
# Usage:  ./test_release_integrity.sh [DEV_DIR]
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEV="${1:-$DIR/..}"
REPO=$(CDPATH= cd -- "$DEV/.." && pwd)
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  PASS  $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL  $1"; }

sh "$REPO/packaging/make_zip.sh" >/tmp/.make_zip.$$.log 2>&1
if [ $? -ne 0 ]; then
  bad "packaging/make_zip.sh failed:"; sed 's/^/          /' /tmp/.make_zip.$$.log
  rm -f /tmp/.make_zip.$$.log
  echo "  -> $pass passed, $fail failed"
  exit 1
fi
rm -f /tmp/.make_zip.$$.log
REL="$REPO/packaging/build/VMDPathFinder"
ZIP="$REPO/packaging/vmdpathfinder.zip"
echo "release-integrity: built fresh at $REL"

# 1. no basename shipped more than once
dups=$(find "$REL" -type f -name '*.tcl' | while read -r f; do basename "$f"; done | sort | uniq -d)
if [ -z "$dups" ]; then ok "no duplicated .tcl basenames"
else
  for d in $dups; do
    bad "'$d' ships more than once:"
    find "$REL" -type f -name "$d" | sed 's/^/          /'
  done
fi

# 2. every shipped copy of vmdpathfinder.tcl declares the SAME version (still
#    meaningful if a future layout ever ships more than one).
vers=$(find "$REL" -type f -name 'vmdpathfinder.tcl' -exec sed -n 's/^## VERSION: *\([^ ]*\).*/\1/p' {} \; | sort -u)
n=$(echo "$vers" | grep -c .)
if [ "$n" -eq 1 ]; then ok "all shipped vmdpathfinder.tcl at one version ($vers)"
else bad "shipped vmdpathfinder.tcl copies disagree on version: $(echo $vers | tr '\n' ' ')"; fi

# 2b. WITHIN the shipped vmdpathfinder.tcl, the three places declaring the version agree.
for f in $(find "$REL" -type f -name 'vmdpathfinder.tcl'); do
  hv=$(sed -n 's/^## VERSION: *\([^ ]*\).*/\1/p' "$f" | head -1)
  ppv=$(sed -n 's/^package provide vmdpathfinder *\([^ ]*\).*/\1/p' "$f" | head -1)
  vv=$(sed -n 's/^ *variable version *\([^ ]*\).*/\1/p' "$f" | head -1)
  if [ "$hv" = "$ppv" ] && [ "$hv" = "$vv" ] && [ -n "$hv" ]; then
    ok "$(basename $(dirname "$f"))/vmdpathfinder.tcl self-consistent at $hv"
  else
    bad "version disagreement inside $f: header='$hv' provide='$ppv' variable='$vv'"
  fi
done

# 3. pkgIndex points at a file that exists, and its version matches the header
for pk in $(find "$REL" -name pkgIndex.tcl); do
  d=$(dirname "$pk")
  if [ -f "$d/vmdpathfinder.tcl" ]; then ok "pkgIndex target exists ($(basename "$d")/vmdpathfinder.tcl)"
  else bad "pkgIndex at $pk sources a missing vmdpathfinder.tcl"; fi
  pv=$(sed -n 's/.*package ifneeded vmdpathfinder \([^ ]*\).*/\1/p' "$pk")
  hv=$(sed -n 's/^## VERSION: *\([^ ]*\).*/\1/p' "$d/vmdpathfinder.tcl" 2>/dev/null)
  if [ -n "$pv" ] && [ "$pv" = "$hv" ]; then ok "pkgIndex version $pv matches header"
  else bad "pkgIndex version '$pv' != header version '$hv'"; fi
done

# 4. the ZIP really contains what make_zip.sh just staged - nothing dropped
#    silently between "files copied" and "files zipped".
if [ ! -f "$ZIP" ]; then
  bad "packaging/vmdpathfinder.zip was not produced by make_zip.sh"
elif ! command -v unzip >/dev/null 2>&1; then
  echo "  SKIP  no unzip - cannot verify the release ZIP"
else
  zt=$(unzip -p "$ZIP" VMDPathFinder/vmdpathfinder/vmdpathfinder.tcl 2>/dev/null | md5sum | cut -d" " -f1)
  dt=$(md5sum "$DEV/vmdpathfinder.tcl" | cut -d" " -f1)
  if [ "$zt" = "$dt" ]; then ok "the ZIP ships the current vmdpathfinder.tcl"
  else bad "packaging/vmdpathfinder.zip ships a STALE vmdpathfinder.tcl - run packaging/make_zip.sh"; fi
  zn=$(unzip -l "$ZIP" | tail -1 | awk "{print \$2}")
  tn=$(cd "$REL" && find . -type f | wc -l)
  if [ "$zn" -eq "$tn" ]; then ok "the ZIP has every staged file ($zn)"
  else bad "ZIP has $zn file(s), the staged build has $tn - run packaging/make_zip.sh"; fi
  for must in VMDPathFinder/vmdpathfinder/NOTICE.md VMDPathFinder/vmdpathfinder/LICENSE-Apache-2.0.txt \
              VMDPathFinder/vmdpathfinder/LICENSE-MIT-MOLE2.txt; do
    if unzip -l "$ZIP" 2>/dev/null | grep -q "$must"; then ok "ZIP carries $(basename "$must")"
    else bad "ZIP is missing $must - the Apache notice must travel with the code"; fi
  done
fi

echo "  -> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
