# NOTICE

Redistribution terms travel with this repository.  This file is the per-file
inventory: what each upstream file is under, where that statement is written,
and which files reach a binary.  The fork's own files are under a different
grant, recorded in `FORK-LICENSE.md`.  Nothing here re-grants, widens or
narrows an upstream term.

## 1. Upstream licensing, as stated in `LICENSE`

This repository is the Time Zone Database distribution by Paul Eggert, imported
from <https://github.com/eggert/tz.git> at tag `2026e`, commit
`039ef27cc5f062a2055cb67435d6d71adbefd27d`.  `LICENSE` is preserved
unmodified and says, in full:

> Unless specified below, all files in the tz code and data (including
> this LICENSE file) are in the public domain.
>
> If the files date.c, newstrftime.3, and strftime.c are present, they
> contain material derived from BSD and use the BSD 3-clause license.

Two tiers, therefore: **public domain** for everything else, and
**BSD-3-Clause** for three named files.  This fork edits neither the tier nor
the files.  The rest of this file is the per-file detail the blanket sentence
hides.

## 2. BSD-3-Clause files — the only exceptions

Three files, named by `LICENSE` itself.  Each carries its own full BSD
3-clause grant in its own text; the line ranges below are that grant.

| File | Grant location | Copyright | Compiled into a binary? |
| --- | --- | --- | --- |
| `strftime.c` | `strftime.c:3-28` | Copyright 1989 The Regents of the University of California | **Yes** — a source file of `libtz` |
| `date.c` | `date.c:3-28` | Copyright 1985, 1987, 1988 The Regents of the University of California | No — preserved source only; this build has no `date` program |
| `newstrftime.3` | `newstrftime.3:4-33` (roff-escaped) | Copyright 1989, 1991 The Regents of the University of California; "derived from software contributed to Berkeley by the American National Standards Committee X3, on Information Processing Systems" | No — manual page |

Consequences, stated plainly:

* Because `strftime.c` is a source file of `libtz`, every binary this fork
  builds that includes `tz_strftime` inherits the BSD 3-clause obligation.
  Redistribution must retain the copyright notice, the conditions and the
  disclaimer, and a **binary** distribution must reproduce them in its
  documentation.  This is the only per-file upstream obligation that reaches
  a shipped artifact.
* The BSD 3-clause notice is the file's own text.  This repository does not
  copy it into `LICENSE`, does not append it to `LICENSE`, and does not
  relabel `LICENSE`; the file keeps the terms where upstream put them.

## 3. Public-domain files carrying their own dedication

Each of these states the public-domain status inside the file.  "Clarified by"
names the person upstream credits and the date upstream gives.

| Dedicator and date | Files (line of the notice) |
| --- | --- |
| Arthur David Olson, 1996-06-05 | `asctime.c:4-5`, `difftime.c:4-5`, `localtime.c:4-5`, `private.h:8-9`, `time2posix.3:1-2`, `tzfile.5:1-2`, `tzfile.h:8-9` |
| Arthur David Olson, 2009-05-17 | **C sources and tools:** `zdump.c:4-5`.  **Zone source data, the `$(TDATA)` this build compiles:** `africa:3-4`, `antarctica:3-4`, `asia:3-4`, `australasia:3-4`, `backward:3-4`, `etcetera:3-4`, `europe:3-4`, `factory:3-4`, `northamerica:3-4`, `southamerica:3-4`.  **Tables:** `zone.tab:3-4`, `iso3166.tab:3-4`.  **Manual pages:** `date.1:1-2`, `newctime.3:1-2`, `newtzset.3:1-2`, `tzselect.8:1-2`, `zdump.8:1-2`, `zic.8:1-2`.  **Build input:** `Makefile:2-3`, `workman.sh:4-5`.  **Documentation:** `README:53-54` (preserved as `README.upstream.md:53-54`), `calendars:146-147`, `theory.html:1591-1592`, `tz-art.html:629-630`, `tz-link.html:1261-1262` |
| Arthur David Olson, 2006-07-17 | `zic.c:4-5` |
| Bill Seymour, 2015-10-20 | `tz-how-to.html:670-671` |
| Paul Eggert, undated | `checklinks.awk:3`, `checknow.awk:3`, `checktab.awk:3`, `ziguard.awk:3`, `zishrink.awk:3`, `tzselect.ksh:9` |
| unattributed, undated | `LICENSE:1-5` (the blanket dedication quoted in § 1), `CONTRIBUTING:105`, `NEWS:6892`, `zone1970.tab:3`, `zonenow.tab:3`, `leapseconds.awk:3`, `leap-seconds.list:50` (the NIST/IERS file's own "COPYRIGHT STATUS OF THIS FILE"), `backzone:3` |

That is all 53 files in `PROVENANCE.sha256`: 3 under BSD-3-Clause, 49 with a
dedication of their own, and 1 - `SECURITY` - with none.

`leap-seconds.list` is a NIST/IERS input redistributed by upstream; its own
header already places it in the public domain, and `leapseconds.awk:21-24`
generates an equivalent notice into its output.  Upstream's `NEWS:766-768`
records the same fact for the leap-second data.

## 4. Public-domain files with no notice of their own

One file in the recorded upstream set carries no licence statement anywhere in
it:

* `SECURITY` — a vulnerability-reporting contact note.  It is public domain by
  `LICENSE`'s blanket sentence, not by anything it says itself.

This matters because the blanket sentence is the only source for it: a reader
who greps for a notice in `SECURITY` finds nothing and must read `LICENSE` to
learn its terms.

Everything else in the recorded set appears in § 2 or § 3.

## 5. What is compiled, what is installed

| Artifact | Sources | Terms that travel with it |
| --- | --- | --- |
| `lib/libtz.a`, or the shared object (`lib/libtz.so`, `lib/libtz.dylib`, `tz.dll` + `tz.lib`) | `localtime.c`, `asctime.c`, `difftime.c`, `strftime.c`, `src/tzdata_version.c` | public domain for the first two tiers, **BSD-3-Clause** via `strftime.c`; `src/tzdata_version.c` is fork-authored (`FORK-LICENSE.md`) |
| `bin/zic` | `zic.c`, plus the generated `version.h` and `tzdir.h` | public domain (`zic.c:4-5`); the generated headers are fork-authored |
| `lib/pkgconfig/tzdata.pc` | generated by `build.zig` from the same macro set the C compiler was given | fork-authored; it is metadata, and the macros it names are described in § 3 |
| `include/tzdata.h` | fork-authored; transcribes declarations from `private.h` and `#include`s `tzfile.h` | fork grant; its content derives from public-domain `private.h` |
| `include/tzfile.h` | upstream, unmodified | public domain (`tzfile.h:8-9`) |
| `share/zoneinfo/**` | TZif files compiled by `zic` from the upstream zone sources | public domain; the compiled form carries no separate licence |
| `share/zoneinfo/iso3166.tab`, `zone.tab`, `zone1970.tab`, `zonenow.tab` | upstream tables, installed unmodified | public domain; see `iso3166.tab:3-4`, `zone.tab:3-4`, `zone1970.tab:3`, `zonenow.tab:3` |
| `share/man/man3/newctime.3`, `man3/newtzset.3`, `man5/tzfile.5`, `man8/zic.8` | upstream manual pages, installed unmodified | public domain (`newctime.3:1-2`, `newtzset.3:1-2`, `tzfile.5:1-2`, `zic.8:1-2`) |
| `share/licenses/tzdata/**` | § 7 below | each file keeps its own terms |
| not built: `zdump` | `zdump.c` is present but **no build step compiles it**, so no `zdump` binary is installed; `date.c` and `tzselect.ksh` likewise | public domain by § 3, but not a shipped artifact |

The zone data is data, not code, but it is licensed by its own file the same
way: every source file `zic` reads is in § 3 or § 4 above.

## 6. Files this fork authors

Recorded in full in `FORK-LICENSE.md` § 4.  In short: `build.zig`,
`build.zig.zon`, `include/tzdata.h`, `src/`, `test/`, `consumer/`, `tools/`,
`PROVENANCE.sha256`, `.github/workflows/ci.yml`, the documentation set
(`README.md`, `README.upstream.md`, `README.zig.md`, `CHANGELOG.md`,
`NOTICE.md`, `UPSTREAM.md`, `FORK-NOTES.md`, `FORK-LICENSE.md`) and the Nix,
flake and devenv packaging (`package.nix`, `flake.nix`, `devenv.nix`,
`devenv.yaml`, `.envrc`) are dedicated to the public domain under the
Unlicense, on the owner's direct authorization recorded in `FORK-LICENSE.md`
§ 1.

The single upstream file this fork changes is `.gitignore`, which keeps all of
upstream's patterns and appends negations for the fork's own paths.  Its
upstream content is recorded here and in `CHANGELOG.md` entry 1 as
`8607841b6e6f8525f49013d9592a32775d412e0a6e80ec6510f4d786493cb36b`.  That
digest is a prior record, not a gate result: `PROVENANCE.sha256` covers the 53
files that are unchanged, and `.gitignore` is not among them because it is
changed.  It carries no SPDX header either, because adding one would change
an upstream file further.

## 7. Where the licence material is installed

`build.zig` installs this material for every linkage, so a plain
`zig build install` and a Nix output carry the same four files.  Relative to
the install prefix:

```
share/licenses/tzdata/LICENSE        # upstream, unmodified
share/licenses/tzdata/NOTICE.md     # this file
share/licenses/tzdata/FORK-LICENSE.md
share/licenses/tzdata/UPSTREAM.md
```

Under Nix those paths are `$out/share/licenses/tzdata/…`.  `package.nix`
deliberately does not reinstall them: the build graph already writes those four
paths, and a second `install` of the same bytes from a second place risks a
collision rather than adding redundancy.

`strftime.c` is not copied into the output: its BSD-3-Clause text travels
inside the compiled library, and § 2 above is the record of which artifact it
reached.

## 8. Build configuration is not a source modification

The fork compiles the unmodified upstream sources with preprocessor options
that upstream documents in its own `Makefile` and `private.h` (`HAVE_*`,
`SUPPORT_POSIX2008`, `USG_COMPAT`, `TM_GMTOFF`, and friends), plus
`-Dtime_tz=time_t`, upstream's documented private-`time_t` mode.  No upstream
`.c` or `.h` file, no data file, no manual page and no licence file was
changed.  `PROVENANCE.sha256` records the SHA-256 of all 53 preserved
upstream files and is checked by `zig build provenance`.

## 9. Terms of the exported provider surface

The exported surface carries the terms of the sources it is compiled from:

| Surface | Source | Terms |
| --- | --- | --- |
| reentrant `tz_tzalloc`, `tz_tzfree`, `tz_localtime_rz`, `tz_mktime_z`; X3J11 and POSIX families; `tz_ctime`, `tz_asctime`, `tz_difftime` | `localtime.c`, `asctime.c` | public domain (§ 3) |
| `tz_strftime`, `tz_strftime_l` | `strftime.c` | **BSD-3-Clause** (§ 2) — the notice and disclaimer travel with every binary and with the installed library |
| exported data `tz_tzname`, `tz_timezone`, `tz_daylight` | `localtime.c:623-629` | public domain (§ 3) |
| `tz_asctime_r`, `tz_ctime_r` | `asctime.c` | public domain (§ 3), and emitted only under `SUPPORT_POSIX2008` |
| `tzdata_version`, `tzdata_package` | `src/tzdata_version.c` | fork grant (`FORK-LICENSE.md`) |

`tz_tzalloc` allocates with `malloc` and `tz_tzfree` releases with `free`
(`localtime.c:1976`, `:2005`), so a loaded provider's zone handles come from
that provider's allocator and are released by that provider alone.  The
load-time check in `runtime/library.zig` exercises that pairing; it establishes
nothing about the version, the rule data or any zone file, and tzcode has no
versioned ABI.