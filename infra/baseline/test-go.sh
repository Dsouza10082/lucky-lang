#!/usr/bin/env bash
# Run the Go test selection from go-tests.txt with the baseline toolchain.
#
# Writes go-tests.tsv (result per package, with skipped tests and subtests and
# the reason) and go-dist-tests.tsv (every entry of dist's full test suite and
# what happened to it in this run). The full JSON output stays in $WORK/out.
# LUCKY_GO_TEST_TIMEOUT (default 60m) replaces go test's 10-minute limit.

. "$(dirname "$0")/lib.sh"
require_go
require_src go

# Like dist: run inside the std module, so the go.mod of the calling directory
# changes neither GODEBUG nor the required version, and without GOFLAGS (std and
# cmd use their vendor directories).
cd "$BASELINE_GOROOT/src"
unset GOFLAGS

# Without a C compiler go turns cgo off, and cmd/cgo/internal/test would pass without testing cgo.
[ "$("$GO" env CGO_ENABLED)" = 1 ] || die "cgo disabled (no C compiler found); cmd/cgo/internal/test would not test cgo"

timeout=${LUCKY_GO_TEST_TIMEOUT:-60m}
pkgs=$(sed -e 's/#.*//' "$BASELINE_DIR/go-tests.txt" | awk 'NF { print $1 }')
# A pattern that selects nothing is only a warning in go test; here it is an error.
for p in $pkgs; do
  [ -n "$("$GO" list "$p" 2>/dev/null)" ] || die "go-tests.txt: pattern $p selects no package"
done
# shellcheck disable=SC2086 # each pattern is one argument
"$GO" list $pkgs > "$OUT/go-tests-selected.txt"
echo "go test -json -short -count=1 -timeout=$timeout" $pkgs

rc=0
# shellcheck disable=SC2086
"$GO" test -json -short -count=1 -timeout="$timeout" $pkgs > "$OUT/go-tests.jsonl" 2> "$EVIDENCE/go-tests.stderr" || rc=$?
trc=0
testsum -scope go -known "$KNOWN_FAILURES" < "$OUT/go-tests.jsonl" > "$EVIDENCE/go-tests.tsv" || trc=$?

# Every entry of dist's suite: the package status when the package was selected
# and run whole (no variant, or the single shard 0_1); not-run with a reason
# otherwise.
GOROOT="$BASELINE_GOROOT" "$GO" tool dist test -list > "$OUT/go-dist-test-list.txt"
awk -F'\t' '
  FILENAME == ARGV[1] { st[$1] = $2; next }
  FILENAME == ARGV[2] { sel[$1] = 1; next }
  {
    entry = $0; pkg = entry; variant = index(entry, ":")
    if (variant) pkg = substr(entry, 1, variant - 1)
    s = (pkg in st) ? st[pkg] : "no-result"
    if (!(pkg in sel)) print entry "\tnot-run\toutside the go-tests.txt selection"
    else if (variant && substr(entry, variant + 1) == "0_1") print entry "\t" s "\tsingle shard (whole package); go test -short; see go-tests.tsv"
    else if (variant) print entry "\tnot-run\tdist variant not run"
    else print entry "\t" s "\tgo test -short, without dist flags; see go-tests.tsv"
  }' "$EVIDENCE/go-tests.tsv" "$OUT/go-tests-selected.txt" "$OUT/go-dist-test-list.txt" > "$EVIDENCE/go-dist-tests.tsv"

echo "packages run:"
summarize "$EVIDENCE/go-tests.tsv"
echo "dist suite entries: $(wc -l < "$EVIDENCE/go-dist-tests.tsv" | tr -d ' ')"
cut -f2,3 "$EVIDENCE/go-dist-tests.tsv" | LC_ALL=C sort | uniq -c
awk -F'\t' '$2 ~ /^fail/ { print "failure: " $1 ": " $6 }' "$EVIDENCE/go-tests.tsv"
# Every selected package must have a result.
awk -F'\t' 'FILENAME == ARGV[1] { r[$1] = 1; next } !($1 in r) { print "no result: " $1; bad = 1 } END { exit bad }' \
  "$EVIDENCE/go-tests.tsv" "$OUT/go-tests-selected.txt" || exit 1
test_status "$rc" "$trc" "$EVIDENCE/go-tests.tsv"
