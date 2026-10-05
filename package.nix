# Source-only derivation for the tzdata SDK.
#
# One injected function, one derivation.  The `linkage` argument selects the
# native library form and nothing else; variants are chosen at the call sites
# (flake.nix, devenv.nix), never inside this file.  No workspace import, no
# host path, no build-time download.

{ lib
, stdenv
, zig
, linkage ? "static"
}:

assert lib.assertMsg (linkage == "static" || linkage == "dynamic")
  "package.nix: linkage must be \"static\" or \"dynamic\", got ${builtins.toString linkage}";

let
  # Bound here rather than read off the attribute set: an attribute name is not
  # a variable, so the source name below could not interpolate them.
  pname = "tzdata";
  version = "0.1.0+2026e";
in

stdenv.mkDerivation {
  inherit pname version;

  # Drop VCS and tool state only.  Every source, data, test, fixture and licence
  # file stays, including all 53 entries PROVENANCE.sha256 names, so checkPhase
  # runs against the packaged tree.
  src = lib.cleanSourceWith {
    src = ./.;
    name = "${pname}-${version}";
    filter = path: _type:
      let base = baseNameOf (toString path);
      in !(builtins.elem base [
        ".git"
        ".jj"
        ".devenv"
        ".devenv.flake.nix"
        ".direnv"
        ".envrc.lock"
        ".zig-cache"
        "zig-cache"
        "zig-out"
        "zig-pkg"
        "result"
      ]) && !(lib.hasPrefix "result-" base);
  };

  strictDeps = true;
  nativeBuildInputs = [ zig ];

  # The Zig setup hook replaces a phase only while it is empty, so these two
  # run our commands instead of its default `zig build` then `zig build install`.
  dontConfigure = true;
  dontBuild = true;

  # build.zig installs the library, zic, both public headers, the upstream zone
  # tables and manual pages, the licence files and lib/pkgconfig/tzdata.pc.
  # Nothing is written here: one writer per path.
  installPhase = ''
    runHook preInstall

    export ZIG_GLOBAL_CACHE_DIR="''${TMPDIR:-/tmp}/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="''${TMPDIR:-/tmp}/zig-local-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

    # --prefix is what makes $out/share/zoneinfo the compiled-in TZDIR:
    # build.zig resolves the installed database directory, publishes the tree
    # zic compiled there, and makes the library step depend on that copy.
    # -Dtz-dir repeats that resolution as an assertion, because build.zig
    # rejects any other value; prefix/$out drift then fails at configure time
    # instead of producing a library that cannot open a zone by plain name.
    zig build install \
      --prefix "$out" \
      -j"''${NIX_BUILD_CORES:-1}" \
      -Doptimize=ReleaseSafe \
      -Dcpu=baseline \
      -Dtz-version=2026e \
      -Dtz-dir="$out/share/zoneinfo" \
      -Dlinkage=${linkage}

    runHook postInstall
  '';

  # Provenance over the packaged tree: the recorded upstream hashes, and that
  # README.upstream.md is still the preserved copy of upstream's README.
  doCheck = true;
  checkPhase = ''
    runHook preCheck

    export ZIG_GLOBAL_CACHE_DIR="''${TMPDIR:-/tmp}/zig-global-cache"
    export ZIG_LOCAL_CACHE_DIR="''${TMPDIR:-/tmp}/zig-local-cache"
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"

    zig build provenance \
      -j"''${NIX_BUILD_CORES:-1}" \
      -Doptimize=ReleaseSafe \
      -Dcpu=baseline

    runHook postCheck
  '';

  passthru = {
    inherit linkage;
  };

  meta = {
    description =
      "IANA Time Zone Database 2026e built as a Zig SDK, with the tz_ symbol "
      + "namespace and an installed zoneinfo tree";

    longDescription = ''
      The upstream tzcode C sources and Time Zone Database zone data, compiled
      with upstream's documented private time_t mode, so every externally
      visible entry point carries a tz_ prefix and the library cannot shadow
      libc's own localtime, mktime, tzname, timezone, daylight or strftime.

      The build compiles the database with its own zic, publishes it to
      share/zoneinfo beside upstream's zone tables and manual pages, and bakes
      that installed directory into the library as TZDIR.  linkage selects a
      static archive (the default) or a real shared object from the same
      sources; both install the same headers, data, tool, manual pages, licence
      files and relocatable pkg-config metadata.

      Licensing is per file: upstream tz code and data are public domain except
      strftime.c, date.c and newstrftime.3, which are BSD-3-Clause, and
      strftime.c is a source file of libtz, so its notice and disclaimer travel
      with every binary.  NOTICE.md is the per-file inventory.
    '';

    homepage = "https://github.com/eggert/tz";

    licenses = with lib.licenses; [ publicDomain bsd3 unlicense ];

    platforms = lib.platforms.all;
  };
}