const std = @import("std");

const Build = std.Build;
const Step = std.Build.Step;
const Module = std.Build.Module;
const OptimizeMode = std.builtin.OptimizeMode;

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

/// Absolute path of the zoneinfo tree the library resolves plain zone names
/// in.
///
/// It is a directory this build owns and always produces, which an install
/// prefix is not: a dependent package's install step never runs inside the
/// build that uses it, so a TZDIR baked from `<prefix>/share/zoneinfo` is
/// never populated downstream and every plain zone name fails there.
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
    // A Windows cache root carries backslashes, and tzdir.h embeds this value
    // in a C string literal where a backslash escapes the next character.
    // Forward slashes work in every path API tzcode, zic and Zig use.
    return std.mem.replaceOwned(u8, b.allocator, joined, "\\", "/") catch @panic("OOM");
}

/// Reject a TZDIR that cannot be written into the generated `tzdir.h`.
fn checkTzdirPath(path: []const u8) void {
    if (!std.fs.path.isAbsolute(path)) @panic("-Dtz-dir must be an absolute path");
    // tzdir.h embeds the value in a C string literal: a backslash would
    // escape the next character and a quote would end the literal.
    if (std.mem.indexOfAny(u8, path, "\\\"") != null) {
        @panic("-Dtz-dir must not contain a backslash or a double quote");
    }
}

/// Build the C library, the translated-C module and the zic tool for one target.
fn addCore(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: OptimizeMode,
    generated: *Step.WriteFile,
) Core {
    const defines = cDefines(b, target);

    const library_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    library_module.addIncludePath(b.path("."));
    library_module.addIncludePath(generated.getDirectory());
    configureCMacros(library_module, defines);
    const library = b.addLibrary(.{
        .name = "tz",
        .root_module = library_module,
        .linkage = .static,
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
    // exactly when the library emits the symbol behind it.
    if (defineValue(defines, "HAVE_STRFTIME_L")) |value| {
        if (std.mem.eql(u8, value, "1")) translate_c.defineCMacro("TZDATA_HAVE_STRFTIME_L", "1");
    }
    // asctime.c publishes asctime_r/ctime_r only under SUPPORT_POSIX2008
    // (asctime.c:53-62); otherwise it renames both to static functions.
    if (defineValue(defines, "SUPPORT_POSIX2008")) |value| {
        if (std.mem.eql(u8, value, "1")) translate_c.defineCMacro("TZDATA_HAVE_POSIX2008", "1");
    }
    // tz_tzname is emitted only where HAVE_TZNAME is nonzero and
    // tz_timezone and tz_daylight only where USG_COMPAT is
    // (localtime.c:623-629).  Both are 0 or 1 in cDefines, so the value "1"
    // is exactly the condition the aggregate header tests.
    if (defineValue(defines, "HAVE_TZNAME")) |value| {
        if (std.mem.eql(u8, value, "1")) translate_c.defineCMacro("TZDATA_HAVE_TZNAME", "1");
    }
    if (defineValue(defines, "USG_COMPAT")) |value| {
        if (std.mem.eql(u8, value, "1")) translate_c.defineCMacro("TZDATA_USG_COMPAT", "1");
    }

    return .{
        .library = library,
        .zic = zic,
        .c_module = translate_c.createModule(),
    };
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
    module.addImport("tz_c", core.c_module);
    module.linkLibrary(core.library);
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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = b.option(
        []const u8,
        "tz-version",
        "Upstream release string compiled into version.h (default: 2026e)",
    ) orelse "2026e";
    // The database a program finds by plain zone name is the one this build
    // compiles, not one an install step would copy later.
    const bundled_zoneinfo = bundledZoneinfoDir(b);
    const zoneinfo_dir = b.option(
        []const u8,
        "tz-dir",
        "Absolute TZDIR compiled into the library (default: the database this build compiles)",
    ) orelse bundled_zoneinfo;
    checkTzdirPath(zoneinfo_dir);

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

    const core = addCore(b, target, optimize, generated);
    const module = addFacadeModule(b, target, optimize, core);

    // zic and the compiled database are always host programs: they run on the
    // build machine no matter which target the library was compiled for.
    const host_core = if (target.query.isNative())
        core
    else
        addCore(b, b.resolveTargetQuery(.{}), optimize, generated);

    // zic writes into the bundled directory itself rather than into a path
    // the build runner allocates, because tzdir.h has to name that directory
    // before any step has run.
    const zoneinfo_tree: Build.LazyPath = .{ .cwd_relative = bundled_zoneinfo };
    const zic_run = b.addRunArtifact(host_core.zic);
    zic_run.addArg("-d");
    zic_run.addArg(bundled_zoneinfo);
    for (data_sources) |source| zic_run.addFileArg(b.path(source));

    // The library is linked into every binary that can call it, and each of
    // them may open a zone by name, so the database has to exist before any
    // of them runs.  A dependent package reaches this step through the
    // module graph (the library it links), and the build runner follows the
    // dependency edges from there, so `dep.module("tzdata")` alone is
    // enough.
    core.library.step.dependOn(&zic_run.step);

    b.installArtifact(host_core.zic);
    b.installArtifact(core.library);
    // The source directory is a plain path, so the copy step gets no
    // dependency from it and the zic step has to be wired in by hand.
    const install_zoneinfo = b.addInstallDirectory(.{
        .source_dir = zoneinfo_tree,
        .install_dir = .prefix,
        .install_subdir = "share/zoneinfo",
    });
    install_zoneinfo.step.dependOn(&zic_run.step);
    b.getInstallStep().dependOn(&install_zoneinfo.step);
    // addInstallHeaderFile only creates the step; it does not register it.
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/tzdata.h"), "tzdata.h").step);
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("tzfile.h"), "tzfile.h").step);

    // Paths handed to the tests: the zic binary that generates fixtures and
    // the database it generates, both as absolute paths.
    const test_options = b.addOptions();
    test_options.addOptionPath("zic_exe", host_core.zic.getEmittedBin());
    test_options.addOptionPath("zoneinfo_dir", zoneinfo_tree);

    const unit_tests = b.addTest(.{
        .name = "tzdata-test",
        .root_module = addTestModule(b, target, optimize, module, test_options),
    });
    b.step("test", "Run the tzdata unit tests").dependOn(&b.addRunArtifact(unit_tests).step);

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
    // TZDIR lookup any dependent package gets.
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
    const check_step = b.step("check", "Compile the library and public API for all targets");
    for (check_target_queries) |query| {
        const resolved = b.resolveTargetQuery(query);
        const triple = resolved.result.zigTriple(b.allocator) catch @panic("OOM");
        const check_core = addCore(b, resolved, optimize, generated);
        const check_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = resolved,
            .optimize = optimize,
            .link_libc = true,
        });
        check_module.addImport("tz_c", check_core.c_module);
        check_module.linkLibrary(check_core.library);
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
    // never part of the default, test or check steps.
    const consumer_run = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "run" });
    consumer_run.setCwd(b.path("consumer"));
    b.step("consumer", "Run the consumer package (zig build run in consumer/)")
        .dependOn(&consumer_run.step);
}
