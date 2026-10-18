// A tiny Zig program used to prove the universal `zig` container can compile,
// not just report its version. It exits with code 145 (= 12*12 + 1), a
// deterministic value the example checks, mirroring how the project's app
// probes use a fixed exit code as their oracle.
pub fn main() u8 {
    var x: u8 = 12;
    x = x *% x +% 1;
    return x;
}
