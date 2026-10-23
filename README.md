# IANA Time Zone Database for Zig

IANA Time Zone Database (`eggert/tz`) release `2026e`, built as a Zig 0.16.0 package.
It builds tzcode, its zone database, and a typed Zig facade.

## Source deviations from upstream

- Upstream C sources, headers, zone data, manuals, scripts, and licence files are unchanged.
- `.gitignore` retains upstream patterns and re-includes package directories and root dotfiles for Git and package hashing.
- `include/tzdata.h` (fork addition) gates aggregate C declarations on target macros so translated bindings match emitted symbols.
- `src/tzdata_version.c` (fork addition) exports the configured release and package strings.
- `src/root.zig` (fork addition) maps C pointer, errno, sentinel, and target-struct behavior into typed Zig results.

## Build deviations

- `build.zig` replaces upstream Make, generates `version.h` and `tzdir.h`, and builds without downloads.
- `-Dtime_tz=time_t` selects upstream's private-`time_t` mode and prefixes externally visible tzcode symbols with `tz_`. There is no system-library mode; libc does not export this API.
- Target feature macros drive C compilation, translated declarations, pkg-config flags, and Windows exports.
- Host `zic` compiles raw zone sources. `ziguard.awk` and `zishrink.awk` do not run, so zones they rewrite or drop may differ from upstream `make install`. No leap-second database is generated.
- `zic` stages the TZif tree in the build cache; install publishes it at `<prefix>/share/zoneinfo`, the compiled-in `TZDIR`. `--prefix` selects that path; `-Dtz-dir` only asserts it.
- A runtime-loading route generates a typed dispatch from the selected translation and loads an explicit shared provider instead of linking the package library.
- The install provides `zic` but omits `date`, `zdump`, `tzselect`, `leapseconds`, and `tzdata.zi`.

## Support matrix

Zig 0.16.0. The configured compile targets use 64-bit `time_t`.

| Target | Support and platform boundary |
|---|---|
| `x86_64-linux-gnu` | Supported |
| `aarch64-linux-gnu` | Supported |
| `aarch64-macos` | Supported |
| `riscv64-linux-gnu` | Supported |
| `x86_64-windows-gnu` | `struct tm` lacks `tm_gmtoff` and `tm_zone`; `Tm.utcOffset` is null, while `Zone.utcOffset` uses `tz_timegm`. `%Z` and `%z` render empty. |
| `wasm32-wasi` | Library and facade compile; host `zic` builds the database because WASI lacks APIs used by `zic`. |
| NetBSD | Unsupported: `zig translate-c` cannot read libc's `sys/cdefs.h`. |
| 32-bit OpenBSD | Unsupported: `zig translate-c`'s `size_t` differs from libc's. |

## Consumption

Add the package in `build.zig.zon`:

```zig
.dependencies = .{
    .tzdata = .{ .path = "../tzdata" },
},
```

Import the facade from `build.zig`:

```zig
const dep = b.dependency("tzdata", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("tzdata", dep.module("tzdata"));
```

`dep.module("tzdata")` links the selected library. `dep.artifact("zic")` is the host zone compiler; `dep.artifact("tz")` names the native library. The installed prefix also contains `include/tzdata.h`, `include/tzfile.h`, `share/zoneinfo/`, manual pages, licence files, and `lib/pkgconfig/tzdata.pc`.

| `-Dlinkage` | Installed library |
|---|---|
| `static` (default) | `lib/libtz.a` |
| `dynamic` | `lib/libtz.so`, `lib/libtz.dylib`, or `tz.dll` plus `tz.lib` on Windows |

Options: `-Dtarget=<triple>`, `-Doptimize=<mode>`, `-Dlinkage=static|dynamic`, `-Druntime=true|false` (default `false`), `-Dtz-version=<release>`, `--prefix <dir>`, and `-Dtz-dir=<path>` as an assertion of the installed database path. `--prefix` sets the compiled-in `TZDIR`.

A C consumer uses `pkg-config --cflags --libs tzdata` for the matching declarations and libraries. See `README.zig.md` for the Zig facade API.
