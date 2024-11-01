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
        .root_source_file = root_file,
        .target = context.target,
        .optimize = context.optimize,
    });
    exe.root_module.addImport("common", context.common_module);
    b.installArtifact(exe);

    context.check_step.dependOn(&exe.step);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run-" ++ name, "Run the '" ++ name ++ "' executable");
    run_step.dependOn(&run_exe.step);

    return exe;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ------------- MODULES -------------

    const common_module = b.addModule("common", .{
        .root_source_file = b.path("src/common/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ------------ COMMON STEPS -------------

    const check_step = b.step("check", "Check that the project compiles");
    const tests_step = b.step("run-tests", "Run tests");

    // ------------- EXECUTABLES -------------

    const context = Context{
        .common_module = common_module,
        .target = target,
        .optimize = optimize,
        .check_step = check_step,
        .tests_step = tests_step,
    };

    _ = try add_problem_executable(b, &context, "problem-0", b.path("src/problem-0/main.zig"));
    _ = try add_problem_executable(b, &context, "problem-1", b.path("src/problem-1/main.zig"));
}
