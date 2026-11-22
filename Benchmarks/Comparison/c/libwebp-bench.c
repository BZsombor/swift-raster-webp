// The libwebp measuring program of Scripts/compare-decoders.sh. It follows the same command-line
// contract as Benchmarks/Comparison/swift/Sources/BenchSupport/Bench.swift.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <webp/decode.h>

static uint8_t *read_file(const char *path, size_t *size) {
    FILE *file = fopen(path, "rb");
    if (!file) return NULL;
    fseek(file, 0, SEEK_END);
    *size = (size_t)ftell(file);
    fseek(file, 0, SEEK_SET);
    uint8_t *bytes = malloc(*size);
    if (fread(bytes, 1, *size, file) != *size) { free(bytes); bytes = NULL; }
    fclose(file);
    return bytes;
}

static const char *base_name(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

static double now_ms(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (double)time.tv_sec * 1e3 + (double)time.tv_nsec * 1e-6;
}

static int compare(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

// Decodes into straight RGBA, libwebp's usual output, and frees it.
static int decode(const uint8_t *bytes, size_t size, int *width, int *height) {
    uint8_t *pixels = WebPDecodeRGBA(bytes, size, width, height);
    if (!pixels) return 0;
    WebPFree(pixels);
    return 1;
}

int main(int argc, char **argv) {
    if (argc >= 5 && strcmp(argv[1], "speed") == 0) {
        int warmup = atoi(argv[2]), runs = atoi(argv[3]);
        double *times = malloc(sizeof(double) * (size_t)runs);
        for (int index = 4; index < argc; index++) {
            size_t size;
            uint8_t *bytes = read_file(argv[index], &size);
            int width = 0, height = 0;
            if (!bytes) return 1;
            for (int run = 0; run < warmup; run++) decode(bytes, size, &width, &height);
            for (int run = 0; run < runs; run++) {
                double start = now_ms();
                if (!decode(bytes, size, &width, &height)) return 1;
                times[run] = now_ms() - start;
            }
            qsort(times, (size_t)runs, sizeof(double), compare);
            double median = runs % 2 ? times[runs / 2] : (times[runs / 2 - 1] + times[runs / 2]) / 2;
            printf("{\"file\":\"%s\",\"width\":%d,\"height\":%d,\"median_ms\":%.6f,\"best_ms\":%.6f,\"runs\":%d}\n",
                   base_name(argv[index]), width, height, median, times[0], runs);
            free(bytes);
        }
        free(times);
        return 0;
    }
    if (argc >= 2 && strcmp(argv[1], "hash") == 0) {
        for (int index = 2; index < argc; index++) {
            size_t size;
            int width, height;
            uint8_t *bytes = read_file(argv[index], &size);
            uint8_t *pixels = bytes ? WebPDecodeRGBA(bytes, size, &width, &height) : NULL;
            if (!pixels) {
                printf("%s\tERROR decoding failed\n", base_name(argv[index]));
            } else {
                uint64_t hash = 0xcbf29ce484222325ULL;
                for (size_t offset = 0; offset < (size_t)width * (size_t)height * 4; offset++)
                    hash = (hash ^ pixels[offset]) * 0x100000001b3ULL;
                printf("%s\t%016llx\n", base_name(argv[index]), (unsigned long long)hash);
                WebPFree(pixels);
            }
            free(bytes);
        }
        return 0;
    }
    if (argc == 3 && (strcmp(argv[1], "decode") == 0 || strcmp(argv[1], "read") == 0)) {
        size_t size;
        int width = 0, height = 0;
        uint8_t *bytes = read_file(argv[2], &size);
        if (!bytes) return 1;
        if (argv[1][0] == 'd' && !decode(bytes, size, &width, &height)) return 1;
        printf("%d\n", argv[1][0] == 'd' ? width : (int)size);
        free(bytes);
        return 0;
    }
    fprintf(stderr, "usage: speed|hash|decode|read\n");
    return 2;
}
