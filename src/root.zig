//! Public Zig interface to the tzcode core library (eggert/tz).
//!
//! One registered module publishes two things: the typed layer below, and `c`,
//! the translated declarations of `include/tzdata.h`.  The typed layer adds an
//! owning reentrant zone handle over `tz_tzalloc`/`tz_tzfree`, conversions over
//! `tz_localtime_rz`/`tz_mktime_z` that hand out `Tm` values instead of
//! pointers into tzcode's internal state, and rendering through `iso8601` and
//! `formatAlloc`.  Nothing here reimplements an upstream algorithm; it fixes
//! ownership, sentinel strings, null-pointer conversion and 64-bit `time_t`.
//!
//! Every conversion in the typed layer names its zone, so no result depends on
//! ambient environment state: the reentrant entry points `tz_localtime_rz` and
//! `tz_mktime_z` work on the handle they were given and never publish into
//! the process globals (`localtime.c:2891`).  `Ambient` is the one namespace
//! that does look at the environment, and it is opt-in.  There is no
//! system-library mode, because no installed library exports `tz_tzalloc`,
//! `tz_localtime_rz`, `tz_mktime_z` or `tz_time2posix_z`.
//!
//! ## Two configurations: linked and runtime-loaded
//!
//! This module is built in one of two shapes, and `runtime_loaded` says which
//! at comptime.
//!
//! *Linked* is the default.  The `tz` archive is linked, `c` is the translated
//! header, and every call below is an ordinary direct call into it: no table,
//! no lookup, no readiness check.
//!
//! *Runtime-loaded* is opt-in.  Nothing is linked; `c` is a dispatch generated
//! from the same translation step's output, and every native entry point -
//! twenty-six functions unconditionally, plus whatever `SUPPORT_POSIX2008`,
//! `HAVE_STRFTIME_L`, `HAVE_TZNAME` and `USG_COMPAT` add - is resolved
//! through the platform loader when the caller calls
//!
//! ```zig
//! try tzdata.load(.{ .path = "/usr/local/lib/libtz.so" });
//! ```
//!
//! before using anything else.  A call into a module that has not loaded stops
//! the program with a message naming the function, in every optimization mode.
//! That is a programming error rather than a recoverable condition: the table
//! does not exist yet, and there is no partial state to fall back on.  The
//! load itself reports a missing file, a provider that does not export what
//! the header declares, a provider whose `struct tm` does not match, a request
//! that cannot be honoured because a different provider already won, or a
//! reentrant call, as errors rather than as a different library being loaded
//! instead.
//!
//! The provider is reached, never guessed.  `.path` names an absolute file and
//! `.system` names a basename or SONAME for the platform loader; neither falls
//! back to the other, the module has no unload and no reset, and it keeps the
//! handle and its own copy of the request to the end of the process.
//!
//! A provider carries its own data too: it resolves a plain zone name below
//! the `TZDIR` that was compiled into *it*, and that tree has to be present at
//! run time.  `runtime/library.zig` records what a provider must be - the four
//! configuration macros, the `time_t` width, the `struct tm` layout, the
//! allocator pairing and the TZDIR data resource - and what the one load-time
//! check does and does not establish.
//!
//! One thing differs in spelling between the two configurations and is
//! bridged here rather than left to every caller: a routed exported object
//! reaches the caller as `NAMEAddr()` in a runtime-loaded build and as the
//! variable itself in a linked one.  `Ambient` reads through whichever form
//! this build has, so the same call site works in both.
//!
//! Shortest sequence:
//!
//! ```zig
//! const std = @import("std");
//! const tzdata = @import("tzdata");
//!
//! pub fn main(init: std.process.Init) !void {
//!     var zone = try tzdata.Zone.open("Europe/Berlin");
//!     defer zone.close();
//!     const timestamp = 1782043200;
//!     const local = try zone.toLocal(timestamp);
//!     const text = try local.iso8601(init.gpa, try zone.utcOffset(timestamp));
//!     defer init.gpa.free(text);
//!     std.debug.print("{s}\n", .{text});
//! }
//! ```
//!
//! What the caller owns:
//!
//! * `Zone.close` releases the upstream handle through `tz_tzfree`.  Every
//!   other method of `Zone` needs a value whose `close` has not run.
//! * `Tm.zone` is borrowed storage whose producer decides how long it lives;
//!   see that field.  `Tm.zoneNameOwned`, `Tm.iso8601` and `formatAlloc`
//!   allocate through the allocator passed in, and are released with that same
//!   allocator - `zoneNameOwned` returns a sentinel-terminated slice, the
//!   other two a plain `[]u8`.
//! * `version` and `packageName` borrow strings inside the library, and so do
//!   `Ambient.abbreviation`'s results: both point at storage the C side owns
//!   for the life of the process.  Nothing else here is allocated for the
//!   caller to free, and no upstream `malloc` result ever leaves the library.
//!
//! The library resolves plain zone names below one absolute `TZDIR` compiled
//! into it, which the build that produced it fills; that directory has to be
//! present at run time.  In a linked build that is this tree's build; in a
//! runtime-loaded build it is whatever the *provider* was built with, which
//! this module neither chooses nor can see - see `runtime/library.zig`.  An
//! absolute path to a TZif file, and a POSIX TZ specification, both work with
//! no database present at all.  See README.zig.md, "Where the data is".
//!
//! This module requires a signed 64-bit `time_t` and refuses to compile
//! against a narrower one instead of truncating.  `src/smoke.zig`, `test/`
//! and `consumer/` call every entry point declared here, so `zig build check`
//! compiles all of them for each of its six targets; that step compiles
//! without running anything, so it is compile evidence and not a runtime
//! result.
//!
//! Symbol isolation: this package always compiles tzcode with upstream's
//! documented `-Dtime_tz=time_t` mode, which renames every externally visible
//! identifier to a `tz_`-prefixed spelling (`tz_localtime`, `tz_mktime`,
//! `tz_tzalloc`, ...).  Linking this package next to a C library that owns
//! `localtime`, `mktime`, `tzname`, `timezone`, `daylight` or `strftime`
//! therefore never replaces or shadows those symbols.  See README.zig.md.

const std = @import("std");

/// Complete translated declarations of `include/tzdata.h`: the whole upstream
/// tzcode surface in its `tz_` spelling.
///
/// This is the raw escape hatch and a supported route; the typed layer below
/// is the convenience.  Reaching a declaration here carries the C contract
/// unchanged, so these are the obligations:
///
/// * In a linked build the module links the `tz` library, so a `c` call needs
///   no extra link step and is an ordinary direct call.  In a runtime-loaded
///   build nothing is linked and a `c` call goes through the table `load`
///   fills.  `@hasDecl(c, ...)` is how a caller asks for a declaration that
///   only some targets build; `c` carries exactly the set this build emits.
/// * The one naming difference between the two configurations is an exported
///   *object*: `tz_tzname`, `tz_timezone` and `tz_daylight` are the variable in
///   a linked build and a `NAMEAddr()` function returning the provider's
///   address in a runtime-loaded one, wherever the build emits them at all.
///   `Ambient` reads through whichever form this build has.  A function is a
///   function in both, so nothing else in this namespace changes shape.
/// * A result that can be null arrives as whatever the translator produced -
///   an optional or a plain pointer - so `pointerIsNull` is how it is tested.
/// * `tz_localtime_rz`, `tz_gmtime_r` and other conversions write into the
///   caller's `struct tm` and return it, or null. `tm_gmtoff` is a scalar.
///   `tm_zone` borrows from the producing zone state or static UTC storage,
///   not the caller's buffer. `tz_mktime_z` can replace both fields.
/// * `tz_tzalloc` is released with `tz_tzfree` and with nothing else, exactly
///   once per handle.
/// * `tz_strftime` writes into a caller buffer of the caller's size and
///   returns the length, or 0 for both an empty result and `ERANGE`.
pub const c = @import("tz_c");

/// The loader core, which is where a linked build's two public types come
/// from.
///
/// It is imported only by the linked configuration. In a runtime-loading build
/// the generated dispatch carries its own copy of the same declarations, and
/// this module is never referenced, so it is never resolved and never
/// compiled. Either way there is exactly one `LoadSource` and one `LoadError`
/// in a build, which is what keeps them one type for a consumer that names
/// them.
const rt = @import("rt");

/// Whether this module was configured to resolve its native symbols at run
/// time.
///
/// False for the ordinary build, where the tz library is linked and `c` is the
/// translated header itself: every call below is then an ordinary direct call
/// into the archive, with no table and no readiness check. True when the build
/// generated a dispatch that resolves the same symbols through the platform
/// loader, in which case `load` is the call that makes the library usable.
///
/// It is a comptime constant, so a consumer can write two different code paths
/// and have only the one it chose analyzed.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// Which native library `load` should open.
///
/// `.path` is an explicit **absolute** file path and `.system` is an explicit
/// name for the platform loader - a basename or SONAME, never a path.  There
/// is no path-to-system fallback in either direction and no search path of our
/// own: a request that names the wrong kind fails as `InvalidSource` rather
/// than quietly becoming the other kind, and a request that cannot be honoured
/// is an error, not a different library.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Every way `load` can decline.
///
/// Declared here, in the module a consumer imports, rather than only inside
/// the loader: the caller names the failure it is handling.  The closed set is
/// `EmptySource`, `SourceTooLong`, `InvalidSource`, `UnsupportedTarget`,
/// `OpenFailed`, `MissingSymbol`, `ValidationFailed`, `ProviderMismatch` and
/// `ReentrantLoad`.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Load the native library this module dispatches to.
///
/// In a runtime-loading build this is the whole contract: call it once, then
/// use this module as if it were linked. Calling it again with the same request
/// succeeds and changes nothing; calling it with a different request after a
/// success is `ProviderMismatch`, and the library already in use stays in use.
/// A failed attempt publishes nothing and can be retried explicitly, by
/// calling this again: there is no automatic retry, and no implicit second
/// source.
///
/// It keeps the process handle and its own copy of the request to the end of
/// the process. There is no unload and no reset, because the table is
/// process-global state that other code may already have called through.
///
/// Safe to call from any thread. A thread that arrives while an attempt for
/// the same request is in flight waits for that attempt and gets its result,
/// whatever it was. A call from the thread that is running the attempt is
/// `ReentrantLoad` rather than a deadlock.
///
/// In a linked build there is no provider, no table and nothing to resolve, so
/// this stops the program with a message saying so instead of quietly
/// succeeding. `runtime_loaded` is false there, so a consumer that supports
/// both configurations can tell the two apart at comptime instead of meeting
/// this at run time.
pub fn load(source: LoadSource) LoadError!void {
    if (comptime !runtime_loaded) {
        std.debug.panic(
            "tzdata: load was called on a linked build; this module is not " ++
                "runtime-loaded, so there is no library to load. Build with " ++
                "runtime loading configured, or do not call load.",
            .{},
        );
    }
    return c.load(source);
}

/// The request that succeeded, or null when nothing has loaded yet.
///
/// The answer is the loader's own retained copy and stays valid for the life
/// of the process. Null in a linked build, which has no request.
pub fn loadedSource() ?LoadSource {
    if (comptime !runtime_loaded) return null;
    return c.loadedSource();
}

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

/// True when a raw C result is the null pointer.
///
/// C headers do not record nullability, so the translator may model a pointer
/// either as an optional or as a plain pointer; both are handled here.  Use it
/// on any `c` result before reading it.  Testing a `Zone.handle` this way is
/// an ordinary comparison, not a trap.
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
///
/// One closed vocabulary for the whole module.  Each method reaches only part
/// of it, so a `catch` here may name a tag that particular call cannot answer.
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
///
/// Borrows a static string inside the linked library: valid for the life of
/// the process, and never released.
pub fn version() [:0]const u8 {
    return ownedSentinel(c.tzdata_version());
}

/// The upstream package string, e.g. "(tzcode) ", borrowed from static storage
/// inside the linked library exactly as `version` is.
pub fn packageName() [:0]const u8 {
    return ownedSentinel(c.tzdata_package());
}

/// A broken-down local time, owned by the caller.
///
/// This is a value.  Copying a `Tm` copies its fields, a copy is independent,
/// and nothing owns or releases memory for it - the one field that names
/// memory outside the struct is `zone`, and both copies then borrow the same
/// bytes.
///
/// Field ranges and meanings follow `struct tm` from <time.h>: `year` counts
/// years since 1900 and `isdst` keeps the raw C value (positive when daylight
/// saving time is in effect, zero for standard time, negative when unknown).
/// The field types are the widths of the C fields, not a validated range:
/// `Zone.toUtc` normalizes an out-of-range `mon`, `mday`, `hour`, `min` or
/// `sec` by carrying into the next field, the way `mktime_z` does
/// (`localtime.c:2545-2606`), and overwrites `wday` and `yday`, which it
/// never reads.
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
    /// Zone abbreviation, or `null` where the target's `struct tm` carries no
    /// `tm_zone` (MS-Windows, `NO_TM_ZONE`).
    ///
    /// The bytes belong to whichever call produced this value, so the producer
    /// - not this field and not a copy of the struct - decides how long they
    /// live:
    ///
    /// * from `Zone.toLocal`, they are the abbreviation table inside that
    ///   `Zone`'s upstream state (`localtime.c:2115`), so the slice is
    ///   invalidated by `close` on that `Zone`;
    /// * from `toUtcTm`, they are tzcode's process-wide UTC state
    ///   (`localtime.c:2214-2215`), which lives for the life of the process
    ///   and is invalidated by no `Zone`.
    ///
    /// Copy it with `zoneNameOwned` to keep the name past its producer.
    zone: ?[:0]const u8,

    /// Copy a C `struct tm` into a `Tm`.
    ///
    /// Every scalar is copied out of `raw`.  `zone` is not: `tm_zone` points
    /// at abbreviation storage rather than into `raw`, so the result borrows
    /// whatever produced `raw` and says nothing about `raw`'s own lifetime.
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
    ///
    /// `tm_gmtoff` becomes `gmtoff orelse 0`, because upstream treats that
    /// field as a hint it checks rather than as input it trusts
    /// (`localtime.c:2673-2711`), so zero stands in for "unknown" there and
    /// not for UTC.  `tm_zone` becomes a pointer at `zone`'s bytes when the
    /// field exists, which is what upstream `strftime` reads for `%Z`
    /// (`strftime.c:560-567`); the returned struct borrows them, so it is only
    /// valid while that `zone` is.
    ///
    /// Upstream writes back into the struct it is handed: `tz_mktime_z`
    /// normalizes calendar fields and replaces `tm_gmtoff`
    /// (`localtime.c:2393-2400`), then `localsub` sets `tm_zone`
    /// (`localtime.c:2111-2115`). `Zone.toUtc` passes a private struct and
    /// leaves the caller's `Tm` unchanged.
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
            // Upstream `strftime` reads this pointer for `%Z` (strftime.c:562)
            // and `tz_mktime_z` replaces the field without reading it
            // (`mktmcpy` copies no tm_zone, localtime.c:2511-2524), so no
            // upstream entry point writes through the name.  Darwin declares
            // the field as a mutable pointer, hence the constCast.
            const text: ?[*c]u8 = if (self.zone) |name| @constCast(name.ptr) else null;
            if (@typeInfo(@TypeOf(raw.tm_zone)) == .optional) {
                raw.tm_zone = text;
            } else {
                raw.tm_zone = text orelse @ptrFromInt(0);
            }
        }
        return raw;
    }

    /// Seconds east of UTC, or `null` where this target's `struct tm` carries
    /// no `tm_gmtoff` field (MS-Windows, `NO_TM_GMTOFF`).
    ///
    /// `null` means this target cannot answer, not that the offset is zero.
    /// `Zone.utcOffset` answers it on every target.
    pub fn utcOffset(self: Tm) ?i64 {
        return self.gmtoff;
    }

    /// Copy the borrowed zone abbreviation into caller-owned memory.
    ///
    /// Returns `null` when `zone` is `null`, which is the whole difference
    /// between a target with `tm_zone` and one without.  On success the
    /// result is sentinel-terminated, allocated from `gpa`, owned by the
    /// caller and released with `gpa.free`; it borrows nothing, so it stays
    /// valid after the producer of `zone` is gone.  `error.OutOfMemory` is the
    /// only failure, and nothing has been allocated when it is returned.
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
    ///
    /// A month the caller never normalized is rendered as one more than the
    /// field holds, so the widest value a `u5` month can carry renders as
    /// `32` rather than failing, and an offset is rendered from its unsigned
    /// magnitude, which every `i64` has.
    ///
    /// The result is a plain `[]u8` allocated from `gpa` - not sentinel
    /// terminated - and is released with `gpa.free`.  Nothing in it borrows
    /// from `self`, which is taken by value, so the caller may close the zone
    /// first.  `error.OutOfMemory` is the only failure.
    pub fn iso8601(self: Tm, gpa: std.mem.Allocator, offset: ?i64) std.mem.Allocator.Error![]u8 {
        const year: i64 = @as(i64, self.year) + 1900;
        const year_sign: []const u8 = if (year < 0) "-" else "";
        // One wider than the field, because `mon` is the width of the C field
        // and not a validated range: the widest value it holds renders like
        // every other one rather than overflowing on the way to a number.
        const month: u6 = @as(u6, self.mon) + 1;
        if (offset) |seconds| {
            const sign: u8 = if (seconds < 0) '-' else '+';
            // Taken in unsigned arithmetic rather than by negating the signed
            // value, which is the one magnitude `minInt(i64)` cannot survive.
            const magnitude: u64 = if (seconds < 0)
                @as(u64, @intCast(~seconds)) + 1
            else
                @intCast(seconds);
            return std.fmt.allocPrint(gpa, "{s}{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>2}:{d:0>2}", .{
                year_sign,
                @abs(year),
                month,
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
            month,
            self.mday,
            self.hour,
            self.min,
            self.sec,
        });
    }
};

/// An owning reentrant zone handle over one `tz_tzalloc` state.
///
/// One `Zone` owns that state and releases it in `close`.  Move a `Zone`
/// rather than copying it: Zig has no move-only type, so a copy names the same
/// handle with its own `closed` flag, and `close` reached through two copies
/// frees the same state twice.  Nothing here detects that alias.
///
/// `handle` and `closed` are reachable fields, because Zig has no private
/// fields.  The type therefore has one valid state: a value `open` returned
/// whose `close` has not run.  Every method below except `close` dereferences
/// the handle, so a conversion through a closed or alias-copied `Zone` is a
/// use-after-free that nothing here checks.  A struct literal carrying a
/// `handle` the caller did not get from `open` is not a `Zone` at all: `close`
/// hands that pointer to `tz_tzfree`, which frees it.
pub const Zone = struct {
    /// The upstream `timezone_t`, valid from a successful `open` until `close`
    /// releases it and unusable afterwards.  It is reachable because passing
    /// it to `c` is a supported route; a caller that does so then owns the
    /// release through `c.tz_tzfree` exactly once and must not also call
    /// `close`.
    handle: c.timezone_t,
    /// Whether `close` has already run on this value.  The guard is a field,
    /// so it covers repeat calls on one variable only; a copy taken before the
    /// close keeps its own false flag and is not protected by it.
    closed: bool = false,

    /// Load a zone by name.
    ///
    /// `name` may be a TZif zone name ("Europe/Berlin"), a POSIX TZ
    /// specification ("EST5EDT,M3.2.0,M11.1.0"), or an absolute path to a TZif
    /// file.  A relative name is looked up below TZDIR, exactly as upstream
    /// does; by default that is the database this package's own build
    /// compiles, so a plain name resolves in a dependent package too.  See
    /// README.zig.md, "Where the data is".
    ///
    /// An empty name is not "use the ambient zone".  Upstream takes a
    /// zero-offset UTC fast path that reads no file and no environment
    /// variable (`localtime.c:1808-1819`): the handle answers "UTC" with a
    /// +00:00 offset, `isdst` zero and the abbreviation "UTC" for every
    /// timestamp, on every target.
    ///
    /// `name` is read during the call only and is not retained.  On
    /// `error.InvalidZone` no handle exists and the caller's state is
    /// unchanged; upstream answers null for a name that is neither a readable
    /// TZif file, nor a POSIX TZ specification, nor affordable.
    pub fn open(name: [:0]const u8) Error!Zone {
        const handle = c.tz_tzalloc(name.ptr);
        if (pointerIsNull(handle)) return error.InvalidZone;
        return .{ .handle = handle };
    }

    /// Release the handle through `tz_tzfree` and mark this value closed.
    ///
    /// Idempotent on one variable, so a second call is a no-op and this is
    /// safe to `defer`.  What that does not cover is a copy taken before the
    /// call: it still holds the handle, its own flag is still false, and
    /// closing both frees the same state twice.  No method may be called
    /// through this value afterwards.
    pub fn close(self: *Zone) void {
        if (!self.closed) {
            c.tz_tzfree(self.handle);
            self.closed = true;
        }
    }

    /// Convert a seconds-since-epoch timestamp (leap seconds excluded) to
    /// local time in this zone.
    ///
    /// The `Tm` comes back as an independent value, but its `zone` field
    /// borrows this zone's abbreviation storage, so the value as a whole must
    /// not be read after `close`.  Use `zoneNameOwned` for a copy that
    /// outlives it.
    ///
    /// `self` is taken by value, so the call copies the handle: the copy is
    /// usable while the owning value is open, and `close` on either ends the
    /// handle for both.  `error.ConversionFailed` means upstream returned a
    /// null result, and then no `Tm` exists.
    pub fn toLocal(self: Zone, timestamp: i64) Error!Tm {
        const seconds: c.time_t = @intCast(timestamp);
        var raw: c.struct_tm = undefined;
        const result = c.tz_localtime_rz(self.handle, &seconds, &raw);
        if (pointerIsNull(result)) return error.ConversionFailed;
        return Tm.fromC(result);
    }

    /// Convert local time in this zone to a seconds-since-epoch timestamp.
    ///
    /// `local` is passed by value and upstream's normalized result lands in a
    /// private `struct tm`, so the caller's `Tm` is not modified even though
    /// `tz_mktime_z` rewrites the struct it is given.  Ambiguous and skipped
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
///
/// No `Zone` is involved, so this is not a zone borrow: the result's `zone`
/// points into tzcode's process-wide UTC state (`localtime.c:2214-2215`),
/// which lives for the life of the process and is invalidated by no `Zone`
/// this module exposes.  It is still borrowed storage the caller never
/// releases; copy it with `Tm.zoneNameOwned` to give it an owner.
/// `error.ConversionFailed` means upstream returned a null result.
pub fn toUtcTm(timestamp: i64) Error!Tm {
    const seconds: c.time_t = @intCast(timestamp);
    var raw: c.struct_tm = undefined;
    const result = c.tz_gmtime_r(&seconds, &raw);
    if (pointerIsNull(result)) return error.ConversionFailed;
    return Tm.fromC(result);
}

/// The process-global POSIX zone state upstream publishes as `tz_tzname`,
/// `tz_timezone` and `tz_daylight` (`localtime.c:623-629`).
///
/// These are the only exported *objects* in the whole surface: everything else
/// here is a function. Upstream fills them from the ambient zone - whatever
/// `TZ` names, or the platform's own default - inside `settzname`
/// (`localtime.c:735-768`), and `tz_localtime`, `tz_mktime` and `tz_tzset`
/// refresh them as they go. A `Zone` never touches them: `tz_localtime_rz`
/// and `tz_mktime_z` work on the handle they were given and pass `setname` as
/// false (`localtime.c:2891`), so the reentrant API above is independent of
/// the environment and of this namespace.
///
/// Nothing here is ever copied out of the library. In a linked build the values
/// are read from the linked objects; in a runtime-loaded build they are read
/// through the address the loader resolved, which is the provider's own
/// storage. A caller therefore observes a write tzcode made to its globals,
/// not a value this module snapshotted at `load` time.
///
/// ## Lifetime and the reentrant API
///
/// The zone abbreviation `abbreviation` returns is `char *` storage inside the
/// library (`localtime.c:705` stores `&sp->chars[...]`), which lives for the
/// life of the process and is invalidated by nothing this module does. It is
/// borrowed: copy it with `Tm.zoneNameOwned`, or with your own allocator, to
/// keep it.
///
/// ## What a zone handle has nothing to do with
///
/// A handle from `Zone.open` belongs to the library that produced it, and only
/// `Zone.close` releases it. Nothing in this namespace releases or replaces
/// one, and no handle is ever taken from the ambient state: use `Zone.open` for
/// anything whose zone is named.
pub const Ambient = struct {
    /// Read upstream's `TZ` (or the platform's default) and refresh the three
    /// globals below from it.
    ///
    /// This is `tz_tzset`. It is the only call in this module whose result
    /// depends on the environment, which is why nothing else here calls it for
    /// you: `tz_localtime`, `tz_mktime` and `tz_timelocal` refresh the same
    /// state on their own.
    pub fn tzset() void {
        c.tz_tzset();
    }

    /// True where this target's build emits `tz_tzname` at all.
    ///
    /// Upstream emits it only where `2 <= HAVE_TZNAME + TZ_TIME_T`
    /// (`localtime.c:623-625`), and this build pins `HAVE_TZNAME` to 0 on
    /// mingw-w64 and on every unknown OS, where the aggregate header declares
    /// nothing either.  A caller that wants a compile-time branch rather than
    /// a null result asks this.
    pub const tzname_emitted = has_tzname_object;

    /// True where this target's build emits `tz_timezone` and `tz_daylight`.
    ///
    /// Both are selected by `USG_COMPAT` (`localtime.c:626-629`) and always
    /// together, so one flag covers them.
    pub const usg_compat_emitted = has_timezone_object and has_daylight_object;

    /// `tz_tzname[index]`, or null where this target's build emits no
    /// `tz_tzname` at all.
    ///
    /// Index 0 is the zone's standard-time abbreviation and index 1 its
    /// daylight-saving one, whenever the ambient zone has both; upstream
    /// publishes them from `update_tzname_etc` (`localtime.c:704-706`). Before
    /// anything has refreshed them, both are `WILDABBR`
    /// (`localtime.c:406, 624`) - three spaces - so a caller that wants a
    /// meaningful value calls `tzset` first.
    ///
    /// A null element means the library published no abbreviation for that
    /// slot, which upstream does deliberately: a zone with no daylight saving
    /// time never fills index 1, and one with no standard time never fills
    /// index 0.
    pub fn abbreviation(index: usize) ?[:0]const u8 {
        if (comptime !has_tzname_object) return null;
        const slot = tzname_address();
        if (index >= slot.len) return null;
        const text = slot[index];
        if (pointerIsNull(text)) return null;
        return text[0..std.mem.len(text) :0];
    }

    /// `tz_timezone`: the ambient zone's standard-time offset, in seconds
    /// **west** of UTC. Null where this target's build emits no `tz_timezone`.
    ///
    /// The sign is the one upstream documents for the C library's `timezone`
    /// and is the opposite of every other offset in this module: upstream
    /// writes `timezone = -ttisp->tt_utoff` (`localtime.c:709`), while a `Tm`
    /// carries `gmtoff` east of UTC. Europe/Berlin in January is `-3600` here
    /// and `+3600` in `Tm.gmtoff`.
    ///
    /// It is the *standard* offset even in summer, so it does not change with
    /// the season; `Zone.utcOffset` is the one that does.
    pub fn standardOffsetSeconds() ?i64 {
        if (comptime !has_timezone_object) return null;
        return @intCast(timezone_address().*);
    }

    /// `tz_daylight`: non-zero when the ambient zone uses daylight saving
    /// time at all. Null where this target's build emits no `tz_daylight`.
    ///
    /// It answers a property of the *zone*, not of the current instant:
    /// upstream computes it from whether a daylight rule type was found at
    /// all (`localtime.c:767`). A conversion is what decides which of the two
    /// types is in force - see `Tm.isdst`.
    pub fn daylightSavingEverUsed() ?bool {
        if (comptime !has_daylight_object) return null;
        return daylight_address().* != 0;
    }
};

/// True where this target's build emits `tz_tzname` at all.
///
/// Upstream emits it only where `2 <= HAVE_TZNAME + TZ_TIME_T`
/// (`localtime.c:623-625`), and this build pins `HAVE_TZNAME` to 0 on mingw-w64
/// and on every unknown OS, where the aggregate header declares nothing either.
/// The generated dispatch renames a routed object to `NAMEAddr`, so the name
/// to ask about differs between the two configurations.
const has_tzname_object: bool = @hasDecl(c, "tz_tznameAddr") or @hasDecl(c, "tz_tzname");
const has_timezone_object: bool = @hasDecl(c, "tz_timezoneAddr") or @hasDecl(c, "tz_timezone");
const has_daylight_object: bool = @hasDecl(c, "tz_daylightAddr") or @hasDecl(c, "tz_daylight");

/// The provider's own `tz_tzname` object, read through its address.
///
/// A linked build takes the address of the linked variable; a runtime-loaded
/// build asks the dispatch for the address it resolved at `load`. Neither
/// copies the object.
fn tzname_address() *const [2][*c]u8 {
    if (comptime runtime_loaded) return c.tz_tznameAddr();
    return &c.tz_tzname;
}

fn timezone_address() *const c_long {
    if (comptime runtime_loaded) return c.tz_timezoneAddr();
    return &c.tz_timezone;
}

fn daylight_address() *const c_int {
    if (comptime runtime_loaded) return c.tz_daylightAddr();
    return &c.tz_daylight;
}

/// Longest result `formatAlloc` renders before reporting `FormatTooLong`.
const max_format_bytes = 64 * 1024;

/// Format `value` with upstream `strftime`, allocating the result.
///
/// The result is a plain `[]u8` allocated from `gpa` - not sentinel
/// terminated - and is released with `gpa.free`.  Nothing in it borrows from
/// `value`, which is taken by value, so the caller may close the zone first.
///
/// `strftime` signals failure by returning 0, which is also the length of a
/// valid empty result - an empty format string renders nothing - so the
/// wrapper reads the out-of-band signal upstream documents: `strftime` sets
/// `ERANGE` when the result did not fit and restores the caller's `errno`
/// when it succeeded (strftime.c:206-212).  A result that does not fit 64 KiB
/// is `error.FormatTooLong`, which frees the buffer it tried in;
/// `error.OutOfMemory` is the only other failure and leaves nothing behind
/// either.
///
/// `%Z` and `%z` do not name the zone a value was converted in on a target
/// whose `struct tm` carries neither `tm_zone` nor `tm_gmtoff`
/// (MS-Windows): there neither field has anything to read, so `%Z` renders
/// the empty string because `HAVE_TZNAME` is also 0 (strftime.c:560-567) and
/// `%z` renders nothing at all, because `USG_COMPAT` and `ALTZONE` are off
/// too (strftime.c:575-641).  `Zone.utcOffset` is correct on every target;
/// `Tm.zone` answers wherever the target's `struct tm` carries `tm_zone`, and
/// its `null` there means the target cannot name the zone, not that the zone
/// is UTC.
///
/// On a target that does carry `tm_zone`, a format containing `%Z` requires
/// `value.zone` to be non-null: upstream reads that pointer directly
/// (`strftime.c:562`), and `Tm.toC` turns a null `zone` into a null field.
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
