const std = @import("std");

test "passed test" {
    try std.testing.expect(true);
}

test "failed test" {
    try std.testing.expect(false);
}

test "skipped test" {
    return error.SkipZigTest;
}
