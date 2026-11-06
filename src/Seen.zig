//! What `watch` has already shown: for each chat, the id of the newest message seen. Message
//! ids are arrival times in milliseconds, so a larger id is a newer message.

const Seen = @This();

const std = @import("std");
const chat = @import("teams").chat;

gpa: std.mem.Allocator,
/// Conversation id to the newest message id seen there. The keys live in `id_bytes`.
marks: std.StringHashMapUnmanaged(u64) = .empty,
/// Room for `chat_count_limit` ids of up to `id_size_max` bytes, reserved up front.
id_bytes: []u8,
/// How much of `id_bytes` the keys of `marks` use.
id_bytes_used: u32 = 0,
/// The mark for a chat not in `marks`: the newest message id at the first poll, so a chat that
/// appears later shows only what arrived after `watch` started, by the service's clock. Raised
/// when `fold` empties `marks`.
mark_first: u64 = 0,

/// The most chats `marks` holds; space for them is reserved up front.
pub const chat_count_limit = 1024;

/// Far longer than any conversation id seen (about 90 bytes for a 1:1 chat).
const id_size_max = 256;

comptime {
    std.debug.assert(chat_count_limit * id_size_max <= std.math.maxInt(u32));
}

pub const Error = error{ OutOfMemory, ConversationIdTooLong };

/// Records where every chat in the first poll stands, so nothing older is shown.
pub fn init(gpa: std.mem.Allocator, conversations: []const chat.Conversation) Error!Seen {
    std.debug.assert(conversations.len <= chat_count_limit);
    const id_bytes = try gpa.alloc(u8, chat_count_limit * id_size_max);
    errdefer gpa.free(id_bytes);

    var seen: Seen = .{ .gpa = gpa, .id_bytes = id_bytes };
    errdefer seen.marks.deinit(gpa);
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
    seen.marks.deinit(seen.gpa);
    seen.gpa.free(seen.id_bytes);
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
/// Allocates nothing.
pub fn record(
    seen: *Seen,
    conversation_id: []const u8,
    message_id: u64,
) error{ConversationIdTooLong}!void {
    std.debug.assert(conversation_id.len > 0);
    std.debug.assert(seen.marks.count() <= chat_count_limit);
    if (seen.marks.getPtr(conversation_id)) |chat_mark| {
        chat_mark.* = @max(chat_mark.*, message_id);
        return;
    }
    // The id comes from the service, so a long one is an error, not a bug.
    if (conversation_id.len > id_size_max) return error.ConversationIdTooLong;
    if (seen.marks.count() == chat_count_limit) seen.fold();

    // `chat_count_limit` ids of at most `id_size_max` bytes always fit.
    std.debug.assert(seen.id_bytes_used + conversation_id.len <= seen.id_bytes.len);
    const key = seen.id_bytes[seen.id_bytes_used..][0..conversation_id.len];
    @memcpy(key, conversation_id);
    seen.id_bytes_used += @intCast(key.len);
    // Its mark was `mark_first` until now.
    seen.marks.putAssumeCapacityNoClobber(key, @max(seen.mark_first, message_id));
}

/// Empties `marks`, raising `mark_first` to the newest mark so no chat goes back.
fn fold(seen: *Seen) void {
    std.debug.assert(seen.marks.count() == chat_count_limit);
    var marks = seen.marks.valueIterator();
    while (marks.next()) |chat_mark| seen.mark_first = @max(seen.mark_first, chat_mark.*);
    seen.marks.clearRetainingCapacity();
    seen.id_bytes_used = 0;
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

test "record refuses an id longer than it has room for" {
    var seen: Seen = try .init(std.testing.allocator, &.{});
    defer seen.deinit();

    const long_id: [id_size_max + 1]u8 = @splat('x');
    try std.testing.expectError(error.ConversationIdTooLong, seen.record(&long_id, 1));
    try std.testing.expectEqual(0, seen.marks.count());
}
