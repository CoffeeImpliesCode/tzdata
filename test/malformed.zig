//! Malformed TZif input handling.
//!
//! Each case is a byte string written into a temporary directory; the library
//! is asked to load it through the same public entry point users call.

const std = @import("std");
const tzdata = @import("tzdata");
const support = @import("support.zig");

/// Write `bytes` to `name` in `tmp` and return its absolute path.
fn writeAndOpen(
    tmp: *std.testing.TmpDir,
    name: []const u8,
    bytes: []const u8,
) ![:0]const u8 {
    try tmp.dir.writeFile(support.io, .{ .sub_path = name, .data = bytes });
    return support.tmpPath(support.gpa, tmp, name);
}

fn putU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .big);
}

/// A 44-byte TZif header: magic, version, reserved bytes and the six counts.
fn headerBytes(version: u8, timecnt: u32) [44]u8 {
    var bytes: [44]u8 = @splat(0);
    @memcpy(bytes[0..4], "TZif");
    bytes[4] = version;
    putU32(&bytes, 20, 0); // ttisutcnt
    putU32(&bytes, 24, 0); // ttisstdcnt
    putU32(&bytes, 28, 0); // leapcnt
    putU32(&bytes, 32, timecnt);
    putU32(&bytes, 36, 2); // typecnt
    putU32(&bytes, 40, 4); // charcnt
    return bytes;
}

test "a file without the TZif magic is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var bytes = headerBytes('2', 0);
    @memcpy(bytes[0..4], "XXXX");
    const path = try writeAndOpen(&tmp, "NoMagic", &bytes);
    defer support.gpa.free(path);

    try std.testing.expectError(error.InvalidZone, tzdata.Zone.open(path));
}

test "a TZif file that ends inside its header is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeAndOpen(&tmp, "Short", headerBytes('2', 0)[0..20]);
    defer support.gpa.free(path);

    try std.testing.expectError(error.InvalidZone, tzdata.Zone.open(path));
}

test "a TZif header claiming more transitions than the file holds is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 1000 transitions need at least 4000 bytes of 32-bit data, plus the
    // local time types and abbreviations the counts also promise.
    var bytes: [64]u8 = @splat(0);
    const header = headerBytes('2', 1000);
    @memcpy(bytes[0..44], &header);
    const path = try writeAndOpen(&tmp, "Overstated", &bytes);
    defer support.gpa.free(path);

    try std.testing.expectError(error.InvalidZone, tzdata.Zone.open(path));
}

test "an empty file is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeAndOpen(&tmp, "Empty", "");
    defer support.gpa.free(path);

    try std.testing.expectError(error.InvalidZone, tzdata.Zone.open(path));
}

test "a missing zone file is rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try support.tmpPath(support.gpa, &tmp, "Etc/DoesNotExist");
    defer support.gpa.free(path);

    try std.testing.expectError(error.InvalidZone, tzdata.Zone.open(path));
}
