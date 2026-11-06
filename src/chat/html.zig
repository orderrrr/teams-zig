//! Reading the HTML in Teams messages, one piece at a time.

const std = @import("std");
const writeVisible = @import("text.zig").writeVisible;

/// One piece of a message's HTML.
pub const Token = union(enum) {
    /// Text as written, up to the next tag or entity. It may hold control bytes.
    text: []const u8,
    /// A decoded entity: always one of the fixed replacements in `entities`.
    entity: []const u8,
    tag: Tag,
};

pub const Tag = struct {
    /// As written; compare with `is`.
    name: []const u8,
    closing: bool,
    /// Everything between the name and the closing `>`, as written.
    attributes: []const u8,

    /// Whether the tag is `name`, ignoring ASCII case.
    pub fn is(tag: *const Tag, name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(tag.name, name);
    }

    /// The raw value of attribute `name` (still entity-encoded), or null if the tag has none.
    pub fn attribute(tag: *const Tag, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);
        for (0..tag.attributes.len) |index| {
            // Only a whole word counts, so `alt` doesn't match `data-alt`.
            if (index > 0) {
                if (!std.ascii.isWhitespace(tag.attributes[index - 1])) continue;
            }
            const rest = tag.attributes[index..];
            if (!std.ascii.startsWithIgnoreCase(rest, name)) continue;
            const after = rest[name.len..];
            if (std.mem.startsWith(u8, after, "=")) return attributeValue(after[1..]);
        }
        return null;
    }
};

/// The common entities Teams writes, and what they stand for. Numeric entities other than `&#39;`
/// aren't decoded, so they can't produce control bytes.
const entities = [_]struct { []const u8, []const u8 }{
    .{ "&amp;", "&" },
    .{ "&lt;", "<" },
    .{ "&gt;", ">" },
    .{ "&quot;", "\"" },
    .{ "&#39;", "'" },
    .{ "&nbsp;", " " },
};

/// Splits HTML into tokens. Never fails: an unterminated tag is dropped, and an `&` that starts
/// no known entity is text.
pub const Reader = struct {
    /// What's left to read.
    rest: []const u8,

    pub fn next(reader: *Reader) ?Token {
        if (reader.rest.len == 0) return null;
        const rest_len_before = reader.rest.len;
        defer std.debug.assert(reader.rest.len < rest_len_before);

        if (reader.rest[0] == '<') {
            // The first `>` ends the tag; Teams writes `>` in values as `&gt;`. An unterminated
            // tag runs to the end of the content.
            const close_index = std.mem.indexOfScalar(u8, reader.rest, '>') orelse reader.rest.len;
            const inside = reader.rest[1..close_index];
            reader.rest = reader.rest[@min(close_index + 1, reader.rest.len)..];
            return .{ .tag = parseTag(inside) };
        }
        if (entityAt(reader.rest)) |entity| {
            reader.rest = reader.rest[entity[0].len..];
            return .{ .entity = entity[1] };
        }
        // Text runs to the next tag or entity, so two-byte control characters stay together.
        const next_markup = std.mem.indexOfAny(u8, reader.rest[1..], "<&");
        const run_len = if (next_markup) |index| index + 1 else reader.rest.len;
        const run = reader.rest[0..run_len];
        reader.rest = reader.rest[run_len..];
        return .{ .text = run };
    }
};

/// Writes an attribute value with its entities decoded and its control bytes shown as `\xNN`.
pub fn writeDecoded(writer: *std.Io.Writer, raw: []const u8) std.Io.Writer.Error!void {
    var reader: Reader = .{ .rest = raw };
    while (reader.next()) |token| switch (token) {
        .text => |run| try writeVisible(writer, run),
        .entity => |replacement| try writer.writeAll(replacement),
        // A value holds no tags; anything that looks like one is dropped.
        .tag => {},
    };
}

fn parseTag(inside: []const u8) Tag {
    const closing = std.mem.startsWith(u8, inside, "/");
    const after_slash = if (closing) inside[1..] else inside;
    const name_len = for (after_slash, 0..) |byte, index| {
        if (!std.ascii.isAlphanumeric(byte)) break index;
    } else after_slash.len;
    return .{
        .name = after_slash[0..name_len],
        .closing = closing,
        .attributes = after_slash[name_len..],
    };
}

/// The value at the start of `rest`: quoted with `"` or `'`, or up to the next space.
fn attributeValue(rest: []const u8) []const u8 {
    if (rest.len == 0) return rest;
    switch (rest[0]) {
        '"', '\'' => |quote| {
            const end = std.mem.indexOfScalar(u8, rest[1..], quote) orelse rest.len - 1;
            return rest[1..][0..end];
        },
        else => {
            const end = std.mem.indexOfAny(u8, rest, &std.ascii.whitespace) orelse rest.len;
            return rest[0..end];
        },
    }
}

/// The entity `rest` starts with, as its text and its replacement; null if none matches.
fn entityAt(rest: []const u8) ?struct { []const u8, []const u8 } {
    for (entities) |entity| {
        if (std.mem.startsWith(u8, rest, entity[0])) return entity;
    }
    return null;
}

fn expectTokens(html: []const u8, expected: []const Token) !void {
    var reader: Reader = .{ .rest = html };
    for (expected) |want| {
        const got = reader.next() orelse return error.TestExpectedMoreTokens;
        try std.testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(got));
        switch (want) {
            .text => |run| try std.testing.expectEqualStrings(run, got.text),
            .entity => |replacement| try std.testing.expectEqualStrings(replacement, got.entity),
            .tag => |tag| {
                try std.testing.expectEqualStrings(tag.name, got.tag.name);
                try std.testing.expectEqual(tag.closing, got.tag.closing);
            },
        }
    }
    try std.testing.expectEqual(null, reader.next());
}

test "Reader splits text, entities and tags" {
    try expectTokens("<p>fake &amp; <b>bye</b></p>", &.{
        .{ .tag = .{ .name = "p", .closing = false, .attributes = "" } },
        .{ .text = "fake " },
        .{ .entity = "&" },
        .{ .text = " " },
        .{ .tag = .{ .name = "b", .closing = false, .attributes = "" } },
        .{ .text = "bye" },
        .{ .tag = .{ .name = "b", .closing = true, .attributes = "" } },
        .{ .tag = .{ .name = "p", .closing = true, .attributes = "" } },
    });
}

test "Reader keeps unknown entities and a bare ampersand as text" {
    try expectTokens("fake &copy; & done", &.{
        .{ .text = "fake " },
        .{ .text = "&copy; " },
        .{ .text = "& done" },
    });
}

test "Reader drops an unterminated tag and ends" {
    try expectTokens("fake <b", &.{
        .{ .text = "fake " },
        .{ .tag = .{ .name = "b", .closing = false, .attributes = "" } },
    });
    try expectTokens("<", &.{.{ .tag = .{ .name = "", .closing = false, .attributes = "" } }});
}

test "Tag.attribute reads quoted and bare values, ignoring case and look-alike names" {
    var reader: Reader = .{
        .rest =
        \\<IMG data-alt="no" ALT="fake smile" itemtype='http://x/Emoji' width=20 src>
        ,
    };
    const tag = reader.next().?.tag;
    try std.testing.expect(tag.is("img"));
    try std.testing.expectEqualStrings("fake smile", tag.attribute("alt").?);
    try std.testing.expectEqualStrings("http://x/Emoji", tag.attribute("itemtype").?);
    try std.testing.expectEqualStrings("20", tag.attribute("width").?);
    try std.testing.expectEqual(null, tag.attribute("src"));
    try std.testing.expectEqual(null, tag.attribute("href"));
}

test "a > inside a quoted value ends the tag early, harmlessly" {
    var reader: Reader = .{ .rest = "<a href=\"x>y\">fake</a>" };
    const tag = reader.next().?.tag;
    try std.testing.expect(tag.is("a"));
    try std.testing.expectEqualStrings("x", tag.attribute("href").?);
    try std.testing.expectEqualStrings("y\">fake", reader.next().?.text);
}

test "writeDecoded decodes entities and shows control bytes" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeDecoded(&out.writer, "https://x/?a=1&amp;b=\x1b<i>2");
    try std.testing.expectEqualStrings("https://x/?a=1&b=\\x1b2", out.written());
}
