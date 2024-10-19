const std = @import("std");
const libcoro = @import("libcoro");


const log = std.log.scoped(.outbound_http);

const assert = std.debug.assert;

const Allocator = std.mem.Allocator; 
const ArenaAllocator = std.heap.ArenaAllocator;
const aio = libcoro.asyncio;

pub const State = enum {
    ready,
};

pub fn skipLWS(buff:[]const u8) usize {
    var start: usize = 0;
    while(true) {
        switch(buff[start]) {
            ' ','\t' => start+=1,
            else => break,
        }
    }
    return start;
}
pub fn seekNotCRCL(buff: []const u8) !usize {
    var start: usize = 0;
    while(buff[start..].len > 2) {
        if (!std.mem.eql(u8, buff[start..start+2], "\r\n")) {
            return start;
        }
        start += 2;
    }
    return error.EntityTooLarge;
}


pub fn seekText(comptime target: []const u8, buff:[]const u8) !usize {
    var start: usize = 0;
    while(start+target.len < buff.len) {
            if(std.mem.eql(u8, buff[start..start+target.len], target)) {
                return start; 
            }
            start+=1;
    }
    return error.NotFound;
}

pub const Request = struct {
    const Self = @This();

    method: []const u8,
    uri: []const u8,
    headers: std.StringHashMap([]const u8),
};

pub const HTTPBuffer = struct {
    const B = @This();

    allocator: Allocator,
    buffer: []u8,
    consumed: usize = 0,
    used: usize = 0,
    socket: aio.TCP,

    pub fn init(allocator: Allocator, size: usize, socket: aio.TCP) !B {
        return . {
            .buffer = try allocator.alloc(u8, size),
            .allocator = allocator,
            .socket = socket,
        };
    }
    pub fn deinit(b:*B) void {
        b.allocator.free(b.buffer);
    }

    pub fn readUntil(b: *B, comptime needle: []const u8) ![]u8 {
        while(b.used < b.buffer.len) {
            const end = seekText(needle, b.buffer[b.consumed..b.used]) catch {
                b.used += try b.socket.read(.{ .slice = b.buffer[b.used..] });
                continue;
            };
            const out = b.buffer[b.consumed..b.consumed+end];
            b.consumed += end + needle.len;
            return out;
        }
        return error.EntityTooLarge;
    }

    pub fn skipCRCL(b: *B) !void {
        while(b.used < b.buffer.len) {
            b.consumed += seekNotCRCL(b.buffer[b.consumed..b.used]) catch {
                b.used += try b.socket.read(.{ .slice = b.buffer[b.used..] });
                continue;
            }; 
            return;
        }
        return error.EntityTooLarge;
    }
    
    pub fn skipChars(b: *B, comptime chars: []const u8) !void {
        outer: while(true) {
            for(chars) |char| {
                if(b.buffer[b.consumed] == char) {
                    b.consumed+=1;
                    continue :outer;
                }
            }
            return;
        }
    }

    pub fn peek(b: *B, len: usize) ![]const u8 {
        while(b.used < b.buffer.len) {
            if(len > b.buffer[b.consumed..b.used].len) {
                b.used += try b.socket.read(.{ .slice = b.buffer[b.used..] });
                continue;
            }
            return b.buffer[b.consumed..b.consumed+len];
        }
        return error.EntityTooLarge;
    }

    pub fn read(b: *B, len: usize) ![]u8 {
        while(b.used < b.buffer.len) {
            if(len > b.buffer[b.consumed..b.used].len) {
                b.used += try b.socket.read(.{ .slice = b.buffer[b.used..] });
                continue;
            }
            b.consumed += len;
            return b.buffer[b.consumed-len..b.consumed];
        }
        return error.EntityTooLarge;
    }
};

pub const Connection = struct {
    const Self = @This();

    state: State,
    arena: ArenaAllocator,
    socket: aio.TCP,

    pub fn init(allocator: Allocator, socket: aio.TCP) !Self {
        log.debug("Initalizing connection", .{});
        return . {
            .arena = ArenaAllocator.init(allocator),
            .socket = socket,
            .state = .ready,
        };
    }


    pub fn receiveHead(c: *Self) !void {
        assert(c.state == .ready);
        var httpBuffer = try HTTPBuffer.init(c.arena.allocator(), 8190, c.socket);
        defer httpBuffer.deinit();

        //_ = httpBuffer.readUntil("\r\n") catch {};
        // RFC2616 - Servers SHOULD ignore any empty line(s) received where a Request-Line is expected.
        // aka any CRLF at the start should be ignored
        log.debug("Reading Request-Line", .{});
        // Read Request-Line
        // Method SP Request-UCI SP HTTP-Version CRLF
    
        try httpBuffer.skipCRCL();
        const method = try httpBuffer.readUntil(" ");
        const uri = try httpBuffer.readUntil(" ");
        const http_version = try httpBuffer.readUntil("\r\n");

        
        // Method read 
        log.debug("method: '{s}' uri:'{s}' http_version:'{s}'", .{ method, uri, http_version });
        // RFC2616 - client MUST NOT preface or follow a request with an extra CRLF
        
        if (!std.mem.eql(u8, http_version, "HTTP/1.1")) {
            log.debug("{d}, {d}", .{ http_version.len, "HTTP/1.1".len });
            return error.HTTP_505;
        }
        var req = Request{
            .method = method,
            .uri = uri,
            .headers = std.StringHashMap([]const u8).init(c.arena.allocator()),
        };

        // Parse all the fields in the header
        while(true) {
            // Now parse all the headers
            const name = try httpBuffer.readUntil(":");

            try httpBuffer.skipChars(" \t");

            // Now parse the value
            const value = try httpBuffer.readUntil("\r\n");

            try req.headers.put(std.ascii.lowerString(name, name), value);
            log.debug("'{s}':'{s}'", .{ name, value });
            if(std.mem.eql(u8, try httpBuffer.peek(2), "\r\n")) {
                    httpBuffer.consumed +=2;
                    break;
            }
        }
        const content_len = try std.fmt.parseInt(usize, req.headers.get("content-length").?, 10);
        log.debug("len: {d}", .{ content_len});

        const body = try httpBuffer.read(content_len); 

        //len = try c.socket.read(.{ .slice = body });
        //if (len != content_len)  {
        //    return error.BodyTooSmall;
        //}
        log.debug("body: '{s}'", .{ body });
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }
};

