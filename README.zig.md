# tzdata as a Zig package: the interface

This file documents the Zig interface: commands, the module's public
surface, ownership and lifetime, symbol isolation, where the data is, and the
platform notes.  `README.md` is the fork's entry point — deviations from
upstream, the build/run/test matrix and consumption — and `README.upstream.md`
is upstream's own `README`, preserved byte for byte.

This repository is the IANA Time Zone Database (`eggert/tz`, release `2026e`)
with a Zig 0.16 build around its C sources.

## Requirements

Zig 0.16.0 and a C toolchain that ships with it.  Nothing is downloaded at
build time: the C sources and the time zone data are both in this repository.

## Commands

| Command | What it does |
| --- | --- |
| `zig build` | Builds `tz` and `zic`, compiles the database, and publishes it with upstream's tables, manual pages, licence files and a pkg-config file into `zig-out/` beside `lib/libtz.a` (or the shared form under `-Dlinkage=dynamic`) and `bin/zic`.  `--prefix <dir>` chooses the install prefix, and that prefix is also what fixes the compiled-in `TZDIR` |
| `zig build test` | Runs the behavioural test suite (runs `zic` to build fixtures first) |
| `zig build smoke` | Runs the smoke program, which converts fixed timestamps in zones opened by plain name and checks each result against an independently known civil time |
| `zig build check` | Compiles the library, facade, smoke and tests for all six targets; also compiles `zic` except on WASI. No target binary runs. |
| `zig build provenance` | Verifies every preserved upstream file against `PROVENANCE.sha256`, and that `README.upstream.md` is still byte-identical to upstream's `README` |
| `zig build consumer` | Runs the separate `consumer/` package, or installs it when this host cannot execute the selected target |
| `cd consumer && zig build run` | The same consumer run without going through the parent build |

Useful options: `-Doptimize=ReleaseSafe`, `-Dtarget=<triple>`,
`-Dlinkage=static|dynamic` (see "Native delivery") and `-Dtz-version=2026e`
(the string compiled into `version.h` and into the pkg-config `Version`).  A
`-Dtz-dir` may still be given, but it must name this invocation's installed
database directory; `--prefix` is how you choose that (see "Where the data
is").

The root `consumer` step invokes a nested build with the resolved target
query, CPU, optimize mode, linkage, runtime mode and release string.  It
forwards enabled executor switches and `--libc-runtimes`, uses `-j8 --summary
all`, keeps the local cache's `consumer` subdirectory and inherits the
enclosing build's global cache through two-token `--global-cache-dir`.
Caller arguments after `--` continue to the consumer program.  The nested
sub-command is `run` when this host can execute the resolved target and
`install` when it cannot, chosen by `std.zig.system.getExternalExecutor` --
the same predicate `std.Build.Step.Run` uses about the binary it is about to
spawn.  Forwarding a switch makes an executor reachable; it does not prove one
is installed.  An installed file is `INSTALL_ONLY`: a foreign binary delivered
to `bin/` proves nothing about tzcode and no test runs.  This correction is
`PENDING-VERIFICATION`.

## Using the module

```zig
const std = @import("std");
const tzdata = @import("tzdata");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var zone = try tzdata.Zone.open("Europe/Berlin");
    defer zone.close();

    const local = try zone.toLocal(1782043200); // 2026-06-21T12:00:00Z
    try std.debug.print("{s} {s}\n", .{
        // The offset comes from the zone, so it is correct on every target,
        // including those whose `struct tm` has no tm_gmtoff.
        try local.iso8601(arena, try zone.utcOffset(1782043200)),
        (try local.zoneNameOwned(arena)).?,
    });

    // localtime_rz and mktime_z are the reentrant pair behind this.
    const back = try zone.toUtc(local);
    if (back != 1782043200) return error.UnexpectedInstant;
}
```

The `close` is registered right after the `open` that succeeded and before
anything else can fail.  The arena owns everything `iso8601` and
`zoneNameOwned` allocate here; with a plain allocator, release each result
with `gpa.free` - `zoneNameOwned` returns a sentinel-terminated slice,
`iso8601` a plain `[]u8` - and release the zone before the `Tm` that borrows
from it.

`build.zig.zon`:

```zig
.dependencies = .{
    .tzdata = .{ .path = "../tzdata" },
},
```

`build.zig` needs only the module; the C library is linked for you:

```zig
const dep = b.dependency("tzdata", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("tzdata", dep.module("tzdata"));
```

### Supported routes

This package publishes six ways in and nothing else; a declaration that is
reachable only by a relative import from inside the package is not part of the
surface.

| Route | Status | What the consumer must do |
| --- | --- | --- |
| `dep.module("tzdata")` | supported | Import it.  The native library for the chosen `-Dlinkage` is already linked, so do not add `tz` to the same build again |
| `tzdata.c`, inside that module | supported | Reach an upstream entry point the typed layer omits.  It carries the C contract unchanged, so its own obligations apply |
| `dep.artifact("zic")` | supported | Run it at build time with `-d <dir>` to compile zone sources into a database, the way `consumer/` does.  It is a host program on every target, including a cross build of the library |
| `dep.artifact("tz")` | reachable, not needed | The same native library for the resolved target.  No Zig consumer requires it, and `b.dependency` publishes no include path for it |
| `<prefix>` from `zig build install` | the C route | `lib/libtz.a` (or `lib/libtz.so` / `lib/libtz.dylib` / `tz.dll` under `-Dlinkage=dynamic`), `bin/zic`, `include/tzdata.h`, `include/tzfile.h`, `share/zoneinfo/` with the TZif tree plus `iso3166.tab`, `zone.tab`, `zone1970.tab`, `zonenow.tab`, `share/man/man3/{newctime.3,newtzset.3}`, `share/man/man5/tzfile.5`, `share/man/man8/zic.8`, `share/licenses/tzdata/` and `lib/pkgconfig/tzdata.pc`.  A C consumer points `pkg-config --cflags --libs tzdata` at that prefix and gets the four `TZDATA_HAVE_*` macros it cannot otherwise reconstruct; no gate in this package builds such a program, so that route is documented and unexercised |
| `<prefix>` from `nix build .#static` / `.#shared` | the C route, packaged | The same layout, with `TZDIR` compiled as `$out/share/zoneinfo`, so a plain zone name resolves against the installed database and never against a build cache.  See "Native delivery" |

### Public surface

| Name | Kind | Notes |
| --- | --- | --- |
| `tzdata.c` | module | Translated C declarations; raw escape hatch with the C contract unchanged |
| `tzdata.Zone` | struct | Owning reentrant handle: `open`, `close`, `toLocal`, `toUtc`, `utcOffset`, `toPosix`, `fromPosix`.  Move it; `close` is idempotent on one value only.  `open("")` is the zero-offset UTC path, not the ambient zone.  `toUtc` fails with `ConversionFailed` on a year C cannot represent |
| `tzdata.Tm` | struct | Caller-owned `struct tm` value: `fromC`, `toC`, `utcOffset` (null without `tm_gmtoff`), `zoneNameOwned`, `iso8601(gpa, offset)`.  Copyable; only `zone` names memory outside the struct |
| `tzdata.toUtcTm` | function | `gmtime_r` equivalent; its `zone` is tzcode's process-wide UTC storage, not a zone borrow |
| `tzdata.formatAlloc` | function | `strftime` with allocation; returns a plain `[]u8` |
| `tzdata.version`, `tzdata.packageName` | function | Upstream release strings compiled into the library; borrowed static storage |
| `tzdata.pointerIsNull` | function | Tests a raw `c` result whichever nullability shape the translator produced |
| `tzdata.Error` | error set | `InvalidZone`, `ConversionFailed`, `FormatTooLong`; one closed vocabulary, and each method reaches only part of it |

`Zone.open` delegates file parsing to native tzcode and maps a failed
`tz_tzalloc` to `InvalidZone`.  It inherits the native count and data-block
bounds checks; it is not a strict TZif validator and does not validate the
`TZif` magic.  A successful open therefore does not establish that the file
has that signature.  The malformed-input tests cover truncated headers,
overstated data-block counts, empty files and missing paths, not magic
rejection.  No additional Zig validator or native parsing patch is applied.

### Ownership and lifetime

Every byte this package hands out, and who owns it:

| Bytes | Owner | Released with | Invalidated by |
| --- | --- | --- | --- |
| The `tz_tzalloc` state behind a `Zone` | the `Zone` that opened it | `zone.close()`, once per value | nothing before the close |
| `Zone.handle` | the `Zone`; it is a pointer value, not memory | not memory, so never freed by hand | `close`, after which every method is invalid |
| `Tm.zone` from `zone.toLocal` | tzcode, inside that `Zone` | not yours to free | `close` on that `Zone` |
| `Tm.zone` from `toUtcTm` | tzcode's process-wide UTC state | not yours to free | nothing this package does |
| `Tm.zoneNameOwned(gpa, ...)` | the caller | `gpa.free` | nothing |
| `Tm.iso8601(gpa, ...)` | the caller | `gpa.free` | nothing |
| `formatAlloc(gpa, ...)` | the caller | `gpa.free` | nothing |
| `version()`, `packageName()` | the linked library | never released | nothing |
| A `Tm` itself | the caller, by value | nothing to release | nothing |

Two rules sit on top of that table:

* `close` is idempotent on one variable, so it is safe in a `defer`.  It is
  not idempotent across copies: Zig has no move-only type, so a copy carries
  the same handle with its own `closed` flag, and closing both frees the same
  state twice.  Move a `Zone`.
* No upstream `malloc` result ever leaves the library, so nothing here can
  mismatch a Zig allocator.  The three Zig allocations above are the only ones.

## Symbol isolation

This package always compiles tzcode with `-Dtime_tz=time_t`, the private
time_t mode documented in upstream `private.h` and in the `Makefile`
(`-Dtime_tz="T"`).  In that mode upstream renames every externally visible
identifier with a `tz_` prefix:

```
tz_localtime  tz_localtime_r  tz_localtime_rz  tz_mktime  tz_mktime_z
tz_tzalloc    tz_tzfree       tz_gmtime        tz_gmtime_r tz_timegm
tz_asctime    tz_asctime_r    tz_ctime         tz_ctime_r  tz_difftime
tz_strftime   tz_strftime_l   tz_time          tz_tzset    tz_tzname
tz_timezone   tz_daylight     tz_offtime       tz_timelocal tz_time2posix
tz_posix2time tz_posix2time_z tz_time2posix    tz_time2posix_z
```

Five of those names exist only on some targets.  `include/tzdata.h` guards
each of them on a macro `build.zig` derives from the same value it gives the C
compiler, so the bindings never carry a declaration the library cannot link:

| Declared when | Names | Upstream condition |
| --- | --- | --- |
| `SUPPORT_POSIX2008=1` | `tz_asctime_r`, `tz_ctime_r` | `asctime.c:53-62` renames both to static functions otherwise |
| `HAVE_STRFTIME_L=1` | `tz_strftime_l` | `private.h:805-808` |
| `HAVE_TZNAME=1` | `tz_tzname` | `2 <= HAVE_TZNAME + TZ_TIME_T` (`localtime.c:623-625`) |
| `USG_COMPAT=1` | `tz_timezone`, `tz_daylight` | `2 <= USG_COMPAT + TZ_TIME_T` (`localtime.c:626-629`) |

Upstream guesses `HAVE_TZNAME` and `USG_COMPAT` from `_POSIX_VERSION` and
`_XOPEN_VERSION` (`private.h:335-349`), which would make the emitted variables
a property of the libc header set rather than of this package.  This build
states both instead - `1` on Linux, the BSDs, macOS and WASI, `0` on MS-Windows
and in the fallback branch - and passes the same values to the translation
step, so the three declarations above appear and disappear with the symbols.

Consequences:

* Linking this package never defines, replaces or shadows libc's `localtime`,
  `mktime`, `gmtime`, `ctime`, `asctime`, `strftime`, `time`, `tzset`,
  `tzname`, `timezone` or `daylight`.
* Apart from the five target-conditional names above, the names are stable for
  every supported target, so `tzdata.c` only changes shape where a macro says
  it may.
* `zic.c` explicitly `#undef`s `time_tz`, so the `zic` program is untouched by
  this and keeps its upstream interface.

The alternative (unprefixed) build is what upstream ships; this package does
not offer it, because offering both would make the translated names, and
therefore the bindings, differ between builds.

## Where the data is

The database is compiled by this package's own `zic` from the upstream source
files `africa`, `antarctica`, `asia`, `australasia`, `backward`, `etcetera`,
`europe`, `factory`, `northamerica` and `southamerica` - the Makefile's
`$(TDATA)`, with the default empty `PACKRATDATA`.  Two consequences are worth
stating plainly:

* Those are the raw source files, handed to `zic` directly.  A stock upstream
  `make` instead derives `main.zi` from them with `ziguard.awk` and
  `zishrink.awk` (`Makefile:745-764`) and compiles that, with `REDO` deciding
  what `zishrink` keeps; this build runs neither preprocessor, so it compiles
  the same input list as upstream's `check` target (`Makefile:1208-1212`).
  The installed tree can therefore differ from a stock install for zones
  those scripts rewrite or drop, and no gate compares the two.
* No leap-second data is compiled in, which is the `REDO=posix_only`
  outcome, so `Zone.toPosix` and `Zone.fromPosix` return their input.

`zic` writes the TZif tree into a directory this build owns - the local Zig
cache root plus `tzdata-zoneinfo-<digest>`, where the digest is a SHA-256 of
the zone sources, so changed data never reuses an old tree - and an install
step publishes that tree to `<install prefix>/share/zoneinfo`.  **That
installed directory is the `TZDIR` compiled into the library**, and the library
step depends on the publish step, so three things always agree: the compiled-in
`TZDIR`, the installed database, and the directory a dependent package
resolves a plain zone name against.  `dep.module("tzdata")` therefore still
gets a working database with no further wiring, and
`Zone.open("Europe/Berlin")` works in a dependent package.

The cache directory is staging only.  It is disposable, no shipped binary is
expected to read it, and a tree deleted from the cache is written again by the
next build.

`-Dtz-dir` still exists, but it no longer chooses the path.  Its value must be
this invocation's own installed database directory; any other value is a
configure-time failure that names both paths.  Set the prefix instead:

```sh
zig build install --prefix /opt/tz
```

The value must be absolute, must use forward slashes, and must contain neither
a backslash nor a double quote, because `tzdir.h` embeds it in a C string
literal.

`package.nix` passes both `--prefix "$out"` and
`-Dtz-dir="$out/share/zoneinfo"`.  The second is an assertion, not a setting:
it is the default, and repeating it turns any future divergence in how the
prefix is resolved into a loud configure-time failure instead of a library
that silently cannot open a zone.

One consequence for a plain `zig build`: `test` and `smoke` now also populate
`<install prefix>/share/zoneinfo`, and the tests read the published tree rather
than the staging one.

Zone names are resolved the way upstream resolves them:

* a name starting with `/` is used as an absolute path (this is upstream's
  test, `name[0] != '/'` in `localtime.c`; on MS-Windows a drive-letter path
  does not satisfy it, so use names relative to `TZDIR` there);
* any other non-empty name is looked up below `TZDIR`;
* a POSIX TZ specification such as `EST5EDT,M3.2.0,M11.1.0` also works,
  because `tzalloc` falls back to `tzparse` for a name that is not a file;
* an empty name is none of those.  Upstream takes a zero-offset UTC fast path
  that reads no file and no environment variable
  (`localtime.c:1808-1819`), so `Zone.open("")` answers "UTC" at +00:00 with
  no daylight saving for every timestamp, on every target.  It is not
  "use the ambient `TZ`".

## Platform notes

The build defines the preprocessor macros upstream documents, per target, in
`build.zig`:

* `HAVE_GETTEXT=0` everywhere, so no libintl is required.
* MS-Windows (mingw-w64): `struct tm` has no `tm_gmtoff`/`tm_zone`
  (`NO_TM_GMTOFF`, `NO_TM_ZONE`), so `Tm.gmtoff` and `Tm.zone` are null and
  `Tm.utcOffset` answers null there; `Zone.utcOffset` still answers, because
  it derives the offset by reading the broken-down time as UTC with
  `tz_timegm`.  There is no `strftime_l`, `struct stat` has no `st_ctim`,
  `asctime_r`/`ctime_r` are published as static functions rather than symbols
  (`SUPPORT_POSIX2008=0`), and `HAVE_TZNAME=0` with `USG_COMPAT=0` leaves
  `tz_tzname`, `tz_timezone` and `tz_daylight` unemitted; `link`/`symlink` are
  unavailable, so `zic` copies zone files instead of linking them, as upstream
  supports.  Each of those conditions also hides the matching declaration in
  `include/tzdata.h`, so `tzdata.c` is smaller there.
* In that configuration `formatAlloc`'s `%Z` renders the empty string: there
  is no `tm_zone` and no `tzname[]` to fall back on (`strftime.c:560-567`).
  `%z` renders the empty string too, because `TM_GMTOFF`, `USG_COMPAT` and
  `ALTZONE` are all off (`strftime.c:575-641`).  `Zone.utcOffset` is correct
  on every target; `Tm.zone` answers wherever the target's `struct tm` carries
  `tm_zone`, and its `null` there means the target cannot name the zone, not
  that the zone is UTC.
* WASI: wasi-libc has no passwd database and no `setmode`, but does declare
  `link`, `symlink` and `fchmod`; its `time_t` is 64-bit.
  `zic` itself is a host tool: WASI lacks the `umask` and signal APIs its
  source requires. The WASI library, facade, smoke and tests remain in `check`.
* Windows and WASI declare `mempcpy` but have no POSIX user-ID APIs;
  configuration sets `HAVE_MEMPCPY=1`, `HAVE_GETRESUID=0`, `HAVE_GETEUID=0`.
* Darwin needs `_USE_EXTENDED_LOCALES_=1` to expose `locale_t` to the C core
  and translated header.
* Every supported target has a 64-bit `time_t`; the facade refuses to compile
  against a narrower one rather than truncating silently.

## No system-library mode

This package deliberately has no `b.systemIntegrationOption` mode.  The only
system implementations of these entry points are libc's, which do not export
`tz_tzalloc`, `tz_localtime_rz`, `tz_mktime_z` or `tz_time2posix_z` — the
functions this package's API is built on — and translating our headers while
linking an older installed libc would produce exactly the header/ABI mismatch
the fork contract forbids.  Linking libc's timezone handling alongside a
vendored libtz is exactly what the `tz_` namespace above avoids.

## Native delivery

`-Dlinkage=static` (the default, and this package's existing policy) builds
`lib/libtz.a`; `-Dlinkage=dynamic` builds a real shared object from the same
four translation units, with `.pic` set on the library module and the same
`tz_*` export set.  The static branch leaves `pic` at the compiler default, so
the existing static objects are unchanged.  Every C flag stays in `build.zig`;
the option chooses the library form and nothing else, and the translated
bindings are identical either way because the symbol names come from
`-Dtime_tz=time_t`, not from the linkage.

Installed library names, decided by Zig per target: `lib/libtz.a` for static;
`lib/libtz.so` or `lib/libtz.dylib` on Unix, `tz.dll` plus `tz.lib` on
MS-Windows.  The MS-Windows shared build gets a module-definition file listing
its `publicSymbols`, because a COFF DLL exports nothing without one; the static
build neither needs nor gets one.

`lib/pkgconfig/tzdata.pc` is generated by the build and installed for both
linkages.  It is relocatable - `prefix` is computed from the file's own
location - its `Version` is the `-Dtz-version` value, its `Libs` is
`-L${libdir} -ltz` with no `Libs.private` (upstream's own link line adds
nothing but the C library, `Makefile:209`), and its `Cflags` carry one
`-D<NAME>=1` per enabled macro, spelled `TZDATA_HAVE_STRFTIME_L`,
`TZDATA_HAVE_POSIX2008`, `TZDATA_HAVE_TZNAME`, `TZDATA_USG_COMPAT`.  That is
what a C consumer needs and cannot reconstruct from the installed headers
alone; see `FORK-NOTES.md` § 28.

`check` does not fold `-Dlinkage` in: it compiles for six targets and installs
nothing, so folding the option in would make it answer a different question
and depend on whether every matrix target has a shared-object form.  The
shared object is produced by the default step.

**Status: PENDING-VERIFICATION.**  The option, both artefacts and the
pkg-config file are source-confirmed in `build.zig`; no gate in this
repository has built, linked or installed either form.

Neither form is a wholly static closure.  Both link libc, exactly as
`zig build` does, and both resolve zone names through `TZDIR`.

## Nix, flake and devenv

`package.nix` is one injected function returning one derivation, and it is
source-only: no workspace import, no host path, no build-time download.  The
variants live at the call sites.  `flake.nix` exposes
`packages.<system>.static` and `.shared`, with `default` = `static`.
`devenv.nix` exposes the same two as lazy `outputs.static` and
`outputs.shared`, built with `devenv build outputs.static` /
`outputs.shared`.  Neither the flake nor the shell lists the SDK in
`packages`, so entering a shell never builds it.

Build caches and scratch variables are the caller's.  Nothing in this
repository's Nix or devenv files sets, resets or unsets
`ZIG_GLOBAL_CACHE_DIR`, `ZIG_LOCAL_CACHE_DIR`, `TMPDIR`, `XDG_*` or any other
path: `package.nix` scopes its own two Zig caches under the Nix-provided
`TMPDIR` inside its sandbox, and `devenv.nix` leaves the shell's alone.

`devenv.nix`'s seven scripts each change into this checkout before running, so
they answer for this tree from any working directory.  The five whose step
installs something — `tz-build`, `tz-test`, `tz-smoke`, `tz-consumer` and
`tz-consumer-direct` — pass `--prefix "$ZIG_LOCAL_CACHE_DIR/tzdata/<script>"`
(`$XDG_CACHE_HOME`, then `$TMPDIR`, when that is unset; `TZDATA_PREFIX`
overrides).  `test` and `smoke` are in that list because both publish
`<prefix>/share/zoneinfo` through the install step, and `tz-consumer-direct`
because `consumer/build.zig` declares an install step for its own executable.
`tz-check` and `tz-provenance` take no prefix: neither installs anything.

The consumer's `TZDIR` is untouched by any of this.  `--prefix` reaches the
nested build because `build.zig` forwards it (build.zig:1286-1301), and it
decides where that build's own executable lands; a dependency's install prefix
is the build system's choice and no `--prefix` reaches it, so the run still
reads the tree the dependency published.  `-Dtz-dir` is not passed anywhere.

No C flag, source list, include path or installed artifact is declared here.
`build.zig` owns all of them, and `package.nix` writes no file: one writer per
path.

## Runtime loading

`-Druntime=true` selects the runtime-loading branch and is orthogonal to
`-Dlinkage`; the default is false, and a linked build calls the native
functions directly.  `runtime/graph.zig` owns it, and its interface is:

* One immutable, process-lifetime dispatch table per configured module.  No
  owning `Library` object and no returned API view.
* `load(.{ .path = absolute_file })` or `load(.{ .system = explicit_basename })`
  comes first; ordinary module calls follow.  No path-to-system fallback.
* The table is published atomically, only after every selected entry point
  resolved and the library validated.  A call before publication panics, in
  every optimize mode including `ReleaseFast` and `ReleaseSmall`.
* A failed attempt closes its handle and publishes nothing.  No automatic
  retry; the same request is idempotent; a different request after success is
  rejected.  No unload, reset, provider replacement or implicit fallback.
* A same-thread reentrant `load` returns an explicit error.

The loader trusts native code.  Finding the symbols is not ABI proof: a
provider must satisfy the header, ABI, scalar, layout, configuration and
allocator requirements documented above and inventoried in `NOTICE.md`.

Verification status for this branch is `PENDING-VERIFICATION`; the gates that
would move it are the driver's.

## External ABI

One shared object, built by this package's own graph, exporting the whole
`tz_`-spelled surface that upstream's `-Dtime_tz=time_t` mode produces
(`private.h:717-764`): the NetBSD-inspired reentrant family (`tz_tzalloc`,
`tz_tzfree`, `tz_localtime_rz`, `tz_mktime_z`), the X3J11-inspired family, the
POSIX family, `tz_ctime`/`tz_asctime`/`tz_difftime`/`tz_strftime`, and the
fork's `tzdata_version`/`tzdata_package`.  `runtime/library.zig` is the
authoritative in-source record.

What a provider must satisfy:

* **Configuration.**  Four macros select declarations — `SUPPORT_POSIX2008`,
  `HAVE_STRFTIME_L`, `HAVE_TZNAME`, `USG_COMPAT` — and `build.zig` drives the C
  compile line, the translated bindings, the installed `.pc` and the Windows
  export list from one table, so "declared" and "emitted" cannot disagree.  A
  provider built with other values is refused by name.
* **Scalars and layout.**  `time_t` is signed 64-bit; `timezone_t` is
  `struct state *`, allocated against the `TZ_MAX_*` bounds in `tzfile.h`;
  `struct tm` is the target's, with `tm_gmtoff` and `tm_zone` absent where
  `private.h` reads `NO_TM_GMTOFF`/`NO_TM_ZONE`.  Upstream writes through a
  caller-supplied `struct tm *`, so differing field widths are a silent
  mismatch.
* **Exported data.**  `tz_tzname`, `tz_timezone` and `tz_daylight` are
  objects, not functions.  The table holds their addresses and reads through
  them, so a write tzcode makes is visible; nothing is copied at load.
* **Allocator.**  `tz_tzalloc` is `malloc` and `tz_tzfree` is `free`
  (`localtime.c:1976`, `:2005`) through the provider's own allocator.  A
  handle is released by `tz_tzfree` exactly once, always by the library that
  produced it.  There is no caller-supplied allocator in the surface.
* **Data resource.**  `TZDIR` is compiled into the provider, so a plain zone
  name resolves below a path the *provider* was built with and a consumer must
  run with that tree present.  An absolute TZif path and a POSIX `TZ`
  specification need no database, which is what the load-time check uses, so
  `load` never depends on the data being there.

**The load-time check, and its limits.**  After every symbol resolves and
before anything is published, the provider must allocate a zone with
`tz_tzalloc("")` — upstream's UTC fast path, which reads no file and no `TZ` —
convert the epoch through `tz_localtime_rz`, release the handle through
`tz_tzfree`, and read back `1970-01-01T00:00:00` with `tm_isdst` 0, and
`tm_gmtoff` 0 where the field exists, through *this* translation's field types.
That establishes the handle pairing and the `time_t`/`struct tm` agreement.
It establishes **no** version, no rule data and nothing about a zone file:
tzcode has no versioned ABI, and this is behavioural evidence on top of the
header and symbol boundary, not a compatibility verdict.