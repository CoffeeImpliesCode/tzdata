# Fork deviations

## Source

- Upstream C sources, headers, zone data, manuals, scripts, and licence files are unchanged.
- `.gitignore`: re-includes package directories and root dotfiles while keeping caches and build outputs ignored, so Git and Zig package hashing see the intended inputs.
- `include/tzdata.h` (fork addition): gates the aggregate C declarations on target macros so the translated bindings match symbols emitted by the library.
- `src/tzdata_version.c` (fork addition): exports the configured release and package strings without changing tzcode.
- `src/root.zig` (fork addition): maps C pointer, errno, sentinel, and target-struct behavior into the Zig facade's typed results.

## Build graph

- `build.zig` replaces upstream Make; it generates `version.h` and `tzdir.h`, builds the library and `zic`, and provides static or shared linkage.
- `-Dtime_tz=time_t` selects tzcode's namespaced symbols; per-target feature macros drive C compilation, translated declarations, pkg-config flags, and Windows exports.
- Host `zic` compiles the raw zone sources; `ziguard.awk` and `zishrink.awk` do not run, so zones they rewrite or drop can differ from upstream `make install`. No leap-second database is generated.
- The install omits `date`, `zdump`, and `tzselect`; it also omits generated `leapseconds` and `tzdata.zi`.
- `zic` writes a digest-named cache tree; install publishes it at `<prefix>/share/zoneinfo`, which is the compiled-in `TZDIR`. `--prefix` selects the path; `-Dtz-dir` only asserts it.
- The graph generates relocatable `tzdata.pc` with the target macros required by `tzdata.h`.
- A `-Druntime=true` consumer install does not publish the dependency's zone tree; that route installs the executable without the library's data.
- There is no system-library mode: libc does not provide this package's namespaced `tz_*` API.

## Platform boundaries

- `zic` is a host program for every target. WASI lacks the `umask` and signal APIs used by `zic`, so a host-built `zic` supplies the database for WASI builds.
- On `x86_64-windows-gnu`, `struct tm` lacks `tm_gmtoff` and `tm_zone`; `Tm.utcOffset` is null, while `Zone.utcOffset` is derived through `tz_timegm`. The build omits `tz_tzname`, `tz_timezone`, and `tz_daylight`; `asctime_r` and `ctime_r` are not exported, and `%Z`/`%z` render empty.
- tzcode recognizes an absolute zone path only when it begins with `/`; on Windows, use zone names relative to `TZDIR`.
- The build refuses NetBSD because `zig translate-c` cannot read its libc `sys/cdefs.h`, and 32-bit OpenBSD because the translator's `size_t` differs from that libc's.
