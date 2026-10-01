# Fork notes: issues met while building the tzdata package

Issues recorded while designing the source, build and API layers of this fork.
"Verification" states what has and has not been observed: this fork's author
was not permitted to run gates, so nothing here claims a passing build.

## 1. Upstream ships no CI configuration to update

* Evidence: `git ls-files | grep -i github` at tag `2026e` returns nothing; the
  tree has 54 tracked files and no `.github` directory.
* Cause: not applicable - there is nothing inherited to rewrite or preserve.
* Fix/constraint: the fork adds exactly one workflow, `.github/workflows/ci.yml`,
  targeting this repository's own gates.  Nothing from another maintainer's
  infrastructure is copied.
* Affects: all platforms.
* Rule: when a fork's upstream has no CI, say so in the changelog rather than
  implying inherited workflows exist.
* Verification: file content only; the workflow has not been executed.

## 2. `.gitignore` hides every subdirectory and dotfile

* Evidence: upstream `.gitignore` contains `*/` and `.*`; after adding
  `src/`, `test/`, `include/`, `tools/`, `consumer/` those paths were
  invisible to `git status` until negations were appended.
* Cause (hypothesis, high confidence): upstream intends this to exclude build
  products; the patterns are over-broad for a repository that also holds a
  source tree.
* Fix/constraint: appended a fork section with `!*/` and explicit negations,
  including `!test/data/*.zi` and `!consumer/data/*.zi` because upstream also
  ignores `*.zi`.
* Affects: every target.  This matters beyond Git: Zig hashes a package
  excluding gitignored paths, so the `consumer/` package's `.path = ".."`
  dependency would have hashed an empty tree.
* Rule: after adding paths to a repository with an aggressive ignore file,
  confirm with `git status --short` that the new paths are visible *and*
  package-hashed, before writing a dependent package.
* Verification: `git status --short` listed `build.zig`, `consumer/`,
  `include/`, `src/`, `test/`, `tools/` after the change.  Dependency hashing
  itself has not been observed.

## 3. `tzdir.h` and `version.h` are generated and gitignored

* Evidence: `Makefile` rules generate both; `.gitignore` lists `tzdir.h`,
  `version.h` and `version`; `localtime.c` and `zic.c` `#include` the headers,
  so the C sources do not compile without them.
* Cause: upstream expects a POSIX build system to create them.
* Fix/constraint: `build.zig` writes both headers with the same content shape
  (`TZVERSION`, `PKGVERSION`, `REPORT_BUGS_TO`; `TZDIR`, `TZDEFAULT`) through a
  generated include directory, so upstream sources compile unmodified.
* Affects: every target; `TZDIR` must be absolute and free of backslashes and
  double quotes, because `tzdir.h` embeds it in a C string literal.
* Rule: when replacing an autotools/Make build, regenerate *every* file the
  sources `#include` but do not ship; grep the sources for `#include` of
  non-standard headers first.
* Verification: header content was written to match the Makefile rules by
  inspection; nothing has been compiled.

## 4. The packaged data pipeline needs awk

* Evidence: `Makefile` builds `vanguard.zi`, `main.zi` and `rearguard.zi`
  with `ziguard.awk` (`Makefile:745-752`) and `tzdata.zi` from `main.zi` with
  `zishrink.awk` (`Makefile:755-764`); the install target compiles the result
  with `REDO=posix_only` (`Makefile:830-831`).
* Cause: those awk scripts implement the `DATAFORM` and `REDO` variants.
* Fix/constraint: the build feeds `zic` the `$(TDATA)` source files directly,
  which is the input list of upstream's `check` target (`Makefile:1208-1212`).
  Consequence, now stated in README.zig.md as well: neither preprocessor
  runs, so the compiled tree can differ from a stock `make install` for
  zones those scripts rewrite or drop, and no gate compares the two; no
  leap-second database is generated, as with `REDO=posix_only`.
* Affects: data content, not code.
* Rule: prefer the compiler's own inputs over its preprocessors when replacing
  a build system, and name the skipped step in the user-facing document, not
  only in the worker's notes.
* Verification: file inspection only.

## 5. libc and tzcode export the same names

* Evidence: `private.h` lines about `time_tz` and `RESERVE_STD_EXT_IDS`, and
  the `Makefile` comment "-Dtime_tz=\"T\" ... it mangles external names".
* Cause: tzcode is designed to *be* the platform's time library; its unprefixed
  externals (`localtime`, `mktime`, `tzname`, ...) are the same symbols libc
  owns.
* Fix/constraint: the library is always compiled with `-Dtime_tz=time_t`, so
  upstream itself performs the renaming; no source patch is needed and
  `zic.c` is unaffected because it `#undef`s `time_tz`.  The alternative
  settings (`USG_COMPAT=1`, `HAVE_TZNAME=1`, `ALTZONE=0`) only stop duplicate
  *variable* definitions; they do not rename functions, so they were rejected.
* Affects: every platform; the choice is what keeps the translated names
  stable.
* Rule: prefer an isolation mechanism the upstream source already implements
  over a namespace implemented by the build system.
* Verification: none yet; the compile-time effect of the rename is unobserved.

## 6. mingw-w64 lacks `tm_gmtoff`, `tm_zone`, `st_ctim` and POSIX `*_r` guards

* Evidence: the toolchain's `lib/libc/include/any-windows-any/time.h` defines
  `struct tm` with nine fields only, exposes `_strftime_l` (no `strftime_l`),
  and declares `asctime_r`/`ctime_r` only under `_POSIX_THREAD_SAFE_FUNCTIONS`,
  which `private.h` never defines.  `struct stat` provides `st_ctime`.
* Cause: the UCRT headers predate those POSIX extensions.
* Fix/constraint: per-target macros `NO_TM_GMTOFF`, `NO_TM_ZONE`,
  `HAVE_STRUCT_STAT_ST_CTIM=0`, `HAVE_STRFTIME_L=0`, `SUPPORT_POSIX2008=0`,
  `HAVE_DECL_ASCTIME_R=0`, `HAVE_DIRECT_H=1`, and `HAVE_LINK=0`/
  `HAVE_SYMLINK=0` so `zic` copies files instead of linking them.
  `include/tzdata.h` gates `tz_asctime_r` and `tz_ctime_r` on
  `TZDATA_HAVE_POSIX2008`, which `build.zig` defines from the same value it
  gives the C compiler, so the bindings never declare a symbol that
  `asctime.c:53-62` compiles away.
* Affects: `x86_64-windows-gnu`.
* Rule: read the toolchain's bundled target headers before choosing HAVE_*
  values; `__has_include` detection inside `private.h` cannot detect a
  *missing field* or a declaration hidden behind another macro.
* Verification: header inspection only; the Windows compile is unobserved.

## 7. Absolute zone paths are a POSIX convention in tzcode

* Evidence: `localtime.c` treats a name as absolute only when `name[0] == '/'`
  (`if (!OPENAT_TZDIR && !SUPPRESS_TZDIR && name[0] != '/')`).
* Cause: tzcode predates drive letters; `zic.c` separately rejects `:` and `\`
  in zone names on `_WIN32`.
* Fix/constraint: tests, the smoke program and the consumer pass
  `<dir>/<zone>` paths, which works wherever the test runs natively; README
  documents that Windows users should use names relative to `TZDIR`.
* Affects: MS-Windows runtime use.
* Rule: a path-shaped API built on POSIX string tests needs a documented
  platform caveat instead of a silent reinterpretation.
* Verification: source inspection.

## 8. C pointer nullability is not recorded in headers

* Evidence: `include/tzdata.h` declares upstream functions with plain pointer
  returns; C carries no nullability, so the translator may model them as
  optional or as plain pointers.
* Cause: inherent to the C ABI.
* Fix/constraint: `pointerIsNull` and `borrowedString` in `src/root.zig` accept
  both representations, so the facade compiles either way; the raw escape
  hatch keeps whatever the translator produced.
* Affects: all targets.
* Rule: binding layers that must survive translator changes should branch on
  `@typeInfo` instead of assuming a pointer shape.
* Verification: not observed; written defensively rather than from a failure.

## 9. No system-library mode is offered

* Evidence: the public API is `tz_tzalloc`, `tz_localtime_rz`, `tz_mktime_z`,
  `tz_time2posix_z`; no installed library exports them.  libc's own timezone
  functions do not include the reentrant zone-handle API at all.
* Cause: the namespaced build deliberately does not reuse libc's symbols.
* Fix/constraint: no `b.systemIntegrationOption`; README.zig.md states the ABI
  reason.  Translating vendored headers while linking an installed libc would
  produce exactly the header/ABI mismatch the fork contract forbids.
* Affects: packaging policy, not code.
* Rule: offer a system mode only when an installed library provides the same
  declarations; otherwise document why it is absent.
* Verification: not applicable.

## 10. Where the generated database lives

* Evidence: `zig build` copies the TZif tree to `<prefix>/share/zoneinfo`,
  and the library's `TZDIR` names the directory `zic` wrote inside the local
  Zig cache (`<cache>/tzdata-zoneinfo-<digest>`).
* Cause: two different notions of "installed" in one build.  Zig's test and
  run steps use cache-local directories, and a dependent package's install
  step never runs at all; see issue 14.
* Fix/constraint: `zic` writes straight into the directory `TZDIR` names, so
  the tree a plain zone name resolves against is produced by the build graph
  and not by an install step.  The directory name carries a SHA-256 of the
  zone sources, so changed data cannot reuse an old tree.  Tests receive that
  path as a generated option, `zig build` copies the same tree to the install
  prefix, and `-Dtz-dir` moves `TZDIR` for a packaged build.
* Affects: all platforms.
* Rule: a generated path must reach a program as a step argument or a
  generated option; and a package that ships data must name a directory its
  own build graph always populates.
* Verification: not observed.

## 11. Test policy applied while writing the suite

* Rule: tests assert behaviour (conversions, TZif structure, error mapping,
  handle lifetime), never version strings or merely-present declarations.
  The smoke program prints the release string instead.
* Verification: reviewed while writing `test/`.

## 12. Packaging requirement: build outputs must stay out of source and packages

* Requirement: `.zig-cache/` and `zig-out/` must be ignored by Git and absent
  from `build.zig.zon`'s `.paths`, so an ordinary `zig build` in a user clone
  cannot contaminate a later commit or the package hash.
* Why it needed care here: the negation block added for issue 2 re-includes
  every subdirectory, which would otherwise have exposed both build output
  directories again.
* Fix/constraint: `.gitignore` ends with explicit `.zig-cache/` and `zig-out/`
  rules after the negations; `.paths` in `build.zig.zon` lists only source,
  data, test, consumer, tool and documentation paths.
* Affects: repository hygiene for every consumer.
* Verification: `git check-ignore -v` matches both directories with the new
  rules, and `git status --short` lists no build output after creating probe
  files in them.  Package hashing has not been exercised.

## 13. A run step's output directory has no path while the build script runs

* Evidence: `addOutputDirectoryArg` returns a `LazyPath` over a
  `GeneratedFile` whose `path` is only filled in during `make`
  (lib/std/Build/Step/Run.zig:438-459), and `LazyPath.getPath4` panics with
  "misconfigured build script" when it is read earlier
  (lib/std/Build.zig:2498-2522).  Reading it while configuring the smoke
  step panicked before any step was scheduled; `consumer/build.zig` repeated
  the same construct.
* Cause: one path was used both as "where the file ends up" and as "where it
  is now", and the two are different moments.
* Fix/constraint: generated paths travel as step arguments or through
  generated options.  The consumer receives its database directory as
  `argv[1]`; the smoke program needs none, because the library resolves plain
  zone names itself.
* Affects: every build.
* Rule: never resolve a `GeneratedFile` during build-script evaluation; the
  failure is a panic before scheduling, so it hides every other step.
* Verification: source inspection only; no build has been run here.

## 14. A dependent package never runs this package's install step

* Evidence: `b.dependency` runs the child's build script and nothing else
  (lib/std/Build.zig:2216-2260); the child keeps its own `install_tls`
  (lib/std/Build.zig:341-419) and no install step is registered in the
  parent's graph.  A dependent's install prefix is `<cache>/i/<hash>`.
  With `TZDIR` baked from `<prefix>/share/zoneinfo`, a plain zone name could
  therefore never resolve downstream, while the tests, the smoke program and
  the consumer all passed explicit paths and said nothing about it.
* Fix/constraint: `TZDIR` names a directory inside the local cache root that
  `zic` writes directly, and the library compile step depends on that run
  step.  The build runner derives step dependencies from the module graph of
  every compilation (lib/compiler/build_runner.zig:1794-1840), so a consumer
  that takes only `dep.module("tzdata")` reaches the run step through the
  library it links, and the database exists before its binary starts.
* Affects: every dependent package.
* Rule: for a package whose value is bundled data, prove the data path from a
  bare module dependency; a self-generated fixture proves nothing about it.
* Verification: source inspection of the wiring; no build has been run here.

## 15. `strftime` reports failure with a value that is also a valid result

* Evidence: `strftime.c:206-212` returns 0 with `ERANGE` when the result does
  not fit, and returns `p - s` otherwise, which is 0 for a format that
  renders nothing; it restores the caller's `errno` on success.
* Fix/constraint: `formatAlloc` clears `errno` before each attempt and reports
  `FormatTooLong` only for `ERANGE`, so an empty format renders an empty
  string.
* Affects: every target.
* Rule: a length-0 return is ambiguous by construction; read the documented
  out-of-band signal instead of inferring failure from a sentinel that also
  denotes output.
* Verification: source inspection; the suite that pins both branches has not
  been executed here.

## 16. `mktime_z`'s only failure signal is a valid instant

* Evidence: `WRONG` is `(-1)` (localtime.c:2413-2415) and is returned for a
  year outside `int` (localtime.c:2612-2614), a binary search that exhausts
  `TIME_T_MIN`/`TIME_T_MAX` (localtime.c:2656-2667) and an overflowing
  increment (localtime.c:2752-2753).
* Fix/constraint: `Zone.toUtc` rejects the year case itself with
  `error.ConversionFailed` and documents that upstream's other failures are
  indistinguishable from the instant 1969-12-31T23:59:59Z.
* Affects: every target.
* Rule: when a C API's error return is an in-range value, either range-check
  the input or state the collision; "the call cannot fail" is never the
  truth.
* Verification: source inspection only.

## 17. Test fixture paths missed the directory zic writes

* Evidence: `compileFixture` ran `zic -d <tmp>/zoneinfo`, so the compiled
  files are at `<tmp>/zoneinfo/Etc/Fixture`, while the tests opened
  `<tmp>/Etc/Fixture`.
* Cause: one convention, spelled by hand at every use site.
* Fix/constraint: `support.fixture_dir`, `support.fixtureRoot`,
  `support.fixtureZoneSubPath`, `support.fixtureZone` and
  `support.readFixture` own the convention, and every test path derives from
  them.
* Affects: the test suite on every platform.
* Rule: when a helper owns a subdirectory convention, derive every path
  through the helper; a hand-written path that drops one component is
  invisible until the gate runs.
* Verification: source inspection only.

## 18. `struct tm` field presence changes numeric semantics

* Evidence: mingw-w64's `struct tm` has no `tm_gmtoff`, so the facade's
  `gmtoff orelse 0` answered a zero offset for every timestamp there.
  Upstream's `strftime` does not recover either: with no `tm_zone` and, in
  this build's mingw-w64 configuration, no `tzname[]` either, `%Z` renders
  the empty string (strftime.c:560-567) and, because `USG_COMPAT` and
  `ALTZONE` are off there too, `%z` renders nothing at all
  (strftime.c:575-641).  See section 20 for the macros behind that choice.
* Fix/constraint: `Tm.utcOffset` answers null, `Tm.iso8601` takes the offset
  as an argument and omits it when unknown, and `Zone.utcOffset` derives the
  offset from `tz_timegm` where the field does not exist.  The two `strftime`
  fields are documented on `formatAlloc` as well.
* Affects: `x86_64-windows-gnu`.
* Rule: a documented `orelse 0` over a field that may be absent is a silent
  wrong answer, not a fallback.
* Verification: source inspection of the toolchain's `time.h`; the Windows
  compile is unobserved.

## 19. "Every entry point is covered by check" was not true

* Evidence: `Zone.fromPosix` had no call site outside `src/root.zig`, so
  `check` never instantiated it on any target; and the `time_t` range guards
  in `toLocal` and `toUtcTm` compared an `i64` against bounds the file's own
  `comptime` assertion had already proved equal, so they could never fire.
* Fix/constraint: the smoke program calls `fromPosix` beside `toPosix`, and
  the inert guards are replaced by that `comptime` assertion on `time_t`.
* Affects: the compile matrix and the documentation claim.
* Rule: compile-only coverage is a claim about call sites in the tree; grep
  the public surface for each name before asserting it in a doc comment.
* Verification: source inspection only.

## 20. Three legacy variables were declared on targets that never emit them

* Evidence: upstream emits `tz_tzname` only under
  `2 <= HAVE_TZNAME + TZ_TIME_T` (localtime.c:623-625) and `tz_timezone` and
  `tz_daylight` only under `2 <= USG_COMPAT + TZ_TIME_T` (localtime.c:626-629);
  private.h:868-874 guards the matching externs the same way.  The build set
  neither macro, so upstream guessed them from `_POSIX_VERSION` and
  `_XOPEN_VERSION` (private.h:335-349) and the aggregate header declared all
  three unconditionally.  Which of them exist therefore came down to whether
  the target's headers define `_POSIX_VERSION` and `_XOPEN_VERSION`, which is
  not a fact this package controls: with `HAVE_TZNAME=0` and `USG_COMPAT=0`
  nothing is emitted, and any translation that used the header would fail to
  link.
* Cause: a hand-written aggregate header and a macro configuration that was
  never pinned to each other; "the header declares it" and "the library emits
  it" were treated as one fact.
* Fix/constraint: `cDefines` states `HAVE_TZNAME` and `USG_COMPAT` for every
  target branch, `addCore` mirrors them to the translation step as
  `TZDATA_HAVE_TZNAME` and `TZDATA_USG_COMPAT`, and `include/tzdata.h` guards
  the three declarations on exactly those macros.  The values are 1 on Linux,
  the BSDs, macOS and WASI and 0 on MS-Windows and in the fallback branch.
* Affects: `x86_64-windows-gnu` and every unknown-OS build for the symbols;
  every target for the determinism of the guess.
* Rule: an aggregate header written by hand from upstream must be gated on the
  same preprocessor conditions upstream uses to decide whether a symbol exists.
* Verification: source inspection of `private.h` and `localtime.c`; no target
  has been built here.

## 21. The offset derived without `tm_gmtoff` had its sign inverted

* Evidence: `timegm` reads the broken-down fields as UTC
  (`localtime.c:2929-2940` calls `timeoff(&tmcpy, 0)`), so for an instant `t`
  whose local time is `t + offset` it returns `t + offset`.  The fallback in
  `Zone.utcOffset` returned `timestamp - timegm(local)`, which is the negation
  of the offset: `America/New_York` in June would have answered `+04:00`
  instead of `-04:00`.
* Cause: subtracting in the direction the wording suggested rather than in the
  direction the arithmetic requires, and no target where the fallback runs has
  been executed.
* Fix/constraint: `Zone.utcOffset` returns `timegm(local) - timestamp`, and the
  doc comment states the direction the difference runs in.
* Affects: any target whose `struct tm` has no `tm_gmtoff`, that is
  `x86_64-windows-gnu` and the fallback branch.
* Rule: a derived value carries the sign of the subtraction that produced it;
  derive it from the definition of the function it calls, and keep the
  direction in the comment that names the function.
* Verification: source inspection; the path is unreachable on a target whose
  `struct tm` carries `tm_gmtoff`, so no test exercises it on the host.

## 22. Zig 0.16 rejects a runtime string inside `@panic`

* Evidence: `zoneDataDigest` built its failure message with `++` at run time,
  which the compiler rejects inside the `@panic` builtin.
* Fix/constraint: `std.debug.panic` with a comptime format string and the
  offending name and error as arguments.
* Affects: every build of this package; the failure was fatal before any step
  was scheduled.
* Rule: `@panic` takes a comptime message; a formatted one belongs to
  `std.debug.panic`.
* Verification: source inspection only.