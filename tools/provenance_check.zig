//! Licence and provenance integrity gate.
//!
//! Reads a `sha256sum`-style manifest and verifies that every listed upstream
//! file is byte-for-byte unchanged.  The fork only ever adds files; a modified
//! upstream file means either an accidental edit or a divergence that is not
//! recorded in CHANGELOG.md.
//!
//! It then verifies the README relocation: upstream's `README` is preserved
//! under a different name, so the copy and the original must stay identical.
//! That is the one upstream file a fork file would otherwise shadow, and the
//! manifest cannot express it - the manifest records `README`, not the
//! preserved copy.
//!
//! Usage: tzdata-provenance <manifest> <root-directory>

const std = @import("std");

const read_limit: std.Io.Limit = .limited(16 << 20);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 3) return error.Usage;

    const manifest = try std.Io.Dir.cwd().readFileAlloc(io, args[1], arena, read_limit);
    const root = args[2];

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var checked: usize = 0;
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const separator = std.mem.indexOf(u8, line, "  ") orelse return error.MalformedManifest;
        const expected = line[0..separator];
        const name = std.mem.trim(u8, line[separator..], " \t\r");
        const path = std.fs.path.join(arena, &.{ root, name }) catch return error.OutOfMemory;

        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, read_limit) catch |err| {
            try stdout.print("provenance: cannot read {s}: {t}\n", .{ name, err });
            return error.ProvenanceMismatch;
        };
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        var actual: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 = undefined;
        _ = std.fmt.bufPrint(&actual, "{x}", .{&digest}) catch unreachable;
        if (!std.ascii.eqlIgnoreCase(expected, &actual)) {
            try stdout.print("provenance: {s} differs from the recorded hash\n  expected {s}\n  actual   {s}\n", .{
                name, expected, &actual,
            });
            return error.ProvenanceMismatch;
        }
        checked += 1;
    }

    // The README relocation: upstream's `README` is preserved as
    // `README.upstream.md`, and the fork's own `README.md` is a separate
    // file.  The manifest above proves the original is unchanged; this proves
    // the copy is still the same bytes.
    const original = std.fs.path.join(arena, &.{ root, "README" }) catch return error.OutOfMemory;
    const preserved = std.fs.path.join(arena, &.{ root, "README.upstream.md" }) catch return error.OutOfMemory;
    const original_bytes = std.Io.Dir.cwd().readFileAlloc(io, original, arena, read_limit) catch |err| {
        try stdout.print("provenance: cannot read {s}: {t}\n", .{ original, err });
        return error.ProvenanceMismatch;
    };
    const preserved_bytes = std.Io.Dir.cwd().readFileAlloc(io, preserved, arena, read_limit) catch |err| {
        try stdout.print("provenance: cannot read {s}: {t}\n", .{ preserved, err });
        return error.ProvenanceMismatch;
    };
    if (!std.mem.eql(u8, original_bytes, preserved_bytes)) {
        try stdout.print("provenance: {s} is not the preserved copy of {s}\n", .{ preserved, original });
        return error.ProvenanceMismatch;
    }

    try stdout.print("provenance ok: {d} upstream files unchanged, {s} matches {s}\n", .{ checked, preserved, original });
}
