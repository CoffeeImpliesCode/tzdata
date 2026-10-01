//! Helpers shared by the tzdata tests.
//!
//! Fixture databases are produced at test time by this package's own zic, so
//! the tests exercise the real compiler and the real library together instead
//! of trusting a checked-in binary blob.

const std = @import("std");
const build_options = @import("build_options");

pub const io = std.testing.io;
pub const gpa = std.testing.allocator;

/// Absolute path of `name` inside a `std.testing.TmpDir`.
pub fn tmpPath(
    allocator: std.mem.Allocator,
    tmp: *const std.testing.TmpDir,
    name: []const u8,
) ![:0]const u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fmt.allocPrintSentinel(
        allocator,
        "{s}/.zig-cache/tmp/{s}/{s}",
        .{ cwd, tmp.sub_path[0..], name },
        0,
    );
}

/// Run this package's zic with `args` and fail the test if it does not exit 0.
pub fn runZic(args: []const []const u8) !void {
    const result = try std.process.run(gpa, io, .{
        .argv = args,
        .stdout_limit = .limited(1 << 16),
        .stderr_limit = .limited(1 << 16),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("zic exited with {d}: {s}\n", .{ code, result.stderr });
                return error.ZicFailed;
            }
        },
        else => {
            std.debug.print("zic did not exit normally: {t}\n", .{result.term});
            return error.ZicFailed;
        },
    }
}

/// Directory below `tmp` that zic writes its TZif tree into.
pub const fixture_dir = "zoneinfo";

/// Write `source` to `name` in `tmp` and compile it with zic into
/// `fixture_dir` below `tmp`.  zic creates the directory itself and derives
/// every zone name in the source from it, so the compiled files are at
/// `fixture_dir/<zone>` and nowhere else.
pub fn compileFixture(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    name: []const u8,
    source: []const u8,
) !void {
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = source });
    const destination = try fixtureRoot(allocator, tmp);
    defer allocator.free(destination);
    const source_path = try tmpPath(allocator, tmp, name);
    defer allocator.free(source_path);
    try runZic(&.{ build_options.zic_exe, "-d", destination, source_path });
}

/// Absolute path of the fixture database `compileFixture` produced.
pub fn fixtureRoot(
    allocator: std.mem.Allocator,
    tmp: *const std.testing.TmpDir,
) ![:0]const u8 {
    return tmpPath(allocator, tmp, fixture_dir);
}

/// Path of `zone` inside the fixture database, relative to `tmp.dir`.
///
/// This is the one place that knows `zic` writes the tree into `fixture_dir`,
/// so both the absolute form below and the read helper compose from it.
pub fn fixtureZoneSubPath(
    allocator: std.mem.Allocator,
    zone: []const u8,
) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ fixture_dir, zone }, 0);
}

/// Absolute path of `zone` inside the fixture database.
pub fn fixtureZone(
    allocator: std.mem.Allocator,
    tmp: *const std.testing.TmpDir,
    zone: []const u8,
) ![:0]const u8 {
    const sub_path = try fixtureZoneSubPath(allocator, zone);
    defer allocator.free(sub_path);
    return tmpPath(allocator, tmp, sub_path);
}

/// Read the compiled TZif file for `zone` out of the fixture database.
pub fn readFixture(
    allocator: std.mem.Allocator,
    tmp: *const std.testing.TmpDir,
    zone: []const u8,
    limit: std.Io.Limit,
) ![]u8 {
    const sub_path = try fixtureZoneSubPath(allocator, zone);
    defer allocator.free(sub_path);
    return tmp.dir.readFileAlloc(io, sub_path, allocator, limit);
}

/// Absolute path of `zone` inside the database this build generated.
pub fn databaseZone(
    allocator: std.mem.Allocator,
    zone: [:0]const u8,
) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(
        allocator,
        "{s}/{s}",
        .{ build_options.zoneinfo_dir, zone },
        0,
    );
}

/// Big-endian integer readers for TZif headers and bodies.
pub fn readU32(bytes: []const u8, offset: usize) !u32 {
    if (offset + 4 > bytes.len) return error.Truncated;
    const raw: *const [4]u8 = bytes[offset..][0..4];
    return std.mem.readInt(u32, raw, .big);
}

pub fn readI32(bytes: []const u8, offset: usize) !i32 {
    if (offset + 4 > bytes.len) return error.Truncated;
    const raw: *const [4]u8 = bytes[offset..][0..4];
    return std.mem.readInt(i32, raw, .big);
}

pub fn readI64(bytes: []const u8, offset: usize) !i64 {
    if (offset + 8 > bytes.len) return error.Truncated;
    const raw: *const [8]u8 = bytes[offset..][0..8];
    return std.mem.readInt(i64, raw, .big);
}

/// The fixed part of a TZif file header (Internet RFC 9636).
pub const TzifHeader = struct {
    version: u8,
    ttisutcnt: u32,
    ttisstdcnt: u32,
    leapcnt: u32,
    timecnt: u32,
    typecnt: u32,
    charcnt: u32,
};

/// Offset of the 32-bit data block that follows the header.
pub const data_offset = 4 + 1 + 15 + 6 * 4;

pub fn parseHeader(bytes: []const u8) !TzifHeader {
    if (bytes.len < data_offset) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], "TZif")) return error.BadMagic;
    var offset: usize = 20;
    const header: TzifHeader = .{
        .version = bytes[4],
        .ttisutcnt = try readU32(bytes, offset),
        .ttisstdcnt = try readU32(bytes, offset + 4),
        .leapcnt = try readU32(bytes, offset + 8),
        .timecnt = try readU32(bytes, offset + 12),
        .typecnt = try readU32(bytes, offset + 16),
        .charcnt = try readU32(bytes, offset + 20),
    };
    offset += 24;
    return header;
}

/// Size of the data block (transitions, types, abbreviations, leap seconds
/// and transition flags) that follows a header with the given counts.
pub fn dataSize(header: TzifHeader, wide: bool) usize {
    const time_size: usize = if (wide) 8 else 4;
    return header.timecnt * time_size +
        header.timecnt +
        header.typecnt * 6 +
        header.charcnt +
        header.leapcnt * (time_size + 4) +
        header.ttisstdcnt +
        header.ttisutcnt;
}
