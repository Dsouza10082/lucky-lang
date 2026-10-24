# Functions and environment shared by the baseline scripts (LUCKY-001).
# Usage: . "$(dirname "$0")/lib.sh"
#
# Works with macOS bash 3.2 and with bash 5 and GNU tools.

set -euo pipefail

LUCKY_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BASELINE_DIR="$LUCKY_ROOT/infra/baseline"
LOCK_FILE="$BASELINE_DIR/upstreams.lock"
KNOWN_FAILURES="$BASELINE_DIR/known-failures.tsv"
WORK=${LUCKY_WORK:-$LUCKY_ROOT/.work}
case $WORK in /*) ;; *) WORK="$PWD/$WORK" ;; esac
SRC="$WORK/src"
OUT="$WORK/out"
# Evidence directory of the current run; run.sh sets one per run.
EVIDENCE=${LUCKY_EVIDENCE:-$WORK/evidence}

# Exit code for "not run"; the last printed line is the reason.
SKIP=77

# Isolate the caller's environment: Go configuration and caches, proxy and
# checksum database, automatic toolchain switching, workspaces, architecture
# variables, C compiler and cgo flags, runtime settings and locale.
# GOTOOLCHAIN=local keeps a go.mod from silently replacing the baseline compiler.
# LUCKY_CC and LUCKY_CXX pick another C compiler explicitly, and it is recorded.
unset GOROOT GOBIN GOOS GOARCH GOHOSTOS GOHOSTARCH CGO_ENABLED GOEXPERIMENT GODEBUG \
  GOAMD64 GOARM64 GO386 GOARM GOMIPS GOMIPS64 GOPPC64 GORISCV64 GOWASM GOFIPS140 \
  GO_GCFLAGS GO_LDFLAGS GO_EXTLINK_ENABLED GO_LDSO BOOT_GO_GCFLAGS BOOT_GO_LDFLAGS \
  GOCACHEPROG GOTMPDIR GOPRIVATE GONOPROXY GONOSUMDB GONOSUMCHECK GOINSECURE GOAUTH \
  GIT_HTTP_USER_AGENT CC CXX CC_FOR_TARGET CXX_FOR_TARGET PKG_CONFIG \
  CGO_CFLAGS CGO_CPPFLAGS CGO_CXXFLAGS CGO_FFLAGS CGO_LDFLAGS \
  MACOSX_DEPLOYMENT_TARGET SDKROOT DEVELOPER_DIR GOGC GOMEMLIMIT GOMAXPROCS GOTRACEBACK \
  GO111MODULE GOVCS GO_BUILDER_NAME GO_TEST_SHORT GO_TEST_SHARDS GO_TEST_TIMEOUT_SCALE \
  GO_TEST_ASMFLAGS GO_DISTFLAGS GOBOOTSTRAP_TOOLEXEC GOBUILDTIMELOGFILE GOROOT_BOOTSTRAP GOWASIRUNTIME \
  GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
  GIT_COMMON_DIR GIT_NAMESPACE GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT \
  CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH LIBRARY_PATH \
  PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR \
  TAC_WRITE_CONFORMANCE TAC_WRITE_COMPAT_BASELINE \
  LC_ALL LC_CTYPE LC_COLLATE LC_MESSAGES LC_NUMERIC LC_TIME
for v in $(env | awk -F= '/^(CC|CXX)_FOR_|^CGO_[A-Z]+_(ALLOW|DISALLOW)=/ { print $1 }'); do unset "$v"; done
if [ -n "${LUCKY_CC:-}" ]; then export CC=$LUCKY_CC; fi
if [ -n "${LUCKY_CXX:-}" ]; then export CXX=$LUCKY_CXX; fi
if [ -n "${LUCKY_PKG_CONFIG_PATH:-}" ]; then export PKG_CONFIG_PATH=$LUCKY_PKG_CONFIG_PATH; fi
# A source directory without its own .git must not resolve to the Lucky repository.
export GIT_CEILING_DIRECTORIES="$SRC"
export LANG=en_US.UTF-8 # same as Fyne's upstream CI
export GOENV=off
export GOWORK=off
export GOTOOLCHAIN=local
export GOFLAGS=-mod=readonly
export GOPROXY=https://proxy.golang.org,direct
export GOSUMDB=sum.golang.org
export GOCACHE="$WORK/cache/go-build"
export GOMODCACHE="$WORK/cache/mod"
export GOPATH="$WORK/gopath"

die() { echo "error: $*" >&2; exit 1; }
skip() { echo "not run: $*"; exit "$SKIP"; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

lock_names() { awk '/^[[:space:]]*(#|$)/ { next } { print $1 }' "$LOCK_FILE"; }

# lock_get NAME FIELD, where FIELD is role|source|version|id.
lock_get() {
  awk -v n="$1" -v f="$2" '
    /^[[:space:]]*(#|$)/ { next }
    $1 == n {
      i = (f == "role") ? 2 : (f == "source") ? 3 : (f == "version") ? 4 : (f == "id") ? 5 : 0
      if (i == 0) exit 2
      print $i; found = 1
    }
    END { exit found ? 0 : 1 }' "$LOCK_FILE" || die "field '$2' of entry '$1' missing from $LOCK_FILE"
}

# Baseline Go toolchain, built by build-go.sh. require_go sets GO and puts the
# baseline first on PATH, so that subprocesses use the same go.
BASELINE_GOROOT="$SRC/go"
require_go() {
  [ -x "$BASELINE_GOROOT/bin/go" ] || skip "baseline toolchain not built yet (build-go.sh)"
  GO="$BASELINE_GOROOT/bin/go"
  export PATH="$BASELINE_GOROOT/bin:$PATH"
  mkdir -p "$OUT"
}

# require_src NAME: the tree $SRC/NAME must be at the locked commit, with no
# changes to tracked files. Without a checkout, the stage is not run.
require_src() {
  local dir="$SRC/$1" want got
  want=$(lock_get "$1" id)
  got=$(git -C "$dir" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || skip "sources of $1 missing or incomplete in $dir (fetch.sh)"
  [ "$got" = "$want" ] || die "$1: $dir is at $got; the lock requires $want (run fetch.sh)"
  [ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ] || die "$1: $dir has changes to tracked files"
}

# Remove a tree that may contain the module cache (read-only files).
remove_tree() {
  [ -e "$1" ] || return 0
  chmod -R u+w "$1"
  rm -rf "$1"
}

# Record an artifact hash under a label that is stable across runs.
record_artifact() { # label path
  printf '%s  %s\n' "$(sha256 "$2" | cut -d' ' -f1)" "$1" >> "$EVIDENCE/artifacts.sha256"
}

# license_rows LABEL DIR: one line per license file at the top of DIR, with the
# label, file name, sha256 and first non-empty line of the text.
license_rows() {
  local f found=0
  for f in "$2"/[Ll][Ii][Cc][Ee][Nn][CcSs][Ee]* "$2"/[Cc][Oo][Pp][Yy][Ii][Nn][Gg]* "$2"/NOTICE* "$2"/PATENTS* "$2"/COPYRIGHT*; do
    [ -f "$f" ] || continue
    found=1
    printf '%s\t%s\t%s\t%s\n' "$1" "${f##*/}" "$(sha256 "$f" | cut -d' ' -f1)" "$(awk 'NF { gsub(/[[:space:]]+/, " "); sub(/^ /, ""); sub(/ $/, ""); print; exit }' "$f")"
  done
  if [ "$found" = 0 ]; then printf '%s\t-\t-\tno license file in the module directory\n' "$1"; fi
}

# testsum ARGS...: summarize "go test -json" from standard input (tools/testsum).
# Called on the left of ||, where set -e does not apply: hence the explicit returns.
testsum() {
  rm -f "$OUT/testsum"
  (cd "$BASELINE_DIR/tools/testsum" && "$GO" build -o "$OUT/testsum" main.go) || {
    echo "error: building tools/testsum failed" >&2
    return 1
  }
  "$OUT/testsum" "$@"
}

# test_status RC_GO_TEST RC_TESTSUM TSV: success only if the summary has no new
# failures and go test failed for nothing but known failures (exit status 1).
test_status() {
  [ "$2" -eq 0 ] || return 1
  [ "$1" -eq 0 ] && return 0
  [ "$1" -eq 1 ] || return 1
  awk -F'\t' '$2 == "fail-known" { k = 1 } END { exit !k }' "$3"
}

# Print the number of packages per status in a test TSV.
summarize() { cut -f2 "$1" | LC_ALL=C sort | uniq -c; }
