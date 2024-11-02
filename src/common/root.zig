const std = @import("std");

pub const settings = @import("settings.zig");
pub const utility = @import("utility.zig");

test {
    _ = std.testing.refAllDeclsRecursive(@This());
}
