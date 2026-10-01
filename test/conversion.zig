//! Conversion tests against the database this build compiled with its own zic.
//!
//! Every expectation is an independently known civil time: the UTC zone has a
//! fixed zero offset, and America/New_York's rules put the 2026 transitions at
//! 2026-03-08T07:00:00Z and 2026-11-01T06:00:00Z.  One test opens zones by
//! plain name instead, which is the lookup path a dependent package gets.
//! Those tests resolve through TZDIR, so a build that overrides it with
//! `-Dtz-dir` needs a populated directory to pass them.

const std = @import("std");
const tzdata = @import("tzdata");
const support = @import("support.zig");

fn openDatabaseZone(allocator: std.mem.Allocator, name: [:0]const u8) !tzdata.Zone {
    const path = try support.databaseZone(allocator, name);
    defer allocator.free(path);
    return tzdata.Zone.open(path);
}

test "UTC is exact at the epoch, before it and far beyond 2038" {
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    var zone = try openDatabaseZone(gpa, "Etc/UTC");
    defer zone.close();

    const cases = [_]struct { timestamp: i64, rendered: []const u8 }{
        .{ .timestamp = -1, .rendered = "1969-12-31T23:59:59+00:00" },
        .{ .timestamp = 0, .rendered = "1970-01-01T00:00:00+00:00" },
        .{ .timestamp = 2147483647, .rendered = "2038-01-19T03:14:07+00:00" },
        .{ .timestamp = 2147483648, .rendered = "2038-01-19T03:14:08+00:00" },
        .{ .timestamp = 4102444800, .rendered = "2100-01-01T00:00:00+00:00" },
    };
    for (cases) |case| {
        const local = try zone.toLocal(case.timestamp);
        const offset = try zone.utcOffset(case.timestamp);
        try std.testing.expectEqual(@as(i64, 0), offset);
        try std.testing.expectEqual(@as(i32, 0), local.isdst);
        try std.testing.expectEqualStrings("UTC", local.zone.?);
        try std.testing.expectEqualStrings(case.rendered, try local.iso8601(gpa, offset));
        try std.testing.expectEqual(case.timestamp, try zone.toUtc(local));
    }
}

test "America/New_York switches to and from daylight saving time in 2026" {
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    var zone = try openDatabaseZone(gpa, "America/New_York");
    defer zone.close();

    // One second before and after 2026-03-08T07:00:00Z (02:00 local standard).
    try std.testing.expectEqualStrings("EST", (try zone.toLocal(1772953199)).zone.?);
    const spring = try zone.toLocal(1772953200);
    try std.testing.expectEqualStrings("EDT", spring.zone.?);
    try std.testing.expectEqual(@as(i64, -4 * 3600), try zone.utcOffset(1772953200));
    try std.testing.expectEqualStrings(
        "2026-03-08T03:00:00-04:00",
        try spring.iso8601(gpa, try zone.utcOffset(1772953200)),
    );
    try std.testing.expectEqual(@as(i64, 1772953200), try zone.toUtc(spring));

    // One second before and after 2026-11-01T06:00:00Z (02:00 local daylight).
    try std.testing.expectEqualStrings("EDT", (try zone.toLocal(1793512799)).zone.?);
    const autumn = try zone.toLocal(1793512800);
    try std.testing.expectEqualStrings("EST", autumn.zone.?);
    try std.testing.expectEqual(@as(i64, -5 * 3600), try zone.utcOffset(1793512800));
    try std.testing.expectEqualStrings(
        "2026-11-01T01:00:00-05:00",
        try autumn.iso8601(gpa, try zone.utcOffset(1793512800)),
    );
    try std.testing.expectEqual(@as(i64, 1793512800), try zone.toUtc(autumn));

    // Pre-epoch and far-future instants use the same standard time offset.
    const before_epoch = try zone.toLocal(-1);
    try std.testing.expectEqualStrings("EST", before_epoch.zone.?);
    try std.testing.expectEqualStrings(
        "1969-12-31T18:59:59-05:00",
        try before_epoch.iso8601(gpa, try zone.utcOffset(-1)),
    );
    const future = try zone.toLocal(4102444800);
    try std.testing.expectEqualStrings("EST", future.zone.?);
    try std.testing.expectEqualStrings(
        "2099-12-31T19:00:00-05:00",
        try future.iso8601(gpa, try zone.utcOffset(4102444800)),
    );

    // Where struct tm carries tm_gmtoff, it must agree with the zone.
    if (spring.utcOffset()) |carried| {
        try std.testing.expectEqual(carried, try zone.utcOffset(1772953200));
    }
}

test "a plain zone name resolves in the database this package bundles" {
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();

    var zone = try tzdata.Zone.open("Europe/Berlin");
    defer zone.close();

    // European summer time runs in June, so Berlin is +02:00 "CEST" then.
    const local = try zone.toLocal(1782043200);
    try std.testing.expectEqual(@as(i64, 2 * 3600), try zone.utcOffset(1782043200));
    try std.testing.expectEqualStrings("CEST", local.zone.?);
    try std.testing.expectEqualStrings(
        "2026-06-21T14:00:00+02:00",
        try local.iso8601(arena.allocator(), try zone.utcOffset(1782043200)),
    );
    try std.testing.expectEqual(@as(i64, 1782043200), try zone.toUtc(local));
}

test "a POSIX TZ specification needs no database file" {
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();

    // "EST5" is a fixed -05:00 zone with no daylight saving rule, so no
    // transition table exists at all.
    var zone = try tzdata.Zone.open("EST5");
    defer zone.close();

    const local = try zone.toLocal(0);
    try std.testing.expectEqual(@as(i64, -5 * 3600), try zone.utcOffset(0));
    try std.testing.expectEqual(@as(i32, 0), local.isdst);
    try std.testing.expectEqualStrings("EST", local.zone.?);
    try std.testing.expectEqualStrings(
        "1969-12-31T19:00:00-05:00",
        try local.iso8601(arena.allocator(), try zone.utcOffset(0)),
    );
    try std.testing.expectEqual(@as(i64, 0), try zone.toUtc(local));
}

test "mktime_z turns a hand-built local time back into an instant" {
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();

    var zone = try openDatabaseZone(support.gpa, "America/New_York");
    defer zone.close();

    // 2026-06-21 08:00 local, unambiguous daylight saving time.
    const summer: tzdata.Tm = .{
        .year = 2026 - 1900,
        .mon = 5,
        .mday = 21,
        .hour = 8,
        .min = 0,
        .sec = 0,
        .wday = 0,
        .yday = 171,
        .isdst = 1,
        .gmtoff = null,
        .zone = null,
    };
    try std.testing.expectEqual(@as(i64, 1782043200), try zone.toUtc(summer));

    // 2026-12-25 09:15:30 local, unambiguous standard time.
    const winter: tzdata.Tm = .{
        .year = 2026 - 1900,
        .mon = 11,
        .mday = 25,
        .hour = 9,
        .min = 15,
        .sec = 30,
        .wday = 0,
        .yday = 358,
        .isdst = 0,
        .gmtoff = null,
        .zone = null,
    };
    const winter_instant = try zone.toUtc(winter);
    const round_trip = try zone.toLocal(winter_instant);
    try std.testing.expectEqual(@as(i64, -5 * 3600), try zone.utcOffset(winter_instant));
    try std.testing.expectEqualStrings(
        "2026-12-25T09:15:30-05:00",
        try round_trip.iso8601(arena.allocator(), try zone.utcOffset(winter_instant)),
    );
}

test "a year outside the C int range is rejected instead of truncated" {
    var zone = try openDatabaseZone(support.gpa, "America/New_York");
    defer zone.close();

    // mktime_z adds TM_YEAR_BASE to this in an int and answers WRONG, which
    // is also the valid instant 1969-12-31T23:59:59Z, so the facade refuses
    // the input instead of passing the sentinel on.
    const unrepresentable: tzdata.Tm = .{
        .year = std.math.maxInt(i32),
        .mon = 0,
        .mday = 1,
        .hour = 0,
        .min = 0,
        .sec = 0,
        .wday = 0,
        .yday = 0,
        .isdst = 0,
        .gmtoff = null,
        .zone = null,
    };
    try std.testing.expectError(error.ConversionFailed, zone.toUtc(unrepresentable));
}

test "one second before the epoch is an instant, not a failure" {
    var zone = try openDatabaseZone(support.gpa, "Etc/UTC");
    defer zone.close();

    // mktime_z answers -1, its WRONG sentinel, for this instant; it is a
    // perfectly valid one and must be reported as itself.
    const end_of_1969: tzdata.Tm = .{
        .year = 1969 - 1900,
        .mon = 11,
        .mday = 31,
        .hour = 23,
        .min = 59,
        .sec = 59,
        .wday = 3,
        .yday = 364,
        .isdst = 0,
        .gmtoff = null,
        .zone = null,
    };
    try std.testing.expectEqual(@as(i64, -1), try zone.toUtc(end_of_1969));
}

test "zone handles can be opened, used and released repeatedly" {
    const path = try support.databaseZone(support.gpa, "Europe/Berlin");
    defer support.gpa.free(path);

    for (0..128) |_| {
        var zone = try tzdata.Zone.open(path);
        const local = try zone.toLocal(1772366400);
        try std.testing.expectEqual(@as(i64, 3600), try zone.utcOffset(1772366400));
        try std.testing.expectEqual(@as(i64, 1772366400), try zone.toUtc(local));
        zone.close();
        zone.close();
    }
}

test "borrowed zone names can be copied before the handle is released" {
    const path = try support.databaseZone(support.gpa, "America/New_York");
    defer support.gpa.free(path);

    var zone = try tzdata.Zone.open(path);
    defer zone.close();

    const owned = try (try zone.toLocal(1782043200)).zoneNameOwned(support.gpa);
    try std.testing.expectEqualStrings("EDT", owned.?);
    zone.close();

    // The copy is independent of the released handle.
    try std.testing.expectEqualStrings("EDT", owned.?);
    support.gpa.free(owned.?);
}

test "the UTC helpers and strftime agree with the zone conversions" {
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    const epoch = try tzdata.toUtcTm(0);
    if (epoch.utcOffset()) |offset| {
        try std.testing.expectEqual(@as(i64, 0), offset);
    }
    try std.testing.expectEqualStrings("UTC", epoch.zone.?);
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00+00:00",
        try epoch.iso8601(gpa, epoch.utcOffset()),
    );
    try std.testing.expectEqualStrings(
        "1970-01-01 00:00:00",
        try tzdata.formatAlloc(gpa, epoch, "%Y-%m-%d %H:%M:%S"),
    );

    var zone = try openDatabaseZone(gpa, "America/New_York");
    defer zone.close();
    const summer = try zone.toLocal(1782043200);
    try std.testing.expectEqualStrings(
        "2026-06-21 08:00:00",
        try tzdata.formatAlloc(gpa, summer, "%Y-%m-%d %H:%M:%S"),
    );
}

test "an empty format renders an empty string, not a formatting failure" {
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();

    // strftime answers 0 for a format that renders nothing and 0 for a
    // result that did not fit; only ERANGE tells them apart.
    const epoch = try tzdata.toUtcTm(0);
    try std.testing.expectEqualStrings("", try tzdata.formatAlloc(arena.allocator(), epoch, ""));
}

test "a result that does not fit 64 KiB is reported as FormatTooLong" {
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    const epoch = try tzdata.toUtcTm(0);
    const format = try gpa.allocSentinel(u8, 70 * 1024, 0);
    @memset(format, 'x');
    try std.testing.expectError(error.FormatTooLong, tzdata.formatAlloc(gpa, epoch, format));
}

test "the raw C escape hatch reaches upstream entry points the facade omits" {
    var zone = try openDatabaseZone(support.gpa, "America/New_York");
    defer zone.close();

    const local = try zone.toLocal(1772953200);
    var raw = local.toC();

    // asctime.c publishes asctime_r and ctime_r only where
    // SUPPORT_POSIX2008 is on (asctime.c:53-62), and the bindings declare
    // them under the same condition.
    if (@hasDecl(tzdata.c, "tz_asctime_r")) {
        var buffer: [64]u8 = undefined;
        const text = tzdata.c.tz_asctime_r(&raw, &buffer);
        try std.testing.expect(!tzdata.pointerIsNull(text));
        const rendered = switch (@typeInfo(@TypeOf(text))) {
            .optional => text orelse return error.NoRenderedTime,
            else => text,
        };
        try std.testing.expectEqualStrings("Sun Mar  8 03:00:00 2026\n", std.mem.sliceTo(rendered, 0));
    }

    // The same struct tm goes back into the zone-specific conversion.
    try std.testing.expectEqual(@as(i64, 1772953200), try zone.toUtc(local));
}
