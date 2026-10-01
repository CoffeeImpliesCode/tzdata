# tzdata as a Zig package

This repository is the IANA Time Zone Database (`eggert/tz`, release `2026e`)
with a Zig 0.16 build around its C sources.  `README` still describes the
upstream distribution; this file describes the Zig package.

## Requirements

Zig 0.16.0 and a C toolchain that ships with it.  Nothing is downloaded at
build time: the C sources and the time zone data are both in this repository.

## Commands

| Command | What it does |
| --- | --- |
| `zig build` | Builds `tz` and `zic`, compiles the database, installs into `zig-out/` (`lib/libtz.a`, `bin/zic`, `share/zoneinfo/`, `include/tzdata.h`, `include/tzfile.h`) |
| `zig build test` | Runs the behavioural test suite (runs `zic` to build fixtures first) |
| `zig build smoke` | Runs the smoke program, which converts fixed timestamps in zones opened by plain name and checks each result against an independently known civil time |
| `zig build check` | Compiles the library, facade, smoke and tests for all six targets; also compiles `zic` except on WASI. No target binary runs. |
| `zig build provenance` | Verifies every preserved upstream file against `PROVENANCE.sha256` |
| `zig build consumer` | Runs the separate `consumer/` package (a second Zig build) |
| `cd consumer && zig build run` | The same consumer run without going through the parent build |

Useful options: `-Doptimize=ReleaseSafe`, `-Dtarget=<triple>`,
`-Dtz-version=2026e` (the string compiled into `version.h`) and
`-Dtz-dir=/absolute/path/to/zoneinfo` (see "Where the data is").

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
    std.debug.assert(back == 1782043200);
}
```

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

Add `dep.artifact("zic")` as well if you want to compile zone sources at build
time, the way `consumer/` does.

### Public surface

| Name | Kind | Notes |
| --- | --- | --- |
| `tzdata.c` | module | Translated C declarations; raw escape hatch |
| `tzdata.Zone` | struct | Owning reentrant handle: `open`, `close`, `toLocal`, `toUtc`, `utcOffset`, `toPosix`, `fromPosix`.  `toUtc` fails with `ConversionFailed` on a year C cannot represent |
| `tzdata.Tm` | struct | Caller-owned `struct tm` copy: `fromC`, `toC`, `utcOffset` (null without `tm_gmtoff`), `zoneNameOwned`, `iso8601(gpa, offset)` |
| `tzdata.toUtcTm` | function | `gmtime_r` equivalent |
| `tzdata.formatAlloc` | function | `strftime` with allocation |
| `tzdata.version`, `tzdata.packageName` | function | Upstream release string compiled into the library |
| `tzdata.Error` | error set | `InvalidZone`, `ConversionFailed`, `FormatTooLong` |

Ownership rules:

* A `Zone` owns its upstream handle; `close` releases it with `tzfree` and is
  idempotent.  Move a `Zone`, do not copy it.
* No upstream `malloc` result is ever handed to a caller, so there is nothing
  for a Zig allocator to free and no allocator mismatch is possible.
* `Tm.zone` borrows tzcode's abbreviation storage and is valid only while the
  owning `Zone` lives; `Tm.zoneNameOwned` copies it.

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

`zic` writes the tree into a directory this build owns - the local Zig cache
root plus `tzdata-zoneinfo-<digest>`, where the digest is a SHA-256 of the
zone sources, so changed data never reuses an old tree - and that absolute
path is compiled into the library as `TZDIR`.  The library's compile step
depends on the step that runs `zic`, so any dependent package that links
`dep.module("tzdata")` gets that database with no further build wiring and a
plain `Zone.open("Europe/Berlin")` works there.  `zig build` copies the same
tree to `<install prefix>/share/zoneinfo` as well.

A build that has to ship the library against a database at a fixed path - an
install tree, a sysroot - passes
`-Dtz-dir=/that/prefix/share/zoneinfo`.  The value must be absolute, must use
forward slashes, and must contain neither a backslash nor a double quote,
because `tzdir.h` embeds it in a C string literal.  In that build the library
looks names up only below the given directory, and populating it is the
caller's job.

Zone names are resolved the way upstream resolves them:

* a name starting with `/` is used as an absolute path (this is upstream's
  test, `name[0] != '/'` in `localtime.c`; on MS-Windows a drive-letter path
  does not satisfy it, so use names relative to `TZDIR` there);
* any other name is looked up below `TZDIR`;
* a POSIX TZ specification such as `EST5EDT,M3.2.0,M11.1.0` also works,
  because `tzalloc` falls back to `tzparse` for a name that is not a file.

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
  `ALTZONE` are all off (`strftime.c:575-641`).  Use `Tm.zone` and
  `Zone.utcOffset` instead; both are correct on every target.
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