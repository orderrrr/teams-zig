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
/// Whether anything changed since `load`, so `save` has something to write.
changed: bool = false,

/// The most `person` entries kept; past it, new ones are dropped.
pub const person_count_max: u32 = 1024;
/// The most `chat` entries kept: a full listing (100 chats, `conversation_count_limit` in
/// commands.zig, asserted there) rewrites the map, so it never holds more.
pub const chat_count_max: u32 = 100;
/// The longest id, name or upn stored; a longer one isn't cached.
pub const value_size_max: u32 = 256;

/// The longest line of each kind: its word, its values at their longest, tabs and a newline.
const self_line_size_max: u32 = "self".len + 3 * (1 + value_size_max) + 1;
const person_line_size_max: u32 = "person".len + 2 * (1 + value_size_max) + 1;
const chat_line_size_max: u32 = "chat".len + 2 * (1 + value_size_max) + 1;

/// The largest cache file read; a larger one counts as empty. A full cache at its longest lines
/// is exactly this size, so a saved cache always loads (about 1 MiB).
pub const file_size_max: u32 = self_line_size_max + person_count_max * person_line_size_max +
    chat_count_max * chat_line_size_max;

comptime {
    std.debug.assert(self_line_size_max == 776);
    std.debug.assert(person_line_size_max == 521);
    std.debug.assert(chat_line_size_max == 519);
    std.debug.assert(file_size_max < 2 * 1024 * 1024);
}

/// Your user, as `whoami` gives it. Borrowed from the cache.
pub const User = struct {
    mri: []const u8,
    name: []const u8,
    upn: []const u8,

    fn storable(user: *const User) bool {
        return Cache.storable(user.mri) and Cache.storable(user.name) and
            Cache.storable(user.upn);
    }
};

/// Where the cache file lives, under your home directory. Only `scripts/teams-token.fish`
/// deletes it, at each new sign-in.
pub const sub_path = "Library/Caches/teams-zig/cache.txt";

/// Failures saving the cache. Callers go on without it: a cache must never stop a command.
pub const SaveError = std.Io.Dir.CreateFileAtomicError || std.Io.File.Atomic.ReplaceError ||
    error{WriteFailed};

/// Reads the cache file under `home`. A file that is missing, unreadable, too large or bad gives
/// an empty cache.
pub fn load(gpa: std.mem.Allocator, io: std.Io, home: std.Io.Dir) error{OutOfMemory}!Cache {
    var cache: Cache = .init(gpa);
    errdefer cache.deinit();
    const limit: std.Io.Limit = .limited(file_size_max + 1);
    const text = home.readFileAlloc(io, sub_path, gpa, limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return cache,
    };
    defer gpa.free(text);
    try cache.parse(text);
    return cache;
}

/// Writes the cache file under `home` in one step: a new file, readable only by you, renamed
/// over the old one. Two writers at once: the last one wins.
pub fn save(cache: *const Cache, io: std.Io, home: std.Io.Dir) SaveError!void {
    var atomic = try home.createFileAtomic(io, sub_path, .{
        .permissions = .fromMode(0o600),
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = atomic.file.writer(io, &buffer);
    try cache.write(&file_writer.interface);
    try file_writer.interface.flush();
    try atomic.replace(io);
}

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
    // What was just read is what the file holds.
    cache.changed = false;
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
            const user: User = .{ .mri = first, .name = second, .upn = third };
            if (!user.storable()) return error.BadLine;
            try cache.putSelf(&user);
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
        // A user that can't go on a line is kept for this run only.
        if (user.storable()) {
            try writer.print("self\t{s}\t{s}\t{s}\n", .{ user.mri, user.name, user.upn });
        }
    }
    for (cache.persons.keys(), cache.persons.values()) |id, name| {
        // `putEntry` stores only what `storable` passes.
        std.debug.assert(storable(id));
        std.debug.assert(storable(name));
        try writer.print("person\t{s}\t{s}\n", .{ id, name });
    }
    for (cache.chats.keys(), cache.chats.values()) |name, id| {
        std.debug.assert(storable(name));
        std.debug.assert(storable(id));
        try writer.print("chat\t{s}\t{s}\n", .{ name, id });
    }
}

/// Remembers your user. One that can't go on a line (see `storable`) is kept for this run, but
/// not written.
pub fn putSelf(cache: *Cache, user: *const User) error{OutOfMemory}!void {
    // A user who hasn't changed leaves the file as it is.
    if (cache.self_user) |known| {
        if (std.mem.eql(u8, known.mri, user.mri)) {
            if (std.mem.eql(u8, known.name, user.name)) {
                if (std.mem.eql(u8, known.upn, user.upn)) return;
            }
        }
    }
    const arena = cache.arena.allocator();
    cache.changed = true;
    cache.self_user = .{
        .mri = try arena.dupe(u8, user.mri),
        .name = try arena.dupe(u8, user.name),
        .upn = try arena.dupe(u8, user.upn),
    };
}

/// Remembers the other person's name in the 1:1 chat `id`. Dropped past `person_count_max`, or
/// if either can't be stored.
pub fn putPerson(cache: *Cache, id: []const u8, name: []const u8) error{OutOfMemory}!void {
    try cache.putEntry(&cache.persons, person_count_max, id, name);
}

/// Remembers that `name` (any case) picks the chat `id`. Dropped past `chat_count_max`, or if
/// either can't be stored.
pub fn putChat(cache: *Cache, name: []const u8, id: []const u8) error{OutOfMemory}!void {
    var name_buffer: [value_size_max]u8 = undefined;
    if (name.len > name_buffer.len) return;
    try cache.putEntry(&cache.chats, chat_count_max, std.ascii.lowerString(&name_buffer, name), id);
}

/// Forgets `name` (any case), as when its chat id answers 404.
pub fn removeChat(cache: *Cache, name: []const u8) void {
    var name_buffer: [value_size_max]u8 = undefined;
    if (name.len > name_buffer.len) return;
    if (cache.chats.orderedRemove(std.ascii.lowerString(&name_buffer, name))) cache.changed = true;
}

/// The chat id `name` (any case) picks, if remembered. Borrowed from the cache.
pub fn chatId(cache: *const Cache, name: []const u8) ?[]const u8 {
    var name_buffer: [value_size_max]u8 = undefined;
    if (name.len > name_buffer.len) return null;
    return cache.chats.get(std.ascii.lowerString(&name_buffer, name));
}

/// Forgets every chat name, before a full listing caches its names again, so a name that now
/// picks several chats, or none, is gone.
pub fn clearChats(cache: *Cache) void {
    if (cache.chats.count() == 0) return;
    cache.chats.clearRetainingCapacity();
    cache.changed = true;
}

/// The other person's name in the 1:1 chat `id`, if remembered. Borrowed from the cache.
pub fn personName(cache: *const Cache, id: []const u8) ?[]const u8 {
    return cache.persons.get(id);
}

fn putEntry(
    cache: *Cache,
    map: *std.StringArrayHashMapUnmanaged([]const u8),
    count_max: u32,
    key: []const u8,
    value: []const u8,
) error{OutOfMemory}!void {
    std.debug.assert(map.count() <= count_max);
    defer std.debug.assert(map.count() <= count_max);
    if (!storable(key)) return;
    if (!storable(value)) return;
    const arena = cache.arena.allocator();
    if (map.getPtr(key)) |existing| {
        if (std.mem.eql(u8, existing.*, value)) return;
        existing.* = try arena.dupe(u8, value);
        cache.changed = true;
        return;
    }
    // A full map drops new entries.
    if (map.count() == count_max) return;
    try map.put(arena, try arena.dupe(u8, key), try arena.dupe(u8, value));
    cache.changed = true;
}

/// Whether `value` fits on a cache line: not empty, at most `value_size_max` bytes, and no tab,
/// newline or other control byte, which would break the line apart.
fn storable(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value.len > value_size_max) return false;
    for (value) |byte| {
        if (std.ascii.isControl(byte)) return false;
    }
    return true;
}

/// Options for the tests' temporary directories, spelled out.
const tmp_options: std.Io.Dir.OpenOptions = .{
    .access_sub_paths = true,
    .iterate = false,
    .follow_symlinks = true,
};

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

test "load gives an empty cache when the file is missing or too large" {
    var tmp = std.testing.tmpDir(tmp_options);
    defer tmp.cleanup();

    var missing = try load(std.testing.allocator, std.testing.io, tmp.dir);
    defer missing.deinit();
    try std.testing.expectEqual(null, missing.self_user);

    try tmp.dir.createDirPath(std.testing.io, "Library/Caches/teams-zig");
    const long_text = try std.testing.allocator.alloc(u8, file_size_max + 1);
    defer std.testing.allocator.free(long_text);
    @memset(long_text, '\n');
    @memcpy(long_text[0..14], "chat\tfake\t19:x");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = long_text });
    var too_large = try load(std.testing.allocator, std.testing.io, tmp.dir);
    defer too_large.deinit();
    try std.testing.expectEqual(0, too_large.chats.count());
}

test "save writes a file only you can read, and load reads it back" {
    var tmp = std.testing.tmpDir(tmp_options);
    defer tmp.cleanup();

    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();
    try cache.putChat("Fake Standup", "19:fake-group@thread.v2");
    try cache.save(std.testing.io, tmp.dir);

    const stat = try tmp.dir.statFile(std.testing.io, sub_path, .{ .follow_symlinks = true });
    try std.testing.expectEqual(0o600, stat.permissions.toMode() & 0o777);

    var loaded = try load(std.testing.allocator, std.testing.io, tmp.dir);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("19:fake-group@thread.v2", loaded.chatId("fake standup").?);
}

test "values up to value_size_max are stored, and one byte more is not" {
    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();
    const longest: [value_size_max]u8 = @splat('a');
    const too_long: [value_size_max + 1]u8 = @splat('b');

    try cache.putPerson(&longest, "Fake A");
    try cache.putPerson(&too_long, "Fake B");
    try cache.putChat(&longest, "19:fake-a");
    try cache.putChat(&too_long, "19:fake-b");
    try cache.putChat("fake", &too_long);
    try std.testing.expectEqualStrings("Fake A", cache.personName(&longest).?);
    try std.testing.expectEqual(null, cache.personName(&too_long));
    try std.testing.expectEqualStrings("19:fake-a", cache.chatId(&longest).?);
    try std.testing.expectEqual(null, cache.chatId(&too_long));
    try std.testing.expectEqual(null, cache.chatId("fake"));
}

test "a full cache at its longest lines is file_size_max, and saves and loads whole" {
    var tmp = std.testing.tmpDir(tmp_options);
    defer tmp.cleanup();

    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();
    const longest: [value_size_max]u8 = @splat('v');
    try cache.putSelf(&.{ .mri = &longest, .name = &longest, .upn = &longest });
    for (0..person_count_max) |index| {
        // Each key is the longest value, made unique by its last bytes. The index is below
        // `person_count_max` (1024), at most 4 digits, so its 8 bytes always fit.
        var key: [value_size_max]u8 = longest;
        _ = std.fmt.bufPrint(key[value_size_max - 8 ..], "{d:0>8}", .{index}) catch unreachable;
        try cache.putPerson(&key, &longest);
        if (index < chat_count_max) try cache.putChat(&key, &longest);
    }
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try cache.write(&out.writer);
    try std.testing.expectEqual(file_size_max, out.written().len);

    try cache.save(std.testing.io, tmp.dir);
    var loaded = try load(std.testing.allocator, std.testing.io, tmp.dir);
    defer loaded.deinit();
    try std.testing.expectEqual(person_count_max, loaded.persons.count());
    try std.testing.expectEqual(chat_count_max, loaded.chats.count());
}

test "clearChats forgets every chat name" {
    var cache: Cache = .init(std.testing.allocator);
    defer cache.deinit();
    try cache.putChat("Fake Standup", "19:fake-group");
    cache.changed = false;
    cache.clearChats();
    try std.testing.expectEqual(null, cache.chatId("fake standup"));
    try std.testing.expect(cache.changed);
}
