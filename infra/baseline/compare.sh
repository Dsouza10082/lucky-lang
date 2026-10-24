#!/usr/bin/env bash
# Compare two complete run.sh runs: procedure, status per stage, upstream
# commits and licenses, bootstrap, artifact hashes, test results, target matrix
# and collector inventory. Also shows, without comparing it, the environment
# each run declared.
#
# Usage: infra/baseline/compare.sh infra/evidence/lucky-001/<A> infra/evidence/lucky-001/<B>
# Exit status: 0 if they reproduce; 1 if they differ or a file is missing; 2 if
# either run did not pass every stage (not comparable).

. "$(dirname "$0")/lib.sh"

[ $# -eq 2 ] || die "usage: compare.sh RUN_A RUN_B"
a=${1%/} b=${2%/}

for run in "$a" "$b"; do
  [ -f "$run/status.tsv" ] || die "$run/status.tsv missing"
  if ! awk '$0 == "result: complete" { ok = 1 } END { exit !ok }' "$run/env.txt" 2>/dev/null; then
    echo "not comparable: $run did not finish with result complete"
    exit 2
  fi
  if awk -F'\t' 'NR > 1 && $2 != "pass" { bad = 1 } END { exit !bad }' "$run/status.tsv"; then
    echo "not comparable: $run has stages that did not pass"
    awk -F'\t' 'NR > 1 && $2 != "pass" { print "    " $1 ": " $2 " " $4 }' "$run/status.tsv"
    exit 2
  fi
done

differs=0
# check TITLE FILE COLUMNS: compare the columns (cut -f) of the file in both runs.
check() {
  local title=$1 file=$2 cols=$3 d
  if [ ! -f "$a/$file" ] || [ ! -f "$b/$file" ]; then
    echo "MISSING: $title ($file)"
    differs=1
    return
  fi
  if d=$(diff -u <(cut -f"$cols" "$a/$file") <(cut -f"$cols" "$b/$file")); then
    echo "same: $title"
  else
    echo "DIFFERENT: $title"
    printf '%s\n' "$d" | tail -n +3 | sed 's/^/    /'
    differs=1
  fi
}

check "procedure (scripts and locks)" scripts.sha256 1-
check "status per stage" status.tsv 1,2
check "upstream commits" upstreams.tsv 1-
check "upstream licenses" licenses.tsv 1-
check "licenses of modules vendored into Go" go-vendor-licenses.tsv 1-
check "bootstrap" bootstrap.txt 1-
check "C compiler" c-toolchain.txt 1-
check "artifact hashes" artifacts.sha256 1-
# In the test TSVs, column 6 (reason) may hold messages with timings; it is left out.
check "Go tests per package" go-tests.tsv 1-5,7
check "dist suite" go-dist-tests.tsv 1-
check "target matrix" targets.tsv 1-
check "Fyne modules" fyne-modules.txt 1-
check "Fyne module licenses" fyne-licenses.tsv 1-
check "Fyne packages with cgo" fyne-demo-cgo.tsv 1-
check "Fyne tests per package" fyne-tests.tsv 1-5,7
check "TAC versions" tac-versions.tsv 1-
check "TAC corpus" tac-corpus.sha256 1-
check "TAC tests per package" tac-tests.tsv 1-5,7
check "TAC corpus per case" tac-conformance.tsv 1-
check "collector components" gc-components.tsv 1-
for scope in std fyne tac; do check "collector uses ($scope)" "gc-usage-$scope.tsv" 1-; done
check "collector inventory" gc-inventory.txt 1-

echo
echo "declared environment (not compared):"
for key in clean_run workspace_commit workspace_dirty spec_sha256 os xcode_clt sdk_macos cpu bash git go_on_path free_space_start_mb; do
  va=$(awk -v k="$key" 'index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }' "$a/env.txt")
  vb=$(awk -v k="$key" 'index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }' "$b/env.txt")
  printf '    %-26s %s | %s\n' "$key" "$va" "$vb"
done
exit "$differs"
