{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11";
    zig_overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs = { self, nixpkgs, zig_overlay, ... }: let
    system = "x86_64-linux";
    zig = zig_overlay.packages.${system}.master-2024-08-03;
  in {
    devShells.${system}.default = let
      pkgs = import nixpkgs {
        inherit system;
      };
    in pkgs.mkShell {
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
        echo "zig `zig version`"
      '';
    };
  };
}
