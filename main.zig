const std = @import("std");
const fs = std.fs;
const print = std.debug.print;
const assert = std.debug.assert;

const MmappedFile = struct {
    file: fs.File,
    mem: []align(4096) u8,

    const Self = @This();

    pub fn open(fileName: []const u8) !MmappedFile {
        const file = try fs.cwd().openFile(fileName, .{});
        const md = try file.metadata();
        const ptr = try std.os.mmap(null, md.size(), std.os.PROT.READ, .{ .TYPE = .PRIVATE }, file.handle, 0);

        return MmappedFile{ .file = file, .mem = ptr[0..md.size()] };
    }

    pub fn deinit(self: *const Self) void {
        self.file.close();
        std.os.munmap(self.mem);
    }
};

const ReaderError = error{
    outOfMemoryError,
};

const BinaryReader = struct {
    data: []const u8,
    pos: u32 = 0,
    const Self = @This();

    fn read(self: *Self, comptime T: type) ReaderError!T {
        comptime assert(@typeInfo(T) == .Int or @typeInfo(T) == .ComptimeInt);
        if (self.pos + @sizeOf(T) > self.data.len) {
            return ReaderError.outOfMemoryError;
        }
        const value: T = @bitCast(std.mem.readInt(T, self.data[self.pos..][0..@sizeOf(T)], .little));
        self.pos += @sizeOf(T);
        return value;
    }

    fn readIntLeb(self: *Self, comptime T: type) ReaderError!T {
        comptime assert(@typeInfo(T) == .Int or @typeInfo(T) == .ComptimeInt);
        var shift: u6 = 0;
        var result: u64 = 0;
        while (true) {
            assert(shift < @sizeOf(T) * 8);
            const byte = self.data[self.pos];
            result |= @as(u64, @intCast(byte & 0x7f)) << shift;
            shift += 7;
            self.pos += 1;
            if ((byte & 0x80) == 0) {
                break;
            }
        }
        return @as(T, @intCast(result));
    }

    fn hasMore(self: *Self) bool {
        return self.pos < self.data.len;
    }
};

const WasmError = error{
    verificationValid,
};

const WasmSectionId = enum(u8) {
    customSection,
    typeSection,
    importSection,
    functionSection,
    tableSection,
    memorySection,
    globalSection,
    exportSection,
    startSection,
    ElementSection,
    CodeSection,
    DataSection,
    EnumSize,
};

const WasmValueType = enum(u8) {
    I32 = 0x7F,
    I64 = 0x7E,
    F32 = 0x7D,
    F64 = 0x7C,
};

const WasmFunctionType = struct {
    retType: WasmValueType,
    argTypes: []WasmValueType,
    const Self = @This();

    pub fn parse(self: *Self, alloc: std.mem.Allocator, reader: *BinaryReader) !void {
        const fnMagic = try reader.read(u8);
        try wasmValidateEq(fnMagic, 0x60);
        const numArgs = try reader.readIntLeb(u32);
        self.argTypes = try alloc.alloc(WasmValueType, numArgs);
        for (self.argTypes) |*arg| {
            arg.* = @enumFromInt(try reader.read(u8));
        }
        const numRetTypes = try reader.readIntLeb(u32);
        try wasmValidateEq(numRetTypes, 1);
        self.retType = @enumFromInt(try reader.read(u8));
    }

    pub fn dump(self: Self) void {
        print("Fn Signature: (", .{});

        // Print arguments
        var first = true;
        for (self.argTypes) |*arg| {
            if (!first) {
                print(", ");
            }
            print("{}", arg.str());
            first = false;
        }

        // Print return type
        print(") -> {}", self.retType.str());
    }
};

const WasmTypeSection = struct {};

const WasmModule = struct {
    allocator: std.mem.Allocator,
    typeSection: WasmFunctionType = undefined,
    const Self = @This();

    pub fn run(self: *Self, wasmCode: []const u8) !void {
        var reader = BinaryReader{ .data = wasmCode };
        const magic = try reader.read(u32);
        try wasmValidateEq(magic, 0x6d736100);
        const version = try reader.read(u32);
        try wasmValidateEq(version, 1);
        while (reader.hasMore()) {
            const sectionId: WasmSectionId = @enumFromInt(try reader.read(u8));
            try wasmValidateLt(@intFromEnum(sectionId), @intFromEnum(WasmSectionId.EnumSize));
            print("{}\n", .{sectionId});

            switch (sectionId) {
                WasmSectionId.typeSection => {
                    try self.typeSection.parse(self.allocator, &reader);
                    self.typeSection.dump();
                },
                else => break,
            }

            break;
        }
    }
};

pub fn wasmValidateEq(actual: anytype, expected: anytype) WasmError!void {
    if (actual != expected) {
        print("Validation failed, expected:{}, actual:{}\n", .{ expected, actual });
        return WasmError.verificationValid;
    }
}

pub fn wasmValidateLt(actual: anytype, expected: anytype) WasmError!void {
    if (actual >= expected) {
        print("Validation failed, expected:{}, actual:{}\n", .{ expected, actual });
        return WasmError.verificationValid;
    }
}

pub fn main() !void {
    const file = try MmappedFile.open("wasm_adder.wasm");
    var wasm = WasmModule{ .allocator = std.heap.page_allocator };
    try wasm.run(file.mem);
    defer file.deinit();
}
