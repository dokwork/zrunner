//! zrunner - is a simple test runner for zig with detailed report
//!           and support of selective running tests in modules.
//!
//! Usage:
//!
//!   If the build step to run tests is named "test":
//!   zig build test -- [options]
//!
//! Options:
//!
//!   -m <str>, --modules-only=<str>    Run only tests from modules whose names contain a given substring <str>.
//!   -t <str>, --tests-only=<str>      Run only tests  whose names contain a given substring <str>.
//!   --failed-only                     Include in the report only failed tests.
//!   --no-stack-trace                  Do not print a stack trace of failed tests.
//!   --colors=<zon>                    Parses <zon> as `FileReporter.Colors` and uses them printing test report.
//!                                     See the source code of `FileReporter.Colors` for more details.
//!   --no-colors                       Do not use ascii escape code to make output colorful.
//!                                     Ignore the '--colors' option.
//!   --stdout                          Print output to the stdout. Default.
//!   --stderr                          Print output to the stderr.
//!   --file=<file path>                Create and open a file <file path> to print an output to it.
//!
//! Configuration example:
//! ```zig
//!   // Prepare zrunner
//!   const test_runner = std.Build.Step.Compile.TestRunner{
//!       .path = b.path("zrunner.zig"),
//!       .mode = .simple,
//!   };
//!   const tests_module = b.addTest(.{
//!       .name = "my module", // this name is used in the test report
//!       .root_module = my_module,
//!       .test_runner = test_runner,
//!   });
//!   const run_module_tests = b.addRunArtifact(tests_module);
//!   // this forces using colors in some cases when they would be omitted otherwise
//!   run_module_tests.setEnvironmentVariable("CLICOLOR_FORCE", "true");
//! ```
//!
//! Version: 1.0.0
//!
const std = @import("std");
const builtin = @import("builtin");
const TestFn = std.builtin.TestFn;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer if (gpa.deinit() == .leak) unreachable;

    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const process_name = args.next() orelse unreachable;
    const module_name = std.fs.path.basename(process_name);

    // Parse arguments and prepare a reporter
    var io_buffer: [2048]u8 = undefined;
    var custom_colors: ?[:0]const u8 = null;
    var custom_out: ?std.fs.File.Writer = null;
    var module_filter: ?[:0]const u8 = null;
    var test_filter: ?[:0]const u8 = null;
    var failed_only: bool = false;
    var no_colors: bool = false;
    var no_stack_trace: bool = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, "-t", arg)) {
            test_filter = args.next();
        } else if (std.mem.startsWith(u8, arg, "--tests-only=")) {
            test_filter = arg[13..];
        } else if (std.mem.eql(u8, "-m", arg)) {
            module_filter = args.next();
        } else if (std.mem.startsWith(u8, arg, "--modules-only=")) {
            module_filter = arg[15..];
        } else if (std.mem.eql(u8, arg, "--failed-only")) {
            failed_only = true;
        } else if (std.mem.eql(u8, arg, "--no-stack-trace")) {
            no_stack_trace = true;
        } else if (std.mem.eql(u8, arg, "--no-colors")) {
            no_colors = true;
        } else if (std.mem.startsWith(u8, arg, "--colors=")) {
            custom_colors = arg[9..];
        } else if (std.mem.eql(u8, arg, "--stdout")) {
            custom_out = std.fs.File.stdout().writer(&io_buffer);
        } else if (std.mem.eql(u8, arg, "--stderr")) {
            custom_out = std.fs.File.stderr().writer(&io_buffer);
        } else if (std.mem.startsWith(u8, arg, "--file=")) {
            const file = try std.fs.cwd().createFile(arg[7..], .{ .truncate = false });
            custom_out = std.fs.File.writer(file, &io_buffer);
        } else {
            std.debug.print("Unsupported option '{s}'.\n", .{arg});
            std.process.exit(1);
        }
    }

    if (module_filter) |filter| {
        if (!std.mem.containsAtLeast(u8, module_name, 1, filter)) {
            // break the process
            return;
        }
    }

    var diag: std.zon.parse.Diagnostics = .{};
    const colors: FileReporter.Colors = if (custom_colors) |str|
        std.zon.parse.fromSlice(FileReporter.Colors, arena.allocator(), str, &diag, .{ .free_on_error = false }) catch |err| {
            std.debug.panic("Error {t} on parse colors: {f}", .{ err, diag });
        }
    else
        .default;

    var reporter: FileReporter = if (custom_out) |out|
        .{ .file_writer = out, .config = std.io.tty.Config.detect(out.file), .colors = colors }
    else
        .stdout(&io_buffer, colors);

    if (no_colors) {
        reporter.config = .no_color;
    }

    try run(&arena, process_name, test_filter, &reporter, failed_only, no_stack_trace);
}

pub fn run(
    arena: *std.heap.ArenaAllocator,
    process_name: []const u8,
    test_filter: ?[]const u8,
    reporter: anytype,
    failed_only: bool,
    no_stack_trace: bool,
) !void {
    var arena_alloc = arena.allocator();
    var tests: []const TestFn = builtin.test_functions;

    // Filter tests:
    if (test_filter) |filter| {
        var arr = try arena_alloc.alloc(TestFn, tests.len);
        arr.len = 0;
        for (builtin.test_functions) |tst| {
            if (std.mem.containsAtLeast(u8, tst.name, 1, filter)) {
                arr.len += 1;
                arr[arr.len - 1] = tst;
            }
        }
        tests = arr;
    }

    var report = Report{
        .process_name = process_name,
        .test_results = try arena.allocator().alloc(TestResult, tests.len),
    };

    try reporter.writeTitle(report.process_name, test_filter, tests.len);
    try runTests(arena, tests, &report, no_stack_trace);
    try writeTestResults(arena, reporter, report, failed_only);
    try reporter.writeSummary(
        report.passed_count,
        report.failed_count,
        report.skipped_count,
        report.total_duration,
        report.is_mem_leak,
    );
    if (report.failed_count != 0 or report.is_mem_leak) std.process.exit(1);
}

fn runTests(arena: *std.heap.ArenaAllocator, tests: []const TestFn, report: *Report, no_stack_trace: bool) !void {
    if (tests.len == 0) return;

    var total_timer: std.time.Timer = try std.time.Timer.start();
    var test_timer: std.time.Timer = try std.time.Timer.start();
    for (tests, 0..) |test_fn, idx| {
        const t = Test.wrap(test_fn);

        // Run tests:
        report.test_results[idx] = try t.run(arena, &test_timer, no_stack_trace);

        switch (report.test_results[idx]) {
            .passed => {
                report.passed_count += 1;
            },
            .failed => {
                report.failed_count += 1;
            },
            .skipped => {
                report.skipped_count += 1;
            },
        }
        report.is_mem_leak = report.is_mem_leak or report.test_results[idx].isMemoryLeak();
    }
    report.total_duration = Duration.fromNanos(total_timer.lap());
}

fn writeTestResults(
    arena: *std.heap.ArenaAllocator,
    reporter: anytype,
    report: Report,
    failed_only: bool,
) !void {
    const alloc = arena.allocator();
    var grouped_tests: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(TestResult)) = .empty;
    for (report.test_results) |test_result| {
        if (failed_only and test_result != .failed) continue;

        const gop = try grouped_tests.getOrPut(alloc, test_result.@"test"().namespace);
        if (gop.found_existing) {
            try gop.value_ptr.append(alloc, test_result);
        } else {
            gop.value_ptr.* = .empty;
            try gop.value_ptr.append(alloc, test_result);
        }
    }

    var itr = grouped_tests.iterator();
    while (itr.next()) |group| {
        try reporter.writeNamespace(group.key_ptr.*);
        for (group.value_ptr.items) |test_result| {
            try reporter.writeTestName(test_result.@"test"().name);
            try reporter.writeTestResult(test_result);
        }
    }
}

/// Meta information about a single test
const Test = struct {
    /// A name of the test
    name: []const u8 = undefined,
    /// A full name of the namespace, where the test is created
    namespace: []const u8 = undefined,
    /// A builtin test representation
    test_fn: TestFn,

    pub fn wrap(test_fn: TestFn) Test {
        var instance: Test = .{ .test_fn = test_fn };
        // Split a full name of a test in two parts:
        //  1. a namespace of the test;
        //  2. a name of the test.
        //
        // Possible templates of full test name are expected:
        //  - "<namespace>.test.<test name>"
        //  - "<namespace>.decltest.<test name>"
        const names = if (std.mem.indexOf(u8, test_fn.name, ".test.")) |idx|
            .{ test_fn.name[0..idx], test_fn.name[idx + 6 ..] }
        else if (std.mem.indexOf(u8, test_fn.name, ".decltest.")) |idx|
            .{ test_fn.name[0..idx], test_fn.name[idx + 10 ..] }
        else
            .{ "", test_fn.name };
        instance.namespace = names[0];
        instance.name = names[1];
        return instance;
    }

    /// Runs the test and builds the result. Marks a test thrown the error.SkipZigTest as skipped.
    fn run(self: Test, arena: *std.heap.ArenaAllocator, timer: *std.time.Timer, no_stack_trace: bool) !TestResult {
        var test_result: TestResult = undefined;
        timer.reset();
        const result = self.test_fn.func();
        const duration = Duration.fromNanos(timer.read());

        const is_mem_leak = (std.testing.allocator_instance.deinit() == .leak);
        std.testing.allocator_instance = .{};

        if (result) |_| {
            test_result = .{
                .passed = .{ .@"test" = self, .duration = duration, .is_mem_leak = is_mem_leak },
            };
        } else |err| switch (err) {
            error.SkipZigTest => {
                test_result = TestResult{ .skipped = self };
            },
            else => {
                var str: []u8 = &.{};
                if (!no_stack_trace) {
                    if (@errorReturnTrace()) |stack_trace| {
                        var stack_trace_writer = std.io.Writer.Allocating.init(arena.allocator());
                        // skip frame from the testing.zig:
                        const st = std.builtin.StackTrace{
                            .index = stack_trace.index - 1,
                            .instruction_addresses = stack_trace.instruction_addresses[1..],
                        };
                        try st.format(&stack_trace_writer.writer);
                        str = stack_trace_writer.written();
                    }
                }
                test_result = TestResult{
                    .failed = .{
                        .@"test" = self,
                        .duration = duration,
                        .is_mem_leak = is_mem_leak,
                        .err = err,
                        .stack_trace = str,
                    },
                };
            },
        }
        return test_result;
    }
};

/// A report about run a single test
pub const TestResult = union(enum) {
    passed: struct { @"test": Test, duration: Duration, is_mem_leak: bool },
    failed: struct { @"test": Test, duration: Duration, err: anyerror, stack_trace: []const u8, is_mem_leak: bool },
    skipped: Test,

    pub fn @"test"(self: TestResult) Test {
        return switch (self) {
            .passed => |result| result.@"test",
            .failed => |result| result.@"test",
            .skipped => |t| t,
        };
    }

    pub fn testDurationMs(self: TestResult) f64 {
        return switch (self) {
            .passed => |result| result.duration_ms,
            .failed => |result| result.duration_ms,
            .skipped => 0.0,
        };
    }

    pub fn isMemoryLeak(self: TestResult) bool {
        return switch (self) {
            .passed => |result| result.is_mem_leak,
            .failed => |result| result.is_mem_leak,
            .skipped => false,
        };
    }
};

/// A report about run of all tests.
const Report = struct {
    process_name: []const u8,
    test_results: []TestResult,
    passed_count: u8 = 0,
    failed_count: u8 = 0,
    skipped_count: u8 = 0,
    total_duration: Duration = .zero,
    is_mem_leak: bool = false,
};

/// A representation of the time duration with human readable format.
const Duration = struct {
    minutes: u6 = 0,
    seconds: u6 = 0,
    millis: u10 = 0,
    nanos: u30 = 0,

    pub const zero: Duration = .{};

    pub fn fromNanos(ns: u64) Duration {
        var result: Duration = .zero;
        result.addNs(ns);
        return result;
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.minutes > 0) {
            try writer.print("{d}m ", .{self.minutes});
            if (self.seconds > 0)
                try writer.print("{d}s ", .{self.seconds});
            if (self.millis > 0)
                try writer.print("{d}ms ", .{self.millis});
            if (self.nanos > 0)
                try writer.print("{d}ns", .{self.nanos});

            return;
        }
        if (self.seconds > 0) {
            try writer.print("{d}.{d} seconds", .{ self.seconds, self.millis });
            return;
        }
        if (self.millis > 0) {
            try writer.print("{d} ms", .{self.millis});
            return;
        }

        try writer.print("< 1 ms", .{});
    }

    fn addNs(self: *Duration, count: u64) void {
        if (count == 0) return;
        self.nanos += @intCast(count % 1_000_000);
        self.addMillis(@intCast(count / 1_000_000));
    }

    fn addMillis(self: *Duration, count: u64) void {
        if (count == 0) return;
        self.millis += @intCast(count % 1_000);
        self.addSeconds(@intCast(count / 1_000));
    }

    fn addSeconds(self: *Duration, count: u64) void {
        if (count == 0) return;
        self.seconds += @intCast(count % 60);
        self.addMinutes(@intCast(count / 60));
    }

    fn addMinutes(self: *Duration, count: u6) void {
        if (count == 0) return;
        std.debug.assert(count < 60);
        self.minutes += count;
    }
};

/// Writes to a file a tests report as an optionally colored text.
const FileReporter = struct {
    const Color = std.io.tty.Color;

    const Colors = struct {
        title: Color = .cyan,
        process_name: Color = .yellow,
        no_tests: Color = .dim,
        namespace: Color = .cyan,
        test_name: Color = .cyan,
        filter: Color = .yellow,
        summary: Color = .cyan,
        passed: Color = .green,
        failed: Color = .red,
        skipped: Color = .yellow,
        memory_leak: Color = .magenta,

        pub const default: Colors = .{};
    };

    const border = "=" ** 65;

    file_writer: std.fs.File.Writer,
    config: std.io.tty.Config,
    colors: Colors,

    pub fn stdout(buffer: []u8, colors: Colors) FileReporter {
        const file = std.fs.File.stdout();
        return .{ .file_writer = file.writer(buffer), .config = std.io.tty.Config.detect(file), .colors = colors };
    }

    pub fn writeTitle(
        self: *FileReporter,
        process_name: []const u8,
        filter: ?[]const u8,
        tests_count: usize,
    ) anyerror!void {
        // move to the next line and cleanup output settings:
        _ = try self.file_writer.interface.write("\r\n\x1b[0K");
        try self.colorizeLine(self.colors.title, "{s}", .{border});

        if (tests_count == 0) {
            try self.colorizeLine(self.colors.no_tests, "No one test was found in {s}", .{process_name});
            return;
        }
        try self.colorize(self.colors.title, "Run ", .{});
        try self.colorizeLine(self.colors.process_name, "{s}", .{process_name});
        if (filter) |f| {
            try self.colorize(self.colors.no_tests, "Only tests contain ", .{});
            try self.colorize(self.colors.filter, "'{s}'", .{f});
            try self.colorizeLine(self.colors.no_tests, " in the name are running", .{});
        }
        // to print the title before any output from tests
        try self.file_writer.interface.flush();
    }

    pub fn writeNamespace(self: *FileReporter, namespace: []const u8) anyerror!void {
        try self.colorizeLine(self.colors.namespace, "{s}", .{namespace});
    }

    pub fn writeTestName(self: *FileReporter, test_name: []const u8) anyerror!void {
        try self.colorize(self.colors.test_name, " - {s} ", .{test_name});
    }

    pub fn writeTestResult(self: *FileReporter, test_result: TestResult) anyerror!void {
        switch (test_result) {
            .passed => |result| {
                try self.colorize(
                    self.colors.passed,
                    " PASSED in {f}",
                    .{result.duration},
                );
            },
            .failed => |result| {
                try self.colorize(
                    self.colors.failed,
                    " FAILED in {f}: {s}",
                    .{ result.duration, @errorName(result.err) },
                );
            },
            .skipped => {
                try self.colorize(self.colors.skipped, " SKIPPED", .{});
            },
        }
        if (test_result.isMemoryLeak()) {
            try self.colorizeLine(self.colors.memory_leak, " MEMORY LEAK", .{});
        } else {
            try self.file_writer.interface.writeByte('\n');
        }
        if (test_result == .failed) {
            try self.file_writer.interface.writeAll(test_result.failed.stack_trace);
        }
    }

    pub fn writeSummary(
        self: *FileReporter,
        passed: u8,
        failed: u8,
        skipped: u8,
        total_duration: Duration,
        is_mem_leak: bool,
    ) anyerror!void {
        if (passed + skipped + failed == 0 and !is_mem_leak)
            return;

        try self.colorize(
            self.colors.summary,
            border ++ "\nTotal {d} tests were run in {f}: ",
            .{ passed + failed + skipped, total_duration },
        );
        if (passed > 0)
            try self.colorize(self.colors.passed, "{d} passed; ", .{passed});
        if (failed > 0)
            try self.colorize(self.colors.failed, "{d} failed; ", .{failed});
        if (skipped > 0)
            try self.colorize(self.colors.skipped, "{d} skipped;", .{skipped});
        if (is_mem_leak)
            try self.colorize(self.colors.memory_leak, " MEMORY LEAK", .{});

        // move to the next line and cleanup output settings:
        _ = try self.file_writer.interface.write("\r\n\x1b[0K");
        try self.file_writer.interface.flush();
    }

    fn colorizeLine(
        self: *FileReporter,
        color: Color,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        try self.colorize(color, format, args);
        try self.file_writer.interface.writeByte('\n');
    }

    fn colorize(
        self: *FileReporter,
        color: Color,
        comptime format: []const u8,
        args: anytype,
    ) !void {
        try self.config.setColor(&self.file_writer.interface, color);
        try self.file_writer.interface.print(format, args);
        try self.config.setColor(&self.file_writer.interface, .reset);
    }
};
