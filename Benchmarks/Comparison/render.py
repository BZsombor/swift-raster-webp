#!/usr/bin/env python3
"""Draws the comparison charts and writes the comparison page from collected results.

    python3 -I Benchmarks/Comparison/render.py <linux.json> [<macos.json>]

Writes docs/performance/charts/*.svg, in a light and a dark variant each, and
docs/performance/comparison.md. Both are generated, so edit this script rather than the output.
"""
import html
import json
import os
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', '..'))
CHARTS = os.path.join(ROOT, 'docs', 'performance', 'charts')
PAGE = os.path.join(ROOT, 'docs', 'performance', 'comparison.md')
OURS = 'swift-raster-webp'

THEMES = {
    'light': {'text': '#1f2328', 'muted': '#59636e', 'ours': '#0969da', 'others': '#afb8c1', 'grid': '#d1d9e0'},
    'dark': {'text': '#f0f6fc', 'muted': '#9198a1', 'ours': '#4493f8', 'others': '#656c76', 'grid': '#3d444d'},
}

LARGE_IMAGES = ['photo-q75.webp', 'photo-q90.webp', 'photo-alpha.webp', 'photo-lossless.webp']
SMALL_IMAGES = ['small-q75.webp', 'small-lossless.webp']


def bar_chart(title, subtitle, rows, theme, footnote=None):
    """Draws horizontal bars. Each row is (name, detail, value or None, text, is_ours)."""
    colors = THEMES[theme]
    width, label_width, value_width, row_height, top = 760, 230, 110, 30, 64
    bar_area = width - label_width - value_width
    largest = max((row[2] for row in rows if row[2] is not None), default=1) or 1
    height = top + row_height * len(rows) + (34 if footnote else 14)

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" aria-label="{html.escape(title)}">',
        f'<title>{html.escape(title)}</title>',
        '<style>text{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}</style>',
        f'<text x="0" y="22" font-size="17" font-weight="600" fill="{colors["text"]}">{html.escape(title)}</text>',
        f'<text x="0" y="44" font-size="13" fill="{colors["muted"]}">{html.escape(subtitle)}</text>',
    ]
    for index, (name, detail, value, text, is_ours) in enumerate(rows):
        y = top + index * row_height
        weight = '600' if is_ours else '400'
        parts.append(
            f'<text x="0" y="{y + 19}" font-size="14" font-weight="{weight}" fill="{colors["text"]}">'
            f'{html.escape(name)} <tspan fill="{colors["muted"]}" font-weight="400">{html.escape(detail)}</tspan></text>')
        if value is None:
            parts.append(f'<text x="{label_width}" y="{y + 19}" font-size="13" fill="{colors["muted"]}">'
                         f'{html.escape(text)}</text>')
            continue
        bar = max(2.0, bar_area * value / largest)
        color = colors['ours'] if is_ours else colors['others']
        parts.append(f'<rect x="{label_width}" y="{y + 6}" width="{bar:.1f}" height="18" rx="3" fill="{color}"/>')
        parts.append(f'<text x="{label_width + bar + 8:.1f}" y="{y + 19}" font-size="13" '
                     f'font-weight="{weight}" fill="{colors["text"]}">{html.escape(text)}</text>')
    if footnote:
        parts.append(f'<text x="0" y="{height - 10}" font-size="12" fill="{colors["muted"]}">'
                     f'{html.escape(footnote)}</text>')
    parts.append('</svg>')
    return '\n'.join(parts) + '\n'


def write_chart(name, title, subtitle, rows, footnote=None):
    os.makedirs(CHARTS, exist_ok=True)
    for theme in THEMES:
        with open(os.path.join(CHARTS, f'{name}-{theme}.svg'), 'w', encoding='utf8') as file:
            file.write(bar_chart(title, subtitle, rows, theme, footnote))


def picture(name, alt):
    return (f'<picture>\n  <source media="(prefers-color-scheme: dark)" srcset="charts/{name}-dark.svg">\n'
            f'  <img alt="{html.escape(alt)}" src="charts/{name}-light.svg">\n</picture>')


def libraries_by_id(results):
    return {library['id']: library for library in results['libraries']}


def ranked(results, values, higher_is_better):
    """Orders the libraries best first. Values maps an id to a number or None."""
    names = libraries_by_id(results)
    known = [(name, value) for name, value in values.items() if value is not None]
    known.sort(key=lambda item: -item[1] if higher_is_better else item[1])
    missing = [(name, None) for name, value in values.items() if value is None]
    return [(names[name], value) for name, value in known + missing]


def charts_for(results, prefix):
    """Draws every chart of one environment and returns their names, titles and alt texts."""
    drawn = []
    names = libraries_by_id(results)
    environment = results['environment']
    machine = environment.get('machine', environment.get('architecture', ''))

    def differs(library, image):
        return not results['matches_libwebp'].get(library, {}).get(image, True)

    for image in LARGE_IMAGES + SMALL_IMAGES:
        if image not in results['images']:
            continue
        info = results['images'][image]
        small = image in SMALL_IMAGES
        values = {}
        for library in names:
            entry = results['speed'].get(library, {}).get(image)
            values[library] = (entry['median_ms'] * 1000 if small else entry['megapixels_per_second']) if entry else None
        rows, any_different = [], False
        for library, value in ranked(results, values, higher_is_better=not small):
            mark = ' †' if differs(library['id'], image) else ''
            any_different = any_different or bool(mark)
            text = 'not supported' if value is None else (f'{value:,.0f} µs' if small else f'{value:,.0f} Mpx/s')
            rows.append((library['name'] + mark, library['language'], value, text, library['id'] == OURS))
        size = f'{info["width"]} × {info["height"]}'
        subtitle = (f'Time per {size} image, shorter is better' if small
                    else f'Megapixels per second on a {size} photo, longer is better') + f' · {machine}'
        name = f'{prefix}speed-{image.removesuffix(".webp")}'
        title = f'{info["label"]}: decoding {"time" if small else "speed"}'
        write_chart(name, title, subtitle, rows,
                    '† Its pixels differ from libwebp\'s on this image.' if any_different else None)
        drawn.append((name, title))

    for image in ['photo-q75.webp', 'photo-lossless.webp']:
        values = {library: results['memory'].get(library, {}).get(image, {}).get('extra_mb') for library in names}
        if all(value is None for value in values.values()):
            continue
        rows = [(library['name'], library['language'], max(value, 0) if value is not None else None,
                 'not measured' if value is None else f'{max(value, 0):,.1f} MB', library['id'] == OURS)
                for library, value in ranked(results, values, higher_is_better=False)]
        label = results['images'][image]['label']
        name = f'{prefix}memory-{image.removesuffix(".webp")}'
        title = f'{label}: memory beyond the input and the pixels'
        write_chart(name, title, f'Extra peak memory while decoding the 24 Mpx photo, shorter is better · {machine}',
                    rows, 'Garbage-collected runtimes (Go, C#, Java) are measured with their default settings.')
        drawn.append((name, title))

    if results['size']:
        values = {library: results['size'].get(library) for library in names if library in results['size']}
        rows = [(library['name'], library['language'], value / 1024, f'{value / 1024:,.0f} KB', library['id'] == OURS)
                for library, value in ranked(results, values, higher_is_better=False)]
        name = f'{prefix}binary-size'
        title = 'Binary size added by the decoder'
        write_chart(name, title, f'Static, stripped programs, shorter is better · {machine}', rows,
                    'Only natively compiled libraries. Go includes its image packages.')
        drawn.append((name, title))

    values = {library: results['conformance'][library]['matching'] for library in names}
    total = next(iter(results['conformance'].values()))['total']
    rows = [(library['name'], library['language'], value, f'{value} of {total}', library['id'] == OURS)
            for library, value in ranked(results, values, higher_is_better=True)]
    name = f'{prefix}conformance'
    title = 'Files decoded exactly like libwebp'
    write_chart(name, title, f'Files of the libwebp test corpus with identical RGBA pixels, longer is better', rows,
                'Differences come from a different lossy color conversion, or from premultiplied alpha.')
    drawn.append((name, title))
    return drawn


def number_table(results):
    """The exact numbers behind the charts, as Markdown."""
    names = libraries_by_id(results)
    images = [image for image in LARGE_IMAGES + SMALL_IMAGES if image in results['images']]
    header = '| Library | ' + ' | '.join(results['images'][image]['label'] for image in images) + ' |'
    lines = [header, '|---|' + '---:|' * len(images)]
    for library in names.values():
        cells = []
        for image in images:
            entry = results['speed'].get(library['id'], {}).get(image)
            if not entry:
                cells.append('–')
            elif image in SMALL_IMAGES:
                cells.append(f'{entry["median_ms"] * 1000:,.0f} µs')
            else:
                cells.append(f'{entry["megapixels_per_second"]:,.1f} Mpx/s')
        lines.append(f"| {library['name']} {library['version']} | " + " | ".join(cells) + " |")
    lines += ['', '| Library | Peak memory, lossy | Extra, lossy | Peak memory, lossless | Extra, lossless | '
              'Binary size added | Corpus files like libwebp |', '|---|---:|---:|---:|---:|---:|---:|']
    for library in names.values():
        memory = results['memory'].get(library['id'], {})
        cells = []
        for image in ['photo-q75.webp', 'photo-lossless.webp']:
            entry = memory.get(image)
            cells += ([f'{entry["peak_mb"]:,.0f} MB', f'{max(entry["extra_mb"], 0):,.1f} MB'] if entry else ['–', '–'])
        size = results['size'].get(library['id'])
        cells.append(f'{size / 1024:,.0f} KB' if size else '–')
        conformance = results['conformance'][library['id']]
        cells.append(f'{conformance["matching"]} of {conformance["total"]}')
        lines.append(f'| {library["name"]} | ' + ' | '.join(cells) + ' |')
    return '\n'.join(lines)


def environment_line(results):
    environment = results['environment']
    parts = [environment.get('machine', ''), environment.get('os', ''), environment.get('architecture', '')]
    return ', '.join(part for part in parts if part) + f', measured on {environment.get("date", "")}'


def main(linux_path, macos_path=None):
    with open(linux_path, encoding='utf8') as file:
        linux = json.load(file)
    macos = None
    if macos_path:
        with open(macos_path, encoding='utf8') as file:
            macos = json.load(file)

    linux_charts = dict(charts_for(linux, ''))
    macos_charts = dict(charts_for(macos, 'macos-')) if macos else {}

    def section(charts, names):
        return '\n\n'.join(picture(name, charts[name]) for name in names if name in charts)

    environment = linux['environment']
    libraries = '\n'.join(
        f'| {library["name"]} | {library["language"]} | {library["version"]} |' for library in linux['libraries'])
    page = f"""# Decoding compared with other WebP decoders

<!-- Generated by Benchmarks/Comparison/render.py from the files in results/. Edit the script, not this page. -->

swift-raster-webp is compared with every independent WebP decoder we could find in other languages: libwebp, the reference in C, two Rust crates, Go's official package, ImageSharp for .NET and two Java libraries. Wrappers around libwebp, such as Pillow or sharp, are left out, because they would measure libwebp again.

**Environment:** {environment_line(linux)}. Every library runs on one thread, in the same Linux container, with the same images.

| Library | Language | Version |
|---|---|---|
{libraries}

## Speed on a large photo

{section(linux_charts, ['speed-photo-q75', 'speed-photo-q90', 'speed-photo-alpha', 'speed-photo-lossless'])}

## Time per small image

Small images show the fixed cost of every decode, which matters for icons and thumbnails.

{section(linux_charts, ['speed-small-q75', 'speed-small-lossless'])}

## Memory

The extra memory is the peak memory of one decode, minus the same program's peak when it only reads the file, minus the decoded pixels themselves.

{section(linux_charts, ['memory-photo-q75', 'memory-photo-lossless'])}

## Binary size and correctness

{section(linux_charts, ['binary-size', 'conformance'])}

<details>
<summary>All numbers</summary>

{number_table(linux)}

Tools: {environment.get('swift', '')}; {environment.get('cc', '')}; {environment.get('rust', '')}; {environment.get('go', '')}; .NET {environment.get('dotnet', '')}; {environment.get('java', '')}.

</details>
"""
    if macos:
        page += f"""
## On macOS, with Apple's ImageIO

Apple platforms decode WebP natively through ImageIO, so Swift developers can also compare with that. This run is separate from the Linux one, and the two are not mixed.

**Environment:** {environment_line(macos)}.

{section(macos_charts, ['macos-speed-photo-q75', 'macos-speed-photo-lossless', 'macos-speed-small-q75'])}

<details>
<summary>All numbers on macOS</summary>

{number_table(macos)}

</details>
"""
    page += """
## How it was measured

- **The images** come from `bryce.webp` of the libwebp test corpus, an 11158 × 2156 photo, encoded again with `cwebp` 1.6.0: at quality 75 and 90, with an alpha ramp, and lossless. The small images are a 256 × 256 crop of the same photo.
- **Each speed** is the median of 20 decodes from memory after 3 warm-up decodes, or of 1,000 decodes after 100 warm-ups for the small images. Every library is measured in two rounds, one after the other for all libraries, and the faster round counts, so a short disturbance of the machine cannot distort one library. The output buffer's allocation counts, the file reading does not.
- **Everyone does the same work:** WebP bytes to 8-bit pixels. swift-raster-webp, libwebp, zenwebp and ImageSharp write RGBA. image-webp writes RGB for opaque images, so its time includes expanding that to RGBA. Go returns YCbCr for lossy images, so its time includes the conversion to RGBA with `image/draw`. TwelveMonkeys returns a `BufferedImage`, and jwebp ARGB integers.
- **Pixels are checked** against libwebp. A dagger (†) marks a library whose pixels differ on that image. Go, TwelveMonkeys and jwebp convert lossy images to RGB differently from libwebp. ImageIO returns premultiplied alpha, which changes translucent pixels.
- **ImageSharp is measured at 3.1.12,** the last version that builds without a Six Labors license key. Later versions need a commercial key at build time. NuGet reports known vulnerabilities in 3.1.12, which do not matter here, because it only decodes the test images and the libwebp corpus.
- **Memory** is the peak resident memory of a separate process that decodes once, measured with `time`.
- **Binary size** is the difference between two static, stripped programs: one that only reads its argument and one that also decodes it.

## Reproducing the measurements

The script needs Docker, and on macOS also Swift and Homebrew's `webp`. Everything is built in a container or a temporary directory, which is removed at the end.

```bash
Scripts/fetch-corpus.sh
Scripts/compare-decoders.sh
```
"""
    with open(PAGE, 'w', encoding='utf8') as file:
        file.write(page)


if __name__ == '__main__':
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    main(*sys.argv[1:])
