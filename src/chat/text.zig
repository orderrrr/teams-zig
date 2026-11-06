//! Writing text that came from other people to a terminal.

const std = @import("std");

/// Writes `bytes`, showing control characters as `\xNN` so text from the service can't send
/// terminal escape sequences (retitling the window, writing the clipboard, redrawing earlier
/// lines). That covers C0 controls and DEL, and C1 controls in their UTF-8 form (`C2 80`..`C2 9F`),
/// which some terminals obey too. Newlines and tabs pass through.
pub fn writeVisible(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    var run_start: usize = 0;
    var index: usize = 0;
    while (index < bytes.len) {
        const control_len = controlLenAt(bytes[index..]);
        if (control_len == 0) {
            index += 1;
            continue;
        }

        try writer.writeAll(bytes[run_start..index]);
        for (bytes[index..][0..control_len]) |byte| try writer.print("\\x{x:0>2}", .{byte});
        index += control_len;
        run_start = index;
    }
    try writer.writeAll(bytes[run_start..]);
}

/// How many bytes of control character `rest` starts with: 0 for none, 1 for C0 or DEL, 2 for a
/// UTF-8-encoded C1 control.
fn controlLenAt(rest: []const u8) usize {
    std.debug.assert(rest.len > 0);
    if (!isVisible(rest[0])) return 1;
    if (rest[0] != 0xc2) return 0;
    if (rest.len < 2) return 0;
    if (rest[1] < 0x80) return 0;
    if (rest[1] > 0x9f) return 0;
    return 2;
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

test "writeVisible shows UTF-8 C1 controls and keeps other two-byte characters" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeVisible(&out.writer, "fake \xc2\x9b2J \xc2\xa9 é");
    try std.testing.expectEqualStrings("fake \\xc2\\x9b2J \xc2\xa9 é", out.written());
}
