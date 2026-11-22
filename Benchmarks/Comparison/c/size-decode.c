// The same program as size-empty, plus decoding, so the size difference is the decoder.
#include <stdio.h>
#include <string.h>
#include <webp/decode.h>

int main(int argc, char **argv) {
    size_t size = argc > 1 ? strlen(argv[1]) : 0;
    printf("%zu\n", size);
    int width, height;
    uint8_t *pixels = WebPDecodeRGBA((const uint8_t *)(argc > 1 ? argv[1] : ""), size, &width, &height);
    if (pixels) { printf("%d\n", width); WebPFree(pixels); }
    return 0;
}
