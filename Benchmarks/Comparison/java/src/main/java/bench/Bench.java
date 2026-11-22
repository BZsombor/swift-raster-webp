// The Java measuring program of Scripts/compare-decoders.sh, for TwelveMonkeys and jwebp. It follows
// the command-line contract of Benchmarks/Comparison/swift/Sources/BenchSupport/Bench.swift, after
// the library name:
//
//     java -cp ... bench.Bench <twelvemonkeys|jwebp> <speed|hash|decode|read> ...
//
// TwelveMonkeys decodes through ImageIO into a BufferedImage, and jwebp into ARGB integers with
// straight alpha. Both are their libraries' usual outputs.
package bench;

import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.IntBuffer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Locale;
import javax.imageio.ImageIO;
import org.glavo.webp.WebPImage;

public final class Bench {
    private interface Decoder {
        /** Decodes into the library's usual output and returns {width, height}. */
        int[] decode(byte[] bytes) throws Exception;

        /** Decodes into ARGB integers with straight alpha. */
        int[] argb(byte[] bytes) throws Exception;
    }

    private static final Decoder TWELVE_MONKEYS = new Decoder() {
        private BufferedImage read(byte[] bytes) throws IOException {
            BufferedImage image = ImageIO.read(new ByteArrayInputStream(bytes));
            if (image == null) throw new IOException("no WebP reader");
            return image;
        }

        public int[] decode(byte[] bytes) throws Exception {
            BufferedImage image = read(bytes);
            return new int[] {image.getWidth(), image.getHeight()};
        }

        public int[] argb(byte[] bytes) throws Exception {
            BufferedImage image = read(bytes);
            return image.getRGB(0, 0, image.getWidth(), image.getHeight(), null, 0, image.getWidth());
        }
    };

    private static final Decoder JWEBP = new Decoder() {
        public int[] decode(byte[] bytes) throws Exception {
            WebPImage image = WebPImage.read(new ByteArrayInputStream(bytes));
            if (image.getFirstFrame().getArgbPixels().remaining() == 0) throw new IOException("empty");
            return new int[] {image.getWidth(), image.getHeight()};
        }

        public int[] argb(byte[] bytes) throws Exception {
            IntBuffer pixels = WebPImage.read(new ByteArrayInputStream(bytes)).getFirstFrame().getArgbPixels();
            int[] values = new int[pixels.remaining()];
            pixels.get(values);
            return values;
        }
    };

    public static void main(String[] args) throws Exception {
        ImageIO.scanForPlugins();
        ImageIO.setUseCache(false);
        if (args.length < 2) usage();
        Decoder decoder = switch (args[0]) {
            case "twelvemonkeys" -> TWELVE_MONKEYS;
            case "jwebp" -> JWEBP;
            default -> null;
        };
        if (decoder == null) usage();
        String[] rest = Arrays.copyOfRange(args, 1, args.length);
        switch (rest[0]) {
            case "speed" -> speed(decoder, Integer.parseInt(rest[1]), Integer.parseInt(rest[2]),
                    Arrays.copyOfRange(rest, 3, rest.length));
            case "hash" -> {
                for (int index = 1; index < rest.length; index++) {
                    String name = Path.of(rest[index]).getFileName().toString();
                    try {
                        long hash = 0xcbf29ce484222325L;
                        for (int pixel : decoder.argb(Files.readAllBytes(Path.of(rest[index])))) {
                            for (int shift : new int[] {16, 8, 0, 24}) {
                                hash = (hash ^ ((pixel >>> shift) & 0xFF)) * 0x100000001b3L;
                            }
                        }
                        System.out.printf("%s\t%016x%n", name, hash);
                    } catch (Exception error) {
                        System.out.printf("%s\tERROR %s%n", name, error.getClass().getSimpleName());
                    }
                }
            }
            case "decode" -> System.out.println(decoder.decode(Files.readAllBytes(Path.of(rest[1])))[0]);
            case "read" -> System.out.println(Files.readAllBytes(Path.of(rest[1])).length);
            default -> usage();
        }
    }

    private static void speed(Decoder decoder, int warmup, int runs, String[] paths) throws Exception {
        for (String path : paths) {
            byte[] bytes = Files.readAllBytes(Path.of(path));
            int[] size = {0, 0};
            for (int run = 0; run < warmup; run++) size = decoder.decode(bytes);
            double[] times = new double[runs];
            for (int run = 0; run < runs; run++) {
                long start = System.nanoTime();
                size = decoder.decode(bytes);
                times[run] = (System.nanoTime() - start) / 1e6;
            }
            Arrays.sort(times);
            double median = runs % 2 == 1 ? times[runs / 2] : (times[runs / 2 - 1] + times[runs / 2]) / 2;
            System.out.println(String.format(Locale.ROOT,
                    "{\"file\":\"%s\",\"width\":%d,\"height\":%d,\"median_ms\":%f,\"best_ms\":%f,\"runs\":%d}",
                    Path.of(path).getFileName(), size[0], size[1], median, times[0], runs));
        }
    }

    private static void usage() {
        System.err.println("usage: <twelvemonkeys|jwebp> <speed|hash|decode|read> ...");
        System.exit(2);
    }
}
