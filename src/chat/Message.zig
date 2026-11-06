//! One message in a conversation, from `GET /users/ME/conversations/{id}/messages`.

const Message = @This();

const std = @import("std");
const json = @import("json.zig");
const text = @import("text.zig");
const Owned = @import("Owned.zig").Owned;

// Every string borrows the arena of the `List` or page that parsed it.
id: []const u8,
/// `Text` and `RichText/Html` are user-written; anything else (`ThreadActivity/AddMember`,
/// `Event/Call`, ...) is an event whose content isn't meant for reading.
message_type: []const u8,
/// The sender's MRI, such as `8:orgid:<uuid>`. Null when the service sends no sender.
sender: ?[]const u8,
/// Null when the service doesn't send a display name, as for some system events.
sender_name: ?[]const u8,
/// Plain text or HTML, depending on `message_type`. Empty for deleted messages.
content: []const u8,
/// ISO timestamp.
arrived_at: []const u8,
/// Null unless the message was deleted. The service sends a number here, not an ISO string.
deleted_at_ms: ?u64,

/// Messages gathered across pages, newest first. Every string lives in the arena.
pub const List = Owned(Message);

/// One response: its messages, and the URL of the next older page if there is one.
pub const Page = struct {
    /// Both fields borrow the arena passed to `parsePage`.
    items: []const Message,
    backward_link: ?[]const u8,
};

const Response = struct {
    messages: []const struct {
        id: []const u8,
        messagetype: []const u8,
        from: ?[]const u8 = null,
        imdisplayname: ?[]const u8 = null,
        content: []const u8 = "",
        originalarrivaltime: []const u8,
        properties: ?struct { deletetime: ?u64 = null } = null,
    },
    _metadata: struct { backwardLink: ?[]const u8 = null },
};

const entities = [_]struct { []const u8, []const u8 }{
    .{ "&amp;", "&" },
    .{ "&lt;", "<" },
    .{ "&gt;", ">" },
    .{ "&quot;", "\"" },
    .{ "&#39;", "'" },
    .{ "&nbsp;", " " },
};

pub fn isText(message: *const Message) bool {
    if (std.mem.eql(u8, message.message_type, "Text")) return true;
    return std.mem.eql(u8, message.message_type, "RichText/Html");
}

/// Writes `content` as plain text: tags dropped, the common entities decoded. Plain `Text`
/// messages keep their text. Either way, control bytes are shown as `\xNN` (see `writeVisible`).
pub fn writeText(message: *const Message, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    std.debug.assert(message.isText());
    if (std.mem.eql(u8, message.message_type, "Text")) {
        return text.writeVisible(writer, message.content);
    }

    var rest = message.content;
    while (rest.len > 0) {
        const rest_len_before = rest.len;
        defer std.debug.assert(rest.len < rest_len_before);

        if (rest[0] == '<') {
            // An unterminated tag runs to the end of the content, so all of it is dropped.
            const close_index = std.mem.indexOfScalar(u8, rest, '>') orelse rest.len - 1;
            rest = rest[close_index + 1 ..];
            continue;
        }
        if (entityAt(rest)) |entity| {
            // Advance before writing, so the progress check holds if the write fails.
            rest = rest[entity[0].len..];
            try writer.writeAll(entity[1]);
            continue;
        }
        const byte = rest[0];
        rest = rest[1..];
        try text.writeVisible(writer, &.{byte});
    }
}

/// The entity `rest` starts with, as its text and its replacement; null if none matches.
fn entityAt(rest: []const u8) ?struct { []const u8, []const u8 } {
    for (entities) |entity| {
        if (std.mem.startsWith(u8, rest, entity[0])) return entity;
    }
    return null;
}

/// Parses one messages response. `arena` owns everything returned.
pub fn parsePage(arena: std.mem.Allocator, body: []const u8) json.ParseError!Page {
    const response = try std.json.parseFromSliceLeaky(Response, arena, body, json.parse_options);
    const items = try arena.alloc(Message, response.messages.len);
    for (response.messages, items) |raw, *item| {
        item.* = .{
            .id = raw.id,
            .message_type = raw.messagetype,
            .sender = if (raw.from) |from| senderOf(from) else null,
            .sender_name = raw.imdisplayname,
            .content = raw.content,
            .arrived_at = raw.originalarrivaltime,
            .deleted_at_ms = if (raw.properties) |properties| properties.deletetime else null,
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
    const older_link = "https://emea.ng.msg.teams.microsoft.com/v1/fake-older";
    const body =
        \\{"tenantId":"fake",
        \\ "_metadata":{"backwardLink":"https://emea.ng.msg.teams.microsoft.com/v1/fake-older"},
        \\ "messages":[
        \\  {"id":"2","messagetype":"RichText/Html","content":"<p>fake hello</p>",
        \\   "imdisplayname":"Fake Person",
        \\   "from":"https://x/v1/users/ME/contacts/8:orgid:fake-uuid",
        \\   "originalarrivaltime":"2026-11-01T10:00:01.000Z"},
        \\  {"id":"1","messagetype":"Text","content":"",
        \\   "from":"https://x/contacts/8:orgid:fake-uuid",
        \\   "originalarrivaltime":"2026-11-01T10:00:00.000Z",
        \\   "properties":{"deletetime":1793000000000}},
        \\  {"id":"0","messagetype":"ThreadActivity/AddMember",
        \\   "originalarrivaltime":"2026-11-01T09:00:00.000Z"}
        \\]}
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const page = try parsePage(arena.allocator(), body);
    try std.testing.expectEqualStrings(older_link, page.backward_link.?);
    try std.testing.expectEqual(3, page.items.len);
    try std.testing.expectEqualStrings("8:orgid:fake-uuid", page.items[0].sender.?);
    try std.testing.expectEqualStrings("Fake Person", page.items[0].sender_name.?);
    try std.testing.expect(page.items[0].isText());
    try std.testing.expectEqual(null, page.items[0].deleted_at_ms);
    try std.testing.expectEqual(1793000000000, page.items[1].deleted_at_ms.?);
    try std.testing.expectEqual(null, page.items[1].sender_name);
    try std.testing.expect(!page.items[2].isText());
    try std.testing.expectEqual(null, page.items[2].sender);
}

test "parsePage reports no backward link on the oldest page" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const body = "{\"_metadata\":{\"backwardLink\":null},\"messages\":[]}";
    const page = try parsePage(arena.allocator(), body);
    try std.testing.expectEqual(null, page.backward_link);
}

test "writeText strips tags and decodes entities from HTML content" {
    const message: Message = .{
        .id = "1",
        .message_type = "RichText/Html",
        .sender = null,
        .sender_name = null,
        .content = "<p>fake &lt;hello&gt; &amp; <b>bye</b>&nbsp;&#39;now&#39;</p>",
        .arrived_at = "",
        .deleted_at_ms = null,
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
        .sender = null,
        .sender_name = null,
        .content = "fake <not a tag> &amp;",
        .arrived_at = "",
        .deleted_at_ms = null,
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try message.writeText(&out.writer);
    try std.testing.expectEqualStrings("fake <not a tag> &amp;", out.written());
}

test "writeText drops an unterminated tag instead of failing" {
    const message: Message = .{
        .id = "1",
        .message_type = "RichText/Html",
        .sender = null,
        .sender_name = null,
        .content = "<p>fake 3 <b",
        .arrived_at = "",
        .deleted_at_ms = null,
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try message.writeText(&out.writer);
    try std.testing.expectEqualStrings("fake 3 ", out.written());
}

test "parsePage fails on a message without an arrival time" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const body = "{\"_metadata\":{},\"messages\":[{\"id\":\"1\",\"messagetype\":\"Text\"}]}";
    try std.testing.expectError(error.MissingField, parsePage(arena.allocator(), body));
}

test "writeText reports a failing writer instead of tripping its progress check" {
    const message: Message = .{
        .id = "1",
        .message_type = "RichText/Html",
        .sender = null,
        .sender_name = null,
        .content = "<p>fake &amp; more text than fits</p>",
        .arrived_at = "",
        .deleted_at_ms = null,
    };
    var buffer: [4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try std.testing.expectError(error.WriteFailed, message.writeText(&writer));
}

test "writeText passes unknown entities and a bare ampersand through" {
    const message: Message = .{
        .id = "1",
        .message_type = "RichText/Html",
        .sender = null,
        .sender_name = null,
        .content = "fake &copy; & done",
        .arrived_at = "",
        .deleted_at_ms = null,
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try message.writeText(&out.writer);
    try std.testing.expectEqualStrings("fake &copy; & done", out.written());
}

test "senderOf returns the whole value when from has no slash" {
    try std.testing.expectEqualStrings("8:orgid:fake-uuid", senderOf("8:orgid:fake-uuid"));
}

test "writeText shows control bytes from both plain and HTML content" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const plain: Message = .{
        .id = "1",
        .message_type = "Text",
        .sender = null,
        .sender_name = null,
        .content = "fake\x1b[2J",
        .arrived_at = "",
        .deleted_at_ms = null,
    };
    try plain.writeText(&out.writer);

    var html = plain;
    html.message_type = "RichText/Html";
    html.content = "<p>fake\x1b[2J</p>";
    try html.writeText(&out.writer);

    try std.testing.expectEqualStrings("fake\\x1b[2Jfake\\x1b[2J", out.written());
}
