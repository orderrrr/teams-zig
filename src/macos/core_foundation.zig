//! The slice of CoreFoundation the keychain needs, with Zig-shaped helpers on top.
//! Every value a `create` method returns is owned by the caller: pass it to `release`.

const std = @import("std");

pub const Index = isize;
pub const Allocator = opaque {};
pub const String = opaque {
    pub fn create(contents: []const u8) error{OutOfMemory}!*const String {
        std.debug.assert(contents.len <= std.math.maxInt(Index));
        const string = CFStringCreateWithBytes(
            null,
            contents.ptr,
            @intCast(contents.len),
            string_encoding_utf8,
            0,
        );
        return string orelse error.OutOfMemory;
    }
};

pub const Data = opaque {
    pub fn create(contents: []const u8) error{OutOfMemory}!*const Data {
        std.debug.assert(contents.len <= std.math.maxInt(Index));
        return CFDataCreate(null, contents.ptr, @intCast(contents.len)) orelse error.OutOfMemory;
    }

    /// Borrows the bytes: they live as long as `data` does.
    pub fn bytes(data: *const Data) []const u8 {
        const length = CFDataGetLength(data);
        std.debug.assert(length >= 0);
        return CFDataGetBytePtr(data)[0..@intCast(length)];
    }
};

pub const Dictionary = opaque {
    /// Keys and values side by side. A struct, so the two lists can't be swapped at a call site.
    pub const Entries = struct {
        keys: []const *const anyopaque,
        values: []const *const anyopaque,
    };

    /// Keys and values must be CoreFoundation objects; the dictionary retains them.
    pub fn create(entries: Entries) error{OutOfMemory}!*const Dictionary {
        std.debug.assert(entries.keys.len > 0);
        std.debug.assert(entries.keys.len == entries.values.len);
        return CFDictionaryCreate(
            null,
            entries.keys.ptr,
            entries.values.ptr,
            @intCast(entries.keys.len),
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        ) orelse error.OutOfMemory;
    }
};
pub const Boolean = opaque {};

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

const string_encoding_utf8: u32 = 0x08000100;

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
extern fn CFDataGetBytePtr(data: *const Data) [*]const u8;
extern fn CFDataGetLength(data: *const Data) Index;
extern fn CFDictionaryCreate(
    allocator: ?*const Allocator,
    keys: [*]const *const anyopaque,
    values: [*]const *const anyopaque,
    count: Index,
    key_callbacks: *const DictionaryKeyCallBacks,
    value_callbacks: *const DictionaryValueCallBacks,
) ?*const Dictionary;

pub fn release(object: *const anyopaque) void {
    CFRelease(object);
}

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
