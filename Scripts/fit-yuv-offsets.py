#!/usr/bin/env python3
"""Finds the rounding offsets that reproduce dwebp's YUV to RGB conversion.

    python3 Scripts/fit-yuv-offsets.py image.webp...

The coefficients are the BT.601 limited-range factors in 14-bit fixed point. For every observed
pixel, the offset of each channel must put the fixed-point sum into the bucket of the observed
8-bit value, so the script reports the range of offsets that agree with all pixels.
"""
import os
import subprocess
import sys
import tempfile

COEFFICIENTS = (19077, 26149, 6419, 13320, 33050)
files = sys.argv[1:]


def read_pam(path):
    data = open(path, 'rb').read()
    end = data.index(b'ENDHDR\n') + 7
    header = data[:end].decode()
    width = int(header.split('WIDTH ')[1].split()[0])
    height = int(header.split('HEIGHT ')[1].split()[0])
    return width, height, data[end:]


def mult(value, coefficient):
    return (value * coefficient) >> 8


bounds = {channel: [-10**9, 10**9] for channel in 'rgb'}
samples = 0
with tempfile.TemporaryDirectory() as work:
    for path in files:
        pam = os.path.join(work, 'out.pam')
        yuv = os.path.join(work, 'out.yuv')
        subprocess.run(['dwebp', '-quiet', '-nofancy', '-pam', path, '-o', pam], check=True)
        subprocess.run(['dwebp', '-quiet', '-yuv', path, '-o', yuv], check=True)
        width, height, rgba = read_pam(pam)
        planes = open(yuv, 'rb').read()
        chroma_width = (width + 1) // 2
        chroma_height = (height + 1) // 2
        u_plane = planes[width * height:width * height + chroma_width * chroma_height]
        v_plane = planes[width * height + chroma_width * chroma_height:]
        for row in range(0, height, 1):
            for column in range(0, width, 1):
                y = planes[row * width + column]
                u = u_plane[(row // 2) * chroma_width + column // 2]
                v = v_plane[(row // 2) * chroma_width + column // 2]
                pixel = rgba[(row * width + column) * 4:(row * width + column) * 4 + 3]
                sums = {
                    'r': mult(y, COEFFICIENTS[0]) + mult(v, COEFFICIENTS[1]),
                    'g': mult(y, COEFFICIENTS[0]) - mult(u, COEFFICIENTS[2]) - mult(v, COEFFICIENTS[3]),
                    'b': mult(y, COEFFICIENTS[0]) + mult(u, COEFFICIENTS[4]),
                }
                for channel, observed in zip('rgb', pixel):
                    total = sums[channel]
                    low, high = bounds[channel]
                    if observed == 0:
                        high = min(high, 63 - total)
                    elif observed == 255:
                        low = max(low, 255 * 64 - total)
                    else:
                        low = max(low, observed * 64 - total)
                        high = min(high, observed * 64 + 63 - total)
                    bounds[channel] = [low, high]
                samples += 1

print(f'{samples} pixels')
for channel, (low, high) in bounds.items():
    print(f'{channel}: offset in [{low}, {high}]')
