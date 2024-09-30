{
  description = "Zig Prompt A tool to make a prompt for input on screen.";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  inputs.systems.url = "github:nix-systems/default-linux";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.flake-utils.inputs.systems.follows = "systems";

  outputs = {
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in
      with pkgs; {
        formatter = alejandra;
        devShells.default = mkShell {
          nativeBuildInputs = [zig];
          buildInputs = [wayland wayland-scanner];
        };

        packages.default = pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
          pname = "walrus-bar";
          version = "0.0.1";

          outputs = ["out"];

          src = ./.;

          deps = pkgs.callPackage ./build.zig.zon.nix {};

          nativeBuildInputs = [
            zig.hook
            pkg-config
            wayland-scanner
          ];

          buildInputs = [
            wayland
          ];

          zigBuildFlags = [
            "--system"
            "${finalAttrs.deps}"
            #"-Doptimize=ReleaseSafe"
          ];

          meta = {
            homepage = "https://github.com/elijahimmer/walrus-bar";
            description = "A prompting utility for wayland.";
            license = nixpkgs.lib.licenses.mit;

            mainProgram = "walrus-bar";
            platforms = lib.platforms.linux;
          };
        });
      });
}
