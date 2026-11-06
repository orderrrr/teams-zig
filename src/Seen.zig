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

/// The most chats `marks` holds; space for them is reserved up front.
pub const chat_count_limit = 1024;

/// Records where every chat in the first poll stands, so nothing older is shown.
pub fn init(
    gpa: std.mem.Allocator,
    conversations: []const chat.Conversation,
) error{OutOfMemory}!Seen {
    var seen: Seen = .{ .gpa = gpa, .marks = .empty, .mark_first = 0 };
    errdefer seen.deinit();
    try seen.marks.ensureTotalCapacity(gpa, chat_count_limit);

    // Each chat's own mark first: while `mark_first` is still zero, `record` keeps ids as they are.
    for (conversations) |*conversation| {
        const last_message_id = conversation.last_message_id orelse continue;
        try seen.record(conversation.id, last_message_id);
    }
    for (conversations) |*conversation| {
        const last_message_id = conversation.last_message_id orelse continue;
        seen.mark_first = @max(seen.mark_first, last_message_id);
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

/// Moves a chat's mark forward to `message_id`; never back. When `chat_count_limit` chats are
/// marked, the marks are folded into `mark_first` (the newest of them) to make room: nothing
/// already shown comes back, at the cost of skipping older unshown messages in unread chats.
pub fn record(
    seen: *Seen,
    conversation_id: []const u8,
    message_id: u64,
) error{OutOfMemory}!void {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(seen.marks.count() <= chat_count_limit);
    if (seen.marks.count() == chat_count_limit and !seen.marks.contains(conversation_id)) {
        seen.fold();
    }
    const entry = seen.marks.getOrPutAssumeCapacity(conversation_id);
    if (entry.found_existing) {
        entry.value_ptr.* = @max(entry.value_ptr.*, message_id);
        return;
    }
    errdefer seen.marks.removeByPtr(entry.key_ptr);
    entry.key_ptr.* = try seen.gpa.dupe(u8, conversation_id);
    // Its mark was `mark_first` until now.
    entry.value_ptr.* = @max(seen.mark_first, message_id);
}

/// Empties `marks`, raising `mark_first` to the newest mark so no chat goes back.
fn fold(seen: *Seen) void {
    var entries = seen.marks.iterator();
    while (entries.next()) |entry| {
        seen.mark_first = @max(seen.mark_first, entry.value_ptr.*);
        seen.gpa.free(entry.key_ptr.*);
    }
    seen.marks.clearRetainingCapacity();
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

test "record folds the marks when full, so nothing shown comes back" {
    var seen: Seen = try .init(std.testing.allocator, &.{});
    defer seen.deinit();

    var id_buffer: [32]u8 = undefined;
    for (0..chat_count_limit) |index| {
        const id = try std.fmt.bufPrint(&id_buffer, "19:fake-{d}@thread.v2", .{index});
        try seen.record(id, 1000 + index);
    }
    try std.testing.expectEqual(chat_count_limit, seen.marks.count());

    try seen.record("19:fake-new@thread.v2", 500);
    try std.testing.expectEqual(1, seen.marks.count());
    try std.testing.expectEqual(1000 + chat_count_limit - 1, seen.mark("19:fake-0@thread.v2"));
    try std.testing.expectEqual(1000 + chat_count_limit - 1, seen.mark("19:fake-new@thread.v2"));
}
