const std = @import("std");

pub fn moveIndex(_index: usize, move: i64, _max: usize, wrap: bool) usize {
    std.debug.assert(_max != 0);

    const index = @intCast(i64, _index);
    const max = @intCast(i64, _max);

    if (wrap) {
        return @intCast(usize, @mod(@mod(index + move, max) + max, max));
    } else {
        return @intCast(usize, std.math.max(0, std.math.min(index + move, max - 1)));
    }
}

test "moveIndex" {
    std.testing.expectEqual(@as(usize, 1), moveIndex(0, 1, 3, true));
    std.testing.expectEqual(@as(usize, 2), moveIndex(0, 2, 3, true));
    std.testing.expectEqual(@as(usize, 0), moveIndex(0, 3, 3, true));
    std.testing.expectEqual(@as(usize, 1), moveIndex(0, 4, 3, true));

    std.testing.expectEqual(@as(usize, 1), moveIndex(2, -1, 3, true));
    std.testing.expectEqual(@as(usize, 0), moveIndex(2, -2, 3, true));
    std.testing.expectEqual(@as(usize, 2), moveIndex(2, -3, 3, true));
    std.testing.expectEqual(@as(usize, 1), moveIndex(2, -4, 3, true));

    std.testing.expectEqual(@as(usize, 1), moveIndex(0, 1, 3, false));
    std.testing.expectEqual(@as(usize, 2), moveIndex(0, 2, 3, false));
    std.testing.expectEqual(@as(usize, 2), moveIndex(0, 3, 3, false));
    std.testing.expectEqual(@as(usize, 2), moveIndex(0, 4, 3, false));

    std.testing.expectEqual(@as(usize, 1), moveIndex(2, -1, 3, false));
    std.testing.expectEqual(@as(usize, 0), moveIndex(2, -2, 3, false));
    std.testing.expectEqual(@as(usize, 0), moveIndex(2, -3, 3, false));
    std.testing.expectEqual(@as(usize, 0), moveIndex(2, -4, 3, false));
}
