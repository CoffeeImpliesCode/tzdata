//! Generate test options with absolute make-time install and tool paths.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var zoneinfo_path: ?[]const u8 = null;
    var zic_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const flag = args[index];
        if (std.mem.eql(u8, flag, "--zoneinfo")) {
            zoneinfo_path = try take(args, &index);
        } else if (std.mem.eql(u8, flag, "--zic")) {
            zic_path = try take(args, &index);
        } else if (std.mem.eql(u8, flag, "--output")) {
            output_path = try take(args, &index);
        } else {
            std.debug.print("test_options: unknown argument '{s}'\n", .{flag});
            return error.UnknownArgument;
        }
    }

    const zoneinfo = zoneinfo_path orelse return error.MissingZoneinfoPath;
    const zic = zic_path orelse return error.MissingZicPath;
    const destination = output_path orelse return error.MissingOutputPath;
    if (!std.fs.path.isAbsolute(zoneinfo)) return error.RelativeZoneinfoPath;
    if (!std.fs.path.isAbsolute(zic)) return error.RelativeZicPath;

    var options: std.Io.Writer.Allocating = .init(arena);
    try options.writer.writeAll("pub const zoneinfo_dir: []const u8 = \"");
    try std.zig.stringEscape(zoneinfo, &options.writer);
    try options.writer.writeAll("\";\npub const zic_exe: []const u8 = \"");
    try std.zig.stringEscape(zic, &options.writer);
    try options.writer.writeAll("\";\n");

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = destination,
        .data = options.written(),
    });
}

fn take(args: []const [:0]const u8, index: *usize) error{MissingArgument}![]const u8 {
    if (index.* + 1 >= args.len) return error.MissingArgument;
    index.* += 1;
    return args[index.*];
}
