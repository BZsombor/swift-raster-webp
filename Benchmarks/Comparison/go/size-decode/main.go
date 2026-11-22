// The same program as size-empty, plus decoding, so the size difference is the decoder.
package main

import (
	"fmt"
	"os"
	"strings"

	"golang.org/x/image/webp"
)

func main() {
	argument := ""
	if len(os.Args) > 1 {
		argument = os.Args[1]
	}
	fmt.Println(len(argument))
	if img, err := webp.Decode(strings.NewReader(argument)); err == nil {
		fmt.Println(img.Bounds().Dx())
	}
}
