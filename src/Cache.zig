//! What teams-zig remembers between runs, to save requests: your user, the other person's name
//! in 1:1 chats, and chat names to chat ids. Text, one entry per line, tab-separated:
//! `self <mri> <name> <upn>`, `person <1:1 chat id> <name>`, `chat <name> <chat id>`. Chat names
//! are stored lower-cased (ASCII), since names match ignoring ASCII case. Holds no token.

const Cache = @This();

const std = @import("std");

/// Owns every string in the cache.
arena: std.heap.ArenaAllocator,
self_user: ?User = null,
/// 1:1 chat id to the other person's name.
persons: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
/// Lower-cased chat name to chat id.
chats: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

/// The most `person` entries kept; past it, new ones are dropped.
pub const person_count_max = 1024;
/// The most `chat` entries kept; past it, new ones are dropped.
pub const chat_count_max = 1024;
/// The largest cache file read; a larger one counts as empty.
pub const file_size_max = 256 * 1024;

comptime {
    // A full cache, at its longest lines, still has to fit the file a load reads.
    std.debug.assert(file_size_max >= 64 * 1024);
}

/// Your user, as `whoami` gives it. Borrowed from the cache.
pub const User = struct {
    mri: []const u8,
    name: []const u8,
    upn: []const u8,
};

pub fn init(gpa: std.mem.Allocator) Cache {
    return .{ .arena = .init(gpa) };
}

pub fn deinit(cache: *Cache) void {
    cache.arena.deinit();
    cache.* = undefined;
}

/// Loads `text`, a cache file. A line that doesn't parse, or text past `file_size_max`, leaves
/// the cache empty: a cache must never stop a command, and the next save rewrites it.
pub fn parse(cache: *Cache, text: []const u8) error{OutOfMemory}!void {
    std.debug.assert(cache.self_user == null);
    std.debug.assert(cache.persons.count() == 0);
    std.debug.assert(cache.chats.count() == 0);
    if (text.len > file_size_max) return;
    cache.parseLines(text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadLine => cache.clear(),
    };
}

fn parseLines(cache: *Cache, text: []const u8) error{ OutOfMemory, BadLine }!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const kind = fields.next() orelse return error.BadLine;
        const first = fields.next() orelse return error.BadLine;
        const second = fields.next() orelse return error.BadLine;
        if (std.mem.eql(u8, kind, "self")) {
            const third = fields.next() orelse return error.BadLine;
            if (fields.next() != null) return error.BadLine;
            try cache.putSelf(&.{ .mri = first, .name = second, .upn = third });
            continue;
        }
        if (fields.next() != null) return error.BadLine;
        if (std.mem.eql(u8, kind, "person")) {
            try cache.putPerson(first, second);
            continue;
        }
        if (std.mem.eql(u8, kind, "chat")) {
            try cache.putChat(first, second);
            continue;
        }
        return error.BadLine;
    }
}

/// Empties the cache, keeping its memory for reuse.
fn clear(cache: *Cache) void {
    cache.self_user = null;
    cache.persons.clearRetainingCapacity();
    cache.chats.clearRetainingCapacity();
}

/// Writes the cache in the form `parse` reads.
pub fn write(cache: *const Cache, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (cache.self_user) |user| {
        try writer.print("self\t{s}\t{s}\t{s}\n", .{ user.mri, user.name, user.upn });
    }
    for (cache.persons.keys(), cache.persons.values()) |id, name| {
        try writer.print("person\t{s}\t{s}\n", .{ id, name });
    }
    for (cache.chats.keys(), cache.chats.values()) |name, id| {
        try writer.print("chat\t{s}\t{s}\n", .{ name, id });
    }
}

/// Remembers your user. A field that can't be stored (see `storable`) leaves it unchanged.
pub fn putSelf(cache: *Cache, user: *const User) error{OutOfMemory}!void {
    if (!storable(user.mri) or !storable(user.name) or !storable(user.upn)) return;
    const arena = cache.arena.allocator();
    cache.self_user = .{
        .mri = try arena.dupe(u8, user.mri),
        .name = try arena.dupe(u8, user.name),
        .upn = try arena.dupe(u8, user.upn),
    };
}

/// Remembers the other person's name in the 1:1 chat `id`. Dropped past `person_count_max`, or
/// if either can't be stored.
pub fn putPerson(cache: *Cache, id: []const u8, name: []const u8) error{OutOfMemory}!void {
    try putEntry(&cache.persons, cache.arena.allocator(), person_count_max, id, name);
}

/// Remembers that `name` (any case) picks the chat `id`. Dropped past `chat_count_max`, or if
/// either can't be stored.
pub fn putChat(cache: *Cache, name: []const u8, id: []const u8) error{OutOfMemory}!void {
    const arena = cache.arena.allocator();
    const name_lower = try std.ascii.allocLowerString(arena, name);
    try putEntry(&cache.chats, arena, chat_count_max, name_lower, id);
}

/// Forgets `name` (any case), as when its chat id answers 404.
pub fn removeChat(cache: *Cache, name: []const u8) void {
    var name_buffer: [256]u8 = undefined;
    if (name.len > name_buffer.len) return;
    _ = cache.chats.orderedRemove(std.ascii.lowerString(&name_buffer, name));
}

/// The chat id `name` (any case) picks, if remembered. Borrowed from the cache.
pub fn chatId(cache: *const Cache, name: []const u8) ?[]const u8 {
    var name_buffer: [256]u8 = undefined;
    if (name.len > name_buffer.len) return null;
    return cache.chats.get(std.ascii.lowerString(&name_buffer, name));
}

/// The other person's name in the 1:1 chat `id`, if remembered. Borrowed from the cache.
pub fn personName(cache: *const Cache, id: []const u8) ?[]const u8 {
    return cache.persons.get(id);
}

fn putEntry(
    map: *std.StringArrayHashMapUnmanaged([]const u8),
    arena: std.mem.Allocator,
    count_max: u32,
    key: []const u8,
    value: []const u8,
) error{OutOfMemory}!void {
    if (!storable(key) or !storable(value)) return;
    if (map.getPtr(key)) |existing| {
        existing.* = try arena.dupe(u8, value);
        return;
    }
    if (map.count() >= count_max) return;
    try map.put(arena, try arena.dupe(u8, key), try arena.dupe(u8, value));
}

/// Whether `value` fits on a cache line: not empty, at most 256 bytes, and no tab, newline or
/// other control byte, which would break the line apart.
fn storable(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value.len > 256) return false;
    for (value) |byte| {
        if (std.ascii.isControl(byte)) return false;
    }
    return true;
}

test "a cache writes what it parses" {
    const text = "self\t8:orgid:fake-self\tFake Self\tfake@example.com\n" ++
        "person\t19:fake-a_fake-b@unq.gbl.spaces\tFake Other\n" ++
        "chat\tfake standup\t19:fake-group@thread.v2\n";
    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();
    try cache.parse(text);

    try std.testing.expectEqualStrings("8:orgid:fake-self", cache.self_user.?.mri);
    const person = cache.personName("19:fake-a_fake-b@unq.gbl.spaces");
    try std.testing.expectEqualStrings("Fake Other", person.?);
    try std.testing.expectEqualStrings("19:fake-group@thread.v2", cache.chatId("Fake STANDUP").?);
    try std.testing.expectEqual(null, cache.chatId("fake"));

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try cache.write(&out.writer);
    try std.testing.expectEqualStrings(text, out.written());
}

test "a bad line or an oversize file leaves the cache empty" {
    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();
    try cache.parse("chat\tfake\t19:fake\nfake\tline\n");
    try std.testing.expectEqual(0, cache.chats.count());

    var too_long: Cache = .init(std.testing.allocator);
    defer too_long.deinit();
    const long_text = try std.testing.allocator.alloc(u8, file_size_max + 1);
    defer std.testing.allocator.free(long_text);
    @memset(long_text, '\n');
    @memcpy(long_text[0..14], "chat\tfake\t19:x");
    try too_long.parse(long_text);
    try std.testing.expectEqual(0, too_long.chats.count());
}

test "values that would break a line, and entries past the limit, are not stored" {
    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();
    try cache.putChat("fake\tname", "19:fake");
    try cache.putChat("fake name", "19:fake\n");
    try cache.putChat("", "19:fake");
    try std.testing.expectEqual(0, cache.chats.count());

    for (0..chat_count_max + 1) |index| {
        var name_buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "fake {d}", .{index});
        try cache.putChat(name, "19:fake");
    }
    try std.testing.expectEqual(chat_count_max, cache.chats.count());

    try cache.putChat("FAKE 0", "19:fake-new");
    try std.testing.expectEqualStrings("19:fake-new", cache.chatId("fake 0").?);
    cache.removeChat("Fake 0");
    try std.testing.expectEqual(null, cache.chatId("fake 0"));
}
