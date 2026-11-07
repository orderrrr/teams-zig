//! Writing Markdown you typed as the HTML Teams sends: the reverse of `markdown.zig`, for the
//! same forms. Every typed character is HTML-escaped, so nothing typed becomes markup.

const std = @import("std");

/// Writes `text`, Markdown you typed, as a message's HTML. Lines are paragraphs (lines next to
/// each other share one, split by `<br>`), and a blank line between them stays. Lines starting
/// `#`–`###`, `> `, `- `/`* `/`+ ` or `1. ` are headings, quotes and list items; `` ``` `` lines
/// fence a code block, kept as typed. `\r` is dropped.
pub fn writeMarkdown(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var output: Output = .{ .writer = writer };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        try output.line(line);
    }
    try output.finish();
}

/// The HTML written so far, as far as the next line depends on it.
const Output = struct {
    writer: *std.Io.Writer,
    block: Block = .none,
    /// Inside a fenced code block, which has held this many lines.
    code_line_count: ?u32 = null,
    /// A blank line was typed after earlier content, and the next block starts with one.
    blank_pending: bool = false,
    /// Something has been written, so a blank line is worth keeping.
    started: bool = false,

    const Block = enum {
        none,
        paragraph,
        quote,
        list_bulleted,
        list_numbered,

        fn closeTags(block: Block) []const u8 {
            return switch (block) {
                .none => "",
                .paragraph => "</p>",
                .quote => "</blockquote>",
                .list_bulleted => "</ul>",
                .list_numbered => "</ol>",
            };
        }
    };

    fn line(output: *Output, text: []const u8) std.Io.Writer.Error!void {
        if (output.code_line_count != null) return output.lineCode(text);
        if (std.mem.trim(u8, text, " \t").len == 0) {
            try output.closeBlock();
            output.blank_pending = output.started;
            return;
        }
        if (std.mem.startsWith(u8, text, "```")) {
            try output.startBlock(.none);
            try output.writer.writeAll("<pre>");
            output.code_line_count = 0;
            return;
        }
        if (lineHeadingLevel(text)) |level| {
            try output.startBlock(.none);
            try output.writer.print("<h{d}>", .{level});
            try writeInline(output.writer, text[level + 1 ..]);
            try output.writer.print("</h{d}>", .{level});
            return;
        }
        if (lineQuoteStart(text)) |start| {
            try output.continueBlock(.quote, "<blockquote>");
            try output.writer.writeAll("<p>");
            try writeInline(output.writer, text[start..]);
            try output.writer.writeAll("</p>");
            return;
        }
        if (lineBulletStart(text)) |start| return output.lineItem(.list_bulleted, text[start..]);
        if (lineNumberStart(text)) |start| return output.lineItem(.list_numbered, text[start..]);
        if (output.block == .paragraph) {
            try output.writer.writeAll("<br>");
        } else {
            try output.startBlock(.paragraph);
            try output.writer.writeAll("<p>");
        }
        try writeInline(output.writer, text);
    }

    fn lineItem(output: *Output, list: Block, item: []const u8) std.Io.Writer.Error!void {
        const open_tag = if (list == .list_bulleted) "<ul>" else "<ol>";
        try output.continueBlock(list, open_tag);
        try output.writer.writeAll("<li>");
        try writeInline(output.writer, item);
        try output.writer.writeAll("</li>");
    }

    /// Code is written as typed, escaped, one line per line, until a closing fence.
    fn lineCode(output: *Output, text: []const u8) std.Io.Writer.Error!void {
        if (std.mem.startsWith(u8, text, "```")) {
            try output.writer.writeAll("</pre>");
            output.code_line_count = null;
            return;
        }
        if (output.code_line_count.? > 0) try output.writer.writeByte('\n');
        try writeEscaped(output.writer, text);
        output.code_line_count.? += 1;
    }

    /// Keeps `block` going if it's the current one; otherwise closes that and opens `block`.
    fn continueBlock(output: *Output, block: Block, open_tag: []const u8) std.Io.Writer.Error!void {
        if (output.block == block) return;
        try output.startBlock(block);
        try output.writer.writeAll(open_tag);
    }

    /// Closes the current block, writes a pending blank line, and makes `block` current.
    fn startBlock(output: *Output, block: Block) std.Io.Writer.Error!void {
        try output.closeBlock();
        if (output.blank_pending) {
            try output.writer.writeAll("<p>&nbsp;</p>");
            output.blank_pending = false;
        }
        output.block = block;
        output.started = true;
    }

    fn closeBlock(output: *Output) std.Io.Writer.Error!void {
        try output.writer.writeAll(output.block.closeTags());
        output.block = .none;
    }

    /// Closes what the text left open: a code block without its closing fence, or the last
    /// block.
    fn finish(output: *Output) std.Io.Writer.Error!void {
        if (output.code_line_count != null) {
            try output.writer.writeAll("</pre>");
            output.code_line_count = null;
        }
        try output.closeBlock();
    }
};

/// The level of a `# `, `## ` or `### ` heading line, or null.
fn lineHeadingLevel(text: []const u8) ?u8 {
    const level = std.mem.indexOfNone(u8, text, "#") orelse return null;
    if (level == 0) return null;
    if (level > 3) return null;
    if (text[level] != ' ') return null;
    return @intCast(level);
}

/// Where a quote line's text starts, after `>` and one optional space; null if it isn't one.
fn lineQuoteStart(text: []const u8) ?u32 {
    if (text[0] != '>') return null;
    if (std.mem.startsWith(u8, text, "> ")) return 2;
    return 1;
}

/// Where a bullet item's text starts, after `- `, `* ` or `+ `; null if it isn't one.
fn lineBulletStart(text: []const u8) ?u32 {
    if (text.len < 2) return null;
    if (std.mem.indexOfScalar(u8, "-*+", text[0]) == null) return null;
    if (text[1] != ' ') return null;
    return 2;
}

/// Where a numbered item's text starts, after up to nine digits, `.` or `)`, and a space; null
/// if it isn't one.
fn lineNumberStart(text: []const u8) ?u32 {
    const digit_count = std.mem.indexOfNone(u8, text, "0123456789") orelse return null;
    if (digit_count == 0) return null;
    if (digit_count > 9) return null;
    if (text.len < digit_count + 2) return null;
    if (std.mem.indexOfScalar(u8, ".)", text[digit_count]) == null) return null;
    if (text[digit_count + 1] != ' ') return null;
    return @intCast(digit_count + 2);
}

/// Inline markup that wraps text, as Markdown markers and HTML tags.
const Mark = enum {
    bold,
    italic,
    strike,

    fn tagName(mark: Mark) []const u8 {
        return switch (mark) {
            .bold => "b",
            .italic => "i",
            .strike => "s",
        };
    }
};

const mark_count = std.enums.values(Mark).len;

/// A marker found in the text: which mark, and how many bytes it takes.
const MarkerAt = struct {
    mark: Mark,
    len: u8,
};

/// The bytes that can start markup, so plain text runs up to the next of them.
const inline_special = "\\`[*_~";

/// Writes one line of Markdown as inline HTML: `**bold**`, `_italic_` or `*italic*`,
/// `~~strike~~`, `` `code` ``, `[text](https://…)`, and `\` before punctuation for a literal.
/// A marker without a partner on the line is text. Marks still open at the end are closed.
fn writeInline(writer: *std.Io.Writer, line: []const u8) std.Io.Writer.Error!void {
    std.debug.assert(std.mem.indexOfScalar(u8, line, '\n') == null);
    var marks_open: [mark_count]Mark = undefined;
    var marks_open_count: u8 = 0;
    var index: usize = 0;
    while (index < line.len) {
        const rest = line[index..];
        if (rest[0] == '\\') {
            if (rest.len > 1) {
                if (std.ascii.isPunctuation(rest[1])) {
                    try writeEscaped(writer, rest[1..2]);
                    index += 2;
                    continue;
                }
            }
        }
        if (rest[0] == '`') {
            if (std.mem.indexOfScalar(u8, rest[1..], '`')) |close_index| {
                if (close_index > 0) {
                    try writer.writeAll("<code>");
                    try writeEscaped(writer, rest[1..][0..close_index]);
                    try writer.writeAll("</code>");
                    index += close_index + 2;
                    continue;
                }
            }
        }
        if (rest[0] == '[') {
            const link_len = try writeInlineLink(writer, rest);
            if (link_len > 0) {
                index += link_len;
                continue;
            }
        }
        if (writeInlineMarkerAt(line, index)) |marker| {
            const open = marks_open[0..marks_open_count];
            const top_open = marks_open_count > 0 and open[open.len - 1] == marker.mark;
            if (top_open) {
                if (writeInlineCanClose(line, index, marker)) {
                    try writer.print("</{s}>", .{marker.mark.tagName()});
                    marks_open_count -= 1;
                    index += marker.len;
                    continue;
                }
            }
            const is_open = std.mem.indexOfScalar(Mark, open, marker.mark) != null;
            if (!is_open) {
                if (writeInlineCanOpen(line, index, marker)) {
                    if (writeInlineCloserAfter(line, index + marker.len, marker)) {
                        try writer.print("<{s}>", .{marker.mark.tagName()});
                        marks_open[marks_open_count] = marker.mark;
                        marks_open_count += 1;
                        index += marker.len;
                        continue;
                    }
                }
            }
            try writeEscaped(writer, rest[0..marker.len]);
            index += marker.len;
            continue;
        }
        const run_len = std.mem.indexOfAny(u8, rest[1..], inline_special) orelse rest.len - 1;
        try writeEscaped(writer, rest[0 .. run_len + 1]);
        index += run_len + 1;
    }
    while (marks_open_count > 0) {
        marks_open_count -= 1;
        try writer.print("</{s}>", .{marks_open[marks_open_count].tagName()});
    }
}

/// The marker at `line[index]`, if any: `**`, `~~`, `*` or `_`.
fn writeInlineMarkerAt(line: []const u8, index: usize) ?MarkerAt {
    const rest = line[index..];
    if (std.mem.startsWith(u8, rest, "**")) return .{ .mark = .bold, .len = 2 };
    if (std.mem.startsWith(u8, rest, "~~")) return .{ .mark = .strike, .len = 2 };
    if (rest[0] == '*') return .{ .mark = .italic, .len = 1 };
    if (rest[0] == '_') return .{ .mark = .italic, .len = 1 };
    return null;
}

/// A marker opens if text follows it; `_` also needs no letter or digit before it, so
/// `snake_case_name` stays as typed.
fn writeInlineCanOpen(line: []const u8, index: usize, marker: MarkerAt) bool {
    const after = index + marker.len;
    if (after == line.len) return false;
    if (std.ascii.isWhitespace(line[after])) return false;
    if (line[index] != '_') return true;
    if (index == 0) return true;
    return !std.ascii.isAlphanumeric(line[index - 1]);
}

/// A marker closes if text precedes it; `_` also needs no letter or digit after it.
fn writeInlineCanClose(line: []const u8, index: usize, marker: MarkerAt) bool {
    if (index == 0) return false;
    if (std.ascii.isWhitespace(line[index - 1])) return false;
    if (line[index] != '_') return true;
    const after = index + marker.len;
    if (after == line.len) return true;
    return !std.ascii.isAlphanumeric(line[after]);
}

/// Whether the same marker, able to close, appears in `line` from `start` on.
fn writeInlineCloserAfter(line: []const u8, start: usize, marker: MarkerAt) bool {
    var index = start;
    while (index < line.len) : (index += 1) {
        const found = writeInlineMarkerAt(line, index) orelse continue;
        if (found.mark != marker.mark) continue;
        if (line[index] != line[start - marker.len]) continue;
        if (writeInlineCanClose(line, index, found)) return true;
    }
    return false;
}

/// Writes `[text](url)` at the start of `rest` as a link and returns its length, or 0 if
/// `rest` doesn't start with one. Only `http` and `https` targets count; the text is plain.
fn writeInlineLink(writer: *std.Io.Writer, rest: []const u8) std.Io.Writer.Error!usize {
    std.debug.assert(rest[0] == '[');
    const text_end = std.mem.indexOf(u8, rest, "](") orelse return 0;
    if (text_end == 1) return 0;
    const url_start = text_end + 2;
    const url_len = std.mem.indexOfScalar(u8, rest[url_start..], ')') orelse return 0;
    const url = rest[url_start..][0..url_len];
    if (!writeInlineLinkAllowed(url)) return 0;

    try writer.writeAll("<a href=\"");
    try writeEscaped(writer, url);
    try writer.writeAll("\">");
    try writeEscaped(writer, rest[1..text_end]);
    try writer.writeAll("</a>");
    return url_start + url_len + 1;
}

/// Web links only, with no spaces, so a typed `javascript:` or local path stays text.
fn writeInlineLinkAllowed(url: []const u8) bool {
    if (std.mem.indexOfAny(u8, url, &std.ascii.whitespace) != null) return false;
    if (std.ascii.startsWithIgnoreCase(url, "https://")) return url.len > "https://".len;
    if (std.ascii.startsWithIgnoreCase(url, "http://")) return url.len > "http://".len;
    return false;
}

/// Writes text with `&`, `<`, `>` and `"` as entities.
fn writeEscaped(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var run_start: usize = 0;
    for (text, 0..) |byte, index| {
        const entity = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            else => continue,
        };
        try writer.writeAll(text[run_start..index]);
        try writer.writeAll(entity);
        run_start = index + 1;
    }
    try writer.writeAll(text[run_start..]);
}

const markdown = @import("markdown.zig");

fn expectInline(line: []const u8, expected_html: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeInline(&out.writer, line);
    try std.testing.expectEqualStrings(expected_html, out.written());
}

/// Writes `line` as HTML, renders it back as `messages` would, and expects `shown`.
fn expectInlineRoundTrip(line: []const u8, shown: []const u8) !void {
    var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer html.deinit();
    try writeInline(&html.writer, line);

    var back: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer back.deinit();
    try markdown.writeHtml(&back.writer, html.written());
    try std.testing.expectEqualStrings(shown, back.written());
}

test "writeInline escapes everything typed" {
    try expectInline("fake <b>&\"x\"</b>", "fake &lt;b&gt;&amp;&quot;x&quot;&lt;/b&gt;");
    try expectInline("", "");
}

test "writeInline writes bold, italic, strike and code" {
    const marked = "**fake** _one_ *two* ~~three~~";
    try expectInline(marked, "<b>fake</b> <i>one</i> <i>two</i> <s>three</s>");
    try expectInline("`a <b> **c**`", "<code>a &lt;b&gt; **c**</code>");
    try expectInline("**fake _nested_ bold**", "<b>fake <i>nested</i> bold</b>");
}

test "writeInline leaves markers without a partner as text" {
    try expectInline("fake ** two", "fake ** two");
    try expectInline("a * b * c", "a * b * c");
    try expectInline("snake_case_name", "snake_case_name");
    try expectInline("**open only", "**open only");
    try expectInline("`open only", "`open only");
    try expectInline("``", "``");
}

test "writeInline keeps backslash-escaped punctuation literal" {
    try expectInline("\\*fake\\* \\_ \\\\ \\a", "*fake* _ \\ \\a");
    try expectInline("\\<b\\>", "&lt;b&gt;");
}

test "writeInline closes marks left open by crossed markers" {
    try expectInline("**a _b** c_", "<b>a <i>b** c</i></b>");
}

test "writeInline writes web links and leaves others as text" {
    try expectInline("[fake](https://example.invalid/?a=1&b=\"2\")",
        \\<a href="https://example.invalid/?a=1&amp;b=&quot;2&quot;">fake</a>
    );
    try expectInline("[fake](javascript:alert(1))", "[fake](javascript:alert(1))");
    try expectInline("[fake](https://)", "[fake](https://)");
    try expectInline("[](https://example.invalid)", "[](https://example.invalid)");
    try expectInline("[fake](https://a b)", "[fake](https://a b)");
}

test "writeInline round-trips through what messages shows" {
    try expectInlineRoundTrip("**fake** _one_ ~~two~~ `three`", "**fake** _one_ ~~two~~ `three`");
    try expectInlineRoundTrip("*one*", "_one_");
    const link = "[fake](https://example.invalid/x)";
    try expectInlineRoundTrip(link, link);
    try expectInlineRoundTrip("a < b & c > d", "a < b & c > d");
}

fn expectMarkdown(text: []const u8, expected_html: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeMarkdown(&out.writer, text);
    try std.testing.expectEqualStrings(expected_html, out.written());
}

/// Writes `text` as HTML, renders it back as `messages` would, and expects `text` again.
fn expectRoundTrip(text: []const u8) !void {
    var html: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer html.deinit();
    try writeMarkdown(&html.writer, text);

    var back: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer back.deinit();
    try markdown.writeHtml(&back.writer, html.written());
    try std.testing.expectEqualStrings(text, back.written());
}

test "writeMarkdown writes paragraphs, line breaks and blank lines" {
    try expectMarkdown("fake one", "<p>fake one</p>");
    try expectMarkdown("fake one\r\nfake two", "<p>fake one<br>fake two</p>");
    try expectMarkdown("fake one\n\n\nfake two", "<p>fake one</p><p>&nbsp;</p><p>fake two</p>");
    try expectMarkdown("\n\nfake\n\n", "<p>fake</p>");
    try expectMarkdown("", "");
}

test "writeMarkdown writes headings, quotes and lists" {
    try expectMarkdown("## fake *one*", "<h2>fake <i>one</i></h2>");
    try expectMarkdown("#### fake", "<p>#### fake</p>");
    try expectMarkdown("> fake one\n>fake two",
        \\<blockquote><p>fake one</p><p>fake two</p></blockquote>
    );
    try expectMarkdown("- a\n* b\n1. c\n2) d",
        \\<ul><li>a</li><li>b</li></ul><ol><li>c</li><li>d</li></ol>
    );
}

test "writeMarkdown fences code as typed and closes an unclosed fence" {
    try expectMarkdown("```zig\na <b>\n  **c**\n```", "<pre>a &lt;b&gt;\n  **c**</pre>");
    try expectMarkdown("```\nfake", "<pre>fake</pre>");
}

test "writeMarkdown round-trips through what messages shows" {
    try expectRoundTrip("fake one\nfake **two**");
    try expectRoundTrip("fake one\n\nfake two");
    try expectRoundTrip("# fake heading\nfake text");
    try expectRoundTrip("- fake one\n- fake _two_\n\nafter");
    try expectRoundTrip("1. fake one\n2. fake two\n\nafter");
    try expectRoundTrip("> fake quote\n> fake more\n\nafter");
    try expectRoundTrip("```\nfake  code\n  <x>\n```\nafter");
    try expectRoundTrip("\\# not a heading");
    try expectRoundTrip("[fake](https://example.invalid/) & `code`");
}
