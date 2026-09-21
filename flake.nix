{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
      wasmtimeVersion = "48.0.0";

      # nixpkgs' wasmtime deletes lib/*.a unless enableStatic, which busts the
      # binary cache. Upstream's tarball ships the archive already built.
      wasmtime-c-api = pkgs.stdenvNoCC.mkDerivation {
        pname = "wasmtime-c-api";
        version = wasmtimeVersion;

        src = pkgs.fetchurl {
          url = "https://github.com/bytecodealliance/wasmtime/releases/download/v${wasmtimeVersion}/wasmtime-v${wasmtimeVersion}-aarch64-macos-c-api.tar.xz";
          hash = "sha256-zJbX6cED1YrBL0Z1oWc7ovVa891lZMQJriXoTy6AMXo=";
        };

        dontConfigure = true;
        dontBuild = true;
        dontFixup = true;

        # min/ is upstream's trimmed build (1.8 MB static vs 39 MB) but ships
        # without the pooling allocator or shared memory, so it is reference
        # only until we cut our own feature set.
        installPhase = ''
          runHook preInstall
          mkdir -p "$out"
          cp -r include lib min "$out/"
          runHook postInstall
        '';

        meta = {
          homepage = "https://wasmtime.dev/";
          # Apache-2.0 WITH LLVM-exception. nixpkgs has no combined attribute
          # for that. The exception is a separate entry, same as nixpkgs' own
          # wasmtime package does it.
          license = with pkgs.lib.licenses; [
            asl20
            llvm-exception
          ];
          platforms = [ system ];
        };
      };
    in
    {
      packages.${system} = {
        inherit wasmtime-c-api;
        default = wasmtime-c-api;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.zig
          pkgs.wabt
          pkgs.binaryen
          pkgs.apple-sdk
        ];

        env = {
          WASMTIME_CAPI = "${wasmtime-c-api}";
          ZIG_GLOBAL_CACHE_DIR = ".zig-cache/global";
        };

        shellHook = ''
          echo "wasmtime ${wasmtimeVersion} c-api: $WASMTIME_CAPI"
          echo "zig $(zig version)"
          echo "build: zig build run"
        '';
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
