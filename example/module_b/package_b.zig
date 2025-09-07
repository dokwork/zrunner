const std = @import("std");

test "passed test with memory leak" {
    _ = try std.testing.allocator.alloc(u8, 8);
    try std.testing.expect(true);
}

test "failed test with memory leak" {
    _ = try std.testing.allocator.alloc(u8, 8);
    try std.testing.expect(false);
}
