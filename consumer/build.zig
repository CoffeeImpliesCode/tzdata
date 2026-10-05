//! Real downstream consumer of the tzdata package.
//!
//! It uses only the public surface a dependent package gets: the `tzdata`
//! module and the `zic` artifact.  It converts instants in two independently
//! sourced databases: zones compiled here at build time with the
//! dependency's own zic, and the database the dependency bundles, reached by
//! plain zone name.  The run is offline and reproducible.
//!
//! `zig build install` delivers this executable instead of running it.  The
//! parent build asks for `install` rather than `run` when this host cannot
//! execute the selected target; nothing here decides that, and a delivered
//! file is compile evidence only.
//!
//! `-Druntime`, `-Dlinkage` and `-Dtz-version` are the dependency's own
//! options, read here and handed on unchanged.  `runtime` says whether the
//! module reaches the `tz_*` entry points through an explicit `load` rather
//! than through a link line; `linkage` says which form of the library the
//! dependency builds and installs; `tz-version` is the release string the
//! dependency compiles into the library, which is the string this program
//! prints at run time.  None of the three is answered here, and none implies
//! another.  A caller who names none of them gets the dependency's own
//! defaults -- linked, static, and the release string that dependency's
//! default carries -- because this package passes no value it did not
//! receive.
//!
//! `-Dtz-dir` is the dependency's one option this package cannot forward, and
//! the reason is that it is not a free-form input: it must name the database
//! directory the dependency's *own* graph installs into, which for a
//! dependency is `<cache>/i/<hash>/share/zoneinfo` and is chosen by the build
//! system rather than by a caller.  See FORK-NOTES.md section 30.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Forwarded to the dependency rather than decided here, so this package
    // cannot build one configuration and link the other.  The default is the
    // dependency's own default, which is the linked one.
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Ask the dependency for its runtime-loading configuration, where the " ++
            "native symbols are resolved at run time instead of linked " ++
            "(default: false)",
    ) orelse false;

    // Unnamed here stays unnamed there.  `std.Build` records a dependency
    // argument only when it carries a value: the enum arm is guarded by
    // `if (maybe_value) |v|` (`std/Build.zig:510-516`) and an optional is
    // unwrapped before that (`std/Build.zig:569-580`), so a `null` is not
    // passed on at all.  The dependency then resolves its own `-Dlinkage`
    // and its `orelse .static` policy stands, which is the library's answer
    // to this question rather than a second one kept in step by hand here.
    // Supplying `.static` instead would freeze today's policy into a second
    // place, where a change of the library's default would silently leave
    // this package behind.
    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Forwarded to the tzdata dependency: which form of the library its " ++
            "build delivers and installs, the default static archive or a " ++
            "real shared object.  Independent of `-Druntime`, which decides " ++
            "whether the module links that library at all, and of the zone " ++
            "data this package compiles with the dependency's own zic, " ++
            "which is generated either way.  Left unset, the library's own " ++
            "default applies.",
    );

    // The release string, forwarded rather than repeated, because the program
    // prints back what the dependency compiled: a dependency built for a
    // different release than the one this invocation configured would report a
    // version nobody asked for.  Unnamed here stays unnamed there, exactly as
    // `linkage` does above.
    //
    // The field is an at-identifier because the option name holds a dash.
    // `b.dependency` keys its argument map by the *struct field name*
    // (`std/Build.zig:421-428`) and the dependency reads that map under the
    // option name it declared (`std/Build.zig:1167-1168`), so a `.tz_version`
    // field would be recorded under a name no `b.option` call ever asks for:
    // the dependency would report an invalid option and fall back to its own
    // default.  `box2d/consumer/build.zig` and `box3d/consumer/build.zig`
    // forward their dashed options the same way.
    const tz_version = b.option(
        []const u8,
        "tz-version",
        "Forwarded to the tzdata dependency: the upstream release string " ++
            "compiled into its library, and so the version this program prints " ++
            "at run time.  Left unset, the library's own default applies.",
    );

    const dep = b.dependency("tzdata", .{
        .target = target,
        .optimize = optimize,
        .runtime = runtime_loaded,
        .linkage = linkage,
        .@"tz-version" = tz_version,
    });

    // Compile data/consumer.zi with the dependency's own zic.
    const zic_run = b.addRunArtifact(dep.artifact("zic"));
    zic_run.addArg("-d");
    const zoneinfo = zic_run.addOutputDirectoryArg("zoneinfo");
    zic_run.addFileArg(b.path("data/consumer.zi"));

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_module.addImport("tzdata", dep.module("tzdata"));
    const exe = b.addExecutable(.{ .name = "tzdata-consumer", .root_module = exe_module });

    const run = b.addRunArtifact(exe);
    // A run step's output directory has no path until that step has run, so
    // the program takes it as an argument instead of reading it here.
    run.addDirectoryArg(zoneinfo);
    // Everything the caller wrote after `--` reaches the program, and it has
    // to follow the directory argument rather than precede it: the program
    // reads `args[1]` as the zoneinfo directory and scans `args[2..]` for
    // `--provider <path>` (`src/main.zig:143-148`, `:297-301`).  Dropping them
    // here leaves a runtime-loaded consumer with no way to name a provider on
    // its command line, which is what the enclosing `consumer` step forwards.
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Run the consumer program against its own compiled zone data");
    run_step.dependOn(&run.step);
    b.installArtifact(exe);
}
