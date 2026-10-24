// Package hellolib is compiled without linking by targets.sh, so that each
// target's compilation is recorded separately from its link.
package hellolib

import (
	"fmt"
	"runtime"
)

// Message identifies the target the program was compiled for.
func Message() string {
	return fmt.Sprintf("hello %s/%s", runtime.GOOS, runtime.GOARCH)
}
