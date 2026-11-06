const std = @import("std");

/// Parsed values that own the arena holding them and every string they point into.
pub fn Owned(comptime T: type) type {
    return struct {
        const Self = @This();

        arena: *std.heap.ArenaAllocator,
        items: []const T,

        /// Starts empty: allocate the items in `arena`, then set `items`.
        pub fn init(gpa: std.mem.Allocator) error{OutOfMemory}!Self {
            const arena = try gpa.create(std.heap.ArenaAllocator);
            arena.* = .init(gpa);
            return .{ .arena = arena, .items = &.{} };
        }

        pub fn deinit(owned: *const Self) void {
            const gpa = owned.arena.child_allocator;
            owned.arena.deinit();
            gpa.destroy(owned.arena);
        }
    };
}

test "deinit frees the arena and everything in it" {
    var owned: Owned(u8) = try .init(std.testing.allocator);
    defer owned.deinit();

    owned.items = try owned.arena.allocator().dupe(u8, "fake");
    try std.testing.expectEqualStrings("fake", owned.items);
}
