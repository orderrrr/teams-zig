//! One message in a conversation, from `GET /users/ME/conversations/{id}/messages`.

const Message = @This();

const std = @import("std");

id: []const u8,
/// `Text` and `RichText/Html` are user-written; anything else (`ThreadActivity/AddMember`,
/// `Event/Call`, ...) is an event whose content isn't meant for reading.
message_type: []const u8,
/// The sender's MRI, such as `8:orgid:<uuid>`.
sender: []const u8,
/// Empty when the service doesn't send a display name, as for some system events.
sender_name: []const u8,
/// Plain text or HTML, depending on `message_type`. Empty for deleted messages.
content: []const u8,
/// ISO timestamp.
arrived_at: []const u8,
/// Milliseconds since the Unix epoch (the service sends a number here, not an ISO string);
/// null unless the message was deleted.
deleted_at: ?u64,

pub const ParseError = std.json.ParseError(std.json.Scanner);

/// Messages gathered across pages, newest first. Every string lives in the arena.
pub const List = struct {
    arena: *std.heap.ArenaAllocator,
    items: []const Message,

    pub fn deinit(list: List) void {
        const allocator = list.arena.child_allocator;
        list.arena.deinit();
        allocator.destroy(list.arena);
    }
};

/// One response: its messages, and the URL of the next older page if there is one.
pub const Page = struct {
    items: []const Message,
    backward_link: ?[]const u8,
};

const Response = struct {
    messages: []const struct {
        id: []const u8,
        messagetype: []const u8,
        from: []const u8 = "",
        imdisplayname: ?[]const u8 = null,
        content: []const u8 = "",
        originalarrivaltime: []const u8,
        properties: ?struct { deletetime: ?u64 = null } = null,
    },
    _metadata: struct { backwardLink: ?[]const u8 = null },
};

pub fn isText(message: Message) bool {
    return std.mem.eql(u8, message.message_type, "Text") or
        std.mem.eql(u8, message.message_type, "RichText/Html");
}

/// Writes `content` as plain text: tags dropped, the common entities decoded. Text messages pass through.
pub fn writeText(message: Message, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (std.mem.eql(u8, message.message_type, "Text")) return writer.writeAll(message.content);

    const entities = [_]struct { []const u8, []const u8 }{
        .{ "&amp;", "&" },   .{ "&lt;", "<" },  .{ "&gt;", ">" },
        .{ "&quot;", "\"" }, .{ "&#39;", "'" }, .{ "&nbsp;", " " },
    };
    var rest = message.content;
    next: while (rest.len > 0) {
        if (rest[0] == '<') {
            const end = std.mem.indexOfScalar(u8, rest, '>') orelse return;
            rest = rest[end + 1 ..];
            continue;
        }
        if (rest[0] == '&') {
            for (entities) |entity| {
                if (std.mem.startsWith(u8, rest, entity[0])) {
                    try writer.writeAll(entity[1]);
                    rest = rest[entity[0].len..];
                    continue :next;
                }
            }
        }
        try writer.writeByte(rest[0]);
        rest = rest[1..];
    }
}

/// Parses one messages response. `arena` owns everything returned.
pub fn parsePage(arena: std.mem.Allocator, body: []const u8) ParseError!Page {
    const response = try std.json.parseFromSliceLeaky(Response, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    const items = try arena.alloc(Message, response.messages.len);
    for (response.messages, items) |raw, *item| {
        item.* = .{
            .id = raw.id,
            .message_type = raw.messagetype,
            .sender = senderOf(raw.from),
            .sender_name = raw.imdisplayname orelse "",
            .content = raw.content,
            .arrived_at = raw.originalarrivaltime,
            .deleted_at = if (raw.properties) |properties| properties.deletetime else null,
        };
    }
    return .{ .items = items, .backward_link = response._metadata.backwardLink };
}

/// `from` is a contact URL ending in the sender's MRI: `https://.../contacts/8:orgid:<uuid>`.
fn senderOf(from: []const u8) []const u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, from, '/')) |slash| slash + 1 else 0;
    return from[start..];
}

test "parsePage reads messages, the deleted marker and the backward link" {
    const body =
        \\{"tenantId":"fake","_metadata":{"backwardLink":"https://emea.ng.msg.teams.microsoft.com/v1/fake-older"},
        \\ "messages":[
        \\  {"id":"2","messagetype":"RichText/Html","content":"<p>fake hello</p>","imdisplayname":"Fake Person",
        \\   "from":"https://emea.ng.msg.teams.microsoft.com/v1/users/ME/contacts/8:orgid:fake-uuid",
        \\   "originalarrivaltime":"2026-11-01T10:00:01.000Z"},
        \\  {"id":"1","messagetype":"Text","content":"","from":"https://x/contacts/8:orgid:fake-uuid",
        \\   "originalarrivaltime":"2026-11-01T10:00:00.000Z","properties":{"deletetime":1793000000000}},
        \\  {"id":"0","messagetype":"ThreadActivity/AddMember","originalarrivaltime":"2026-11-01T09:00:00.000Z"}
        \\]}
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const page = try parsePage(arena.allocator(), body);

    try std.testing.expectEqualStrings("https://emea.ng.msg.teams.microsoft.com/v1/fake-older", page.backward_link.?);
    try std.testing.expectEqual(3, page.items.len);
    try std.testing.expectEqualStrings("8:orgid:fake-uuid", page.items[0].sender);
    try std.testing.expectEqualStrings("Fake Person", page.items[0].sender_name);
    try std.testing.expect(page.items[0].isText());
    try std.testing.expectEqual(null, page.items[0].deleted_at);
    try std.testing.expectEqual(1793000000000, page.items[1].deleted_at.?);
    try std.testing.expect(!page.items[2].isText());
    try std.testing.expectEqualStrings("", page.items[2].sender);
}

test "parsePage reports no backward link on the oldest page" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const page = try parsePage(arena.allocator(), "{\"_metadata\":{\"backwardLink\":null},\"messages\":[]}");
    try std.testing.expectEqual(null, page.backward_link);
}

test "writeText strips tags and decodes entities from HTML content" {
    const message: Message = .{
        .id = "1",
        .message_type = "RichText/Html",
        .sender = "",
        .sender_name = "",
        .content = "<p>fake &lt;hello&gt; &amp; <b>bye</b>&nbsp;&#39;now&#39;</p>",
        .arrived_at = "",
        .deleted_at = null,
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try message.writeText(&out.writer);
    try std.testing.expectEqualStrings("fake <hello> & bye 'now'", out.written());
}

test "writeText leaves plain Text content alone" {
    const message: Message = .{
        .id = "1",
        .message_type = "Text",
        .sender = "",
        .sender_name = "",
        .content = "fake <not a tag> &amp;",
        .arrived_at = "",
        .deleted_at = null,
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try message.writeText(&out.writer);
    try std.testing.expectEqualStrings("fake <not a tag> &amp;", out.written());
}
