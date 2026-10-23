//! Generate tzdir.h from the installation path resolved by the build maker.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var zoneinfo_path: ?[]const u8 = null;
    var expected_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const flag = args[index];
        if (std.mem.eql(u8, flag, "--zoneinfo")) {
            zoneinfo_path = try take(args, &index);
        } else if (std.mem.eql(u8, flag, "--expected")) {
            expected_path = try take(args, &index);
        } else if (std.mem.eql(u8, flag, "--output")) {
            output_path = try take(args, &index);
        } else {
            std.debug.print("tzdir_header: unknown argument '{s}'\n", .{flag});
            return error.UnknownArgument;
        }
    }

    const raw_path = zoneinfo_path orelse return error.MissingZoneinfoPath;
    const destination = output_path orelse return error.MissingOutputPath;
    if (!std.fs.path.isAbsolute(raw_path)) return error.RelativeZoneinfoPath;
    if (std.mem.findScalar(u8, raw_path, '"') != null) return error.InvalidZoneinfoPath;

    const normalized_path = try std.mem.replaceOwned(u8, arena, raw_path, "\\", "/");
    if (expected_path) |expected| {
        if (!std.mem.eql(u8, expected, normalized_path)) {
            std.debug.print(
                "tzdata: -Dtz-dir must name the installed database directory " ++
                    "{s}, but it is {s}\n",
                .{ normalized_path, expected },
            );
            return error.TzdirMismatch;
        }
    }

    var header: std.Io.Writer.Allocating = .init(arena);
    try header.writer.writeAll(
        "#ifndef TZDEFAULT\n" ++
            "# define TZDEFAULT \"/etc/localtime\" /* default zone */\n" ++
            "#endif\n" ++
            "#ifndef TZDIR\n" ++
            "# define TZDIR \"",
    );
    try writeCString(&header.writer, normalized_path);
    try header.writer.writeAll("\" /* TZif directory */\n#endif\n");

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = destination,
        .data = header.written(),
    });
}

fn take(args: []const [:0]const u8, index: *usize) error{MissingArgument}![]const u8 {
    if (index.* + 1 >= args.len) return error.MissingArgument;
    index.* += 1;
    return args[index.*];
}

fn writeCString(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    for (bytes) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(byte),
    };
}
