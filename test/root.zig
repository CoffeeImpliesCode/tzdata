//! Test entry point for the tzdata package.

test {
    _ = @import("tzif.zig");
    _ = @import("conversion.zig");
    _ = @import("malformed.zig");
}
