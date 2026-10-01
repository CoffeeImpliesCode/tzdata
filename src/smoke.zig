//! Deterministic smoke program for the tzdata package.
//!
//! Every line printed here depends only on fixed timestamps and on the
//! database this package's own zic compiled, so the output is reproducible.
//! Zones are opened by plain name, through the TZDIR compiled into the
//! library, so the run also exercises the lookup a dependent package gets
//! from `dep.module("tzdata")` alone.  A build that overrides TZDIR with
//! `-Dtz-dir` needs a populated directory for those names to resolve.

const std = @import("std");
const Io = std.Io;
const tzdata = @import("tzdata");

const Probe = struct {
    zone: [:0]const u8,
    timestamp: i64,
    /// Independently known expectation: abbreviation and UTC offset in seconds.
    abbreviation: ?[:0]const u8,
    offset: i64,
    /// Independently known expectation for the rendered local time.
    local: [:0]const u8,
};

/// Probe points covering UTC, both sides of the 2026 America/New_York
/// daylight saving transitions, a pre-epoch timestamp and a far-future one.
const probes = [_]Probe{
    .{
        .zone = "Etc/UTC",
        .timestamp = -1,
        .abbreviation = "UTC",
        .offset = 0,
        .local = "1969-12-31T23:59:59+00:00",
    },
    .{
        .zone = "Etc/UTC",
        .timestamp = 0,
        .abbreviation = "UTC",
        .offset = 0,
        .local = "1970-01-01T00:00:00+00:00",
    },
    .{
        .zone = "Etc/UTC",
        .timestamp = 4102444800, // 2100-01-01T00:00:00Z
        .abbreviation = "UTC",
        .offset = 0,
        .local = "2100-01-01T00:00:00+00:00",
    },
    .{
        .zone = "America/New_York",
        .timestamp = 1772366400, // 2026-03-01T12:00:00Z, before the March switch
        .abbreviation = "EST",
        .offset = -5 * 3600,
        .local = "2026-03-01T07:00:00-05:00",
    },
    .{
        .zone = "America/New_York",
        .timestamp = 1782043200, // 2026-06-21T12:00:00Z, inside daylight saving time
        .abbreviation = "EDT",
        .offset = -4 * 3600,
        .local = "2026-06-21T08:00:00-04:00",
    },
    .{
        .zone = "America/New_York",
        .timestamp = 1793534400, // 2026-11-01T12:00:00Z, after the November switch
        .abbreviation = "EST",
        .offset = -5 * 3600,
        .local = "2026-11-01T07:00:00-05:00",
    },
    .{
        .zone = "America/New_York",
        .timestamp = 4102444800, // 2100-01-01T00:00:00Z, beyond the 32-bit range
        .abbreviation = "EST",
        .offset = -5 * 3600,
        .local = "2099-12-31T19:00:00-05:00",
    },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    try stdout.print("tzdata version={s} package={s}\n", .{
        tzdata.version(),
        tzdata.packageName(),
    });

    for (probes) |probe| {
        var zone = try tzdata.Zone.open(probe.zone);
        defer zone.close();

        const local = try zone.toLocal(probe.timestamp);
        const offset = try zone.utcOffset(probe.timestamp);
        const rendered = try local.iso8601(arena, offset);
        const abbreviation = if (local.zone) |borrowed| try arena.dupeZ(u8, borrowed) else "?";

        if (!std.mem.eql(u8, rendered, probe.local)) {
            try stdout.print("expected local time {s}, found {s}\n", .{ probe.local, rendered });
            return error.SmokeMismatch;
        }
        if (offset != probe.offset) {
            try stdout.print("expected offset {d}, found {d}\n", .{ probe.offset, offset });
            return error.SmokeMismatch;
        }
        if (probe.abbreviation) |expected| {
            if (!std.mem.eql(u8, abbreviation, expected)) {
                try stdout.print("expected abbreviation {s}, found {s}\n", .{ expected, abbreviation });
                return error.SmokeMismatch;
            }
        }

        // mktime_z must turn the broken-down time back into the same instant.
        const round_trip = try zone.toUtc(local);
        if (round_trip != probe.timestamp) {
            try stdout.print("round trip of {d} produced {d}\n", .{ probe.timestamp, round_trip });
            return error.SmokeMismatch;
        }

        // strftime and the UTC conversion are exercised on the epoch only, so
        // the printed lines stay short.
        if (probe.timestamp == 0) {
            const utc_tm = try tzdata.toUtcTm(probe.timestamp);
            const formatted = try tzdata.formatAlloc(arena, utc_tm, "%Y-%m-%dT%H:%M:%S");
            try stdout.print("strftime {s} t=0 -> {s}\n", .{ probe.zone, formatted });
            if (!std.mem.eql(u8, formatted, "1970-01-01T00:00:00")) return error.SmokeMismatch;

            // POSIX/right conversion: with no leap-second data in the file
            // both scales agree, in both directions.
            const right = zone.toPosix(probe.timestamp);
            const back = zone.fromPosix(probe.timestamp);
            try stdout.print("right-to-posix {s} t=0 -> {d}, posix-to-right -> {d}\n", .{
                probe.zone,
                right,
                back,
            });
            if (right != probe.timestamp or back != probe.timestamp) return error.SmokeMismatch;

            try stdout.print("roundtrip {s} t=0 -> {d}\n", .{ probe.zone, round_trip });
        }
    }
}
