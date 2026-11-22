// The baseline for the binary size: reads its argument like size-decode, without decoding.
fn main() {
    let argument = std::env::args().nth(1).unwrap_or_default();
    println!("{}", argument.len());
}
