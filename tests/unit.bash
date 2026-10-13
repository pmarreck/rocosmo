# Unit tests for the pure packer core.
echo "Unit: packer core (zig build test)"
run_capture zig build test --summary none
assert_rc0 "zig build test"
