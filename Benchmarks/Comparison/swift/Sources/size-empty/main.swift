// The baseline for the binary size: reads the arguments like size-decode, without decoding.
let bytes = Array(CommandLine.arguments.joined().utf8)
print(bytes.count)
