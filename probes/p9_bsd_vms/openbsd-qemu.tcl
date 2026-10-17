# QEMU command prefix for an OpenBSD VM of ARCH (x86_64 under KVM; aarch64
# emulated on QEMU's virt board with the bundled EDK2 UEFI firmware, whose
# console is already the serial port). Sourced by the openbsd*.exp scripts.
proc qemu_cmd {arch} {
	switch -- $arch {
		x86_64 { return [list qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 -nographic] }
		aarch64 {
			set qemu [lindex [auto_execok qemu-system-aarch64] 0]
			set fw [file join [file dirname [file dirname $qemu]] share qemu edk2-aarch64-code.fd]
			return [list $qemu -M virt -cpu cortex-a72 -accel tcg,thread=multi -m 1024 -smp 2 -bios $fw -nographic]
		}
		default { puts "openbsd-qemu.tcl: unknown arch $arch"; exit 2 }
	}
}
proc step {pattern reply} {
	expect {
		$pattern { send $reply }
		timeout { puts "\n[info script]: timed out waiting for: $pattern"; exit 1 }
		eof { puts "\n[info script]: VM exited waiting for: $pattern"; exit 1 }
	}
}
