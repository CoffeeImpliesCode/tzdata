// SPDX-License-Identifier: Unlicense

const std = @import("std");

const Build = std.Build;
const Step = std.Build.Step;
const Module = std.Build.Module;
const Optimize = std.lang.Optimize;

/// Runtime-loader build graph.
const graph = @import("runtime/graph.zig");

/// tzcode sources and the fork's version accessor.
const lib_sources = [_][]const u8{
    "localtime.c",
    "asctime.c",
    "difftime.c",
    "strftime.c",
    "src/tzdata_version.c",
};

/// Upstream TDATA files compiled directly by zic (Makefile:1208-1212).
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

/// Upstream tables installed with the TZif tree; derived text files are absent.
const table_sources = [_][]const u8{
    "iso3166.tab",
    "zone.tab",
    "zone1970.tab",
    "zonenow.tab",
};

/// Manual pages for programs this package builds.
const manual_sources = [_]struct { section: []const u8, path: []const u8 }{
    .{ .section = "3", .path = "newctime.3" },
    .{ .section = "3", .path = "newtzset.3" },
    .{ .section = "5", .path = "tzfile.5" },
    .{ .section = "8", .path = "zic.8" },
};

/// Licence and provenance files installed with every linkage.
const licence_sources = [_][]const u8{
    "LICENSE",
    "NOTICE.md",
    "FORK-LICENSE.md",
    "UPSTREAM.md",
};

/// Targets compiled by `zig build check`.
const check_target_queries = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .wasm32, .os_tag = .wasi },
};

const Define = struct { name: []const u8, value: []const u8 };

/// Accumulate target-specific preprocessor definitions.
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
    /// Macros applied to C sources and pkg-config metadata.
    defines: []const Define,
    /// Whether calls use generated dispatch or link the native library.
    runtime_loaded: bool,
};

/// Preprocessor configuration for one target.
fn cDefines(b: *Build, target: Build.ResolvedTarget) []const Define {
    var defines: Defines = .{ .b = b };

    // -DHAVE_GETTEXT=0: never require libintl on any target.
    defines.add("HAVE_GETTEXT", "0");
    defines.add("PORT_TO_C89", "0");
    // Keep upstream's SUPPORT_C89 default.
    defines.add("SUPPORT_C89", "1");
    // Enable tzalloc and the X3J11-inspired API on all targets.
    defines.add("NETBSD_INSPIRED", "1");
    defines.add("STD_INSPIRED", "1");
    defines.add("TZ_RUNTIME_LEAPS", "1");
    defines.add("HAVE_GETRANDOM", "0");
    defines.add("HAVE_UTMPX_H", "0");
    defines.add("HAVE_SNPRINTF", "1");
    defines.add("HAVE_STRDUP", "1");
    defines.add("HAVE_POSIX_DECLS", "1");
    defines.add("HAVE_SYS_STAT_H", "1");
    defines.add("HAVE_UNISTD_H", "1");
    defines.add("HAVE_STRUCT_TIMESPEC", "1");
    defines.add("HAVE_MALLOC_ERRNO", "1");
    // Prefix exported tzcode symbols to avoid libc collisions (private.h:776-785).
    defines.add("time_tz", "time_t");

    switch (target.result.os.tag) {
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => {
            defines.add("HAVE_FCHMOD", "1");
            defines.add("HAVE_LINK", "1");
            defines.add("HAVE_SYMLINK", "1");
            defines.add("HAVE_PWD_H", "1");
            defines.add("HAVE_STRFTIME_L", "1");
            defines.add("HAVE_STRUCT_STAT_ST_CTIM", "1");
            // Match translated declarations to the compiler's POSIX feature set.
            defines.add("SUPPORT_POSIX2008", "1");
            // Pin timezone globals to match the exported names (localtime.c:623-629).
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
            // Windows mkdir requires <direct.h>.
            defines.add("HAVE_DIRECT_H", "1");
            // zic copies files when links are unavailable.
            defines.add("HAVE_LINK", "0");
            defines.add("HAVE_SYMLINK", "0");
            defines.add("HAVE_FCHMOD", "0");
            defines.add("HAVE_SETMODE", "0");
            defines.add("HAVE_PWD_H", "0");
            // mingw-w64 exposes _strftime_l without locale_t.
            defines.add("HAVE_STRFTIME_L", "0");
            // mingw-w64 stat lacks st_ctim.
            defines.add("HAVE_STRUCT_STAT_ST_CTIM", "0");
            // mingw-w64 hides asctime_r/ctime_r; disable their exports (asctime.c:53-62).
            defines.add("SUPPORT_POSIX2008", "0");
            defines.add("HAVE_DECL_ASCTIME_R", "0");
            // mingw-w64 struct tm has neither tm_gmtoff nor tm_zone.
            defines.add("NO_TM_GMTOFF", "1");
            defines.add("NO_TM_ZONE", "1");
            // Pin timezone globals to match declarations on fallback targets.
            defines.add("HAVE_TZNAME", "0");
            defines.add("USG_COMPAT", "0");
        },
        .wasi => {
            defines.add("HAVE_MEMPCPY", "1");
            defines.add("HAVE_GETRESUID", "0");
            defines.add("HAVE_GETEUID", "0");
            // WASI exposes musl auxv headers but lacks getauxval; disable that path (Makefile:241-242).
            defines.add("HAVE_SYS_AUXV_H", "0");
            // wasi-libc provides hard links, symlinks, and fchmod.
            defines.add("HAVE_FCHMOD", "1");
            defines.add("HAVE_LINK", "1");
            defines.add("HAVE_SYMLINK", "1");
            // wasi-libc has no passwd database or setmode.
            defines.add("HAVE_PWD_H", "0");
            defines.add("HAVE_SETMODE", "0");
            defines.add("HAVE_STRFTIME_L", "1");
            defines.add("HAVE_STRUCT_STAT_ST_CTIM", "1");
            defines.add("SUPPORT_POSIX2008", "1");
            // Set timezone-global exports explicitly for WASI.
            defines.add("HAVE_TZNAME", "1");
            defines.add("USG_COMPAT", "1");
        },
        else => {
            // Unknown targets use conservative feature flags.
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

fn defineValue(defines: []const Define, name: []const u8) ?[]const u8 {
    for (defines) |d| {
        if (std.mem.eql(u8, d.name, name)) return d.value;
    }
    return null;
}

fn configureCMacros(module: *Module, defines: []const Define) void {
    for (defines) |d| module.addCMacro(d.name, d.value);
}

/// Maps upstream feature macros to translated names for bindings, pkg-config, and DLL exports.
const translated_macros = [_]struct { upstream: []const u8, translated: []const u8 }{
    .{ .upstream = "HAVE_STRFTIME_L", .translated = "TZDATA_HAVE_STRFTIME_L" },
    .{ .upstream = "SUPPORT_POSIX2008", .translated = "TZDATA_HAVE_POSIX2008" },
    .{ .upstream = "HAVE_TZNAME", .translated = "TZDATA_HAVE_TZNAME" },
    .{ .upstream = "USG_COMPAT", .translated = "TZDATA_USG_COMPAT" },
};

/// Return translated macros enabled for this target.
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

/// Hash zone sources to isolate compiled TZif trees by input.
fn zoneDataDigest(b: *Build) [8]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (data_sources) |name| {
        const source_path = b.root.join(b.allocator, name) catch @panic("OOM");
        b.dependOnFileContents(b.path(name));
        const bytes = source_path.root_dir.handle.readFileAlloc(
            b.graph.io,
            source_path.sub_path,
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

/// Build-cache directory for zic's digest-specific TZif tree.
fn bundledZoneinfoDir(b: *Build) Build.LazyPath {
    const hex = std.fmt.bytesToHex(zoneDataDigest(b), .lower);
    return .{ .relative = .{
        .base = .local_cache,
        .sub_path = b.fmt("tzdata-zoneinfo-{s}", .{&hex}),
    } };
}

/// Installation path compiled into the library's TZDIR.
fn installedZoneinfoPath() Build.LazyPath {
    return .{ .relative = .{
        .base = .install_prefix,
        .sub_path = "share/zoneinfo",
    } };
}

/// Validate an absolute, quote-free TZDIR before generating `tzdir.h`.
fn checkTzdirPath(path: []const u8) void {
    if (!std.fs.path.isAbsolute(path)) @panic("the TZDIR must be an absolute path");
    // A quote would terminate the C string in `tzdir.h`.
    if (std.mem.indexOf(u8, path, "\"") != null) {
        @panic("the TZDIR must not contain a double quote");
    }
}

/// Reject TZDIR spellings changed by path normalization.
fn checkUserTzdirPath(path: []const u8) void {
    checkTzdirPath(path);
    if (std.mem.indexOf(u8, path, "\\") != null) {
        @panic("-Dtz-dir must use forward slashes, not backslashes");
    }
}

/// Build the library, translated module, and zic for one target.
fn addCore(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: Optimize,
    generated: *Step.WriteFile,
    tzdir_header: Build.LazyPath,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
) Core {
    const defines = cDefines(b, target);

    const library_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // Shared objects need PIC; static builds keep the compiler default.
        .pic = switch (linkage) {
            .dynamic => true,
            .static => null,
        },
    });
    library_module.addIncludePath(b.path("."));
    library_module.addIncludePath(generated.getDirectory());
    library_module.addIncludePath(tzdir_header.dirname());
    configureCMacros(library_module, defines);
    const library = b.addLibrary(.{
        .name = "tz",
        .root_module = library_module,
        .linkage = linkage,
        // Windows DLLs need an explicit export list; other formats export public symbols.
        // The list comes from `publicSymbols`.
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
    zic_module.addIncludePath(tzdir_header.dirname());
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
    // Keep translated declarations aligned with this target's exported symbols.
    for (enabledTranslatedMacros(defines, b.allocator)) |name| {
        translate_c.defineCMacro(name, "1");
    }

    // Runtime mode dispatches through the same target-specific translation.
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

/// Shared-library exports. ELF and Mach-O export visible symbols; Windows needs a module definition.
/// Conditional exports follow the feature macros used by the translated header.
fn publicSymbols(b: *Build, defines: []const Define) []const []const u8 {
    const always = [_][]const u8{
        "tz_localtime_rz", "tz_mktime_z",     "tz_tzalloc",    "tz_tzfree",
        "tz_offtime",      "tz_offtime_r",    "tz_timelocal",  "tz_timeoff",
        "tz_posix2time",   "tz_posix2time_z", "tz_time2posix", "tz_time2posix_z",
        "tz_localtime",    "tz_localtime_r",  "tz_gmtime",     "tz_gmtime_r",
        "tz_mktime",       "tz_timegm",       "tz_time",       "tz_tzset",
        "tz_ctime",        "tz_asctime",      "tz_difftime",   "tz_strftime",
        "tzdata_version",  "tzdata_package",
    };

    var symbols: std.ArrayList([]const u8) = .empty;
    symbols.appendSlice(b.allocator, &always) catch @panic("OOM");

    for (translated_macros) |entry| {
        const value = defineValue(defines, entry.upstream) orelse continue;
        if (!std.mem.eql(u8, value, "1")) continue;
        if (std.mem.eql(u8, entry.translated, "TZDATA_HAVE_POSIX2008")) {
            // SUPPORT_POSIX2008 controls these asctime symbols (asctime.c:53-62).
            symbols.appendSlice(b.allocator, &.{ "tz_asctime_r", "tz_ctime_r" }) catch @panic("OOM");
        } else if (std.mem.eql(u8, entry.translated, "TZDATA_HAVE_STRFTIME_L")) {
            symbols.appendSlice(b.allocator, &.{"tz_strftime_l"}) catch @panic("OOM");
        } else if (std.mem.eql(u8, entry.translated, "TZDATA_HAVE_TZNAME")) {
            // `tz_tzname` is an exported data symbol (localtime.c:623-629).
            symbols.appendSlice(b.allocator, &.{"tz_tzname"}) catch @panic("OOM");
        } else if (std.mem.eql(u8, entry.translated, "TZDATA_USG_COMPAT")) {
            symbols.appendSlice(b.allocator, &.{ "tz_timezone", "tz_daylight" }) catch @panic("OOM");
        } else unreachable;
    }
    return symbols.items;
}

/// Write pkg-config flags from the library's macros and the translated header.
/// The relative prefix follows the installed file; linkage selects the artifact.
fn addPkgConfig(
    b: *Build,
    defines: []const Define,
    version: []const u8,
    linkage: std.lang.LinkMode,
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

/// Write the Windows DLL export list for shared builds.
/// It contains only symbols returned by `publicSymbols`.
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

/// Attach a facade to its matching C module and runtime loader.
/// Runtime mode must not link the library or import a second loader instance.
fn attachFacade(
    module: *Module,
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: Optimize,
    core: Core,
) void {
    module.addImport("tz_c", core.c_module);
    if (core.runtime_loaded) return;
    module.linkLibrary(core.library);
    module.addImport("rt", graph.createCoreModule(b, target, optimize));
}

/// Create the public module with its facade and translated C declarations.
fn addFacadeModule(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: Optimize,
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
    optimize: Optimize,
    tz_module: *Module,
    test_options: *Module,
) *Module {
    const module = b.createModule(.{
        .root_source_file = b.path("test/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("tzdata", tz_module);
    module.addImport("build_options", test_options);
    return module;
}

/// Describe why a target cannot be configured, or return null when supported.
const Refusal = struct {
    /// One line, printed with the triple in front of it.
    summary: []const u8,
    /// The long form, printed under it.
    detail: []const u8,
};

/// Describe platform facts that make target configurations unsupported.
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

/// Fail early with the platform reason when a target is unsupported.
fn refuseTarget(b: *Build, target: Build.ResolvedTarget) error{UnsupportedTarget} {
    const refusal = refusalFor(target) orelse
        @panic("build.zig internal error: refusalFor returned null for a target this build refused");
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    std.log.err("tzdata: {s}: {s}\n{s}", .{ triple, refusal.summary, refusal.detail });
    return error.UnsupportedTarget;
}

/// Keep the refusal table and the `check` target matrix consistent.
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

/// Return whether `std.Build.Step.Run` can execute the target without an explicit executor.
fn hostCanExecute(b: *Build, target: Build.ResolvedTarget) bool {
    const host = &b.graph.host.result;
    const candidate = &target.result;
    const options: std.zig.system.GetExternalExecutorOptions = .{
        .host_cpu_arch = host.cpu.arch,
        .host_os_tag = host.os.tag,
        .link_mode = .dynamic,
        .link_libc = true,
    };
    return switch (std.zig.system.getExternalExecutor(b.graph.io, candidate, options)) {
        .native => true,
        else => false,
    };
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Refuse unsupported targets before creating build steps.
    if (refusalFor(target) != null) return refuseTarget(b, target);

    const version = b.option(
        []const u8,
        "tz-version",
        "Upstream release string compiled into version.h (default: 2026e)",
    ) orelse "2026e";

    const linkage = b.option(
        std.lang.LinkMode,
        "linkage",
        "Link the tz library statically or dynamically (default: static)",
    ) orelse .static;

    // Runtime loading changes symbol resolution, not the selected library form.
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Resolve the native symbols at run time through the platform loader " ++
            "instead of linking them (default: false). Independent of " ++
            "-Dlinkage, which still decides the form of the installed library.",
    ) orelse false;

    // Install-prefix paths are resolved by the maker, not during graph configuration.
    const installed_zoneinfo = installedZoneinfoPath();
    const requested_tz_dir = b.option(
        []const u8,
        "tz-dir",
        "Assert the absolute installed database directory compiled into the library",
    );
    if (requested_tz_dir) |requested| checkUserTzdirPath(requested);

    const bundled_zoneinfo = bundledZoneinfoDir(b);

    // Generate the headers normally produced by upstream's Makefile.
    const generated = b.addWriteFiles();
    _ = generated.add("version.h", b.fmt(
        \\static char const PKGVERSION[] = "(tzcode) ";
        \\static char const TZVERSION[] = "{s}";
        \\static char const REPORT_BUGS_TO[] = "tz@iana.org";
        \\
    , .{version}));

    const tzdir_generator = b.addExecutable(.{
        .name = "tzdata-tzdir-header",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tzdir_header.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const tzdir_run = b.addRunArtifact(tzdir_generator);
    tzdir_run.addArg("--zoneinfo");
    tzdir_run.addDirectoryArg2(installed_zoneinfo, .{ .make_absolute = true });
    if (requested_tz_dir) |requested| {
        tzdir_run.addArg("--expected");
        tzdir_run.addArg(requested);
    }
    tzdir_run.addArg("--output");
    const tzdir_header = tzdir_run.addOutputFileArg2("tzdir.h", .{ .make_absolute = true });

    const core = addCore(b, target, optimize, generated, tzdir_header, linkage, runtime_loaded);
    const module = addFacadeModule(b, target, optimize, core);

    // Cross builds use a host zic to compile the zone database.
    // Configure that tool as static and without runtime dispatch.
    const host_core = if (target.query.isNative())
        core
    else
        addCore(b, b.resolveTargetQuery(.{}), optimize, generated, tzdir_header, .static, false);

    // Write directly to the digest-specific cache tree.
    const zoneinfo_tree = bundled_zoneinfo;
    const zic_run = b.addRunArtifact(host_core.zic);
    zic_run.addArg("-d");
    zic_run.addDirectoryArg2(zoneinfo_tree, .{ .make_absolute = true });
    for (data_sources) |source| zic_run.addFileArg2(b.path(source), .{});
    // Bind the generated tree to the library and install step; runtime mode does not link the library.
    // Wire zic explicitly because the source path carries no build dependency.
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

    // Install upstream's auxiliary zone tables, man pages, and licence material.
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
    core.library.installHeader(b.path("include/tzdata.h"), "tzdata.h");
    core.library.installHeader(b.path("tzfile.h"), "tzfile.h");

    // Resolve both paths during make, when relative prefixes are known.
    const test_options_generator = b.addExecutable(.{
        .name = "tzdata-test-options",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/test_options.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const test_options_run = b.addRunArtifact(test_options_generator);
    test_options_run.addArg("--zoneinfo");
    test_options_run.addDirectoryArg2(installed_zoneinfo, .{ .make_absolute = true });
    test_options_run.addArg("--zic");
    test_options_run.addFileArg2(host_core.zic.getEmittedBin(), .{ .make_absolute = true });
    test_options_run.addArg("--output");
    const test_options_source = test_options_run.addOutputFileArg2("test-options.zig", .{ .make_absolute = true });
    const test_options = b.createModule(.{ .root_source_file = test_options_source });

    const unit_tests = b.addTest(.{
        .name = "tzdata-test",
        .root_module = addTestModule(b, target, optimize, module, test_options),
    });
    const unit_test_run = b.addRunArtifact(unit_tests);
    unit_test_run.setCwd(Build.LazyPath.cache_root);
    // Bind the run directly: runtime mode does not link the library dependency.
    unit_test_run.step.dependOn(&install_zoneinfo.step);
    b.step("test", "Run the tzdata unit tests").dependOn(&unit_test_run.step);

    // Fixed timestamps keep smoke output reproducible.
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
    // Bind smoke runs to the installed tree, as runtime mode has no library dependency.
    smoke_run.step.dependOn(&install_zoneinfo.step);
    smoke_run.addPassthruArgs();
    b.step("smoke", "Run the deterministic smoke program").dependOn(&smoke_run.step);

    // Check licence and provenance integrity of the upstream files.
    const provenance_run = b.addRunArtifact(b.addExecutable(.{
        .name = "tzdata-provenance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/provenance_check.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = .safe,
        }),
    }));
    provenance_run.addFileArg2(b.path("PROVENANCE.sha256"), .{});
    provenance_run.addArg(".");
    b.step("provenance", "Verify preserved upstream files against PROVENANCE.sha256")
        .dependOn(&provenance_run.step);

    // Compile each target's library, facade, smoke program, and tests; zic runs on the host because WASI lacks umask and signals.
    // The matrix checks the static form; linkage separately selects the installed artifact.
    // Forward runtime mode because it changes facade imports for each target.
    const check_step = b.step("check", "Compile the library and public API for all targets");
    checkTargetPartition(b);
    for (check_target_queries) |query| {
        const resolved = b.resolveTargetQuery(query);
        const triple = resolved.result.zigTriple(b.allocator) catch @panic("OOM");
        const check_core = addCore(b, resolved, optimize, generated, tzdir_header, .static, runtime_loaded);
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

    // Run the real downstream consumer in a separate build step.
    const consumer_launcher = b.addExecutable(.{
        .name = "tzdata-consumer-build",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/consumer_build.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const consumer_run = b.addRunArtifact(consumer_launcher);
    consumer_run.addDirectoryArg2(.{ .relative = .{ .base = .global_cache } }, .{ .make_absolute = true });
    consumer_run.addDirectoryArg2(Build.LazyPath.zig_lib, .{ .make_absolute = true });
    consumer_run.addArgs(&.{ b.graph.zig_exe, "build" });
    consumer_run.setCwd(b.path("consumer"));
    // Native targets can run directly; foreign targets use the nested conditional step.
    consumer_run.addArg(if (hostCanExecute(b, target)) "run" else "consumer");
    // Preserve the target, CPU features, and optimization in the nested build.
    const consumer_triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    const consumer_cpu = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    consumer_run.addArg(b.fmt("-Dtarget={s}", .{consumer_triple}));
    consumer_run.addArg(b.fmt("-Dcpu={s}", .{consumer_cpu}));
    consumer_run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    // Forward resolved linkage and runtime options instead of nested defaults.
    consumer_run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(linkage)}));
    consumer_run.addArg(b.fmt("-Druntime={s}", .{if (runtime_loaded) "true" else "false"}));

    // Keep the consumer's version equal to the one generated by this build.
    consumer_run.addArg(b.fmt("-Dtz-version={s}", .{version}));

    // Forward make-phase executor selections without reading hidden configure options.
    consumer_run.addThirdPartyEnabledArgDarling(.{
        .enabled = "-fdarling",
        .disabled = "-fno-darling",
    });
    consumer_run.addThirdPartyEnabledArgQemu(.{ .enabled = "-fqemu", .disabled = "-fno-qemu" });
    consumer_run.addThirdPartyEnabledArgRosetta(.{ .enabled = "-frosetta", .disabled = "-fno-rosetta" });
    consumer_run.addThirdPartyEnabledArgWasmtime(.{ .enabled = "-fwasmtime", .disabled = "-fno-wasmtime" });
    consumer_run.addThirdPartyEnabledArgWine(.{ .enabled = "-fwine", .disabled = "-fno-wine" });
    // Zig 0.17 does not expose --libc-runtimes to the build configurator.
    consumer_run.addArg("-j8");
    consumer_run.addArgs(&.{ "--summary", "all" });

    // Isolate the consumer's local manifest cache and preserve the global cache.
    consumer_run.addArg("--cache-dir");
    consumer_run.addDirectoryArg2(.{ .relative = .{
        .base = .local_cache,
        .sub_path = "consumer",
    } }, .{ .make_absolute = true });

    // The maker resolves the outer install prefix for the nested build.
    consumer_run.addArg("--prefix");
    consumer_run.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix } }, .{ .make_absolute = true });

    // Do not forward `-Dtz-dir`; the nested build checks it against its own resolved prefix.

    // Forward caller arguments after `--` to the consumer's run command.
    consumer_run.addArg("--");
    consumer_run.addPassthruArgs();
    // Always run this step; a cache hit would skip the consumer check.
    consumer_run.has_side_effects = true;
    b.step("consumer", "Run the consumer package (zig build run in consumer/)")
        .dependOn(&consumer_run.step);
}
