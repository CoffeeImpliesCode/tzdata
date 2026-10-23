# Changelog

Fork changes to upstream `2026e`; upstream release changes are in `NEWS`.
- Port to Zig 0.17.0.
- Nested consumer builds pass cache and toolchain paths through environment variables and use absolute fixture paths.
- `zic` receives target-specific C feature settings, including Windows portability macros.
- Nested consumer builds now inherit the outer build's resolved install prefix, including the default.
- Cross-target consumer builds install the executable when no executor can run it.
- Nested `consumer` builds forward global-cache and executor settings alongside target, runtime and linkage selections.
- `devenv` commands run from this package, forward build arguments and use an external prefix for install-producing steps.
- `Tm.iso8601` handles out-of-range month values and the full `i64` offset range without integer overflow.
- `consumer/` forwards the selected release to its dependency and program arguments to the run step.
- Static `libtz.a` remains the default; `-Dlinkage=dynamic` builds the shared library. Installation includes pkg-config metadata, headers, the database, tables, selected manuals and licence files; `date`, `zdump`, `tzselect`, `leapseconds` and `tzdata.zi` are not installed.
- The linked dependency publishes its database at the compiled-in `share/zoneinfo`, so consumers open IANA zones by plain name; `-Dtz-dir` asserts this invocation's installed path and rejects mismatches.
- The typed API documents handle ownership, borrowed-name lifetimes, allocation, sentinel and blocking-call contracts; runtime-loaded builds resolve an explicit provider.
- Target-specific C settings match declarations to emitted symbols and account for Windows/WASI API differences, Darwin extended locales and GNU C17; configured refusal targets fail before compilation.
- On targets without `tm_gmtoff`, `Zone.utcOffset` derives the offset with `tz_timegm`, while `Tm.utcOffset` reports unknown; ISO formatting omits an unknown offset.
- Optional `tz_tzname`, `tz_timezone` and `tz_daylight` declarations match emitted symbols; Windows and fallback builds omit them.
- `zic` compiles raw upstream zone sources without `ziguard.awk` or `zishrink.awk`, so the resulting database can differ from a stock upstream installation.
- `formatAlloc` reports `FormatTooLong` only when `strftime` returns `ERANGE`; an empty result remains an empty string.
- `Zone.toUtc` reports out-of-range years as `ConversionFailed` while preserving `-1` as a valid instant.
- `-Dtime_tz=time_t` gives the library a `tz_`-prefixed external namespace; the package has no system-library mode.
- The public `tzdata` Zig module provides typed `Zone`, `Tm`, conversion, formatting and zone-name APIs alongside translated declarations from `include/tzdata.h`.
- `tzdata_version` and `tzdata_package` expose upstream's translation-unit-local version strings as linkable symbols.
- The build compiles the upstream C library as `libtz`, generates `version.h` and `tzdir.h`, and builds `zic` as a host tool for its bundled zone sources.
