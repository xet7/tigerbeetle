//! Log IO/CPU event spans for analysis/visualization.
//!
//! Example:
//!
//!     $ ./tigerbeetle start --experimental --trace=trace.json
//!
//! or:
//!
//!     $ ./tigerbeetle benchmark --trace=trace.json
//!
//! The trace JSON output is compatible with:
//! - https://ui.perfetto.dev/
//! - https://gravitymoth.com/spall/spall.html
//! - chrome://tracing/
//!
//! Example integrations:
//!
//!     // Trace a synchronous event.
//!     // The second argument is a `anytype` struct, corresponding to the struct argument to
//!     // `log.debug()`.
//!     tree.grid.trace.start(.{ .compact_mutable = .{ .tree = tree.config.name } });
//!     defer tree.grid.trace.stop(.{ .compact_mutable = .{ .tree = tree.config.name } });
//!
//! Note that only one of each Event can be running at a time:
//!
//!     // good
//!     trace.start(.{.foo = .{}});
//!     trace.stop(.{ .foo = .{} });
//!     trace.start(.{ .bar = .{} });
//!     trace.stop(.{ .bar = .{} });
//!
//!     // good
//!     trace.start(.{ .foo = .{} });
//!     trace.start(.{ .bar = .{} });
//!     trace.stop(.{ .foo = .{} });
//!     trace.stop(.{ .bar = .{} });
//!
//!     // bad
//!     trace.start(.{ .foo = .{} });
//!     trace.start(.{ .foo = .{} });
//!
//!     // bad
//!     trace.stop(.{ .foo = .{} });
//!     trace.start(.{ .foo = .{} });
//!
//! If an event is is cancelled rather than properly stopped, use .reset():
//! - Reset is safe to call regardless of whether the event is currently started.
//! - For events with multiple instances (e.g. IO reads and writes), .reset() will
//!   cancel all running traces of the same event.
//!
//!     // good
//!     trace.start(.{ .foo = .{} });
//!     trace.cancel(.foo);
//!     trace.start(.{ .foo = .{} });
//!     trace.stop(.{ .foo = .{} });
//!
//! Notes:
//! - When enabled, traces are written to stdout (as opposed to logs, which are written to stderr).
//! - The JSON output is a "[" followed by a comma-separated list of JSON objects. The JSON array is
//!   never closed with a "]", but Chrome, Spall, and Perfetto all handle this.
//! - Event pairing (start/stop) is asserted at runtime.
//! - `trace.start()/.stop()/.reset()` will `log.debug()` regardless of whether tracing is enabled.
//!
//! The JSON output looks like:
//!
//!     {
//!         // Process id:
//!         // The replica index is encoded as the "process id" of trace events, so events from
//!         // multiple replicas of a cluster can be unified to visualize them on the same timeline.
//!         "pid": 0,
//!
//!         // Thread id:
//!         "tid": 0,
//!
//!         // Category.
//!         "cat": "replica_commit",
//!
//!         // Phase.
//!         "ph": "B",
//!
//!         // Timestamp:
//!         // Microseconds since program start.
//!         "ts": 934327,
//!
//!         // Event name:
//!         // Includes the event name and a *low cardinality subset* of the second argument to
//!         // `trace.start()`. (Low-cardinality part so that tools like Perfetto can distinguish
//!         // events usefully.)
//!         "name": "replica_commit stage='next_pipeline'",
//!
//!         // Extra event arguments. (Encoded from the second argument to `trace.start()`).
//!         "args": {
//!             "stage": "next_pipeline",
//!             "op": 1
//!         },
//!     },
//!
const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.trace);

const constants = @import("constants.zig");
const stdx = @import("stdx.zig");
const IO = @import("io.zig").IO;
const StatsD = @import("trace/statsd.zig").StatsD;
pub const Event = @import("trace/event.zig").Event;
pub const EventMetric = @import("trace/event.zig").EventMetric;
pub const EventTracing = @import("trace/event.zig").EventTracing;
pub const EventTiming = @import("trace/event.zig").EventTiming;
pub const EventTimingAggregate = @import("trace/event.zig").EventTimingAggregate;
pub const EventMetricAggregate = @import("trace/event.zig").EventMetricAggregate;

const trace_span_size_max = 1024;

pub fn TracerType(comptime Time: type) type {
    return struct {
        time: *Time,
        replica_index: u8,
        options: Options,
        buffer: []u8,
        statsd: StatsD,

        events_started: [EventTracing.stack_count]?stdx.Instant =
            .{null} ** EventTracing.stack_count,
        events_metric: []?EventMetricAggregate,
        events_timing: []?EventTimingAggregate,

        time_start: stdx.Instant,

        const Tracer = @This();

        pub const Options = struct {
            /// The tracer still validates start/stop state even when writer=null.
            writer: ?std.io.AnyWriter = null,
            statsd_options: union(enum) {
                log,
                udp: struct {
                    io: *IO,
                    address: std.net.Address,
                },
            } = .log,
        };

        pub fn init(
            allocator: std.mem.Allocator,
            time: *Time,
            cluster: u128,
            replica_index: u8,
            options: Options,
        ) !Tracer {
            if (options.writer) |writer| {
                try writer.writeAll("[\n");
            }

            const buffer = try allocator.alloc(u8, trace_span_size_max);
            errdefer allocator.free(buffer);

            var statsd = try switch (options.statsd_options) {
                .log => StatsD.init_log(allocator, cluster, replica_index),
                .udp => |statsd_options| StatsD.init_udp(
                    allocator,
                    cluster,
                    replica_index,
                    statsd_options.io,
                    statsd_options.address,
                ),
            };
            errdefer statsd.deinit(allocator);

            const events_metric =
                try allocator.alloc(?EventMetricAggregate, EventMetric.slot_count);
            errdefer allocator.free(events_metric);
            @memset(events_metric, null);

            const events_timing =
                try allocator.alloc(?EventTimingAggregate, EventTiming.slot_count);
            errdefer allocator.free(events_timing);
            @memset(events_timing, null);

            return .{
                .time = time,
                .replica_index = replica_index,
                .options = options,
                .buffer = buffer,
                .statsd = statsd,

                .events_metric = events_metric,
                .events_timing = events_timing,

                .time_start = time.monotonic_instant(),
            };
        }

        pub fn deinit(tracer: *Tracer, allocator: std.mem.Allocator) void {
            allocator.free(tracer.events_timing);
            allocator.free(tracer.events_metric);
            tracer.statsd.deinit(allocator);
            allocator.free(tracer.buffer);
            tracer.* = undefined;
        }

        /// Gauges work on a last-set wins. Multiple calls to .record_gauge() followed by an emit
        /// will result in only the last value being submitted.
        pub fn gauge(tracer: *Tracer, event: EventMetric, value: u64) void {
            const timing_slot = event.slot();
            tracer.events_metric[timing_slot] = .{
                .event = event,
                .value = value,
            };
        }

        pub fn start(tracer: *Tracer, event: Event) void {
            const event_tracing = event.as(EventTracing);
            const event_timing = event.as(EventTiming);
            const stack = event_tracing.stack();

            const time_now = tracer.time.monotonic_instant();

            assert(tracer.events_started[stack] == null);
            tracer.events_started[stack] = time_now;

            log.debug(
                "{}: {s}({}): start: {}",
                .{ tracer.replica_index, @tagName(event), event_tracing, event_timing },
            );

            const writer = tracer.options.writer orelse return;
            const time_elapsed = time_now.duration_since(tracer.time_start);

            var buffer_stream = std.io.fixedBufferStream(tracer.buffer);

            // String tid's would be much more useful.
            // They are supported by both Chrome and Perfetto, but rejected by Spall.
            buffer_stream.writer().print("{{" ++
                "\"pid\":{[process_id]}," ++
                "\"tid\":{[thread_id]}," ++
                "\"ph\":\"{[event]c}\"," ++
                "\"ts\":{[timestamp]}," ++
                "\"cat\":\"{[category]s}\"," ++
                "\"name\":\"{[category]s} {[event_tracing]} {[event_timing]}\"," ++
                "\"args\":{[args]s}" ++
                "}},\n", .{
                .process_id = tracer.replica_index,
                .thread_id = event_tracing.stack(),
                .category = @tagName(event),
                .event = 'B',
                .timestamp = time_elapsed.microseconds(),
                .event_tracing = event_tracing,
                .event_timing = event_timing,
                .args = std.json.Formatter(Event){ .value = event, .options = .{} },
            }) catch {
                log.err("{}: {s}({}): event too large: {}", .{
                    tracer.replica_index,
                    @tagName(event),
                    event_tracing,
                    event_timing,
                });
                return;
            };

            writer.writeAll(buffer_stream.getWritten()) catch |err| {
                std.debug.panic("Tracer.start: {}\n", .{err});
            };
        }

        pub fn stop(tracer: *Tracer, event: Event) void {
            const us_log_threshold_ns = 5 * std.time.ns_per_ms;

            const event_tracing = event.as(EventTracing);
            const event_timing = event.as(EventTiming);
            const stack = event_tracing.stack();

            const event_start = tracer.events_started[stack].?;
            const event_end = tracer.time.monotonic_instant();
            const event_duration = event_end.duration_since(event_start);

            assert(tracer.events_started[stack] != null);
            tracer.events_started[stack] = null;

            // Double leading space to align with 'start: '.
            log.debug("{}: {s}({}): stop:  {} (duration={}{s})", .{
                tracer.replica_index,
                @tagName(event),
                event_tracing,
                event_timing,
                if (event_duration.nanoseconds < us_log_threshold_ns)
                    event_duration.microseconds()
                else
                    event_duration.milliseconds(),
                if (event_duration.nanoseconds < us_log_threshold_ns) "us" else "ms",
            });

            tracer.timing(event_timing, event_duration.microseconds());

            tracer.write_stop(stack, event_duration);
        }

        pub fn cancel(tracer: *Tracer, event_tag: Event.Tag) void {
            const stack_base = EventTracing.stack_bases.get(event_tag);
            const cardinality = EventTracing.stack_limits.get(event_tag);
            const event_end = tracer.time.monotonic_instant();
            for (stack_base..stack_base + cardinality) |stack| {
                if (tracer.events_started[stack]) |event_start| {
                    log.debug("{}: {s}: cancel", .{ tracer.replica_index, @tagName(event_tag) });

                    const event_duration = event_end.duration_since(event_start);

                    tracer.events_started[stack] = null;
                    tracer.write_stop(@intCast(stack), event_duration);
                }
            }
        }

        fn write_stop(tracer: *Tracer, stack: u32, time_elapsed: stdx.Duration) void {
            const writer = tracer.options.writer orelse return;
            var buffer_stream = std.io.fixedBufferStream(tracer.buffer);

            buffer_stream.writer().print(
                "{{" ++
                    "\"pid\":{[process_id]}," ++
                    "\"tid\":{[thread_id]}," ++
                    "\"ph\":\"{[event]c}\"," ++
                    "\"ts\":{[timestamp]}" ++
                    "}},\n",
                .{
                    .process_id = tracer.replica_index,
                    .thread_id = stack,
                    .event = 'E',
                    .timestamp = time_elapsed.microseconds(),
                },
            ) catch unreachable;

            writer.writeAll(buffer_stream.getWritten()) catch |err| {
                std.debug.panic("Tracer.stop: {}\n", .{err});
            };
        }

        pub fn emit_metrics(tracer: *Tracer) void {
            tracer.start(.metrics_emit);
            defer tracer.stop(.metrics_emit);

            tracer.statsd.emit(tracer.events_metric, tracer.events_timing) catch |err| {
                assert(err == error.Busy);
                return;
            };

            // For statsd, the right thing is to reset metrics between emitting. For something like
            // Prometheus, this would have to be removed.
            @memset(tracer.events_metric, null);
            @memset(tracer.events_timing, null);
        }

        // Timing works by storing the min, max, sum and count of each value provided. The avg is
        // calculated from sum and count at emit time.
        //
        // When these are emitted upstream (via statsd, currently), upstream must apply different
        // aggregations:
        // * min/max/avg are considered gauges for aggregation: last value wins.
        // * sum/count are considered counters for aggregation: they are added to the existing
        // values.
        //
        // This matches the default behavior of the `g` and `c` statsd types respectively.
        fn timing(tracer: *Tracer, event_timing: EventTiming, duration_us: u64) void {
            const timing_slot = event_timing.slot();

            if (tracer.events_timing[timing_slot]) |*event_timing_existing| {
                if (constants.verify) {
                    assert(std.meta.eql(event_timing_existing.event, event_timing));
                }

                const timing_existing = event_timing_existing.values;
                event_timing_existing.values = .{
                    .duration_min_us = @min(timing_existing.duration_min_us, duration_us),
                    .duration_max_us = @max(timing_existing.duration_max_us, duration_us),
                    .duration_sum_us = timing_existing.duration_sum_us +| duration_us,
                    .count = timing_existing.count +| 1,
                };
            } else {
                tracer.events_timing[timing_slot] = .{
                    .event = event_timing,
                    .values = .{
                        .duration_min_us = duration_us,
                        .duration_max_us = duration_us,
                        .duration_sum_us = duration_us,
                        .count = 1,
                    },
                };
            }
        }
    };
}

test "trace json" {
    const Time = @import("testing/time.zig").Time;
    const Tracer = TracerType(Time);
    const Snap = @import("testing/snaptest.zig").Snap;
    const snap = Snap.snap;

    var trace_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer trace_buffer.deinit();

    var time: Time = .{
        .resolution = constants.tick_ms * std.time.ns_per_ms,
        .offset_type = .linear,
        .offset_coefficient_A = 0,
        .offset_coefficient_B = 0,
    };

    var trace = try Tracer.init(std.testing.allocator, &time, 0, 0, .{
        .writer = trace_buffer.writer().any(),
    });
    defer trace.deinit(std.testing.allocator);

    trace.start(.{ .replica_commit = .{ .stage = .idle, .op = 123 } });
    trace.start(.{ .compact_beat = .{ .tree = @enumFromInt(1), .level_b = 1 } });
    trace.stop(.{ .compact_beat = .{ .tree = @enumFromInt(1), .level_b = 1 } });
    trace.stop(.{ .replica_commit = .{ .stage = .idle, .op = 456 } });

    try snap(@src(),
        \\[
        \\{"pid":0,"tid":0,"ph":"B","ts":<snap:ignore>,"cat":"replica_commit","name":"replica_commit  stage=idle","args":{"stage":"idle","op":123}},
        \\{"pid":0,"tid":4,"ph":"B","ts":<snap:ignore>,"cat":"compact_beat","name":"compact_beat  tree=Account.id","args":{"tree":"Account.id","level_b":1}},
        \\{"pid":0,"tid":4,"ph":"E","ts":<snap:ignore>},
        \\{"pid":0,"tid":0,"ph":"E","ts":<snap:ignore>},
        \\
    ).diff(trace_buffer.items);
}

test "timing overflow" {
    const Time = @import("testing/time.zig").Time;
    const Tracer = TracerType(Time);

    var trace_buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer trace_buffer.deinit();

    var time = Time.init_simple();
    var trace = try Tracer.init(std.testing.allocator, &time, 0, 0, .{
        .writer = trace_buffer.writer().any(),
    });
    defer trace.deinit(std.testing.allocator);

    const event: EventTiming = .replica_aof_write;
    const value = std.math.maxInt(u64) - 1;
    trace.timing(event, value);
    trace.timing(event, value);

    const aggregate = trace.events_timing[event.slot()].?;

    assert(aggregate.values.count == 2);
    assert(aggregate.values.duration_min_us == value);
    assert(aggregate.values.duration_max_us == value);
    assert(aggregate.values.duration_sum_us == std.math.maxInt(u64));
}
