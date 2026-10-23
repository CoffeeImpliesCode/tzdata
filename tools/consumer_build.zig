//! Pass maker-resolved toolchain paths through the nested build's environment.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 5) return error.MissingBuildArguments;

    try init.environ_map.put("ZIG_GLOBAL_CACHE_DIR", args[1]);
    try init.environ_map.put("ZIG_LIB_DIR", args[2]);
    const argv = try arena.alloc([]const u8, args.len - 3);
    for (argv, args[3..]) |*argument, value| argument.* = value;
    var child = try std.process.spawn(init.io, .{
        .argv = argv,
        .environ_map = init.environ_map,
    });
    defer child.kill(init.io);
    const term = try child.wait(init.io);
    switch (term) {
        .exited => |status| if (status != 0) std.process.exit(status),
        else => return error.BuildTerminated,
    }
}
