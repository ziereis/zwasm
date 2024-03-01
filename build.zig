const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "zwasm",
        .root_source_file = .{ .path = "main.zig" },
        .target = b.host,
    });

    b.installArtifact(exe);
}
