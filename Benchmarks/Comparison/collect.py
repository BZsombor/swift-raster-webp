#!/usr/bin/env python3
"""Turns the raw measurements of run-linux.sh or run-macos.sh into one JSON file.

    python3 -I Benchmarks/Comparison/collect.py <raw-directory> <environment-name> <output.json>

The libraries' names, languages and versions are listed below, so a new library needs an entry.
"""
import json
import os
import sys

LIBRARIES = {
    'swift-raster-webp': ('swift-raster-webp', 'Swift', None),
    'libwebp': ('libwebp', 'C', '1.6.0'),
    'imageio': ('ImageIO', 'Apple', None),
    'zenwebp': ('zenwebp', 'Rust', '0.4.6'),
    'image-webp': ('image-webp', 'Rust', '0.2.4'),
    'x-image-webp': ('x/image/webp', 'Go', 'v0.48.0'),
    'imagesharp': ('ImageSharp', 'C#', '3.1.12'),
    'twelvemonkeys': ('TwelveMonkeys', 'Java', '3.15.3'),
    'jwebp': ('jwebp', 'Java', '0.2.0'),
}

IMAGES = {
    'photo-q75.webp': 'Lossy, quality 75',
    'photo-q90.webp': 'Lossy, quality 90',
    'photo-alpha.webp': 'Lossy with alpha, quality 75',
    'photo-lossless.webp': 'Lossless',
    'small-q75.webp': 'Small lossy, quality 75',
    'small-lossless.webp': 'Small lossless',
}

GOLDEN = os.path.join(os.path.dirname(__file__), '..', '..', 'Tests', 'ConformanceTests', 'Golden',
                      'libwebp-test-data.tsv')


def parse_hash(text):
    """Reads a hexadecimal hash, which the golden file writes without leading zeros."""
    try:
        return int(text, 16)
    except ValueError:
        return None


def read_tsv(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding='utf8') as file:
        return [line.rstrip('\n').split('\t') for line in file if line.strip()]


def main(raw, environment_name, output):
    environment = {key: value for key, value in read_tsv(os.path.join(raw, 'environment.tsv'))}
    environment['name'] = environment_name
    golden = {row[0]: parse_hash(row[7]) for row in read_tsv(GOLDEN) if not row[0].startswith('#') and row[1] == 'ok'}

    present = [name for name in LIBRARIES if os.path.exists(os.path.join(raw, f'speed-{name}.jsonl'))]
    reference_hashes = {row[0]: parse_hash(row[1]) for row in read_tsv(os.path.join(raw, 'hash-images-libwebp.tsv'))}

    results = {'environment': environment, 'libraries': [], 'images': {}, 'speed': {}, 'memory': {},
               'conformance': {}, 'matches_libwebp': {}, 'size': {}}
    sizes = {row[0]: int(row[2]) - int(row[1]) for row in read_tsv(os.path.join(raw, 'size.tsv'))}

    for name in present:
        display, language, version = LIBRARIES[name]
        if version is None:
            version = environment.get(f'{name}-version', 'unknown')
        results['libraries'].append({'id': name, 'name': display, 'language': language, 'version': version})

        speed = {}
        with open(os.path.join(raw, f'speed-{name}.jsonl'), encoding='utf8') as file:
            for line in file:
                entry = json.loads(line)
                megapixels = entry['width'] * entry['height'] / 1e6
                results['images'].setdefault(entry['file'], {
                    'label': IMAGES.get(entry['file'], entry['file']),
                    'width': entry['width'], 'height': entry['height']})
                # Each image is measured in two rounds, and the faster median counts.
                previous = speed.get(entry['file'])
                if previous and previous['median_ms'] <= entry['median_ms']:
                    continue
                speed[entry['file']] = {
                    'median_ms': entry['median_ms'], 'best_ms': entry['best_ms'], 'runs': entry['runs'],
                    'megapixels_per_second': megapixels / (entry['median_ms'] / 1e3)}
        results['speed'][name] = speed

        memory = {}
        for image, decode_kb, read_kb in read_tsv(os.path.join(raw, f'memory-{name}.tsv')):
            info = results['images'].get(image)
            output_mb = info['width'] * info['height'] * 4 / 2**20 if info else 0
            peak_mb = int(decode_kb) / 1024
            baseline_mb = int(read_kb) / 1024
            memory[image] = {'peak_mb': peak_mb, 'baseline_mb': baseline_mb, 'output_mb': output_mb,
                             'extra_mb': peak_mb - baseline_mb - output_mb}
        results['memory'][name] = memory

        hashes = read_tsv(os.path.join(raw, f'hash-corpus-{name}.tsv'))
        matching = sum(1 for row in hashes if golden.get(row[0]) == parse_hash(row[1]))
        errors = sum(1 for row in hashes if row[1].startswith('ERROR'))
        results['conformance'][name] = {'matching': matching, 'errors': errors, 'total': len(golden)}

        image_hashes = {row[0]: parse_hash(row[1]) for row in read_tsv(os.path.join(raw, f'hash-images-{name}.tsv'))}
        results['matches_libwebp'][name] = {
            image: image_hashes.get(image) == reference_hashes.get(image) for image in reference_hashes}

        if name in sizes:
            results['size'][name] = sizes[name]

    with open(output, 'w', encoding='utf8') as file:
        json.dump(results, file, indent=2)
        file.write('\n')


if __name__ == '__main__':
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
