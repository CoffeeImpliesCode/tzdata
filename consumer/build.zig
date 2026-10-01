//! Real downstream consumer of the tzdata package.
//!
//! It uses only the public surface a dependent package gets: the `tzdata`
//! module and the `zic` artifact.  It converts instants in two independently
//! sourced databases: zones compiled here at build time with the
//! dependency's own zic, and the database the dependency bundles, reached by
//! plain zone name.  The run is offline and reproducible.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("tzdata", .{
        .target = target,
        .optimize = optimize,
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

    const run_step = b.step("run", "Run the consumer program against its own compiled zone data");
    run_step.dependOn(&run.step);
    b.installArtifact(exe);
}
