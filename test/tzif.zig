//! Interoperability tests between this package's zic and its library.
//!
//! The fixture source lives in test/data/fixture.zi; the expected transition
//! instants below are derived from that file by hand (2:00 local standard
//! time on the Sunday on or after 8 March, 2:00 local daylight time on the
//! Sunday on or after 1 November, in 2005 and 2006), not from zic output.

const std = @import("std");
const tzdata = @import("tzdata");
const support = @import("support.zig");

const fixture_source = @embedFile("data/fixture.zi");

const expected_transitions = [_]i64{
    1110697200, // 2005-03-13T07:00:00Z
    1131256800, // 2005-11-06T06:00:00Z
    1142146800, // 2006-03-12T07:00:00Z
    1162706400, // 2006-11-05T06:00:00Z
};

const read_limit: std.Io.Limit = .limited(1 << 20);

fn compileFixture(tmp: *std.testing.TmpDir) !void {
    try support.compileFixture(support.gpa, tmp, "fixture.zi", fixture_source);
}

test "zic writes a TZif file whose transitions match the fixture rules" {
    try support.requireProvider();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compileFixture(&tmp);

    const bytes = try support.readFixture(support.gpa, &tmp, "Etc/Fixture", read_limit);
    defer support.gpa.free(bytes);

    const header = try support.parseHeader(bytes);
    try std.testing.expect(header.version >= '2');
    // Slim TZif may omit transitions from its compatibility block.
    var offset: usize = support.data_offset + support.dataSize(header, false);
    const wide_header = try support.parseHeader(bytes[offset..]);
    try std.testing.expectEqual(@as(u32, expected_transitions.len), wide_header.timecnt);
    try std.testing.expectEqual(@as(u32, 0), wide_header.leapcnt);
    offset += support.data_offset;
    for (expected_transitions) |expected| {
        try std.testing.expectEqual(expected, try support.readI64(bytes, offset));
        offset += 8;
    }

    // The abbreviations of the fixture must be present in the wide block.
    offset += @as(usize, wide_header.timecnt) + @as(usize, wide_header.typecnt) * 6;
    const abbreviations = bytes[offset..][0..wide_header.charcnt];
    try std.testing.expect(std.mem.indexOf(u8, abbreviations, "Fxs") != null);
    try std.testing.expect(std.mem.indexOf(u8, abbreviations, "Fxd") != null);
}

test "the library converts instants around the fixture's daylight saving changes" {
    try support.requireProvider();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compileFixture(&tmp);

    const zone_path = try support.fixtureZone(support.gpa, &tmp, "Etc/Fixture");
    defer support.gpa.free(zone_path);
    var zone = try tzdata.Zone.open(zone_path);
    defer zone.close();
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    // Before any transition: the zone's standard type, -5:00 "Fxs".
    const before_epoch = try zone.toLocal(-1);
    try std.testing.expectEqual(@as(i64, -5 * 3600), try zone.utcOffset(-1));
    try std.testing.expectEqualStrings("Fxs", before_epoch.zone.?);
    // Where struct tm carries tm_gmtoff, it must agree with the zone.
    if (before_epoch.utcOffset()) |carried| {
        try std.testing.expectEqual(carried, try zone.utcOffset(-1));
    }

    // One second before and one second after 2005-03-13T07:00:00Z.
    try std.testing.expectEqualStrings("Fxs", (try zone.toLocal(1110697199)).zone.?);
    try std.testing.expectEqualStrings("Fxd", (try zone.toLocal(1110697200)).zone.?);
    const in_daylight = try zone.toLocal(1110697200);
    try std.testing.expectEqual(@as(i64, -4 * 3600), try zone.utcOffset(1110697200));
    try std.testing.expectEqualStrings(
        "2005-03-13T03:00:00-04:00",
        try in_daylight.iso8601(gpa, try zone.utcOffset(1110697200)),
    );

    // The Sunday on or after November 1 in 2005 is November 6.
    try std.testing.expectEqualStrings("Fxd", (try zone.toLocal(1131256799)).zone.?);
    try std.testing.expectEqualStrings("Fxs", (try zone.toLocal(1131256800)).zone.?);

    // Far beyond the 32-bit range the last rule type stays in force.
    const future = try zone.toLocal(4102444800);
    try std.testing.expectEqual(@as(i64, -5 * 3600), try zone.utcOffset(4102444800));
    try std.testing.expectEqualStrings(
        "2099-12-31T19:00:00-05:00",
        try future.iso8601(gpa, try zone.utcOffset(4102444800)),
    );

    // mktime_z must reproduce the instants that localtime_rz reported.
    try std.testing.expectEqual(@as(i64, 1110697200), try zone.toUtc(in_daylight));
}

test "zic creates the link declared by the fixture source" {
    try support.requireProvider();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compileFixture(&tmp);

    const alias_path = try support.fixtureZone(support.gpa, &tmp, "Etc/FixtureAlias");
    defer support.gpa.free(alias_path);
    var alias = try tzdata.Zone.open(alias_path);
    defer alias.close();
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();

    const at_epoch = try alias.toLocal(0);
    try std.testing.expectEqual(@as(i64, 0), try alias.utcOffset(0));
    try std.testing.expectEqualStrings("UTC", at_epoch.zone.?);
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00+00:00",
        try at_epoch.iso8601(arena.allocator(), try alias.utcOffset(0)),
    );
}

test "a UTC zone compiled from the fixture reports no daylight saving time" {
    try support.requireProvider();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try compileFixture(&tmp);

    const zone_path = try support.fixtureZone(support.gpa, &tmp, "Etc/FixtureUTC");
    defer support.gpa.free(zone_path);
    var zone = try tzdata.Zone.open(zone_path);
    defer zone.close();

    for ([_]i64{ -1, 0, 1772366400, 4102444800 }) |timestamp| {
        const local = try zone.toLocal(timestamp);
        try std.testing.expectEqual(@as(i64, 0), try zone.utcOffset(timestamp));
        try std.testing.expectEqual(@as(i32, 0), local.isdst);
        try std.testing.expectEqualStrings("UTC", local.zone.?);
    }
}
