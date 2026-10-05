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
  borrowed-name ownership, and native bounds and file-open rejection.
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

## 15. Zig API contract alignment — 2026-10-03

**Condition.** `Tm.zone` has producer-dependent lifetime: Zone conversions
borrow its abbreviation storage, while UTC conversion uses static storage.
Clearing one Zone handle does not protect a copied alias.

**Fix.** State those lifetimes, reachable handle duties, unusable-after-close
state, empty-name UTC behavior and allocator/sentinel/free contracts. Complete
the module example with allocation and cleanup. Document native blocking
without a Zig cancellation channel, artifact linkage and build-local versus
deployment database paths. Preserve the existing digest without a proved
cache defect; correct conversion citations.

**Verification and bound.** Zig 0.16.0, native Linux x86-64: install,
Debug/ReleaseSafe tests, smoke, package consumer and the independent module
example pass. The example opens plain `Europe/Berlin` through a dependency,
not an explicit database path. Compile-only `check` passes. Installed database
deployment outside the build-local path and system providers are not certified.
Native source, headers and generated bindings are unchanged.

## 16. Fork contract migration: README split, licence record, Nix and devenv — 2026-10-04

**Documentation.**  The fork had no `README.md`; the only README in the tree
was upstream's `README`.  `README.upstream.md` now holds those bytes unchanged
(SHA-256 `38b3f33eaddff624727c5bb238542bf448b1b5f446a31085c1ce34942819d328`,
the digest `PROVENANCE.sha256` already records for `README`), and `README.md`
is new: native-source deviations, native-build deviations, support matrix,
consumption.  `README.zig.md` keeps the Zig interface.  Nothing upstream gains
an SPDX header; two preserved files must stay byte-identical.
`tools/provenance_check.zig` now also fails if `README.upstream.md` stops
matching upstream's `README`.

**Licence.**  `FORK-LICENSE.md` is new: the owner's direct authorization of
2026-10-04, the grant for fork-authored files (public-domain dedication under
the Unlicense), the SPDX-identifier table by path, and the statement that it
re-grants nothing upstream.  `NOTICE.md` is rewritten as a per-file inventory
— upstream's two tiers, the three BSD-3-Clause exceptions with line ranges and
copyright lines, every public-domain file with the dedicator and date it names,
`SECURITY` as the one file with no notice of its own, which sources reach
which artifact, and the install paths.

**Native delivery.**  `-Dlinkage=static|dynamic`, default `static`.
`dynamic` is a real shared object from the same four translation units with
`.pic` set on the library module; the static branch leaves `pic` alone, so the
existing static objects are unchanged.  The MS-Windows shared build gets a
module-definition file, because a COFF DLL exports nothing without one.
`check` does not fold the option in: it installs nothing, so folding it in
would make it answer a different question.

**The compiled-in `TZDIR` moved** to `<install prefix>/share/zoneinfo`, which
is also where the install step publishes the tree `zic` compiled; the
digest-named cache tree is staging only.  A `-Dtz-dir` naming anything else is
rejected at configure time with both paths printed, so the flag can no longer
produce a library that silently cannot open a zone.  `dep.module("tzdata")`
still gets a working database, now through the published tree.  See
FORK-NOTES.md § 25.

**The install tree grew:** the four upstream zone tables beside the TZif
files, the four manual pages upstream's install rule installs, the four
licence files to `share/licenses/tzdata/`, and a generated
`lib/pkgconfig/tzdata.pc` carrying the four `TZDATA_HAVE_*` macros to a C
consumer (§ 28).  `leapseconds` and `tzdata.zi` stay out — upstream derives
both with awk, so they are not files this tree can install (§ 29).  `zdump`,
`date` and `tzselect` remain unbuilt.

**Packaging.**  `package.nix` is one injected function returning one
derivation, source-only, with no `../` import, host path or build-time
download.  It passes `--prefix "$out"`, repeats
`-Dtz-dir="$out/share/zoneinfo"` as an assertion of that resolution, writes no
artifact of its own — `build.zig` owns every install path — and runs
`zig build provenance` in `checkPhase`.  `flake.nix` exposes
`packages.<system>.static` and `.shared`, `default` = `static`;
`devenv.nix` exposes the same two as lazy `outputs.static` / `outputs.shared`
over the same `package.nix`, with tools only in the shell.  `devenv.yaml` and
`.envrc` make devenv canonical.  `flake.lock` and `devenv.lock` are not added:
locks are the driver's.

**Native source, headers, data, tests and licence bytes are unchanged.**  Every
feature above is source-confirmed and ungated: no build has run against the
static/shared split, the moved `TZDIR`, the generated pkg-config file, the
devenv shell or either Nix derivation.  README.md records those as
`PENDING-VERIFICATION`; entries 14 and 15 remain the historical observed
evidence for the tree as it stood before this migration.

## 17. Consumer forwarding, install-set wording, manifest audit — 2026-10-04

**Consumer options.**  `consumer/build.zig` now declares `-Dtz-version` and
records it in `b.dependency("tzdata", ...)`, and the `consumer` step hands on
the release string this graph resolved.  `zig build -Dtz-version=<release>
consumer` therefore compiles one `version.h`, installs one pkg-config
`Version`, and runs a consumer that prints that release; before, the consumer
was linked against a dependency that resolved its own default and printed it.
The field is written `.@"tz-version"`: a dependency's argument map is keyed by
the struct field name (`std/Build.zig:421-428`) and read under the option name
the dependency declared (`std/Build.zig:1167-1168`).  No default is copied into
the consumer — the option is nullable, unset stays unset, and the library
resolves its own.  See FORK-NOTES.md § 30.

**`-Dtz-dir` is not forwarded, and `--prefix` is not the reason.**  A
dependency's install prefix is `<cache>/i/<hash>`, applied by `createChild`
(`std/Build.zig:336-338`, `:708-724`), and `--prefix` never reaches a child, so
the nested graph's compiled `TZDIR` is a directory this graph neither publishes
nor can name in advance.  Forwarding this invocation's value would be refused
as an option `consumer/build.zig` does not declare, and a value that did reach
the dependency would be rejected against that dependency's own prefix (§ 25).
The build graph now records the actual reason beside the option it declines to
forward, in place of the implied one.

**Consumer arguments now reach the program.**  `consumer/build.zig` passes
`b.args` to its run step after the zoneinfo directory argument, which is the
position `consumer/src/main.zig` reads `args[1]` and `--provider` after.
`zig build -Druntime=true consumer -- --provider <path>` dropped the provider
before: the parent forwarded `--` arguments to the nested `zig build run` and
the nested build passed none on, so a runtime-loaded consumer fell through to
`TZDATA_PROVIDER` and exited non-zero.  See FORK-NOTES.md § 31.

**Install-set wording.**  The `manual_sources` comment said upstream's
`install` rule installs "exactly these" pages.  It installs six
(`Makefile:719-721`); the two this build omits, `tzselect.8` and `zdump.8`,
document programs it does not build, so the omission is deliberate and the
claim is now stated as such.  See FORK-NOTES.md § 32.

**Manifest.**  `.paths` now also lists `flake.lock`, which exists in the tree
and pins the revision `flake.nix` names, so a fetched tarball can resolve that
input; `devenv.lock` is absent from the tree and is deliberately not named.  The
manifest's "See FORK-NOTES.md section 20" pointed at an unrelated entry and now
names sections 12 and 32.  Audited by hand on 2026-10-04: all 78 `.paths`
entries exist in the tree and all 53 files in `PROVENANCE.sha256` are named.
Package contents changed by one file, so the package hash differs from any
identity recorded earlier; identities are derived once, after the freeze.

**Native source, headers, data, tests and licence bytes are unchanged**, and
nothing has been executed against these edits: no build, test, consumer run,
`zig fetch`, provenance gate or Nix command has run since they were made, so
the forwarding, the argument pass-through and the manifest change are
source-confirmed only.  Entries 14 and 15 remain the historical observed
evidence for the tree as it stood before this migration.

## 18. Typed layer: two reachable panics removed from `Tm.iso8601` — 2026-10-04

**Condition.**  `Tm` is publicly literal-constructible and its own
documentation says its field types are the widths of the C fields rather than
a validated range, so `.mon = 31` and a `utcOffset` of `minInt(i64)` are legal
values — and `test/conversion.zig` builds `Tm` from C-shaped fields exactly
that way.  `Tm.iso8601` added one to the `u5` month in place and took the
offset's magnitude as an unsigned value, so both aborted with an integer
overflow in a method documented to fail only with `error.OutOfMemory`.

**Fix.**  The month is widened before the addition, and the offset's magnitude
is computed in a type that represents `minInt(i64)`.  Out-of-range values now
render as the out-of-range strings they are instead of trapping: month 32 for
`.mon = 31`, and `-2562047788015215:30` for `utcOffset = minInt(i64)` — that is
`9223372036854775808` seconds as 2562047788015215 hours and 30 minutes, the
widest magnitude the offset can name.  `maxInt(i64)` floors to the same hours
and minutes with a `+`.

**Verification and bound.**  Both panics were observed before the fix.  After
it the month cases exit 0, all four, and both offset extremes render
`±2562047788015215:30` and exit 0, two cases.  Each of those was observed in a
scratch Debug consumer run, not in the full native suite, which has not been
run against this change.  Nothing was executed while recording this entry.
`src/root.zig` and `test/conversion.zig` are the typed layer's own files.

## 19. The `devenv` scripts ran in the caller's directory, and would have installed into the checkout — 2026-10-04

**Condition.**  A canonical acceptance run (`nix-acceptance-20261004T175328Z`)
failed this SDK's `devenv:consumer` and `devenv:integrity` gates with
`error: no build.zig file found, in the current directory or any parent
directories`.  `devenv info` showed why: `DEVENV_ROOT` was the driver's scratch
project directory, which holds `.devenv` and `devenv.lock` and none of
`build.zig`, `PROVENANCE.sha256` or `consumer/`.  devenv generates each script
as its own program and runs it with the caller's working directory, so all
seven `tz-*` execs inherited that directory and `$DEVENV_ROOT` would have
reproduced the same failure rather than avoided it.

**A second problem the same shells carried.**  Five of the seven reach an
install step — `zig build` is the delivery step, `test` and `smoke` both
depend on the step that publishes `<prefix>/share/zoneinfo`
(`FORK-NOTES.md` § 25), and `consumer/build.zig` declares an install step for
its own executable in a build whose default prefix is `consumer/zig-out`.
Without `--prefix` the prefix is `<build root>/zig-out`, so a shell session
would write a compiled TZif tree and an installed tree into the checkout, and
the direct consumer route would resolve `consumer/zig-out` in the same tree.
This repository is a shared network mount.

**Fix.**  Every exec body now changes into this SDK's own directory first,
from `builtins.toString ./.` — the module's own path, not `$DEVENV_ROOT` and
not a plain `${./.}` that would copy the SDK into the Nix store — quoted with
`lib.escapeShellArg`.  `tz-build`, `tz-test`, `tz-smoke`, `tz-consumer` and
`tz-consumer-direct` additionally pass `--prefix` at `$TZDATA_PREFIX`, else
`$ZIG_LOCAL_CACHE_DIR/tzdata/<script>`, else `$XDG_CACHE_HOME/tzdata/<script>`,
else `$TMPDIR/tzdata/<script>`; a caller who exported none of those is told so
and the script exits rather than installing into the checkout.  Each script
gets its own directory.  `tz-check` and `tz-provenance` take no prefix because
neither installs anything, and the provenance gate is unchanged: it is still
`zig build provenance`, the one checker over all of `PROVENANCE.sha256` plus
the `README` / `README.upstream.md` relocation.  All seven now carry the
workspace's `-j8 --summary all` and forward `"$@"`, so a caller's `-D`, step
name and arguments after `--` reach the build.  No cache variable is set,
reset or unset; all four are read.  See FORK-NOTES.md § 34.

**The consumer's TZDIR is unchanged.**  `--prefix` reaches the nested build
because `build.zig` forwards it, and it decides where that build's own
executable lands (FORK-NOTES.md § 30).  A dependency's install prefix is the
build system's choice and no `--prefix` reaches it, so the run still reads the
tree that dependency published; `-Dtz-dir` is passed nowhere.

**Nothing has been executed against this change.**  No `devenv` command, no
`zig build`, no consumer run and no Nix build has run since the edit, so the
self-location, the prefixes and the forwarded arguments are source-confirmed
only.  `build.zig`, `consumer/build.zig`, `package.nix`, `flake.nix`,
`devenv.yaml` and `.envrc` are unchanged, and so are every native source,
header, data file, test and licence byte; `PROVENANCE.sha256` still describes
the tree it described.

## 20. Remove the false TZif-magic rejection claim — 2026-10-04

**Condition and cause — SOURCE-CONFIRMED.**  The fork's wrong-magic test
wrote only a 44-byte header while declaring two local-time types and four
abbreviation bytes.  Native `localtime.c:1093-1102` requires another
`2 * 6 + 4` bytes and rejects that fixture for length regardless of its magic.
The test therefore did not establish its stated magic-rejection contract.

**Fix and constraint.**  Delete that test rather than rename it into another
truncation test.  Preserve the legitimate bounds, time, offset and leap
tests.  README.zig.md now states that `Zone.open` inherits native bounds
checks, not a magic validator.  No native source change or extra validator
is introduced.

**Verification — PENDING-VERIFICATION.**  No gate was run for this correction.
The driver's scratch-only well-sized 54-byte `XXXX` fixture and `TZif`
control must check epoch-zero UTC semantics; they are not new permanent
acceptance tests.  Earlier observed results remain historical.

## 21. Nested consumer inherits cache and executor configuration — 2026-10-04

**Condition — SOURCE-CONFIRMED.**  The existing nested `zig build run`
forwarded the target query, CPU, optimize, linkage, runtime and release
choices, local cache, explicit install prefix and trailing arguments, but
not the enclosing global cache or executor configuration.

**Fix.**  `build.zig` forwards the inherited global cache with two-token
`--global-cache-dir`, retains the local cache's `consumer` subdirectory, adds
`-j8 --summary all`, and forwards enabled Darling, QEMU, Rosetta, Wasmtime and
Wine switches plus `--libc-runtimes`.  Existing resolved SDK choices,
`--prefix`, arguments after `--` and the always-`run` policy are preserved.
No system mode, consumer option or second helper framework is added.

**Verification — PENDING-VERIFICATION.**  No worker gate was executed.
The driver must exercise the nested consumer with its selected caches and
configuration, including supported foreign executors where available.
Source argument forwarding is not proof of target execution.

## 22. The 53-cell matrix in `README.md`, bounded to the source it ran against — 2026-10-05

**Condition.**  `README.md` §Support matrix said the 53-target `cross-test`
matrix "is in the same state" as the gates it lists as `PENDING-VERIFICATION`,
which is a statement that nothing had run.  An external driver has since run
it, so that sentence described a tree that no longer exists.

**Fix.**  `README.md` gains a subsection, "The source-bound 53-cell matrix and
baseline, 2026-10-04/05", recording the receipts and the exact counts:

* the 53-cell matrix, `pass 20`, `build_only 21`, `build_fail 12`, run exit 1,
  from `resume-8-evidence/20261004T221720228710Z-45046/tzdata-53-target-8.json`;
* the compile-only baseline, exit 0 and `failed: false`, from
  `baselines-and-configs/20261005T014547Z-797a73f2/receipts/baseline-tzdata-check-2026-10-05T01-46-00Z.json`
  — `check` compiles and runs nothing, so no test number is read out of it;
* 8 of 8 native cells from
  `native-final-evidence/20261004T233628757747Z-69351/run.json` and 8 of 8
  own-provider loaded cells from
  `loaded-final-evidence/20261004T232823091897Z-23133/run.json`;
* a fresh eight-cell loaded run in epoch `20261005T010426507024Z-1590`, 8 of 8
  at 31 of 31 tests each, against an **own-provider** — this SDK's own
  already-built library from a pre-existing native prefix, not a downloaded or
  independent one — with the source closure, the provider and the compiled
  zone-tree bytes held in the integration owner's record.

**The twelve red cells are this fork's own refusals and are named as such.**
Nine NetBSD cells (`aarch64-netbsd`, `aarch64_be-netbsd`, `arm-netbsd`,
`armeb-netbsd`, `mips-netbsd`, `mipsel-netbsd`, `powerpc-netbsd`, `x86-netbsd`,
`x86_64-netbsd`) stop because `zig translate-c` cannot read that libc's
`sys/cdefs.h`, and three 32-bit OpenBSD cells (`arm-openbsd`,
`powerpc-openbsd`, `x86-openbsd`) stop because the translator's `size_t` and
that libc's differ at 32 bits.  All twelve return `error.UnsupportedTarget`
from `refuseTarget` (`build.zig:903-910`) before a compiler runs, and the
section says `build_only` is compiled-not-run and is never a test pass.

**Bound.**  The matrix run predates the later build-graph, header and
normalization edits; its `source_unchanged: true` speaks only to its own run and
those edits are not claimed to be covered by it.  The section also records the
one thing the matrix does not touch: under `-Druntime=true` the dependency's
library is not linked, so the TZif tree is not published through that edge and
the consumer install delivers the executable alone.  That is the pre-existing
property recorded in `FORK-NOTES.md` § 37, unchanged by this entry and not a
new-scope fix.

**Verification — no gate.**  Nothing was built, compiled or run for this entry.
Every number is read off a receipt another gate wrote, and the refusal names
and line numbers are read off `build.zig` at this pin.  No earlier entry's
status moved, the `PENDING-VERIFICATION` rows above are unchanged, and no
native source, header, data file, licence byte or upstream test changed.
