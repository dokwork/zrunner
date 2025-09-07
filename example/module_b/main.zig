const std = @import("std");

test "passed test with memory leak" {
    _ = try std.testing.allocator.alloc(u8, 8);
    try std.testing.expectEqual(4, 2 + 2);
}

test "failed test with memory leak" {
    _ = try std.testing.allocator.alloc(u8, 8);
    try std.testing.expectEqual(5, 2 + 2);
}
