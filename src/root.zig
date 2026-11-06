pub const macos = @import("macos/root.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
