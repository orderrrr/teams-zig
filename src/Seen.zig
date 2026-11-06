//! What `watch` has already shown: for each chat, the id of the newest message seen. Message
//! ids are arrival times in milliseconds, so a larger id is a newer message.

const Seen = @This();

const std = @import("std");
const chat = @import("teams").chat;

/// Owns the keys of `marks`.
gpa: std.mem.Allocator,
/// Conversation id to the newest message id seen there.
marks: std.StringHashMapUnmanaged(u64),
/// The mark for a chat not seen before: the newest message id at the first poll, so a chat that
/// appears later shows only what arrived after `watch` started, by the service's clock.
mark_first: u64,

/// Records where every chat in the first poll stands, so nothing older is shown.
pub fn init(
    gpa: std.mem.Allocator,
    conversations: []const chat.Conversation,
) error{OutOfMemory}!Seen {
    var seen: Seen = .{ .gpa = gpa, .marks = .empty, .mark_first = 0 };
    errdefer seen.deinit();

    for (conversations) |*conversation| {
        const last_message_id = conversation.last_message_id orelse continue;
        seen.mark_first = @max(seen.mark_first, last_message_id);
    }
    for (conversations) |*conversation| {
        const last_message_id = conversation.last_message_id orelse continue;
        try seen.record(conversation.id, last_message_id);
    }
    return seen;
}

pub fn deinit(seen: *Seen) void {
    var keys = seen.marks.keyIterator();
    while (keys.next()) |key| seen.gpa.free(key.*);
    seen.marks.deinit(seen.gpa);
    seen.* = undefined;
}

/// The newest message id already seen in a chat.
pub fn mark(seen: *const Seen, conversation_id: []const u8) u64 {
    return seen.marks.get(conversation_id) orelse seen.mark_first;
}

/// Whether a chat's last user-written message is newer than anything seen there.
pub fn changed(seen: *const Seen, conversation: *const chat.Conversation) bool {
    const last_message_id = conversation.last_message_id orelse return false;
    return last_message_id > seen.mark(conversation.id);
}

/// Moves a chat's mark forward to `message_id`; never back.
pub fn record(
    seen: *Seen,
    conversation_id: []const u8,
    message_id: u64,
) error{OutOfMemory}!void {
    std.debug.assert(conversation_id.len > 0);
    const entry = try seen.marks.getOrPut(seen.gpa, conversation_id);
    if (entry.found_existing) {
        entry.value_ptr.* = @max(entry.value_ptr.*, message_id);
        return;
    }
    errdefer seen.marks.removeByPtr(entry.key_ptr);
    entry.key_ptr.* = try seen.gpa.dupe(u8, conversation_id);
    entry.value_ptr.* = message_id;
}

fn fakeConversation(id: []const u8, last_message_id: ?u64) chat.Conversation {
    return .{
        .id = id,
        .kind = .chat,
        .topic = null,
        .last_message_at = null,
        .last_sender = null,
        .last_sender_name = null,
        .last_message_id = last_message_id,
        .read_up_to_id = null,
    };
}

test "changed sees moved chats and new chats, and ignores older or unchanged ones" {
    const first = [_]chat.Conversation{
        fakeConversation("19:fake-a@thread.v2", 2000),
        fakeConversation("19:fake-b@thread.v2", 3000),
        fakeConversation("19:fake-c@thread.v2", null),
    };
    var seen: Seen = try .init(std.testing.allocator, &first);
    defer seen.deinit();

    try std.testing.expect(!seen.changed(&first[0]));
    try std.testing.expect(!seen.changed(&first[1]));
    try std.testing.expect(!seen.changed(&first[2]));

    try std.testing.expect(seen.changed(&fakeConversation("19:fake-a@thread.v2", 2001)));
    // A chat first seen later starts from the newest message at the first poll.
    try std.testing.expect(!seen.changed(&fakeConversation("19:fake-new@thread.v2", 3000)));
    try std.testing.expect(seen.changed(&fakeConversation("19:fake-new@thread.v2", 3001)));
    try std.testing.expect(seen.changed(&fakeConversation("19:fake-c@thread.v2", 3001)));

    try seen.record("19:fake-a@thread.v2", 2500);
    try std.testing.expect(!seen.changed(&fakeConversation("19:fake-a@thread.v2", 2500)));
    try seen.record("19:fake-a@thread.v2", 1000);
    try std.testing.expectEqual(2500, seen.mark("19:fake-a@thread.v2"));
}

test "init with no messages anywhere starts from zero" {
    var seen: Seen = try .init(std.testing.allocator, &.{});
    defer seen.deinit();

    try std.testing.expectEqual(0, seen.mark("19:fake@thread.v2"));
}
