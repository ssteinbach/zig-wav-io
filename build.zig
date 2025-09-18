//! build script for zig-wav-io module

const std = @import("std");

const MODULE_NAME = "wav_io";

pub fn build(
    b: *std.Build,
) void 
{
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Make module available as dependency.
    const mod_root = b.addModule(
        MODULE_NAME,
        .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }
    );

    const test_filter = b.option(
        []const u8,
        "test-filter",
        "filter for which tests to run",
    ) orelse &.{};

    const test_mod = b.addTest(
        .{
            .name = "test_wav_io",
            .root_module = mod_root,
            .filters = &.{ test_filter },
        },
    );
    const run_test_mod = b.addRunArtifact(test_mod);

    // install test binary for console debugging
    const install_test_bin = b.addInstallArtifact(
        test_mod, 
        .{}
    );

    const test_step = b.step(
        "test",
        "Run library tests",
    );
    test_step.dependOn(&install_test_bin.step);
    test_step.dependOn(&run_test_mod.step);

    // for zls -- "check" step
    const check_step = check: {
        const check_step = b.step(
            "check",
            "Check if everything compiles",
        );
        check_step.dependOn(test_step);

        break :check check_step;
    };

    // demo
    {
        const demo = b.addExecutable(
            .{
                .name = "demo_wav_io",
                .root_module = b.createModule(
                    .{
                        .root_source_file = b.path("src/demo.zig"),
                        .target = target,
                        .optimize = optimize,
                        .imports = &.{
                            .{ 
                                .name = "wav_io",
                                .module = mod_root, 
                            },
                        },
                    },
                ),
            },
        );

        b.installArtifact(demo);
        const run_step = b.step(
            "run",
            "Run the demo program",
        );
        const run_cmd = b.addRunArtifact(demo);
        run_step.dependOn(&run_cmd.step);
        check_step.dependOn(&demo.step);
    }

    // docs
    {
        const install_docs = b.addInstallDirectory(
            .{
                .source_dir = test_mod.getEmittedDocs(),
                .install_dir = .prefix,
                .install_subdir = "docs/" ++ MODULE_NAME,
            },
        );
        const docs_step = b.step(
            "docs",
            "build the documentation for the entire library",
        );
        docs_step.dependOn(&install_docs.step);
    }
}
