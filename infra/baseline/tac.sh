#!/usr/bin/env bash
# Upstream TAC Lang with the baseline toolchain: build cmd/tac, record the
# language, IR and compiler versions and the identity of the conformance corpus
# (SPEC 1.1 and 9.1), and run the repository's test suite, which includes the
# conformance/laya corpus.

. "$(dirname "$0")/lib.sh"
require_go
require_src tac-language
cd "$SRC/tac-language"

"$GO" build -trimpath -o "$OUT/tac" ./cmd/tac
record_artifact out/tac "$OUT/tac"

awk -F'"' '/^[[:space:]]*(LanguageVersion|CompilerVersion|IRVersion|LayaLanguage)[[:space:]]*=/ {
  split($1, a, " "); print a[1] "\t" $2 }' compiler/version.go > "$EVIDENCE/tac-versions.tsv"
[ "$(wc -l < "$EVIDENCE/tac-versions.tsv" | tr -d ' ')" = 4 ] || die "compiler/version.go does not have the 4 expected versions"
# shellcheck disable=SC2046 # no spaces in names: pinned upstream corpus
(cd conformance/laya && sha256 $(find . -type f | LC_ALL=C sort)) > "$EVIDENCE/tac-corpus.sha256"

rc=0
"$GO" test -json -count=1 ./... > "$OUT/tac-tests.jsonl" 2> "$EVIDENCE/tac-tests.stderr" || rc=$?
trc=0
testsum -scope tac -known "$KNOWN_FAILURES" < "$OUT/tac-tests.jsonl" > "$EVIDENCE/tac-tests.tsv" || trc=$?
# One case per corpus file, with its status and reason (skipped cases included).
crc=0
testsum -scope tac -known "$KNOWN_FAILURES" -subtests-of TestConformance_LayaCorpus \
  < "$OUT/tac-tests.jsonl" > "$EVIDENCE/tac-conformance.tsv" || crc=$?

echo "versions:"
cat "$EVIDENCE/tac-versions.tsv"
echo "conformance/laya corpus: $(ls conformance/laya/*.tac | wc -l | tr -d ' ') cases; $(wc -l < "$EVIDENCE/tac-corpus.sha256" | tr -d ' ') files hashed"
echo "packages:"
summarize "$EVIDENCE/tac-tests.tsv"
echo "corpus cases:"
summarize "$EVIDENCE/tac-conformance.tsv"
awk -F'\t' '$2 == "skip" { print "skipped: " $1 ": " $3 } $2 ~ /^fail/ { print $2 ": " $1 ": " $3 }' "$EVIDENCE/tac-conformance.tsv"
awk -F'\t' '$2 ~ /^fail/ { print "failure: " $1 ": " $6 }' "$EVIDENCE/tac-tests.tsv"
[ "$crc" -eq 0 ] || exit 1
test_status "$rc" "$trc" "$EVIDENCE/tac-tests.tsv"
