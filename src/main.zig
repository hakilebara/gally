const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const ArrayList = std.ArrayList;

const ValType = enum(u8) {
    i32 = 0x7F,
    i64 = 0x7E,
    f32 = 0x7D,
    f64 = 0x7C,
    v128 = 0x7B,
    funcref = 0x70,
    externref = 0x6F,
};

const SectionId = enum(u8) {
    custom = 0x00,
    type = 0x01,
    import = 0x02,
    function = 0x03,
    table = 0x04,
    memory = 0x05,
    global = 0x06,
    @"export" = 0x07,
    start = 0x08,
    element = 0x09,
    code = 0x0A,
    data = 0x0B,
    data_count = 0x0C,
    tag = 0x0D,
};

pub fn parsePreamble(reader: *Io.Reader) !void {
    const magic = try reader.take(4);
    if (!mem.eql(u8, magic, "\x00asm")) {
        return error.InvalidMagic;
    }

    const version = try reader.takeInt(u32, .little);
    if (version != 1) {
        return error.UnknownVersion;
    }
}

pub fn readSection(alloc: mem.Allocator, reader: *Io.Reader, module: *Module) !void {
    const id: SectionId = try reader.takeEnum(SectionId, .little);
    const section_size = try reader.takeLeb128(u32);
    _ = section_size;
    return switch (id) {
        .type => parseTypeSection(alloc, reader, module),
        .function => parseFunctionSection(alloc, reader, module),
        .@"export" => parseExportSection(alloc, reader, module),
        .code => parseCodeSection(alloc, reader, module),
        else => error.UnknownSection,
    };
}

const Module = struct {
    type_section: ArrayList(FuncType),
    function_section: ArrayList(u32),
    export_section: ArrayList(Export),
    code_section: ArrayList(Code),

    fn init() Module {
        return .{
            .type_section = undefined,
            .function_section = undefined,
            .export_section = undefined,
            .code_section = undefined,
        };
    }
};

const ExternId = enum(u8) {
    funcidx = 0x00,
    tableix = 0x01,
    memidx = 0x02,
    globalix = 0x03,
    tagidx = 0x04,
};

const Export = struct {
    name: []const u8,
    idxTag: ExternId,
    idx: u32,
};

const FuncType = struct {
    params: ArrayList(ValType),
    results: ArrayList(ValType),

    fn init() FuncType {
        return .{
            .params = undefined,
            .results = undefined,
        };
    }
};

fn parseTypeSection(alloc: mem.Allocator, reader: *Io.Reader, module: *Module) !void {
    var functype_count = try reader.takeLeb128(u32);

    module.type_section = try ArrayList(FuncType).initCapacity(alloc, functype_count);

    // typesec ::== ft*:section1(vec(functype)) => ft*
    while (functype_count > 0) : (functype_count -= 1) {
        // functype ::== 0x60 rt1:resulttype rt2:resulttype => rt1 -> rt2
        var functype = FuncType.init();
        const function_type_0x60 = try reader.takeByte();
        if (function_type_0x60 != 0x60) {
            return error.InvalidSectionFuncType;
        }
        // resulttype ::== t*:vec(valtype) => [*t]
        var params_resulttype_size = try reader.takeLeb128(u32);
        functype.params = try ArrayList(ValType).initCapacity(alloc, params_resulttype_size);
        while (params_resulttype_size > 0) : (params_resulttype_size -= 1) {
            try functype.params.append(alloc, try reader.takeEnum(ValType, .little));
        }
        var result_resulttype_size = try reader.takeLeb128(u32);
        functype.results = try ArrayList(ValType).initCapacity(alloc, result_resulttype_size);
        while (result_resulttype_size > 0) : (result_resulttype_size -= 1) {
            try functype.results.append(alloc, try reader.takeEnum(ValType, .little));
        }
        // resulttype ::== t*:vec(valtype) => [*t]
        try module.type_section.append(alloc, functype);
    }
}

fn parseFunctionSection(alloc: mem.Allocator, reader: *Io.Reader, module: *Module) !void {
    var typeidx_count = try reader.takeLeb128(u32);
    module.function_section = try ArrayList(u32).initCapacity(alloc, typeidx_count);
    while (typeidx_count > 0) : (typeidx_count -= 1) {
        try module.function_section.append(alloc, try reader.takeLeb128(u32));
    }
}

fn parseExportSection(alloc: mem.Allocator, reader: *Io.Reader, module: *Module) !void {
    var export_count = try reader.takeLeb128(u32);
    module.export_section = try ArrayList(Export).initCapacity(alloc, export_count);
    while (export_count > 0) : (export_count -= 1) {
        const name_len = try reader.takeLeb128(u32);
        const name = try reader.take(name_len);
        const externidx_tag = try reader.takeEnum(ExternId, .little);
        const externidx = try reader.takeByte();
        try module.export_section.append(alloc, .{ .name = name, .idxTag = externidx_tag, .idx = externidx });
    }
}

const Opcode = enum(u8) {
    @"local.get" = 0x20,
    @"local.set" = 0x21,
};

const Code = struct {
    locals: ArrayList(Local),
    expr: []const u8,
};

const Local = struct {
    count: u32,
    type: ValType,
};

fn parseCodeSection(alloc: mem.Allocator, reader: *Io.Reader, module: *Module) !void {
    var code_count = try reader.takeLeb128(u32);
    module.code_section = try ArrayList(Code).initCapacity(alloc, code_count);
    while (code_count > 0) : (code_count -= 1) {
        var code : Code = .{
            .locals = undefined,
            .expr = undefined,
        };
        const code_size = try reader.takeLeb128(u32);
        _ = code_size;
        var locals_count = try reader.takeLeb128(u32);
        // TODO: Make it a function
        code.locals = try ArrayList(Local).initCapacity(alloc, locals_count);
        while (locals_count > 0) : (locals_count -= 1) {
            const local : Local = .{
                .count = try reader.takeLeb128(u32),
                .type = try reader.takeEnum(ValType, .little),
            };
            try code.locals.append(alloc, local);
        }
        // Extract expression
        code.expr = try reader.takeSentinel(0x0b);
        try module.code_section.append(alloc, code);
    }
}

const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;

test parsePreamble {
    const binary = @embedFile("empty.wasm");
    var reader: Io.Reader = .fixed(binary);
    try parsePreamble(&reader);
}

test parseTypeSection {
    const binary = @embedFile("addint.wasm");

    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    const arena = aa.allocator();

    var reader: Io.Reader = .fixed(binary);
    var module = Module.init();

    reader.toss(10);
    try parseTypeSection(arena, &reader, &module);

    try expectEqual(module.type_section.items.len, 1);
    try expectEqual(module.type_section.items[0].params.items.len, 2);
    try expectEqual(module.type_section.items[0].results.items.len, 1);
    try expectEqualSlices(ValType, module.type_section.items[0].params.items, &.{ ValType.i32, ValType.i32 });
    try expectEqualSlices(ValType, module.type_section.items[0].results.items, &.{ValType.i32});
}

test parseFunctionSection {
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    const arena = aa.allocator();

    var reader: Io.Reader = .fixed(&.{
        0x01,
            0x00,
    });
    var module = Module.init();
    try parseFunctionSection(arena, &reader, &module);

    reader = .fixed(&.{
        0x02,
            0x00,
            0x01,
    });
    try parseFunctionSection(arena, &reader, &module);
    try expectEqualSlices(u32, module.function_section.items, &.{ 0, 1 });
}

test parseExportSection {
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    const arena = aa.allocator();

    var reader: Io.Reader = .fixed(&.{
        0x01,
        0x06,
            0x61, 0x64, 0x64, 0x49, 0x6E, 0x74, // "addInt"
        0x00, 0x00
    });
    var module = Module.init();
    try parseExportSection(arena, &reader, &module);
    try expectEqualStrings(module.export_section.items[0].name, "addInt");
    try expectEqual(module.export_section.items[0].idxTag, ExternId.funcidx);
    try expectEqual(module.export_section.items[0].idx, 0);
}


test parseCodeSection {
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    const arena = aa.allocator();

    var reader: Io.Reader = .fixed(&.{ 
        0x01,
        0x07,
        0x00,
        0x20, 0x00,
        0x20, 0x01,
        0x6A,
        0x0B,
    });
    var module = Module.init();
    try parseCodeSection(arena, &reader, &module);
    try expectEqualSlices(Local, module.code_section.items[0].locals.items, &.{});
    try expectEqualSlices(u8, module.code_section.items[0].expr, &.{ 0x20, 0x00, 0x20, 0x01, 0x6A });
}
