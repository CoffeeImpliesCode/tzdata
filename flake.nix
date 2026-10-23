{
  # Flake descriptions must be literal strings.
  description = "IANA Time Zone Database 2026e as a Zig SDK: libtz, zic and an installed zoneinfo tree, in separate static and shared variants";

  # Pinned nixpkgs input; flake.lock records its revision.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe";

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSystem = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # Expose each linkage variant here; the default is static.
      packages = forEachSystem (pkgs: rec {
        static = pkgs.callPackage ./package.nix {
          zig = pkgs.zig_0_17;
          linkage = "static";
        };
        shared = pkgs.callPackage ./package.nix {
          zig = pkgs.zig_0_17;
          linkage = "dynamic";
        };
        default = static;
      });
    };
}