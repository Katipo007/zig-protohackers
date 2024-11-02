const std = @import("std");

/// Returns the index of the first element in `items` greater than or equal to `key`,
/// or `items.len` if all elements are less than `key`.
///
/// `items` must be sorted in ascending order with respect to `compareFn`.
///
/// O(log n) complexity.
///
/// We use this, because the current Zig implementation doesn't work correctly when key is not the same type as T.
///    https://github.com/ziglang/zig/issues/20110
pub fn lower_bound(
    comptime T: type,
    key: anytype,
    items: []const T,
    context: anytype,
    comptime compare_fn: fn (context: @TypeOf(context), key: @TypeOf(key), mid_item: T) std.math.Order,
) usize {
    var left: usize = 0;
    var right: usize = items.len;

    while (left < right) {
        const mid = left + (right - left) / 2;
        if (compare_fn(context, key, items[mid]) == .gt) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }

    return left;
}

test lower_bound {
    const testing = std.testing;

    const S = struct {
        fn compare_u32(_: void, lhs: u32, rhs: u32) std.math.Order {
            return std.math.order(lhs, rhs);
        }
        fn compare_i32(_: void, lhs: i32, rhs: i32) std.math.Order {
            return std.math.order(lhs, rhs);
        }
        fn compare_f32(_: void, lhs: f32, rhs: f32) std.math.Order {
            return std.math.order(lhs, rhs);
        }
    };

    try testing.expectEqual(
        @as(usize, 0),
        lower_bound(u32, @as(u32, 0), &[_]u32{}, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 0),
        lower_bound(u32, @as(u32, 0), &[_]u32{ 2, 4, 8, 16, 32, 64 }, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 0),
        lower_bound(u32, @as(u32, 2), &[_]u32{ 2, 4, 8, 16, 32, 64 }, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 2),
        lower_bound(u32, @as(u32, 5), &[_]u32{ 2, 4, 8, 16, 32, 64 }, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 2),
        lower_bound(u32, @as(u32, 8), &[_]u32{ 2, 4, 8, 16, 32, 64 }, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 6),
        lower_bound(u32, @as(u32, 8), &[_]u32{ 2, 4, 7, 7, 7, 7, 16, 32, 64 }, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 2),
        lower_bound(u32, @as(u32, 8), &[_]u32{ 2, 4, 8, 8, 8, 8, 16, 32, 64 }, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 5),
        lower_bound(u32, @as(u32, 64), &[_]u32{ 2, 4, 8, 16, 32, 64 }, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 6),
        lower_bound(u32, @as(u32, 100), &[_]u32{ 2, 4, 8, 16, 32, 64 }, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 2),
        lower_bound(i32, @as(i32, 5), &[_]i32{ 2, 4, 8, 16, 32, 64 }, {}, S.compare_i32),
    );
    try testing.expectEqual(
        @as(usize, 1),
        lower_bound(f32, @as(f32, -33.4), &[_]f32{ -54.2, -26.7, 0.0, 56.55, 100.1, 322.0 }, {}, S.compare_f32),
    );

    {
        const R = struct {
            b: i32,

            fn r(b: i32) @This() {
                return @This(){ .b = b };
            }

            fn compareFn(_: void, key: i32, mid_item: @This()) std.math.Order {
                return std.math.order(key, mid_item.b);
            }
        };
        const rs = [_]R{ R.r(-100), R.r(-40), R.r(-10), R.r(30) };
        try testing.expectEqual(2, lower_bound(R, @as(i32, -20), &rs, {}, R.compareFn));
    }
}

/// Returns the index of the first element in `items` greater than `key`,
/// or `items.len` if all elements are less than or equal to `key`.
///
/// `items` must be sorted in ascending order with respect to `compareFn`.
///
/// O(log n) complexity.
///
/// We use this, because the current Zig implementation doesn't work correctly when key is not the same type as T.
///   https://github.com/ziglang/zig/issues/20110
pub fn upper_bound(
    comptime T: type,
    key: anytype,
    items: []const T,
    context: anytype,
    comptime compare_fn: fn (context: @TypeOf(context), key: @TypeOf(key), mid_item: T) std.math.Order,
) usize {
    var left: usize = 0;
    var right: usize = items.len;

    while (left < right) {
        const mid = left + (right - left) / 2;
        if (compare_fn(context, key, items[mid]) != .lt) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }

    return left;
}

test upper_bound {
    const testing = std.testing;

    const S = struct {
        fn compare_u32(_: void, lhs: u32, rhs: u32) std.math.Order {
            return std.math.order(lhs, rhs);
        }
        fn compare_i32(_: void, lhs: i32, rhs: i32) std.math.Order {
            return std.math.order(lhs, rhs);
        }
        fn compare_f32(_: void, lhs: f32, rhs: f32) std.math.Order {
            return std.math.order(lhs, rhs);
        }
    };

    try testing.expectEqual(
        @as(usize, 0),
        upper_bound(u32, @as(u32, 0), &[_]u32{}, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 0),
        upper_bound(u32, @as(u32, 0), &[_]u32{ 2, 4, 8, 16, 32, 64 }, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 1),
        upper_bound(u32, @as(u32, 2), &[_]u32{ 2, 4, 8, 16, 32, 64 }, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 2),
        upper_bound(u32, @as(u32, 5), &[_]u32{ 2, 4, 8, 16, 32, 64 }, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 6),
        upper_bound(u32, @as(u32, 8), &[_]u32{ 2, 4, 7, 7, 7, 7, 16, 32, 64 }, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 6),
        upper_bound(u32, @as(u32, 8), &[_]u32{ 2, 4, 8, 8, 8, 8, 16, 32, 64 }, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 3),
        upper_bound(u32, @as(u32, 8), &[_]u32{ 2, 4, 8, 16, 32, 64 }, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 6),
        upper_bound(u32, @as(u32, 64), &[_]u32{ 2, 4, 8, 16, 32, 64 }, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 6),
        upper_bound(u32, @as(u32, 100), &[_]u32{ 2, 4, 8, 16, 32, 64 }, {}, S.compare_u32),
    );
    try testing.expectEqual(
        @as(usize, 2),
        upper_bound(i32, @as(i32, 5), &[_]i32{ 2, 4, 8, 16, 32, 64 }, {}, S.compare_i32),
    );
    try testing.expectEqual(
        @as(usize, 1),
        upper_bound(f32, @as(f32, -33.4), &[_]f32{ -54.2, -26.7, 0.0, 56.55, 100.1, 322.0 }, {}, S.compare_f32),
    );
}
