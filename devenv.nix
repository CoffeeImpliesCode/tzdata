# Canonical development environment for the tzdata SDK.
#
# packages is tools only, so entering the shell never builds the SDK.  The two
# derivations are lazy outputs over the same package.nix the flake uses;
# `devenv build outputs.static` / `outputs.shared` is the packaging route.
#
# The shell writes no scratch variable: `enterShell` reports, and every script
# fills its own Zig caches in its own body.  A cache the caller exported is
# kept; a missing one comes from `$XDG_CACHE_HOME`, else `$TMPDIR`, and a
# caller who named none of the three has the script stop before the compiler.
# `TMPDIR`, `XDG_*` and `TZDATA_PREFIX` are read here and never written.

{ pkgs, lib, config, inputs, ... }:

let
  # This SDK's own directory, self-located rather than read out of the caller's
  # working directory.  devenv materialises each script as a generated program
  # and runs it with whatever cwd its caller had, and `$DEVENV_ROOT` is that
  # caller's directory and not this checkout.  `builtins.toString ./.` is the
  # directory this module was imported from, so every script runs against its
  # own graph.  The shorter spelling, interpolating the path directly, would
  # carry it into the Nix store context and copy the whole SDK there.
  # `lib.escapeShellArg` quotes it as one shell word, because a checkout path
  # is not guaranteed to be free of spaces or quotes.
  # `|| exit 1` on the `cd`, because a `cd` that failed unchecked leaves the
  # script running in the caller's directory, which holds no `build.zig`.
  sdk_root = builtins.toString ./.;

  cd_sdk = "cd ${lib.escapeShellArg sdk_root} || exit 1";
  cd_consumer = "cd ${lib.escapeShellArg (sdk_root + "/consumer")} || exit 1";

  # The two Zig caches, filled by every script and not by `enterShell`.
  # `devenv tasks run --mode single` never sources the shell hook, so a script
  # that relied on it would reach the compiler with the variables unset, name no
  # external cache, and take the `.zig-cache` its working directory resolves -
  # this checkout, on a shared network mount, and the tree whose file set the
  # driver digests before and after a run.
  #
  # A value the caller exported is kept exactly as it is.  A missing one is
  # filled from `$XDG_CACHE_HOME`, where a cache belongs by the Base Directory
  # Specification, else `$TMPDIR`, the host's own scratch policy.  The checkout
  # is never one of the two, `/tmp` is not a fallback for anything, and a caller
  # that named none of the three is told which are missing and stops here, in
  # this body, before the compiler.  No location is invented for it.
  #
  # The second argument is the build cache that script names.  One directory
  # serves the six scripts that build this package's own graph, so their
  # manifests and their packages are reused instead of rebuilt; the separate
  # consumer build takes one of its own, because two graphs must not write one
  # manifest directory (`build.zig:1302-1311`).
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

  # The delivery prefix for the five scripts whose graph installs something.
  # `build.zig` resolves the compiled-in TZDIR from the install prefix
  # (`installedZoneinfoDir`, build.zig:400-404), and the default prefix is
  # `<build root>/zig-out`: `zig build test` and `zig build smoke` publish
  # `share/zoneinfo` through the same install step the default step uses
  # (build.zig:1069-1076, FORK-NOTES.md § 25), and `consumer/build.zig:125`
  # declares an install step for the consumer's own executable, which resolves
  # to `consumer/zig-out` when that build is told no prefix.  Left at the
  # default, those steps write a TZif tree and an installed tree into the
  # checkout, which for this repository is a shared network mount.
  #
  # The location is read out of the environment when the script runs and never
  # interpolated.  `zig_caches` has already exported `ZIG_LOCAL_CACHE_DIR`, and
  # that is where a delivery tree belongs: the caller's own cache when the
  # caller exported one, else the one this same body derived from
  # `$XDG_CACHE_HOME` or `$TMPDIR`.  This helper therefore holds no root policy
  # of its own and cannot install into the checkout.
  # `TZDATA_PREFIX` overrides the location outright for a caller who wants an
  # installed tree somewhere else; it is read here and nowhere set.
  #
  # One directory per step, so two gates running at once cannot share a prefix
  # and so the tree a receipt names is the tree that script wrote.  The name is
  # the step's own, so none of these is a build cache directory.
  delivery_prefix = name: ''
    tz_prefix="''${TZDATA_PREFIX:-$ZIG_LOCAL_CACHE_DIR/tzdata/${name}}"
    mkdir -p "$tz_prefix"
    echo "tzdata ${name}: delivery prefix $tz_prefix" >&2
  '';

  # The flags every `zig build` in this file carries, in one string so no body
  # spells them differently: the build cache `zig_caches` just created, the
  # global cache that same body exported, `-j8`, and `--summary all`.
  # `--cache-dir` is what keeps the manifest directory out of this checkout;
  # `--global-cache-dir` states the value the environment already carries, so
  # the graph that reads the variable and the command line that named it cannot
  # disagree.  `-j8` is this workspace's job count and `--summary all` its
  # recipe for a library build, not optional extras.
  # Placement is before `"$@"`, which is where a caller's own flag still
  # overrides.
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

  # Every body starts the same way: change into this checkout, then fill both
  # Zig caches and name the build cache, because `devenv tasks run --mode
  # single` never reaches `enterShell`.  A step that installs something also
  # names its delivery prefix.  `"$@"` is last, so a caller naming `-D`, a step
  # name, `--` or its own arguments still reaches the build and still overrides
  # the four flags before it.
  scripts = {
    # `zig build` is the delivery step: library, `zic`, both headers, the zone
    # tables, the manual pages, the licence files, the pkg-config file and the
    # TZif tree all land under the prefix.
    tz-build.exec = ''
      ${cd_sdk}
      ${zig_caches "tz-build" "build"}
      ${delivery_prefix "install"}
      zig build --prefix "$tz_prefix" ${zig_flags} "$@"
    '';

    # `test` and `smoke` publish `share/zoneinfo` through the same install step
    # and read that published tree back, so both need the prefix too.
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

    # `check` compiles for the six targets and installs nothing: its steps are
    # compilations and the `zic` it builds is never run (build.zig:1204-1235).
    # `provenance` compiles `tools/provenance_check.zig` and runs it over the
    # whole of `PROVENANCE.sha256` plus the README relocation; it installs
    # nothing either.  Neither script takes a prefix, and neither loses part of
    # the gate by not taking one.
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

    # `consumer` runs a second build in `consumer/`.  `--prefix` is the one
    # argument that build.zig forwards to it, and it is forwarded for exactly
    # this reason: it decides where that build's own executable lands
    # (build.zig:1286-1301, FORK-NOTES.md § 30).  The consumer still reads the
    # TZDIR its own dependency installed, which the build system chooses and
    # `--prefix` cannot reach, so the run answers for the tree that graph
    # published.  `-Dtz-dir` is deliberately not passed: the consumer does not
    # declare it, and a value that did reach the dependency would be refused
    # against the different prefix that dependency installs into.
    # `--cache-dir` and `--global-cache-dir` reach the nested build: this graph
    # hands it `<build cache>/consumer` and the global cache it was given
    # (`build.zig:1302-1334`), so one named here is also what keeps
    # `consumer/.zig-cache` out of the checkout.
    tz-consumer.exec = ''
      ${cd_sdk}
      ${zig_caches "tz-consumer" "build"}
      ${delivery_prefix "consumer"}
      zig build consumer --prefix "$tz_prefix" ${zig_flags} "$@"
    '';

    # The separate consumer package, run without going through the parent
    # build, so a failure localises to the consumer's own build.  It declares
    # its own install step (`b.installArtifact(exe)`,
    # `consumer/build.zig:125`), and that build's default prefix is
    # `consumer/zig-out` - inside the checkout.
    # A build root of its own, so it names a cache of its own: two graphs must
    # not write one manifest directory, and without `--cache-dir` this one
    # resolves `consumer/.zig-cache`.
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