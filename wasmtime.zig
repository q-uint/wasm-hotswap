//! Thin Zig wrapper over the slice of the wasmtime C API this demo uses.
//!
//! Ownership rules the C API documents but does not enforce are handled here:
//! errors are deleted after their message is read, and import externs are
//! cloned/deleted around instantiation (wasmtime_instance_new borrows them).

const std = @import("std");

pub const c = @cImport({
    @cInclude("wasmtime.h");
});

pub const Error = error{Wasmtime};

pub const CallError = Error || error{
    Interrupt,
    UnreachableReached,
    Trap,
};

/// Consumes `err`, logs its message, and maps it to a Zig error.
fn wrap(err: ?*c.wasmtime_error_t) Error!void {
    const e = err orelse return;
    defer c.wasmtime_error_delete(e);

    var msg: c.wasm_byte_vec_t = undefined;
    c.wasmtime_error_message(e, &msg);
    defer c.wasm_byte_vec_delete(&msg);

    std.log.err("wasmtime: {s}", .{msg.data[0..msg.size]});
    return error.Wasmtime;
}

pub const Config = struct {
    /// Wall-clock bound: guest checks an engine-global counter at loop
    /// back-edges and function entries, and traps once it moves.
    epoch_interruption: bool = false,
    threads: bool = false,
    shared_memory: bool = false,
};

pub const Engine = struct {
    ptr: *c.wasm_engine_t,

    pub fn init(cfg: Config) Engine {
        const raw = c.wasm_config_new();
        c.wasmtime_config_epoch_interruption_set(raw, cfg.epoch_interruption);
        c.wasmtime_config_wasm_threads_set(raw, cfg.threads);
        c.wasmtime_config_shared_memory_set(raw, cfg.shared_memory);
        return .{ .ptr = c.wasm_engine_new_with_config(raw).? };
    }

    pub fn deinit(self: Engine) void {
        c.wasm_engine_delete(self.ptr);
    }

    /// Safe to call from any thread, and async-signal-safe.
    pub fn incrementEpoch(self: Engine) void {
        c.wasmtime_engine_increment_epoch(self.ptr);
    }
};

pub const Store = struct {
    ptr: *c.wasmtime_store_t,
    ctx: *c.wasmtime_context_t,

    pub fn init(engine: Engine) Store {
        const ptr = c.wasmtime_store_new(engine.ptr, null, null).?;
        return .{ .ptr = ptr, .ctx = c.wasmtime_store_context(ptr).? };
    }

    pub fn deinit(self: Store) void {
        c.wasmtime_store_delete(self.ptr);
    }

    /// Trap once the engine epoch advances this many ticks. Must be re-armed
    /// after every trap.
    pub fn setEpochDeadline(self: Store, ticks: u64) void {
        c.wasmtime_context_set_epoch_deadline(self.ctx, ticks);
    }
};

pub const Module = struct {
    ptr: *c.wasmtime_module_t,

    pub fn init(engine: Engine, wasm: []const u8) Error!Module {
        var ptr: ?*c.wasmtime_module_t = null;
        try wrap(c.wasmtime_module_new(engine.ptr, wasm.ptr, wasm.len, &ptr));
        return .{ .ptr = ptr.? };
    }

    pub fn deinit(self: Module) void {
        c.wasmtime_module_delete(self.ptr);
    }
};

pub const SharedMemory = struct {
    ptr: *c.wasmtime_sharedmemory_t,

    /// Engine-owned memory with min == max pages, so `memory.grow` can never
    /// map. Engine-owned is what lets a Store be dropped without losing state.
    pub fn init(engine: Engine, pages: u64) Error!SharedMemory {
        var mt: ?*c.wasm_memorytype_t = null;
        try wrap(c.wasmtime_memorytype_new(pages, true, pages, false, true, 16, &mt));
        defer c.wasm_memorytype_delete(mt);

        var ptr: ?*c.wasmtime_sharedmemory_t = null;
        try wrap(c.wasmtime_sharedmemory_new(engine.ptr, mt, &ptr));
        return .{ .ptr = ptr.? };
    }

    pub fn deinit(self: SharedMemory) void {
        c.wasmtime_sharedmemory_delete(self.ptr);
    }

    pub fn data(self: SharedMemory) [*]u8 {
        return c.wasmtime_sharedmemory_data(self.ptr).?;
    }

    /// A pointer into linear memory at a fixed offset. Volatile because the
    /// guest writes the same bytes.
    pub fn ptrAt(self: SharedMemory, comptime T: type, offset: usize) *volatile T {
        return @ptrCast(@alignCast(self.data() + offset));
    }
};

pub const Extern = union(enum) {
    shared_memory: SharedMemory,
    func: c.wasmtime_func_t,

    fn toC(self: Extern) c.wasmtime_extern_t {
        return switch (self) {
            // Cloned because wasmtime_instance_new borrows imports rather than
            // taking ownership. The clone is released in Instance.init.
            .shared_memory => |m| .{
                .kind = c.WASMTIME_EXTERN_SHAREDMEMORY,
                .of = .{ .sharedmemory = c.wasmtime_sharedmemory_clone(m.ptr) },
            },
            .func => |f| .{ .kind = c.WASMTIME_EXTERN_FUNC, .of = .{ .func = f } },
        };
    }
};

/// Host function of type `() -> f64` reading `src` at call time. `src` must
/// outlive `store`. Narrow on purpose: a general binding would be more
/// machinery than one sensor read needs.
pub fn funcReadF64(store: Store, src: *const f64) Extern {
    const ty = c.wasm_functype_new_0_1(c.wasm_valtype_new(c.WASM_F64)).?;
    defer c.wasm_functype_delete(ty);

    const trampoline = struct {
        fn call(
            env: ?*anyopaque,
            _: ?*c.wasmtime_caller_t,
            _: [*c]const c.wasmtime_val_t,
            _: usize,
            results: [*c]c.wasmtime_val_t,
            _: usize,
        ) callconv(.c) ?*c.wasm_trap_t {
            const p: *const f64 = @ptrCast(@alignCast(env.?));
            results[0] = .{ .kind = c.WASMTIME_F64, .of = .{ .f64 = p.* } };
            return null;
        }
    }.call;

    var f: c.wasmtime_func_t = undefined;
    c.wasmtime_func_new(store.ctx, ty, trampoline, @constCast(src), null, &f);
    return .{ .func = f };
}

pub const Instance = struct {
    inner: c.wasmtime_instance_t,
    ctx: *c.wasmtime_context_t,

    pub fn init(store: Store, module: Module, imports: []const Extern) Error!Instance {
        var buf: [8]c.wasmtime_extern_t = undefined;
        std.debug.assert(imports.len <= buf.len);
        for (imports, 0..) |e, i| buf[i] = e.toC();
        defer for (buf[0..imports.len]) |*e| c.wasmtime_extern_delete(e);

        var inner: c.wasmtime_instance_t = undefined;
        var trap: ?*c.wasm_trap_t = null;
        try wrap(c.wasmtime_instance_new(
            store.ctx,
            module.ptr,
            &buf,
            imports.len,
            &inner,
            &trap,
        ));
        if (trap) |t| {
            c.wasm_trap_delete(t);
            std.log.err("wasmtime: trap during instantiation", .{});
            return error.Wasmtime;
        }
        return .{ .inner = inner, .ctx = store.ctx };
    }

    pub fn getFunc(self: *const Instance, name: []const u8) ?Func {
        var item: c.wasmtime_extern_t = undefined;
        if (!c.wasmtime_instance_export_get(self.ctx, &self.inner, name.ptr, name.len, &item)) {
            return null;
        }
        if (item.kind != c.WASMTIME_EXTERN_FUNC) return null;
        return .{ .inner = item.of.func, .ctx = self.ctx };
    }
};

pub const Val = union(enum) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,

    fn toC(self: Val) c.wasmtime_val_t {
        return switch (self) {
            .i32 => |v| .{ .kind = c.WASMTIME_I32, .of = .{ .i32 = v } },
            .i64 => |v| .{ .kind = c.WASMTIME_I64, .of = .{ .i64 = v } },
            .f32 => |v| .{ .kind = c.WASMTIME_F32, .of = .{ .f32 = v } },
            .f64 => |v| .{ .kind = c.WASMTIME_F64, .of = .{ .f64 = v } },
        };
    }

    fn fromC(v: c.wasmtime_val_t) Val {
        return switch (v.kind) {
            c.WASMTIME_I64 => .{ .i64 = v.of.i64 },
            c.WASMTIME_F32 => .{ .f32 = v.of.f32 },
            c.WASMTIME_F64 => .{ .f64 = v.of.f64 },
            else => .{ .i32 = v.of.i32 },
        };
    }
};

pub const Func = struct {
    inner: c.wasmtime_func_t,
    ctx: *c.wasmtime_context_t,

    /// Traps surface as errors. `error.Interrupt` is the epoch deadline, which
    /// here means the guest failed to hold its budget.
    pub fn call(self: Func, args: []const Val, results: []Val) CallError!void {
        var argv: [8]c.wasmtime_val_t = undefined;
        var resv: [8]c.wasmtime_val_t = undefined;
        std.debug.assert(args.len <= argv.len and results.len <= resv.len);
        for (args, 0..) |a, i| argv[i] = a.toC();

        var trap: ?*c.wasm_trap_t = null;
        try wrap(c.wasmtime_func_call(
            self.ctx,
            &self.inner,
            &argv,
            args.len,
            &resv,
            results.len,
            &trap,
        ));

        if (trap) |t| {
            defer c.wasm_trap_delete(t);
            var code: c.wasmtime_trap_code_t = 0;
            if (!c.wasmtime_trap_code(t, &code)) return error.Trap;
            return switch (code) {
                c.WASMTIME_TRAP_CODE_INTERRUPT => error.Interrupt,
                c.WASMTIME_TRAP_CODE_UNREACHABLE_CODE_REACHED => error.UnreachableReached,
                else => error.Trap,
            };
        }

        for (results, 0..) |*r, i| r.* = Val.fromC(resv[i]);
    }
};
