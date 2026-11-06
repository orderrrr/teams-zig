//! The slice of CoreFoundation the keychain needs, with Zig-shaped helpers on top.
//! Every value a `create*` function returns is owned by the caller: pass it to `release`.

const std = @import("std");

pub const Index = isize;
pub const Allocator = opaque {};
pub const String = opaque {};
pub const Data = opaque {};
pub const Dictionary = opaque {};
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

pub fn createString(bytes: []const u8) error{OutOfMemory}!*const String {
    std.debug.assert(bytes.len <= std.math.maxInt(Index));
    const string = CFStringCreateWithBytes(
        null,
        bytes.ptr,
        @intCast(bytes.len),
        string_encoding_utf8,
        0,
    );
    return string orelse error.OutOfMemory;
}

pub fn createData(bytes: []const u8) error{OutOfMemory}!*const Data {
    std.debug.assert(bytes.len <= std.math.maxInt(Index));
    return CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse error.OutOfMemory;
}

/// Borrows the bytes: they live as long as `data` does.
pub fn dataBytes(data: *const Data) []const u8 {
    const length = CFDataGetLength(data);
    std.debug.assert(length >= 0);
    return CFDataGetBytePtr(data)[0..@intCast(length)];
}

/// Keys and values must be CoreFoundation objects; the dictionary retains them.
pub fn createDictionary(
    keys: []const *const anyopaque,
    values: []const *const anyopaque,
) error{OutOfMemory}!*const Dictionary {
    std.debug.assert(keys.len > 0);
    std.debug.assert(keys.len == values.len);
    return CFDictionaryCreate(
        null,
        keys.ptr,
        values.ptr,
        @intCast(keys.len),
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks,
    ) orelse error.OutOfMemory;
}

test "data round-trips its bytes" {
    const data = try createData("fake-token-value");
    defer release(data);
    try std.testing.expectEqualStrings("fake-token-value", dataBytes(data));
}

test "dictionary holds string keys and data values" {
    const key = try createString("account");
    defer release(key);
    const value = try createData("fake");
    defer release(value);
    const dictionary = try createDictionary(&.{key}, &.{value});
    release(dictionary);
}
