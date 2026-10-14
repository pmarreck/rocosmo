{
	description = "rocosmo research environment: pinned Roc nightly and official Cosmopolitan toolchain";

	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
		# zstd sources (Zig-packaged fork of upstream zstd); compiled directly by build.zig.
		zstdz = {
			url = "github:pmarreck/zstdz/484cc81791e44d22f459054aedd3ec53dbb20174";
			flake = false;
		};
	};

	outputs = { self, nixpkgs, zstdz }:
		let
			# Roc has no numbered release. Pin one immutable nightly tag; see RESEARCH.md
			# "Updating pins" for the procedure. Hashes are the GitHub release digests.
			rocNightly = "2026-10-12-2664a27";
			rocAssets = {
				x86_64-linux = { name = "linux_x86_64"; hash = "sha256-uKd7P4ZgfcbcwXPS7rgF+fbhMUkTF3xQ6/c1YpOFNLc="; };
				aarch64-linux = { name = "linux_arm64"; hash = "sha256-z9QCxsQDnQz+pYx9STLM2KSULuy2X5owfQZRTv4uFOg="; };
				aarch64-darwin = { name = "macos_apple_silicon"; hash = "sha256-2f9f3Zehe8zntid1iArgfRwIVRAgotKkl85dgAvacIE="; };
				x86_64-darwin = { name = "macos_x86_64"; hash = "sha256-iIRWD2kck1QMH6OxoKR75+4QBhnQFiaVgxB869XZN+c="; };
			};

			# Latest official Cosmopolitan release (GitHub release 4.0.2, 2025-01-06).
			# Fetched from the versioned file, never the mutable cosmocc.zip alias.
			cosmoccVersion = "4.0.2";
			cosmoccHash = "sha256-6KZv7KU2rJhwfc9k6z9I6ZdfIS1KqRFLZUo8YyuD7ZY=";

			systems = builtins.attrNames rocAssets;
			forAll = f: nixpkgs.lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});
		in
		{
			packages = forAll (system: pkgs:
				let
					asset = rocAssets.${system};
				in
				{
					roc = pkgs.stdenvNoCC.mkDerivation {
						pname = "roc-nightly";
						version = rocNightly;
						src = pkgs.fetchurl {
							url = "https://github.com/roc-lang/nightlies/releases/download/nightly-${rocNightly}/roc_nightly-${asset.name}-${rocNightly}.tar.gz";
							hash = asset.hash;
						};
						sourceRoot = ".";
						dontConfigure = true;
						dontBuild = true;
						dontFixup = true;
						installPhase = ''
							mkdir -p $out/libexec/roc $out/bin
							cp -r ./*/. $out/libexec/roc/
							ln -s $out/libexec/roc/roc $out/bin/roc
						'';
					};

					cosmocc = pkgs.stdenvNoCC.mkDerivation {
						pname = "cosmocc";
						version = cosmoccVersion;
						src = pkgs.fetchzip {
							url = "https://cosmo.zip/pub/cosmocc/cosmocc-${cosmoccVersion}.zip";
							hash = cosmoccHash;
							stripRoot = false;
						};
						dontConfigure = true;
						dontBuild = true;
						dontFixup = true;
						installPhase = ''
							mkdir -p $out
							cp -r $src/. $out/
						'';
					};
				});

			devShells = forAll (system: pkgs: {
				default = pkgs.mkShell {
					packages = [
						self.packages.${system}.roc
						self.packages.${system}.cosmocc
						pkgs.zig
						pkgs.file
						pkgs.binutils
						pkgs.llvmPackages.bintools-unwrapped
						pkgs.jq
						pkgs.dash
						pkgs.zsh
						pkgs.oksh
						pkgs.mksh
						pkgs.zstd
						pkgs.xz
					] ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.qemu pkgs.expect pkgs.mtools pkgs.dosfstools ];
					# Busybox applets would shadow coreutils/tar on PATH; expose only the binary.
					# zstd sources for build.zig and the decode-only decoder probe (P6).
					ROCOSMO_ZSTD_SRC = "${zstdz}";
					ROCOSMO_BUSYBOX = pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux "${pkgs.busybox}/bin/busybox";
				};
			});

			checks = forAll (system: pkgs: {
				roc = self.packages.${system}.roc;
				cosmocc = self.packages.${system}.cosmocc;
			});
		};
}
