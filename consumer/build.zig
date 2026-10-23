//! Exercise the dependency's public module and `zic` artifact downstream.
//! Compile test zones and verify bundled-zone access without network access.
//! Install the executable instead of running it when the target cannot execute here.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Forward dependency options unchanged so its defaults stay authoritative.
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Ask the dependency for its runtime-loading configuration, where the " ++
            "native symbols are resolved at run time instead of linked " ++
            "(default: false)",
    ) orelse false;

    // A null option is omitted, preserving the dependency's own linkage default.
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

    // The at-identifier field forwards the dashed option under its declared name.
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
    // Forward arguments after argv[1], the generated zoneinfo directory.
    run.addDirectoryArg(zoneinfo);
    if (b.args) |args| run.addArgs(args);

    const run_step = b.step("run", "Run the consumer program against its own compiled zone data");
    run_step.dependOn(&run.step);
    b.installArtifact(exe);
}
