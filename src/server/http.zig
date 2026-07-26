const std = @import("std");
const types = @import("../core/types.zig");
const router = @import("router.zig");
const svg = @import("../render/svg.zig");
const png = @import("../render/png.zig");
const group = @import("../render/group.zig");
const themes = @import("../render/themes.zig");
const memo = @import("../db/memo.zig");
const token_pool = @import("../db/token_pool.zig");
const hex_util = @import("../util/hex.zig");
const contrast = @import("../util/contrast.zig");
const audit = @import("../util/audit.zig");
const providers = @import("providers.zig");
const static_provider = @import("../providers/static.zig");

/// shieldcn-zig — server/http.zig
/// HTTP server using raw POSIX sockets (Zig 0.16 std.Io.net lacks listen() API).
///
/// Each request emits one structured JSON audit line to stderr (see
/// util/audit.zig). The audit record is stored in a global during
/// handleClient and flushed from the listen loop after handleClient
/// returns, writing from a shallower stack frame. Responses use a
/// dynamic body path so PNG and badge-group payloads are handled
/// without a fixed contiguous buffer.
pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server_fd: i32,
    memo_store: memo.MemoStore,
    token_pool: token_pool.TokenPool,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, host: []const u8, port: u16) !Server {
        // Create socket using raw POSIX syscalls
        const sock_fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (sock_fd < 0) {
            return error.SocketCreateFailed;
        }

        // Enable SO_REUSEADDR
        var opt: c_int = 1;
        _ = std.c.setsockopt(sock_fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &opt, @sizeOf(c_int));

        // Parse address and bind
        const parsed_host = try parseIpv4(host);
        var addr: std.c.sockaddr.in = .{
            .family = std.c.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, parsed_host),
        };

        const rc = std.c.bind(sock_fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in));
        if (rc < 0) {
            _ = std.c.close(sock_fd);
            return error.BindFailed;
        }

        // Call listen()
        const listen_rc = std.c.listen(sock_fd, 128);
        if (listen_rc < 0) {
            _ = std.c.close(sock_fd);
            return error.ListenFailed;
        }

        return .{
            .allocator = allocator,
            .io = io,
            .server_fd = sock_fd,
            .memo_store = memo.MemoStore.init(allocator),
            .token_pool = token_pool.TokenPool.init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        _ = std.c.close(self.server_fd);
        self.memo_store.deinit();
        self.token_pool.deinit();
    }

    pub fn listen(self: *Server) !void {
        std.log.info("shieldcn server listening", .{});

        while (true) {
            var client_addr: std.c.sockaddr.in = undefined;
            var addr_len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
            const client_fd = std.c.accept(self.server_fd, @ptrCast(&client_addr), &addr_len);
            if (client_fd < 0) {
                std.log.err("Accept failed", .{});
                continue;
            }

            // Handle client connection. handleClient stores the audit
            // record in a global; we flush it here from the shallow listen
            // stack frame (not from handleClient's defer where the
            // 4096-byte read_buf is still live).
            self.handleClient(client_fd) catch |err| {
                std.log.err("Client handler error: {}", .{err});
            };
            audit.flushPending();
            _ = std.c.close(client_fd);
        }
    }

    fn handleClient(self: *Server, client_fd: i32) !void {
        var read_buf: [4096]u8 = undefined;
        const bytes_read = std.c.recv(client_fd, &read_buf, read_buf.len, 0);
        if (bytes_read <= 0) {
            return error.ReadFailed;
        }

        const request = read_buf[0..@intCast(bytes_read)];

        // Audit bookkeeping — store the record in a global; the listen
        // loop calls audit.flushPending(io) after handleClient returns.
        const start_ns = audit.monoNs();
        var audit_status: u16 = 200;
        var audit_provider: []const u8 = "";
        var audit_format: []const u8 = "";
        var audit_method: []const u8 = "";
        var audit_path: []const u8 = "";
        defer audit.storePending(.{
            .method = audit_method,
            .path = audit_path,
            .provider = audit_provider,
            .format = audit_format,
            .status = audit_status,
            .latency_us = audit.elapsedUs(start_ns),
        });

        // Parse request line
        var request_it = std.mem.splitScalar(u8, request, '\r');
        const request_line = request_it.next() orelse {
            audit_status = 400;
            return error.InvalidRequest;
        };
        var parts_it = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts_it.next() orelse {
            audit_status = 400;
            return error.InvalidRequest;
        };
        const raw_path = parts_it.next() orelse {
            audit_status = 400;
            return error.InvalidRequest;
        };
        audit_method = method;
        audit_path = raw_path;

        if (std.mem.eql(u8, method, "PUT")) {
            if (std.mem.startsWith(u8, raw_path, "/memo/")) {
                const key_start = "/memo/".len;
                const key_end = std.mem.indexOfScalar(u8, raw_path[key_start..], '.') orelse raw_path.len;
                const key = raw_path[key_start..key_end];

                var body_it = std.mem.splitSequence(u8, request, "\r\n\r\n");
                _ = body_it.next();
                const json_body = body_it.next() orelse "";

                const parsed = std.json.parseFromSlice(struct {
                    label: []const u8,
                    value: []const u8,
                    color: ?[]const u8 = null,
                }, self.allocator, json_body, .{}) catch {
                    audit_status = 400;
                    respond(client_fd, 400, "application/json", "{\"error\":\"invalid json\"}");
                    return;
                };
                defer parsed.deinit();

                self.memo_store.set(key, parsed.value.label, parsed.value.value, parsed.value.color, null, null) catch {};
                audit_provider = "memo";
                respond(client_fd, 200, "application/json", "{\"status\":\"ok\"}");
                return;
            } else {
                audit_status = 405;
                respond(client_fd, 405, "text/plain", "Method Not Allowed");
                return;
            }
        }

        if (!std.mem.eql(u8, method, "GET")) {
            audit_status = 405;
            respond(client_fd, 405, "text/plain", "Method Not Allowed");
            return;
        }

        if (std.mem.eql(u8, raw_path, "/health")) {
            audit_provider = "health";
            respond(client_fd, 200, "application/json", "{\"status\":\"ok\"}");
            return;
        }

        // Handle badge routes
        var route = router.parseBadgePath(self.allocator, raw_path) catch {
            audit_status = 400;
            respondError(self.allocator, client_fd, "error", "invalid");
            return;
        };
        defer route.deinit(self.allocator);
        audit_provider = route.provider;
        audit_format = route.format;

        // Group provider: stack N static badges vertically. SVG only.
        if (std.mem.eql(u8, route.provider, "group")) {
            if (!std.mem.eql(u8, route.format, "svg")) {
                audit_status = 400;
                respond(client_fd, 400, "text/plain", "group only supports svg");
                return;
            }
            self.respondGroup(client_fd, route) catch {
                audit_status = 500;
                respondError(self.allocator, client_fd, "error", "group");
            };
            return;
        }

        if (!std.mem.eql(u8, route.format, "svg") and !std.mem.eql(u8, route.format, "png") and !std.mem.eql(u8, route.format, "json")) {
            audit_status = 400;
            respondError(self.allocator, client_fd, "error", "format");
            return;
        }

        // Resolve badge data via provider registry.
        var badge_data = try providers.resolveBadge(.{
            .allocator = self.allocator,
            .io = self.io,
            .memo_store = &self.memo_store,
            .token_pool = &self.token_pool,
        }, route);
        defer if (badge_data) |*bd| bd.deinit();

        if (badge_data == null) {
            audit_status = 500;
            respondError(self.allocator, client_fd, "error", "provider");
            return;
        }

        const resolved = badge_data.?;
        const label = route.query.label orelse resolved.label;
        const value = resolved.value;

        // Effective color: ?color= query param takes precedence over path color.
        const effective_color = route.query.color orelse resolved.color;

        // For branded variant, the effective color IS the brand color — resolve
        // named colors to hex and pass to resolveTheme for the entire badge.
        const branded_color: ?[]const u8 = blk: {
            if (route.query.variant != .branded) break :blk route.query.color;
            if (effective_color) |c| {
                if (resolveColorHex(c)) |hex| break :blk hex;
            }
            break :blk route.query.color;
        };

        var colors = themes.resolveTheme(route.query.variant, route.query.mode, route.query.theme, branded_color, route.query.label_color, route.query.value_color);

        // Apply path color to value section for standard variants (not branded/destructive).
        // branded: entire badge is the brand color (no split needed).
        // destructive: always red, ignore path color.
        var force_split = false;
        if (route.query.variant != .branded and route.query.variant != .destructive) {
            if (effective_color) |c| {
                if (resolveColorHex(c)) |hex| {
                    colors.value_bg = hex;
                    force_split = true;
                    // Auto-select value text color (white/dark) for contrast
                    if (route.query.value_color == null) {
                        if (hex_util.parseHex(hex)) |rgb| {
                            colors.value_fg = contrast.autoForeground(rgb);
                        }
                    }
                }
            }
        }

        const preset = types.getSizePreset(route.query.size);
        const config = types.BadgeConfig{
            .label = label,
            .value = value,
            .colors = colors,
            .style = route.query.variant,
            .size = route.query.size,
            .mode = route.query.mode,
            .font = route.query.font,
            .split = route.query.split or force_split,
            .status_dot = route.query.status_dot,
            .status_color = null,
            .value_color = route.query.value_color,
            .label_text_color = route.query.label_text_color,
            .label_opacity = route.query.label_opacity,
            .height = route.query.height orelse preset.height,
            .font_size = route.query.font_size orelse preset.font_size,
            .radius = route.query.radius orelse preset.radius,
            .pad_x = route.query.pad_x orelse preset.pad_x,
            .icon_size = route.query.icon_size orelse preset.icon_size,
            .gap = route.query.gap orelse preset.gap,
            .label_gap = route.query.label_gap orelse preset.label_gap,
            .brand_color = route.query.color,
            .gradient = route.query.gradient,
            .icon = null,
            .icon_fill = null,
        };

        if (std.mem.eql(u8, route.format, "svg")) {
            const svg_body = svg.renderBadgeSvg(self.allocator, config) catch {
                audit_status = 500;
                respondError(self.allocator, client_fd, "error", "render");
                return;
            };
            defer self.allocator.free(svg_body);
            respond(client_fd, 200, "image/svg+xml", svg_body);
        } else if (std.mem.eql(u8, route.format, "png")) {
            const png_body = png.renderBadgePng(self.allocator, config) catch {
                audit_status = 500;
                respondError(self.allocator, client_fd, "error", "render");
                return;
            };
            defer self.allocator.free(png_body);
            respond(client_fd, 200, "image/png", png_body);
        } else {
            const json_body = std.fmt.allocPrint(self.allocator, "{{\"label\":\"{s}\",\"message\":\"{s}\",\"color\":\"{s}\",\"labelColor\":\"{s}\"}}", .{ label, value, colors.value_bg, colors.label_bg }) catch {
                audit_status = 500;
                respondError(self.allocator, client_fd, "error", "json");
                return;
            };
            defer self.allocator.free(json_body);
            respond(client_fd, 200, "application/json", json_body);
        }
    }

    /// Render a group of static badges from a `/group/a|b|c.svg` route.
    /// Each sub-spec follows the static badge form `label-message-color`.
    fn respondGroup(self: *Server, client_fd: i32, route: router.Route) !void {
        if (route.segments.len < 2) {
            respondError(self.allocator, client_fd, "group", "empty");
            return;
        }

        const spec_blob = route.segments[1];
        var spec_list: std.ArrayList([]const u8) = .empty;
        defer {
            for (spec_list.items) |s| self.allocator.free(s);
            spec_list.deinit(self.allocator);
        }
        var spec_it = std.mem.splitScalar(u8, spec_blob, '|');
        while (spec_it.next()) |spec| {
            if (spec.len == 0) continue;
            try spec_list.append(self.allocator, try self.allocator.dupe(u8, spec));
        }
        if (spec_list.items.len == 0) {
            respondError(self.allocator, client_fd, "group", "empty");
            return;
        }

        const colors = themes.resolveTheme(route.query.variant, route.query.mode, route.query.theme, route.query.color, route.query.label_color, route.query.value_color);
        const preset = types.getSizePreset(route.query.size);

        var configs: std.ArrayList(types.BadgeConfig) = .empty;
        defer configs.deinit(self.allocator);

        for (spec_list.items) |spec| {
            // Reuse the static badge parser: it expects segments[1] = spec.
            var segs = [_][]const u8{ "badge", spec };
            var bd = static_provider.parseStaticBadge(self.allocator, &segs) catch types.BadgeData{ .label = "badge", .value = "invalid" };
            defer bd.deinit();

            // Per-badge color override (named color or hex) on the value side.
            var badge_colors = colors;
            var force_split = false;
            if (bd.color) |c| {
                if (resolveColorHex(c)) |hex| {
                    badge_colors.value_bg = hex;
                    force_split = true;
                    // Auto-select value text color (white/dark) for contrast
                    if (route.query.value_color == null) {
                        if (hex_util.parseHex(hex)) |rgb| {
                            badge_colors.value_fg = contrast.autoForeground(rgb);
                        }
                    }
                }
            }

            try configs.append(self.allocator, .{
                .label = bd.label,
                .value = bd.value,
                .colors = badge_colors,
                .style = route.query.variant,
                .size = route.query.size,
                .mode = route.query.mode,
                .font = route.query.font,
                .split = route.query.split or force_split,
                .status_dot = route.query.status_dot,
                .label_opacity = route.query.label_opacity,
                .height = route.query.height orelse preset.height,
                .font_size = route.query.font_size orelse preset.font_size,
                .radius = route.query.radius orelse preset.radius,
                .pad_x = route.query.pad_x orelse preset.pad_x,
                .icon_size = route.query.icon_size orelse preset.icon_size,
                .gap = route.query.gap orelse preset.gap,
                .label_gap = route.query.label_gap orelse preset.label_gap,
                .brand_color = route.query.color,
                .gradient = route.query.gradient,
            });
        }

        const group_svg = try group.renderBadgeGroupSvg(self.allocator, configs.items, .{ .gap = 4 });
        defer self.allocator.free(group_svg);
        respond(client_fd, 200, "image/svg+xml", group_svg);
    }
};

fn parseIpv4(host: []const u8) !u32 {
    if (std.mem.eql(u8, host, "0.0.0.0")) return 0;
    if (std.mem.eql(u8, host, "127.0.0.1")) return 0x7F000001;
    if (std.mem.eql(u8, host, "localhost")) return 0x7F000001;

    var parts = std.mem.splitScalar(u8, host, '.');
    var result: u32 = 0;
    var i: u32 = 0;
    while (parts.next()) |part| : (i += 1) {
        if (i >= 4) return error.InvalidIp;
        const num = std.fmt.parseInt(u8, part, 10) catch return error.InvalidIp;
        result = (result << 8) | num;
    }
    if (i != 4) return error.InvalidIp;
    return result;
}

/// Send an HTTP response with a dynamic-length body. Header is formatted
/// into a stack buffer; header and body are sent in two write(2) calls so
/// arbitrarily large bodies (PNG, badge groups) are supported without a
/// fixed contiguous buffer.
fn respond(fd: i32, status: u16, content_type: []const u8, body: []const u8) void {
    const status_text = switch (status) {
        200 => "200 OK",
        400 => "400 Bad Request",
        404 => "404 Not Found",
        405 => "405 Method Not Allowed",
        500 => "500 Internal Server Error",
        else => "200 OK",
    };

    var hdr: [256]u8 = undefined;
    const header = std.fmt.bufPrint(
        &hdr,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: max-age=300\r\n\r\n",
        .{ status_text, content_type, body.len },
    ) catch return;

    _ = std.c.send(fd, header.ptr, header.len, 0);
    if (body.len > 0) _ = std.c.send(fd, body.ptr, body.len, 0);
}

fn respondError(allocator: std.mem.Allocator, fd: i32, label: []const u8, value: []const u8) void {
    const colors = types.ResolvedColors{
        .label_bg = "#dc2626",
        .label_fg = "#ffffff",
        .value_bg = "#dc2626",
        .value_fg = "#ffffff",
        .border = null,
    };
    const svg_body = svg.renderSimple(allocator, label, value, colors) catch {
        respond(fd, 500, "text/plain", "Error rendering badge");
        return;
    };
    defer allocator.free(svg_body);
    respond(fd, 200, "image/svg+xml", svg_body);
}

/// Resolve a shields.io-style color name (or hex) to a hex string.
/// Returns null if the name is unrecognized and not a valid hex.
fn resolveColorHex(name: []const u8) ?[]const u8 {
    const Named = struct { n: []const u8, h: []const u8 };
    const map = [_]Named{
        .{ .n = "brightgreen", .h = "#4c1" },
        .{ .n = "green", .h = "#97ca00" },
        .{ .n = "success", .h = "#97ca00" },
        .{ .n = "yellow", .h = "#dfb317" },
        .{ .n = "yellowgreen", .h = "#a4a61d" },
        .{ .n = "orange", .h = "#fe7d37" },
        .{ .n = "red", .h = "#e05d44" },
        .{ .n = "critical", .h = "#e05d44" },
        .{ .n = "blue", .h = "#007ec6" },
        .{ .n = "informational", .h = "#007ec6" },
        .{ .n = "blueviolet", .h = "#8a2be2" },
        .{ .n = "purple", .h = "#8a2be2" },
        .{ .n = "lightgrey", .h = "#9f9f9f" },
        .{ .n = "grey", .h = "#555" },
        .{ .n = "gray", .h = "#555" },
        .{ .n = "important", .h = "#fe7d37" },
    };
    for (map) |m| {
        if (std.mem.eql(u8, m.n, name)) return m.h;
    }
    // Treat as hex if it starts with '#' or is 3/6 hex digits.
    if (name.len > 0 and name[0] == '#') return name;
    if (name.len == 3 or name.len == 6) {
        for (name) |c| {
            switch (c) {
                '0'...'9', 'a'...'f', 'A'...'F' => {},
                else => return null,
            }
        }
        // Bare hex without '#' — prepend '#' so SVG fill attribute works.
        // Use a static buffer pool since we need to return a pointer.
        const HexBuf = struct { var buf: [8]u8 = .{ '#', 0, 0, 0, 0, 0, 0, 0 }; };
        HexBuf.buf[0] = '#';
        @memcpy(HexBuf.buf[1 .. 1 + name.len], name);
        return HexBuf.buf[0 .. 1 + name.len];
    }
    return null;
}
