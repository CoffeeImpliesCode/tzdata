// SPDX-License-Identifier: Unlicense
//
// Build graph for this fork of the IANA Time Zone Database.  This file is a
// fork addition and is not upstream's; the upstream files it compiles carry
// their own notices and no file here modifies one of them.  See
// FORK-LICENSE.md for the grant and NOTICE.md for the per-file inventory.

const std = @import("std");

const Build = std.Build;
const Step = std.Build.Step;
const Module = std.Build.Module;
const OptimizeMode = std.builtin.OptimizeMode;

/// The runtime route's build half, which is a fork addition and not upstream's.
/// It owns the generated dispatch and the descriptor module; this file only
/// decides which of the two configurations each target graph gets.
const graph = @import("runtime/graph.zig");

/// C sources of the tzcode core library; upstream Makefile variable LIBSRCS,
/// plus the fork's version accessor.
const lib_sources = [_][]const u8{
    "localtime.c",
    "asctime.c",
    "difftime.c",
    "strftime.c",
    "src/tzdata_version.c",
};

/// Upstream zone source data: the Makefile's `$(TDATA)`, that is
/// `$(YDATA) $(NDATA) $(BACKWARD)` with the empty default `PACKRATDATA`.
/// `zic` compiles these files directly.  That is the input list of
/// upstream's `check` target (Makefile:1208-1212), not of a stock `make`,
/// which first derives `main.zi` with `ziguard.awk`/`zishrink.awk` and
/// compiles that; see README.zig.md, "Where the data is".
const data_sources = [_][]const u8{
    "africa",
    "antarctica",
    "asia",
    "australasia",
    "backward",
    "etcetera",
    "europe",
    "factory",
    "northamerica",
    "southamerica",
};

/// Zone tables upstream installs beside the TZif files.  Upstream's `TABDATA`
/// is `iso3166.tab $(TZDATA_TEXT) $(ZONETABLES)` (Makefile:659-660) and its
/// `install` rule copies the whole set into `$(TZDIR)` (Makefile:713).  The two
/// text files in the middle of that list, `leapseconds` and `tzdata.zi`, are
/// *derived* by awk from the shipped sources (Makefile:790-792, 745-764), so
/// they are not files this tree can install; every table upstream ships that
/// exists here is listed.
const table_sources = [_][]const u8{
    "iso3166.tab",
    "zone.tab",
    "zone1970.tab",
    "zonenow.tab",
};

/// Manual pages for the programs installed below, by their man section.
///
/// Upstream's `install` rule copies six pages (`Makefile:719-721`): the two
/// man 3 pages and the man 5 file here, and in man 8 `tzselect.8`, `zdump.8`
/// and `zic.8`.  This build produces and installs only `zic` beside the
/// library, so the two pages that document `tzselect` and `zdump` -- programs
/// this package does not build -- are deliberately absent rather than
/// missed.  A page for a program nothing installs would be the only way to
/// make the set larger than what `zig build` delivers.
const manual_sources = [_]struct { section: []const u8, path: []const u8 }{
    .{ .section = "3", .path = "newctime.3" },
    .{ .section = "3", .path = "newtzset.3" },
    .{ .section = "5", .path = "tzfile.5" },
    .{ .section = "8", .path = "zic.8" },
};

/// Licence material the native build installs for every linkage.
///
/// `LICENSE` is upstream's own public-domain grant with its three
/// BSD-3-Clause exceptions named (`LICENSE:1-5`); the three Markdown files
/// are this fork's per-file inventory, grant and provenance record.  All four
/// are installed unmodified, by name, so an installed package carries its own
/// licence text rather than a pointer to the repository.
const licence_sources = [_][]const u8{
    "LICENSE",
    "NOTICE.md",
    "FORK-LICENSE.md",
    "UPSTREAM.md",
};

/// Targets compiled (never run) by "zig build check".
const check_target_queries = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .wasm32, .os_tag = .wasi },
};

const Define = struct { name: []const u8, value: []const u8 };

/// One target's macro list.
///
/// The macros are written through a method rather than a local function
/// because a nested function cannot capture `b`, and every macro below
/// needs the builder's allocator.
const Defines = struct {
    b: *Build,
    list: std.ArrayList(Define) = .empty,

    fn add(self: *Defines, name: []const u8, value: []const u8) void {
        self.list.append(self.b.allocator, .{ .name = name, .value = value }) catch @panic("OOM");
    }
};

const Core = struct {
    library: *Step.Compile,
    zic: *Step.Compile,
    c_module: *Module,
    /// The macros this core's C sources and its translations were given, so
    /// the installed pkg-config metadata describes the library that was built
    /// rather than a second, separately computed description of it.
    defines: []const Define,
    /// Whether `c_module` is a generated dispatch rather than the translated
    /// header itself.  It decides two things at once, and both have to agree:
    /// whether a module importing `c_module` may link `library`, and whether
    /// it needs the loader core under the name `rt`.
    runtime_loaded: bool,
};

/// Preprocessor configuration for one target.
///
/// Every entry corresponds to a macro documented in the upstream Makefile or
/// in private.h; the comment gives the reason for the value.  Macros that
/// private.h can detect by itself are deliberately left alone.
fn cDefines(b: *Build, target: Build.ResolvedTarget) []const Define {
    var defines: Defines = .{ .b = b };

    // -DHAVE_GETTEXT=0: never require libintl on any target.
    defines.add("HAVE_GETTEXT", "0");
    // -DPORT_TO_C89=0: require C99 or later.
    defines.add("PORT_TO_C89", "0");
    // SUPPORT_C89=1 is upstream's default; keep C89 callers working.
    defines.add("SUPPORT_C89", "1");
    // NETBSD_INSPIRED/STD_INSPIRED=1: expose tzalloc/tzfree/localtime_rz/
    // mktime_z and the X3J11-inspired set, as upstream does on NetBSD.
    defines.add("NETBSD_INSPIRED", "1");
    defines.add("STD_INSPIRED", "1");
    defines.add("TZ_RUNTIME_LEAPS", "1");
    // The Windows and WASI libcs also declare mempcpy; upstream's
    // platform heuristic predates these header sets.
    // -DHAVE_GETRANDOM=0: zic's clock/pid entropy fallback.
    defines.add("HAVE_GETRANDOM", "0");
    defines.add("HAVE_UTMPX_H", "0");
    defines.add("HAVE_SNPRINTF", "1");
    defines.add("HAVE_STRDUP", "1");
    defines.add("HAVE_POSIX_DECLS", "1");
    defines.add("HAVE_SYS_STAT_H", "1");
    defines.add("HAVE_UNISTD_H", "1");
    defines.add("HAVE_STRUCT_TIMESPEC", "1");
    defines.add("HAVE_MALLOC_ERRNO", "1");
    // -Dtime_tz=time_t: upstream's documented private-time_t mode, which
    // renames every externally visible identifier to tz_* and therefore keeps
    // this library from shadowing libc's localtime/mktime/tzname/timezone/
    // daylight/strftime.  See README.zig.md, "Symbol isolation".
    defines.add("time_tz", "time_t");

    switch (target.result.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => {
            defines.add("HAVE_FCHMOD", "1");
            defines.add("HAVE_LINK", "1");
            defines.add("HAVE_SYMLINK", "1");
            defines.add("HAVE_PWD_H", "1");
            defines.add("HAVE_STRFTIME_L", "1");
            defines.add("HAVE_STRUCT_STAT_ST_CTIM", "1");
            // private.h derives SUPPORT_POSIX2008 from
            // `_POSIX_VERSION <= 200809`; state it, so the aggregate header
            // gates tz_asctime_r and tz_ctime_r on the same value the C
            // compiler gets.
            defines.add("SUPPORT_POSIX2008", "1");
            // Upstream emits tz_tzname only when
            // `2 <= HAVE_TZNAME + TZ_TIME_T` (localtime.c:623-625) and
            // tz_timezone and tz_daylight only when
            // `2 <= USG_COMPAT + TZ_TIME_T` (localtime.c:626-629), renaming
            // all three to their tz_ spellings in this namespaced build
            // (private.h:776-785).  Upstream would otherwise guess both from
            // _POSIX_VERSION and _XOPEN_VERSION (private.h:335-349), which
            // would make the emitted symbols a property of the libc header
            // set.  Pin both to 1 here, and mirror them into the translation
            // step below, so the aggregate header declares exactly what is
            // built.
            defines.add("HAVE_TZNAME", "1");
            defines.add("USG_COMPAT", "1");
        },
        .macos => {
            defines.add("_USE_EXTENDED_LOCALES_", "1");
            defines.add("HAVE_FCHMOD", "1");
            defines.add("HAVE_LINK", "1");
            defines.add("HAVE_SYMLINK", "1");
            defines.add("HAVE_PWD_H", "1");
            defines.add("HAVE_SETMODE", "1");
            defines.add("HAVE_STRFTIME_L", "1");
            defines.add("HAVE_STRUCT_STAT_ST_CTIM", "1");
            defines.add("SUPPORT_POSIX2008", "1");
            defines.add("HAVE_TZNAME", "1");
            defines.add("USG_COMPAT", "1");
        },
        .windows => {
            defines.add("HAVE_MEMPCPY", "1");
            defines.add("HAVE_GETRESUID", "0");
            defines.add("HAVE_GETEUID", "0");
            // -DHAVE_DIRECT_H: mkdir needs <direct.h> on MS-Windows.
            defines.add("HAVE_DIRECT_H", "1");
            // zic falls back to copying when neither link nor symlink exists.
            defines.add("HAVE_LINK", "0");
            defines.add("HAVE_SYMLINK", "0");
            defines.add("HAVE_FCHMOD", "0");
            defines.add("HAVE_SETMODE", "0");
            defines.add("HAVE_PWD_H", "0");
            // mingw-w64 declares only _strftime_l, and has no locale_t.
            defines.add("HAVE_STRFTIME_L", "0");
            // struct stat on mingw-w64 has st_ctime but no st_ctim.
            defines.add("HAVE_STRUCT_STAT_ST_CTIM", "0");
            // mingw-w64 declares asctime_r/ctime_r only behind
            // _POSIX_THREAD_SAFE_FUNCTIONS, which private.h never defines, so
            // asctime.c renames both to static functions and tzcode emits
            // neither tz_asctime_r nor tz_ctime_r (asctime.c:53-62).
            defines.add("SUPPORT_POSIX2008", "0");
            defines.add("HAVE_DECL_ASCTIME_R", "0");
            // struct tm on mingw-w64 has neither tm_gmtoff nor tm_zone.
            defines.add("NO_TM_GMTOFF", "1");
            defines.add("NO_TM_ZONE", "1");
            // Pin both to 0 rather than inherit upstream's guess from
            // _POSIX_VERSION and _XOPEN_VERSION (private.h:335-349): with
            // TZ_TIME_T=1 that emits no tz_tzname, tz_timezone or tz_daylight
            // at all, so the aggregate header declares none of them, and the
            // same configuration holds on every unknown-OS target.
            defines.add("HAVE_TZNAME", "0");
            defines.add("USG_COMPAT", "0");
        },
        .wasi => {
            defines.add("HAVE_MEMPCPY", "1");
            defines.add("HAVE_GETRESUID", "0");
            defines.add("HAVE_GETEUID", "0");
            // wasi-libc is musl, so <sys/auxv.h> is reachable through the
            // generic musl headers and localtime.c:335-338 would find it:
            // __has_include(<sys/auxv.h>) is true, so HAVE_SYS_AUXV_H turns
            // itself on, <elf.h> supplies AT_SECURE, and localtime.c:359-362
            // then calls getauxval.  The WASI libc archive defines no
            // getauxval, so the two objects holding that call - localtime.o,
            // and strftime.o, which includes localtime.c at strftime.c:95 -
            // compile and then leave an undefined symbol at link time.
            // Makefile:241-242 and NEWS:398-405 document this exact knob for
            // exactly this case.
            // With it 0 the same issetugid() helper falls through to the two
            // branches above, both of which are 0 here, so it returns 0 -
            // the right answer on a target with no privileged-process
            // concept, no uid and no auxv.
            defines.add("HAVE_SYS_AUXV_H", "0");
            // wasi-libc declares link, symlink and fchmod.
            defines.add("HAVE_FCHMOD", "1");
            defines.add("HAVE_LINK", "1");
            defines.add("HAVE_SYMLINK", "1");
            // wasi-libc has no passwd database and no setmode.
            defines.add("HAVE_PWD_H", "0");
            defines.add("HAVE_SETMODE", "0");
            defines.add("HAVE_STRFTIME_L", "1");
            defines.add("HAVE_STRUCT_STAT_ST_CTIM", "1");
            defines.add("SUPPORT_POSIX2008", "1");
            // Same reasoning as the POSIX branches, applied to a header set
            // upstream's guess is not written against.
            defines.add("HAVE_TZNAME", "1");
            defines.add("USG_COMPAT", "1");
        },
        else => {
            // Unknown platform: select only what upstream can fall back from,
            // so that none of these becomes a silent no-op.
            defines.add("HAVE_FCHMOD", "0");
            defines.add("HAVE_LINK", "0");
            defines.add("HAVE_SYMLINK", "0");
            defines.add("HAVE_SETMODE", "0");
            defines.add("HAVE_PWD_H", "0");
            defines.add("HAVE_STRFTIME_L", "0");
            defines.add("HAVE_STRUCT_STAT_ST_CTIM", "0");
            defines.add("SUPPORT_POSIX2008", "0");
            defines.add("HAVE_DECL_ASCTIME_R", "0");
            defines.add("NO_TM_GMTOFF", "1");
            defines.add("NO_TM_ZONE", "1");
            defines.add("HAVE_TZNAME", "0");
            defines.add("USG_COMPAT", "0");
        },
    }
    return defines.list.items;
}

/// Value of a macro this build set, or null when the target's platform
/// branch leaves it to upstream's own default.
fn defineValue(defines: []const Define, name: []const u8) ?[]const u8 {
    for (defines) |d| {
        if (std.mem.eql(u8, d.name, name)) return d.value;
    }
    return null;
}

fn configureCMacros(module: *Module, defines: []const Define) void {
    for (defines) |d| module.addCMacro(d.name, d.value);
}

/// The macros that select which names the aggregate header declares, each
/// paired with the upstream macro this build sets to decide it.  Every
/// consumer of that selection - the translated bindings, the installed
/// pkg-config file and the Win32 export list - reads this one table, so the
/// three cannot describe different libraries.
const translated_macros = [_]struct { upstream: []const u8, translated: []const u8 }{
    .{ .upstream = "HAVE_STRFTIME_L", .translated = "TZDATA_HAVE_STRFTIME_L" },
    .{ .upstream = "SUPPORT_POSIX2008", .translated = "TZDATA_HAVE_POSIX2008" },
    .{ .upstream = "HAVE_TZNAME", .translated = "TZDATA_HAVE_TZNAME" },
    .{ .upstream = "USG_COMPAT", .translated = "TZDATA_USG_COMPAT" },
};

/// The names from `translated_macros` that this target's configuration turns
/// on.  An upstream macro this build leaves at its own default selects
/// nothing, because the fork's aggregate header declares that name only when
/// the build graph says the symbol exists.
fn enabledTranslatedMacros(defines: []const Define, allocator: std.mem.Allocator) []const []const u8 {
    var enabled: std.ArrayList([]const u8) = .empty;
    for (translated_macros) |entry| {
        const value = defineValue(defines, entry.upstream) orelse continue;
        if (std.mem.eql(u8, value, "1")) {
            enabled.append(allocator, entry.translated) catch @panic("OOM");
        }
    }
    return enabled.items;
}

/// Truncated SHA-256 of the zone source files.
///
/// The bundled database directory is named after this digest, so changing
/// the data selects a different directory and a compiled tree can never be
/// reused for different inputs.
fn zoneDataDigest(b: *Build) [8]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (data_sources) |name| {
        const bytes = b.build_root.handle.readFileAlloc(
            b.graph.io,
            name,
            b.allocator,
            .limited(64 * 1024 * 1024),
        ) catch |err| std.debug.panic("unable to read zone source {s}: {s}", .{
            name,
            @errorName(err),
        });
        defer b.allocator.free(bytes);
        hasher.update(name);
        hasher.update(bytes);
    }
    var full: [32]u8 = undefined;
    hasher.final(&full);
    return full[0..8].*;
}

/// Directory `zic` writes the compiled TZif tree into.
///
/// It is this build's own, and it lives in the build cache rather than in the
/// install prefix for two reasons.  It is named after a digest of the zone
/// sources, so changed data can never reuse a tree compiled from different
/// inputs.  And a build that only *runs* something - a dependent package
/// linking `dep.module("tzdata")` - still has to find a database, without the
/// install prefix being a place this build may write.
fn bundledZoneinfoDir(b: *Build) []const u8 {
    // A null cache_root.path means the cache is the working directory.
    const cache_root = b.cache_root.path orelse ".";
    const absolute_root = if (std.fs.path.isAbsolute(cache_root))
        cache_root
    else
        b.pathJoin(&.{ b.graph.cache.cwd, cache_root });
    const hex = std.fmt.bytesToHex(zoneDataDigest(b), .lower);
    const hex_text: []const u8 = &hex;
    const joined = b.fmt("{s}/tzdata-zoneinfo-{s}", .{ absolute_root, hex_text });
    return tzdirPathForC(b, joined);
}

/// Directory the library resolves plain zone names in, that is the directory
/// the install step publishes the TZif tree to: `<install prefix>/share/zoneinfo`.
///
/// This is the value a packaged build needs compiled into `tzdir.h`.  Naming
/// the build cache instead would compile a library that cannot open any zone
/// once the cache is gone, which is the whole of what an installed artefact
/// has to survive; a Nix store path, for one, has no build cache beside it.
///
/// A dependent package gets the same treatment rather than an exception: a
/// dependency's install prefix is `<cache>/i/<hash>`
/// (`std.Build.determineAndApplyInstallPrefix`), which is a directory that
/// build owns and can write, and the copy that fills it is a dependency of
/// the library rather than of any install step, so a dependent that reaches
/// this graph through the module still gets a populated database.
fn installedZoneinfoDir(b: *Build) []const u8 {
    const raw = b.getInstallPath(.prefix, "share/zoneinfo");
    checkTzdirPath(raw);
    return tzdirPathForC(b, raw);
}

/// Reject a TZDIR that cannot be written into the generated `tzdir.h`.
///
/// This takes a path that may still use the native separator, so it cannot
/// refuse a backslash: on Windows the install prefix is spelled with them, and
/// `tzdirPathForC` rewrites them afterwards.
fn checkTzdirPath(path: []const u8) void {
    if (!std.fs.path.isAbsolute(path)) @panic("the TZDIR must be an absolute path");
    // tzdir.h embeds the value in a C string literal, where a double quote
    // would end it.
    if (std.mem.indexOf(u8, path, "\"") != null) {
        @panic("the TZDIR must not contain a double quote");
    }
}

/// Reject a `-Dtz-dir` whose spelling `tzdirPathForC` would change.
///
/// A backslash is refused rather than normalised because the two spellings
/// would then compare unequal, which would give one directory two names of
/// which only one is accepted.
fn checkUserTzdirPath(path: []const u8) void {
    checkTzdirPath(path);
    if (std.mem.indexOf(u8, path, "\\") != null) {
        @panic("-Dtz-dir must use forward slashes, not backslashes");
    }
}

/// Spell a path the way the generated `tzdir.h` needs it.
///
/// The value is both the body of a C string literal and the directory `zic`
/// and the install step are handed, so it has to stay one directory in both
/// roles: escaping a backslash would be right for the literal and wrong for
/// the filesystem.  tzcode also treats the TZDIR it was given as text, building
/// `TZDIR "/"` and matching a zone name against it (`localtime.c:874, 954-957`),
/// so a Windows install prefix that arrives spelled with backslashes is
/// normalised to the forward slashes every target accepts below a TZDIR.
///
/// A path with no backslash is already spelled correctly and is returned
/// unchanged, so the common case allocates nothing.  One that has a backslash
/// has it rewritten rather than escaped, which is the spelling `README.zig.md`
/// states for a TZDIR; the double quote that would end the literal is refused
/// by `checkTzdirPath` before this runs.
///
/// The result lives in the build allocator, like every other path this file
/// produces, and is never freed.
fn tzdirPathForC(b: *Build, path: []const u8) []const u8 {
    if (std.mem.indexOf(u8, path, "\\") == null) return path;
    return std.mem.replaceOwned(u8, b.allocator, path, "\\", "/") catch @panic("OOM");
}

/// Build the C library, the translated-C module and the zic tool for one target.
///
/// `linkage` selects the library form and nothing else.  The default is
/// `.static`, which is this package's existing policy; `.dynamic` produces a
/// real shared object instead, from the same four translation units, with the
/// same `tz_` symbols and the same installed layout.
///
/// `runtime_loaded` selects how the native symbols are reached, independently
/// of which form the library has: false links them, true resolves them through
/// the platform loader from a provider the caller names.  The library is built
/// and installed either way, because it is what this package delivers; what the
/// second case drops is only the link.
fn addCore(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: OptimizeMode,
    generated: *Step.WriteFile,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
) Core {
    const defines = cDefines(b, target);

    const library_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // Position-independent code is what makes the shared object loadable
        // at an address the loader chooses, so it is requested for `.dynamic`
        // and left at the compiler's own default for `.static`, which leaves
        // the pre-existing static build unchanged.
        .pic = switch (linkage) {
            .dynamic => true,
            .static => null,
        },
    });
    library_module.addIncludePath(b.path("."));
    library_module.addIncludePath(generated.getDirectory());
    configureCMacros(library_module, defines);
    const library = b.addLibrary(.{
        .name = "tz",
        .root_module = library_module,
        .linkage = linkage,
        // A COFF DLL exports nothing unless a module-definition file says
        // what, and the names it may say are `publicSymbols`.  Every other
        // object format exports the non-static symbols by default, which for
        // these four translation units is that same set.
        .win32_module_definition = if (linkage == .dynamic and target.result.os.tag == .windows)
            win32ModuleDefinition(b, defines)
        else
            null,
    });
    library_module.addCSourceFiles(.{ .files = &lib_sources, .flags = &.{"-std=gnu17"} });

    const zic_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zic_module.addIncludePath(b.path("."));
    zic_module.addIncludePath(generated.getDirectory());
    configureCMacros(zic_module, defines);
    const zic = b.addExecutable(.{ .name = "zic", .root_module = zic_module });
    zic_module.addCSourceFiles(.{ .files = &.{"zic.c"}, .flags = &.{"-std=gnu17"} });

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("include/tzdata.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(b.path("."));
    for (defines) |d| translate_c.defineCMacro(d.name, d.value);
    // Upstream's Makefile pairs each HAVE_/SUPPORT_ macro with a matching
    // translation-time macro, so the generated bindings carry a declaration
    // exactly when the library emits the symbol behind it.  The same four
    // names select what the installed pkg-config file declares, so both come
    // from one list rather than from two copies of these conditions.
    //
    //  - HAVE_STRFTIME_L emits tz_strftime_l (strftime.c:175).
    //  - SUPPORT_POSIX2008 emits tz_asctime_r and tz_ctime_r; without it
    //    asctime.c renames both to static functions (asctime.c:53-62).
    //  - tz_tzname is emitted only where HAVE_TZNAME is nonzero, and
    //    tz_timezone and tz_daylight only where USG_COMPAT is
    //    (localtime.c:623-629).
    //
    // Each of the four is 0 or 1 in cDefines, so the value "1" is exactly the
    // condition the aggregate header tests.
    for (enabledTranslatedMacros(defines, b.allocator)) |name| {
        translate_c.defineCMacro(name, "1");
    }

    // The one place the two configurations part ways.  A linked build's `c` is
    // the translated header, and `graph.createModule` replaces it with a
    // dispatch generated from that same translation step, so the header the
    // dispatch describes is the header this target actually selected.
    const c_module = if (runtime_loaded)
        graph.createModule(b, translate_c, target, optimize)
    else
        translate_c.createModule();

    return .{
        .library = library,
        .zic = zic,
        .c_module = c_module,
        .defines = defines,
        .runtime_loaded = runtime_loaded,
    };
}

/// The names a shared object of this package exports.
///
/// On ELF and Mach-O nothing extra is needed: `private.h` renames every
/// externally visible identifier to a `tz_` name (private.h:712-789), and every
/// remaining internal helper is `static`, so the default-visibility export set
/// of the four translation units is this list and nothing else.  Windows is
/// the one platform where that is not true, because a DLL exports only what
/// `__declspec(dllexport)` or a module-definition file names, and neither
/// upstream nor this fork's aggregate header declares one; `addLibrary` takes
/// that file through `win32_module_definition`.
///
/// `tz_timelocal` and `tz_timeoff` are emitted unconditionally because
/// `USE_TIMEX_T` is defined only inside strftime.c (strftime.c:94) and never
/// in the localtime.c translation unit that defines them (localtime.c:2906,
/// 2918); `tz_timegm` is emitted for the same reason (localtime.c:2929).
/// `tz_timeoff` is external rather than static because `TZ_TIME_T` is on, so
/// `EXTERN_TIMEOFF` expands to nothing (private.h:901-902).
fn publicSymbols(b: *Build, defines: []const Define) []const []const u8 {
    const always = [_][]const u8{
        // NETBSD_INSPIRED (private.h:733, 735).
        "tz_localtime_rz", "tz_mktime_z",     "tz_tzalloc",    "tz_tzfree",
        // STD_INSPIRED (private.h:732-751, 758).
        "tz_offtime",      "tz_offtime_r",    "tz_timelocal",  "tz_timeoff",
        "tz_posix2time",   "tz_posix2time_z", "tz_time2posix", "tz_time2posix_z",
        // The POSIX surface (private.h:718-731, 746-757, 764).
        "tz_localtime",    "tz_localtime_r",  "tz_gmtime",     "tz_gmtime_r",
        "tz_mktime",       "tz_timegm",       "tz_time",       "tz_tzset",
        // asctime.c and difftime.c (private.h:717, 719, 720, 744).
        "tz_ctime",        "tz_asctime",      "tz_difftime",   "tz_strftime",
        // This fork's linkable accessors for the upstream version strings.
        "tzdata_version",  "tzdata_package",
    };

    var symbols: std.ArrayList([]const u8) = .empty;
    symbols.appendSlice(b.allocator, &always) catch @panic("OOM");

    for (translated_macros) |entry| {
        const value = defineValue(defines, entry.upstream) orelse continue;
        if (!std.mem.eql(u8, value, "1")) continue;
        if (std.mem.eql(u8, entry.translated, "TZDATA_HAVE_POSIX2008")) {
            // asctime.c renames both to static functions without
            // SUPPORT_POSIX2008 (asctime.c:53-62).
            symbols.appendSlice(b.allocator, &.{ "tz_asctime_r", "tz_ctime_r" }) catch @panic("OOM");
        } else if (std.mem.eql(u8, entry.translated, "TZDATA_HAVE_STRFTIME_L")) {
            symbols.appendSlice(b.allocator, &.{"tz_strftime_l"}) catch @panic("OOM");
        } else if (std.mem.eql(u8, entry.translated, "TZDATA_HAVE_TZNAME")) {
            // The three variables are data, not code; localtime.c:623-629.
            symbols.appendSlice(b.allocator, &.{"tz_tzname"}) catch @panic("OOM");
        } else if (std.mem.eql(u8, entry.translated, "TZDATA_USG_COMPAT")) {
            symbols.appendSlice(b.allocator, &.{ "tz_timezone", "tz_daylight" }) catch @panic("OOM");
        } else unreachable;
    }
    return symbols.items;
}

/// Write the pkg-config metadata for one configured target.
///
/// The `Cflags` carry the four `TZDATA_HAVE_*` macros this target's
/// configuration turns on, because `include/tzdata.h` is guarded by them and
/// a consumer that did not get them would compile against a declaration list
/// smaller than the library's.  They come from `translated_macros`, the same
/// table the translated bindings and the export list read, so the three
/// cannot disagree.
///
/// `prefix` is written as `${pcfiledir}/../..`, which is where the installed
/// file actually sits relative to the prefix, so the metadata stays correct
/// when the tree is moved.  `Libs` names `-ltz` for both linkages: the file
/// describes the same `-L${libdir}` directory, and which library is in it is
/// the packaging variant's business.  There is no `Libs.private`, because
/// upstream's own link line adds nothing but the C library (`Makefile:209`).
fn addPkgConfig(
    b: *Build,
    defines: []const Define,
    version: []const u8,
    linkage: std.builtin.LinkMode,
) void {
    var writer: std.Io.Writer.Allocating = .init(b.allocator);
    defer writer.deinit();
    const w = &writer.writer;

    var macros: std.ArrayList(u8) = .empty;
    defer macros.deinit(b.allocator);
    for (enabledTranslatedMacros(defines, b.allocator)) |name| {
        macros.print(b.allocator, " -D{s}=1", .{name}) catch @panic("OOM");
    }

    w.print(
        \\prefix=${{pcfiledir}}/../..
        \\exec_prefix=${{prefix}}
        \\libdir=${{prefix}}/lib
        \\includedir=${{prefix}}/include
        \\
        \\Name: tzdata
        \\Description: IANA Time Zone Database (tzcode) in the tz_ namespace, {s} library
        \\Version: {s}
        \\Libs: -L${{libdir}} -ltz
        \\Cflags: -I${{includedir}}{s}
        \\
    , .{ @tagName(linkage), version, macros.items }) catch @panic("OOM");

    const generated = b.addWriteFiles();
    const pc = generated.add("tzdata.pc", writer.written());
    b.getInstallStep().dependOn(&b.addInstallFile(pc, "lib/pkgconfig/tzdata.pc").step);
}

/// Write the Win32 module-definition file naming this build's exports.
///
/// `addLibrary` consumes it only for a dynamic library: `Compile.create`
/// forwards it only when the artifact is a `.lib` whose linkage is `.dynamic`
/// (`lib/std/Build/Step/Compile.zig:479-484`).  So this is the whole of the
/// Windows shared-object export story, and the static build neither needs nor
/// gets one.  The list is `publicSymbols`, so a name the library does not
/// define cannot reach the DLL's export table.
fn win32ModuleDefinition(b: *Build, defines: []const Define) std.Build.LazyPath {
    var writer: std.Io.Writer.Allocating = .init(b.allocator);
    defer writer.deinit();
    const w = &writer.writer;
    w.writeAll("EXPORTS\n") catch @panic("OOM");
    for (publicSymbols(b, defines)) |name| {
        w.print("    {s}\n", .{name}) catch @panic("OOM");
    }
    const generated = b.addWriteFiles();
    return generated.add("tz.def", writer.written());
}

/// Wire a facade module to the `c` module of the core it belongs to.
///
/// This is the other half of the split `addCore` makes, and the two halves
/// have to agree or the build describes two different libraries.  In the
/// linked configuration the module links the native library, so every `tz_*`
/// call is an ordinary direct call, and it takes the loader core under the
/// name `rt` because `src/root.zig` reaches for `LoadSource` and `LoadError`
/// there when its `runtime_loaded` is false.
///
/// In the runtime configuration neither happens.  Linking the library here
/// would let the linker resolve the symbols statically and silently turn the
/// runtime route back into a linked one, which `runtime/graph.zig` names as
/// the one thing a caller must not do.  `rt` is left out as well: the
/// dispatch already carries the one core instance, it re-exports those two
/// types, and `src/root.zig` never references `rt` in that configuration, so
/// adding a second import would give one build two sets of the same types.
fn attachFacade(
    module: *Module,
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: OptimizeMode,
    core: Core,
) void {
    module.addImport("tz_c", core.c_module);
    if (core.runtime_loaded) return;
    module.linkLibrary(core.library);
    module.addImport("rt", graph.createCoreModule(b, target, optimize));
}

/// Public module `tzdata`: typed facade plus the translated C declarations.
fn addFacadeModule(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: OptimizeMode,
    core: Core,
) *Module {
    const module = b.addModule("tzdata", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    attachFacade(module, b, target, optimize, core);
    return module;
}

fn addTestModule(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: OptimizeMode,
    tz_module: *Module,
    test_options: *Step.Options,
) *Module {
    const module = b.createModule(.{
        .root_source_file = b.path("test/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("tzdata", tz_module);
    module.addImport("build_options", test_options.createModule());
    return module;
}

/// Why a target has no buildable tzdata from this package, or null when it has one.
///
/// A refusal is a decision this graph records rather than a failure a
/// cross-matrix discovers: `-Dtarget=<that target>` prints it and stops
/// before one step is configured, so no compiler, no header and no artefact
/// is reached.  Both refusals below are the toolchain's own C translation
/// meeting a libc header set, not a property of tzcode: every macro
/// `cDefines` sets is read by a translation unit this package compiles, and
/// none of them is read by the headers either refusal names.
const Refusal = struct {
    /// One line, printed with the triple in front of it.
    summary: []const u8,
    /// The long form, printed under it.
    detail: []const u8,
};

/// The targets this package refuses to configure, and the platform fact behind each.
///
/// The rows stay in the matrix: this function names them, so `zig build
/// -Dtarget=<row>` fails at configure time with the reason rather than
/// reaching a compiler that would report the same thing as a build error.
/// Nothing here narrows a refusal to save a row.  The NetBSD refusal has no
/// narrower form at all - every width and every endianness is in it - and the
/// OpenBSD refusal is stated as the pointer width it is, not as a list of
/// architectures, so a 32-bit OpenBSD row added to the matrix later is
/// refused by this same rule rather than by a name someone remembered.
fn refusalFor(target: Build.ResolvedTarget) ?Refusal {
    switch (target.result.os.tag) {
        .netbsd => return .{
            .summary = "no buildable configuration for this target: `zig translate-c` cannot read this libc's `sys/cdefs.h`, which every NetBSD header reaches.",
            .detail =
            \\include/tzdata.h:30-35 reaches <time.h> and <locale.h> before it
            \\declares anything, and both of those reach
            \\libc/include/generic-netbsd/sys/cdefs.h, whose __END_DECLS
            \\(cdefs.h:432) is __END_PUBLIC_DECLS.  The translator predefines
            \\__GNUC__ (compiler/aro/aro/Compilation.zig:270-274), so
            \\__GNUC_PREREQ__(4, 0) - cdefs.h:50-56 - is true and
            \\__END_PUBLIC_DECLS is
            \\__END_EXTERN_C _Pragma("GCC visibility pop")
            \\(cdefs.h:413).  Aro's _Pragma operator
            \\(compiler/aro/aro/Preprocessor.zig:1626-1655) writes that
            \\pragma's tokens into the expansion buffer without the leading
            \\hash and without the newline that the directive path adds
            \\(Preprocessor.zig:852-855, 2854-2857), so "pragma GCC
            \\visibility pop" reaches the C parser as three ordinary
            \\identifiers.  That is the whole failure: 30 to 34 errors per
            \\target, all of them from libc headers, beginning at
            \\generic-netbsd/sys/endian.h:74 "unknown type name 'pragma'" and
            \\continuing through <aarch64>/byte_swap.h:101, sys/bswap.h:23,
            \\sys/inttypes.h, locale.h:117 and time.h:241.
            \\
            \\The translator offers no way out of it.  What aro documents for
            \\this is -fgnuc-version (compiler/aro/aro/Driver.zig:192), and
            \\std/Build/Step/TranslateC.zig:22-27 gives Options exactly
            \\root_source_file, target, optimize and link_libc, with no way to
            \\pass a flag.  -D__GNUC__=0 would reach the same macro from the
            \\command line, and is not used: it tells every header in the
            \\translation that the compiler is not GCC, which is false, and it
            \\would change which declarations the header set publishes rather
            \\than which ones this package reads.
            \\
            \\Two further facts about the same targets, recorded because a
            \\reader meets them first and each is cheap to state.  One:
            \\include/tzdata.h:43 declares `typedef struct state
            \\*timezone_t`, while generic-netbsd/time.h:198 already declares
            \\`typedef struct __state *timezone_t` on every NetBSD target,
            \\because _NETBSD_SOURCE is predefined for that operating system
            \\and time.h:196 gates it on exactly that.  Upstream's own
            \\private.h:933-938 handles it - `#define state __state` under
            \\_NETBSD_SOURCE, in place of the typedef - and this fork's
            \\aggregate header has no such branch.  Two: localtime.c:1020-1021
            \\calls mempcpy, which private.h:850-856 turns on for any target
            \\whose predefines name NetBSD, while this libc's string.h
            \\declares no mempcpy; -DHAVE_MEMPCPY=0 is the knob Makefile:248
            \\documents and would close that error by itself.
            \\
            \\No *-netbsd triple builds, at any width or endianness.  The nine
            \\rows in the cross matrix - aarch64, aarch64_be, arm, armeb, mips,
            \\mipsel, powerpc, x86 and x86_64 - fail on the translator alone.
            \\
            \\Build for a target this package translates: every *-freebsd
            \\row, every 64-bit *-openbsd row, x86_64-linux-gnu,
            \\aarch64-linux-gnu, riscv64-linux-gnu, aarch64-macos-none,
            \\x86_64-windows-gnu and wasm32-wasi.  Those six are what `check`
            \\walks, and none of them is in this refusal.
            ,
        },
        .openbsd => {
            if (std.Target.ptrBitWidth(&target.result) != 32) return null;
            return .{
                .summary = "no buildable configuration for this target: the translator's size_t and this libc's differ at 32 bits.",
                .detail =
                \\This is the 32-bit half of OpenBSD, and it is the whole of
                \\the failure there.  Three of the six OpenBSD rows in the
                \\cross matrix are 32-bit and fail; the three 64-bit ones build.
                \\
                \\libc/include/generic-openbsd/time.h:59-62 declares
                \\
                \\    #ifndef _SIZE_T_DEFINED_
                \\    #define _SIZE_T_DEFINED_
                \\    typedef __size_t size_t;
                \\    #endif
                \\
                \\and the only header that sets _SIZE_T_DEFINED_ before it is
                \\generic-openbsd/stddef.h:47-50.  zig translate-c never reads
                \\that one: the freestanding compiler/aro/include/stddef.h:8
                \\comes first on the include path and defines size_t itself,
                \\as __SIZE_TYPE__, which for every 32-bit target is `unsigned
                \\int`.  The second declaration is then a redefinition with a
                \\different type, and it is the only error:
                \\
                \\    generic-openbsd/time.h:61:18: error: typedef
                \\      redefinition with different types
                \\      ('__size_t' (aka 'unsigned long') vs 'unsigned int')
                \\
                \\At 64 bits both spellings are `unsigned long`, the
                \\redefinition is identical and legal, and x86_64-openbsd,
                \\aarch64-openbsd, powerpc64-openbsd, mips64-openbsd,
                \\mips64el-openbsd and riscv64-openbsd translate and build.  That
                \\is why this boundary is the pointer width and not the
                \\operating system.
                \\
                \\No macro in cDefines reaches it: both typedefs are this
                \\libc's, behind include/tzdata.h:30, and tzcode's own HAVE_*
                \\macros are read by neither.  -D_SIZE_T_DEFINED_ would
                \\suppress the second declaration, and is not used: size_t
                \\would then be `unsigned int` where this platform's ABI
                \\calls it `unsigned long`, and the translated binding for
                \\tz_strftime would carry c_uint where every other target
                \\carries usize, which is a declaration this facade cannot
                \\call.  Reaching past the translator into the compiler's own
                \\libc directory to make generic-openbsd/stddef.h win would
                \\pin this package to one toolchain's directory names instead.
                \\
                \\Build for a target this package translates: x86_64-openbsd,
                \\aarch64-openbsd, powerpc64-openbsd, mips64-openbsd,
                \\mips64el-openbsd and riscv64-openbsd, every *-freebsd row,
                \\every *-linux row, and the macOS and Windows rows.
                ,
            };
        },
        else => return null,
    }
}

/// Prints why `target` has no buildable tzdata, and fails the build.
///
/// Called before anything is configured, so the message is what a caller
/// reads whether it asked for the target by name or reached it through a
/// dependency.
fn refuseTarget(b: *Build, target: Build.ResolvedTarget) error{UnsupportedTarget} {
    const refusal = refusalFor(target) orelse
        @panic("build.zig internal error: refusalFor returned null for a target this build refused");
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    std.log.err("tzdata: {s}: {s}\n{s}", .{ triple, refusal.summary, refusal.detail });
    return error.UnsupportedTarget;
}

/// Keeps the refusal table and the matrix `check` walks from drifting apart.
///
/// A row added to `check_target_queries` that this graph refuses would
/// otherwise be discovered by whoever ran the gate.  Re-derived here, on
/// every invocation and not only when `check` is asked for.
fn checkTargetPartition(b: *Build) void {
    for (check_target_queries) |query| {
        const resolved = b.resolveTargetQuery(query);
        if (refusalFor(resolved) != null) {
            @panic(b.fmt(
                "tzdata: build.zig: check walks {s}, which this build refuses",
                .{resolved.result.zigTriple(b.allocator) catch @panic("OOM")},
            ));
        }
    }
}

/// True when this build can execute `target`'s binaries.
///
/// `std.zig.system.getExternalExecutor` is the predicate `std.Build.Step.Run`
/// asks about the artifact it is about to spawn, and the switches below are
/// the ones `Run` gates that answer on, so the two cannot disagree.  No
/// enabled executor means the target builds and installs: compile evidence.
fn hostCanExecute(b: *Build, target: Build.ResolvedTarget) bool {
    const host = &b.graph.host.result;
    const candidate = &target.result;
    const options: std.zig.system.GetExternalExecutorOptions = .{
        .allow_darling = b.enable_darling,
        .allow_qemu = b.enable_qemu,
        .allow_wasmtime = b.enable_wasmtime,
        .allow_wine = b.enable_wine,
        // `Run`'s `need_cross_libc` is `exe.is_linking_libc` and a GNU or
        // dynamic-musl target; the consumer links libc and sets no linkage of
        // its own, so `isGnuLibC` is the whole of it here.
        .qemu_fixes_dl = candidate.isGnuLibC() and b.libc_runtimes_dir != null,
        .link_libc = true,
    };
    return switch (std.zig.system.getExternalExecutor(b.graph.io, host, candidate, options)) {
        .native, .rosetta => true,
        // Not a yes on its own: `Run` fails a cross libc target given no
        // `--libc-runtimes` rather than skipping it, and `qemu_fixes_dl` cannot
        // carry that, because the QEMU arm is entered on `!cpu_ok` alone.
        .qemu => !candidate.isGnuLibC() or b.libc_runtimes_dir != null,
        // Reachable only for an executor the switches above enabled, each of
        // which `Run` gates on the same switch and nothing else.
        .wine, .wasmtime, .darling => true,
        // Same OS and CPU with no dynamic linker, or an architecture and system
        // this build has no enabled executor for.
        .bad_dl, .bad_os_or_cpu => false,
    };
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Refused before a single step exists, so `-Dtarget=<row>` reports the
    // platform fact rather than a compiler error from three steps deep, and
    // so no option below can turn a refused row into a different build.
    if (refusalFor(target) != null) return refuseTarget(b, target);

    const version = b.option(
        []const u8,
        "tz-version",
        "Upstream release string compiled into version.h (default: 2026e)",
    ) orelse "2026e";

    // The library form, and nothing else.  `.static` is this package's
    // existing policy and stays the default; `.dynamic` is a real shared
    // object built from the same four translation units with the same `tz_`
    // symbols, not a repackaged archive.
    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Link the tz library statically or dynamically (default: static)",
    ) orelse .static;

    // How the native symbols are reached, and nothing else.  The default is
    // false: the library is linked and every `tz_*` call is a direct call,
    // which is what this package has always done.  `true` generates the
    // dispatch and resolves the same symbols through the platform loader from
    // a provider the caller names, so the library is built and installed but
    // not linked.
    //
    // It is orthogonal to `-Dlinkage` and neither implies the other.  The
    // option still decides which form of the library is installed; this one
    // decides whether the build depends on it at link time.  Loading a
    // provider this package did not build is the other half of the runtime
    // route and needs no particular linkage at all.
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Resolve the native symbols at run time through the platform loader " ++
            "instead of linking them (default: false). Independent of " ++
            "-Dlinkage, which still decides the form of the installed library.",
    ) orelse false;

    // Where the installed library looks for a zone given by plain name.
    //
    // This is the directory the install step fills, not a build-cache path.
    // An installed package has no build cache beside it, so a TZDIR naming one
    // produces a library that cannot open any zone once the cache is gone; the
    // cache tree below exists only so that `zic` writes somewhere fresh and
    // disposable and the install step publishes the result.
    const installed_zoneinfo = installedZoneinfoDir(b);
    if (b.option(
        []const u8,
        "tz-dir",
        "Absolute TZDIR compiled into the library. It must be the installed " ++
            "database directory, <install prefix>/share/zoneinfo, because that is " ++
            "the only tree this build produces; the default is that directory.",
    )) |requested| {
        checkUserTzdirPath(requested);
        const requested_path = tzdirPathForC(b, requested);
        if (!std.mem.eql(u8, requested_path, installed_zoneinfo)) {
            std.debug.panic(
                "zig build: -Dtz-dir must name the installed database " ++
                    "directory, which is {s} for this invocation, but it is {s}. " ++
                    "This build writes the TZif tree to exactly one place, so a " ++
                    "TZDIR naming another compiles a library that cannot open " ++
                    "a zone by plain name. Pass --prefix and drop -Dtz-dir.",
                .{ installed_zoneinfo, requested_path },
            );
        }
    }
    const zoneinfo_dir = installed_zoneinfo;

    // Where `zic` writes.  It is this build's own, and it is named after the
    // zone sources so that changed data can never reuse a tree compiled from
    // different inputs.
    const bundled_zoneinfo = bundledZoneinfoDir(b);

    // Upstream generates these two headers in the Makefile; regenerate them
    // from the same inputs so that the C sources compile unchanged.
    const generated = b.addWriteFiles();
    _ = generated.add("version.h", b.fmt(
        \\static char const PKGVERSION[] = "(tzcode) ";
        \\static char const TZVERSION[] = "{s}";
        \\static char const REPORT_BUGS_TO[] = "tz@iana.org";
        \\
    , .{version}));
    _ = generated.add("tzdir.h", b.fmt(
        \\#ifndef TZDEFAULT
        \\# define TZDEFAULT "/etc/localtime" /* default zone */
        \\#endif
        \\#ifndef TZDIR
        \\# define TZDIR "{s}" /* TZif directory */
        \\#endif
        \\
    , .{zoneinfo_dir}));

    const core = addCore(b, target, optimize, generated, linkage, runtime_loaded);
    const module = addFacadeModule(b, target, optimize, core);

    // zic and the compiled database are always host programs: they run on the
    // build machine no matter which target the library was compiled for.
    // Only `zic` is read out of this core, so it is configured linked and
    // static whatever the selected target asked for: a dispatch generated for
    // the host would describe a library no consumer ever reaches, and its
    // generator would run once more for nothing.
    const host_core = if (target.query.isNative())
        core
    else
        addCore(b, b.resolveTargetQuery(.{}), optimize, generated, .static, false);

    // zic writes into the bundled directory itself rather than into a path
    // the build runner allocates, because tzdir.h has to name the directory
    // it will be published to before any step has run.
    const zoneinfo_tree: Build.LazyPath = .{ .cwd_relative = bundled_zoneinfo };
    const zic_run = b.addRunArtifact(host_core.zic);
    zic_run.addArg("-d");
    zic_run.addArg(bundled_zoneinfo);
    for (data_sources) |source| zic_run.addFileArg(b.path(source));

    // The compiled TZDIR is the directory the tree is published to, so the
    // copy that publishes it has to finish before anything that opens a zone
    // runs.  Every step below is bound to it explicitly rather than reaching it
    // through the library, because under `-Druntime` nothing links
    // `core.library` and the library would no longer carry the dependency:
    //
    //   * the delivered library, in the linked configuration where a dependent
    //     reaches this graph through the module and links it, and in the
    //     runtime configuration where it is installed whether or not anything
    //     links it, so a caller naming it as a provider finds the tree its baked
    //     TZDIR names beside it.  A dependent's own install step never runs
    //     inside its build, but this one does, because it is a dependency of
    //     the library rather than of any install step.
    //   * the test and smoke runs below, which open zones by plain name and so
    //     read the tree directly rather than through a link.
    //
    // The source directory is a plain path, so the copy step gets no
    // dependency from it and the zic step has to be wired in by hand.
    const install_zoneinfo = b.addInstallDirectory(.{
        .source_dir = zoneinfo_tree,
        .install_dir = .prefix,
        .install_subdir = "share/zoneinfo",
    });
    install_zoneinfo.step.dependOn(&zic_run.step);
    core.library.step.dependOn(&install_zoneinfo.step);
    b.getInstallStep().dependOn(&install_zoneinfo.step);

    b.installArtifact(host_core.zic);
    b.installArtifact(core.library);

    // No provider is built here.  What `-Druntime` changes is how a consumer
    // reaches the native symbols, not what this package produces: the install
    // tree is whatever `-Dlinkage` asked for and nothing else, so under the
    // default `.static` it contains an archive and no loadable artifact.  A
    // runtime-loading caller names its own provider, separately built or
    // external, which is the whole point of the route and the reason it
    // accepts a provider this package did not compile.  Adding a shared object
    // under `-Dlinkage=static` would make `-Druntime` silently change the
    // linkage of what gets installed, which is exactly what the two options
    // being orthogonal forbids.
    //
    // The published TZif tree is still bound to whatever library this build
    // did produce, and to the test and smoke runs below, so the static
    // configuration keeps the database beside the archive it compiled it for
    // and the runtime configuration keeps it beside the shared object, when
    // that is what `-Dlinkage` selected.

    // The zone tables upstream installs beside the TZif files, the manual
    // pages for the programs installed here, and the licence material, so an
    // installed tree is the whole of what upstream's `install` rule produces
    // rather than the library and one tool.
    for (table_sources) |table| {
        b.getInstallStep().dependOn(&b.addInstallFile(
            b.path(table),
            b.pathJoin(&.{ "share/zoneinfo", table }),
        ).step);
    }
    for (manual_sources) |manual| {
        b.getInstallStep().dependOn(&b.addInstallFile(
            b.path(manual.path),
            b.pathJoin(&.{ "share/man", b.fmt("man{s}", .{manual.section}), manual.path }),
        ).step);
    }
    for (licence_sources) |licence| {
        b.getInstallStep().dependOn(&b.addInstallFile(
            b.path(licence),
            b.pathJoin(&.{ "share/licenses/tzdata", licence }),
        ).step);
    }
    addPkgConfig(b, core.defines, version, linkage);
    // The public headers go out with the artifact, so the include directory a
    // dependent compiles against is the one the library was installed beside.
    core.library.installHeader(b.path("include/tzdata.h"), "tzdata.h");
    core.library.installHeader(b.path("tzfile.h"), "tzfile.h");

    // Paths handed to the tests: the zic binary that generates fixtures, and
    // the database this build published.  The database is named by its
    // installed path rather than by the staging directory it was copied from,
    // so a test that opens a zone by plain name follows exactly the lookup a
    // dependent package makes against this library.
    const installed_zoneinfo_tree: Build.LazyPath = .{ .cwd_relative = installed_zoneinfo };
    const test_options = b.addOptions();
    test_options.addOptionPath("zic_exe", host_core.zic.getEmittedBin());
    test_options.addOptionPath("zoneinfo_dir", installed_zoneinfo_tree);

    const unit_tests = b.addTest(.{
        .name = "tzdata-test",
        .root_module = addTestModule(b, target, optimize, module, test_options),
    });
    const unit_test_run = b.addRunArtifact(unit_tests);
    unit_test_run.setCwd(.{ .cwd_relative = b.cache_root.path orelse "." });
    // Both runs below read the published tree by name, so both are bound to
    // the copy that publishes it.  Binding the library was enough only while
    // something linked it; under `-Druntime` nothing does, and a test run
    // that started before the tree existed would find an empty TZDIR and every
    // plain zone name would fail rather than the build stopping.
    unit_test_run.step.dependOn(&install_zoneinfo.step);
    b.step("test", "Run the tzdata unit tests").dependOn(&unit_test_run.step);

    // The smoke program calls every public facade entry point with fixed
    // timestamps and prints their results, so its output is reproducible.
    const smoke_module = b.createModule(.{
        .root_source_file = b.path("src/smoke.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    smoke_module.addImport("tzdata", module);
    const smoke_run = b.addRunArtifact(b.addExecutable(.{
        .name = "tzdata-smoke",
        .root_module = smoke_module,
    }));
    // The smoke program opens zones by plain name, so it exercises the same
    // TZDIR lookup any dependent package gets, and is bound to the same copy
    // for the same reason as the test run above.
    smoke_run.step.dependOn(&install_zoneinfo.step);
    if (b.args) |args| smoke_run.addArgs(args);
    b.step("smoke", "Run the deterministic smoke program").dependOn(&smoke_run.step);

    // Licence and provenance integrity gate over the untouched upstream files.
    const provenance_run = b.addRunArtifact(b.addExecutable(.{
        .name = "tzdata-provenance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/provenance_check.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = .ReleaseSafe,
        }),
    }));
    provenance_run.addFileArg(b.path("PROVENANCE.sha256"));
    provenance_run.addArg(".");
    b.step("provenance", "Verify preserved upstream files against PROVENANCE.sha256")
        .dependOn(&provenance_run.step);

    // Compile the library, facade, smoke and tests for all six targets.
    // zic requires umask and signals, which WASI does not provide; it runs
    // on the host to generate the WASI library's database.
    //
    // The matrix always compiles the archive form.  `check` is a compile gate
    // over the C sources and the facade for six targets and installs and runs
    // nothing, while `-Dlinkage` decides the artefact this invocation installs
    // for the selected target; folding the option in here would make `check`
    // answer a different question and depend on whether every matrix target
    // has a shared-object form at all.  The shared object is built by the
    // default step.
    //
    // `-Druntime` is the opposite case and *is* threaded through, because it
    // changes which module the facade imports rather than which artefact is
    // produced, so a matrix that ignored it would never compile the dispatch
    // for any target.  Each target generates its own, from its own
    // translation, because `runtime/graph.zig` reads the translation step's
    // real output rather than a configuration shared across targets.
    const check_step = b.step("check", "Compile the library and public API for all targets");
    checkTargetPartition(b);
    for (check_target_queries) |query| {
        const resolved = b.resolveTargetQuery(query);
        const triple = resolved.result.zigTriple(b.allocator) catch @panic("OOM");
        const check_core = addCore(b, resolved, optimize, generated, .static, runtime_loaded);
        const check_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = resolved,
            .optimize = optimize,
            .link_libc = true,
        });
        attachFacade(check_module, b, resolved, optimize, check_core);
        if (resolved.result.os.tag != .wasi) check_step.dependOn(&check_core.zic.step);

        const check_smoke_module = b.createModule(.{
            .root_source_file = b.path("src/smoke.zig"),
            .target = resolved,
            .optimize = optimize,
            .link_libc = true,
        });
        check_smoke_module.addImport("tzdata", check_module);
        const check_smoke = b.addExecutable(.{
            .name = b.fmt("tzdata-smoke-{s}", .{triple}),
            .root_module = check_smoke_module,
        });
        check_step.dependOn(&check_smoke.step);

        const check_tests = b.addTest(.{
            .name = b.fmt("tzdata-test-{s}", .{triple}),
            .root_module = addTestModule(b, resolved, optimize, check_module, test_options),
        });
        check_step.dependOn(&check_tests.step);
    }

    // Real downstream consumer package.  It is a separate Zig build, so it is
    // never part of the default, test or check steps.  The configuration is
    // forwarded rather than left to that build's own default, because a step
    // that quietly built the other configuration would report a passing
    // consumer for a build nobody asked for.  A nested build told nothing
    // resolves the host, `Debug` and the static archive, which are three
    // different libraries from the ones this invocation configured.
    const consumer_run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    consumer_run.setCwd(b.path("consumer"));
    // `run` when this host can execute the resolved target, `install` when it
    // cannot: `hostCanExecute` asks the same question `std.Build.Step.Run` asks
    // about the artifact it is about to spawn.
    consumer_run.addArg(if (hostCanExecute(b, target)) "run" else "install");
    // `standardTargetOptions` reads both of these, and a triple does not carry
    // the CPU model, so a forward that dropped `-Dcpu` would compile the same
    // sources for the same triple at a different feature level.  `-Doptimize`
    // is the consumer's own `standardOptimizeOption`, and it hands that mode to
    // `b.dependency` rather than keeping it to itself.  `addArg` copies each
    // argument, so the two spellings above need no lifetime of their own.
    const consumer_triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    const consumer_cpu = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    consumer_run.addArg(b.fmt("-Dtarget={s}", .{consumer_triple}));
    consumer_run.addArg(b.fmt("-Dcpu={s}", .{consumer_cpu}));
    consumer_run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    // The delivery and the dispatch, written out in both of their values and
    // independently of each other.  The consumer declares both as its own
    // options and hands them to `b.dependency`, where a nullable value is not
    // recorded at all (std/Build.zig:435, :569-581), so a nested build that
    // was not told resolves the library's own defaults instead of this graph's.
    consumer_run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(linkage)}));
    consumer_run.addArg(b.fmt("-Druntime={s}", .{if (runtime_loaded) "true" else "false"}));

    // The release string, handed on as the value this graph resolved rather
    // than only when the caller named it.  The library answers
    // `tzdata_version()` from the `version.h` this same string generated
    // (`src/tzdata_version.c`), and the consumer program prints it, so a
    // nested build that resolved its own default would report a release this
    // invocation never asked for: the enclosing graph would compile its
    // `version.h` and its pkg-config `Version` from one string and run a
    // consumer against another.  The consumer declares the option and records
    // it in the dependency's argument map, so the two graphs cannot answer
    // differently.
    consumer_run.addArg(b.fmt("-Dtz-version={s}", .{version}));

    // The executor switches this build resolved, so the nested build runs its
    // consumer under the same executor this graph would use and
    // `hostCanExecute` above sees the same one.  `-fwasmtime` is how a WASI
    // consumer runs, `-fqemu` a foreign GNU-libc one, and `--libc-runtimes` is
    // that QEMU integration's dynamic-linker support.
    if (b.enable_darling) consumer_run.addArg("-fdarling");
    if (b.enable_qemu) consumer_run.addArg("-fqemu");
    if (b.enable_rosetta) consumer_run.addArg("-frosetta");
    if (b.enable_wasmtime) consumer_run.addArg("-fwasmtime");
    if (b.enable_wine) consumer_run.addArg("-fwine");
    if (b.libc_runtimes_dir) |runtimes| consumer_run.addArgs(&.{ "--libc-runtimes", runtimes });
    // This workspace's job count and step summary, which every `zig build`
    // entry here is expected to carry (`AGENTS.md:157-159`, `README.md:448-449`).
    // `-j8` is not cosmetic on a nested build: nothing can append a `-j` to a
    // `Run` step's command, so one left to derive its own width takes
    // `cpu_count - 1` (`std/Io/Threaded.zig:1639`) rather than the width the
    // caller asked for.  Both are two tokens: `--summary` takes its value as a
    // separate argument.
    consumer_run.addArg("-j8");
    consumer_run.addArgs(&.{ "--summary", "all" });

    // The nested build writes its cache, and the dependency's own install
    // prefix with it (std.Build.determineAndApplyInstallPrefix, Build.zig:708),
    // so an explicit cache directory here becomes a subdirectory of the one
    // this build uses: two graphs must not write one manifest directory, and
    // nothing this step runs belongs in the source tree.  A null `path` means
    // the working directory, which is already the consumer package.
    if (b.cache_root.path) |cache| {
        consumer_run.addArg("--cache-dir");
        consumer_run.addArg(b.fmt("{s}/consumer", .{cache}));
    }

    // The global cache is the same read and the same handoff.  No caller of
    // this package names it, but this graph inherited it from the build
    // runner before any package script ran
    // (`lib/compiler/build_runner.zig:54`, `:73-76`, `:89`), so without this
    // line a `--global-cache-dir` the caller did name stops here and the
    // nested build resolves a global cache of its own, outside every
    // directory this workspace approved.  Unlike the local directory above it
    // gets no subdirectory, because the two hold different things: the local
    // cache holds the per-build manifest two graphs must not share, while the
    // global one holds the package and hash store both graphs read, which is
    // what sharing it means.  Two arguments, because
    // `--global-cache-dir [path]` is the spelling the build runner documents
    // (`lib/compiler/build_runner.zig:1675`) and the one the build system
    // emits itself (`lib/std/Build/Step/Compile.zig:1478-1479`,
    // `lib/std/Build/Step/TranslateC.zig:179-180`).  No directory is invented
    // for the case where there is no path to inherit: the nested build is then
    // left to resolve its own, which is the state this step is in without
    // this block.
    if (b.graph.global_cache_root.path) |global_cache| {
        consumer_run.addArg("--global-cache-dir");
        consumer_run.addArg(global_cache);
    }

    // The caller's own install prefix, when it named one.  Without it the
    // nested build resolves `<build root>/zig-out`, which is a build artefact
    // inside the repository rather than the place the caller asked for.  A
    // relative `--prefix` would resolve against `consumer/` instead of
    // against this build's root, so it is made absolute before it is handed
    // on; `DESTDIR` needs no forwarding because the nested build inherits the
    // environment this one ran with.
    const default_prefix = b.build_root.join(b.allocator, &.{"zig-out"}) catch @panic("OOM");
    if (!std.mem.eql(u8, b.install_prefix, default_prefix)) {
        const prefix = if (std.fs.path.isAbsolute(b.install_prefix))
            b.install_prefix
        else
            b.pathJoin(&.{ b.graph.cache.cwd, b.install_prefix });
        consumer_run.addArg("--prefix");
        consumer_run.addArg(prefix);
    }

    // `-Dtz-dir` is the one option of this package's four that is
    // deliberately not handed on, and `--prefix` is not what covers it.  A
    // dependency's install prefix is chosen by the build system and by neither
    // caller: `createChild` applies `<cache>/i/<hash>` to every child
    // (`std/Build.zig:336-338`, `determineAndApplyInstallPrefix`, :708-724),
    // and `--prefix` never reaches a child.  So the `TZDIR` the nested
    // build's dependency compiles is `<that prefix>/share/zoneinfo` -- a
    // directory this graph neither publishes nor can name in advance.  Passing
    // this invocation's value on would not make the two graphs agree: this
    // package's consumer declares no such option, so the name would be refused
    // as an invalid option (`std/Build.zig:1644-1652`, called by the build
    // runner at `lib/compiler/build_runner.zig:487-489`), and a value that did
    // reach the dependency would be rejected against the different prefix that
    // dependency installs into, which is the check above.  The nested build
    // resolves its own installed tree instead, and that is the tree its
    // dependency populates and the one the consumer's plain zone names
    // resolve in.

    // The caller's own arguments, last and behind `--`.  A runtime-loaded
    // consumer reads a provider named on its command line, so the chain has to
    // end at the program: this step hands them to the nested `zig build run`,
    // whose own run step passes them on after the zoneinfo directory
    // argument (`consumer/build.zig`, `src/main.zig:143-148`, `:297-301`).  The
    // environment needs no forwarding and reaches the nested program however
    // that package wires its own run step, because a run step inherits the
    // environment of the build that created it unless it is cleared
    // (std/Build/Step/Run.zig:1241-1245).  This build names no provider itself.
    if (b.args) |args| {
        consumer_run.addArg("--");
        consumer_run.addArgs(args);
    }
    // The step's only effect is the nested run.  Without this a repeated
    // `zig build consumer` whose inputs did not change would be skipped as a
    // cache hit (std/Build/Step/Run.zig:926) and report a consumer exchange
    // that never happened.
    consumer_run.has_side_effects = true;
    b.step("consumer", "Run the consumer package (zig build run in consumer/)")
        .dependOn(&consumer_run.step);
}
