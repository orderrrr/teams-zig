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
        .tag => |tag| output.tag(&tag),
    };
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

    /// HTML text: runs of whitespace collapse to one space, and `\r` goes with them.
    fn text(output: *Output, run: []const u8) std.Io.Writer.Error!void {
        var words = std.mem.tokenizeAny(u8, run, html_whitespace);
        if (std.mem.indexOfAny(u8, run[0..1], html_whitespace) != null) output.space_pending = true;
        while (words.next()) |word| {
            try output.flush();
            try writeVisible(output.writer, word);
            output.line_has_text = true;
            output.block_empty = false;
            // A word followed by whitespace owes a space, unless the run ends with it and the
            // next run brings its own.
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
        output.line_has_text = true;
        output.block_empty = false;
    }

    fn tag(output: *Output, html_tag: *const html.Tag) void {
        if (html_tag.is("br")) return output.lineBreak();
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

    /// Ends the current line if it holds text.
    fn endLine(output: *Output) void {
        if (!output.line_has_text) return;
        output.breaks_pending = @max(output.breaks_pending, 1);
        output.line_has_text = false;
        output.space_pending = false;
    }

    /// `<br>`: ends a line with text, or turns an empty one into a blank line.
    fn lineBreak(output: *Output) void {
        if (output.line_has_text) return output.endLine();
        output.blankLine();
    }

    fn blankLine(output: *Output) void {
        output.breaks_pending = 2;
        output.space_pending = false;
    }

    /// Writes the line breaks and space owed before the next text.
    fn flush(output: *Output) std.Io.Writer.Error!void {
        if (output.at_start) {
            output.at_start = false;
            output.breaks_pending = 0;
            output.space_pending = false;
            return;
        }
        if (output.breaks_pending > 0) {
            try output.writer.splatByteAll('\n', output.breaks_pending);
            output.breaks_pending = 0;
            output.space_pending = false;
            return;
        }
        if (output.space_pending and output.line_has_text) try output.writer.writeByte(' ');
        output.space_pending = false;
    }
};

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
    try expectMarkdown("fake<b>joined</b>  <i>spaced</i>", "fakejoined spaced");
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
