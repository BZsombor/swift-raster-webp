// Reports how libwebp's WebPAnimDecoder renders an animation, as the reference for the
// animation conformance tests. It is a test oracle and is never part of the package.
//
// usage: anim-oracle [-premultiplied] <file> [<dump-file>]
//        anim-oracle -speed <runs> <file>
//
// Prints one line per frame: the timestamp at which the frame ends, in milliseconds, and the
// 64-bit FNV-1a hash of the canvas in RGBA order. With a dump file, it also writes the canvas
// of every frame to it, one after another. The speed mode prints the shortest time, in
// milliseconds, in which one thread decodes every frame.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <webp/demux.h>

static uint8_t *read_file(const char *path, size_t *size) {
    FILE *file = fopen(path, "rb");
    if (!file) return NULL;
    fseek(file, 0, SEEK_END);
    *size = (size_t)ftell(file);
    fseek(file, 0, SEEK_SET);
    uint8_t *bytes = malloc(*size ? *size : 1);
    if (fread(bytes, 1, *size, file) != *size) {
        free(bytes);
        bytes = NULL;
    }
    fclose(file);
    return bytes;
}

static uint64_t fnv1a(const uint8_t *bytes, size_t count) {
    uint64_t hash = 0xCBF29CE484222325ull;
    for (size_t index = 0; index < count; index++) hash = (hash ^ bytes[index]) * 0x100000001B3ull;
    return hash;
}

static double now_ms(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (double)time.tv_sec * 1e3 + (double)time.tv_nsec * 1e-6;
}

// Decodes every frame of an animation in straight RGBA, as WebPAnimDecoder does by default.
static int decode_all(const uint8_t *bytes, size_t size) {
    WebPAnimDecoderOptions options;
    WebPAnimDecoderOptionsInit(&options);
    options.color_mode = MODE_RGBA;
    options.use_threads = 0;
    WebPData data = {bytes, size};
    WebPAnimDecoder *decoder = WebPAnimDecoderNew(&data, &options);
    if (!decoder) return 0;
    while (WebPAnimDecoderHasMoreFrames(decoder)) {
        uint8_t *canvas;
        int timestamp;
        if (!WebPAnimDecoderGetNext(decoder, &canvas, &timestamp)) return 0;
    }
    WebPAnimDecoderDelete(decoder);
    return 1;
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "-speed") == 0) {
        size_t size;
        uint8_t *bytes = read_file(argv[3], &size);
        if (!bytes) return 1;
        double best = 1e300;
        for (int run = atoi(argv[2]); run > 0; run--) {
            double start = now_ms();
            if (!decode_all(bytes, size)) return 1;
            double elapsed = now_ms() - start;
            if (elapsed < best) best = elapsed;
        }
        printf("%.3f\n", best);
        free(bytes);
        return 0;
    }

    int argument = 1;
    int premultiplied = argc > argument && strcmp(argv[argument], "-premultiplied") == 0;
    argument += premultiplied;
    if (argc - argument < 1 || argc - argument > 2) {
        fprintf(stderr, "usage: anim-oracle [-premultiplied] <file> [<dump-file>]\n");
        return 2;
    }

    size_t size;
    uint8_t *bytes = read_file(argv[argument], &size);
    if (!bytes) return 1;
    FILE *dump = argc - argument == 2 ? fopen(argv[argument + 1], "wb") : NULL;

    WebPAnimDecoderOptions options;
    WebPAnimDecoderOptionsInit(&options);
    options.color_mode = premultiplied ? MODE_rgbA : MODE_RGBA;
    options.use_threads = 0;

    WebPData data = {bytes, size};
    WebPAnimDecoder *decoder = WebPAnimDecoderNew(&data, &options);
    if (!decoder) return 1;
    WebPAnimInfo info;
    WebPAnimDecoderGetInfo(decoder, &info);
    size_t canvas_size = (size_t)info.canvas_width * info.canvas_height * 4;

    while (WebPAnimDecoderHasMoreFrames(decoder)) {
        uint8_t *canvas;
        int timestamp;
        if (!WebPAnimDecoderGetNext(decoder, &canvas, &timestamp)) return 1;
        printf("%d\t%016llx\n", timestamp, (unsigned long long)fnv1a(canvas, canvas_size));
        if (dump && fwrite(canvas, 1, canvas_size, dump) != canvas_size) return 1;
    }

    WebPAnimDecoderDelete(decoder);
    if (dump) fclose(dump);
    free(bytes);
    return 0;
}
