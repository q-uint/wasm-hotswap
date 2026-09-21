const std = @import("std");

const guests = [_][]const u8{ "guest_v1", "guest_v2", "guest_v3" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "strip the host binary") orelse false;

    const capi = b.option([]const u8, "wasmtime", "wasmtime C API prefix") orelse
        b.graph.environ_map.get("WASMTIME_CAPI") orelse
        @panic("pass -Dwasmtime=<prefix>, or enter `nix develop`");

    const host = b.addExecutable(.{
        .name = "host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("host.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
        }),
    });
    host.root_module.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ capi, "include" }) });
    host.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ capi, "lib", "libwasmtime.a" }) });

    // atomics+bulk_memory are required by --shared-memory. min == max memory
    // means memory.grow can never map.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{ .atomics, .bulk_memory }),
    });

    for (guests) |name| {
        const guest = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("{s}.zig", .{name})),
                .target = wasm_target,
                .optimize = .ReleaseSmall,
            }),
        });
        guest.entry = .disabled;
        guest.import_memory = true;
        guest.shared_memory = true;
        guest.initial_memory = 1 << 20;
        guest.max_memory = 1 << 20;
        guest.stack_size = 16 << 10;
        guest.root_module.export_symbol_names = &.{"step"};

        host.root_module.addAnonymousImport(b.fmt("{s}.wasm", .{name}), .{
            .root_source_file = guest.getEmittedBin(),
        });
        b.installArtifact(guest);
    }

    b.installArtifact(host);

    const run = b.addRunArtifact(host);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Build and run the host").dependOn(&run.step);
}
