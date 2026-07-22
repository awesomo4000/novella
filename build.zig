// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const default_target: std.Target.Query = if (builtin.os.tag == .windows) .{
        .cpu_arch = builtin.cpu.arch,
        .os_tag = .windows,
        .os_version_min = .{ .windows = .win10_rs1 },
        .os_version_max = .{ .windows = std.Target.Os.WindowsVersion.latest },
        .abi = builtin.abi,
    } else .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    const novella = b.addModule("novella", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_step = b.step("test", "Run the justification and shared application tests");

    if (target.result.os.tag == .macos) {
        const harfbuzz = b.addLibrary(.{
            .name = "harfbuzz-vendored",
            .linkage = .static,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
            }),
        });
        harfbuzz.root_module.link_libc = true;
        harfbuzz.root_module.link_libcpp = true;
        harfbuzz.root_module.addIncludePath(b.path("vendor/harfbuzz/src"));
        harfbuzz.root_module.addCSourceFile(.{
            .file = b.path("vendor/harfbuzz/src/harfbuzz.cc"),
            .flags = &.{
                "-std=c++17",
                "-fno-exceptions",
                "-fno-rtti",
                "-fvisibility=hidden",
                "-DHB_NO_AAT",
                "-DHB_NO_BITMAP",
                "-DHB_NO_COLOR",
                "-DHB_NO_DRAW",
                "-DHB_NO_GETENV",
                "-DHB_NO_MATH",
                "-DHB_NO_META",
                "-DHB_NO_PAINT",
                "-DHB_NO_SETLOCALE",
                "-DHB_NO_STYLE",
            },
        });

        const text_engine = b.createModule(.{
            .root_source_file = b.path("src/app/text_engine.zig"),
            .target = target,
            .optimize = optimize,
        });
        text_engine.addIncludePath(b.path("vendor/harfbuzz/src"));
        text_engine.linkLibrary(harfbuzz);

        const font_data = b.createModule(.{
            .root_source_file = b.path("src/app/font_data.zig"),
            .target = target,
            .optimize = optimize,
        });
        font_data.addAnonymousImport("junicode_font", .{
            .root_source_file = b.path("src/assets/junicode.zig"),
        });

        const text_engine_test_module = b.createModule(.{
            .root_source_file = b.path("src/app/text_engine_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "text_engine", .module = text_engine },
                .{ .name = "font_data", .module = font_data },
            },
        });
        const text_engine_tests = b.addTest(.{ .root_module = text_engine_test_module });
        const run_text_engine_tests = b.addRunArtifact(text_engine_tests);
        test_step.dependOn(&run_text_engine_tests.step);

        const macos_module = b.createModule(.{
            .root_source_file = b.path("src/platform/macos.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "novella", .module = novella },
                .{ .name = "text_engine", .module = text_engine },
                .{ .name = "font_data", .module = font_data },
            },
        });
        macos_module.linkFramework("AppKit", .{});
        macos_module.linkFramework("CoreFoundation", .{});
        macos_module.linkFramework("CoreGraphics", .{});
        macos_module.linkFramework("CoreText", .{});
        const macos_app = b.addExecutable(.{
            .name = "novella",
            .root_module = macos_module,
        });
        b.installArtifact(macos_app);

        const run_command = b.addRunArtifact(macos_app);
        run_command.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_command.addArgs(args);
        const run_step = b.step("run", "Run the native macOS writing sheet");
        run_step.dependOn(&run_command.step);
    }

    if (target.result.os.tag == .windows) {
        const windows_module = b.createModule(.{
            .root_source_file = b.path("src/platform/windows/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        windows_module.link_libc = true;
        windows_module.linkSystemLibrary("user32", .{});
        const windows_app = b.addExecutable(.{
            .name = "novella",
            .root_module = windows_module,
            .win32_manifest = b.path("src/platform/windows/novella.manifest"),
        });
        windows_app.subsystem = .windows;

        const install_windows = b.addInstallArtifact(windows_app, .{});
        b.getInstallStep().dependOn(&install_windows.step);
        const windows_step = b.step("windows", "Build the native Windows application");
        windows_step.dependOn(&install_windows.step);

        const run_windows_command = b.addRunArtifact(windows_app);
        run_windows_command.step.dependOn(&install_windows.step);
        const run_windows_step = b.step("run-windows", "Run the native Windows application");
        run_windows_step.dependOn(&run_windows_command.step);
        const run_step = b.step("run", "Run the native Windows application");
        run_step.dependOn(&run_windows_command.step);
    }

    const xau = b.addLibrary(.{
        .name = "Xau-vendored",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    xau.root_module.link_libc = true;
    xau.root_module.addIncludePath(b.path("vendor/xau/include"));
    xau.root_module.addIncludePath(b.path("vendor/xau/src"));
    xau.root_module.addCSourceFiles(.{
        .root = b.path("vendor/xau/src"),
        .files = &.{
            "AuDispose.c",
            "AuFileName.c",
            "AuGetBest.c",
            "AuRead.c",
        },
        .flags = &.{ "-std=c99", "-DHAVE_CONFIG_H=1" },
    });

    const xcb = b.addLibrary(.{
        .name = "xcb-vendored",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    xcb.root_module.link_libc = true;
    xcb.root_module.addIncludePath(b.path("vendor/xcb/src"));
    xcb.root_module.addIncludePath(b.path("vendor/xau/include"));
    xcb.root_module.addCSourceFiles(.{
        .root = b.path("vendor/xcb/src"),
        .files = &.{
            "xcb_conn.c",
            "xcb_out.c",
            "xcb_in.c",
            "xcb_ext.c",
            "xcb_xid.c",
            "xcb_list.c",
            "xcb_util.c",
            "xcb_auth.c",
            "xproto.c",
            "bigreq.c",
            "xc_misc.c",
        },
        .flags = &.{ "-std=c99", "-DHAVE_CONFIG_H=1" },
    });

    const x11_module = b.createModule(.{
        .root_source_file = b.path("src/platform/x11.zig"),
        .target = target,
        .optimize = optimize,
    });
    x11_module.addIncludePath(b.path("vendor/xcb/src"));
    x11_module.linkLibrary(xcb);
    x11_module.linkLibrary(xau);
    const x11_app = b.addExecutable(.{
        .name = "novella-x11",
        .root_module = x11_module,
    });
    const install_x11 = b.addInstallArtifact(x11_app, .{});
    const x11_step = b.step("x11", "Build the static-XCB X11 sample");
    x11_step.dependOn(&install_x11.step);

    const run_x11_command = b.addRunArtifact(x11_app);
    run_x11_command.step.dependOn(&install_x11.step);
    const run_x11_step = b.step("run-x11", "Run the static-XCB X11 sample");
    run_x11_step.dependOn(&run_x11_command.step);

    const module_tests = b.addTest(.{ .root_module = novella });
    const run_tests = b.addRunArtifact(module_tests);
    test_step.dependOn(&run_tests.step);

    const oracle_module = b.createModule(.{
        .root_source_file = b.path("src/oracle.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "novella", .module = novella }},
    });
    const oracle_executable = b.addExecutable(.{
        .name = "novella-oracle-cases",
        .root_module = oracle_module,
    });
    const emit_oracle_cases = b.addRunArtifact(oracle_executable);
    const compare_oracle = b.addSystemCommand(&.{ "node", "oracle/compare.mjs" });
    compare_oracle.addFileArg(emit_oracle_cases.captureStdOut(.{}));
    const oracle_step = b.step("oracle", "Compare Zig line breaking with the original justif core");
    oracle_step.dependOn(&compare_oracle.step);
}
