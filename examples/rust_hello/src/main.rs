// A tiny Rust program compiled for several OS/CPU targets and joined into one
// rocosmo container. It prints 145 (= 12*12 + 1), a deterministic value the
// example checks on each OS to prove the right native build ran.
fn main() {
    let n: u64 = 12;
    println!("{}", n * n + 1);
}
