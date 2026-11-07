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
    /// What came before the next block: nothing yet, content, or content and then a blank line,
    /// which the next block keeps.
    before: enum { nothing, content, blank } = .nothing,

    const Block = union(enum) {
        none,
        paragraph,
        quote,
        list_bulleted,
        list_numbered,
        /// A fenced code block that has held this many lines.
        code: u32,

        fn closeTags(block: Block) []const u8 {
            return switch (block) {
                .none => "",
                .paragraph => "</p>",
                .quote => "</blockquote>",
                .list_bulleted => "</ul>",
                .list_numbered => "</ol>",
                .code => "</pre>",
            };
        }
    };

    /// A typed line. As in Teams' compose box, a run of three or more backticks anywhere is a code
    /// fence: with a run of the same length later on the line, what's between is a code block;
    /// without one, the block starts on the next line (the rest of this one names the language).
    /// Text before and after a fence becomes its own block.
    fn line(output: *Output, text: []const u8) std.Io.Writer.Error!void {
        var rest = text;
        // Each pass ends the line or consumes a fence and its partner, so it stops within it.
        while (true) {
            if (output.block == .code) {
                rest = try output.lineCode(rest) orelse return;
            }
            const fence = lineFence(rest) orelse return output.lineText(rest);
            const before = std.mem.trim(u8, rest[0..fence.start], " \t");
            if (before.len > 0) try output.lineText(before);
            try output.startBlock(.{ .code = 0 });
            try output.writer.writeAll("<pre>");

            const after = rest[fence.start + fence.len ..];
            const close_start = backtickRunFind(after, 0, fence.len) orelse return;
            try writeEscaped(output.writer, std.mem.trim(u8, after[0..close_start], " \t"));
            try output.closeBlock();
            rest = std.mem.trim(u8, after[close_start + fence.len ..], " \t");
            if (rest.len == 0) return;
        }
    }

    /// A line with no code fence: a blank line, a heading, a quote, a list item or text.
    fn lineText(output: *Output, text: []const u8) std.Io.Writer.Error!void {
        if (std.mem.trim(u8, text, " \t").len == 0) {
            try output.closeBlock();
            if (output.before == .content) output.before = .blank;
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
        const open_tag = switch (list) {
            .list_bulleted => "<ul>",
            .list_numbered => "<ol>",
            .none, .paragraph, .quote, .code => unreachable,
        };
        try output.continueBlock(list, open_tag);
        try output.writer.writeAll("<li>");
        try writeInline(output.writer, item);
        try output.writer.writeAll("</li>");
    }

    /// A line inside a code block, written as typed, escaped. A fence on it ends the block, after
    /// the code before the fence; what follows the fence on the line is returned, or null if
    /// nothing does.
    fn lineCode(output: *Output, text: []const u8) std.Io.Writer.Error!?[]const u8 {
        std.debug.assert(output.block == .code);
        const found = lineFence(text) orelse {
            try output.lineCodeWrite(text);
            return null;
        };
        // Code typed before the fence on its line, as in `ls -la```, is the block's last line.
        const code = text[0..found.start];
        if (std.mem.trim(u8, code, " \t").len > 0) try output.lineCodeWrite(code);
        try output.closeBlock();
        const after = std.mem.trim(u8, text[found.start + found.len ..], " \t");
        if (after.len == 0) return null;
        return after;
    }

    fn lineCodeWrite(output: *Output, code: []const u8) std.Io.Writer.Error!void {
        if (output.block.code > 0) try output.writer.writeByte('\n');
        try writeEscaped(output.writer, code);
        output.block.code += 1;
    }

    /// Keeps `block` going if it's the current one; otherwise closes that and opens `block`.
    fn continueBlock(output: *Output, block: Block, open_tag: []const u8) std.Io.Writer.Error!void {
        if (std.meta.activeTag(output.block) == std.meta.activeTag(block)) return;
        try output.startBlock(block);
        try output.writer.writeAll(open_tag);
    }

    /// Closes the current block, writes a pending blank line, and makes `block` current.
    fn startBlock(output: *Output, block: Block) std.Io.Writer.Error!void {
        try output.closeBlock();
        if (output.before == .blank) try output.writer.writeAll("<p>&nbsp;</p>");
        output.before = .content;
        output.block = block;
    }

    fn closeBlock(output: *Output) std.Io.Writer.Error!void {
        try output.writer.writeAll(output.block.closeTags());
        output.block = .none;
    }

    /// Closes what the text left open, a code block without its closing fence included.
    fn finish(output: *Output) std.Io.Writer.Error!void {
        try output.closeBlock();
    }
};

/// A code fence on a line: where its run of backticks starts and how long it is.
const Fence = struct {
    start: u32,
    len: u32,
};

/// The first run of three or more backticks on a line, or null if there's none.
fn lineFence(text: []const u8) ?Fence {
    std.debug.assert(text.len <= std.math.maxInt(u32));
    var search_start: u32 = 0;
    while (std.mem.indexOfScalarPos(u8, text, search_start, '`')) |run_index| {
        const run_start: u32 = @intCast(run_index);
        const run_end: u32 = @intCast(
            std.mem.indexOfNonePos(u8, text, run_start, "`") orelse text.len,
        );
        // Each pass moves past a whole run, so the loop ends within `text`.
        std.debug.assert(run_end > run_start);
        if (run_end - run_start >= 3) return .{ .start = run_start, .len = run_end - run_start };
        search_start = run_end;
    }
    return null;
}

/// Where the first run of exactly `run_len` backticks at or after `search_start` begins, or null
/// if there's none.
fn backtickRunFind(text: []const u8, search_start: u32, run_len: u32) ?u32 {
    std.debug.assert(run_len > 0);
    std.debug.assert(search_start <= text.len);
    std.debug.assert(text.len <= std.math.maxInt(u32));
    var candidate_start: u32 = search_start;
    while (std.mem.indexOfScalarPos(u8, text, candidate_start, '`')) |candidate_index| {
        const candidate: u32 = @intCast(candidate_index);
        const candidate_end: u32 = @intCast(
            std.mem.indexOfNonePos(u8, text, candidate, "`") orelse text.len,
        );
        // Each pass moves past a whole run, so the loop ends within `text`.
        std.debug.assert(candidate_end > candidate);
        if (candidate_end - candidate == run_len) return candidate;
        candidate_start = candidate_end;
    }
    return null;
}

/// The level of a `# `, `## ` or `### ` heading line, or null.
fn lineHeadingLevel(text: []const u8) ?u8 {
    std.debug.assert(text.len > 0);
    const level = std.mem.indexOfNone(u8, text, "#") orelse return null;
    if (level == 0) return null;
    if (level > 3) return null;
    if (text[level] != ' ') return null;
    return @intCast(level);
}

/// Where a quote line's text starts, after `>` and one optional space; null if it isn't one.
fn lineQuoteStart(text: []const u8) ?u32 {
    std.debug.assert(text.len > 0);
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
    std.debug.assert(line.len <= std.math.maxInt(u32));
    var state: Inline = .{ .writer = writer, .line = line };
    while (state.index < line.len) {
        const index_before = state.index;
        try state.next();
        // Checked after success only: a failed write leaves the index where it was.
        std.debug.assert(state.index > index_before);
    }
    try state.finish();
}

/// One line on its way to inline HTML.
const Inline = struct {
    writer: *std.Io.Writer,
    line: []const u8,
    /// Where the next unwritten byte is.
    index: u32 = 0,
    /// The open marks, outermost first.
    marks_open: [mark_count]MarkOpen = undefined,
    marks_open_count: u8 = 0,

    /// An open mark and the byte that opened it, so `_` doesn't close what `*` opened.
    const MarkOpen = struct {
        mark: Mark,
        byte: u8,
    };

    /// Writes the next piece of the line: an escape, code, a link, a marker or plain text.
    fn next(state: *Inline) std.Io.Writer.Error!void {
        std.debug.assert(state.index < state.line.len);
        if (try state.nextEscape()) return;
        if (try state.nextCode()) return;
        if (try state.nextLink()) return;
        if (try state.nextMarker()) return;
        try state.nextText();
    }

    fn rest(state: *const Inline) []const u8 {
        return state.line[state.index..];
    }

    /// `\` before punctuation: the punctuation, as text.
    fn nextEscape(state: *Inline) std.Io.Writer.Error!bool {
        const text = state.rest();
        if (text[0] != '\\') return false;
        if (text.len < 2) return false;
        if (!std.ascii.isPunctuation(text[1])) return false;
        try writeEscaped(state.writer, text[1..2]);
        state.index += 2;
        return true;
    }

    /// `` `code` ``: the code as typed, with no markup or escapes inside. As in CommonMark, a run
    /// of backticks closes only at a run of the same length, so ``` ``a `b` c`` ``` holds
    /// backticks, and one space just inside each end is dropped. A run with no partner is text,
    /// whole, so no part of it opens code later.
    fn nextCode(state: *Inline) std.Io.Writer.Error!bool {
        const text = state.rest();
        if (text[0] != '`') return false;
        const run_len: u32 = @intCast(std.mem.indexOfNone(u8, text, "`") orelse text.len);
        // `text` opens with exactly `run_len` backticks, so the partner is the next such run.
        std.debug.assert(run_len == text.len or text[run_len] != '`');
        const close_start = backtickRunFind(text, run_len, run_len) orelse {
            try state.writer.writeAll(text[0..run_len]);
            state.index += run_len;
            return true;
        };
        std.debug.assert(close_start > run_len);
        std.debug.assert(close_start + run_len <= text.len);
        try state.writer.writeAll("<code>");
        try writeEscaped(state.writer, nextCodeTrim(text[run_len..close_start]));
        try state.writer.writeAll("</code>");
        state.index += close_start + run_len;
        return true;
    }

    /// Code with one space dropped from each end when both ends have one and it isn't all
    /// spaces, so `` `` `x` `` `` shows `` `x` ``.
    fn nextCodeTrim(code: []const u8) []const u8 {
        if (code.len < 2) return code;
        if (code[0] != ' ') return code;
        if (code[code.len - 1] != ' ') return code;
        if (std.mem.indexOfNone(u8, code, " ") == null) return code;
        return code[1 .. code.len - 1];
    }

    /// `[text](url)` with a web address: a link. The text is plain.
    fn nextLink(state: *Inline) std.Io.Writer.Error!bool {
        const text = state.rest();
        if (text[0] != '[') return false;
        const text_end = std.mem.indexOf(u8, text, "](") orelse return false;
        if (text_end == 1) return false;
        const url_start = text_end + 2;
        const url_len = nextLinkUrlLen(text[url_start..]) orelse return false;
        const url = text[url_start..][0..url_len];
        if (!nextLinkAllowed(url)) return false;

        try state.writer.writeAll("<a href=\"");
        try writeEscaped(state.writer, url);
        try state.writer.writeAll("\">");
        try writeEscaped(state.writer, text[1..text_end]);
        try state.writer.writeAll("</a>");
        state.index += @intCast(url_start + url_len + 1);
        return true;
    }

    /// `**`, `~~`, `*` or `_`: closes the innermost mark, opens a new one, or is text.
    fn nextMarker(state: *Inline) std.Io.Writer.Error!bool {
        const marker = markerAt(state.line, state.index) orelse return false;
        if (try state.nextMarkerClose(marker)) return true;
        if (try state.nextMarkerOpen(marker)) return true;
        try writeEscaped(state.writer, state.rest()[0..marker.len]);
        state.index += marker.len;
        return true;
    }

    /// Closes the innermost mark, if `marker` is its partner.
    fn nextMarkerClose(state: *Inline, marker: MarkerAt) std.Io.Writer.Error!bool {
        if (state.marks_open_count == 0) return false;
        const innermost = state.marks_open[state.marks_open_count - 1];
        if (innermost.mark != marker.mark) return false;
        if (innermost.byte != state.line[state.index]) return false;
        if (!markerCanClose(state.line, state.index, marker)) return false;
        try state.writer.print("</{s}>", .{marker.mark.tagName()});
        state.marks_open_count -= 1;
        state.index += marker.len;
        return true;
    }

    /// Opens a mark, if it isn't open already and a partner follows on the line.
    fn nextMarkerOpen(state: *Inline, marker: MarkerAt) std.Io.Writer.Error!bool {
        for (state.marks_open[0..state.marks_open_count]) |open| {
            if (open.mark == marker.mark) return false;
        }
        if (!state.nextMarkerOpenAllowed(marker)) return false;
        if (!state.nextMarkerOpenCloserAfter(marker)) return false;
        std.debug.assert(state.marks_open_count < mark_count);
        state.marks_open[state.marks_open_count] = .{
            .mark = marker.mark,
            .byte = state.line[state.index],
        };
        state.marks_open_count += 1;
        try state.writer.print("<{s}>", .{marker.mark.tagName()});
        state.index += marker.len;
        return true;
    }

    /// The marker at `index` opens if text follows it; `_` also needs no letter or digit before
    /// it, so `snake_case_name` stays as typed.
    fn nextMarkerOpenAllowed(state: *const Inline, marker: MarkerAt) bool {
        std.debug.assert(state.index < state.line.len);
        const after = state.index + marker.len;
        if (after == state.line.len) return false;
        if (std.ascii.isWhitespace(state.line[after])) return false;
        if (state.line[state.index] != '_') return true;
        if (state.index == 0) return true;
        return !std.ascii.isAlphanumeric(state.line[state.index - 1]);
    }

    /// Whether a partner for the marker at `index`, the same bytes and able to close, follows on
    /// the line. Quadratic per line at worst (`_a _a _a …`); the 16 KiB cap on what `send` takes
    /// keeps that near a tenth of a second.
    fn nextMarkerOpenCloserAfter(state: *const Inline, marker: MarkerAt) bool {
        std.debug.assert(state.index < state.line.len);
        var candidate: u32 = state.index + marker.len;
        while (candidate < state.line.len) : (candidate += 1) {
            const found = markerAt(state.line, candidate) orelse continue;
            if (found.mark != marker.mark) continue;
            if (state.line[candidate] != state.line[state.index]) continue;
            if (markerCanClose(state.line, candidate, found)) return true;
        }
        return false;
    }

    /// Plain text, up to the next byte that could start markup.
    fn nextText(state: *Inline) std.Io.Writer.Error!void {
        const text = state.rest();
        const run_len = std.mem.indexOfAny(u8, text[1..], inline_special) orelse text.len - 1;
        try writeEscaped(state.writer, text[0 .. run_len + 1]);
        state.index += @intCast(run_len + 1);
    }

    /// Closes the marks still open, innermost first.
    fn finish(state: *Inline) std.Io.Writer.Error!void {
        while (state.marks_open_count > 0) {
            state.marks_open_count -= 1;
            const open = state.marks_open[state.marks_open_count];
            try state.writer.print("</{s}>", .{open.mark.tagName()});
        }
    }
};

/// The marker at `line[index]`, if any: `**`, `~~`, `*` or `_`.
fn markerAt(line: []const u8, index: u32) ?MarkerAt {
    std.debug.assert(index < line.len);
    const text = line[index..];
    if (std.mem.startsWith(u8, text, "**")) return .{ .mark = .bold, .len = 2 };
    if (std.mem.startsWith(u8, text, "~~")) return .{ .mark = .strike, .len = 2 };
    if (text[0] == '*') return .{ .mark = .italic, .len = 1 };
    if (text[0] == '_') return .{ .mark = .italic, .len = 1 };
    return null;
}

/// A marker closes if text precedes it; `_` also needs no letter or digit after it.
fn markerCanClose(line: []const u8, index: u32, marker: MarkerAt) bool {
    std.debug.assert(index < line.len);
    if (index == 0) return false;
    if (std.ascii.isWhitespace(line[index - 1])) return false;
    if (line[index] != '_') return true;
    const after = index + marker.len;
    if (after == line.len) return true;
    return !std.ascii.isAlphanumeric(line[after]);
}

/// How long the address at the start of `text` is, up to the `)` that closes the link. Brackets
/// inside it pair up, as in `https://en.wikipedia.org/wiki/Foo_(bar)`. Null if nothing closes it.
fn nextLinkUrlLen(text: []const u8) ?u32 {
    var depth: u32 = 0;
    for (text, 0..) |byte, index| {
        if (byte == '(') depth += 1;
        if (byte != ')') continue;
        if (depth == 0) return @intCast(index);
        depth -= 1;
    }
    return null;
}

/// Web links only, with no spaces, so a typed `javascript:` or local path stays text.
fn nextLinkAllowed(url: []const u8) bool {
    if (std.mem.indexOfAny(u8, url, &std.ascii.whitespace) != null) return false;
    if (std.ascii.startsWithIgnoreCase(url, "https://")) return url.len > "https://".len;
    if (std.ascii.startsWithIgnoreCase(url, "http://")) return url.len > "http://".len;
    return false;
}

/// Writes text with `&`, `<`, `>` and `"` as entities.
fn writeEscaped(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    std.debug.assert(text.len <= std.math.maxInt(u32));
    var run_start: u32 = 0;
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
        run_start = @intCast(index + 1);
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
    try expectInline("``fake`", "``fake`");
}

test "writeInline closes code only at a backtick run of the same length" {
    try expectInline("```a `b` c```", "<code>a `b` c</code>");
    try expectInline("`` `fake` ``", "<code>`fake`</code>");
    // One space is dropped from each end only when both ends have one and it isn't all spaces.
    try expectInline("`  `", "<code>  </code>");
    try expectInline("` `", "<code> </code>");
    try expectInline("`` `a``", "<code> `a</code>");
    try expectInline("`a`", "<code>a</code>");
    try expectInline("`a\\`b`", "<code>a\\</code>b`");
    // A fenced snippet typed on one line, backslashes and all, stays one code span.
    const snippet = "just: ```send \"Fake\" \"**hi** \\`test\\`\"``` in markdown";
    try expectInline(snippet,
        \\just: <code>send &quot;Fake&quot; &quot;**hi** \`test\`&quot;</code> in markdown
    );
}

test "writeInline keeps backslash-escaped punctuation literal" {
    try expectInline("\\*fake\\* \\_ \\\\ \\a", "*fake* _ \\ \\a");
    try expectInline("\\<b\\>", "&lt;b&gt;");
}

test "writeInline closes marks left open by crossed markers" {
    try expectInline("**a _b** c_", "<b>a <i>b** c</i></b>");
}

test "writeInline closes italic only with the byte that opened it" {
    try expectInline("_a* b_", "<i>a* b</i>");
    try expectInline("*a_ b*", "<i>a_ b</i>");
}

test "writeInline writes web links and leaves others as text" {
    try expectInline("[fake](https://example.invalid/?a=1&b=\"2\")",
        \\<a href="https://example.invalid/?a=1&amp;b=&quot;2&quot;">fake</a>
    );
    try expectInline("[fake](javascript:alert(1))", "[fake](javascript:alert(1))");
    try expectInline("[fake](https://)", "[fake](https://)");
    try expectInline("[](https://example.invalid)", "[](https://example.invalid)");
    try expectInline("[fake](https://a b)", "[fake](https://a b)");
    try expectInline("[fake](https://example.invalid/Foo_(bar)) x",
        \\<a href="https://example.invalid/Foo_(bar)">fake</a> x
    );
    const unclosed = "[fake](https://example.invalid/(open";
    try expectInline(unclosed, unclosed);
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

test "writeMarkdown makes a code block from ``` anywhere on a line, as Teams does" {
    try expectMarkdown("```ls -la```\nfake", "<pre>ls -la</pre><p>fake</p>");
    try expectMarkdown("fake: ```ls -la``` after", "<p>fake:</p><pre>ls -la</pre><p>after</p>");
    try expectMarkdown("```zig\nfake\n```", "<pre>fake</pre>");
    try expectMarkdown("````\nfake\n````", "<pre>fake</pre>");
    try expectMarkdown("fake: ```\none\ntwo```\nafter",
        \\<p>fake:</p><pre>one
        \\two</pre><p>after</p>
    );
    try expectMarkdown("```\nfake\n``` after", "<pre>fake</pre><p>after</p>");
    try expectMarkdown("``two`` stays", "<p><code>two</code> stays</p>");
    // The owner's message, its lines joined by the shell: the snippet becomes a code block.
    const joined = "So cool: ```send \"Fake\" \"**hi** \\`test\\`\"```in markdown " ++
        "[link](https://example.invalid)";
    try expectMarkdown(joined, "<p>So cool:</p>" ++
        "<pre>send &quot;Fake&quot; &quot;**hi** \\`test\\`&quot;</pre>" ++
        "<p>in markdown <a href=\"https://example.invalid\">link</a></p>");
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
