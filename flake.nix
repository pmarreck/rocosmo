{
	description = "rocosmo: one Roc-built file for Linux, macOS, Windows and the BSDs; pinned Roc nightly";

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


			# The same nightly for every OS/CPU the nightlies cover, keyed by
			# rocosmo-pack target: the payloads of the Roc compiler container.
			rocTargetAssets = {
				linux-x86_64 = rocAssets.x86_64-linux;
				linux-aarch64 = rocAssets.aarch64-linux;
				macos-arm64 = rocAssets.aarch64-darwin;
				macos-x86_64 = rocAssets.x86_64-darwin;
				windows-x86_64 = { name = "windows_x86_64"; ext = "zip"; hash = "sha256-0e3sDs27fjtrvFEftK79hLK+hgb703ijET3oDAo+8b4="; };
			};
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

					# Every target's roc executable, one folder per rocosmo-pack target
					# (roc, or roc.exe for Windows), for scripts/roc-container.
					roc-all-targets = pkgs.stdenvNoCC.mkDerivation {
						pname = "roc-nightly-all-targets";
						version = rocNightly;
						nativeBuildInputs = [ pkgs.unzip ];
						dontUnpack = true;
						dontConfigure = true;
						dontBuild = true;
						dontFixup = true;
						installPhase = nixpkgs.lib.concatStrings (nixpkgs.lib.mapAttrsToList (target: a:
							let
								ext = a.ext or "tar.gz";
								src = pkgs.fetchurl {
									url = "https://github.com/roc-lang/nightlies/releases/download/nightly-${rocNightly}/roc_nightly-${a.name}-${rocNightly}.${ext}";
									hash = a.hash;
								};
							in ''
								mkdir -p unpack/${target} $out/${target}
								${if ext == "zip" then "unzip -q ${src} -d unpack/${target}" else "tar -xzf ${src} -C unpack/${target}"}
								find unpack/${target} -type f \( -name roc -o -name roc.exe \) -exec cp {} $out/${target}/ \;
							'') rocTargetAssets);
					};
				});

			devShells = forAll (system: pkgs: {
				default = pkgs.mkShell {
					packages = [
						self.packages.${system}.roc
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
			});
		};
}
