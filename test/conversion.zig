//! Conversion tests against the database this build compiled with its own zic.
//!
//! Every expectation is an independently known civil time: the UTC zone has a
//! fixed zero offset, and America/New_York's rules put the 2026 transitions at
//! 2026-03-08T07:00:00Z and 2026-11-01T06:00:00Z.  One test opens zones by
//! plain name instead, which is the lookup path a dependent package gets.
//! Those tests resolve through TZDIR, so a build that overrides it with
//! `-Dtz-dir` needs a populated directory to pass them.
//!
//! Every test begins by loading the native library, which is a no-op in a
//! linked build and the explicit provider load in a runtime-loaded one.

const std = @import("std");
const tzdata = @import("tzdata");
const support = @import("support.zig");

fn openDatabaseZone(allocator: std.mem.Allocator, name: [:0]const u8) !tzdata.Zone {
    const path = try support.databaseZone(allocator, name);
    defer allocator.free(path);
    return tzdata.Zone.open(path);
}

/// A broken-down local time built from calendar fields only.
///
/// `wday` and `yday` are never read by `tz_mktime_z` - upstream copies only
/// the fields it normalizes (`localtime.c:2509-2524`) - so they are left at
/// zero rather than computed here.
fn local(
    year: i32,
    mon: u5,
    mday: u5,
    hour: u5,
    min: u6,
    sec: u6,
    isdst: i32,
) tzdata.Tm {
    return .{
        .year = year - 1900,
        .mon = mon - 1,
        .mday = mday,
        .hour = hour,
        .min = min,
        .sec = sec,
        .wday = 0,
        .yday = 0,
        .isdst = isdst,
        .gmtoff = null,
        .zone = null,
    };
}

test "UTC is exact at the epoch, before it and far beyond 2038" {
    try support.requireProvider();
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
        const converted = try zone.toLocal(case.timestamp);
        const offset = try zone.utcOffset(case.timestamp);
        try std.testing.expectEqual(@as(i64, 0), offset);
        try std.testing.expectEqual(@as(i32, 0), converted.isdst);
        try std.testing.expectEqualStrings("UTC", converted.zone.?);
        try std.testing.expectEqualStrings(case.rendered, try converted.iso8601(gpa, offset));
        try std.testing.expectEqual(case.timestamp, try zone.toUtc(converted));
    }
}

test "America/New_York switches to and from daylight saving time in 2026" {
    try support.requireProvider();
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


test "an autumn fold names two instants an hour apart, and both convert back" {
    try support.requireProvider();
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    var zone = try openDatabaseZone(gpa, "America/New_York");
    defer zone.close();

    // 2026-11-01T06:00:00Z moves 02:00 daylight back to 01:00 standard, so the
    // local hour 01:00 to 01:59:59 happens twice: once at -04:00 and once at
    // -05:00.  Those are 1793511000 (05:30:00Z) and 1793514600 (06:30:00Z), and
    // the civil time at both is 2026-11-01T01:30:00.
    const first = try zone.toLocal(1793511000);
    const second = try zone.toLocal(1793514600);
    try std.testing.expectEqual(@as(i64, 1), second.hour);
    try std.testing.expectEqual(@as(u6, 30), second.min);
    try std.testing.expectEqual(@as(i32, 1), first.isdst);
    try std.testing.expectEqual(@as(i32, 0), second.isdst);
    try std.testing.expectEqualStrings("EDT", first.zone.?);
    try std.testing.expectEqualStrings("EST", second.zone.?);
    try std.testing.expectEqual(@as(i64, -4 * 3600), try zone.utcOffset(1793511000));
    try std.testing.expectEqual(@as(i64, -5 * 3600), try zone.utcOffset(1793514600));
    // Where struct tm carries tm_gmtoff, the two occurrences differ by
    // exactly the hour the clock was turned back.
    if (comptime @hasField(tzdata.c.struct_tm, "tm_gmtoff")) {
        try std.testing.expectEqual(@as(i64, -3600), second.gmtoff.? - first.gmtoff.?);
    }

    // `mktime_z` has to land on one of those two instants and nowhere else.
    // Which one it picks is upstream's business - the binary search in
    // `time2sub` stops at whichever candidate it reaches first and does not
    // consult `tm_isdst` once it has one - so what is asserted is the property
    // a caller can rely on: the answer is a real occurrence of that local
    // time, and converting it back gives that same wall clock.
    const folded = try zone.toUtc(local(2026, 11, 1, 1, 30, 0, 0));
    try std.testing.expect(
        folded == 1793511000 or folded == 1793514600,
    );
    const back = try zone.toLocal(folded);
    try std.testing.expectEqual(@as(u5, 1), back.hour);
    try std.testing.expectEqual(@as(u6, 30), back.min);
    try std.testing.expectEqual(@as(u5, 1), back.mday);
    try std.testing.expectEqual(@as(u5, 10), back.mon);
}

test "a spring gap is normalized forward past the transition" {
    try support.requireProvider();
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    var zone = try openDatabaseZone(gpa, "America/New_York");
    defer zone.close();

    // 2026-03-08T07:00:00Z moves 02:00 standard forward to 03:00, so local
    // 02:00:00 to 02:59:59 never happens.  No timestamp has those fields, so
    // the search in `time2sub` (`localtime.c:2638-2672`) cannot match and
    // `time1` retries with the hour carried forward and the type flipped
    // (`localtime.c:2828-2849`).  03:30 daylight is 07:30:00Z, which is
    // 1772955000.
    const gap = try zone.toUtc(local(2026, 3, 8, 2, 30, 0, 0));
    try std.testing.expectEqual(@as(i64, 1772955000), gap);
    const normalized = try zone.toLocal(gap);
    try std.testing.expectEqual(@as(u5, 3), normalized.hour);
    try std.testing.expectEqual(@as(u6, 30), normalized.min);
    try std.testing.expectEqual(@as(i32, 1), normalized.isdst);
    try std.testing.expectEqualStrings("EDT", normalized.zone.?);
    try std.testing.expectEqualStrings(
        "2026-03-08T03:30:00-04:00",
        try normalized.iso8601(gpa, try zone.utcOffset(gap)),
    );

    // The same input asking for daylight time instead carries the hour back
    // and lands on the last instant that really has 01:30 standard time.
    const asked_for_dst = try zone.toUtc(local(2026, 3, 8, 2, 30, 0, 1));
    try std.testing.expectEqual(@as(i64, 1772951400), asked_for_dst);
    try std.testing.expectEqualStrings(
        "2026-03-08T01:30:00-05:00",
        try (try zone.toLocal(asked_for_dst)).iso8601(gpa, try zone.utcOffset(asked_for_dst)),
    );
}

test "calendar fields outside their range are carried, not truncated" {
    try support.requireProvider();
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    var zone = try openDatabaseZone(gpa, "Etc/UTC");
    defer zone.close();

    // `mktime_z` normalizes before it searches (`localtime.c:2547-2607`), so a
    // minute of 60 is the next hour, a day of 0 is the last day of the month
    // before, and a month of 13 is January of the year after.
    try std.testing.expectEqual(
        @as(i64, 1782032400), // 2026-06-21T09:00:00Z
        try zone.toUtc(local(2026, 6, 21, 8, 60, 0, 0)),
    );
    try std.testing.expectEqual(
        @as(i64, 1772280000), // 2026-02-28T12:00:00Z
        try zone.toUtc(local(2026, 3, 0, 12, 0, 0, 0)),
    );
    try std.testing.expectEqual(
        @as(i64, 1798761600), // 2027-01-01T00:00:00Z
        try zone.toUtc(local(2026, 13, 1, 0, 0, 0, 0)),
    );

    // Each of those is a real instant in this zone, not a rejected input, and
    // converting it back gives the normalized civil time rather than the one
    // that was asked for.
    try std.testing.expectEqualStrings(
        "2026-02-28T12:00:00+00:00",
        try (try zone.toLocal(1772280000)).iso8601(gpa, 0),
    );
    try std.testing.expectEqualStrings(
        "2027-01-01T00:00:00+00:00",
        try (try zone.toLocal(1798761600)).iso8601(gpa, 0),
    );
}

test "the widest month the field holds renders rather than failing" {
    try support.requireProvider();
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    // A caller builds a `Tm` out of C-shaped fields, and `mon` is the width of
    // the C field rather than a validated range, so the widest value it holds
    // is one a caller can legitimately store.  The field is set here directly
    // because `local` takes the one-based month as a `u5` as well, and so
    // cannot name the month that stores the widest value.  Nothing normalizes
    // it before the rendering, which is one more than December either way.
    const widest: tzdata.Tm = .{
        .year = 126,
        .mon = 31,
        .mday = 15,
        .hour = 12,
        .min = 30,
        .sec = 45,
        .wday = 0,
        .yday = 0,
        .isdst = 0,
        .gmtoff = null,
        .zone = null,
    };
    try std.testing.expectEqualStrings(
        "2026-32-15T12:30:45+05:30",
        try widest.iso8601(gpa, 5 * 3600 + 30 * 60),
    );
    try std.testing.expectEqualStrings("2026-32-15T12:30:45", try widest.iso8601(gpa, null));

    // The months on either side of it are unchanged.
    try std.testing.expectEqualStrings(
        "2026-01-15T12:30:45+00:00",
        try local(2026, 1, 15, 12, 30, 45, 0).iso8601(gpa, 0),
    );
    try std.testing.expectEqualStrings(
        "2026-12-15T12:30:45-05:00",
        try local(2026, 12, 15, 12, 30, 45, 0).iso8601(gpa, -5 * 3600),
    );
}

test "an offset with no signed magnitude renders rather than failing" {
    try support.requireProvider();
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    const december = local(2026, 12, 15, 12, 30, 45, 0);

    // The magnitude of the smallest i64 is one larger than the largest i64, so
    // it is the one offset whose absolute value no signed negation can hold.
    // It renders as the unsigned magnitude it has, in whole hours and minutes:
    // 9223372036854775808 = 2562047788015215 * 3600 + 1808, and
    // 9223372036854775807 = 2562047788015215 * 3600 + 1807.
    try std.testing.expectEqualStrings(
        "2026-12-15T12:30:45-2562047788015215:30",
        try december.iso8601(gpa, std.math.minInt(i64)),
    );
    try std.testing.expectEqualStrings(
        "2026-12-15T12:30:45+2562047788015215:30",
        try december.iso8601(gpa, std.math.maxInt(i64)),
    );
}

test "a plain zone name resolves in the database this package bundles" {
    try support.requireProvider();
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();

    var zone = try tzdata.Zone.open("Europe/Berlin");
    defer zone.close();

    // European summer time runs in June, so Berlin is +02:00 "CEST" then.
    const converted = try zone.toLocal(1782043200);
    try std.testing.expectEqual(@as(i64, 2 * 3600), try zone.utcOffset(1782043200));
    try std.testing.expectEqualStrings("CEST", converted.zone.?);
    try std.testing.expectEqualStrings(
        "2026-06-21T14:00:00+02:00",
        try converted.iso8601(arena.allocator(), try zone.utcOffset(1782043200)),
    );
    try std.testing.expectEqual(@as(i64, 1782043200), try zone.toUtc(converted));
}

test "a POSIX TZ specification needs no database file" {
    try support.requireProvider();
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();

    // "EST5" is a fixed -05:00 zone with no daylight saving rule, so no
    // transition table exists at all.
    var zone = try tzdata.Zone.open("EST5");
    defer zone.close();

    const converted = try zone.toLocal(0);
    try std.testing.expectEqual(@as(i64, -5 * 3600), try zone.utcOffset(0));
    try std.testing.expectEqual(@as(i32, 0), converted.isdst);
    try std.testing.expectEqualStrings("EST", converted.zone.?);
    try std.testing.expectEqualStrings(
        "1969-12-31T19:00:00-05:00",
        try converted.iso8601(arena.allocator(), try zone.utcOffset(0)),
    );
    try std.testing.expectEqual(@as(i64, 0), try zone.toUtc(converted));
}

test "an empty zone name is the zero-offset UTC path, not the ambient zone" {
    try support.requireProvider();
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    // zoneinit takes this branch for an empty name (localtime.c:1808-1819):
    // one rule type at +00:00, isdst false, the abbreviation "UTC", no file
    // read and no TZ environment variable consulted.  Both instants below are
    // ones any non-UTC ambient local zone would shift, so the expectation is
    // UTC's own fixed offset rather than this machine's local time.
    var zone = try tzdata.Zone.open("");
    defer zone.close();

    const cases = [_]struct { timestamp: i64, rendered: []const u8 }{
        .{ .timestamp = 0, .rendered = "1970-01-01T00:00:00+00:00" },
        .{ .timestamp = 1782043200, .rendered = "2026-06-21T12:00:00+00:00" },
    };
    for (cases) |case| {
        const converted = try zone.toLocal(case.timestamp);
        try std.testing.expectEqual(@as(i64, 0), try zone.utcOffset(case.timestamp));
        try std.testing.expectEqual(@as(i32, 0), converted.isdst);
        try std.testing.expectEqualStrings("UTC", converted.zone.?);
        try std.testing.expectEqualStrings(case.rendered, try converted.iso8601(gpa, 0));
        try std.testing.expectEqual(case.timestamp, try zone.toUtc(converted));
    }
}

test "mktime_z turns a hand-built local time back into an instant" {
    try support.requireProvider();
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();

    var zone = try openDatabaseZone(support.gpa, "America/New_York");
    defer zone.close();

    // 2026-06-21 08:00 local, unambiguous daylight saving time.
    const summer = local(2026, 6, 21, 8, 0, 0, 1);
    try std.testing.expectEqual(@as(i64, 1782043200), try zone.toUtc(summer));

    // 2026-12-25 09:15:30 local, unambiguous standard time.
    const winter = local(2026, 12, 25, 9, 15, 30, 0);
    const winter_instant = try zone.toUtc(winter);
    const round_trip = try zone.toLocal(winter_instant);
    try std.testing.expectEqual(@as(i64, -5 * 3600), try zone.utcOffset(winter_instant));
    try std.testing.expectEqualStrings(
        "2026-12-25T09:15:30-05:00",
        try round_trip.iso8601(arena.allocator(), try zone.utcOffset(winter_instant)),
    );
}

test "a year outside the C int range is rejected instead of truncated" {
    try support.requireProvider();
    var zone = try openDatabaseZone(support.gpa, "America/New_York");
    defer zone.close();

    // mktime_z adds TM_YEAR_BASE to this in an int and answers WRONG, which
    // is also the valid instant 1969-12-31T23:59:59Z, so the facade refuses
    // the input instead of passing the sentinel on.
    var unrepresentable = local(2026, 6, 21, 8, 0, 0, 0);
    unrepresentable.year = std.math.maxInt(i32);
    try std.testing.expectError(error.ConversionFailed, zone.toUtc(unrepresentable));
}

test "one second before the epoch is an instant, not a failure" {
    try support.requireProvider();
    var zone = try openDatabaseZone(support.gpa, "Etc/UTC");
    defer zone.close();

    // mktime_z answers -1, its WRONG sentinel, for this instant; it is a
    // perfectly valid one and must be reported as itself.
    try std.testing.expectEqual(
        @as(i64, -1),
        try zone.toUtc(local(1969, 12, 31, 23, 59, 59, 0)),
    );
}

test "zone handles can be opened, used and released repeatedly" {
    try support.requireProvider();
    const path = try support.databaseZone(support.gpa, "Europe/Berlin");
    defer support.gpa.free(path);

    // Each handle is allocated by the library that answered the conversion and
    // released through the same one, so a handle that crosses a provider
    // change could not survive this: `close` is `tz_tzfree` through whichever
    // route this build has.
    for (0..128) |_| {
        var zone = try tzdata.Zone.open(path);
        const converted = try zone.toLocal(1772366400);
        try std.testing.expectEqual(@as(i64, 3600), try zone.utcOffset(1772366400));
        try std.testing.expectEqual(@as(i64, 1772366400), try zone.toUtc(converted));
        zone.close();
        zone.close();
    }

    // And a fresh handle still works afterwards, so the loop above released
    // rather than exhausted anything.
    var again = try tzdata.Zone.open(path);
    defer again.close();
    try std.testing.expectEqualStrings("CET", (try again.toLocal(1772366400)).zone.?);
}

test "borrowed zone names can be copied before the handle is released" {
    try support.requireProvider();
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
    try support.requireProvider();
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
    try support.requireProvider();
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();

    // strftime answers 0 for a format that renders nothing and 0 for a
    // result that did not fit; only ERANGE tells them apart.
    const epoch = try tzdata.toUtcTm(0);
    try std.testing.expectEqualStrings("", try tzdata.formatAlloc(arena.allocator(), epoch, ""));
}

test "a result that does not fit 64 KiB is reported as FormatTooLong" {
    try support.requireProvider();
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    const epoch = try tzdata.toUtcTm(0);
    const format = try gpa.allocSentinel(u8, 70 * 1024, 0);
    @memset(format, 'x');
    try std.testing.expectError(error.FormatTooLong, tzdata.formatAlloc(gpa, epoch, format));
}

test "the raw C route renders and re-parses the same broken-down time" {
    try support.requireProvider();
    var arena = std.heap.ArenaAllocator.init(support.gpa);
    defer arena.deinit();
    const gpa = arena.allocator();

    var zone = try openDatabaseZone(gpa, "America/New_York");
    defer zone.close();

    const converted = try zone.toLocal(1772953200);
    var raw = converted.toC();

    // asctime.c publishes asctime_r only where SUPPORT_POSIX2008 is on
    // (asctime.c:53-62), and the bindings declare it under the same condition,
    // so this is exercised on the targets that build it and skipped on the
    // ones that do not.
    if (comptime @hasDecl(tzdata.c, "tz_asctime_r")) {
        var buffer: [64]u8 = undefined;
        const text = tzdata.c.tz_asctime_r(&raw, &buffer);
        if (@typeInfo(@TypeOf(text)) == .optional) {
            try std.testing.expect(text != null);
        } else {
            try std.testing.expect(!tzdata.pointerIsNull(text));
        }
        const rendered = switch (@typeInfo(@TypeOf(text))) {
            .optional => text.?,
            else => text,
        };
        // 2026-03-08 was a Sunday, which is what the layout below encodes.
        try std.testing.expectEqualStrings("Sun Mar  8 03:00:00 2026\n", std.mem.sliceTo(rendered, 0));
    }

    // tz_difftime is exact on the 64-bit time_t this module requires.
    try std.testing.expectEqual(@as(f64, 3600), tzdata.c.tz_difftime(1772953200, 1772949600));

    // tz_offtime_r is the offset-from-UTC form of the same conversion, so it
    // must produce the same civil time the zone did at the same instant.
    var off: tzdata.c.struct_tm = undefined;
    const offset: c_long = -4 * 3600;
    var seconds: tzdata.c.time_t = 1772953200;
    if (!tzdata.pointerIsNull(tzdata.c.tz_offtime_r(&seconds, offset, &off))) {
        try std.testing.expectEqualStrings(
            "2026-03-08T03:00:00-04:00",
            try tzdata.Tm.fromC(&off).iso8601(gpa, -4 * 3600),
        );
    }

    // The same struct tm goes back into the zone-specific conversion.
    try std.testing.expectEqual(@as(i64, 1772953200), try zone.toUtc(converted));
}

test "the exported zone globals agree with the ambient POSIX conversion" {
    try support.requireProvider();

    // These three objects are the only exported data in the surface, and they
    // are read through the provider's own storage - the variable in a linked
    // build, the address the loader resolved in a runtime-loaded one - so what
    // is asserted is never a value this module copied.
    //
    // The build emits none of them where upstream emits none: `HAVE_TZNAME`
    // and `USG_COMPAT` are pinned to 0 on mingw-w64 and on every unknown OS
    // (`localtime.c:623-629`), so there is nothing to read there.
    if (comptime !tzdata.Ambient.usg_compat_emitted) return;

    tzdata.Ambient.tzset();
    const daylight = tzdata.Ambient.daylightSavingEverUsed().?;
    const standard_offset = tzdata.Ambient.standardOffsetSeconds().?;

    var now: tzdata.c.time_t = undefined;
    _ = tzdata.c.tz_time(&now);
    const raw = tzdata.c.tz_localtime(&now);
    if (tzdata.pointerIsNull(raw)) return error.NoAmbientLocalTime;

    // `settzname` publishes both abbreviation slots and zeroes `tz_timezone`
    // before its scan fills in whatever it finds
    // (`localtime.c:745-768`), so both slots always point at storage the
    // provider owns once `tzset` has run.
    try std.testing.expect(tzdata.Ambient.abbreviation(0) != null);
    try std.testing.expect(tzdata.Ambient.abbreviation(1) != null);

    // A daylight type in force means the zone has one, so the scan found it and
    // `daylight` was set (`localtime.c:766-768`).  A standard type in force
    // means the standard slot was filled from a real abbreviation rather than
    // left as `WILDABBR` (`localtime.c:400-406`, `:704-706`).  Both hold for
    // whatever zone this machine's own `TZ` names, which is what keeps the
    // test independent of the environment it runs in.
    if (raw[0].tm_isdst != 0) {
        try std.testing.expect(daylight);
    } else {
        try std.testing.expect(!std.mem.eql(u8, tzdata.Ambient.abbreviation(0).?, "   "));
    }

    // Reading again reaches the same provider storage, so a second `tzset`
    // republishes the same values rather than leaving a copy this module made
    // the first time.
    tzdata.Ambient.tzset();
    try std.testing.expectEqual(daylight, tzdata.Ambient.daylightSavingEverUsed().?);
    try std.testing.expectEqual(standard_offset, tzdata.Ambient.standardOffsetSeconds().?);
}