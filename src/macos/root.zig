pub const core_foundation = @import("core_foundation.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
