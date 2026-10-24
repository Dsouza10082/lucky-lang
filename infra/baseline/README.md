# Upstream baseline (LUCKY-001)

Rebuilds Lucky's upstream reference from the commits pinned in
[`upstreams.lock`](upstreams.lock) and records evidence for each stage. The
binaries built here are upstream Go, Fyne and TAC, **with a garbage
collector**: they are a comparison tool, not Lucky deliverables, and they do not
satisfy V15.

## Usage

```sh
infra/baseline/run.sh --clean            # run from scratch
infra/baseline/compare.sh infra/evidence/lucky-001/<A> infra/evidence/lucky-001/<B>
```

`run.sh` exits with 0 if every stage passed, 1 if one failed and 2 if one was
skipped (not run). `compare.sh` exits with 0 if the runs reproduce, 1 if they
differ and 2 if either run did not pass every stage.

## Host requirements

- `git`, `curl` (licenses of the Rust reference) and a C compiler for cgo.
  Without a C compiler, `go-test` fails instead of recording cgo without tests.
- Any `go` command 1.21 or later on `PATH`, used only to download the pinned
  bootstrap (go1.26.10). The script requires the GOROOT it uses to be that
  download, verified against the checksum database.
- Network access for the download steps: sources, bootstrap and Fyne modules.
- macOS: Xcode Command Line Tools.
- Linux: `pkg-config`, the GL and X11 development libraries that Fyne uses
  (`gl x11 xcursor xrandr xinerama xi xxf86vm`) and `xvfb-run` for the Fyne
  tests. Fyne's upstream CI installs `libgl1-mesa-dev xorg-dev xvfb`. Without
  them, the Fyne stages are recorded as not run, with the reason.

Sources, caches and outputs live in `.work/` (outside version control, about
4 GB at peak). `.work/src` is disposable: `fetch.sh` refuses to delete a tree
with local changes, and `--clean` deletes everything.

## Variables

| Variable | Effect |
| --- | --- |
| `LUCKY_WORK` | Work directory (default `.work/`). |
| `LUCKY_MIN_FREE_MB` | Minimum free space for a stage to start (default 2048). Below that the stage is skipped. |
| `LUCKY_ALLOW_SKIP` | Stages that may be skipped without exit status 2, separated by spaces. Recorded in `env.txt`. |
| `LUCKY_GO_TEST_TIMEOUT` | `go test` timeout in `go-test` (default `60m`). |
| `LUCKY_BOOTSTRAP_GOROOT` | Use a local go1.26.10 install instead of the download; `bootstrap.txt` records that no origin check was made. `LUCKY_BOOTSTRAP_SHA256` checks its `bin/go`. |
| `LUCKY_CC`, `LUCKY_CXX`, `LUCKY_PKG_CONFIG_PATH` | Explicit C and C++ compilers and pkg-config path. `lib.sh` discards `CC`, `CXX`, `CGO_*`, `PKG_CONFIG_*` and other Go variables from the environment. |

## Stages

| Stage | Script | What it records |
| --- | --- | --- |
| `fetch` | `fetch.sh` | Clones each upstream at its tag and fails if the commit differs from the lock or a license differs from [`licenses.lock`](licenses.lock). Rust is only checked on the remote. Records the licenses of the modules vendored into Go. |
| `go-build` | `build-go.sh` | Bootstrap, `make.bash`, `go env`, the C compiler actually used, and hashes of `bin/` and `pkg/tool/`. |
| `go-test` | `test-go.sh` | The [`go-tests.txt`](go-tests.txt) selection with `-short`, per package, with skipped tests and reasons; dist's full suite with what was not run. |
| `targets` | `targets.sh` | Targets from `go tool dist list`: compile without linking, link, and native run, all without cgo. Expected failures are in [`targets-expected.tsv`](targets-expected.tsv); any other failure fails the stage. |
| `fyne-build` | `fyne.sh build` | Build of `cmd/fyne_demo`, modules and licenses, packages with cgo and native files, `go mod verify` after the downloads. |
| `fyne-test` | `fyne.sh test` | The Fyne test suite with the upstream CI tags for this OS (without `-race`). |
| `tac` | `tac.sh` | Build of `cmd/tac`, language, IR and compiler versions, hash of the `conformance/laya` corpus, test suite and per-case corpus results. |
| `gc-inventory` | `gc-inventory.sh` | Curated list of the files that implement the collector or generate metadata for it; per-package uses of APIs coupled to the GC. |

Test results come from [`tools/testsum`](tools/testsum/main.go) over
`go test -json`: `pass`, `partial` (some test skipped), `not-run` (every test
skipped), `no-tests`, `fail` and `fail-known`. Known upstream failures go into
[`known-failures.tsv`](known-failures.tsv) with a reason, so they stay apart
from failures introduced by the project.

Each run creates `infra/evidence/lucky-001/<UTC>-<os>-<arch>/` with `env.txt`,
`status.tsv`, `logs/` and the files listed above. The full JSON test output
stays in `.work/out/`.
