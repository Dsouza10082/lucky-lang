// Minimal program used by targets.sh to check linking and running each
// baseline target.
package main

import (
	"fmt"

	"baselinetestdata/hellolib"
)

func main() {
	fmt.Println(hellolib.Message())
}
