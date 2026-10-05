# Upstream source

| Field | Value |
| --- | --- |
| Canonical repository | https://github.com/eggert/tz.git |
| Upstream remote name in this clone | `origin` (unmodified) |
| Release tag | `2026e` (annotated tag object `db07415c7da0359ae355fd4bee3c016b72b7dc14`) |
| Commit | `039ef27cc5f062a2055cb67435d6d71adbefd27d` |
| Commit subject | `Release 2026e` |
| Commit date | Tue Sep 29 17:14:38 2026 -0700 |
| Import | Full `git clone` of upstream; complete history and tags preserved |
| Branch | `main`, created at the commit above |

Upstream `main` was one commit ahead of the release tag at import time
(`bec4d95af5bc600df799bdec8964a4c78e9b57b3`); this fork deliberately pins the
released tag rather than the moving branch.

Upstream's own licence record is the `LICENSE` file plus the per-file notices
inside the files themselves; `NOTICE.md` is this fork's inventory of both, and
`FORK-LICENSE.md` is the record for the files this fork authors.

## The README split

Upstream ships a `README`, not a `README.md`.  That file is preserved here
byte for byte as **`README.upstream.md`**, and it is the only copy of upstream's
text: nothing in it was rewritten, re-wrapped or annotated.

| Path | What it is |
| --- | --- |
| `README` | upstream's own file, unchanged; SHA-256 `38b3f33eaddff624727c5bb238542bf448b1b5f446a31085c1ce34942819d328` in `PROVENANCE.sha256` |
| `README.upstream.md` | the same bytes as `README`, so the fork's documentation set does not shadow upstream's |
| `README.md` | this fork's entry point: native-source deviations, native-build deviations, the build/run/test matrix, consumption |
| `README.zig.md` | the Zig interface: commands, module API, ownership, symbol isolation, where the data is, platform notes |

`README.upstream.md` carries no SPDX header, and neither does `.gitignore`,
because both must stay byte-identical to what `PROVENANCE.sha256` records.

## What this fork adds

No upstream source file was modified except `.gitignore` (see `NOTICE.md` § 6).
Everything the fork adds lives in paths upstream does not use:

| Path | Purpose |
| --- | --- |
| `build.zig`, `build.zig.zon` | Zig 0.16 build of the C sources, `zic` and the database |
| `include/tzdata.h` | Aggregate public header fed to `addTranslateC` |
| `src/root.zig` | Public module `tzdata`: typed facade plus `pub const c` |
| `src/tzdata_version.c` | Linkable accessors for upstream's static version strings |
| `src/smoke.zig` | Deterministic example, run by `zig build smoke` |
| `test/` | Behavioural tests, including zic/TZif interoperability |
| `consumer/` | Separate package depending on `..` through `b.dependency` |
| `tools/provenance_check.zig` | Licence and provenance integrity gate: the recorded upstream hashes, plus that `README.upstream.md` is still the preserved copy of upstream's `README` |
| `PROVENANCE.sha256` | SHA-256 of every preserved upstream file |
| `.github/workflows/ci.yml` | Verification workflow for this fork |
| `README.md` | Fork entry point |
| `README.upstream.md` | Upstream `README`, preserved byte for byte |
| `README.zig.md` | Zig interface documentation |
| `CHANGELOG.md`, `FORK-NOTES.md`, `NOTICE.md`, `UPSTREAM.md`, `FORK-LICENSE.md` | Provenance, licensing and issue record |
| `package.nix` | One injected function returning one derivation; `linkage` selects the variant at the call sites |
| `flake.nix` | `packages.<system>.static` and `.shared`, `default` = `static` |
| `flake.lock` | The nixpkgs lock `flake.nix` names, listed in `.paths` so a fetched tarball resolves that input |
| `devenv.nix`, `devenv.yaml`, `.envrc` | Canonical development environment: tools in `packages`, lazy `outputs.static` / `outputs.shared` over the same `package.nix` |

`flake.lock` is the only lock in this tree, and it ships with the package:
`.paths` names it beside `flake.nix`, so a fetched tarball resolves the pinned
input without network access.  `devenv.lock` does not exist here and nothing
names it; `devenv.yaml` pins `cachix/devenv-nixpkgs`, a different input, and
says that lock belongs to the driver.  See `FORK-NOTES.md` § 32.

## Synchronising with a newer upstream release

```sh
git remote -v                 # origin is upstream, downstream is this fork
git fetch origin --tags
git checkout main
git merge <new-tag>           # conflicts should be limited to .gitignore
zig build check               # parent-owned verification, see README.md
```

After a new upstream release, update the `-Dtz-version` default in
`build.zig`, `TZDATA_UPSTREAM_RELEASE` in `devenv.nix`, and the version in
`package.nix`, regenerate the manifest from the upstream commit's own tree -
not from this repository's `git ls-files`, which now lists fork files as well -
and record the change in `CHANGELOG.md`:

```sh
git ls-tree -r --name-only 039ef27cc5f062a2055cb67435d6d71adbefd27d \
  | grep -v '^\.gitignore$' | sort | xargs sha256sum > PROVENANCE.sha256
```

The upstream commit has 54 tracked files; all but `.gitignore` are unchanged,
which is the 53 the manifest records.

The upstream `README` also has to be re-preserved: copy the new `README` over
`README.upstream.md` unchanged, and add the new digest to the record in
`README.md`.