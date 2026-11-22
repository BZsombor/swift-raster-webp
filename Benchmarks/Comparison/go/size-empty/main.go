// The baseline for the binary size: reads its argument like size-decode, without decoding.
package main

import (
	"fmt"
	"os"
)

func main() {
	argument := ""
	if len(os.Args) > 1 {
		argument = os.Args[1]
	}
	fmt.Println(len(argument))
}
