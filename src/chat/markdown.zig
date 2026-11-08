//! Writing message HTML as Markdown for a terminal.
//!
//! Every byte from the message goes through `writeVisible`; only the writer's own line breaks,
//! spaces and markers are written raw. Wherever a byte is dropped or collapsed (`\r`, the HTML's
//! own whitespace), the text is split there and each piece is written separately, so a control
//! character can't form across the gap.

const std = @import("std");
const html = @import("html.zig");
const writeVisible = @import("text.zig").writeVisible;

/// Writes `content`, a message's HTML, as Markdown. Blank lines at both ends are left out, and no
/// final line break is written.
pub fn writeHtml(writer: *std.Io.Writer, content: []const u8) std.Io.Writer.Error!void {
    var output: Output = .{ .writer = writer };
    var reader: html.Reader = .{ .rest = content };
    while (reader.next()) |token| switch (token) {
        .text => |run| try output.text(run),
        .entity => |replacement| try output.entity(replacement),
        .tag => |tag| try output.tag(&tag, reader.rest),
    };
    try output.finish();
}

/// Inline markup, as Markdown markers.
const Mark = enum {
    bold,
    italic,
    strike,
    code,
    link,

    /// The opening marker; for bold, italic and strike, the closing one too. Code's markers are
    /// backtick runs, written by `Output.writeMarker`.
    fn marker(mark: Mark) []const u8 {
        return switch (mark) {
            .bold => "**",
            .italic => "_",
            .strike => "~~",
            .code => unreachable,
            .link => "[",
        };
    }
};

/// The mark a tag opens or closes, or null for tags that aren't inline markup. Underline has
/// no Markdown form, so it stays plain.
fn tagMark(tag: *const html.Tag) ?Mark {
    for (mark_tags) |mark_tag| {
        if (tag.is(mark_tag[0])) return mark_tag[1];
    }
    return null;
}

const mark_tags = [_]struct { []const u8, Mark }{
    .{ "b", .bold },
    .{ "strong", .bold },
    .{ "i", .italic },
    .{ "em", .italic },
    .{ "s", .strike },
    .{ "strike", .strike },
    .{ "del", .strike },
    .{ "code", .code },
    .{ "a", .link },
};

/// The output so far, as far as what comes next depends on it.
const Output = struct {
    writer: *std.Io.Writer,
    /// Nothing written yet, so line breaks owed are dropped.
    at_start: bool = true,
    /// The current line holds text.
    line_has_text: bool = false,
    /// Line breaks owed before the next text: a new line, or a blank line, which holds the quotes
    /// open when it was owed. A quote that opens after it doesn't prefix it, so the blank line
    /// before a quote stays outside it.
    breaks_pending: union(enum) { none, line, blank: u8 } = .none,
    /// A space owed before the next text on this line, from collapsed whitespace.
    space_pending: bool = false,
    /// The latest paragraph or div opened has held no text yet.
    block_empty: bool = false,
    /// The open marks, in the order they opened; each appears once.
    marks_open: [mark_count]Mark = undefined,
    marks_open_count: u8 = 0,
    /// The open marks whose opener is written. The others wait for text, so markup around
    /// nothing writes nothing and spaces at its edges stay outside it.
    marks_written: std.EnumSet(Mark) = .empty,
    /// The open link's target, still entity-encoded, borrowed from the content.
    link_href: []const u8 = "",
    /// How many backticks fence the open code: one more than its longest run, so none inside
    /// ends it early.
    code_ticks: u8 = 1,
    /// How many quotes are open; lines show at most `quote_depth_limit` of them.
    quote_depth: u8 = 0,
    /// The open lists, outermost first; only the first `list_depth_limit` are kept.
    lists: [list_depth_limit]List = undefined,
    /// How many lists are open, counting those deeper than `list_depth_limit`.
    list_depth: u8 = 0,
    /// The next line starts a list item, so it gets the item's marker.
    item_starting: bool = false,
    /// The next line starts a heading of this level (1 to 3).
    heading_starting: ?u2 = null,
    /// Inside `<pre>`: text is written as it is, line by line, inside a fence.
    code_block: ?CodeBlock = null,

    const CodeBlock = struct {
        /// The current line holds code.
        line_has_text: bool = false,
        /// No text yet, so a newline right after `<pre>` is dropped, as in HTML.
        empty: bool = true,
    };

    const List = struct {
        ordered: bool,
        item_count: u16 = 0,

        /// How wide this list's marker is for its current item: `- ` or `12. `.
        fn markerWidth(list: *const List) u8 {
            if (!list.ordered) return 2;
            // A u16 has at most 5 digits.
            const digit_count: u8 = @intCast(std.fmt.count("{d}", .{list.item_count}));
            return digit_count + 2;
        }
    };

    const mark_count = std.enums.values(Mark).len;

    /// HTML text: runs of whitespace collapse to one space, and `\r` goes with them. A word that
    /// starts a line and would read as a Markdown block marker gets a `\` (see `textEscapeIndex`).
    fn text(output: *Output, run: []const u8) std.Io.Writer.Error!void {
        std.debug.assert(run.len > 0);
        if (output.code_block != null) return output.textCode(run);
        if (std.mem.indexOfScalar(u8, html_whitespace, run[0]) != null) output.space_pending = true;
        var words = std.mem.tokenizeAny(u8, run, html_whitespace);
        while (words.next()) |word| {
            const escape_index = if (output.startsLine()) textEscapeIndex(word) else null;
            try output.flush();
            if (escape_index) |index| {
                // The split falls before an ASCII marker byte, so no control character forms
                // across it.
                try writeVisible(output.writer, word[0..index]);
                try output.writer.writeByte('\\');
                try writeVisible(output.writer, word[index..]);
            } else {
                try writeVisible(output.writer, word);
            }
            output.wroteText();
            // A word followed by whitespace owes a space.
            output.space_pending = words.index < run.len;
        }
    }

    /// A decoded entity. `&nbsp;` counts as whitespace; the rest are text.
    fn entity(output: *Output, replacement: []const u8) std.Io.Writer.Error!void {
        if (output.code_block != null) {
            try output.writer.writeAll(replacement);
            output.wroteCode();
            return;
        }
        if (std.mem.eql(u8, replacement, " ")) {
            output.space_pending = true;
            return;
        }
        // Asked before `flush`, which writes the line's prefix. `&gt;` starting a line would read
        // as a quote.
        const starts_line = output.startsLine();
        try output.flush();
        if (starts_line) {
            if (std.mem.eql(u8, replacement, ">")) try output.writer.writeByte('\\');
        }
        try output.writer.writeAll(replacement);
        output.wroteText();
    }

    /// The next text starts its line, with only the line's prefix before it: no text and no
    /// marker that `flush` would write.
    fn startsLine(output: *const Output) bool {
        if (output.line_has_text) return false;
        return output.marks_open_count == 0;
    }

    fn wroteText(output: *Output) void {
        output.line_has_text = true;
        output.block_empty = false;
    }

    /// `after` is the HTML after the tag.
    fn tag(
        output: *Output,
        html_tag: *const html.Tag,
        after: []const u8,
    ) std.Io.Writer.Error!void {
        if (output.code_block != null) {
            // Inside a code block only its end and line breaks count; markup is dropped.
            if (html_tag.is("pre")) {
                if (html_tag.closing) return output.closeCodeBlock();
                return;
            }
            if (html_tag.is("br")) return output.codeNewline();
            return;
        }
        if (tagMark(html_tag)) |mark| {
            if (html_tag.closing) return output.closeMark(mark);
            return output.tagMarkOpen(html_tag, mark, after);
        }
        if (html_tag.closing) return output.tagClose(html_tag);
        return output.tagOpen(html_tag);
    }

    fn tagOpen(output: *Output, html_tag: *const html.Tag) std.Io.Writer.Error!void {
        if (html_tag.is("pre")) return output.tagOpenCodeBlock();
        if (html_tag.is("br")) return output.tagOpenLineBreak();
        if (html_tag.is("img")) return output.tagOpenImage(html_tag);
        if (headingLevel(html_tag)) |level| {
            try output.endLine();
            output.heading_starting = level;
            return;
        }
        if (html_tag.is("blockquote")) return output.tagOpenQuote();
        if (html_tag.is("ul")) return output.tagOpenList(false);
        if (html_tag.is("ol")) return output.tagOpenList(true);
        if (html_tag.is("li")) return output.tagOpenItem();
        if (html_tag.is("p")) return output.tagOpenBlock();
        if (html_tag.is("div")) return output.tagOpenBlock();
    }

    fn tagClose(output: *Output, html_tag: *const html.Tag) std.Io.Writer.Error!void {
        if (headingLevel(html_tag) != null) {
            try output.endLine();
            // An empty heading marks nothing after it.
            output.heading_starting = null;
            return;
        }
        if (html_tag.is("blockquote")) return output.tagCloseQuote();
        if (html_tag.is("ul")) return output.tagCloseList();
        if (html_tag.is("ol")) return output.tagCloseList();
        if (html_tag.is("li")) return output.endLine();
        if (html_tag.is("p")) return output.tagCloseBlock();
        if (html_tag.is("div")) return output.tagCloseBlock();
    }

    /// `p` and `div` start a line.
    fn tagOpenBlock(output: *Output) std.Io.Writer.Error!void {
        output.block_empty = true;
        try output.endLine();
    }

    /// A block that held no text, like `<p>&nbsp;</p>`, is a blank line.
    fn tagCloseBlock(output: *Output) std.Io.Writer.Error!void {
        if (output.block_empty) {
            output.block_empty = false;
            return output.blankLine();
        }
        try output.endLine();
    }

    fn tagMarkOpen(output: *Output, html_tag: *const html.Tag, mark: Mark, after: []const u8) void {
        if (output.markIndex(mark) != null) return;
        std.debug.assert(output.marks_open_count < mark_count);
        output.marks_open[output.marks_open_count] = mark;
        output.marks_open_count += 1;
        switch (mark) {
            .link => output.link_href = html_tag.attribute("href") orelse "",
            .code => output.code_ticks = tagMarkOpenCodeTicks(after),
            else => {},
        }
    }

    fn closeMark(output: *Output, mark: Mark) std.Io.Writer.Error!void {
        const index = output.markIndex(mark) orelse {
            // Only open marks are ever written.
            std.debug.assert(!output.marks_written.contains(mark));
            return;
        };
        const open = output.marks_open[0..output.marks_open_count];
        std.mem.copyForwards(Mark, open[index..], open[index + 1 ..]);
        output.marks_open_count -= 1;

        if (!output.marks_written.contains(mark)) return;
        output.marks_written.remove(mark);
        if (mark != .link) return output.writeMarker(mark, .closing);
        try output.writer.writeAll("](");
        try html.writeDecoded(output.writer, output.link_href);
        try output.writer.writeByte(')');
    }

    /// Where `mark` is in `marks_open`, or null if it isn't open.
    fn markIndex(output: *const Output, mark: Mark) ?u8 {
        const open = output.marks_open[0..output.marks_open_count];
        const index = std.mem.indexOfScalar(Mark, open, mark) orelse return null;
        return @intCast(index);
    }

    /// Ends the current line if it holds text. Written marks close here, newest first, and
    /// reopen with the next text, since Markdown markup doesn't span lines. A link stays open.
    fn endLine(output: *Output) std.Io.Writer.Error!void {
        if (!output.line_has_text) return;
        var index = output.marks_open_count;
        while (index > 0) {
            index -= 1;
            const mark = output.marks_open[index];
            if (mark == .link) continue;
            if (!output.marks_written.contains(mark)) continue;
            try output.writeMarker(mark, .closing);
            output.marks_written.remove(mark);
        }
        // A blank line already owed stays owed.
        if (output.breaks_pending == .none) output.breaks_pending = .line;
        output.line_has_text = false;
        output.space_pending = false;
    }

    /// Quotes start on their own line and end with a blank one, since Markdown would otherwise
    /// carry the quote on into the next line.
    fn tagOpenQuote(output: *Output) std.Io.Writer.Error!void {
        try output.endLine();
        output.quote_depth +|= 1;
    }

    fn tagCloseQuote(output: *Output) std.Io.Writer.Error!void {
        try output.endLine();
        if (output.quote_depth == 0) return;
        output.quote_depth -= 1;
        output.blankLine();
    }

    /// An emoji is its `alt` text, which holds the emoji itself; any other image is `[image]`.
    fn tagOpenImage(output: *Output, html_tag: *const html.Tag) std.Io.Writer.Error!void {
        const item_type = html_tag.attribute("itemtype") orelse "";
        if (std.mem.endsWith(u8, item_type, "/Emoji")) {
            const alt = html_tag.attribute("alt") orelse "";
            if (alt.len == 0) return;
            try output.flush();
            try html.writeDecoded(output.writer, alt);
        } else {
            try output.flush();
            try output.writer.writeAll("[image]");
        }
        output.wroteText();
    }

    /// A code block starts on its own line with a fence; its text follows on the next.
    fn tagOpenCodeBlock(output: *Output) std.Io.Writer.Error!void {
        try output.endLine();
        try output.flush();
        try output.writer.writeAll("```\n");
        try output.writeLinePrefix();
        output.code_block = .{};
    }

    fn closeCodeBlock(output: *Output) std.Io.Writer.Error!void {
        if (output.code_block.?.line_has_text) {
            try output.writer.writeByte('\n');
            try output.writeLinePrefix();
        }
        try output.writer.writeAll("```");
        output.code_block = null;
        output.line_has_text = true;
        try output.endLine();
    }

    /// Code keeps its spaces and line breaks. `\r` is dropped, splitting the text there.
    fn textCode(output: *Output, run: []const u8) std.Io.Writer.Error!void {
        var rest = run;
        while (rest.len > 0) {
            const end = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
            if (end > 0) {
                try writeVisible(output.writer, rest[0..end]);
                output.wroteCode();
            }
            if (end == rest.len) return;
            if (rest[end] == '\n') try output.codeNewline();
            rest = rest[end + 1 ..];
        }
    }

    fn codeNewline(output: *Output) std.Io.Writer.Error!void {
        if (output.code_block.?.empty) {
            output.code_block.?.empty = false;
            return;
        }
        try output.writer.writeByte('\n');
        try output.writeLinePrefix();
        output.code_block.?.line_has_text = false;
    }

    fn wroteCode(output: *Output) void {
        output.code_block.?.line_has_text = true;
        output.code_block.?.empty = false;
    }

    /// Lists start on their own line; the outermost ends with a blank line, since Markdown
    /// would otherwise carry its last item on into the next line.
    fn tagOpenList(output: *Output, ordered: bool) std.Io.Writer.Error!void {
        try output.endListLine();
        if (output.list_depth < list_depth_limit) {
            output.lists[output.list_depth] = .{ .ordered = ordered };
        }
        output.list_depth +|= 1;
    }

    fn tagCloseList(output: *Output) std.Io.Writer.Error!void {
        try output.endListLine();
        if (output.list_depth == 0) return;
        output.list_depth -= 1;
        if (output.list_depth == 0) output.blankLine();
    }

    /// Ends the line before a list starts or ends. An item that held nothing leaves no marker
    /// for the line after its list.
    fn endListLine(output: *Output) std.Io.Writer.Error!void {
        try output.endLine();
        output.item_starting = false;
    }

    fn tagOpenItem(output: *Output) std.Io.Writer.Error!void {
        try output.endLine();
        if (output.list_depth == 0) return;
        const shown = @min(output.list_depth, list_depth_limit);
        output.lists[shown - 1].item_count +|= 1;
        output.item_starting = true;
    }

    /// Writes the start of a line: `> ` for each quote shown, then the list indent, with the
    /// item's marker on an item's first line, then a heading's `#` marks.
    fn writeLinePrefix(output: *Output) std.Io.Writer.Error!void {
        try output.writeQuotes(output.quote_depth, "> ");
        try output.writeLinePrefixList();
        if (output.heading_starting) |level| {
            std.debug.assert(level >= 1);
            try output.writer.splatByteAll('#', level);
            try output.writer.writeByte(' ');
            output.heading_starting = null;
        }
    }

    /// Writes `> ` for each quote shown, with `last` for the innermost.
    fn writeQuotes(output: *Output, depth: u8, last: []const u8) std.Io.Writer.Error!void {
        const quote_depth = @min(depth, quote_depth_limit);
        if (quote_depth == 0) return;
        try output.writer.splatBytesAll("> ", quote_depth - 1);
        try output.writer.writeAll(last);
    }

    fn writeLinePrefixList(output: *Output) std.Io.Writer.Error!void {
        const list_depth = @min(output.list_depth, list_depth_limit);
        if (list_depth == 0) return;
        for (output.lists[0 .. list_depth - 1]) |*outer| {
            try output.writer.splatByteAll(' ', outer.markerWidth());
        }
        const inner = &output.lists[list_depth - 1];
        if (!output.item_starting) return output.writer.splatByteAll(' ', inner.markerWidth());
        output.item_starting = false;
        if (inner.ordered) return output.writer.print("{d}. ", .{inner.item_count});
        try output.writer.writeAll("- ");
    }

    /// Closes what the HTML left open: a code block, then marks, newest first.
    fn finish(output: *Output) std.Io.Writer.Error!void {
        if (output.code_block != null) try output.closeCodeBlock();
        while (output.marks_open_count > 0) {
            const mark = output.marks_open[output.marks_open_count - 1];
            try output.closeMark(mark);
        }
        std.debug.assert(output.marks_written.count() == 0);
    }

    /// `<br>`: ends a line with text, or turns an empty one into a blank line.
    fn tagOpenLineBreak(output: *Output) std.Io.Writer.Error!void {
        if (output.line_has_text) return output.endLine();
        output.blankLine();
    }

    fn blankLine(output: *Output) void {
        output.breaks_pending = .{ .blank = output.quote_depth };
        output.space_pending = false;
    }

    /// Writes the line breaks or space owed before the next text, with each new line's prefix.
    fn flushSpacing(output: *Output) std.Io.Writer.Error!void {
        defer output.space_pending = false;
        if (output.at_start) {
            output.at_start = false;
            output.breaks_pending = .none;
            return output.writeLinePrefix();
        }
        switch (output.breaks_pending) {
            .none => {},
            .line => {
                try output.writer.writeByte('\n');
                output.breaks_pending = .none;
                return output.writeLinePrefix();
            },
            .blank => |blank_quote_depth| {
                // A blank line inside quotes holds only them, the last as a bare `>`.
                const depth = @min(blank_quote_depth, output.quote_depth);
                try output.writer.writeByte('\n');
                try output.writeQuotes(depth, ">");
                try output.writer.writeByte('\n');
                output.breaks_pending = .none;
                return output.writeLinePrefix();
            },
        }
        if (!output.space_pending) return;
        // Spaces at a line's start are dropped.
        if (output.line_has_text) try output.writer.writeByte(' ');
    }

    /// Writes what's owed before the next text: line breaks or a space, then pending openers.
    fn flush(output: *Output) std.Io.Writer.Error!void {
        try output.flushSpacing();
        for (output.marks_open[0..output.marks_open_count]) |mark| {
            if (output.marks_written.contains(mark)) continue;
            try output.writeMarker(mark, .opening);
            output.marks_written.insert(mark);
        }
    }

    /// Code with a backtick inside gets a space inside each end of its run, which Markdown drops,
    /// so a backtick at the code's edge doesn't join the run.
    fn writeMarker(
        output: *Output,
        mark: Mark,
        side: enum { opening, closing },
    ) std.Io.Writer.Error!void {
        // A link's closer carries its target, so `closeMark` writes it.
        std.debug.assert(!(mark == .link and side == .closing));
        if (mark != .code) return output.writer.writeAll(mark.marker());
        std.debug.assert(output.code_ticks >= 1);
        std.debug.assert(output.code_ticks <= code_ticks_max);
        const padded = output.code_ticks > 1;
        if (padded and side == .closing) try output.writer.writeByte(' ');
        try output.writer.splatByteAll('`', output.code_ticks);
        if (padded and side == .opening) try output.writer.writeByte(' ');
    }
};

/// Where a `\` goes so that `word`, starting a line, reads as text rather than a Markdown block
/// marker; null if it can't read as one. Catches quotes (`>`), fences (`` ``` ``, `~~~`),
/// headings, bullets, rules and underlines (a word of one repeated `#`, `-`, `*`, `+`, `_` or
/// `=`), and numbered items (`1.`, `2)`). Over-escaping is harmless: `\` before punctuation
/// reads as the punctuation.
fn textEscapeIndex(word: []const u8) ?u32 {
    std.debug.assert(word.len > 0);
    if (word[0] == '>') return 0;
    if (std.mem.startsWith(u8, word, "```")) return 0;
    if (std.mem.startsWith(u8, word, "~~~")) return 0;
    if (std.mem.indexOfScalar(u8, "#-*+_=", word[0]) != null) {
        if (std.mem.indexOfNone(u8, word, word[0..1]) == null) return 0;
        return null;
    }
    const digit_count = std.mem.indexOfNone(u8, word, "0123456789") orelse return null;
    if (digit_count == 0) return null;
    if (digit_count + 1 != word.len) return null;
    // A number marker is short; anything this long is just text.
    if (digit_count > 9) return null;
    const marker = word[digit_count];
    if (marker == '.') return @intCast(digit_count);
    if (marker == ')') return @intCast(digit_count);
    return null;
}

/// The Markdown level of `h1`, `h2` or `h3`, or null for any other tag. Smaller headings are
/// shown as plain lines.
fn headingLevel(tag: *const html.Tag) ?u2 {
    if (tag.is("h1")) return 1;
    if (tag.is("h2")) return 2;
    if (tag.is("h3")) return 3;
    return null;
}

/// The backticks fencing code that starts `after`, the HTML after its `<code>`: one more than
/// the longest run before its `</code>`, or the end. No entity decodes to a backtick, so the raw
/// HTML holds them all.
fn tagMarkOpenCodeTicks(after: []const u8) u8 {
    const code_end = std.ascii.findIgnoreCase(after, "</code") orelse after.len;
    var run_len_max: usize = 0;
    var run_len: usize = 0;
    for (after[0..code_end]) |byte| {
        run_len = if (byte == '`') run_len + 1 else 0;
        run_len_max = @max(run_len_max, run_len);
    }
    // A run of three or more at a line's start isn't a fence: Markdown forbids backticks after
    // a fence's opener, and the closing run is on the same line.
    // Nobody types a longer run; past it, the code shows ambiguous, nothing worse.
    return @intCast(@min(run_len_max, code_ticks_max - 1) + 1);
}

/// The most backticks written around code.
const code_ticks_max = 16;

/// Deeper quotes are shown at this depth.
const quote_depth_limit = 8;

/// Deeper lists are shown at this depth.
const list_depth_limit = 8;

/// What HTML collapses as whitespace, with `\r` among it so carriage returns are dropped.
const html_whitespace = " \t\n\r\x0c";

fn expectMarkdown(content: []const u8, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeHtml(&out.writer, content);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "writeHtml collapses the HTML's whitespace and drops carriage returns" {
    try expectMarkdown("<p>fake   words\r\n  here\t&nbsp; too</p>", "fake words here too");
    try expectMarkdown("fake<b>joined</b>  <i>spaced</i>", "fake**joined** _spaced_");
}

test "writeHtml starts a line per paragraph, break and div" {
    try expectMarkdown("<p>fake one</p>\r\n<p>fake two</p>", "fake one\nfake two");
    try expectMarkdown("fake one<br>fake two<br/>fake three", "fake one\nfake two\nfake three");
    try expectMarkdown("<div>fake one</div><div><p>fake two</p></div>", "fake one\nfake two");
    const nested = "<div><p>fake one</p></div><div><p>fake two</p></div>";
    try expectMarkdown(nested, "fake one\nfake two");
}

test "writeHtml keeps one blank line for empty paragraphs and doubled breaks" {
    const spaced = "<p>fake one</p><p>&nbsp;</p><p>&nbsp;</p><p>fake two</p>";
    try expectMarkdown(spaced, "fake one\n\nfake two");
    try expectMarkdown("fake one<br><br><br>fake two", "fake one\n\nfake two");
}

test "writeHtml trims blank lines and spaces at both ends and at line starts" {
    try expectMarkdown("<p>&nbsp;</p><br><p>   fake   </p><p>&nbsp;</p><br>", "fake");
    try expectMarkdown("<p>fake one</p><p>    fake indented</p>", "fake one\nfake indented");
}

test "writeHtml keeps control bytes escaped where a byte was dropped" {
    try expectMarkdown("<p>\xc2\r\x9b[2J</p>", "\\xc2 \x9b[2J");
    try expectMarkdown("<p>\xc2\n\x9b[2J</p>", "\\xc2 \x9b[2J");
    try expectMarkdown("<p>\xc2<br>\x9b[2J</p>", "\\xc2\n\x9b[2J");
    try expectMarkdown("<p>fake\x1b[2J</p>", "fake\\x1b[2J");
}

test "writeHtml decodes entities and drops unknown tags" {
    try expectMarkdown("<span>fake &lt;b&gt; &amp; &#39;x&#39;</span><zz>", "fake <b> & 'x'");
}

test "writeHtml writes bold, italic, strike and code markers" {
    const emphasis = "<b>fake</b> <strong>bold</strong> <i>it</i> <em>em</em>";
    try expectMarkdown(emphasis, "**fake** **bold** _it_ _em_");
    const other = "<s>gone</s> <del>gone</del> <code>x = 1</code> <u>plain</u>";
    try expectMarkdown(other, "~~gone~~ ~~gone~~ `x = 1` plain");
}

test "writeHtml fences code holding backticks with a longer run" {
    try expectMarkdown("<code>a`b</code>", "`` a`b ``");
    try expectMarkdown("<code>`fake`</code> x", "`` `fake` `` x");
    try expectMarkdown("<code>a ``` b</code> <code>c</code>", "```` a ``` b ```` `c`");
    try expectMarkdown("<code>x</code> <code>a``b</code>", "`x` ``` a``b ```");
    try expectMarkdown("<code>a`b<br>c</code>", "`` a`b ``\n`` c ``");
}

test "writeHtml leaves out markup around nothing and keeps edge spaces outside markers" {
    try expectMarkdown("fake<b></b> <i> </i>text", "fake text");
    try expectMarkdown("fake<b> bold </b>text", "fake **bold** text");
}

test "writeHtml nests markers and closes them across a line break" {
    try expectMarkdown("<i><b>fake</b></i>", "_**fake**_");
    try expectMarkdown("<b>fake one<br>fake two</b>", "**fake one**\n**fake two**");
    try expectMarkdown("<b>fake <i>never closed", "**fake _never closed_**");
}

test "writeHtml writes links with their target decoded and visible" {
    const link = "see <a href=\"https://x/?a=1&amp;b=2\">fake</a>";
    try expectMarkdown(link, "see [fake](https://x/?a=1&b=2)");
    try expectMarkdown("<a href=\"https://x/\x1b[2J\">fake</a>", "[fake](https://x/\\x1b[2J)");
    try expectMarkdown("<a href=\"https://x/\"></a>fake", "fake");
}

test "writeHtml quotes every line of a blockquote, and ends the quote with a blank line" {
    try expectMarkdown("<blockquote><p>fake one</p><p>fake two</p></blockquote><p>after</p>",
        \\> fake one
        \\> fake two
        \\
        \\after
    );
    const spaced = "<blockquote>fake one<br><br>fake two</blockquote>";
    try expectMarkdown(spaced, "> fake one\n>\n> fake two");
}

test "writeHtml quotes a reply the way Teams sends it" {
    try expectMarkdown(
        \\<blockquote itemscope="" itemtype="http://schema.skype.com/Reply" itemid="1">
        \\<strong itemprop="mri" itemid="8:orgid:fake">Fake Person</strong>
        \\<span itemprop="time" itemid="1"></span>
        \\<p itemprop="preview">fake earlier words</p></blockquote><p>fake answer</p>
    ,
        \\> **Fake Person**
        \\> fake earlier words
        \\
        \\fake answer
    );
}

test "writeHtml nests quotes up to its limit and survives unbalanced ones" {
    const nested = "<blockquote>a<blockquote>b</blockquote>c</blockquote>";
    try expectMarkdown(nested, "> a\n> > b\n>\n> c");
    var deep: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer deep.deinit();
    var shown: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer shown.deinit();
    for (0..quote_depth_limit + 4) |_| try deep.writer.writeAll("<blockquote>");
    try deep.writer.writeAll("fake");
    for (0..quote_depth_limit) |_| try shown.writer.writeAll("> ");
    try shown.writer.writeAll("fake");
    try expectMarkdown(deep.written(), shown.written());
    try expectMarkdown("</blockquote>fake</blockquote>", "fake");
}

test "writeHtml writes bulleted and numbered lists" {
    try expectMarkdown("<p>fake</p><ul><li>one</li><li>two</li></ul><p>after</p>",
        \\fake
        \\- one
        \\- two
        \\
        \\after
    );
    try expectMarkdown("<ol><li>one</li><li>two<br>more</li></ol>", "1. one\n2. two\n   more");
}

test "writeHtml indents nested lists by their parents' markers" {
    try expectMarkdown("<ol><li>one<ul><li>inner</li></ul></li><li>two</li></ol>",
        \\1. one
        \\   - inner
        \\2. two
    );
}

test "writeHtml quotes a list inside a quote" {
    const quoted = "<blockquote><ul><li>one</li><li>two</li></ul></blockquote>";
    try expectMarkdown(quoted, "> - one\n> - two");
}

test "writeHtml shows lists deeper than its limit at the limit, and survives stray tags" {
    var deep: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer deep.deinit();
    for (0..list_depth_limit + 3) |_| try deep.writer.writeAll("<ul><li>");
    try deep.writer.writeAll("fake");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeHtml(&out.writer, deep.written());
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "- fake"));

    try expectMarkdown("</ul><li>fake</li></ol>", "fake");
}

test "writeHtml fences code blocks and keeps their spacing" {
    try expectMarkdown("<p>fake</p><pre><code>if (x) {\n    y();\n}</code></pre><p>after</p>",
        \\fake
        \\```
        \\if (x) {
        \\    y();
        \\}
        \\```
        \\after
    );
    try expectMarkdown("<pre>\none<br>  <b>two</b>\n</pre>", "```\none\n  two\n```");
}

test "writeHtml quotes a code block inside a quote" {
    try expectMarkdown("<blockquote><pre>a\r\nb</pre></blockquote>", "> ```\n> a\n> b\n> ```");
}

test "writeHtml keeps control bytes escaped in code blocks and closes an unclosed one" {
    try expectMarkdown("<pre>\xc2\r\x9b[2J\x1b</pre>", "```\n\\xc2\x9b[2J\\x1b\n```");
    try expectMarkdown("<pre>fake", "```\nfake\n```");
}

test "writeHtml writes headings on their own lines" {
    const headings = "fake<h2>Fake heading</h2><p>after</p><h3>Small</h3>";
    try expectMarkdown(headings, "fake\n## Fake heading\nafter\n### Small");
}

test "writeHtml writes an emoji as its alt text and other images as [image]" {
    const smile = "\u{1F604}";
    const emoji = "<span title=\"Smile\" type=\"(smile)\"><img itemscope=\"\" " ++
        "itemtype=\"http://schema.skype.com/Emoji\" itemid=\"smile\" src=\"https://x/s.png\" " ++
        "title=\"Smile\" alt=\"" ++ smile ++ "\" style=\"width:20px\"></span>";
    try expectMarkdown("fake " ++ emoji ++ " done", "fake " ++ smile ++ " done");

    const pasted = "<p>see<img itemtype=\"http://schema.skype.com/AMSImage\" src=\"x\"></p>";
    try expectMarkdown(pasted, "see[image]");
    try expectMarkdown("<img itemtype=\"x/Emoji\" alt=\"\x1b[2J\">", "\\x1b[2J");
}

test "writeHtml forgets an empty heading or list item" {
    try expectMarkdown("<h2></h2><p>fake</p>", "fake");
    try expectMarkdown("<ul><li>a<ul><li></li></ul>b</li></ul>", "- a\n  b");
}

test "writeHtml escapes typed text that would start a Markdown block" {
    try expectMarkdown("<p># fake</p><p>- fake</p><p>* fake</p><p>+ fake</p>",
        \\\# fake
        \\\- fake
        \\\* fake
        \\\+ fake
    );
    try expectMarkdown("<p>&gt; fake</p><p>&gt;fake</p><p>12. fake</p><p>3) fake</p>",
        \\\> fake
        \\\>fake
        \\12\. fake
        \\3\) fake
    );
    try expectMarkdown("<p>```fake</p><p>~~~</p><p>---</p><p>===</p><p>## fake</p>",
        \\\```fake
        \\\~~~
        \\\---
        \\\===
        \\\## fake
    );
}

test "writeHtml escapes after a line's prefix, and only at a line's start" {
    try expectMarkdown("<ul><li># fake</li></ul><blockquote>- fake</blockquote>",
        \\- \# fake
        \\
        \\> \- fake
    );
    try expectMarkdown("<p>fake # - 1. &gt; ```</p>", "fake # - 1. > ```");
    try expectMarkdown("<p><b># fake</b></p>", "**# fake**");
    try expectMarkdown("<p>#fake -fake 1.5 1.fake</p>", "#fake -fake 1.5 1.fake");
    // CommonMark reads at most nine digits as a list number.
    try expectMarkdown("<p>123456789. fake</p>", "123456789\\. fake");
    try expectMarkdown("<p>1234567890. fake</p>", "1234567890. fake");
    try expectMarkdown("<pre># fake</pre>", "```\n# fake\n```");
}

test "writeHtml keeps the blank line before a quote outside it" {
    try expectMarkdown("<ul><li>fake</li></ul><blockquote>fake quote</blockquote>",
        \\- fake
        \\
        \\> fake quote
    );
    const nested = "<blockquote><blockquote>fake quote</blockquote></blockquote>";
    try expectMarkdown("<p>fake</p><p>&nbsp;</p>" ++ nested,
        \\fake
        \\
        \\> > fake quote
    );
    const spaced = "<blockquote><p>fake one</p><p>&nbsp;</p><p>fake two</p></blockquote>";
    try expectMarkdown(spaced,
        \\> fake one
        \\>
        \\> fake two
    );
}
