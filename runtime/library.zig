//! tzdata's runtime-loader binding: namespaced synchronization and provider validation.
//! Providers must match the translated header, target ABI, and build configuration.

const rt = @import("rt");
const std = @import("std");

/// Namespaced synchronization functions used by the generic loader.
/// The symbol prefix must match the C build definition in `runtime/graph.zig`.
pub const Sync = struct {
    extern fn tzdata_rt_lock() void;
    extern fn tzdata_rt_unlock() void;
    extern fn tzdata_rt_wait() void;
    extern fn tzdata_rt_broadcast() void;
    // C `unsigned long long` is 64 bits on supported targets.
    extern fn tzdata_rt_thread_self() u64;

    pub fn lock() void {
        tzdata_rt_lock();
    }
    pub fn unlock() void {
        tzdata_rt_unlock();
    }
    pub fn wait() void {
        tzdata_rt_wait();
    }
    pub fn broadcast() void {
        tzdata_rt_broadcast();
    }
    pub fn threadSelf() u64 {
        return tzdata_rt_thread_self();
    }
};

/// Configure the generic loader for the generated dispatch.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Name used in pre-load panics.
        pub const library_name = "tzdata";

        /// The generated dispatch table.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// Namespaced lock and wait functions.
        pub const sync = Sync;

        pub fn tablePtr() *table {
            return dispatch.tablePtr();
        }

        pub fn ready() *rt.Ready {
            return &dispatch.ready;
        }

        pub fn assign(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assign(index, dst, address);
        }

        /// Store an optional symbol address or clear its table field.
        pub inline fn assignOptional(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assignOptional(index, dst, address);
        }

        pub inline fn assignMissing(comptime index: usize, dst: *table) void {
            dispatch.assignMissing(index, dst);
        }

        /// Validate provider ownership and ABI after all symbols resolve.
        /// An empty zone checks allocation, conversion, and release without `TZDIR`.
        pub fn validate(dst: *const table) ?[]const u8 {
            const handle = dst.tz_tzalloc("") orelse
                return "tz_tzalloc(\"\") answered NULL, so this provider cannot " ++
                    "create a zone state at all, and every reentrant conversion " ++
                    "in this API depends on that";
            defer dst.tz_tzfree(handle);

            const epoch: dispatch.time_t = 0;
            var raw: dispatch.struct_tm = std.mem.zeroes(dispatch.struct_tm);
            if (dst.tz_localtime_rz(handle, &epoch, &raw) == null) {
                return "tz_localtime_rz() answered NULL on the empty-name UTC " ++
                    "path, so this provider cannot convert a timestamp";
            }
            if (raw.tm_year != 70 or raw.tm_mon != 0 or raw.tm_mday != 1 or
                raw.tm_hour != 0 or raw.tm_min != 0 or raw.tm_sec != 0 or
                raw.tm_isdst != 0)
            {
                return "tz_localtime_rz() did not answer 1970-01-01T00:00:00 " ++
                    "with tm_isdst 0 on the empty-name UTC path, so this " ++
                    "provider's struct tm layout or time_t width is not the one " ++
                    "these declarations describe";
            }
            // The target `struct tm` may omit `tm_gmtoff`.
            if (comptime @hasField(dispatch.struct_tm, "tm_gmtoff")) {
                if (raw.tm_gmtoff != 0) {
                    return "tz_localtime_rz() reported a UTC offset other than " ++
                        "zero on the empty-name UTC path, so this provider's " ++
                        "struct tm layout is not the one these declarations " ++
                        "describe";
                }
            }
            return null;
        }
    };
}
