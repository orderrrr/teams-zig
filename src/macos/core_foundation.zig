//! The slice of CoreFoundation the keychain and local times need, with Zig-shaped helpers on top.
//! Every value a `create` or `copy` method returns is owned by the caller: pass it to `release`.

const std = @import("std");

/// CFIndex, a C `long`: platform-sized on purpose, to match the C ABI.
pub const Index = isize;
pub const Allocator = opaque {};
pub const Boolean = opaque {};

pub const String = opaque {
    pub fn create(contents: []const u8) error{OutOfMemory}!*const String {
        std.debug.assert(contents.len <= std.math.maxInt(Index));
        const string = CFStringCreateWithBytes(
            null, // the default allocator
            contents.ptr,
            @intCast(contents.len),
            string_encoding_utf8,
            0, // not an external representation: no byte-order mark
        );
        return string orelse error.OutOfMemory;
    }
};

pub const Data = opaque {
    pub fn create(contents: []const u8) error{OutOfMemory}!*const Data {
        std.debug.assert(contents.len <= std.math.maxInt(Index));
        const data = CFDataCreate(
            null, // the default allocator
            contents.ptr,
            @intCast(contents.len),
        );
        return data orelse error.OutOfMemory;
    }

    /// Borrows the bytes: they live as long as `data` does.
    pub fn bytes(data: *const Data) []const u8 {
        const length = CFDataGetLength(data);
        std.debug.assert(length >= 0);
        if (length == 0) return &.{};

        // Apple only promises a non-null pointer when there are bytes to point at.
        const pointer = CFDataGetBytePtr(data);
        std.debug.assert(pointer != null);
        return pointer.?[0..@intCast(length)];
    }
};

pub const Dictionary = opaque {
    /// Keys and values side by side. A struct, so the two lists can't be swapped at a call site.
    pub const Entries = struct {
        /// Both lists are borrowed for the length of the `create` call.
        keys: []const *const anyopaque,
        values: []const *const anyopaque,
    };

    /// Keys and values must be CoreFoundation objects; the dictionary retains them.
    pub fn create(entries: Entries) error{OutOfMemory}!*const Dictionary {
        std.debug.assert(entries.keys.len > 0);
        std.debug.assert(entries.keys.len <= std.math.maxInt(Index));
        std.debug.assert(entries.keys.len == entries.values.len);
        return CFDictionaryCreate(
            null, // the default allocator
            entries.keys.ptr,
            entries.values.ptr,
            @intCast(entries.keys.len),
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        ) orelse error.OutOfMemory;
    }
};

pub const TimeZone = opaque {
    /// The time zone set in System Settings, as it was when first asked for in this process.
    pub fn copySystem() *const TimeZone {
        return CFTimeZoneCopySystem();
    }

    /// A zone always `seconds` ahead of GMT, with no daylight saving.
    pub fn createFixed(seconds: i32) error{OutOfMemory}!*const TimeZone {
        std.debug.assert(@abs(seconds) < std.time.s_per_day);
        return CFTimeZoneCreateWithTimeIntervalFromGMT(
            null, // the default allocator
            @floatFromInt(seconds),
        ) orelse error.OutOfMemory;
    }

    /// The zone's offset from GMT at `unix_seconds`, daylight saving included.
    pub fn secondsFromGmt(zone: *const TimeZone, unix_seconds: i64) i32 {
        const absolute: f64 = @floatFromInt(unix_seconds - absolute_time_unix_seconds);
        const offset = CFTimeZoneGetSecondsFromGMT(zone, absolute);
        // Real zones are within a day of GMT, in whole seconds.
        std.debug.assert(@abs(offset) < std.time.s_per_day);
        return @intFromFloat(offset);
    }
};

pub const DictionaryKeyCallBacks = extern struct {
    version: Index,
    retain: ?*const anyopaque,
    release: ?*const anyopaque,
    copy_description: ?*const anyopaque,
    equal: ?*const anyopaque,
    hash: ?*const anyopaque,
};

pub const DictionaryValueCallBacks = extern struct {
    version: Index,
    retain: ?*const anyopaque,
    release: ?*const anyopaque,
    copy_description: ?*const anyopaque,
    equal: ?*const anyopaque,
};

pub fn release(object: *const anyopaque) void {
    CFRelease(object);
}

const string_encoding_utf8: u32 = 0x08000100;

/// CoreFoundation counts time from 2001-01-01 GMT.
const absolute_time_unix_seconds = 978307200;

pub extern const kCFBooleanTrue: *const Boolean;
pub extern const kCFTypeDictionaryKeyCallBacks: DictionaryKeyCallBacks;
pub extern const kCFTypeDictionaryValueCallBacks: DictionaryValueCallBacks;

extern fn CFRelease(object: *const anyopaque) void;
extern fn CFStringCreateWithBytes(
    allocator: ?*const Allocator,
    bytes: [*]const u8,
    bytes_count: Index,
    encoding: u32,
    is_external_representation: u8,
) ?*const String;
extern fn CFDataCreate(
    allocator: ?*const Allocator,
    bytes: [*]const u8,
    length: Index,
) ?*const Data;
extern fn CFDataGetBytePtr(data: *const Data) ?[*]const u8;
extern fn CFDataGetLength(data: *const Data) Index;
extern fn CFTimeZoneCopySystem() *const TimeZone;
extern fn CFTimeZoneCreateWithTimeIntervalFromGMT(
    allocator: ?*const Allocator,
    seconds: f64,
) ?*const TimeZone;
extern fn CFTimeZoneGetSecondsFromGMT(zone: *const TimeZone, at: f64) f64;
extern fn CFDictionaryCreate(
    allocator: ?*const Allocator,
    keys: [*]const *const anyopaque,
    values: [*]const *const anyopaque,
    count: Index,
    key_callbacks: *const DictionaryKeyCallBacks,
    value_callbacks: *const DictionaryValueCallBacks,
) ?*const Dictionary;

test "data round-trips its bytes" {
    const data = try Data.create("fake-token-value");
    defer release(data);

    try std.testing.expectEqualStrings("fake-token-value", data.bytes());
}

test "dictionary holds string keys and data values" {
    const key = try String.create("account");
    defer release(key);

    const value = try Data.create("fake");
    defer release(value);

    const dictionary = try Dictionary.create(.{
        .keys = &.{key},
        .values = &.{value},
    });
    release(dictionary);
}

test "empty data has no bytes" {
    const data = try Data.create("");
    defer release(data);

    try std.testing.expectEqual(0, data.bytes().len);
}

test "the system time zone has an offset from GMT" {
    const zone = TimeZone.copySystem();
    defer release(zone);

    // Any real zone is within 14 hours of GMT.
    const offset = zone.secondsFromGmt(1_700_000_000);
    try std.testing.expect(@abs(offset) <= 14 * std.time.s_per_hour);
}

test "a fixed zone keeps its offset" {
    const zone = try TimeZone.createFixed(-5 * std.time.s_per_hour);
    defer release(zone);

    try std.testing.expectEqual(-5 * std.time.s_per_hour, zone.secondsFromGmt(1_700_000_000));
}
