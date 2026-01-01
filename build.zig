pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const config = b.addOptions();
    config.addOption([]const u8, "listen_address", b.option([]const u8, "listen-address", "") orelse "0.0.0.0");
    config.addOption(u16, "listen_port", b.option(u16, "listen-port", "") orelse 37619);

    const step_check = b.step("check", "Check that the project compiles");
    const step_test = b.step("test", "Run tests");

    const mod_config = config.createModule();

    const mod_common = b.addModule("common", .{
        .root_source_file = b.path("src/common/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "config", .module = mod_config },
        },
    });

    const test_common = b.addTest(.{
        .name = "common-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/common/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    step_test.dependOn(&b.addRunArtifact(test_common).step);

    // ------------- EXECUTABLES -------------

    const context = Context{
        .common_module = mod_common,
        .target = target,
        .optimize = optimize,
        .check_step = step_check,
        .tests_step = step_test,
    };

    _ = try add_problem_executable(b, &context, "problem-0", b.path("src/problem-0/main.zig"));
    _ = try add_problem_executable(b, &context, "problem-1", b.path("src/problem-1/main.zig"));
    _ = try add_problem_executable(b, &context, "problem-2", b.path("src/problem-2/main.zig"));
    _ = try add_problem_executable(b, &context, "problem-3", b.path("src/problem-3/main.zig"));
}

const std = @import("std");

const Context = struct {
    common_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    check_step: *std.Build.Step,
    tests_step: *std.Build.Step,
};

fn add_problem_executable(
    b: *std.Build,
    context: *const Context,
    comptime name: []const u8,
    root_file: std.Build.LazyPath,
) !*std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = root_file,
            .target = context.target,
            .optimize = context.optimize,
        }),
    });
    exe.root_module.addImport("common", context.common_module);
    b.installArtifact(exe);

    context.check_step.dependOn(&exe.step);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run-" ++ name, "Run the '" ++ name ++ "' executable");
    run_step.dependOn(&run_exe.step);

    return exe;
}
