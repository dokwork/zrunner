const std = @import("std");

test "passed test" {
    try std.testing.expectEqual(4, 2 + 2);
}

test "failed test" {
    try std.testing.expectEqual(5, 2 + 2);
}

test "skipped test" {
    return error.SkipZigTest;
}
