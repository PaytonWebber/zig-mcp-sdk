const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mcp_mod = b.addModule("zig_mcp_sdk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const greeter = addExample(b, "greeter", "examples/greeter.zig", mcp_mod, target, optimize);
    const greeter_http = addExample(b, "greeter_http", "examples/greeter_http.zig", mcp_mod, target, optimize);
    const channel = addExample(b, "channel", "examples/channel.zig", mcp_mod, target, optimize);

    // Keep the default build useful for CI and releases without installing
    // example binaries as package artifacts.
    b.default_step.dependOn(&greeter.step);
    b.default_step.dependOn(&greeter_http.step);
    b.default_step.dependOn(&channel.step);

    addRunStep(b, "example", "Build and run the greeter example", greeter);
    addRunStep(b, "example-http", "Build and run the HTTP greeter example", greeter_http);
    addRunStep(b, "example-channel", "Build and run the channel example", channel);

    const examples_step = b.step("examples", "Install example binaries to zig-out/bin");
    examples_step.dependOn(&b.addInstallArtifact(greeter, .{}).step);
    examples_step.dependOn(&b.addInstallArtifact(greeter_http, .{}).step);
    examples_step.dependOn(&b.addInstallArtifact(channel, .{}).step);

    const mod_tests = b.addTest(.{ .root_module = mcp_mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "src", "examples" },
        .check = true,
    });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const docs_obj = b.addObject(.{ .name = "zig_mcp_sdk", .root_module = mcp_mod });
    const docs_step = b.step("docs", "Generate API documentation into zig-out/docs");
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);

    const check_step = b.step("check", "Run tests, format checks, and compile examples");
    check_step.dependOn(test_step);
    check_step.dependOn(&fmt.step);
    check_step.dependOn(&greeter.step);
    check_step.dependOn(&greeter_http.step);
    check_step.dependOn(&channel.step);
}

fn addExample(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    mcp_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zig_mcp_sdk", .module = mcp_mod }},
        }),
    });
}

fn addRunStep(
    b: *std.Build,
    step_name: []const u8,
    description: []const u8,
    exe: *std.Build.Step.Compile,
) void {
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const step = b.step(step_name, description);
    step.dependOn(&run_cmd.step);
}
