# Fork licence

This grant covers only fork-authored files listed in `UPSTREAM.md`. The repository owner authorized it; no individual holder is named. Upstream terms remain in the unmodified `LICENSE` and are inventoried in `NOTICE.md`.

`SPDX-License-Identifier: Unlicense`

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

Not covered: upstream `strftime.c` (`libtz` source), `date.c`, and `newstrftime.3` (BSD-3-Clause); upstream's unchanged `README.upstream.md`. `.gitignore` is upstream with fork exclusions; modified, without SPDX header, and absent from `PROVENANCE.sha256`.

## SPDX by path

`Unlicense`: `build.zig`, `build.zig.zon`, `include/tzdata.h`, `src/*.zig`, `test/*.zig`, `consumer/**/*.zig`, `tools/*.zig`; `README.md`, `README.zig.md`, `CHANGELOG.md`, `NOTICE.md`, `UPSTREAM.md`, `FORK-NOTES.md`, `FORK-LICENSE.md`; `package.nix`, `flake.nix`, `devenv.nix`, `devenv.yaml`, `.envrc`, `PROVENANCE.sha256`.

`include/tzdata.h` is transcribed from public-domain `private.h`; `PROVENANCE.sha256` is a fork-authored hash manifest, not upstream material. Other files' terms are in `NOTICE.md`.
