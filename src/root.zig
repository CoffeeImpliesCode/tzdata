//! Public Zig interface to the tzcode core library (tzdata).
//!
//! This module wraps the translated C declarations in `c` with a small typed
//! layer: an owning reentrant zone handle over `tz_tzalloc`/`tz_tzfree`, and
//! conversions over `tz_localtime_rz`/`tz_mktime_z` that hand out Zig-owned
//! `Tm` values instead of pointers into tzcode's internal state.  Nothing in
//! this file reimplements an upstream algorithm; it only fixes ownership,
//! sentinel strings, null-pointer error conversion and 64-bit `time_t`.
//!
//! `src/smoke.zig`, `test/` and `consumer/` call every entry point declared
//! here, so `zig build check` compiles all of them for each target it lists.
//! That step compiles without running anything, so no target other than the
//! host has been observed executing this code.
//!
//! Symbol isolation: this package always compiles tzcode with upstream's
//! documented `-Dtime_tz=time_t` mode, which renames every externally visible
//! identifier to a `tz_`-prefixed spelling (`tz_localtime`, `tz_mktime`,
//! `tz_tzalloc`, ...).  Linking this package next to a C library that owns
//! `localtime`, `mktime`, `tzname`, `timezone`, `daylight` or `strftime`
//! therefore never replaces or shadows those symbols.  See README.zig.md.

const std = @import("std");

/// Complete translated declarations of the upstream C API.
/// This is the raw escape hatch; the typed layer below is a convenience.
pub const c = @import("tz_c");

// Upstream is built with 64-bit time semantics, which is what makes the `i64`
// timestamps below exact.  Refuse to compile against a narrower `time_t`
// rather than truncate silently.
comptime {
    const info = @typeInfo(c.time_t);
    if (info != .int or info.int.bits != 64 or info.int.signedness != .signed) {
        @compileError("tzdata requires a signed 64-bit time_t; this target has " ++
            @typeName(c.time_t));
    }
}

/// True when a C pointer result is null.
///
/// C headers do not record nullability, so the translator may model a pointer
/// either as an optional or as a plain pointer; both are handled here.
pub fn pointerIsNull(value: anytype) bool {
    const Info = @typeInfo(@TypeOf(value));
    if (Info == .optional) return value == null;
    if (Info != .pointer) @compileError("expected a pointer, found " ++ @typeName(@TypeOf(value)));
    if (@typeInfo(Info.pointer.child) == .optional) return value == null;
    return @intFromPtr(value) == 0;
}

/// A borrowed, sentinel-terminated string from a C pointer result.
fn borrowedString(value: anytype) ?[:0]const u8 {
    if (@typeInfo(@TypeOf(value)) == .optional) {
        const inner = value orelse return null;
        if (@intFromPtr(inner) == 0) return null;
        return inner[0..std.mem.len(inner) :0];
    }
    if (@intFromPtr(value) == 0) return null;
    return value[0..std.mem.len(value) :0];
}

fn ownedSentinel(value: anytype) [:0]const u8 {
    return value[0..std.mem.len(value) :0];
}

/// Errors produced by the typed layer.
pub const Error = error{
    /// `tz_tzalloc` returned NULL: the zone name could not be loaded.
    InvalidZone,
    /// Upstream rejected the value: a NULL conversion result, or a broken
    /// down time whose year leaves the C `int` range `mktime_z` needs.
    ConversionFailed,
    /// `strftime` reported `ERANGE`: the result did not fit into 64 KiB.
    FormatTooLong,
};

/// The upstream release this library was generated from, e.g. "2026e".
pub fn version() [:0]const u8 {
    return ownedSentinel(c.tzdata_version());
}

/// The upstream package string, e.g. "(tzcode) ".
pub fn packageName() [:0]const u8 {
    return ownedSentinel(c.tzdata_package());
}

/// A broken-down local time, owned by the caller.
///
/// Field ranges and meanings follow `struct tm` from <time.h>: `year` counts
/// years since 1900 and `isdst` keeps the raw C value (positive when daylight
/// saving time is in effect, zero for standard time, negative when unknown).
pub const Tm = struct {
    year: i32,
    mon: u5,
    mday: u5,
    hour: u5,
    min: u6,
    sec: u6,
    wday: u3,
    yday: u9,
    isdst: i32,
    /// Seconds east of UTC, if the target's `struct tm` carries `tm_gmtoff`.
    gmtoff: ?i64,
    /// Zone abbreviation, if the target's `struct tm` carries `tm_zone`.
    ///
    /// This borrows tzcode's internal abbreviation storage, so it is valid
    /// only while the owning `Zone` is alive.  Use `zoneNameOwned` to keep
    /// the name past that point.
    zone: ?[:0]const u8,

    /// Copy a tzcode-owned `struct tm` into a Zig-owned value.
    pub fn fromC(raw: *const c.struct_tm) Tm {
        return .{
            .year = raw.tm_year,
            .mon = @intCast(raw.tm_mon),
            .mday = @intCast(raw.tm_mday),
            .hour = @intCast(raw.tm_hour),
            .min = @intCast(raw.tm_min),
            .sec = @intCast(raw.tm_sec),
            .wday = @intCast(raw.tm_wday),
            .yday = @intCast(raw.tm_yday),
            .isdst = raw.tm_isdst,
            .gmtoff = if (@hasField(c.struct_tm, "tm_gmtoff")) @as(i64, raw.tm_gmtoff) else null,
            .zone = if (@hasField(c.struct_tm, "tm_zone")) borrowedString(raw.tm_zone) else null,
        };
    }

    /// Build the C `struct tm` that the upstream entry points expect.
    pub fn toC(self: Tm) c.struct_tm {
        var raw: c.struct_tm = std.mem.zeroes(c.struct_tm);
        raw.tm_year = self.year;
        raw.tm_mon = self.mon;
        raw.tm_mday = self.mday;
        raw.tm_hour = self.hour;
        raw.tm_min = self.min;
        raw.tm_sec = self.sec;
        raw.tm_wday = self.wday;
        raw.tm_yday = self.yday;
        raw.tm_isdst = self.isdst;
        if (@hasField(c.struct_tm, "tm_gmtoff")) {
            // Upstream treats tm_gmtoff as a hint it checks rather than as
            // input it trusts (localtime.c:2674-2709), so zero stands in for
            // "unknown" rather than claiming UTC.
            raw.tm_gmtoff = @intCast(self.gmtoff orelse 0);
        }
        if (@hasField(c.struct_tm, "tm_zone")) {
            // Darwin declares a mutable pointer, but tzcode reads the name
            // or replaces this field; it does not modify the name bytes.
            const text: ?[*c]u8 = if (self.zone) |name| @constCast(name.ptr) else null;
            if (@typeInfo(@TypeOf(raw.tm_zone)) == .optional) {
                raw.tm_zone = text;
            } else {
                raw.tm_zone = text orelse @ptrFromInt(0);
            }
        }
        return raw;
    }

    /// Seconds east of UTC, or null when this target's `struct tm` carries no
    /// `tm_gmtoff` field (MS-Windows, `NO_TM_GMTOFF`).  `Zone.utcOffset`
    /// answers the same question on every target.
    pub fn utcOffset(self: Tm) ?i64 {
        return self.gmtoff;
    }

    /// Copy the borrowed zone abbreviation into caller-owned memory.
    pub fn zoneNameOwned(self: Tm, gpa: std.mem.Allocator) std.mem.Allocator.Error!?[:0]const u8 {
        const borrowed = self.zone orelse return null;
        return try gpa.dupeZ(u8, borrowed);
    }

    /// Render as "YYYY-MM-DDTHH:MM:SS", built without locale input, plus
    /// "+HH:MM" or "-HH:MM" when `offset` is known.
    ///
    /// Pass `Tm.utcOffset` for the offset this value carries, or
    /// `Zone.utcOffset` for the one in effect at an instant.  Without an
    /// offset the rendering stops after the seconds rather than claiming a
    /// zero offset it cannot know.
    pub fn iso8601(self: Tm, gpa: std.mem.Allocator, offset: ?i64) std.mem.Allocator.Error![]u8 {
        const year: i64 = @as(i64, self.year) + 1900;
        const year_sign: []const u8 = if (year < 0) "-" else "";
        if (offset) |seconds| {
            const sign: u8 = if (seconds < 0) '-' else '+';
            const magnitude: u64 = @intCast(if (seconds < 0) -seconds else seconds);
            return std.fmt.allocPrint(gpa, "{s}{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>2}:{d:0>2}", .{
                year_sign,
                @abs(year),
                self.mon + 1,
                self.mday,
                self.hour,
                self.min,
                self.sec,
                sign,
                magnitude / 3600,
                (magnitude % 3600) / 60,
            });
        }
        return std.fmt.allocPrint(gpa, "{s}{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
            year_sign,
            @abs(year),
            self.mon + 1,
            self.mday,
            self.hour,
            self.min,
            self.sec,
        });
    }
};

/// An owning reentrant zone handle.
///
/// The handle is allocated by upstream `tz_tzalloc` and released by `close`;
/// no Zig allocator is involved on this path and the wrapper never hands out
/// the underlying pointer.  A `Zone` owns that handle, so move it instead of
/// copying it.
pub const Zone = struct {
    handle: c.timezone_t,
    closed: bool = false,

    /// Load a zone by name.
    ///
    /// `name` may be a TZif zone name ("Europe/Berlin"), a POSIX TZ
    /// specification ("EST5EDT,M3.2.0,M11.1.0"), or an absolute path to a TZif
    /// file.  A relative name is looked up below TZDIR, exactly as upstream
    /// does; by default that is the database this package's own build
    /// compiles, so a plain name resolves in a dependent package too.  See
    /// README.zig.md, "Where the data is".
    pub fn open(name: [:0]const u8) Error!Zone {
        const handle = c.tz_tzalloc(name.ptr);
        if (pointerIsNull(handle)) return error.InvalidZone;
        return .{ .handle = handle };
    }

    /// Release the handle.  Safe to call more than once.
    pub fn close(self: *Zone) void {
        if (!self.closed) {
            c.tz_tzfree(self.handle);
            self.closed = true;
        }
    }

    /// Convert a seconds-since-epoch timestamp (leap seconds excluded) to
    /// local time in this zone.  The result is Zig-owned.
    pub fn toLocal(self: Zone, timestamp: i64) Error!Tm {
        const seconds: c.time_t = @intCast(timestamp);
        var raw: c.struct_tm = undefined;
        const result = c.tz_localtime_rz(self.handle, &seconds, &raw);
        if (pointerIsNull(result)) return error.ConversionFailed;
        return Tm.fromC(result);
    }

    /// Convert local time in this zone to a seconds-since-epoch timestamp.
    ///
    /// `local` is normalized as `mktime_z` requires; ambiguous and skipped
    /// local times are resolved exactly as upstream resolves them.
    ///
    /// Upstream's only failure signal is the `WRONG` sentinel `-1`
    /// (localtime.c:2413-2415), which is also the valid instant
    /// 1969-12-31T23:59:59Z, so a caller cannot read a failure out of the
    /// value.  This wrapper rejects the one failure it can see - a year
    /// outside the C `int` range that `mktime_z` adds `TM_YEAR_BASE` to
    /// (localtime.c:2612-2614) - with `error.ConversionFailed`.  The others,
    /// a binary search that exhausts `TIME_T_MIN`/`TIME_T_MAX`
    /// (localtime.c:2656-2667) and an overflowing increment
    /// (localtime.c:2752-2753), answer `-1` as well, and are reported here as
    /// that instant.
    pub fn toUtc(self: Zone, local: Tm) Error!i64 {
        _ = std.math.add(i32, local.year, 1900) catch return error.ConversionFailed;
        var raw = local.toC();
        return @intCast(c.tz_mktime_z(self.handle, &raw));
    }

    /// UTC offset in effect at `timestamp`, in seconds east of UTC.
    ///
    /// The value comes from `struct tm`'s `tm_gmtoff` where the target has
    /// that field.  Where it has none (MS-Windows, `NO_TM_GMTOFF`) the offset
    /// is derived instead: `tz_timegm` reads the same broken-down time as if
    /// it were UTC (`localtime.c:2929-2940` calls `timeoff(&tmcpy, 0)`), so
    /// the instant it names is `timestamp` plus the offset east of UTC and
    /// the difference is the offset.  `localtime` already rejected a year
    /// outside the C `int` range, so `tz_timegm` cannot fail for this input.
    pub fn utcOffset(self: Zone, timestamp: i64) Error!i64 {
        const local = try self.toLocal(timestamp);
        if (local.gmtoff) |offset| return offset;
        var raw = local.toC();
        const as_utc: c.time_t = c.tz_timegm(&raw);
        return @as(i64, as_utc) - timestamp;
    }

    /// Convert a leap-second-counting timestamp ("right" time) to POSIX time.
    ///
    /// The database this package compiles carries no leap seconds, which is
    /// upstream's `REDO=posix_only` output, so both scales hold the same
    /// value for every timestamp.
    pub fn toPosix(self: Zone, right_seconds: i64) i64 {
        const value: c.time_t = @intCast(right_seconds);
        return @intCast(c.tz_time2posix_z(self.handle, value));
    }

    /// Convert POSIX time to a leap-second-counting ("right") timestamp.
    ///
    /// See `toPosix`: without leap-second data the value is unchanged.
    pub fn fromPosix(self: Zone, posix_seconds: i64) i64 {
        const value: c.time_t = @intCast(posix_seconds);
        return @intCast(c.tz_posix2time_z(self.handle, value));
    }
};

/// Convert a seconds-since-epoch timestamp to UTC, in tzcode's reentrant form.
pub fn toUtcTm(timestamp: i64) Error!Tm {
    const seconds: c.time_t = @intCast(timestamp);
    var raw: c.struct_tm = undefined;
    const result = c.tz_gmtime_r(&seconds, &raw);
    if (pointerIsNull(result)) return error.ConversionFailed;
    return Tm.fromC(result);
}

/// Longest result `formatAlloc` renders before reporting `FormatTooLong`.
const max_format_bytes = 64 * 1024;

/// Format `value` with upstream `strftime`, allocating the result.
///
/// `strftime` signals failure by returning 0, which is also the length of a
/// valid empty result - an empty format string renders nothing - so the
/// wrapper reads the out-of-band signal upstream documents: `strftime` sets
/// `ERANGE` when the result did not fit and restores the caller's `errno`
/// when it succeeded (strftime.c:206-212).
///
/// `%Z` and `%z` do not name the zone a value was converted in on a target
/// whose `struct tm` carries neither `tm_zone` nor `tm_gmtoff`
/// (MS-Windows): there neither field has anything to read, so `%Z` renders
/// the empty string because `HAVE_TZNAME` is also 0 (strftime.c:560-567) and
/// `%z` renders nothing at all, because `USG_COMPAT` and `ALTZONE` are off
/// too (strftime.c:575-641).  `Tm.zone` and `Zone.utcOffset` are correct on
/// every target.
pub fn formatAlloc(
    gpa: std.mem.Allocator,
    value: Tm,
    format: [:0]const u8,
) (std.mem.Allocator.Error || Error)![]u8 {
    var raw = value.toC();
    var stack_buffer: [256]u8 = undefined;
    if (try formatInto(gpa, &stack_buffer, format, &raw)) |text| return text;

    const heap_buffer = try gpa.alloc(u8, max_format_bytes);
    defer gpa.free(heap_buffer);
    if (try formatInto(gpa, heap_buffer, format, &raw)) |text| return text;
    return error.FormatTooLong;
}

/// One `tz_strftime` attempt into `buffer`.  Returns the rendered text -
/// empty for a format that renders nothing - or null when the result did not
/// fit, which upstream reports by setting `ERANGE`.
fn formatInto(
    gpa: std.mem.Allocator,
    buffer: []u8,
    format: [:0]const u8,
    raw: *const c.struct_tm,
) std.mem.Allocator.Error!?[]u8 {
    // `errno` is a thread-local C int; std.c._errno() is the pointer libc's
    // own <errno.h> writes to for this thread.  The enum's backing type
    // differs per target, so the comparison value is narrowed to c_int.
    const range: c_int = @intCast(@intFromEnum(std.c.E.RANGE));
    std.c._errno().* = 0;
    const length = c.tz_strftime(buffer.ptr, buffer.len, format.ptr, raw);
    if (length != 0) return try gpa.dupe(u8, buffer[0..length]);
    if (std.c._errno().* == range) return null;
    return try gpa.dupe(u8, "");
}
