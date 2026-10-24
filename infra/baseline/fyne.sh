#!/usr/bin/env bash
# Upstream Fyne with the baseline toolchain (reference with a GC, not a Lucky deliverable).
#
#   fyne.sh build  build cmd/fyne_demo; inventory the modules, the host's cgo and
#                  native-code packages, and the licenses of the modules the demo
#                  depends on across the GUI targets (input to the LUCKY-008
#                  audit); finally, go mod verify checks the downloaded modules
#   fyne.sh test   run the Fyne test suite with the upstream CI tags for this OS
#
# On Linux, missing GL/X11 libraries (or a missing xvfb-run, for the tests)
# mark the stage as not run, with the reason.

. "$(dirname "$0")/lib.sh"
require_go
require_src fyne
cd "$SRC/fyne"

# Native libraries that Fyne's GLFW driver needs on Linux (pkg-config).
linux_gui_deps() {
  [ "$("$GO" env GOHOSTOS)" = linux ] || return 0
  command -v pkg-config >/dev/null 2>&1 || skip "pkg-config missing; needed to check Fyne's GL/X11 libraries"
  local missing="" m
  for m in gl x11 xcursor xrandr xinerama xi xxf86vm; do
    pkg-config --exists "$m" || missing="$missing $m"
  done
  [ -z "$missing" ] || skip "Fyne native libraries missing (pkg-config):$missing"
}

# verify_modules: go mod verify after the downloads; the count depends on the cache.
verify_modules() {
  "$GO" mod verify
  echo "modules present in the cache and verified: $("$GO" list -m -f '{{if and (not .Main) .Dir}}{{.Path}}{{end}}' all | awk 'NF' | wc -l | tr -d ' ')"
}

# GUI targets, also used by gc-inventory.sh (items 1 to 3 of SPEC section 12.2).
GUI_TARGETS="darwin/arm64 linux/amd64 linux/arm64 windows/amd64 android/arm64 ios/arm64 js/wasm"

# demo_modules: non-main modules that cmd/fyne_demo depends on for some GUI
# target, with their directory in the cache (downloads any that are missing).
demo_modules() {
  local t c
  for t in $GUI_TARGETS; do
    case $t in js/*) c=0 ;; *) c=1 ;; esac
    env GOOS="${t%/*}" GOARCH="${t#*/}" CGO_ENABLED=$c "$GO" list -deps \
      -f '{{with .Module}}{{if not .Main}}{{.Path}}@{{.Version}}{{"\t"}}{{.Dir}}{{end}}{{end}}' ./cmd/fyne_demo
  done | awk 'NF' | LC_ALL=C sort -u
}

case "${1:-}" in
build)
  linux_gui_deps
  "$GO" list -m all > "$EVIDENCE/fyne-modules.txt"
  printf 'package\tmodule\tcgo\tc\tobjc\tcxx\tldflags\n' > "$EVIDENCE/fyne-demo-cgo.tsv"
  "$GO" list -deps -f '{{if .CgoFiles}}{{.ImportPath}}{{"\t"}}{{with .Module}}{{.Path}}{{if .Main}} (main){{else}}@{{.Version}}{{end}}{{else}}std{{end}}{{"\t"}}{{len .CgoFiles}}{{"\t"}}{{len .CFiles}}{{"\t"}}{{len .MFiles}}{{"\t"}}{{len .CXXFiles}}{{"\t"}}{{join .CgoLDFLAGS " "}}{{"\n"}}{{end}}' \
    ./cmd/fyne_demo >> "$EVIDENCE/fyne-demo-cgo.tsv"
  env CGO_ENABLED=1 "$GO" build -trimpath -o "$OUT/fyne_demo" ./cmd/fyne_demo
  record_artifact out/fyne_demo "$OUT/fyne_demo"
  if command -v otool >/dev/null 2>&1; then otool -L "$OUT/fyne_demo" | tail -n +2 > "$EVIDENCE/fyne-demo-linked.txt"
  elif command -v ldd >/dev/null 2>&1; then ldd "$OUT/fyne_demo" > "$EVIDENCE/fyne-demo-linked.txt"
  fi
  printf 'module\tfile\tsha256\tfirst_line\n' > "$EVIDENCE/fyne-licenses.tsv"
  license_rows "fyne.io/fyne/v2 (main)" "$SRC/fyne" >> "$EVIDENCE/fyne-licenses.tsv"
  # Independent of the cache state: only modules in fyne_demo's graph on the GUI targets.
  demo_modules | while IFS="$(printf '\t')" read -r mod dir; do license_rows "$mod" "$dir"; done >> "$EVIDENCE/fyne-licenses.tsv"
  verify_modules
  echo "modules in the graph: $(wc -l < "$EVIDENCE/fyne-modules.txt" | tr -d ' '); packages with cgo: $(tail -n +2 "$EVIDENCE/fyne-demo-cgo.tsv" | wc -l | tr -d ' ')"
  echo "fyne_demo built; not run: interactive GUI application (functional check is left to LUCKY-008)"
  ;;
test)
  linux_gui_deps
  # Same tags as .github/workflows/platform_tests.yml; -race left out to save time and disk.
  runner=""
  case "$("$GO" env GOHOSTOS)" in
  darwin | windows) tags=no_glfw,ci,migrated_fynedo ;;
  *)
    tags=ci,migrated_fynedo
    command -v xvfb-run >/dev/null 2>&1 || skip "xvfb-run missing; Fyne's upstream CI uses a virtual X server on this OS"
    runner=xvfb-run
    ;;
  esac
  echo "go test -json -count=1 -tags $tags ./... (LANG=$LANG)"
  rc=0
  $runner "$GO" test -json -count=1 -tags "$tags" ./... > "$OUT/fyne-tests.jsonl" 2> "$EVIDENCE/fyne-tests.stderr" || rc=$?
  trc=0
  testsum -scope fyne -known "$KNOWN_FAILURES" < "$OUT/fyne-tests.jsonl" > "$EVIDENCE/fyne-tests.tsv" || trc=$?
  verify_modules
  summarize "$EVIDENCE/fyne-tests.tsv"
  awk -F'\t' '$2 ~ /^fail/ { print "failure: " $1 ": " $6 }' "$EVIDENCE/fyne-tests.tsv"
  test_status "$rc" "$trc" "$EVIDENCE/fyne-tests.tsv"
  ;;
*) die "usage: fyne.sh build|test" ;;
esac
