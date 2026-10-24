//! Behavioural tests for the runtime-loading configuration.
//!
//! These are about what happens *around* the load rather than inside a single
//! conversion, which is why they are a separate root from the rest of `test/`:
//! there is one loader per process, it has no unload, and the first successful
//! load is a one-way door.  Any consumer with this lifecycle has the same
//! constraint, so it is part of what is under test rather than an inconvenience.
//!
//! ## Real providers, no substitutes
//!
//! `TZDATA_PROVIDER` names a libtz from this package's own build graph - which
//! under the default static linkage this package does not itself install, so
//! the caller supplies one or builds it with `-Dlinkage=dynamic` first.
//! Nothing here imitates tzcode, and the answers checked below come from the
//! calendar rather than from a recorded run of this library.
//!
//! Nothing is skipped when the variable is missing.  In a runtime-loading build
//! a test that cannot name a provider has nothing to say, and passing anyway
//! would mean nothing at all.
//!
//! ## Order is part of the contract
//!
//! Every test here calls `support.requireProvider` first, which performs the
//! explicit load.  That is idempotent for the same request, so the order the
//! runner uses does not change what any of them observes.

const std = @import("std");
const tzdata = @import("tzdata");
const support = @import("support.zig");

comptime {
    if (!tzdata.runtime_loaded) {
        @compileError(
            "test/runtime.zig is the runtime-loading test root. Build it with " ++
                "runtime loading configured; in a linked build there is no " ++
                "loader to test and `load` deliberately stops the program.",
        );
    }
}

/// No machine has this directory, which is what makes it a request that names
/// a different provider rather than a guess about what might be missing.
const other_provider = "/tzdata-no-such-provider/libtz.so";

test "conversions keep working through the provider that was loaded" {
    try support.requireProvider();

    // The empty zone name is upstream's UTC fast path, which reads no file and
    // no `TZ` (`localtime.c:1808-1819`), so this exercises the routed
    // `tz_tzalloc`/`tz_localtime_rz`/`tz_tzfree` triple without depending on
    // the provider's TZDIR being present at all - which matters, because the
    // database is a resource of the provider and not of the table.
    //
    // Sixty-four open/convert/release rounds matter because a handle is
    // allocated by the provider and must be released by the same one: a
    // release that went anywhere else would either double free or leave the
    // round unable to allocate.
    for (0..64) |_| {
        var zone = try tzdata.Zone.open("");
        defer zone.close();

        const converted = try zone.toLocal(0);
        try std.testing.expectEqual(@as(i32, 0), converted.isdst);
        try std.testing.expectEqualStrings("UTC", converted.zone.?);
        try std.testing.expectEqual(@as(i64, 0), try zone.utcOffset(0));
        try std.testing.expectEqual(@as(i64, 0), try zone.toUtc(converted));
    }
}

test "a different provider request is refused and the loaded provider stays in use" {
    try support.requireProvider();

    // The loader's answer here is `ProviderMismatch`, not `OpenFailed`, and the
    // difference is the whole point: the request cannot be honoured because a
    // provider has already been chosen, and that provider is not replaced by
    // the failure.
    try std.testing.expectError(
        error.ProviderMismatch,
        tzdata.load(.{ .path = other_provider }),
    );

    // Which is observable: the library that was already in use still converts.
    var zone = try tzdata.Zone.open("");
    defer zone.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    try std.testing.expectEqual(@as(i64, 0), try zone.utcOffset(1772953200));
    try std.testing.expectEqualStrings(
        "2026-03-08T07:00:00+00:00",
        try (try zone.toLocal(1772953200)).iso8601(gpa, try zone.utcOffset(1772953200)),
    );
}
