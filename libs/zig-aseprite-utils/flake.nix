{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11";
    flake-utils.url = "github:numtide/flake-utils";
    zig_overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, zig_overlay, ...}:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = import nixpkgs { inherit system; };
      zig = zig_overlay.packages.${system}.master-2025-07-18;
    in {
      devShell = pkgs.mkShell {
        packages = [
          zig
        ];
        shellHook = ''
          echo "zig $(zig version)"
        '';
      };
    });
}
