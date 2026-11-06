//! One message in a conversation, from `GET /users/ME/conversations/{id}/messages`.

const Message = @This();

const std = @import("std");
const json = @import("json.zig");
const mri = @import("mri.zig");
const markdown = @import("markdown.zig");
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

pub fn isText(message: *const Message) bool {
    return isTextType(message.message_type);
}

/// Whether a `messagetype` is user-written text rather than an event.
pub fn isTextType(message_type: []const u8) bool {
    if (std.mem.eql(u8, message_type, "Text")) return true;
    return std.mem.eql(u8, message_type, "RichText/Html");
}

/// Writes `content` for a terminal: HTML as Markdown (see `markdown.writeHtml`), plain `Text` as
/// it is but without `\r`. Either way, control bytes are shown as `\xNN` (see `writeVisible`).
pub fn writeText(message: *const Message, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    std.debug.assert(message.isText());
    if (std.mem.eql(u8, message.message_type, "Text")) {
        // Drop `\r`, writing the pieces separately so no control character forms across it.
        var pieces = std.mem.splitScalar(u8, message.content, '\r');
        while (pieces.next()) |piece| try text.writeVisible(writer, piece);
        return;
    }

    return markdown.writeHtml(writer, message.content);
}

/// Parses one messages response. `arena` owns everything returned.
pub fn parsePage(arena: std.mem.Allocator, body: []const u8) json.ParseError!Page {
    const response = try std.json.parseFromSliceLeaky(Response, arena, body, json.parse_options);
    const items = try arena.alloc(Message, response.messages.len);
    for (response.messages, items) |raw, *item| {
        item.* = .{
            .id = raw.id,
            .message_type = raw.messagetype,
            .sender = if (raw.from) |from| mri.fromContactUrl(from) else null,
            .sender_name = raw.imdisplayname,
            .content = raw.content,
            .arrived_at = raw.originalarrivaltime,
            .deleted_at_ms = if (raw.properties) |properties| properties.deletetime else null,
        };
    }

    return .{ .items = items, .backward_link = response._metadata.backwardLink };
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

test "writeText renders HTML content as Markdown with entities decoded" {
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
    try std.testing.expectEqualStrings("fake <hello> & **bye** 'now'", out.written());
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
    try std.testing.expectEqualStrings("fake 3", out.written());
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

    var rich = plain;
    rich.message_type = "RichText/Html";
    rich.content = "<p>fake\x1b[2J</p>";
    try rich.writeText(&out.writer);

    try std.testing.expectEqualStrings("fake\\x1b[2Jfake\\x1b[2J", out.written());
}

test "writeText doesn't let a dropped tag join a C1 control back together" {
    const message: Message = .{
        .id = "1",
        .message_type = "RichText/Html",
        .sender = null,
        .sender_name = null,
        .content = "<p>\xc2<span>\x9b[2J</p>",
        .arrived_at = "",
        .deleted_at_ms = null,
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try message.writeText(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\xc2\x9b") == null);
    try std.testing.expectEqualStrings("\\xc2\x9b[2J", out.written());
}

test "writeText drops carriage returns from plain Text without joining a C1 control" {
    const message: Message = .{
        .id = "1",
        .message_type = "Text",
        .sender = null,
        .sender_name = null,
        .content = "fake one\r\nfake two \xc2\r\x9b[2J",
        .arrived_at = "",
        .deleted_at_ms = null,
    };
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try message.writeText(&out.writer);
    try std.testing.expectEqualStrings("fake one\nfake two \\xc2\x9b[2J", out.written());
}
