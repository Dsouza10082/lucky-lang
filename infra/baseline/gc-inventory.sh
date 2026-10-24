#!/usr/bin/env bash
# Initial inventory of what depends on the garbage collector in the pinned
# sources (SPEC 15.4).
#
#   gc-components.tsv      curated list of the main runtime, compiler, linker and
#                          metadata files that implement the GC or generate data
#                          for it; not exhaustive
#   gc-usage-<scope>.tsv   per package: imports of runtime, unsafe and reflect;
#                          finalizers and cleanups, weak references, sync.Pool,
#                          GC control, KeepAlive, go:linkname; cgo, assembly and
#                          native (C, Objective-C, C++) files
#   gc-inventory.txt       summary per scope and category
#
# Scopes: std (standard library), fyne (non-std dependencies of cmd/fyne_demo)
# and tac (of cmd/tac). Packages and files are the union of what the build
# selects for each target in TARGETS. Maps, slices, strings, interfaces,
# closures, channels and goroutines, also listed in section 3.3, are not counted:
# they are left to LUCKY-003 and LUCKY-008. The counts are a text search
# (comments included) and prove neither a dependency nor its absence (SPEC 14.2).

. "$(dirname "$0")/lib.sh"
require_go
require_src go
goroot_src="$BASELINE_GOROOT/src"
r="$goroot_src/runtime"
c="$goroot_src/cmd/compile/internal"
l="$goroot_src/cmd/link/internal/ld"

# GUI targets: items 1 to 3 of SPEC section 12.2, covering the GUI groups of 11.3.
TARGETS="darwin/arm64 linux/amd64 linux/arm64 windows/amd64 android/arm64 ios/arm64 js/wasm"
CAVEAT="Text search over the pinned sources, comments included; proves neither a dependency on the collector nor its absence (SPEC 14.2)."

rm -f "$EVIDENCE"/gc-usage-*.tsv "$EVIDENCE/gc-components.tsv" "$EVIDENCE/gc-inventory.txt"

# for_targets COMMAND...: run COMMAND with each target's GOOS, GOARCH and CGO_ENABLED.
for_targets() {
  local target cgo
  for target in $TARGETS; do
    case $target in js/* | wasip1/*) cgo=0 ;; *) cgo=1 ;; esac
    env GOOS="${target%/*}" GOARCH="${target#*/}" CGO_ENABLED=$cgo "$@"
  done
}

components="$EVIDENCE/gc-components.tsv"
printf 'category\tfile\tlines\tlines_with_gc_identifiers\n' > "$components"
GC_RE='\bgc[A-Z][A-Za-z]*|[wW]riteBarrier|\bmarkBits|sweepgen|GCProg|[gG]cmask|ptrmask|PtrDataSize|PtrBytes|GCData'
# component CATEGORY FILE...: every file must exist in the baseline, so that an
# upstream rename cannot silently shrink the inventory.
component() {
  local cat=$1 f; shift
  for f in "$@"; do
    [ -f "$f" ] || die "component missing from the baseline: ${f#"$SRC/"}"
    printf '%s\t%s\t%s\t%s\n' "$cat" "${f#"$SRC/"}" "$(wc -l < "$f" | tr -d ' ')" \
      "$(grep -c -E "$GC_RE" "$f" || true)" >> "$components"
  done
}

component runtime-collector "$r"/mgc*.go "$r"/mbitmap*.go "$r"/mwbbuf.go "$r"/mbarrier.go "$r"/mcheckmark.go \
  "$r"/mspanset.go "$r"/pinner.go
# internal/runtime/gc and its subpackages (Green Tea scan kernels), as the build selects them.
(cd "$goroot_src" && for_targets "$GO" list -f '{{$d := .Dir}}{{range .GoFiles}}{{$d}}/{{.}}{{"\n"}}{{end}}{{range .SFiles}}{{$d}}/{{.}}{{"\n"}}{{end}}' internal/runtime/gc/...) |
  awk 'NF' | LC_ALL=C sort -u | while read -r f; do component runtime-collector "$f"; done
component runtime-finalization "$r"/mfinal.go "$r"/mcleanup.go
for f in "$r"/asm_*.s; do
  if grep -q gcWriteBarrier "$f"; then component runtime-barrier-asm "$f"; fi
done
component runtime-coupled "$r"/malloc.go "$r"/malloc_generated.go "$r"/malloc_stubs.go "$r"/mcache.go "$r"/mcentral.go \
  "$r"/mheap.go "$r"/arena.go "$r"/mstats.go "$r"/stack.go "$r"/stkframe.go "$r"/proc.go "$r"/mprof.go "$r"/heapdump.go \
  "$r"/cgocheck.go "$r"/atomic_pointer.go
component compiler-write-barrier "$c"/ssa/writebarrier.go "$c"/ssagen/nowb.go
component compiler-pointer-maps "$c"/liveness/*.go "$c"/reflectdata/reflect.go "$c"/typebits/typebits.go
component compiler-coupled "$c"/ssagen/ssa.go "$c"/types/size.go "$c"/gc/obj.go
# Deciding and lowering allocation on the collected heap: escapes and new/make/append/closures.
component compiler-heap-allocation "$c"/escape/*.go "$c"/walk/builtin.go "$c"/walk/assign.go "$c"/walk/complit.go \
  "$c"/walk/closure.go
component gc-metadata "$goroot_src"/cmd/internal/gcprog/gcprog.go "$goroot_src"/internal/abi/type.go \
  "$goroot_src"/internal/abi/symtab.go "$goroot_src"/reflect/type.go
component linker-pointer-maps "$l"/data.go "$l"/decodesym.go "$l"/symtab.go "$l"/pcln.go
# Tests are not part of the inventory.
awk -F'\t' 'NR == 1 || $2 !~ /_test\.go$/' "$components" > "$components.tmp" && mv "$components.tmp" "$components"

# usage SCOPE DIR PATTERN...: files, imports and categories per package, over the union of targets.
usage() {
  local scope=$1 dir=$2; shift 2
  (cd "$dir" && for_targets "$GO" list -deps -f \
    '{{if or (not .Standard) (eq "'"$scope"'" "std")}}{{$p := .ImportPath}}{{$d := .Dir}}{{range .GoFiles}}{{$p}}{{"\t"}}{{$d}}/{{.}}{{"\tgo\n"}}{{end}}{{range .CgoFiles}}{{$p}}{{"\t"}}{{$d}}/{{.}}{{"\tcgo\n"}}{{end}}{{range .SFiles}}{{$p}}{{"\t"}}{{$d}}/{{.}}{{"\tasm\n"}}{{end}}{{range .CFiles}}{{$p}}{{"\t"}}{{$d}}/{{.}}{{"\tnative\n"}}{{end}}{{range .MFiles}}{{$p}}{{"\t"}}{{$d}}/{{.}}{{"\tnative\n"}}{{end}}{{range .CXXFiles}}{{$p}}{{"\t"}}{{$d}}/{{.}}{{"\tnative\n"}}{{end}}{{range .Imports}}{{$p}}{{"\t"}}{{.}}{{"\timport\n"}}{{end}}{{end}}' \
    "$@") | LC_ALL=C sort -u | awk -F'\t' '
    $3 == "import" { if ($2 == "runtime" || $2 == "unsafe" || $2 == "reflect") n[$1, "imports-" $2] = 1; next }
    $3 == "native" { n[$1, "native-files"]++; next }
    $3 == "asm" { n[$1, "assembly-files"]++; next }
    $3 == "cgo" { n[$1, "cgo-files"]++ }
    {
      while ((getline line < $2) > 0) {
        if (line ~ /runtime\.(SetFinalizer|AddCleanup)\(/) n[$1, "finalizer-cleanup"]++
        if (line ~ /weak\.(Make|Pointer)|unique\.(Make|Handle)/) n[$1, "weak-reference"]++
        if (line ~ /sync\.Pool/) n[$1, "sync-pool"]++
        if (line ~ /runtime\.GC\(\)|debug\.(SetGCPercent|SetMemoryLimit|FreeOSMemory)\(/) n[$1, "gc-control"]++
        if (line ~ /runtime\.KeepAlive\(/) n[$1, "keepalive"]++
        if (line ~ /^\/\/go:linkname /) n[$1, "linkname"]++
      }
      close($2)
    }
    END { for (k in n) { split(k, a, SUBSEP); print a[1] "\t" a[2] "\t" n[k] } }' |
    LC_ALL=C sort > "$EVIDENCE/gc-usage-$scope.tsv"
}

missing=""
usage std "$goroot_src" std
if git -C "$SRC/fyne" rev-parse -q --verify HEAD >/dev/null 2>&1; then
  require_src fyne
  usage fyne "$SRC/fyne" ./cmd/fyne_demo
else
  missing="$missing fyne"
fi
if git -C "$SRC/tac-language" rev-parse -q --verify HEAD >/dev/null 2>&1; then
  require_src tac-language
  usage tac "$SRC/tac-language" ./cmd/tac
else
  missing="$missing tac"
fi

{
  echo "$CAVEAT"
  echo
  echo "# Collector components (curated list; files, lines)"
  awk -F'\t' 'NR > 1 { f[$1]++; l[$1] += $3 } END { for (c in f) printf "%-28s %4d files %7d lines\n", c, f[c], l[c] }' "$components" | LC_ALL=C sort
  for f in "$EVIDENCE"/gc-usage-*.tsv; do
    scope=${f##*/gc-usage-}
    scope=${scope%.tsv}
    case $scope in std) what="standard library" ;; fyne) what="non-std dependencies of cmd/fyne_demo" ;; tac) what="packages of cmd/tac" ;; esac
    echo
    echo "# Uses in $scope: $what (packages, occurrences; targets: $TARGETS)"
    if [ -s "$f" ]; then
      awk -F'\t' '{ p[$2]++; o[$2] += $3 } END { for (c in p) printf "%-28s %4d packages %7d occurrences\n", c, p[c], o[c] }' "$f" | LC_ALL=C sort
    else
      echo "no occurrence of the counted categories; this does not show independence from the collector"
    fi
  done
} | tee "$EVIDENCE/gc-inventory.txt"

if [ -n "$missing" ]; then
  echo "not run: scopes without sources:$missing" | tee -a "$EVIDENCE/gc-inventory.txt"
  exit "$SKIP"
fi
