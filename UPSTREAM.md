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

## What this fork adds

No upstream source file was modified except `.gitignore` (see NOTICE.md).
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
| `tools/provenance_check.zig` | Licence and provenance integrity gate |
| `PROVENANCE.sha256` | SHA-256 of every preserved upstream file |
| `.github/workflows/ci.yml` | Verification workflow for this fork |

## Synchronising with a newer upstream release

```sh
git remote -v                 # origin is upstream, downstream is this fork
git fetch origin --tags
git checkout main
git merge <new-tag>           # conflicts should be limited to .gitignore
zig build check               # parent-owned verification, see README.zig.md
```

After a new upstream release, update the `-Dtz-version` default in
`build.zig`, regenerate `PROVENANCE.sha256` with
`git ls-files | grep -v '^\.gitignore$' | sort | xargs sha256sum > PROVENANCE.sha256`,
and record the change in `CHANGELOG.md`.