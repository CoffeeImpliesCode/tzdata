# NOTICE

The Time Zone Database by Paul Eggert was imported from <https://github.com/eggert/tz.git>, release `2026e`, commit `039ef27cc5f062a2055cb67435d6d71adbefd27d`. Upstream's `LICENSE` is preserved unmodified and states:

> Unless specified below, all files in the tz code and data (including
> this LICENSE file) are in the public domain.
>
> If the files date.c, newstrftime.3, and strftime.c are present, they
> contain material derived from BSD and use the BSD 3-clause license.

| Upstream path | Licence and attribution |
| --- | --- |
| `strftime.c` | BSD-3-Clause; Copyright 1989 The Regents of the University of California; compiled into `libtz` |
| `date.c` | BSD-3-Clause; Copyright 1985, 1987, 1988 The Regents of the University of California; not built |
| `newstrftime.3` | BSD-3-Clause; Copyright 1989, 1991 The Regents of the University of California; derived from software contributed to Berkeley by the American National Standards Committee X3, on Information Processing Systems; manual only |
| Public domain; Arthur David Olson, 1996-06-05 | `asctime.c`, `difftime.c`, `localtime.c`, `private.h`, `time2posix.3`, `tzfile.5`, `tzfile.h` |
| Public domain; Arthur David Olson, 2009-05-17 | `zdump.c`; data `africa`, `antarctica`, `asia`, `australasia`, `backward`, `etcetera`, `europe`, `factory`, `northamerica`, `southamerica`; tables `zone.tab`, `iso3166.tab`; manuals `date.1`, `newctime.3`, `newtzset.3`, `tzselect.8`, `zdump.8`, `zic.8`; `Makefile`, `workman.sh`; `README` (preserved as `README.upstream.md`), `calendars`, `theory.html`, `tz-art.html`, `tz-link.html` |
| Public domain; Arthur David Olson, 2006-07-17 | `zic.c` |
| Public domain; Bill Seymour, 2015-10-20 | `tz-how-to.html` |
| Public domain; Paul Eggert, undated | `checklinks.awk`, `checknow.awk`, `checktab.awk`, `ziguard.awk`, `zishrink.awk`, `tzselect.ksh` |
| Public domain by `LICENSE`; no individual attribution | `LICENSE`, `CONTRIBUTING`, `NEWS`, `zone1970.tab`, `zonenow.tab`, `leapseconds.awk`, `leap-seconds.list`, `backzone`; `leap-seconds.list` also carries the NIST/IERS public-domain notice |
| Public domain by `LICENSE`; no notice in file | `SECURITY` |

The table covers all 53 unchanged upstream files in `PROVENANCE.sha256`: three BSD-3-Clause files, 49 files with their own public-domain notice, and `SECURITY`, which has none. The BSD notice in `strftime.c` applies to binaries containing `tz_strftime`; redistributors must retain its copyright, conditions and disclaimer and reproduce them in binary documentation. The full BSD texts remain in their respective upstream files.

The Unlicense grant in `FORK-LICENSE.md` covers fork-authored files: `build.zig`, `build.zig.zon`, `include/tzdata.h`, `src/`, `test/`, `consumer/`, `tools/`, `PROVENANCE.sha256`, `README.md`, `README.zig.md`, `CHANGELOG.md`, `NOTICE.md`, `UPSTREAM.md`, `FORK-NOTES.md`, `FORK-LICENSE.md`, `package.nix`, `flake.nix`, `devenv.nix`, `devenv.yaml` and `.envrc`. It does not re-grant upstream material. `README.upstream.md` is the unchanged upstream `README` and is outside that grant. `.gitignore` retains upstream patterns with fork-specific exclusions; it is modified, has no SPDX header and is not in `PROVENANCE.sha256`.
