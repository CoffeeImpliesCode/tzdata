# Zig facade API

See `README.md` for dependency wiring, build options, and supported targets.

## Example

```zig
const tzdata = @import("tzdata");

pub fn example() !void {
    var zone = try tzdata.Zone.open("Europe/Berlin");
    defer zone.close();

    const instant = 1782043200;
    const local = try zone.toLocal(instant);
    if (try zone.toUtc(local) != instant) return error.UnexpectedInstant;
}
```

## `Zone`

- `Zone.open(name)` creates an owning reentrant handle. A failed `tz_tzalloc` returns `InvalidZone`. The empty name selects zero-offset UTC; it does not read the ambient `TZ` setting.
- `zone.close()` releases the native handle. It is idempotent on one value; do not copy a `Zone` and close both copies.
- `zone.toLocal(timestamp)` returns a `Tm` whose `zone` field borrows from that handle. Do not use the borrow after `close`.
- `zone.toUtc(tm)` converts a local `Tm` to an instant and returns `ConversionFailed` when the year is outside the C representation.
- `zone.utcOffset(timestamp)` returns the offset for that zone and instant.

## `Tm` and other functions

- `Tm.fromC` and `Tm.toC` convert the C `struct tm` representation.
- `tm.utcOffset()` returns null when the target has no `tm_gmtoff` field.
- `tm.zoneNameOwned(allocator)` returns an optional sentinel-terminated allocation. The caller owns it and releases it with that allocator.
- `tm.iso8601(allocator, offset)` returns an allocated plain `[]u8`, owned by the caller.
- `toUtcTm(tm)` is the `gmtime_r` equivalent. Its `zone` field points to tzcode's process-wide UTC storage, not to a `Zone` handle.
- `formatAlloc(allocator, format, tm)` formats with `strftime` and returns an allocated `[]u8` for the caller to free.
- `version()` and `packageName()` return borrowed strings in static library storage.
- `pointerIsNull` normalizes the nullability shape of a raw translated C pointer.
- `Error` contains `InvalidZone`, `ConversionFailed`, and `FormatTooLong`; each operation returns only the errors it can produce.

## Runtime-loaded configuration

Call `load` before other facade operations:

```zig
try tzdata.load(.{ .path = "/absolute/path/libtz.so" });
// Or use an explicit platform library name:
try tzdata.load(.{ .system = "libtz.so" });
```

Paths must be absolute; system names cannot contain path separators. The loader does not fall back between these forms. A routed call before a successful load panics. Repeating the successful request is idempotent; another request returns `ProviderMismatch`. Failed loads publish nothing and can be retried explicitly. `loadedSource()` returns the successful request or null before loading. The provider remains loaded for the process lifetime.

`LoadSource` names a path or system library. `LoadError` includes invalid or oversized requests, unsupported targets, open failures, missing symbols, validation failures, provider mismatches, and reentrant loads.

## Raw C declarations

`tzdata.c` exposes the translated upstream C declarations for cases the typed facade does not cover. It retains the C ABI and its ownership and error rules.
