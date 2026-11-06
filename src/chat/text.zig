//! Writing text that came from other people to a terminal.

const std = @import("std");

/// Writes `bytes`, showing control bytes as `\xNN` so text from the service can't send terminal
/// escape sequences (retitling the window, writing the clipboard, redrawing earlier lines).
/// Newlines and tabs pass through.
pub fn writeVisible(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    var run_start: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (isVisible(byte)) continue;

        try writer.writeAll(bytes[run_start..index]);
        try writer.print("\\x{x:0>2}", .{byte});
        run_start = index + 1;
    }
    try writer.writeAll(bytes[run_start..]);
}

fn isVisible(byte: u8) bool {
    if (byte == '\n') return true;
    if (byte == '\t') return true;
    if (byte == 0x7f) return false;
    return byte >= 0x20;
}

test "writeVisible shows control bytes and keeps text, newlines and tabs" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeVisible(&out.writer, "fake \x1b]52;c;aGk=\x07 hi\tthere\nbye\x7f");
    try std.testing.expectEqualStrings(
        "fake \\x1b]52;c;aGk=\\x07 hi\tthere\nbye\\x7f",
        out.written(),
    );
}

test "writeVisible passes UTF-8 through unchanged" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeVisible(&out.writer, "café ✓");
    try std.testing.expectEqualStrings("café ✓", out.written());
}
