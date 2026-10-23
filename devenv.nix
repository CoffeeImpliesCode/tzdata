# Tools and tasks for the tzdata development shell.

{ pkgs, lib, config, inputs, ... }:

let
  # Resolve task paths from this checkout, not the caller's directory.
  sdk_root = builtins.toString ./.;

  cd_sdk = "cd ${lib.escapeShellArg sdk_root} || exit 1";
  cd_consumer = "cd ${lib.escapeShellArg (sdk_root + "/consumer")} || exit 1";

  # Each task sets both caches; task runs do not source `enterShell`.
  # Preserve caller values, else use `XDG_CACHE_HOME` or `TMPDIR`.
  # Fail rather than write Zig cache data in the checkout.
  zig_caches = script: cache: ''
    if [ -z "''${ZIG_LOCAL_CACHE_DIR:-}" ] || [ -z "''${ZIG_GLOBAL_CACHE_DIR:-}" ]; then
      if [ -n "''${XDG_CACHE_HOME:-}" ]; then
        tz_cache_root="''${XDG_CACHE_HOME}"
      elif [ -n "''${TMPDIR:-}" ]; then
        tz_cache_root="''${TMPDIR}"
      else
        echo "tzdata ${script}: XDG_CACHE_HOME and TMPDIR are both unset, so no" >&2
        echo "Zig cache location is named here. Export ZIG_LOCAL_CACHE_DIR and" >&2
        echo "ZIG_GLOBAL_CACHE_DIR at an approved mount." >&2
        exit 1
      fi
      : "''${ZIG_LOCAL_CACHE_DIR:=$tz_cache_root/zig-local-cache}"
      : "''${ZIG_GLOBAL_CACHE_DIR:=$tz_cache_root/zig-global-cache}"
      export ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR
      mkdir -p "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"
      unset tz_cache_root
    fi
    tz_cache="$ZIG_LOCAL_CACHE_DIR/tzdata/${cache}"
    mkdir -p "$tz_cache"
    echo "tzdata ${script}: build cache $tz_cache" >&2
  '';

  # Install tasks use separate cache prefixes for the zoneinfo tree.
  # `TZDATA_PREFIX` overrides their base path.
  delivery_prefix = name: ''
    tz_prefix="''${TZDATA_PREFIX:-$ZIG_LOCAL_CACHE_DIR/tzdata/${name}}"
    mkdir -p "$tz_prefix"
    echo "tzdata ${name}: delivery prefix $tz_prefix" >&2
  '';

  # Shared Zig flags precede caller arguments, which can override them.
  zig_flags = ''
    --cache-dir "$tz_cache" --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" -j8 --summary all
  '';
in

{
  packages = [
    pkgs.zig_0_16
    pkgs.pkg-config
    pkgs.gawk
    pkgs.coreutils
    pkgs.gnused
    pkgs.gnugrep
    pkgs.git
  ];

  outputs = rec {
    static = pkgs.callPackage ./package.nix {
      zig = pkgs.zig_0_16;
      linkage = "static";
    };
    shared = pkgs.callPackage ./package.nix {
      zig = pkgs.zig_0_16;
      linkage = "dynamic";
    };
    default = static;
  };

  env = {
    TZDATA_UPSTREAM_RELEASE = "2026e";
  };

  scripts = {
    # Install the SDK and compiled zoneinfo tree.
    tz-build.exec = ''
      ${cd_sdk}
      ${zig_caches "tz-build" "build"}
      ${delivery_prefix "install"}
      zig build --prefix "$tz_prefix" ${zig_flags} "$@"
    '';

    # Tests and smoke read the installed zoneinfo tree.
    tz-test.exec = ''
      ${cd_sdk}
      ${zig_caches "tz-test" "build"}
      ${delivery_prefix "test"}
      zig build test --prefix "$tz_prefix" ${zig_flags} "$@"
    '';
    tz-smoke.exec = ''
      ${cd_sdk}
      ${zig_caches "tz-smoke" "build"}
      ${delivery_prefix "smoke"}
      zig build smoke --prefix "$tz_prefix" ${zig_flags} "$@"
    '';

    # Check compiles only; provenance verifies packaged files.
    tz-check.exec = ''
      ${cd_sdk}
      ${zig_caches "tz-check" "build"}
      zig build check ${zig_flags} "$@"
    '';
    tz-provenance.exec = ''
      ${cd_sdk}
      ${zig_caches "tz-provenance" "build"}
      zig build provenance ${zig_flags} "$@"
    '';

    # Forward the nested consumer's prefix and cache paths.
    # Its dependency selects its own TZDIR; do not forward `-Dtz-dir`.
    tz-consumer.exec = ''
      ${cd_sdk}
      ${zig_caches "tz-consumer" "build"}
      ${delivery_prefix "consumer"}
      zig build consumer --prefix "$tz_prefix" ${zig_flags} "$@"
    '';

    # Run the consumer directly with its own build cache and prefix.
    tz-consumer-direct.exec = ''
      ${cd_consumer}
      ${zig_caches "tz-consumer-direct" "consumer-direct-build"}
      ${delivery_prefix "consumer-direct"}
      zig build run --prefix "$tz_prefix" ${zig_flags} "$@"
    '';
  };

  assertions = [
    {
      assertion = pkgs.zig_0_16.version == "0.16.0";
      message = "tzdata requires Zig 0.16.0; this nixpkgs exposes "
        + pkgs.zig_0_16.version;
    }
  ];

  enterShell = ''
    echo "tzdata SDK, upstream release $TZDATA_UPSTREAM_RELEASE"
    echo "  zig: $(zig version)"
    echo "  scripts: tz-build tz-test tz-smoke tz-check tz-provenance tz-consumer tz-consumer-direct"
    echo "  each script runs in this checkout, wherever it is called from"
    echo "  caches: each script fills its own from ''${XDG_CACHE_HOME}, else ''${TMPDIR}; the shell sets none"
    echo "  delivery prefixes: ''${ZIG_LOCAL_CACHE_DIR}/tzdata/<step>; ''${TZDATA_PREFIX} overrides"
    echo "  package: devenv build outputs.static | devenv build outputs.shared"
  '';
}