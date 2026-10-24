// Command testsum summarizes "go test -json" output (standard input) as TSV.
//
// By default it prints one package per line: package, status, top-level tests
// passed, failed and skipped, reason, and skipped subtests. Statuses:
//
//	pass        every test and subtest that ran passed
//	partial     passed, but some test or subtest was skipped (t.Skip)
//	not-run     every test was skipped
//	no-tests    the package has no tests, or none was selected
//	fail        build, test or test-process failure (panic, timeout, test
//	            without a result)
//	fail-known  only test failures listed in -known; a panic, timeout or test
//	            without a result in the same package is still fail
//
// With -subtests-of NAME it prints the direct subtests of NAME: case, status
// (pass, fail, fail-known or skip) and reason.
//
// It exits with 1 if there is a failure not listed in -known, if a package or
// test ends without a final result, or if the input has no package.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
)

type event struct {
	Action      string
	Package     string
	Test        string
	Output      string
	FailedBuild string
	ImportPath  string // build-output and build-fail events
}

type testResult struct {
	action string
	output []string
}

type pkgResult struct {
	action      string // pass, fail, skip; empty if the output ended early
	failedBuild string
	output      []string
	tests       map[string]*testResult
	order       []string
}

func main() {
	known := flag.String("known", "", "TSV file of known failures: scope, package, test (or *), reason")
	scope := flag.String("scope", "", "scope used to match the -known entries")
	subtestsOf := flag.String("subtests-of", "", "list the direct subtests of this test")
	flag.Parse()

	pkgs, builds, err := read(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "testsum:", err)
		os.Exit(1)
	}
	knownSet, err := loadKnown(*known, *scope)
	if err != nil {
		fmt.Fprintln(os.Stderr, "testsum:", err)
		os.Exit(1)
	}
	if *subtestsOf != "" {
		os.Exit(printSubtests(pkgs, *subtestsOf, knownSet))
	}
	os.Exit(printPackages(pkgs, builds, knownSet))
}

func read(r io.Reader) (map[string]*pkgResult, map[string][]string, error) {
	pkgs := map[string]*pkgResult{}
	builds := map[string][]string{}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 1<<20), 64<<20)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 || line[0] != '{' {
			continue
		}
		var e event
		if err := json.Unmarshal(line, &e); err != nil {
			continue
		}
		if e.Action == "build-output" {
			builds[e.ImportPath] = append(builds[e.ImportPath], e.Output)
			continue
		}
		if e.Package == "" {
			continue
		}
		p := pkgs[e.Package]
		if p == nil {
			p = &pkgResult{tests: map[string]*testResult{}}
			pkgs[e.Package] = p
		}
		if e.Test == "" {
			switch e.Action {
			case "output":
				p.output = append(p.output, e.Output)
			case "pass", "fail", "skip":
				p.action, p.failedBuild = e.Action, e.FailedBuild
			}
			continue
		}
		t := p.tests[e.Test]
		if t == nil {
			t = &testResult{}
			p.tests[e.Test] = t
			p.order = append(p.order, e.Test)
		}
		switch e.Action {
		case "output":
			t.output = append(t.output, e.Output)
		case "pass", "fail", "skip":
			t.action = e.Action
		}
	}
	return pkgs, builds, sc.Err()
}

func loadKnown(path, scope string) (map[string]string, error) {
	set := map[string]string{}
	if path == "" {
		return set, nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.TrimSpace(line) == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Split(line, "\t")
		if len(f) < 4 {
			return nil, fmt.Errorf("%s: line without 4 columns: %q", path, line)
		}
		if f[0] == scope {
			set[f[1]+"\t"+f[2]] = f[3]
		}
	}
	return set, nil
}

func printPackages(pkgs map[string]*pkgResult, builds map[string][]string, known map[string]string) int {
	if len(pkgs) == 0 {
		fmt.Fprintln(os.Stderr, "testsum: no package in the input")
		return 1
	}
	names := make([]string, 0, len(pkgs))
	for name := range pkgs {
		names = append(names, name)
	}
	sort.Strings(names)

	code := 0
	for _, name := range names {
		p := pkgs[name]
		var pass, fail, skip, subSkip int
		var failed, incomplete []string
		firstSkip := ""
		aborted := hasPanic(p.output)
		for _, tn := range p.order {
			t := p.tests[tn]
			if hasPanic(t.output) {
				aborted = true
			}
			if strings.Contains(tn, "/") {
				if t.action == "skip" {
					subSkip++
					if firstSkip == "" {
						firstSkip = tn + ": " + reason(t.output)
					}
				}
				continue
			}
			switch t.action {
			case "pass":
				pass++
			case "fail":
				fail++
				failed = append(failed, tn)
			case "skip":
				skip++
				if firstSkip == "" {
					firstSkip = reason(t.output)
				}
			default:
				incomplete = append(incomplete, tn)
			}
		}

		status, why := "", ""
		switch {
		case p.action == "":
			status, why = "fail", "no final result (output cut short)"
		case p.action == "fail" && p.failedBuild != "":
			status, why = "fail", "build: "+firstBuildError(builds[p.failedBuild])
		case p.action == "fail" && (len(failed) == 0 || len(incomplete) > 0 || aborted):
			out := append([]string{}, p.output...)
			for _, tn := range append(incomplete, failed...) {
				out = append(out, p.tests[tn].output...)
			}
			status, why = "fail", "test process: "+processError(out)
			if len(incomplete) > 0 {
				why = "tests without a result: " + list(incomplete) + "; " + why
			}
		case p.action == "fail":
			status = "fail-known"
			for _, tn := range failed {
				if _, ok := known[name+"\t"+tn]; !ok {
					if _, ok := known[name+"\t*"]; !ok {
						status = "fail"
					}
				}
			}
			why = "failures: " + list(failed)
		case len(incomplete) > 0:
			status, why = "fail", "tests without a result: "+list(incomplete)
		case pass+skip == 0:
			status, why = "no-tests", noTestsReason(p.output)
		case pass == 0:
			status, why = "not-run", firstSkip
		case skip > 0 || subSkip > 0:
			status, why = "partial", fmt.Sprintf("%d skipped, %d subtests skipped; first reason: %s", skip, subSkip, firstSkip)
		default:
			status = "pass"
		}
		if status == "fail" {
			code = 1
		}
		fmt.Printf("%s\t%s\t%d\t%d\t%d\t%s\t%d\n", name, status, pass, fail, skip, clean(why), subSkip)
	}
	return code
}

// hasPanic reports whether the output has a panic of the test process. t.Log
// lines are indented, so only a line that starts with "panic: " counts.
func hasPanic(output []string) bool {
	for _, o := range output {
		if strings.HasPrefix(o, "panic: ") {
			return true
		}
	}
	return false
}

// printSubtests lists the direct subtests of parent. A failure listed in known
// as "<package>\t<parent>/<case>" is fail-known.
func printSubtests(pkgs map[string]*pkgResult, parent string, known map[string]string) int {
	found, code := false, 0
	names := make([]string, 0, len(pkgs))
	for name := range pkgs {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		p := pkgs[name]
		pt, ok := p.tests[parent]
		if !ok {
			continue
		}
		found = true
		caseFailed := false
		for _, tn := range p.order {
			sub, ok := strings.CutPrefix(tn, parent+"/")
			if !ok || strings.Contains(sub, "/") {
				continue
			}
			t := p.tests[tn]
			status, why := t.action, ""
			switch t.action {
			case "skip":
				why = reason(t.output)
			case "fail":
				why, caseFailed = reason(t.output), true
				if _, ok := known[name+"\t"+tn]; ok {
					status = "fail-known"
				} else {
					code = 1
				}
			case "pass":
			default:
				status, why, caseFailed, code = "fail", "no final result", true, 1
			}
			fmt.Printf("%s\t%s\t%s\n", sub, status, clean(why))
		}
		// The parent itself failed, was skipped or did not finish, with no case to explain it.
		if pt.action != "pass" && !caseFailed {
			fmt.Fprintf(os.Stderr, "testsum: %s ended as %q with no failing case\n", parent, pt.action)
			code = 1
		}
	}
	if !found {
		fmt.Fprintf(os.Stderr, "testsum: test %s not found\n", parent)
		return 1
	}
	return code
}

// reason returns the first output line of the test that is not go test markup.
func reason(output []string) string {
	for _, o := range output {
		s := strings.TrimSpace(o)
		if s == "" || strings.HasPrefix(s, "=== ") || strings.HasPrefix(s, "--- ") {
			continue
		}
		return s
	}
	return "no message"
}

func firstBuildError(lines []string) string {
	for _, l := range lines {
		if s := strings.TrimSpace(l); s != "" && !strings.HasPrefix(s, "#") {
			return s
		}
	}
	return "no message"
}

func processError(output []string) string {
	for _, o := range output {
		if s := strings.TrimSpace(o); strings.HasPrefix(s, "panic:") || strings.Contains(s, "timed out") {
			return s
		}
	}
	for i := len(output) - 1; i >= 0; i-- {
		s := strings.TrimSpace(output[i])
		if s != "" && s != "FAIL" && !strings.HasPrefix(s, "FAIL\t") && !strings.HasPrefix(s, "exit status") &&
			!strings.HasPrefix(s, "--- ") && !strings.HasPrefix(s, "=== ") {
			return s
		}
	}
	return "no message"
}

func noTestsReason(output []string) string {
	for _, o := range output {
		if strings.Contains(o, "[no test files]") {
			return "[no test files]"
		}
		if strings.Contains(o, "[no tests to run]") {
			return "[no tests to run]"
		}
	}
	return "no test run"
}

func list(names []string) string {
	if len(names) > 5 {
		return strings.Join(names[:5], ", ") + fmt.Sprintf(" and %d more", len(names)-5)
	}
	return strings.Join(names, ", ")
}

func clean(s string) string {
	return strings.Join(strings.Fields(s), " ")
}
