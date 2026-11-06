//! A chat, meeting chat, channel or self-chat, from `GET /users/ME/conversations`.

const Conversation = @This();

const std = @import("std");
const json = @import("json.zig");
const Owned = @import("Owned.zig").Owned;

id: []const u8,
kind: Kind,
/// Null for 1:1 chats, which have no topic.
topic: ?[]const u8,
/// ISO timestamp of the last message; null when the conversation has none.
last_message_at: ?[]const u8,

pub const Kind = enum { chat, meeting, space, topic, notes, other };

/// Conversations from one response. Every string lives in the arena.
pub const List = Owned(Conversation);

const Response = struct {
    conversations: []const struct {
        id: []const u8,
        threadProperties: ?ThreadProperties = null,
        properties: ?Properties = null,
    },

    const Properties = struct { lastimreceivedtime: ?[]const u8 = null };

    const ThreadProperties = struct {
        threadType: ?[]const u8 = null,
        topic: ?[]const u8 = null,
    };
};

/// Parses a conversations response, leaving out system streams (notifications, mentions, ...).
/// The result is owned by the caller: free it with `List.deinit`.
pub fn parseList(gpa: std.mem.Allocator, body: []const u8) json.ParseError!List {
    var list: List = try .init(gpa);
    errdefer list.deinit();

    const arena = list.arena.allocator();
    const response = try std.json.parseFromSliceLeaky(Response, arena, body, json.parse_options);
    var items: std.ArrayList(Conversation) = try .initCapacity(arena, response.conversations.len);
    for (response.conversations) |raw| {
        const thread: Response.ThreadProperties = raw.threadProperties orelse .{};
        // A conversation without a thread type isn't a system stream, so it's kept as `.other`.
        const kind: Kind = if (thread.threadType) |thread_type|
            kindOf(thread_type) orelse continue
        else
            .other;
        const properties: Response.Properties = raw.properties orelse .{};
        items.appendAssumeCapacity(.{
            .id = raw.id,
            .kind = kind,
            .topic = thread.topic,
            .last_message_at = properties.lastimreceivedtime,
        });
    }
    std.debug.assert(items.items.len <= response.conversations.len);

    list.items = items.items;
    return list;
}

/// Null for system streams, which every `streamof*` type except the self-chat is.
fn kindOf(thread_type: []const u8) ?Kind {
    if (std.mem.eql(u8, thread_type, "streamofnotes")) return .notes;
    if (std.mem.startsWith(u8, thread_type, "streamof")) return null;

    return std.meta.stringToEnum(Kind, thread_type) orelse .other;
}

test "parseList keeps chats and the self-chat, and drops system streams" {
    const body =
        \\{"_metadata":{},"conversations":[
        \\  {"id":"19:fake-a_fake-b@unq.gbl.spaces","threadProperties":{"threadType":"chat"},
        \\   "properties":{"lastimreceivedtime":"2026-11-01T10:00:00.000Z"}},
        \\  {"id":"19:fake-meeting@thread.v2",
        \\   "threadProperties":{"threadType":"meeting","topic":"Fake standup"},
        \\   "properties":{"lastimreceivedtime":null}},
        \\  {"id":"48:notifications","threadProperties":{"threadType":"streamofnotifications"}},
        \\  {"id":"48:notes","threadProperties":{"threadType":"streamofnotes"}}
        \\]}
    ;
    const list = try parseList(std.testing.allocator, body);
    defer list.deinit();

    try std.testing.expectEqual(3, list.items.len);
    try std.testing.expectEqual(Kind.chat, list.items[0].kind);
    try std.testing.expectEqual(null, list.items[0].topic);
    try std.testing.expectEqualStrings("2026-11-01T10:00:00.000Z", list.items[0].last_message_at.?);
    try std.testing.expectEqual(Kind.meeting, list.items[1].kind);
    try std.testing.expectEqualStrings("Fake standup", list.items[1].topic.?);
    try std.testing.expectEqual(null, list.items[1].last_message_at);
    try std.testing.expectEqual(Kind.notes, list.items[2].kind);
}

test "kindOf maps unknown thread types to other" {
    try std.testing.expectEqual(Kind.other, kindOf("somethingnew").?);
    try std.testing.expectEqual(null, kindOf("streamofcalllogs"));
}

test "parseList keeps a conversation without a thread type as other" {
    const body =
        \\{"conversations":[{"id":"19:fake@thread.v2","threadProperties":{"topic":"Fake"}}]}
    ;
    const list = try parseList(std.testing.allocator, body);
    defer list.deinit();

    try std.testing.expectEqual(1, list.items.len);
    try std.testing.expectEqual(Kind.other, list.items[0].kind);
}

test "parseList fails on a conversation without an id" {
    const body = "{\"conversations\":[{\"threadProperties\":{\"threadType\":\"chat\"}}]}";
    try std.testing.expectError(error.MissingField, parseList(std.testing.allocator, body));
}
