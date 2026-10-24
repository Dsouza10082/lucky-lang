#!/usr/bin/env bash
# Build the baseline Go toolchain from the pinned sources.
#
# The bootstrap is the official release pinned in upstreams.lock (go-bootstrap):
# the go on PATH downloads the matching golang.org/toolchain module, verified
# against the checksum database, and the script requires the GOROOT it uses to
# be that download. To use a local install of the same version, set
# LUCKY_BOOTSTRAP_GOROOT (and optionally LUCKY_BOOTSTRAP_SHA256 with the
# expected sha256 of bin/go).

. "$(dirname "$0")/lib.sh"

version=$(lock_get go-bootstrap version)
require_src go

if [ -n "${LUCKY_BOOTSTRAP_GOROOT:-}" ]; then
  # Absolute path: make.bash runs in another directory and, if it cannot find
  # the bootstrap, would silently use the go on PATH.
  boot=$(CDPATH='' cd -P -- "$LUCKY_BOOTSTRAP_GOROOT" && pwd) || die "LUCKY_BOOTSTRAP_GOROOT does not exist: $LUCKY_BOOTSTRAP_GOROOT"
  origin="local install (LUCKY_BOOTSTRAP_GOROOT)"
  check="no origin verification"
  if [ -n "${LUCKY_BOOTSTRAP_SHA256:-}" ]; then
    [ "$(sha256 "$boot/bin/go" | cut -d' ' -f1)" = "$LUCKY_BOOTSTRAP_SHA256" ] || die "bootstrap bin/go does not match LUCKY_BOOTSTRAP_SHA256"
    check="sha256 of bin/go checked against LUCKY_BOOTSTRAP_SHA256"
  fi
  ziphash=""
else
  command -v go >/dev/null 2>&1 || skip "no go on PATH to fetch bootstrap $version; set LUCKY_BOOTSTRAP_GOROOT"
  echo "fetching bootstrap $version with $(command -v go) ($(go env GOVERSION))"
  module="golang.org/toolchain@v0.0.1-$version.$(go env GOHOSTOS)-$(go env GOHOSTARCH)"
  boot=$(GOTOOLCHAIN="$version" go env GOROOT)
  # A go$version on PATH (for example a golang.org/dl wrapper) would be used with
  # no download and no checksum database; only the downloaded module is accepted.
  [ "$boot" = "$GOMODCACHE/$module" ] || die "the resolved bootstrap is $boot, not module $module downloaded into GOMODCACHE"
  zipfile="$GOMODCACHE/cache/download/golang.org/toolchain/@v/${module#*@}.ziphash"
  [ -f "$zipfile" ] || die "ziphash missing for $module: the download was not recorded"
  ziphash=$(cat "$zipfile")
  origin="$module (downloaded by the go command)"
  check="checksum database $GOSUMDB"
fi
got=$("$boot/bin/go" env GOVERSION)
[ "$got" = "$version" ] || die "the bootstrap at $boot is $got; the lock requires $version"

# Fields that do not depend on the workspace path, so runs can be compared.
{
  echo "version: $got"
  echo "source: $origin"
  echo "verification: $check"
  echo "go_sha256: $(sha256 "$boot/bin/go" | cut -d' ' -f1)"
  if [ -n "$ziphash" ]; then echo "ziphash: $ziphash"; fi
} > "$EVIDENCE/bootstrap.txt"
cat "$EVIDENCE/bootstrap.txt"

mkdir -p "$OUT"
(cd "$BASELINE_GOROOT/src" && GOROOT_BOOTSTRAP="$boot" ./make.bash) 2>&1 | tee "$OUT/make.log"
# make.bash switches bootstrap with only a warning if the given one does not work.
grep -qF "Building Go cmd/dist using $boot. (" "$OUT/make.log" || die "make.bash did not use the recorded bootstrap ($boot)"

require_go
"$GO" version
"$GO" env > "$EVIDENCE/go-env.txt"

# The C compiler go actually uses for cgo, resolved on PATH.
cc=$("$GO" env CC)
{
  echo "cc: $cc"
  echo "cc_path: $(command -v "$cc" || echo missing)"
  echo "cc_version: $("$cc" --version 2>/dev/null | awk 'NR == 1' || true)"
  echo "cgo_enabled_default: $("$GO" env CGO_ENABLED)"
  if command -v xcrun >/dev/null 2>&1; then echo "sdk_macos: $(xcrun --show-sdk-version 2>/dev/null || echo unknown)"; fi
} > "$EVIDENCE/c-toolchain.txt"
cat "$EVIDENCE/c-toolchain.txt"

hosttools="pkg/tool/$("$GO" env GOHOSTOS)_$("$GO" env GOHOSTARCH)"
for f in "$BASELINE_GOROOT"/bin/* "$BASELINE_GOROOT/$hosttools"/*; do
  record_artifact "go/${f#"$BASELINE_GOROOT/"}" "$f"
done
