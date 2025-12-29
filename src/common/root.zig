const std = @import("std");

pub const config = @import("config");
pub const utility = @import("utility.zig");

test {
    _ = std.testing.refAllDeclsRecursive(@This());
}
