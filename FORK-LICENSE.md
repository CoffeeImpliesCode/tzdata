# Licence of this fork's own additions

The licence of files **this fork adds**, as distinct from the upstream tz
distribution it ships.  Upstream's terms are in `LICENSE` and are inventoried
per file in `NOTICE.md`; they are not restated as a grant here.

## 1. Owner authorization

The repository owner directly authorized a per-project licence for
fork-authored additions, chosen to match the project's upstream terms where
appropriate.  Records written before that authorization described the earlier
state, not the grant now in force.

## 2. The grant

`SPDX-License-Identifier: Unlicense`

The fork-authored files listed in `UPSTREAM.md` are dedicated to the public
domain, with the Unlicense as the instrument.  Granted by the repository
owner; no individual is named as holder.

```
This is free and unencumbered software released into the public domain.

Anyone is free to copy, modify, publish, use, compile, sell, or
distribute this software, either in source code form or as a compiled
binary, for any purpose, commercial or non-commercial, and by any
means.

In jurisdictions that recognize copyright laws, the author or authors
of this software dedicate any and all copyright interest in the
software to the public domain. We make this dedication for the benefit
of the public at large and to the detriment of our heirs and
successors. We intend this dedication to be an overt act of
relinquishment in perpetuity of all present and future rights to this
software under copyright law.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

For more information, please refer to <https://unlicense.org/>
```

Facts about the scope, stated once:

* It covers only files this fork authored.  It does not re-grant, change,
  waive or extend any upstream file's terms, and attributes nothing to
  upstream's authors.
* Upstream uses no SPDX identifier; `Unlicense` is the SPDX form used for the
  fork's own files, because SPDX carries no bare public-domain identifier.
* Per-file upstream exceptions are untouched.  `strftime.c` — a source file
  of `libtz` — is BSD-3-Clause; `date.c` and `newstrftime.3` are BSD-3-Clause
  and ship as preserved upstream material.  See `NOTICE.md` § 2.

## 3. SPDX identifier by path

| Path | SPDX identifier |
| --- | --- |
| `build.zig`, `build.zig.zon` | `Unlicense` |
| `include/tzdata.h` | `Unlicense`; content transcribed from public-domain `private.h` |
| `src/*.zig`, `test/*.zig`, `consumer/**/*.zig`, `tools/*.zig` | `Unlicense` |
| `README.md`, `README.zig.md`, `CHANGELOG.md`, `NOTICE.md`, `UPSTREAM.md`, `FORK-NOTES.md`, `FORK-LICENSE.md` | `Unlicense` |
| `package.nix`, `flake.nix`, `devenv.nix`, `devenv.yaml`, `.envrc` | `Unlicense` |
| `.github/workflows/ci.yml` | `Unlicense` |
| `PROVENANCE.sha256` | `Unlicense`; a manifest of hashes, not upstream material |
| `README.upstream.md`, `.gitignore` | **no header** — both must stay byte-identical to what `PROVENANCE.sha256` records |
| every other file | see `NOTICE.md` |

## 4. Redistribution

Upstream's obligations travel with the source: the BSD-3-Clause notice and
disclaimer for `strftime.c`, `date.c` and `newstrftime.3`, in a binary
distribution as well as a source one.  Upstream `LICENSE` is installed
unmodified next to this record, and `NOTICE.md` is the per-file inventory.