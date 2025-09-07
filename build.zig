const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const module_a = b.addModule("module_a", .{
        .root_source_file = b.path("example/module_a/main.zig"),
        .target = target,
    });
    const module_b = b.addModule("module_b", .{
        .root_source_file = b.path("example/module_b/main.zig"),
        .target = target,
    });

    // Prepare our zrunner
    const test_runner = std.Build.Step.Compile.TestRunner{
        .path = b.path("zrunner.zig"),
        .mode = .simple,
    };

    const tests_module_a = b.addTest(.{
        .name = "module_a", // this name is used in the report
        .root_module = module_a,
        .test_runner = test_runner, // use our runner
    });
    const run_module_a_tests = b.addRunArtifact(tests_module_a);
    // this forces using colors in some cases when they would be omitted otherwise
    run_module_a_tests.setEnvironmentVariable("CLICOLOR_FORCE", "true");

    const tests_module_b = b.addTest(.{
        .name = "module_b", // this name is used in the report
        .root_module = module_b,
        .test_runner = test_runner, // use our runner
    });
    const run_module_b_tests = b.addRunArtifact(tests_module_b);
    // this forces using colors in some cases when they would be omitted otherwise
    run_module_b_tests.setEnvironmentVariable("CLICOLOR_FORCE", "true");

    // This is very important configuration!
    // Without it the test runner is not able to handle arguments.
    if (b.args) |args| {
        run_module_a_tests.addArgs(args);
        run_module_b_tests.addArgs(args);
    }

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_module_a_tests.step);
    test_step.dependOn(&run_module_b_tests.step);
}
