// The golang.org/x/image/webp measuring program of Scripts/compare-decoders.sh. It follows the
// command-line contract of Benchmarks/Comparison/swift/Sources/BenchSupport/Bench.swift.
//
// Lossy images decode to YCbCr, so the measured time includes the conversion to RGBA that
// image/draw offers. That RGBA is premultiplied, so the hashes use straight alpha instead.
package main

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"time"

	"golang.org/x/image/webp"
)

func decode(data []byte) (int, int, error) {
	img, err := webp.Decode(bytes.NewReader(data))
	if err != nil {
		return 0, 0, err
	}
	bounds := img.Bounds()
	if _, ok := img.(*image.NRGBA); !ok {
		rgba := image.NewRGBA(bounds)
		draw.Draw(rgba, bounds, img, bounds.Min, draw.Src)
	}
	return bounds.Dx(), bounds.Dy(), nil
}

func straightRGBA(data []byte) ([]byte, error) {
	img, err := webp.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	if nrgba, ok := img.(*image.NRGBA); ok {
		return nrgba.Pix, nil
	}
	bounds := img.Bounds()
	pixels := make([]byte, 0, bounds.Dx()*bounds.Dy()*4)
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			c := color.NRGBAModel.Convert(img.At(x, y)).(color.NRGBA)
			pixels = append(pixels, c.R, c.G, c.B, c.A)
		}
	}
	return pixels, nil
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}

func main() {
	args := os.Args[1:]
	switch {
	case len(args) >= 4 && args[0] == "speed":
		warmup, _ := strconv.Atoi(args[1])
		runs, _ := strconv.Atoi(args[2])
		for _, path := range args[3:] {
			data, err := os.ReadFile(path)
			if err != nil {
				fail(err)
			}
			width, height := 0, 0
			for i := 0; i < warmup; i++ {
				if width, height, err = decode(data); err != nil {
					fail(err)
				}
			}
			times := make([]float64, runs)
			for i := range times {
				start := time.Now()
				if width, height, err = decode(data); err != nil {
					fail(err)
				}
				times[i] = float64(time.Since(start).Nanoseconds()) / 1e6
			}
			sort.Float64s(times)
			median := times[runs/2]
			if runs%2 == 0 {
				median = (times[runs/2-1] + times[runs/2]) / 2
			}
			fmt.Printf("{\"file\":%q,\"width\":%d,\"height\":%d,\"median_ms\":%g,\"best_ms\":%g,\"runs\":%d}\n",
				filepath.Base(path), width, height, median, times[0], runs)
		}
	case len(args) >= 1 && args[0] == "hash":
		for _, path := range args[1:] {
			data, err := os.ReadFile(path)
			var pixels []byte
			if err == nil {
				pixels, err = straightRGBA(data)
			}
			if err != nil {
				fmt.Printf("%s\tERROR %v\n", filepath.Base(path), err)
				continue
			}
			hash := uint64(0xcbf29ce484222325)
			for _, b := range pixels {
				hash = (hash ^ uint64(b)) * 0x100000001b3
			}
			fmt.Printf("%s\t%016x\n", filepath.Base(path), hash)
		}
	case len(args) == 2 && (args[0] == "decode" || args[0] == "read"):
		data, err := os.ReadFile(args[1])
		if err != nil {
			fail(err)
		}
		if args[0] == "read" {
			fmt.Println(len(data))
			return
		}
		width, _, err := decode(data)
		if err != nil {
			fail(err)
		}
		fmt.Println(width)
	default:
		fail(fmt.Errorf("usage: speed|hash|decode|read"))
	}
}
