# Changelog

Numbered entries describe changes this fork makes to the upstream
`2026e` tree.  Upstream changes are tracked in `NEWS`.

## 1. Import upstream 2026e

* Full history of https://github.com/eggert/tz.git, branch `main` at commit
  `039ef27cc5f062a2055cb67435d6d71adbefd27d`, tag `2026e`.  No upstream file
  changed except `.gitignore`, which gained re-inclusion rules for the Zig
  package (upstream ignores all subdirectories and all dotfiles).

## 2. Zig 0.16 build of the C sources

* `build.zig` compiles `localtime.c`, `asctime.c`, `difftime.c` and
  `strftime.c` into the static library `tz`, and `zic.c` into the `zic`
  program, for the host and for the six check targets.
* Generates `version.h` and `tzdir.h` exactly as the upstream `Makefile` does,
  so no upstream source needed editing.
* Generates the TZif database with the freshly built `zic` from the upstream
  data files and installs it to `<prefix>/share/zoneinfo`; `-Dtz-dir=` overrides
  the compiled-in `TZDIR` (superseded by entry 7).
* Per-target preprocessor macros replace the Makefile's `-D` flags, including
  explicit values for mingw-w64 and wasi-libc.

## 3. Public Zig module and bindings

* Public module `tzdata` exposes `pub const c`, the translated declarations of
  `include/tzdata.h`, an aggregate header covering the whole upstream surface
  (`tz_localtime_rz`, `tz_mktime_z`, `tz_tzalloc`, `tz_tzfree`, the X3J11 and
  POSIX functions, `struct tzhead`).
* Typed layer: `Zone` (owning handle over `tz_tzalloc`/`tzfree`), `Tm`
  (caller-owned `struct tm` copy), `toUtcTm`, `formatAlloc`, `iso8601`,
  `zoneNameOwned`.
* `src/tzdata_version.c` adds linkable accessors for the upstream version
  strings, which upstream keeps as per-translation-unit statics.

## 4. Symbol isolation

* The library is always built with `-Dtime_tz=time_t`, upstream's documented
  private time_t mode, so every external symbol is `tz_`-prefixed and libc's
  `localtime`, `mktime`, `tzname`, `timezone`, `daylight` and `strftime` are
  never shadowed.  `zic` is unaffected (it `#undef`s `time_tz` upstream).
* No system-library mode: no installed library exports this API, and
  translating vendored headers against one would break header/ABI parity.

## 5. Tests, smoke program and consumer

* `zig build test` runs behavioural tests: zic/TZif interoperability against a
  fixture whose transitions are derived from the fixture source by hand,
  known-answer conversions for UTC and `America/New_York` (pre-epoch, the 2026
  daylight saving transitions, instants past 2038), handle lifetime and
  borrowed-name ownership, and malformed TZif rejection.
* `zig build smoke` runs a deterministic example over fixed timestamps, with
  zones opened by plain name.
* `consumer/` is a separate package that depends on `..` through
  `b.dependency`.  It compiles its own zone source with the dependency's `zic`
  and checks conversions against it, opens IANA zones by plain name to show
  that the module alone carries a usable database, and converts once through
  `tzdata.c`'s own `tz_tzalloc`/`tz_localtime_rz`/`tz_tzfree` so the aggregate
  header and the `tz_` namespace are exercised from a dependent package.
  Reachable as `zig build run` there.

## 6. Provenance gate and CI

* `PROVENANCE.sha256` records the SHA-256 of all 53 preserved upstream files;
  `zig build provenance` fails when one of them changes.
* `.github/workflows/ci.yml` runs the native tests, the smoke run, the
  six-target compile matrix and the provenance gate.  Upstream ships no CI
  configuration at this tag, so none was inherited.

## 7. The bundled database is reachable from a dependency

* `TZDIR` no longer names `<install prefix>/share/zoneinfo`, which a dependent
  package never populates.  `zic` writes into `<cache>/tzdata-zoneinfo-<digest>`,
  the digest being a SHA-256 of the zone sources, and the library compile step
  depends on that run step, so `dep.module("tzdata")` alone makes
  `Zone.open("Europe/Berlin")` work downstream.  `zig build` still copies the
  tree to `<install prefix>/share/zoneinfo`; `-Dtz-dir` moves `TZDIR` for a
  packaged build and is now rejected unless it is absolute and free of
  backslashes and double quotes.  See FORK-NOTES.md sections 10 and 14.

## 8. Generated paths never resolved during configuration

* The smoke and consumer steps receive a generated database directory as a
  step argument instead of reading a `GeneratedFile` path while the build
  script runs, which panicked before any step was scheduled.  The header
  installation steps are now registered on the install step, and the
  install-directory step depends on the `zic` step explicitly.  See
  FORK-NOTES.md section 13.

## 9. The bindings declare only what the library emits

* `tz_asctime_r` and `tz_ctime_r` are declared behind
  `TZDATA_HAVE_POSIX2008`, defined by `build.zig` from the same
  `SUPPORT_POSIX2008` value it gives the C compiler, because `asctime.c`
  compiles both away otherwise.  See FORK-NOTES.md section 6.

## 10. Corrected conversion semantics

* `Zone.toUtc` returns `Error!i64`: it rejects a year outside the C `int`
  range with `error.ConversionFailed` and documents that upstream's remaining
  failure signal, `-1`, is also a valid instant.
* `Zone.utcOffset` derives the offset from `tz_timegm` where `struct tm` has
  no `tm_gmtoff`, instead of reporting zero; `Tm.utcOffset` answers null
  there, and `Tm.iso8601` takes the offset as an argument and omits it when
  unknown.  See FORK-NOTES.md section 18.
* `formatAlloc` reads `errno` and reports `FormatTooLong` only for `ERANGE`,
  so a format that renders nothing returns an empty string.
  See FORK-NOTES.md section 15.

## 11. Tests and compile coverage

* Fixture paths derive from one helper, so they name the directory `zic`
  actually writes (`<tmp>/zoneinfo`).  See FORK-NOTES.md section 17.
* `Zone.fromPosix` is now called by the smoke program, so the compile matrix
  instantiates it for every target, and the `time_t` range guards that could
  never fire are replaced by the file's `comptime` assertion.
  See FORK-NOTES.md section 19.
* New behavioural tests cover plain-name lookup in the bundled database, a
  POSIX TZ specification, the `mktime_z` year range, the valid instant -1, an
  empty strftime result and a result that really does not fit 64 KiB.

## 12. Honest data pipeline documentation

* README.zig.md now states that the build feeds `$(TDATA)` to `zic` directly,
  skipping the `ziguard.awk` and `zishrink.awk` stage a stock `make` uses, so
  the installed tree can differ from a stock install where those scripts
  rewrite or drop zones.  See FORK-NOTES.md section 4.

## 13. Optional symbols and derived offsets match what is built

* `build.zig` pins `HAVE_TZNAME` and `USG_COMPAT` for every target branch and
  mirrors them into the translation step as `TZDATA_HAVE_TZNAME` and
  `TZDATA_USG_COMPAT`, so `include/tzdata.h` declares `tz_tzname`,
  `tz_timezone` and `tz_daylight` exactly where upstream emits them
  (`localtime.c:623-629`) instead of on every target.  On MS-Windows and in
  the fallback branch those three symbols are not emitted and are not
  declared.  That also corrects the `%Z` documentation for that
  configuration: it renders the empty string, not the process-global
  `tzname[]`.  See FORK-NOTES.md section 20.
* `Zone.utcOffset` returns `tz_timegm(local) - timestamp` where `struct tm`
  carries no `tm_gmtoff`; the previous subtraction returned the negation of
  the offset.  See FORK-NOTES.md section 21.
* `zoneDataDigest` reports an unreadable zone source with
  `std.debug.panic`, because Zig 0.16 rejects a message concatenated at run
  time inside `@panic`.  See FORK-NOTES.md section 22.
* Every fixture path now derives from `support.fixtureZoneSubPath` or
  `support.readFixture`, so the last hand-written `zoneinfo/` prefix is gone
  as well.

## 14. Driver-verified Zig 0.16 runtime and target corrections

* Sentinel strings retain their sentinel type. `Tm.yday` covers all 366
  calendar days; ISO output does not add a plus sign to ordinary years.
* Fixture paths contain `zoneinfo` once. Rule fields use zic's documented
  order and saving offsets. Transition oracles use the correct Sundays and
  daylight-saving hints; slim TZif checks read the authoritative 64-bit block.
* Process helpers use Zig 0.16 argument order and `Io.Limit` values.
* Target configuration accounts for Windows/WASI `mempcpy`, missing POSIX
  user-ID calls, and Darwin extended locales. C sources use GNU C17.
* WASI checks cover the full library and public API, not upstream zic's
  unavailable `umask`/signal path. Host zic still generates the database.
* Observed with Zig 0.16.0: native build, 23/23 Debug and ReleaseSafe tests,
  smoke, six-target compile check, consumer run, and 53-file provenance pass.