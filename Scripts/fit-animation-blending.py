#!/usr/bin/env python3
"""Checks the integer alpha-blending formula against libwebp's WebPAnimDecoder.

    python3 Scripts/fit-animation-blending.py [rounds]

Every round builds a two-frame, 256 x 256 animation. The first frame replaces the canvas and has
an alpha of x in column x; the second blends over it with an alpha of y in row y, so each round
covers all 65,536 pairs of source and destination alpha, with random colors. The script compares
the oracle's second canvas with the formula of docs/adr/0006-animation-compositing.md and reports
every pair that disagrees. It needs cwebp, webpmux, a C compiler and libwebpdemux with pkg-config.
"""
import os
import random
import subprocess
import sys
import tempfile

SIZE = 256
rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 16
oracle_source = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Tools', 'Oracle', 'anim-oracle.c')


def blend(source, destination):
    source_alpha, destination_alpha = source[3], destination[3]
    if source_alpha == 255:
        return tuple(source)
    if source_alpha == 0:
        return tuple(destination)
    destination_factor = (destination_alpha * (256 - source_alpha)) >> 8
    alpha = source_alpha + destination_factor
    scale = (1 << 24) // alpha
    color = [((source[c] * source_alpha + destination[c] * destination_factor) * scale) >> 24 for c in range(3)]
    return tuple(color + [alpha])


def write_pam(path, pixels):
    header = f'P7\nWIDTH {SIZE}\nHEIGHT {SIZE}\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n'
    with open(path, 'wb') as file:
        file.write(header.encode() + bytes(pixels))


with tempfile.TemporaryDirectory() as work:
    flags = subprocess.run(['pkg-config', '--cflags', '--libs', 'libwebpdemux'], check=True,
                           capture_output=True, text=True).stdout.split()
    oracle = os.path.join(work, 'anim-oracle')
    subprocess.run(['cc', '-O2', '-o', oracle, oracle_source] + flags, check=True)

    mismatches = 0
    count = SIZE * SIZE * 4
    for round_index in range(rounds):
        generator = random.Random(round_index)
        destination = bytearray()
        source = bytearray()
        for y in range(SIZE):
            for x in range(SIZE):
                destination += bytes([generator.randrange(256) for _ in range(3)] + [x])
                source += bytes([generator.randrange(256) for _ in range(3)] + [y])

        paths = {name: os.path.join(work, name) for name in ('d.pam', 's.pam', 'd.webp', 's.webp', 'a.webp', 'a.raw')}
        write_pam(paths['d.pam'], destination)
        write_pam(paths['s.pam'], source)
        for name in ('d', 's'):
            subprocess.run(['cwebp', '-quiet', '-lossless', '-exact', paths[name + '.pam'], '-o', paths[name + '.webp']],
                           check=True)
        subprocess.run(['webpmux', '-frame', paths['d.webp'], '+100+0+0+0-b', '-frame', paths['s.webp'],
                        '+100+0+0+0+b', '-o', paths['a.webp']], check=True, capture_output=True)
        subprocess.run([oracle, paths['a.webp'], paths['a.raw']], check=True, capture_output=True)

        canvases = open(paths['a.raw'], 'rb').read()
        if canvases[:count] != destination:
            sys.exit('The first frame does not replace the canvas exactly.')
        expected = canvases[count:]
        for index in range(0, count, 4):
            if blend(source[index:index + 4], destination[index:index + 4]) != tuple(expected[index:index + 4]):
                mismatches += 1
                print('mismatch: source', tuple(source[index:index + 4]), 'destination',
                      tuple(destination[index:index + 4]), 'libwebp', tuple(expected[index:index + 4]))

print(f'Compared {rounds * SIZE * SIZE} blended pixels, found {mismatches} mismatches')
sys.exit(1 if mismatches else 0)
