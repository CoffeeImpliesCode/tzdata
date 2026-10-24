//! Test entry point for the tzdata package.
//!
//! `conversion.zig`, `tzif.zig` and `malformed.zig` are behavioural and run in
//! both configurations: each begins with `support.requireProvider`, which does
//! nothing in the ordinary linked build and is the explicit provider load in a
//! runtime-loaded one.
//!
//! `runtime.zig` is the exception.  It is about what happens *between* loads -
//! a provider that has already been chosen staying chosen - which has no
//! meaning at all when there is no loader, and it says so with a `@compileError`
//! rather than being silently skipped.  The `comptime` test below is what keeps
//! that from being a linked-build compile error.

const tzdata = @import("tzdata");

test {
    _ = @import("tzif.zig");
    _ = @import("conversion.zig");
    _ = @import("malformed.zig");
    if (comptime tzdata.runtime_loaded) {
        _ = @import("runtime.zig");
    }
}
