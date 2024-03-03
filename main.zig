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

fn MakeUnsigned(comptime T: type) type {
    return @Type(.{ .Int = .{
        .bits = @typeInfo(T).Int.bits,
        .signedness = .unsigned,
    } });
}

fn GetSaveShiftType(comptime T: type) type {
    return @Type(.{ .Int = .{
        .bits = @sizeOf(T) * 8 - 1 - @clz(@as(T, @typeInfo(T).Int.bits)),
        .signedness = .unsigned,
    } });
}

const BinaryReader = struct {
    data: []const u8,
    pos: u32 = 0,
    const Self = @This();

    fn read(self: *Self, comptime T: type) ReaderError!T {
        comptime assert(@typeInfo(T) == .Int or @typeInfo(T) == .ComptimeInt);
        if (self.pos + @sizeOf(T) > self.data.len) {
            return ReaderError.outOfMemoryError;
        }
        defer self.pos += @sizeOf(T);
        return @bitCast(std.mem.readInt(T, self.data[self.pos..][0..@sizeOf(T)], .little));
    }

    fn readIntLeb(self: *Self, comptime T: type) ReaderError!T {
        comptime assert(@typeInfo(T) == .Int or @typeInfo(T) == .ComptimeInt);
        const U = MakeUnsigned(T);
        var shift: GetSaveShiftType(T) = 0;
        var result: U = 0;
        while (true) {
            assert(shift < @sizeOf(T) * 8);
            const byte = self.data[self.pos];
            result |= @as(U, @intCast(byte & 0x7f)) << shift;
            shift += 7;
            self.pos += 1;
            if ((byte & 0x80) == 0) {
                if (comptime @typeInfo(T).Int.signedness == .signed) {
                    const cond = (byte & 0x40 != 0) and (shift < @sizeOf(T) * 8);
                    if (cond) {
                        var ones: U = 0;
                        ones = ~ones;
                        result |= ones << shift;
                    }
                }
                break;
            }
        }
        return @as(T, @bitCast(result));
    }

    fn readStr(self: *Self) ReaderError![]const u8 {
        const len = try self.readIntLeb(u32);
        if (self.pos + len > self.data.len) {
            return ReaderError.outOfMemoryError;
        }
        defer self.pos += len;
        return self.data[self.pos .. self.pos + len];
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

    pub fn parse(reader: *BinaryReader) !WasmValueType {
        return @enumFromInt(try reader.read(u8));
    }
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
            arg.* = try WasmValueType.parse(reader);
        }
        const numRetTypes = try reader.readIntLeb(u32);
        try wasmValidateEq(numRetTypes, 1);
        self.retType = try WasmValueType.parse(reader);
    }

    pub fn dump(self: Self) void {
        print("Fn Signature: (", .{});

        // Print arguments
        var first = true;
        for (self.argTypes) |*arg| {
            if (!first) {
                print(", ", .{});
            }
            print("{}", .{arg});
            first = false;
        }

        // Print return type
        print(") -> {}", .{self.retType});
    }
};

const WasmTypeSection = struct {
    prototypes: []WasmFunctionType,
    const Self = @This();

    pub fn parseSection(self: *Self, alloc: std.mem.Allocator, reader: *BinaryReader) !void {
        const count = try reader.readIntLeb(u32);
        self.prototypes = try alloc.alloc(WasmFunctionType, count);
        for (self.prototypes) |*proto| {
            try proto.parse(alloc, reader);
        }
    }

    pub fn dump(self: *Self) void {
        for (self.prototypes) |*proto| {
            proto.dump();
        }
    }
};

const WasmFunctionSection = struct {
    functions: []u32,
    const Self = @This();

    pub fn parseSection(self: *Self, alloc: std.mem.Allocator, reader: *BinaryReader) !void {
        const count = try reader.readIntLeb(u32);
        self.functions = try alloc.alloc(u32, count);
        for (self.functions) |*func| {
            func.* = try reader.readIntLeb(u32);
        }
    }

    pub fn dump(self: *Self) void {
        for (self.functions) |idx| {
            print("Function Index: {}\n", .{idx});
        }
    }
};

const ExportType = enum(u8) {
    function,
    table,
    memory,
    global,
};

const ExportEntity = struct {
    name: []u8,
    idx: u32,
    exportType: ExportType,

    pub fn dump(self: *ExportEntity) void {
        print("ExportEntity: {s} -> {}, {}\n", .{ self.name, self.exportType, self.idx });
    }
};

const WasmExportSection = struct {
    exports: []ExportEntity,
    const Self = @This();

    pub fn parseSection(self: *Self, alloc: std.mem.Allocator, reader: *BinaryReader) !void {
        const count = try reader.readIntLeb(u32);
        self.exports = try alloc.alloc(ExportEntity, count);

        for (self.exports) |*exp| {
            const strRef = try reader.readStr();
            exp.* = ExportEntity{
                .name = try alloc.alloc(u8, strRef.len),
                .exportType = @enumFromInt(try reader.read(u8)),
                .idx = try reader.readIntLeb(u32),
            };
            std.mem.copyForwards(u8, exp.name, strRef);
        }
    }

    pub fn dump(self: *Self) void {
        for (self.exports) |*exp| {
            exp.dump();
        }
    }
};

const WasmOpCode = enum(u8) {
    wasmUnreachable = 0x00,
    wasmNop = 0x01,
    localGet = 0x20,
    localSet = 0x21,
    localTee = 0x22,
    i32Add = 0x6A,
    i32Const = 0x41,

    pub fn parse(reader: *BinaryReader) !WasmOpCode {
        return @enumFromInt(try reader.read(u8));
    }
};

const WasmValue = union(WasmValueType) {
    I32: i32,
    I64: i64,
    F32: f32,
    F64: f64,
};

const WasmInstruction = struct {
    opcode: WasmOpCode,
    op1: WasmValue,
    op2: WasmValue,
};

const OperandStack = struct {
    stack: []ValentIR,
    top: u32 = 0,
    const Self = @This();

    pub fn push(self: *Self, value: ValentIR) void {
        wasmValidateLt(self.top, self.data.len);
        self.stack[self.top] = value;
    }

    pub fn pop(self: *Self) ?ValentIR {
        if (self.top == 0) {
            return null;
        }

        defer self.top -= 1;
        return self.stack[self.top];
    }
};

const ValentOpcode = enum(u8) {
    i32const,
    setLocal,
    getLocal,
    i32add,
};

const ValentOp = union(enum) {
    stackLocation: u32,
    gpr: x86Register,
    i32Const: u32,
};

const ValentIR = struct {
    opcode: ValentOpcode,
    op1: ValentOp,
    op2: ValentOp,
};

const x86Register = struct {
    idx: u32,
};

const RegisterManager = struct {
    freeReg: x86Register = 0,

    pub fn getReg(self: *RegisterManager) x86Register {
        defer self.freeReg += 1;
        return self.freeReg;
    }
};

const x86Opcode = enum {
    loadConst,
    sadd,
    add,
    mov,
    ret,
};

const x86Operator = union {
    imm: u32,
    reg: x86Register,
};

const x86MIR = struct {
    opcode: x86Opcode,
    op1: x86Operator,
    op2: x86Operator,
};

const x86Module = struct {
    allocator: std.mem.Allocator,
    code: std.ArrayList(x86MIR),

    pub fn append(inst: x86MIR) void {
        code.append(inst);
    }
};

pub fn readCompressedLocals(
    localsList: *std.ArrayList(WasmValueType),
    reader: *BinaryReader,
) !void {
    const compressedLocalVecLen = try reader.readIntLeb(u32);
    var idx: u32 = 0;
    while (idx < compressedLocalVecLen) : (idx += 1) {
        const runLength = try reader.readIntLeb(u32);
        const localType = try WasmValueType.parse(reader);
        try localsList.appendNTimes(localType, runLength);
    }
}

const StorageLocation = union(enum) {
    reg: x86Register,
};

const VBCodeGen = struct {
    virtStack: OperandStack,
    regDescriptor: std.AutoArrayHashMap(x86Register, u32),
    localDescriptor: std.AutoArrayHashMap(u32, x86Register),
    regManager: RegisterManager,
    mod: x86Module,

    const Self = @This();

    pub fn produce(self: *Self) !x86Register {
        const top = try self.virtStack.pop();
        switch (top.opcode) {
            ValentIR.i32Const => {
                const reg = RegisterManager.getReg();
                x86Module.append(x86MIR{.opcode = x86Opcode.mov, op1 = x86Operator{.imm = top.op1.i32Const},
                op2 = )
            },
        }
    }

    pub fn handleWasmInst(self: *Self, inst: WasmInstruction) !void {
        switch (inst.opcode) {
            WasmOpCode.i32Const => {
                self.virtStack.push(ValentIR{
                    .opcode = ValentOp.i32Const,
                    .op1 = inst.op1.I32,
                });
            },
            WasmOpCode.localSet => {},
        }
    }
};

const WasmModule = struct {
    allocator: std.mem.Allocator,
    typeSection: WasmTypeSection = undefined,
    functionSection: WasmFunctionSection = undefined,
    exportSection: WasmExportSection = undefined,

    const Self = @This();

    pub fn genIR(
        _: *Self,
        reader: *BinaryReader,
    ) !ValentIR {
        var regManager = RegisterManager{};
        var tempAlloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer tempAlloc.deinit();

        const numFuncs = try reader.readIntLeb(u32);
        var localTypes = std.ArrayList(WasmValueType).init(std.heap.page_allocator);

        print("Num imported fns: {}\n", .{numFuncs});

        const mod = x86Module{ .alloc = std.heap.ArenaAllocator.ini(std.heap.page_allocator), .code = std.ArrayList(x86MIR).init(.alloc) };

        var virtualStack = OperandStack{ .stack = tempAlloc.alloc(ValentIR, 10000) };

        var curFn: u32 = 0;
        while (curFn < numFuncs) : (curFn += 1) {
            const fnSize = try reader.readIntLeb(u32);
            print("Fn {} -> size: {}\n", .{ curFn, fnSize });
            try readCompressedLocals(&localTypes, reader);
            for (localTypes.items) |ty| {
                print("ty: {}", .{ty});
            }
            print("\n", .{});

            while (true) {
                const opcode = try WasmOpCode.parse(reader);

                switch (opcode) {
                    WasmOpCode.i32Const => {
                        const imm = try reader.readIntLeb(i32);
                        virtualStack.push(ValentIR{ .opcode = ValentOp.i32Const });
                        print("const: {}\n", .{imm});
                    },
                    WasmOpCode.localSet => {
                        const localIdx = try reader.readIntLeb(u32);
                        const reg = regManager.getReg();

                        break;
                    },
                    else => break,
                }
                print("Op: {}\n", .{opcode});
            }
        }
        return WasmIR{};
        // TODO: handle imported function here
    }

    pub fn run(self: *Self, wasmCode: []const u8) !void {
        var reader = BinaryReader{ .data = wasmCode };
        print("{x}\n", .{reader.data});
        const magic = try reader.read(u32);
        try wasmValidateEq(magic, 0x6d736100);
        const version = try reader.read(u32);
        try wasmValidateEq(version, 1);
        while (reader.hasMore()) {
            const sectionId: WasmSectionId = @enumFromInt(try reader.read(u8));
            const sectionsize = try reader.readIntLeb(u32);
            print("Section size: {}\n", .{sectionsize});
            try wasmValidateLt(
                @intFromEnum(sectionId),
                @intFromEnum(WasmSectionId.EnumSize),
            );
            print("{}\n", .{sectionId});

            switch (sectionId) {
                WasmSectionId.typeSection => {
                    try self.typeSection.parseSection(self.allocator, &reader);
                    self.typeSection.dump();
                },
                WasmSectionId.functionSection => {
                    try self.functionSection.parseSection(self.allocator, &reader);
                    self.functionSection.dump();
                },
                WasmSectionId.exportSection => {
                    try self.exportSection.parseSection(self.allocator, &reader);
                    self.exportSection.dump();
                },
                WasmSectionId.CodeSection => {
                    _ = try self.genIR(&reader);
                },
                else => break,
            }
        }
    }
};

pub fn wasmValidateNeq(actual: anytype, expected: anytype) WasmError!void {
    if (actual != expected) {
        print("Validation failed, expected:{}, actual:{}\n", .{ expected, actual });
        return WasmError.verificationValid;
    }
}

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
