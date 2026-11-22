// The ImageSharp measuring program of Scripts/compare-decoders.sh. It follows the command-line
// contract of Benchmarks/Comparison/swift/Sources/BenchSupport/Bench.swift. ImageSharp decodes
// straight into RGBA with straight alpha, on one thread as configured below.
using System.Diagnostics;
using System.Globalization;
using SixLabors.ImageSharp;
using SixLabors.ImageSharp.Formats;
using SixLabors.ImageSharp.PixelFormats;

var configuration = Configuration.Default.Clone();
configuration.MaxDegreeOfParallelism = 1;
var options = new DecoderOptions { Configuration = configuration };

(int, int) Decode(byte[] bytes)
{
    using var image = Image.Load<Rgba32>(options, bytes);
    return (image.Width, image.Height);
}

byte[] Rgba(byte[] bytes)
{
    using var image = Image.Load<Rgba32>(options, bytes);
    var pixels = new byte[image.Width * image.Height * 4];
    image.CopyPixelDataTo(pixels);
    return pixels;
}

var invariant = CultureInfo.InvariantCulture;
switch (args)
{
    case ["speed", var warmupText, var runsText, .. var paths] when paths.Length > 0:
        int warmup = int.Parse(warmupText), runs = int.Parse(runsText);
        foreach (var path in paths)
        {
            var bytes = File.ReadAllBytes(path);
            var size = (0, 0);
            for (var run = 0; run < warmup; run++) size = Decode(bytes);
            var times = new double[runs];
            for (var run = 0; run < runs; run++)
            {
                var start = Stopwatch.GetTimestamp();
                size = Decode(bytes);
                times[run] = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
            }
            Array.Sort(times);
            var median = runs % 2 == 1 ? times[runs / 2] : (times[runs / 2 - 1] + times[runs / 2]) / 2;
            Console.WriteLine(string.Format(invariant,
                "{{\"file\":\"{0}\",\"width\":{1},\"height\":{2},\"median_ms\":{3},\"best_ms\":{4},\"runs\":{5}}}",
                Path.GetFileName(path), size.Item1, size.Item2, median, times[0], runs));
        }
        break;
    case ["hash", .. var paths]:
        foreach (var path in paths)
        {
            try
            {
                var hash = 0xcbf29ce484222325UL;
                foreach (var value in Rgba(File.ReadAllBytes(path))) hash = (hash ^ value) * 0x100000001b3UL;
                Console.WriteLine($"{Path.GetFileName(path)}\t{hash:x16}");
            }
            catch (Exception error)
            {
                Console.WriteLine($"{Path.GetFileName(path)}\tERROR {error.GetType().Name}");
            }
        }
        break;
    case ["decode", var path]:
        Console.WriteLine(Decode(File.ReadAllBytes(path)).Item1);
        break;
    case ["read", var path]:
        Console.WriteLine(File.ReadAllBytes(path).Length);
        break;
    default:
        Console.Error.WriteLine("usage: speed|hash|decode|read");
        return 2;
}
return 0;
