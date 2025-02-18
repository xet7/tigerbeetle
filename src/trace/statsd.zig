const std = @import("std");
const stdx = @import("../stdx.zig");

const assert = std.debug.assert;

const IO = @import("../io.zig").IO;
const IOPSType = @import("../iops.zig").IOPSType;

const EventMetric = @import("event.zig").EventMetric;
const EventMetricAggregate = @import("event.zig").EventMetricAggregate;
const EventTiming = @import("event.zig").EventTiming;
const EventTimingAggregate = @import("event.zig").EventTimingAggregate;

const log = std.log.scoped(.statsd);

/// A reasonable value to keep the total length of the packet under a single MTU, for a local
/// network.
///
/// https://github.com/statsd/statsd/blob/master/docs/metric_types.md#multi-metric-packets
const packet_size_max = 1400;

/// No single metric may be larger than this value. If it is, it'll be dropped with an error
/// message. Since this is calculated at comptime, that means there's a bug in the calculation
/// logic.
const statsd_line_size_max = line_size_max: {
    // For each type of event, build a payload containing the maximum possible values for that
    // event. This is essentially maxInt for integer payloads, and the longest enum tag name for
    // enum payloads.
    var events_metric: [std.meta.fieldNames(EventMetric).len]EventMetricAggregate = undefined;
    for (&events_metric, std.meta.fields(EventMetric)) |*event_metric, EventMetricInner| {
        event_metric.* = .{
            .event = @unionInit(
                EventMetric,
                EventMetricInner.name,
                struct_size_max(EventMetricInner.type),
            ),
            .value = std.math.maxInt(EventMetricAggregate.ValueType),
        };
    }

    var events_timing: [std.meta.fieldNames(EventTiming).len]EventTimingAggregate = undefined;
    for (&events_timing, std.meta.fields(EventTiming)) |*event_timing, EventTimingInner| {
        event_timing.* = .{
            .event = @unionInit(
                EventTiming,
                EventTimingInner.name,
                struct_size_max(EventTimingInner.type),
            ),
            .values = .{
                .duration_min_us = std.math.maxInt(EventTimingAggregate.ValueType),
                .duration_max_us = std.math.maxInt(EventTimingAggregate.ValueType),
                .duration_sum_us = std.math.maxInt(EventTimingAggregate.ValueType),
                .count = std.math.maxInt(EventTimingAggregate.ValueType),
            },
        };
    }

    var buffer: [packet_size_max]u8 = undefined;
    var buffer_stream = std.io.fixedBufferStream(&buffer);
    const buffer_writer = buffer_stream.writer();

    var line_size_max: u32 = 0;
    for (events_metric) |event| {
        buffer_stream.reset();
        format_metric(
            buffer_writer,
            .{ .metric = .{ .aggregate = event } },
            .{ .cluster = 0, .replica = 0 },
        ) catch unreachable;
        line_size_max = @max(line_size_max, buffer_stream.getPos() catch unreachable);
    }
    for (events_timing) |event| {
        for (std.enums.values(TimingStat)) |stat| {
            buffer_stream.reset();
            format_metric(
                buffer_writer,
                .{ .timing = .{ .aggregate = event, .stat = stat } },
                .{ .cluster = 0, .replica = 0 },
            ) catch unreachable;
            line_size_max = @max(line_size_max, buffer_stream.getPos() catch unreachable);
        }
    }
    break :line_size_max line_size_max;
};

const packet_messages_max = @divFloor(packet_size_max, statsd_line_size_max);

comptime {
    assert(statsd_line_size_max <= packet_size_max);
    assert(packet_messages_max > 0);
}

/// This implementation emits on an open-loop: on the emit interval, it fires off up to
/// packet_count_max UDP packets, without waiting for completions.
///
/// The emit interval needs to be large enough that the kernel will have finished processing them
/// before emitting again. If not, an error will be logged.
const packet_count_max = stdx.div_ceil(
    EventMetric.slot_count + EventTiming.slot_count,
    packet_messages_max,
);

comptime {
    // Sanity-check:
    assert(packet_count_max > 0);
    assert(packet_count_max < 256);
}

pub const StatsD = struct {
    cluster: u128,
    replica: u8,
    implementation: union(enum) {
        udp: struct {
            socket: std.posix.socket_t,
            io: *IO,
            send_callback_error_count: u64 = 0,
        },
        log,
    },

    send_buffer: *[packet_count_max * packet_size_max]u8,
    send_completions: IOPSType(IO.Completion, packet_count_max) = .{},

    /// Creates a statsd instance, which will send UDP packets via the IO instance provided.
    pub fn init_udp(
        allocator: std.mem.Allocator,
        cluster: u128,
        replica: u8,
        io: *IO,
        address: std.net.Address,
    ) !StatsD {
        const socket = try io.open_socket(
            address.any.family,
            std.posix.SOCK.DGRAM,
            std.posix.IPPROTO.UDP,
        );
        errdefer io.close_socket(socket);

        const send_buffer = try allocator.create([packet_count_max * packet_size_max]u8);
        errdefer allocator.destroy(send_buffer);

        // 'Connect' the UDP socket, so we can just send() to it normally.
        try std.posix.connect(socket, &address.any, address.getOsSockLen());

        log.info("sending statsd metrics to {}", .{address});

        return .{
            .cluster = cluster,
            .replica = replica,
            .implementation = .{
                .udp = .{
                    .socket = socket,
                    .io = io,
                },
            },
            .send_buffer = send_buffer,
        };
    }

    // Creates a statsd instance, which will log out the packets that would have been sent. Useful
    // so that all of the other code can run and be tested in the simulator.
    pub fn init_log(
        allocator: std.mem.Allocator,
        cluster: u128,
        replica: u8,
    ) !StatsD {
        const send_buffer = try allocator.create([packet_count_max * packet_size_max]u8);
        errdefer allocator.destroy(send_buffer);

        return .{
            .cluster = cluster,
            .replica = replica,
            .implementation = .log,
            .send_buffer = send_buffer,
        };
    }

    pub fn deinit(self: *StatsD, allocator: std.mem.Allocator) void {
        if (self.implementation == .udp) {
            self.implementation.udp.io.close_socket(self.implementation.udp.socket);
        }
        allocator.destroy(self.send_buffer);

        self.* = undefined;
    }

    pub fn emit(
        self: *StatsD,
        events_metric: []const ?EventMetricAggregate,
        events_timing: []const ?EventTimingAggregate,
    ) error{Busy}!void {
        // This really should not happen; it means we're emitting so many packets, on a short
        // enough emit timeout, that the kernel hasn't been able to process them all (UDP doesn't
        // block or provide back-pressure like a TCP socket).
        //
        // Keep it as a log, rather than assert, to avoid the common pitfall of metrics killing
        // the whole system.
        if (self.send_completions.executing() != 0) {
            log.err("{} / {} packets still in flight; skipping emit", .{
                self.send_completions.executing(),
                packet_count_max,
            });
            return error.Busy;
        }

        if (self.implementation == .udp and self.implementation.udp.send_callback_error_count > 0) {
            log.warn(
                "failed to send {} packets",
                .{self.implementation.udp.send_callback_error_count},
            );
            self.implementation.udp.send_callback_error_count = 0;
        }

        var send_ready: u32 = 0;
        var send_sizes = stdx.BoundedArrayType(u32, packet_count_max){};
        var send_stream = std.io.fixedBufferStream(self.send_buffer);
        const send_writer = send_stream.writer();
        inline for (.{ events_metric, events_timing }) |events| {
            for (events) |event_new_maybe| {
                const event_new = event_new_maybe orelse continue;
                const stats = switch (@TypeOf(event_new)) {
                    EventMetricAggregate => [_]Stat{.{ .metric = .{ .aggregate = event_new } }},
                    EventTimingAggregate => [_]Stat{
                        .{ .timing = .{ .aggregate = event_new, .stat = .min } },
                        .{ .timing = .{ .aggregate = event_new, .stat = .max } },
                        .{ .timing = .{ .aggregate = event_new, .stat = .avg } },
                        .{ .timing = .{ .aggregate = event_new, .stat = .sum } },
                        .{ .timing = .{ .aggregate = event_new, .stat = .count } },
                    },
                    else => unreachable,
                };

                for (stats) |stat| {
                    const send_position_before = send_stream.getPos() catch unreachable;
                    format_metric(send_writer, stat, .{
                        .cluster = self.cluster,
                        .replica = self.replica,
                    }) catch |err| {
                        // This shouldn't ever happen, but don't allow metrics to kill the system.
                        assert(err == error.NoSpaceLeft);
                        log.err("insufficient buffer space", .{});
                        break;
                    };

                    const send_position_after = send_stream.getPos() catch unreachable;
                    const send_size: u32 = @intCast(send_position_after - send_position_before);
                    assert(send_size > 0);
                    if (send_ready + send_size > packet_size_max) {
                        assert(send_ready > 0);

                        send_sizes.append_assume_capacity(send_ready);
                        send_ready = send_size;
                    } else {
                        send_ready += send_size;
                    }
                }
            }
        }

        var send_offset: u32 = 0;
        for (send_sizes.const_slice()) |send_size| {
            const completion = self.send_completions.acquire() orelse {
                // This shouldn't ever happen, but don't allow metrics to kill the system.
                log.err("insufficient packets to emit any metrics", .{});
                return;
            };
            self.emit_buffer(completion, self.send_buffer[send_offset..][0..send_size]);
            send_offset += send_size;
        }
    }

    fn emit_buffer(self: *StatsD, send_completion: *IO.Completion, send_buffer: []const u8) void {
        switch (self.implementation) {
            .udp => |udp| {
                udp.io.send(
                    *StatsD,
                    self,
                    StatsD.send_callback,
                    send_completion,
                    udp.socket,
                    send_buffer,
                );
            },
            .log => {
                log.debug("statsd packet: {s}", .{send_buffer});
                StatsD.send_callback(self, send_completion, send_buffer.len);
            },
        }
    }

    /// The UDP packets containing the metrics are sent in a fire-and-forget manner.
    fn send_callback(self: *StatsD, completion: *IO.Completion, result: IO.SendError!usize) void {
        _ = result catch {
            // Errors are only supported when using UDP; not if calling this loopback.
            assert(self.implementation == .udp);
            self.implementation.udp.send_callback_error_count += 1;
        };
        self.send_completions.release(completion);
    }
};

const TimingStat = enum { min, max, avg, sum, count };
const Stat = union(enum) {
    metric: struct { aggregate: EventMetricAggregate },
    timing: struct { aggregate: EventTimingAggregate, stat: TimingStat },
};

fn format_metric(
    writer: anytype,
    stat: Stat,
    options: struct { cluster: u128, replica: u8 },
) error{NoSpaceLeft}!void {
    const stat_name = switch (stat) {
        inline else => |stat_data| @tagName(stat_data.aggregate.event),
    };

    const stat_suffix, const stat_type, const stat_value = switch (stat) {
        .metric => |data| .{ "", "g", data.aggregate.value },
        .timing => |data| switch (data.stat) {
            .count => .{ "_us.count", "c", data.aggregate.values.count },
            .sum => .{ "_us.sum", "c", data.aggregate.values.duration_sum_us },
            .min => .{ "_us.min", "g", data.aggregate.values.duration_min_us },
            .max => .{ "_us.max", "g", data.aggregate.values.duration_max_us },
            .avg => .{ "_us.avg", "g", @divFloor(
                data.aggregate.values.duration_sum_us,
                data.aggregate.values.count,
            ) },
        },
    };

    try writer.print("tb.{[name]s}{[name_suffix]s}:{[value]d}|{[statsd_type]s}" ++
        "|#cluster:{[cluster]x:0>32},replica:{[replica]d}", .{
        .name = stat_name,
        .name_suffix = stat_suffix,
        .statsd_type = stat_type,
        .value = stat_value,
        .cluster = options.cluster,
        .replica = options.replica,
    });

    switch (stat) {
        inline else => |stat_data| {
            switch (stat_data.aggregate.event) {
                inline else => |data| {
                    const Tags = @TypeOf(data);
                    if (@typeInfo(Tags) == .Struct) {
                        const fields = std.meta.fields(@TypeOf(data));
                        inline for (fields) |data_field| {
                            comptime assert(!std.mem.eql(u8, data_field.name, "cluster"));
                            comptime assert(!std.mem.eql(u8, data_field.name, "replica"));
                            comptime assert(@typeInfo(data_field.type) == .Int or
                                @typeInfo(data_field.type) == .Enum or
                                @typeInfo(data_field.type) == .Union);

                            const data_field_value = @field(data, data_field.name);
                            try writer.writeByte(',');
                            try writer.writeAll(data_field.name);
                            try writer.writeByte(':');

                            if (@typeInfo(data_field.type) == .Enum or
                                @typeInfo(data_field.type) == .Union)
                            {
                                try writer.print("{s}", .{@tagName(data_field_value)});
                            } else {
                                try writer.print("{}", .{data_field_value});
                            }
                        }
                    } else {
                        assert(@TypeOf(data) == void);
                    }
                },
            }
        },
    }
    try writer.writeByte('\n');
}

/// Returns an instance of a Struct (or void) with all fields set to what would result in the
/// longest length when formatted.
///
/// Integers get maxInt, and Enums get a value corresponding to `enum_size_max()`.
fn struct_size_max(StructOrVoid: type) StructOrVoid {
    if (@typeInfo(StructOrVoid) == .Void) return {};

    assert(@typeInfo(StructOrVoid) == .Struct);
    const Struct = StructOrVoid;

    var output: Struct = undefined;

    for (std.meta.fields(Struct)) |field| {
        const type_info = @typeInfo(field.type);
        assert(type_info == .Int or type_info == .Enum);
        assert(type_info != .Int or type_info.Int.signedness == .unsigned);
        switch (type_info) {
            .Int => @field(output, field.name) = std.math.maxInt(field.type),
            .Enum => @field(output, field.name) =
                std.enums.nameCast(field.type, enum_size_max(field.type)),
            else => @compileError("unsupported type"),
        }
    }

    return output;
}

/// Returns the longest @tagName for a given Enum.
fn enum_size_max(Enum: type) []const u8 {
    var tag_longest: []const u8 = "";
    for (std.meta.fieldNames(Enum)) |field_name| {
        if (field_name.len > tag_longest.len) {
            tag_longest = field_name;
        }
    }
    return tag_longest;
}
