#!/usr/bin/env bash
# Run the LUCKY-001 baseline and write the evidence to
# infra/evidence/lucky-001/<run>/: environment, status per stage, logs,
# artifact hashes, test results, licenses, target matrix and collector inventory.
#
# Usage: infra/baseline/run.sh [--clean]
#   --clean  delete $WORK (sources, caches and outputs) before starting
#
# status.tsv records each stage as pass, fail or skip (not run, with the
# reason). Exit status: 0 if every stage passed; 1 if one failed; 2 if one was
# skipped without being listed in LUCKY_ALLOW_SKIP (space-separated stage names).
# If fetch does not pass, the later stages are not run.
#
# LUCKY_MIN_FREE_MB (default 2048): a stage does not start with less free space.

. "$(dirname "$0")/lib.sh"

clean=0
case "${1:-}" in
--clean) clean=1 ;;
"") ;;
*) die "usage: run.sh [--clean]" ;;
esac

min_free_mb=${LUCKY_MIN_FREE_MB:-2048}
allow_skip=${LUCKY_ALLOW_SKIP:-}
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
export LUCKY_EVIDENCE="$LUCKY_ROOT/infra/evidence/lucky-001/$run_id"
EVIDENCE=$LUCKY_EVIDENCE
mkdir -p "$EVIDENCE/logs"

if [ "$clean" = 1 ]; then remove_tree "$WORK"; fi
mkdir -p "$WORK" "$OUT"

free_mb() { df -Pm "$WORK" | awk 'NR == 2 { print $4 }'; }

workspace_state() {
  local st
  st=$(git -C "$LUCKY_ROOT" status --porcelain -- . ':!infra/evidence' 2>/dev/null) || { echo unknown; return; }
  if [ -n "$st" ]; then echo yes; else echo no; fi
}

{
  echo "run: $run_id"
  echo "start_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "clean_run: $([ "$clean" = 1 ] && echo yes || echo no)"
  echo "workspace_commit: $(git -C "$LUCKY_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "workspace_dirty: $(workspace_state)"
  spec="$LUCKY_ROOT/spec/SPEC-Lucky.md"
  echo "spec_sha256: $([ -f "$spec" ] && sha256 "$spec" | cut -d' ' -f1 || echo missing)"
  echo "uname: $(uname -a)"
  if command -v sw_vers >/dev/null 2>&1; then
    echo "os: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
    echo "cpu: $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) logical cores"
    echo "memory_bytes: $(sysctl -n hw.memsize)"
    echo "xcode_clt: $(pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null | awk '/^version/ { print $2 }')"
    echo "sdk_macos: $(xcrun --show-sdk-version 2>/dev/null || echo unknown)"
  elif [ -r /etc/os-release ]; then
    echo "os: $(. /etc/os-release && echo "$PRETTY_NAME")"
    echo "cpu: $(awk -F': ' '/model name/ { print $2; exit }' /proc/cpuinfo), $(nproc) logical cores"
  fi
  echo "bash: ${BASH_VERSION}"
  echo "git: $(git --version)"
  echo "cc_on_path: $(cc --version 2>/dev/null | awk 'NR == 1' || true)"
  echo "go_on_path: $(command -v go || echo missing) $(go env GOVERSION 2>/dev/null || true)"
  echo "locale: LANG=$LANG (set by lib.sh)"
  echo "lucky_cc: ${LUCKY_CC:-go default}; lucky_cxx: ${LUCKY_CXX:-go default}; lucky_pkg_config_path: ${LUCKY_PKG_CONFIG_PATH:-none}"
  echo "lucky_allow_skip: ${allow_skip:-none}"
  echo "lucky_min_free_mb: $min_free_mb"
  echo "free_space_start_mb: $(free_mb)"
} > "$EVIDENCE/env.txt"
# shellcheck disable=SC2046 # no spaces in names: this repository's own tree
(cd "$BASELINE_DIR" && sha256 $(find . -type f | LC_ALL=C sort)) > "$EVIDENCE/scripts.sha256"

blocked=""
stage() { # name command [args...]
  local name=$1 log="$EVIDENCE/logs/$1.log" start rc=0 status note elapsed
  shift
  start=$(date +%s)
  printf '==> %-12s ' "$name"
  if [ -n "$blocked" ]; then
    echo "not run: $blocked" > "$log"
    rc=$SKIP
  elif [ "$(free_mb)" -lt "$min_free_mb" ]; then
    echo "not run: free space $(free_mb) MB below $min_free_mb MB" > "$log"
    rc=$SKIP
  else
    "$@" > "$log" 2>&1 || rc=$?
  fi
  case $rc in
  0) status=pass note="" ;;
  "$SKIP") status=skip note=$(tail -1 "$log") ;;
  *) status=fail note="exit $rc; see logs/$name.log" ;;
  esac
  elapsed=$(($(date +%s) - start))
  printf '%s\t%s\t%s\t%s\n' "$name" "$status" "$elapsed" "$note" >> "$EVIDENCE/status.tsv"
  echo "$status (${elapsed}s) $note"
}

printf 'stage\tstatus\tseconds\treason\n' > "$EVIDENCE/status.tsv"
stage fetch "$BASELINE_DIR/fetch.sh"
if ! awk -F'\t' '$1 == "fetch" && $2 == "pass" { ok = 1 } END { exit !ok }' "$EVIDENCE/status.tsv"; then
  blocked="sources not verified in this run (fetch did not pass)"
fi
stage go-build "$BASELINE_DIR/build-go.sh"
stage go-test "$BASELINE_DIR/test-go.sh"
stage targets "$BASELINE_DIR/targets.sh"
stage fyne-build "$BASELINE_DIR/fyne.sh" build
stage fyne-test "$BASELINE_DIR/fyne.sh" test
stage tac "$BASELINE_DIR/tac.sh"
stage gc-inventory "$BASELINE_DIR/gc-inventory.sh"

if [ -f "$EVIDENCE/artifacts.sha256" ]; then
  LC_ALL=C sort -k2 -o "$EVIDENCE/artifacts.sha256" "$EVIDENCE/artifacts.sha256"
fi

result=complete code=0
if awk -F'\t' 'NR > 1 && $2 == "fail" { f = 1 } END { exit !f }' "$EVIDENCE/status.tsv"; then
  result=failed code=1
elif awk -F'\t' -v allow=" $allow_skip " 'NR > 1 && $2 == "skip" && index(allow, " " $1 " ") == 0 { s = 1 } END { exit !s }' "$EVIDENCE/status.tsv"; then
  result=incomplete code=2
elif awk -F'\t' 'NR > 1 && $2 == "skip" { s = 1 } END { exit !s }' "$EVIDENCE/status.tsv"; then
  result="complete with allowed skipped stages ($allow_skip)"
fi
{
  echo "end_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "free_space_end_mb: $(free_mb)"
  echo "result: $result"
} >> "$EVIDENCE/env.txt"

echo
echo "evidence: ${EVIDENCE#"$LUCKY_ROOT/"}"
tail -n +2 "$EVIDENCE/status.tsv" | cut -f2 | LC_ALL=C sort | uniq -c
echo "result: $result"
exit "$code"
