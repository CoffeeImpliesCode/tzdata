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

## 23. The fork had no README of its own

* Evidence: the tracked-file list captured on 2026-10-03 contained upstream's
  `README` and the fork's `README.zig.md`, and no `README.md`;
  `README.zig.md` opened with "README still describes the upstream
  distribution; this file describes the Zig package".
* Cause: this fork was written before the README-relocation contract, and the
  interface document absorbed the entry-point role that a separate `README.md`
  now has.
* Fix/constraint: upstream's `README` is preserved byte for byte as
  `README.upstream.md`, and a new `README.md` carries the canonical order -
  native-source deviations, native-build deviations, the build/run/test
  matrix, consumption - with `README.zig.md` unchanged as the interface
  document.
* Affects: documentation only.
* Rule: a preserved-upstream file and a fork file must have different names.
  Shadowing upstream's text with a fork file of the same name destroys the
  record of what upstream actually said, which is the one thing an import has
  to be able to answer.
* Verification: the driver recorded the byte identity of `README.upstream.md`
  against upstream's `README` at commit `039ef27cc5f062a2055cb67435d6d71adbefd27d`,
  SHA-256 `38b3f33eaddff624727c5bb238542bf448b1b5f446a31085c1ce34942819d328`,
  which is the same digest `PROVENANCE.sha256` carries for `README`.  This
  worker did not re-run that comparison.

## 24. The upstream ignore file hides the new root dotfiles

* Evidence: `.gitignore:5` is `*/` and `.gitignore:31` is `.*`; the fork block
  at `.gitignore:49-60` re-includes `!*/` and then names `src/`, `include/`,
  `test/`, `consumer/`, `tools/`, `.github/` and, last, `!.envrc`.  Lines
  62-71 name the tooling state that must stay ignored - `.devenv/`,
  `.devenv.flake.nix`, `.direnv/`, `.envrc.lock`, `result`, `result-*` - and
  lines 74-75 re-ignore `.zig-cache/` and `zig-out/` after the negations.
  Before `!.envrc` was appended, that file was invisible to Git - and, because
  Zig hashes a package excluding gitignored paths, to a path dependency as well.
* Cause: the negations were written when every fork file lived in one of those
  subdirectories (section 2 above).  A root dotfile was never among them.
* Fix/constraint: resolved in `.gitignore` - `!.envrc` re-included, the
  devenv, direnv and `nix build` state explicitly ignored, and every upstream
  pattern together with the `!*/` block left in place.
* Affects: every target, through Git visibility and package hashing rather
  than through the compiler.
* Rule: after adding a root dotfile to a repository with an over-broad ignore
  file, confirm `git status --short` lists it.  The mechanism that keeps build
  products out of the tree is the same one that can keep the tree out.
* Verification: not run; `.gitignore` and `build.zig.zon` are the build-graph
  role's files and no gate was executed by this role.

## 25. The default `TZDIR` is wrong for a packaged output

* Evidence (before the fix): the bundled database directory was derived from
  `b.cache_root.path`, `-Dtz-dir` could override it, and the value was written
  into `tzdir.h` while the build script was configured.  A Nix store output has
  no build cache beside it, so a library compiled that way could not open a
  zone by plain name once the cache was gone.  The current `build.zig` resolves
  the directory from the install prefix, publishes the tree there, and rejects
  any other `-Dtz-dir`.
* Cause: the default was chosen for a dependent Zig package, where the
  library's compile step depends on the step that runs `zic` (section 14
  above).  That reasoning does not transfer to a package whose data directory
  has to outlive the build that produced it.
* Fix/constraint: resolved at the build graph, not in the packaging.  `TZDIR`
  is now `<install prefix>/share/zoneinfo` and that is its default; a `-Dtz-dir`
  naming anything else is rejected while the build script is configured, with a
  message that prints both paths.  `zic` still writes a digest-named tree in
  the cache, an install step publishes it, and the library step depends on that
  copy, so the compiled `TZDIR`, the installed database and what a dependent
  resolves are one directory.  `package.nix` therefore only has to pass
  `--prefix "$out"`; it repeats `-Dtz-dir="$out/share/zoneinfo"` as an assertion,
  so a future divergence in how the prefix resolves fails loudly instead of
  producing a library that silently cannot open a zone.
* Affects: every consumption.  The `dep.module("tzdata")` route now publishes
  into the consumer's own prefix and reads the published tree, so a bare module
  dependency still works and no longer depends on a cache directory outliving
  the build.  One consequence: `zig build test` and `zig build smoke` also
  populate `<install prefix>/share/zoneinfo`.
* Rule: a default chosen so that an in-tree consumer works can make a deployed
  consumer fail quietly - here every plain zone name failed with no error at
  build time.  Once the correct path is derivable from the install prefix,
  derive it and make any other value an error, rather than leaving a flag that
  silently produces a broken library.
* Verification: source inspection of the current `build.zig`; no Nix derivation
  and no deployment has been built, so the claim that the published tree and
  the compiled `TZDIR` agree at run time is still unobserved.

## 26. The primary upstream term has no SPDX identifier

* Evidence: `LICENSE:1-5` dedicates the tree to the public domain and names
  three BSD-3-Clause exceptions; no upstream file carries an SPDX header; the
  BSD grants are `strftime.c:3-28`, `date.c:3-28` and `newstrftime.3:4-33`.
* Cause: SPDX has no bare "public domain" identifier, so a fork file that is
  required to carry one must pick between the two standard public-domain
  instruments, `CC0-1.0` and `Unlicense`.
* Fix/constraint: `FORK-LICENSE.md` grants the Unlicense, states why, reproduces
  the text, and says in the same paragraph that upstream used neither, offered
  no fallback grant and no SPDX identifier, and that the fork's grant re-grants
  nothing upstream and attributes nothing to upstream's authors.
* Affects: SPDX headers on fork-authored files.  No upstream file is touched,
  and `README.upstream.md` and `.gitignore` deliberately carry no header
  because both must stay byte-identical.
* Rule: when a project's primary term has no SPDX identifier, record which of
  the two standard instruments was chosen and why, rather than letting a bare
  header imply upstream used it.
* Verification: source inspection only.

## 27. One package attribute has to stand for a tree with three terms

* Evidence: `NOTICE.md` § 2 records that `strftime.c` is BSD-3-Clause and is a
  source file of `libtz`; § 1 records that everything else upstream is public
  domain; `FORK-LICENSE.md` grants the Unlicense to the fork's own files.
* Cause: `meta` has one licence field and the tree has three terms.
* Fix/constraint: `package.nix` uses the plural `meta.licenses` and lists all
  three, and its `longDescription` says which component carries which term and
  points at `NOTICE.md` as the authority.  No single label is asserted
  anywhere.
* Affects: Nix metadata and any scanner that trusts `meta`.
* Rule: a package-level licence field is a summary.  Where the tree is mixed,
  the same derivation has to say which component carries which term, or the
  summary reads as a claim.
* Verification: not run.

## 28. An installed prefix does not carry the macros its header needs

* Evidence: `include/tzdata.h` gates six declarations on four macros -
  `TZDATA_HAVE_STRFTIME_L`, `TZDATA_HAVE_POSIX2008`, `TZDATA_HAVE_TZNAME`,
  `TZDATA_USG_COMPAT` (`:33-35`, `:72-78`, `:82-84`, `:90-95`) - which
  `build.zig`'s `configureCMacros` and its translation step compute per target
  from the same `cDefines` value given to the C compiler.  Before this
  migration `zig build install` installed only `tzdata.h` and `tzfile.h`, and
  nothing recorded those four values.
* Cause: the macros are a property of the C compile line, and the install step
  does not carry the compile line.
* Fix/constraint: the build graph now generates `lib/pkgconfig/tzdata.pc` and
  installs it for both linkages.  It computes `prefix` from the file's own
  location so the tree stays relocatable, takes `Version` from `-Dtz-version`,
  emits `-L${libdir} -ltz` with no `Libs.private` (upstream's own link line adds
  nothing but the C library, `Makefile:209`), and emits one `-D<NAME>=1` per
  enabled macro in `Cflags`.  `package.nix` deliberately installs no `.pc`, so a
  build-graph file and a derivation file cannot collide on the same path.
* Affects: any C consumer of an installed prefix, static or shared.  A C
  consumer that guesses the macros either fails to link on a target where the
  symbols do not exist or silently loses a declaration on a target where they
  do.
* Rule: a header whose declarations are gated on build configuration needs
  that configuration to travel with it, or every consumer of the installed
  prefix has to reconstruct it by guessing.
* Verification: source inspection of the generator in `build.zig`; no `.pc`
  file has been generated, installed or read by `pkg-config` yet.  The C route
  therefore remains documented and unexercised, which `README.md` and
  `README.zig.md` both state.

## 29. Two upstream tables are deliberately not installed

* Evidence: upstream's `TABDATA` is `iso3166.tab $(TZDATA_TEXT) $(ZONETABLES)`
  (`Makefile:659-660`) and its `install` rule copies the whole set into
  `$(TZDIR)` (`Makefile:713`).  Two members of that set, `leapseconds` and
  `tzdata.zi`, are *generated* by `leapseconds.awk` and
  `ziguard.awk`/`zishrink.awk` from sources this tree already ships
  (`Makefile:790-792`, `745-764`), so no file in the repository is the file to
  install.  Everything upstream ships that does exist here is installed.
* Cause: the build feeds `zic` the raw `$(TDATA)` sources directly (section 4
  above), so those two generated files are not inputs to anything this package
  does; and the library takes leap seconds from the TZif files themselves,
  which is what `TZ_RUNTIME_LEAPS=1` selects.
* Fix/constraint: a deliberate non-inclusion, recorded rather than left as a
  silent gap.  `package.nix` and `devenv.nix` do not add an awk dependency: an
  awk host dependency on every packaging variant and every target's build, to
  produce two human-readable text files nothing reads, would also make the
  derivation's closure depend on which awk the builder happens to have.
* Affects: the install tree of both linkages, and any consumer that expected
  upstream's complete `TABDATA` beside the TZif files.
* Rule: "upstream installs it, so we should too" is not a reason when the file
  does not exist in the tree and nothing consumes it.  Record the omission and
  its reason; if it is wanted later, the honest route is a build-graph step,
  not an interpreter added to `nativeBuildInputs`.
* Verification: source inspection of `Makefile` and of the current
  `build.zig`'s `table_sources`.  Neither file has been generated.

## 30. The consumer could not see the release string, and `-Dtz-dir` cannot be forwarded at all

* Evidence: the `consumer` step forwarded `-Dtarget`, `-Dcpu`, `-Doptimize`,
  `-Dlinkage`, `-Druntime`, `--cache-dir`, `--prefix` and `--`, and
  `consumer/build.zig` declared `linkage` and `runtime` alone.  So
  `zig build -Dtz-version=2026f consumer` compiled this graph's `version.h` and
  pkg-config `Version` from `2026f` and then ran a consumer whose dependency had
  resolved its own default; `consumer/src/main.zig:169` prints
  `tzdata.version()`, so the consumer reports a release the enclosing build did
  not configure.
* Cause: the forwarded set was assembled from what a nested build can be told,
  and the release string was not on it.  It was not obvious that it can be
  told, because the option name contains a dash.
* Fix/constraint: `consumer/build.zig` declares `-Dtz-version` and records it in
  the dependency's argument map, and the parent step hands on the value this
  graph resolved.  The field is written `.@"tz-version"` because
  `b.dependency` keys its argument map by the *struct field name*
  (`std/Build.zig:421-428`) while the dependency reads that map under the option
  name it declared (`std/Build.zig:1167-1168`): a `.tz_version` field would be
  recorded under a name no `b.option` call asks for, the dependency would fall
  back to its own default, and `validateUserInputDidItFail`
  (`std/Build.zig:1644-1652`) would refuse the graph.  `box2d/consumer` and
  `box3d/consumer` forward dashed options this way already.
  No default is copied into the consumer: the option is nullable, a `null` is
  not recorded at all (`std/Build.zig:486-492`), and the dependency resolves its
  own policy.  What the parent forwards is the string it already compiled its
  own headers and metadata from, not only the case where the caller named it -
  forwarding nothing and letting the nested build answer for itself is how the
  two graphs came to disagree.
* `-Dtz-dir` is the opposite case, and the reason it stays is not `--prefix`.  A
  dependency's install prefix is chosen by the build system and by neither
  caller: `createChild` applies `<cache>/i/<hash>` to every child
  (`std/Build.zig:336-338`, `determineAndApplyInstallPrefix`, `:708-724`), and
  `--prefix` never reaches a child.  A dependent's compiled `TZDIR` is therefore
  a directory no caller can name in advance and this graph does not publish.
  Handing this invocation's value on would not make the graphs agree: the
  consumer declares no such option, so the name would be refused
  (`std/Build.zig:1644-1652`, reached from
  `lib/compiler/build_runner.zig:487-489`), and a value that did reach the
  dependency would be rejected against the different prefix that dependency
  installs into (section 25).  `--prefix` is forwarded for another reason
  entirely: it decides where the consumer's own executable lands.
* Affects: `zig build -Dtz-version=<release> consumer` now compiles, installs
  and runs a single release.  `zig build run` inside `consumer/`, and any
  dependent that names none of the three options, are unchanged and still get
  the library's own defaults.
* Rule: an option a nested build can be told about is part of that build's
  contract; leaving one out makes the nested build answer a different question
  from the enclosing one, quietly, and both answers can end up in one
  transcript.  Where an option cannot be forwarded, record the real reason in
  the graph that declines to forward it.
* Verification: source inspection only.  No build, consumer run or Zig
  invocation has been run against this change; both `zig build
  -Dtz-version=<release> consumer` and `zig build run` in `consumer/` are
  unobserved since the edit.

## 31. The consumer step's arguments stopped at the nested build

* Evidence: the `consumer` step appended `--` and the caller's own arguments,
  and its comment named that as "where a runtime-loaded consumer reads a
  provider named on its command line".  `consumer/build.zig` gave the program
  only the zoneinfo directory and never read `b.args`, so
  `zig build -Druntime=true consumer -- --provider <path>` discarded the
  provider and the program fell through to `TZDATA_PROVIDER` and exited with
  `error.MissingProvider` (`consumer/src/main.zig:303-326`).  The equivalent
  smoke step in the same file has forwarded `b.args` since entry 14.
* Cause: the forwarding was written for the nested `zig build run` and never
  continued to the program that nested build runs.  The comment described the
  intended chain; only its first hop existed.
* Fix/constraint: `consumer/build.zig` passes `b.args` to the run step *after*
  `addDirectoryArg(zoneinfo)`, because the program reads `args[1]` as that
  directory and scans `args[2..]` for `--provider <path>`
  (`consumer/src/main.zig:143-148`, `:297-301`).  The order is not
  interchangeable: reversed, the program would open a directory named
  `--provider`.
* Affects: only the runtime-loaded consumer route, which previously could not
  name a provider on its command line at all.  The linked route is unchanged
  and still refuses a `--provider` rather than ignoring it.
* Verification: source inspection only; no consumer run has been executed since
  the edit.

## 32. Three recorded statements did not match the tree

* Evidence: (1) `build.zig`'s `manual_sources` claimed "Upstream's `install`
  rule installs exactly these (Makefile:719-721)", but that rule copies six
  pages - `newctime.3`, `newtzset.3`, `tzfile.5`, and `tzselect.8`, `zdump.8`,
  `zic.8` - and this build installs only `zic` beside the library, so the two
  pages for `tzselect` and `zdump` are a deliberate omission rather than a
  complete list.  (2) `build.zig.zon`'s comment sent the reader to "FORK-NOTES.md
  section 20" for the packaging manifest; section 20 is the legacy-variable
  entry and the packaging requirement is section 12.  (3) `flake.lock` exists in
  the tree, pinning exactly the revision `flake.nix:7` names, while `.paths`
  listed `flake.nix` without it.
* Fix/constraint: the manual-page comment states the six-page rule and why two
  pages are absent; the manifest comment points at sections 12 and 32; `.paths`
  lists `flake.lock` beside `flake.nix`, so a fetched tarball can resolve that
  input without network access.  `devenv.lock` does not exist in the tree and
  is deliberately not named - section 12 is the rule for outputs, and a missing
  entry fails at `zig fetch` rather than at the gate.
* Audit (2026-10-04): all 78 `.paths` entries exist in the tree, every one of
  the 53 files in `PROVENANCE.sha256` is named, and the only top-level tree
  entry the manifest did not name was `flake.lock` (excluding `.git`,
  `.zig-cache` and `zig-out`, which section 12 excludes by policy).  The package
  contents changed by one file, so the package hash differs from any identity
  recorded earlier.
* Rule: a citation that is right about the file it names is still wrong if the
  sentence around it is not; "exactly" is the load-bearing word and it was the
  word that failed.  Where a manifest entry points at a note, re-point it when
  the note numbering moves.
* Verification: source inspection and a file-list comparison against the tree.
  No `zig fetch`, `zig build provenance` or Nix command has been run since the
  edit.

## 33. `Tm.iso8601` trapped on values `Tm`'s own documentation admits

* Evidence: `Tm` is a publicly literal-constructible struct whose own doc
  states the field types are the widths of the C fields, not a validated range,
  and `test/conversion.zig` builds `Tm` from C-shaped fields that way.  So
  `.mon = 31` and a `utcOffset` of `minInt(i64)` are legal values, while
  `iso8601` added one to the `u5` month in place and took the offset's
  magnitude as an unsigned value: both abort with an integer overflow, in a
  method whose documentation says `error.OutOfMemory` is its only failure.
  Both panics were actually observed before the fix.
* Cause: field types used as if they carried a range.  They carry widths, and
  the same struct is constructible from whatever a C caller produced.
* Fix: widen the month before the addition and compute the offset's magnitude
  in a type that represents `minInt(i64)`.  Out-of-range values now render as
  the out-of-range strings they are - month 32 for `.mon = 31`, and
  `-2562047788015215:30` for `utcOffset = minInt(i64)`, which is
  `9223372036854775808` seconds as 2562047788015215 hours and 30 minutes, the
  widest magnitude the offset can name (`maxInt(i64)` floors to the same hours
  and minutes with a `+`) -
  rather than aborting.  The typed layer's own files (`src/root.zig`,
  `test/conversion.zig`) carry the change; this note records it.
* Affects: `Tm.iso8601` only.  The conversions, the module's other entry
  points and every native source file are unchanged.
* Rule: a documented-unvalidated field and arithmetic on it are a contract.
  Either validate the value or widen before the operation; an overflow abort in
  a formatting call is the third outcome nobody chose.
* Verification: the two panics were observed before the fix.  After it the
  month cases exit 0, all four, and both offset extremes render
  `±2562047788015215:30` and exit 0, two cases.  Each of those was observed in a
  scratch Debug consumer run rather than in the full native suite, which has
  not been run against this change.  No build, test or consumer run was
  executed while recording this note.

## 34. Every `devenv` script ran in the caller's directory, and five of them would have installed into the checkout

* Evidence: the acceptance run of 2026-10-04T17:53Z failed this SDK's
  `devenv:consumer` and `devenv:integrity` gates with
  `error: no build.zig file found, in the current directory or any parent
  directories`, while `devenv info` printed
  `DEVENV_ROOT: .../sdks/tzdata/project` - the driver's scratch project
  directory, which holds `.devenv` and `devenv.lock` and no `build.zig`, no
  `PROVENANCE.sha256` and no `consumer/`.  devenv materialises each script as
  its own generated program and runs it with the caller's cwd, so all seven
  `tz-*` execs inherited that directory; `$DEVENV_ROOT` names the same place,
  so reading it would have reproduced the failure rather than avoided it.
  Separately, five of the seven reach an install step: `zig build` is the
  delivery step, `test` and `smoke` both depend on `install_zoneinfo`
  (build.zig:1147, :1166) which publishes `<prefix>/share/zoneinfo`, and
  `consumer/build.zig:125` calls `b.installArtifact(exe)` in a build whose
  default prefix is its own `zig-out`.  With no `--prefix`, `<prefix>` is
  `<build root>/zig-out`, so `tz-build`, `tz-test` and `tz-smoke` wrote a TZif
  tree and an installed tree into the checkout - a shared network mount for
  this repository - and the two consumer routes resolved
  `consumer/zig-out` in the same tree.
* Cause: two assumptions that neither the devenv CLI nor `std.Build` makes.
  A script is not run in the package it belongs to, and an install step is not
  confined to a sandbox - `zig build` outside Nix writes where it is told, and
  by default that is the source tree.
* Fix: every exec body starts by changing into this SDK's own directory,
  taken from the module itself as `builtins.toString ./.` and quoted with
  `lib.escapeShellArg` - not from `$DEVENV_ROOT`, and not from a plain
  `${./.}` that would carry the path into the Nix store context and copy the
  whole SDK there.  `tz-build`, `tz-test`, `tz-smoke`, `tz-consumer` and
  `tz-consumer-direct` then pass `--prefix "$tz_prefix"`, where `tz_prefix` is
  `$TZDATA_PREFIX`, else `$ZIG_LOCAL_CACHE_DIR/tzdata/<script>`, else
  `$XDG_CACHE_HOME/tzdata/<script>`, else `$TMPDIR/tzdata/<script>`; a caller
  who exported none of them is told so and the script exits rather than
  installing into the checkout.  One directory per script, so two gates at once
  cannot share a prefix.  `tz-check` and `tz-provenance` take no prefix
  because neither installs anything: `check` compiles for the six targets and
  never runs the `zic` it builds (build.zig:1204-1235), and `provenance` runs
  one checker over the whole manifest.  Nothing here sets, resets or unsets a
  cache variable - all four are read, never written.
* Affects: the devenv scripts only.  `build.zig`, `consumer/build.zig`,
  `package.nix`, `flake.nix` and every source, data, test and licence file are
  unchanged, and no option, step name or default was added or removed: `-D`,
  step names and everything after `--` still reach `zig build` through `"$@"`,
  and the `-j8 --summary all` flags the workspace runs its gates with are now
  on all seven scripts, which did not carry them before.
* Rule: a shell gate has to name its own working directory and its own output
  location, because neither of them is the caller's to give it.  And a prefix
  is not a packaging detail: for this package it is what the compiled-in
  `TZDIR` is derived from (section 25), so where the prefix lands decides
  whether a built library can open a zone by plain name at all.
* Verification: none.  Nothing here has been executed: no `devenv shell`, no
  `zig build`, no consumer run and no Nix command has been run against this
  change.  The repair is source-confirmed against the driver's evidence and
  against `build.zig` and `consumer/build.zig`; the seven scripts, their
  prefixes and their self-location are unobserved until a fresh canonical
  devenv run exercises them.

## 35. The wrong-magic fixture proved length rejection, not magic validation

* Condition and evidence — SOURCE-CONFIRMED: the removed fork test changed
  the header signature to `XXXX` but wrote only 44 bytes.  Its header declared
  `typecnt = 2` and `charcnt = 4`; `localtime.c:1093-1102` computes a 16-byte
  data block and requires 60 bytes overall, so the fixture is truncated even
  with the correct signature.
* Cause: a malformed fixture violated both the claimed property and an
  earlier native length check.  The loader inherits native count and
  data-block bounds checks, not a `TZif`-magic validation contract.
* Fix: remove the bogus test outright.  Do not rename or repin it as a
  truncation test.  State the actual `Zone.open` boundary in README.zig.md;
  retain the legitimate native bounds, conversion, offset and leap tests.
* Constraint and targets bound: no extra Zig validator and no native parsing
  patch; the native parsing semantics remain unchanged on every target.
* Rule: a rejection test must distinguish its named defect from earlier
  checks.  A length accident cannot establish signature validation.
* Verification — PENDING-VERIFICATION: no build, test or probe was run here.
  The driver's scratch-only 54-byte `XXXX` fixture and equally sized `TZif`
  control must check the epoch-zero UTC result, not merely a live handle.
  Do not preserve either as a permanent acceptance pin.

## 36. A nested consumer must inherit the enclosing compiler configuration

* Condition and evidence — SOURCE-CONFIRMED: the root consumer step creates
  a second `zig build run`.  Its existing target query, CPU, optimize,
  linkage, runtime, release, local-cache, prefix and trailing-argument
  forwarding did not include the global cache or enabled executors.
* Cause: the nested compiler process resolves its own runner configuration
  unless the enclosing build hands it on explicitly.
* Fix: inherit the global cache using two-token `--global-cache-dir`, retain
  the separate local `consumer` cache, add `-j8 --summary all`, and forward
  enabled `-fdarling`, `-fqemu`, `-frosetta`, `-fwasmtime`, `-fwine` and
  `--libc-runtimes`.  Existing resolved SDK choices and arguments after `--`
  are preserved.
* Constraint and targets bound: preserve the always-`run` policy.  Executor
  forwarding does not establish executor availability or runtime coverage.
  No system-library mode or extra consumer option is introduced.
* Rule: a separate compiler invocation must receive the actual resolved
  configuration, not silently resolve its own cache and execution choices.
* Verification — PENDING-VERIFICATION: no build, consumer or foreign run was
  executed by this worker.  The driver owns the configuration and execution
  gates after all source writers freeze.

## 37. The consumer step asked a foreign target to run

* Condition and evidence — SOURCE-CONFIRMED: the root consumer step spelled
  `"run"` into its `addSystemCommand` literal, so the nested build was told to
  execute a target binary whatever this host could actually do.  § 36 preserved
  that always-`run` policy deliberately; this entry changes it.
* Cause: the sub-command was never derived from host capability.  Forwarding
  `-fqemu` and friends makes an executor reachable; it does not establish that
  one is installed.
* Fix: the token is now `run` when this host can execute the resolved target and
  `install` when it cannot, chosen by `hostCanExecute` (`build.zig`), which
  asks `std.zig.system.getExternalExecutor` — the predicate
  `std.Build.Step.Run` itself uses about the binary it is about to spawn — and
  carries the same switches `Run` gates its answer on.  Every resolved option,
  the executor forwarding, the caches, the prefix, `-j8 --summary all` and the
  arguments after `--` are unchanged.
* Targets bound: all nested consumer configurations.  A foreign target with no
  enabled executor now builds and installs instead of running; that is compile
  evidence and nothing more, and an installed file is `INSTALL_ONLY`.
* Known limit, unchanged by this entry: under `-Druntime=true` the dependency's
  library is not linked, so the TZif tree is not published through this edge and
  the install delivers the executable alone.  That is a pre-existing property of
  the graph; no install edge was added here.
* Verification — PENDING-VERIFICATION: no build, consumer run or foreign
  execution was run by this worker.  The driver owns the before/after gates.