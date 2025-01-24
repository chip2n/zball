{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11";
    flake-utils.url = "github:numtide/flake-utils";
    zig_overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, zig_overlay, ...}:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs { inherit system; };
      zig = zig_overlay.packages.${system}.master-2025-01-20;
    in {
      devShell = pkgs.mkShell {
        packages = [
          zig
          pkgs.alsa-lib
          pkgs.alsa-plugins
          pkgs.glfw
          pkgs.xorg.libX11
          pkgs.xorg.libXi
          pkgs.xorg.libXcursor
        ];
        shellHook = ''
          export ALSA_PLUGIN_DIR=${pkgs.alsa-plugins}/lib/alsa-lib
          echo "zig $(zig version)"
        '';
      };
    });
}
