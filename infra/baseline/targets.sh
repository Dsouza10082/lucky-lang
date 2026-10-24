#!/usr/bin/env bash
# Extract the baseline target list (go tool dist list) and record, per target
# and without cgo, the compilation of testdata/hellolib (no link) and the link of
# testdata/hello. Only the native target is run; the others stay pending.
#
# The matrix describes upstream Go (with a GC), used as a reference. No row is
# evidence of Lucky support: every Lucky profile is still pending.
#
# Fails if the native target does not compile, link and run, if a first-class
# target fails, or if a failure is not listed in targets-expected.tsv.

. "$(dirname "$0")/lib.sh"
require_go

hostos=$("$GO" env GOHOSTOS)
hostarch=$("$GO" env GOHOSTARCH)
host="$hostos/$hostarch"
commit=$(lock_get go id)
version=$(lock_get go version)
bins="$OUT/targets"
testdata="$BASELINE_DIR/testdata"
expected="$BASELINE_DIR/targets-expected.tsv"
mkdir -p "$bins"
# Separate cache for the other targets' objects, removed at the end to save disk.
export GOCACHE="$WORK/cache/go-build-targets"

# How the host runs binaries: "real", "emulated" or "undetermined" (SPEC 12.1).
host_execution() {
  case $hostos in
  darwin)
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then echo emulated; return; fi
    arm=$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)
    if { [ "$hostarch" = arm64 ] && [ "$arm" = 1 ]; } || { [ "$hostarch" = amd64 ] && [ "$arm" != 1 ]; }; then echo real; else echo emulated; fi
    ;;
  linux)
    case "$hostarch/$(uname -m)" in
    amd64/x86_64 | arm64/aarch64 | 386/i?86 | arm/armv* | riscv64/riscv64 | ppc64le/ppc64le | s390x/s390x | loong64/loongarch64) ;;
    *) echo emulated; return ;;
    esac
    # qemu-user and Rosetta fake uname, but /proc/cpuinfo comes from the real kernel.
    case $hostarch in
    amd64 | 386) grep -q '^flags' /proc/cpuinfo || { echo emulated; return; } ;;
    arm64 | arm) grep -q '^Features' /proc/cpuinfo || { echo emulated; return; } ;;
    esac
    if grep -qi rosetta /proc/self/maps 2>/dev/null; then echo emulated; return; fi
    # Without a visible binfmt_misc (common in containers), emulation cannot be ruled out.
    [ -e /proc/sys/fs/binfmt_misc/status ] || { echo undetermined; return; }
    for e in /proc/sys/fs/binfmt_misc/*; do
      case ${e##*/} in qemu-* | rosetta*) echo undetermined; return ;; esac
    done
    echo real
    ;;
  *) echo undetermined ;;
  esac
}

# variant OS ARCH: the target's sub-architecture variable and its default value.
variant() {
  local var
  case $2 in
  386) var=GO386 ;; amd64) var=GOAMD64 ;; arm) var=GOARM ;; arm64) var=GOARM64 ;;
  mips | mipsle) var=GOMIPS ;; mips64 | mips64le) var=GOMIPS64 ;;
  ppc64 | ppc64le) var=GOPPC64 ;; riscv64) var=GORISCV64 ;; wasm) var=GOWASM ;;
  *) echo "-"; return ;;
  esac
  echo "$var=$(env GOOS="$1" GOARCH="$2" "$GO" env "$var")"
}

# expected_failure TARGET STEP MESSAGE: print the external toolchain if the failure is expected.
expected_failure() {
  awk -F'\t' -v t="$1" -v s="$2" -v msg="$3" '
    /^[[:space:]]*(#|$)/ { next }
    $1 == t && $2 == s && index(msg, $3) { print $4; found = 1; exit }
    END { exit !found }' "$expected"
}

# First line of an error message that is not a package header ("# ...").
first_error() { printf '%s\n' "$1" | awk '!/^#/ && NF { print; exit }'; }

"$GO" tool dist list -json > "$EVIDENCE/go-dist-list.json"
# The dist list JSON has one field per line; turn it into "goos goarch cgo firstclass".
pairs=$(awk -F'"' '
  /"GOOS"/         { os = $4 }
  /"GOARCH"/       { arch = $4 }
  /"CgoSupported"/ { cgo = ($3 ~ /true/) ? "yes" : "no" }
  /"FirstClass"/   { first = ($3 ~ /true/) ? "yes" : "no"; print os, arch, cgo, first }
' "$EVIDENCE/go-dist-list.json")
[ -n "$pairs" ] || die "dist list -json returned no targets"
listed=$("$GO" tool dist list | wc -l | tr -d ' ')

go_test_state=pending
if awk -F'\t' '$1 == "go-test" && $2 == "pass" { ok = 1 } END { exit !ok }' "$EVIDENCE/status.tsv" 2>/dev/null; then
  go_test_state=executed
fi
execution=$(host_execution)

matrix="$EVIDENCE/targets.tsv"
printf 'target\tfirst_class\tupstream_cgo\tbuild_host\tprofile\tcommit\tvariant\texternal_toolchain\tcompile\tlink\trun\ttests\tpackaging\tnotes\n' > "$matrix"

total=0 built=0 linked=0 ran=0 failed=0 host_ok=0
while read -r os arch cgo first; do
  [ -n "$os" ] && [ -n "$arch" ] || die "invalid line in dist list: '$os $arch'"
  total=$((total + 1))
  target="$os/$arch"
  bin="$bins/hello-$os-$arch"
  compile=pending link=pending run=pending tests=pending external="-" notes=""

  if err=$(cd "$testdata" && env GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 "$GO" build ./hellolib 2>&1); then
    compile=compiled built=$((built + 1))
  elif external=$(expected_failure "$target" compile "$err"); then
    notes="compilation requires $external"
  else
    notes="unexpected compile failure: $(first_error "$err")" failed=1 external="-"
  fi

  if [ "$compile" = compiled ]; then
    if err=$(cd "$testdata" && env GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 "$GO" build -trimpath -o "$bin" ./hello 2>&1); then
      link=linked linked=$((linked + 1))
      record_artifact "targets/hello-$os-$arch" "$bin"
    elif external=$(expected_failure "$target" link "$err"); then
      notes="external linking required: $(first_error "$err")"
    else
      notes="unexpected link failure: $(first_error "$err")" failed=1 external="-"
    fi
  fi

  if [ "$target" = "$host" ] && [ "$link" = linked ]; then
    rrc=0
    out=$("$bin" 2>&1) || rrc=$?
    if [ "$rrc" -eq 0 ] && [ "$out" = "hello $target" ]; then
      run=executed ran=$((ran + 1)) host_ok=1 tests=$go_test_state
      notes="run on the build host: $execution; tests: go-tests.txt selection (-short)"
      [ "$execution" = real ] || notes="$notes; does not count as real hardware"
    else
      notes="native run failed: exit $rrc, '$(first_error "$out")'" failed=1
    fi
  elif [ -z "$notes" ]; then
    notes="not run: target differs from the build host"
  fi

  if [ "$first" = yes ] && [ "$link" != linked ]; then failed=1; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$target" "$first" "$cgo" "$host" "go-upstream-reference (with GC; CGO_ENABLED=0)" "$version@${commit:0:12}" \
    "$(variant "$os" "$arch")" "$external" "$compile" "$link" "$run" "$tests" pending "$notes" >> "$matrix"
done <<EOF
$pairs
EOF

rm -rf "$bins" "$GOCACHE"
echo "targets: $total (dist list: $listed); compiled: $built; linked: $linked; executed: $ran (host $host, execution $execution)"
awk -F'\t' 'NR > 1 && $10 != "linked" { print $1 "\t" $14 }' "$matrix"
[ "$total" -eq "$listed" ] || die "the matrix has $total targets; dist list has $listed"
[ "$host_ok" = 1 ] || die "the native target $host did not compile, link and run"
[ "$failed" = 0 ] || die "unexpected target failures (see targets.tsv)"
