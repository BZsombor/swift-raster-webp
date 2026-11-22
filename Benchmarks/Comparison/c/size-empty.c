// The baseline for the binary size: reads its argument like size-decode, without decoding.
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    printf("%zu\n", argc > 1 ? strlen(argv[1]) : 0);
    return 0;
}
