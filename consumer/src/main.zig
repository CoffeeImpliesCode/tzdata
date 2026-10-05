//! Consumer of the tzdata package: converts instants with the module it
//! depends on and checks the results against independently known civil times.
//!
//! Two databases are exercised.  The zones in `data/consumer.zi` are compiled
//! by the dependency's own `zic` during the build, so this program needs no
//! installed database and no network access; the build passes that tree's
//! path as the first argument.  The IANA zones are opened by plain name with
//! no path and no environment variable, which is what proves the dependency
//! ships a usable database on its own.  The last conversion goes through the
//! translated C declarations directly, with its own reentrant handle, so the
//! aggregate header and the `tz_` namespace are exercised too.  Any mismatch
//! exits non-zero.
//!
//! ## Naming a provider, in a runtime-loaded build
//!
//! When the dependency was configured to resolve its native symbols at run
//! time, nothing is linked into this program and there is no fallback: this
//! one has to say which library to open, with `--provider <path>` anywhere on
//! the command line or through the `TZDATA_PROVIDER` environment variable.
//! It never silently uses the bundled linkage - if the dependency is
//! runtime-loaded and neither names one, this exits non-zero rather than
//! passing.  Passing `--provider` to a *linked* dependency is refused rather
//! than ignored, because there would be nothing for it to do.
//!
//! ## The provider's data
//!
//! A plain zone name is resolved by the library below the `TZDIR` that was
//! compiled into *it*, which is `<that provider's install prefix>/share/zoneinfo`
//! when it came from this package's own graph.  That tree has to be present at
//! run time and it is not this program's to choose.  The dependency installs
//! exactly what its `-Dlinkage` asked for and nothing else, so under the
//! default static linkage it produces no loadable artefact and the provider is
//! supplied separately; build one first with `-Dlinkage=dynamic` if this
//! program has to name a path.  A zone opened by absolute path, and a POSIX TZ
//! specification, need no database at all, which is why the raw conversions
//! below work even when no tree is reachable.

const std = @import("std");
const Io = std.Io;
const tzdata = @import("tzdata");

/// Environment variable naming the provider when `--provider` is not given.
const provider_variable = "TZDATA_PROVIDER";

const Case = struct {
    timestamp: i64,
    /// Independently known local time, abbreviation and UTC offset.
    local: [:0]const u8,
    abbreviation: [:0]const u8,
    offset: i64,
};

/// Etc/Consumer is -05:00 "Cst" outside the 2030 daylight saving season and
/// -04:00 "Cdt" inside it; 2030-03-10T07:00:00Z and 2030-11-03T06:00:00Z are
/// the two transitions.
const cases = [_]Case{
    .{
        .timestamp = -1, // one second before the epoch
        .local = "1969-12-31T18:59:59-05:00",
        .abbreviation = "Cst",
        .offset = -5 * 3600,
    },
    .{
        .timestamp = 0,
        .local = "1969-12-31T19:00:00-05:00",
        .abbreviation = "Cst",
        .offset = -5 * 3600,
    },
    .{
        .timestamp = 1899356400, // 2030-03-10T07:00:00Z
        .local = "2030-03-10T03:00:00-04:00",
        .abbreviation = "Cdt",
        .offset = -4 * 3600,
    },
    .{
        .timestamp = 1907755200, // 2030-06-15T12:00:00Z
        .local = "2030-06-15T08:00:00-04:00",
        .abbreviation = "Cdt",
        .offset = -4 * 3600,
    },
    .{
        .timestamp = 1919916000, // 2030-11-03T06:00:00Z
        .local = "2030-11-03T01:00:00-05:00",
        .abbreviation = "Cst",
        .offset = -5 * 3600,
    },
    .{
        .timestamp = 4102444800, // 2100-01-01T00:00:00Z, beyond 2038
        .local = "2099-12-31T19:00:00-05:00",
        .abbreviation = "Cst",
        .offset = -5 * 3600,
    },
};

/// Zones of the bundled IANA database, opened by plain name.  The instants
/// are chosen so the civil time is known without consulting the database:
/// Berlin is on European summer time in June and on standard time in
/// November, and New York is on standard time before its March transition
/// and on daylight time in June.
const bundled_cases = [_]struct { zone: [:0]const u8, case: Case }{
    .{
        .zone = "Europe/Berlin",
        .case = .{
            .timestamp = 1782043200, // 2026-06-21T12:00:00Z
            .local = "2026-06-21T14:00:00+02:00",
            .abbreviation = "CEST",
            .offset = 2 * 3600,
        },
    },
    .{
        .zone = "Europe/Berlin",
        .case = .{
            .timestamp = 1700000000, // 2023-11-14T22:13:20Z
            .local = "2023-11-14T23:13:20+01:00",
            .abbreviation = "CET",
            .offset = 3600,
        },
    },
    .{
        .zone = "America/New_York",
        .case = .{
            .timestamp = 1772366400, // 2026-03-01T12:00:00Z
            .local = "2026-03-01T07:00:00-05:00",
            .abbreviation = "EST",
            .offset = -5 * 3600,
        },
    },
    .{
        .zone = "America/New_York",
        .case = .{
            .timestamp = 1782043200, // 2026-06-21T12:00:00Z
            .local = "2026-06-21T08:00:00-04:00",
            .abbreviation = "EDT",
            .offset = -4 * 3600,
        },
    },
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    // The build passes the database its own zic compiled as the first
    // argument; a run step's output directory has no path at configure time.
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) return error.MissingZoneinfoDirectory;
    const zoneinfo = args[1];

    try loadProvider(init, arena, args);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    if (comptime tzdata.runtime_loaded) {
        // The loader retains its own copy for the life of the process, so this
        // is a stable pointer into that copy rather than into `arena`.
        const loaded = tzdata.loadedSource().?;
        try stdout.print("provider {s}\n", .{switch (loaded) {
            .path => |path| path,
            .system => |name| name,
        }});
    }

    const zone_path = try std.fmt.allocPrintSentinel(arena, "{s}/Etc/Consumer", .{zoneinfo}, 0);
    var zone = try tzdata.Zone.open(zone_path);
    defer zone.close();

    try stdout.print("tzdata {s}\n", .{tzdata.version()});

    for (cases) |case| {
        const converted = try zone.toLocal(case.timestamp);
        const offset = try zone.utcOffset(case.timestamp);
        const rendered = try converted.iso8601(arena, offset);
        const abbreviation = (try converted.zoneNameOwned(arena)).?;

        try stdout.print(
            "Etc/Consumer t={d} -> {s} {s} offset={d}\n",
            .{ case.timestamp, rendered, abbreviation, offset },
        );

        if (!std.mem.eql(u8, rendered, case.local)) return error.UnexpectedLocalTime;
        if (!std.mem.eql(u8, abbreviation, case.abbreviation)) return error.UnexpectedAbbreviation;
        if (offset != case.offset) return error.UnexpectedOffset;
        if (try zone.toUtc(converted) != case.timestamp) return error.UnexpectedRoundTrip;
    }

    // The same zone reached through a UTC database entry, and strftime.
    const utc_path = try std.fmt.allocPrintSentinel(arena, "{s}/Etc/ConsumerUTC", .{zoneinfo}, 0);
    var utc_zone = try tzdata.Zone.open(utc_path);
    defer utc_zone.close();
    const utc_converted = try utc_zone.toLocal(1919916000);
    const utc_rendered = try utc_converted.iso8601(arena, try utc_zone.utcOffset(1919916000));
    try stdout.print("Etc/ConsumerUTC t=1919916000 -> {s} ({s})\n", .{
        utc_rendered,
        try tzdata.formatAlloc(arena, utc_converted, "%Y-%m-%dT%H:%M:%S"),
    });
    if (!std.mem.eql(u8, utc_rendered, "2030-11-03T06:00:00+00:00")) return error.UnexpectedUtc;

    // Plain names only: whatever path the dependency compiled its database
    // into, the module alone must be able to open these.
    for (bundled_cases) |bundled| {
        var bundled_zone = try tzdata.Zone.open(bundled.zone);
        defer bundled_zone.close();

        const converted = try bundled_zone.toLocal(bundled.case.timestamp);
        const offset = try bundled_zone.utcOffset(bundled.case.timestamp);
        const rendered = try converted.iso8601(arena, offset);
        const abbreviation = (try converted.zoneNameOwned(arena)).?;

        try stdout.print(
            "{s} t={d} -> {s} {s} offset={d}\n",
            .{ bundled.zone, bundled.case.timestamp, rendered, abbreviation, offset },
        );

        if (!std.mem.eql(u8, rendered, bundled.case.local)) return error.UnexpectedLocalTime;
        if (!std.mem.eql(u8, abbreviation, bundled.case.abbreviation)) {
            return error.UnexpectedAbbreviation;
        }
        if (offset != bundled.case.offset) return error.UnexpectedOffset;
        if (try bundled_zone.toUtc(converted) != bundled.case.timestamp) {
            return error.UnexpectedRoundTrip;
        }
    }

    // One conversion through the translated C declarations themselves, which
    // is the only path that exercises the aggregate header, the `tz_`
    // namespace and the target ABI without the typed layer in between.
    try rawHandleConversion(stdout);
}

/// Convert the epoch with `tz_tzalloc`, `tz_localtime_rz` and `tz_tzfree`
/// exactly as a C caller would, and release the handle exactly once.
///
/// Europe/Berlin is one hour east of UTC in January, so the epoch is
/// 1970-01-01 01:00:00 local time.  The zone is named, not opened by path, so
/// this conversion does depend on the provider's TZif tree - which is the
/// point: it is the one conversion here that exercises the provider's data
/// resource rather than a compiled-in rule.
fn rawHandleConversion(stdout: *std.Io.Writer) !void {
    const handle = tzdata.c.tz_tzalloc("Europe/Berlin");
    if (tzdata.pointerIsNull(handle)) return error.InvalidZone;
    defer tzdata.c.tz_tzfree(handle);

    var seconds: tzdata.c.time_t = 0;
    var raw: tzdata.c.struct_tm = undefined;
    const converted = tzdata.c.tz_localtime_rz(handle, &seconds, &raw);
    if (tzdata.pointerIsNull(converted)) return error.ConversionFailed;

    try stdout.print(
        "c.tz_localtime_rz Europe/Berlin t=0 -> {d}-{d}-{d} {d}:{d}:{d} isdst={d}\n",
        .{
            raw.tm_year,  raw.tm_mon + 1, raw.tm_mday,
            raw.tm_hour,  raw.tm_min,     raw.tm_sec,
            raw.tm_isdst,
        },
    );

    if (raw.tm_year != 70 or raw.tm_mon != 0 or raw.tm_mday != 1 or
        raw.tm_hour != 1 or raw.tm_min != 0 or raw.tm_sec != 0 or raw.tm_isdst != 0)
    {
        return error.UnexpectedRawLocalTime;
    }
    if (comptime @hasField(tzdata.c.struct_tm, "tm_gmtoff")) {
        if (raw.tm_gmtoff != 3600) return error.UnexpectedRawOffset;
    }

    // The three exported objects are read through the provider's own storage,
    // never through a value captured at load time.  A reentrant handle never
    // publishes into them (`localtime.c:2891`), so they still hold whatever the
    // ambient zone last wrote and this consumer has no reason to expect any
    // particular value - it only proves they are readable where the build
    // emits them at all.
    if (comptime tzdata.Ambient.usg_compat_emitted) {
        try stdout.print(
            "c.tz_timezone={d} c.tz_daylight={d} c.tz_tzname[0]={s}\n",
            .{
                tzdata.Ambient.standardOffsetSeconds().?,
                @intFromBool(tzdata.Ambient.daylightSavingEverUsed().?),
                tzdata.Ambient.abbreviation(0) orelse "(unset)",
            },
        );
    }
}

/// Name the provider and load it, or say exactly what is missing.
///
/// `--provider <path>` wins over `TZDATA_PROVIDER`; neither is a search path,
/// and there is no fallback from one to the other.  The environment value is
/// copied into `arena` because the loader retains its own copy anyway and the
/// caller's buffer is not required to outlive the call.
fn loadProvider(
    init: std.process.Init,
    arena: std.mem.Allocator,
    args: []const [:0]const u8,
) !void {
    var named_on_command_line: ?[]const u8 = null;
    var index: usize = 2;
    while (index + 1 < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--provider")) named_on_command_line = args[index + 1];
    }

    if (comptime !tzdata.runtime_loaded) {
        // A linked dependency has the library in its link line; there is
        // nothing to load and nothing a provider name could change, so saying
        // so beats quietly ignoring the argument.
        if (named_on_command_line != null) return error.ProviderNamedForLinkedBuild;
        return;
    }

    if (named_on_command_line) |path| {
        try tzdata.load(.{ .path = path });
        return;
    }

    const named = std.process.Environ.getAlloc(init.minimal.environ, arena, provider_variable) catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "tzdata consumer: the dependency resolves tzcode at run time, so " ++
                    "this program must say which library to open. Pass " ++
                    "--provider <path>, or set {s} to a libtz from that " ++
                    "dependency's own build graph (build one with " ++
                    "-Dlinkage=dynamic), beside the TZif tree its TZDIR names.\n",
                .{provider_variable},
            );
            return error.MissingProvider;
        },
        else => return err,
    };
    try tzdata.load(.{ .path = named });
}