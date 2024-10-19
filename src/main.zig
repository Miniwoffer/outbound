const std = @import("std");

const log = std.log.scoped(.outbound_main);

// coroutine library
const libcoro = @import("libcoro");

//event handler
const xev = @import("xev");
const aio = libcoro.asyncio;

//My http library
const http = @import("http.zig");

const Allocator = std.mem.Allocator;

threadlocal var env: struct {allocator: std.mem.Allocator, exec: *aio.Executor} = undefined;

const Server = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    tp: *xev.ThreadPool,
    loop: *xev.Loop,
    exec: *aio.Executor,
    stacks: []u8,

    fn init(alloc: Allocator) !Self {
        const stack_size = 1024 * 128;
        const num_stacks = 5;
        
        const self: Self = .{
            .allocator = alloc,
            .tp =  try alloc.create(xev.ThreadPool),
            .loop = try alloc.create(xev.Loop),
            .exec = try alloc.create(aio.Executor),
            .stacks = try alloc.alignedAlloc(u8, libcoro.stack_alignment, num_stacks * stack_size)
        };
        self.tp.* = xev.ThreadPool.init(.{});
        self.loop.* = try xev.Loop.init(.{ .thread_pool = self.tp });
        self.exec.* = aio.Executor.init(self.loop);
        
        env = .{
            .allocator = self.allocator,
            .exec = self.exec,
        };

        aio.initEnv(.{
            .executor = self.exec,
            .stack_allocator = self.allocator,
            .default_stack_size = stack_size,
        });


        return self;
    }

    fn deinit(self: *const Self) void {
        self.loop.deinit();
        self.tp.shutdown();
        self.tp.deinit();

        self.allocator.destroy(self.tp);
        self.allocator.destroy(self.loop);
        self.allocator.destroy(self.exec);
        self.allocator.free(self.stacks);

    }

    fn run(self: *Self, func: anytype) !void {
        const stack = try libcoro.stackAlloc(self.allocator, 1024 * 32);
        defer self.allocator.free(stack);
        try aio.run(self.exec, func, .{}, stack);
    }

};

const ServerInfo = struct {
    addr: std.net.Address = undefined,
};

fn apiServerAccept(server: aio.TCP, allocator: Allocator) !void {
   const conn = try server.accept();
   var con = try http.Connection.init(allocator, conn);
   defer con.deinit();
   while(true) {
       try con.receiveHead();
   }
}

fn apiServer(_: *ServerInfo) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const addr = try std.net.Address.parseIp4("127.0.0.1", 8082);
    const srv = try xev.TCP.init(addr);

    try srv.bind(addr);
    try srv.listen(1);

    const server = aio.TCP.init(env.exec, srv);
    defer server.close() catch unreachable;

    while(true) {
        apiServerAccept(server, gpa.allocator()) catch |err| {
            log.err("Error: {}", .{ err });
        };
    }

}

pub fn serverMain() !void {
    const stack_size = 1024 * 32;

    var info: ServerInfo = .{};

    var server = try aio.xasync(apiServer, .{&info}, stack_size);
    defer server.deinit();

    try aio.xawait(server);
}


pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    var server = try Server.init(alloc);
    defer server.deinit();

    try server.run(serverMain); 
}
