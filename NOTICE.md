# NOTICE

## Upstream material

This repository is the Time Zone Database distribution by Paul Eggert, imported
verbatim from https://github.com/eggert/tz.git at tag `2026e`
(commit `039ef27cc5f062a2055cb67435d6d71adbefd27d`).

The upstream `LICENSE` file states:

> Unless specified below, all files in the tz code and data (including this
> LICENSE file) are in the public domain.
>
> If the files date.c, newstrftime.3, and strftime.c are present, they contain
> material derived from BSD and use the BSD 3-clause license.

That distinction is preserved here:

* **Public domain** — the data files, `localtime.c`, `asctime.c`,
  `difftime.c`, `zic.c`, `zdump.c`, `date.c` except where noted, `private.h`,
  `tzfile.h`, the manual pages, the web pages and the licence file itself.
  Public-domain dedication is by Arthur David Olson, as stated in each file
  and in `README`.
* **BSD 3-clause** — `strftime.c`, `date.c` and `newstrftime.3` contain
  material copyright 1989 The Regents of the University of California.  Their
  redistribution terms are reproduced in the files themselves and remain in
  force for this repository and for anything built from it.

Upstream asks that improvements to the data be sent back to the project; that
request is unchanged for the upstream files, which this fork does not edit.

## Modifications made by this fork

* `.gitignore` — appended re-inclusion rules for the Zig package, its tests,
  fixtures, tools and CI.  Upstream content:
  `sha256 8607841b6e6f8525f49013d9592a32775d412e0a6e80ec6510f4d786493cb36b`.
* Everything listed in the "What this fork adds" table of `UPSTREAM.md` is new
  work.  `include/tzdata.h` transcribes the externally visible declarations of
  `private.h` (public domain) and includes `tzfile.h` (public domain) rather
  than copying it.
* No upstream `.c` or `.h` file, no data file and no manual page was changed.
  `PROVENANCE.sha256` records the SHA-256 of all 53 preserved upstream files
  and is checked by `zig build provenance`.

## Build configuration is not a source modification

The fork compiles the unmodified upstream sources with preprocessor options
that upstream documents in its own `Makefile` (HAVE_*, USG_COMPAT, TM_GMTOFF,
and friends), plus `-Dtime_tz=time_t`, upstream's documented private-time_t
mode.  See `README.zig.md` for the full list and the reason for each value.