{
  # A flake description must be a literal string: a concatenation is a thunk,
  # and the flake checker rejects a thunk here.
  description = "IANA Time Zone Database 2026e as a Zig SDK: libtz, zic and an installed zoneinfo tree, in separate static and shared variants";

  # Pinned input; the driver owns the lock file that resolves it.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/c7def046b9a883d46974757852106483d741586f";

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
      # Variants live here, not in package.nix: one callPackage per linkage.
      # default is the SDK's native policy, which is static.
      packages = forEachSystem (pkgs: rec {
        static = pkgs.callPackage ./package.nix {
          zig = pkgs.zig_0_16;
          linkage = "static";
        };
        shared = pkgs.callPackage ./package.nix {
          zig = pkgs.zig_0_16;
          linkage = "dynamic";
        };
        default = static;
      });
    };
}