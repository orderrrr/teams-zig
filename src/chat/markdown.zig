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
    var reader: html.Reader = .init(content);
    while (reader.next()) |token| switch (token) {
        .text => |run| try output.text(run),
        .entity => |replacement| try output.entity(replacement),
        .tag => |tag| try output.tag(&tag),
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

    /// The opening marker; for all but links, the closing one too.
    fn marker(mark: Mark) []const u8 {
        return switch (mark) {
            .bold => "**",
            .italic => "_",
            .strike => "~~",
            .code => "`",
            .link => "[",
        };
    }
};

const MarkState = enum { closed, pending, written };

/// The mark a tag opens or closes, or null for tags that aren't inline markup. Underline has
/// no Markdown form, so it stays plain.
fn markOf(tag: *const html.Tag) ?Mark {
    if (tag.is("b") or tag.is("strong")) return .bold;
    if (tag.is("i") or tag.is("em")) return .italic;
    if (tag.is("s") or tag.is("strike") or tag.is("del")) return .strike;
    if (tag.is("code")) return .code;
    if (tag.is("a")) return .link;
    return null;
}

/// The output so far, as far as what comes next depends on it.
const Output = struct {
    writer: *std.Io.Writer,
    /// Nothing written yet, so line breaks owed are dropped.
    at_start: bool = true,
    /// The current line holds text.
    line_has_text: bool = false,
    /// Line breaks owed before the next text: 1 starts a new line, 2 leaves a blank line.
    breaks_pending: u2 = 0,
    /// A space owed before the next text on this line, from collapsed whitespace.
    space_pending: bool = false,
    /// The latest paragraph or div opened has held no text yet.
    block_empty: bool = false,
    /// Each mark's state. A pending mark's opener waits for text, so markup around nothing
    /// writes nothing and spaces at its edges stay outside it.
    marks: std.EnumArray(Mark, MarkState) = .initFill(.closed),
    /// The open marks, pending or written, in the order they opened; each appears once.
    marks_open: [mark_count]Mark = undefined,
    marks_open_count: u8 = 0,
    /// The open link's target, still entity-encoded, borrowed from the content.
    link_href: []const u8 = "",
    /// How many quotes are open; lines show at most `quote_depth_limit` of them.
    quote_depth: u8 = 0,

    const mark_count = std.enums.values(Mark).len;

    /// HTML text: runs of whitespace collapse to one space, and `\r` goes with them.
    fn text(output: *Output, run: []const u8) std.Io.Writer.Error!void {
        std.debug.assert(run.len > 0);
        if (std.mem.indexOfScalar(u8, html_whitespace, run[0]) != null) output.space_pending = true;
        var words = std.mem.tokenizeAny(u8, run, html_whitespace);
        while (words.next()) |word| {
            try output.flush();
            try writeVisible(output.writer, word);
            output.wroteText();
            // A word followed by whitespace owes a space.
            output.space_pending = words.index < run.len;
        }
    }

    /// A decoded entity. `&nbsp;` counts as whitespace; the rest are text.
    fn entity(output: *Output, replacement: []const u8) std.Io.Writer.Error!void {
        if (std.mem.eql(u8, replacement, " ")) {
            output.space_pending = true;
            return;
        }
        try output.flush();
        try output.writer.writeAll(replacement);
        output.wroteText();
    }

    fn wroteText(output: *Output) void {
        output.line_has_text = true;
        output.block_empty = false;
    }

    fn tag(output: *Output, html_tag: *const html.Tag) std.Io.Writer.Error!void {
        if (markOf(html_tag)) |mark| {
            if (html_tag.closing) return output.closeMark(mark);
            if (mark == .link) output.link_href = html_tag.attribute("href") orelse "";
            return output.openMark(mark);
        }
        if (html_tag.is("br")) return output.lineBreak();
        if (html_tag.is("blockquote")) return output.quote(html_tag.closing);
        if (html_tag.is("p") or html_tag.is("div")) {
            if (!html_tag.closing) {
                output.block_empty = true;
                return output.endLine();
            }
            // A block that held no text, like `<p>&nbsp;</p>`, is a blank line.
            if (output.block_empty) {
                output.block_empty = false;
                return output.blankLine();
            }
            return output.endLine();
        }
    }

    fn openMark(output: *Output, mark: Mark) void {
        if (output.marks.get(mark) != .closed) return;
        output.marks.set(mark, .pending);
        std.debug.assert(output.marks_open_count < mark_count);
        output.marks_open[output.marks_open_count] = mark;
        output.marks_open_count += 1;
    }

    fn closeMark(output: *Output, mark: Mark) std.Io.Writer.Error!void {
        const state = output.marks.get(mark);
        if (state == .closed) return;
        output.marks.set(mark, .closed);

        const open = output.marks_open[0..output.marks_open_count];
        const index = std.mem.indexOfScalar(Mark, open, mark).?;
        std.mem.copyForwards(Mark, open[index..], open[index + 1 ..]);
        output.marks_open_count -= 1;

        if (state == .written) try output.writeCloser(mark);
    }

    fn writeCloser(output: *Output, mark: Mark) std.Io.Writer.Error!void {
        if (mark != .link) return output.writer.writeAll(mark.marker());
        try output.writer.writeAll("](");
        try html.writeDecoded(output.writer, output.link_href);
        try output.writer.writeByte(')');
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
            if (output.marks.get(mark) != .written) continue;
            try output.writer.writeAll(mark.marker());
            output.marks.set(mark, .pending);
        }
        output.breaks_pending = @max(output.breaks_pending, 1);
        output.line_has_text = false;
        output.space_pending = false;
    }

    /// Quotes start on their own line and end with a blank one, since Markdown would otherwise
    /// carry the quote on into the next line.
    fn quote(output: *Output, closing: bool) std.Io.Writer.Error!void {
        try output.endLine();
        if (closing) {
            if (output.quote_depth == 0) return;
            output.quote_depth -= 1;
            output.blankLine();
            return;
        }
        output.quote_depth +|= 1;
    }

    /// Writes the start of a line: `> ` for each quote shown. A blank line inside a quote is a
    /// bare `>`.
    fn writeLinePrefix(output: *Output, blank: bool) std.Io.Writer.Error!void {
        const depth = @min(output.quote_depth, quote_depth_limit);
        for (0..depth) |level| {
            const last = level + 1 == depth;
            try output.writer.writeAll(if (blank and last) ">" else "> ");
        }
    }

    /// Closes the marks the HTML left open, newest first.
    fn finish(output: *Output) std.Io.Writer.Error!void {
        while (output.marks_open_count > 0) {
            const mark = output.marks_open[output.marks_open_count - 1];
            try output.closeMark(mark);
        }
    }

    /// `<br>`: ends a line with text, or turns an empty one into a blank line.
    fn lineBreak(output: *Output) std.Io.Writer.Error!void {
        if (output.line_has_text) return output.endLine();
        output.blankLine();
    }

    fn blankLine(output: *Output) void {
        output.breaks_pending = 2;
        output.space_pending = false;
    }

    /// Writes what's owed before the next text: line breaks or a space, then pending openers.
    fn flush(output: *Output) std.Io.Writer.Error!void {
        if (output.at_start) {
            output.at_start = false;
            output.breaks_pending = 0;
            try output.writeLinePrefix(false);
        } else if (output.breaks_pending > 0) {
            try output.writer.writeByte('\n');
            if (output.breaks_pending == 2) {
                try output.writeLinePrefix(true);
                try output.writer.writeByte('\n');
            }
            output.breaks_pending = 0;
            try output.writeLinePrefix(false);
        } else if (output.space_pending and output.line_has_text) {
            try output.writer.writeByte(' ');
        }
        output.space_pending = false;

        for (output.marks_open[0..output.marks_open_count]) |mark| {
            if (output.marks.get(mark) != .pending) continue;
            try output.writer.writeAll(mark.marker());
            output.marks.set(mark, .written);
        }
    }
};

/// Deeper quotes are shown at this depth.
const quote_depth_limit = 8;

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
