package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Fprintln(os.Stderr, "spank has been split into spankd, spank-sensor-helper, and badapple")
	fmt.Fprintln(os.Stderr, "build and run the new binaries under cmd/")
	os.Exit(1)
}
