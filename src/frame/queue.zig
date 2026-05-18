
const std = @import("std");
const pipeline = @import("pipeline.zig");

const ThreadMutex = struct {
    state: std.Io.Mutex = .init,

    pub fn unlock(self: *ThreadMutex) void {
        std.Io.Threaded.mutexUnlock(&self.state);
    }
};

fn lockMutex(mutex: *ThreadMutex) void {
    std.Io.Threaded.mutexLock(&mutex.state);
}

pub const TerminalSurface = struct {
    const PrepareMailbox = pipeline.LatestMailbox(pipeline.RenderRequest);
    const SubmitMailbox = pipeline.LatestMailbox(pipeline.PreparedFrame);

    mutex: ThreadMutex = .{},
    prepare_mailbox: PrepareMailbox = .{},
    submit_mailbox: SubmitMailbox = .{},
    latest_token: ?pipeline.SnapshotToken = null,
    submitted_frame: ?pipeline.SubmittedFrame = null,
    presented_token: ?pipeline.SnapshotToken = null,
    target_epoch: u64 = 0,
    visible: bool = true,
    metrics: Metrics = .{},

    pub const Action = enum {
        idle,
        prepare,
        submit,
        present,
    };

    pub const SubmitDecision = union(enum) {
        submit: pipeline.PreparedFrame,
        stale: pipeline.SnapshotToken,
        needs_full_prepare: pipeline.FullPrepareReason,
        idle,
    };

    pub const RejectedSubmit = struct {
        prepared: pipeline.PreparedFrame,
        reason: pipeline.FullPrepareReason,
    };

    pub const SubmitTransition = union(enum) {
        submit: pipeline.PreparedFrame,
        stale: pipeline.SnapshotToken,
        rejected: RejectedSubmit,
        idle,
    };

    pub const Metrics = struct {
        snapshot_publishes: u64 = 0,
        snapshot_hidden_drops: u64 = 0,
        snapshot_clean_drops: u64 = 0,
        prepare_requests: u64 = 0,
        prepare_coalesces: u64 = 0,
        prepare_forced_full: u64 = 0,
        prepare_takes: u64 = 0,
        prepared_publishes: u64 = 0,
        prepared_coalesces: u64 = 0,
        submit_takes: u64 = 0,
        submit_valid: u64 = 0,
        submit_rejected: u64 = 0,
        full_prepare_requests: u64 = 0,
        submitted_accepts: u64 = 0,
        presents: u64 = 0,
        target_invalidations: u64 = 0,
    };

    pub fn setVisible(self: *TerminalSurface, visible: bool) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.visible = visible;
    }

    pub fn bindTargetEpoch(self: *TerminalSurface, target_epoch: u64) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.target_epoch == target_epoch) return;
        self.target_epoch = target_epoch;
        if (self.submitted_frame) |*frame| frame.content_valid = false;
        self.metrics.target_invalidations +%= 1;
    }

    pub fn publishSnapshot(self: *TerminalSurface, token: pipeline.SnapshotToken, priority: pipeline.PreparePriority) ?u64 {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.latest_token = token;
        self.metrics.snapshot_publishes +%= 1;
        if (!self.visible) {
            self.metrics.snapshot_hidden_drops +%= 1;
            return null;
        }
        if (token.damage_kind == .none) {
            self.metrics.snapshot_clean_drops +%= 1;
            return null;
        }
        const request_token = self.prepareTokenForCurrentRetainedState(token);
        const effective_token = request_token;
        if (effective_token.damage_kind == .full and token.damage_kind != .full) self.metrics.prepare_forced_full +%= 1;
        if (self.prepare_mailbox.hasPending()) self.metrics.prepare_coalesces +%= 1;
        self.metrics.prepare_requests +%= 1;
        const request = pipeline.RenderRequest{
            .token = effective_token,
            .known_target_epoch = self.target_epoch,
            .allow_retained_reuse = true,
            .priority = priority,
        };
        const seq = self.prepare_mailbox.publish(request);
        return seq;
    }

    fn takePrepareEnvelope(self: *TerminalSurface) ?PrepareMailbox.Envelope {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const envelope = self.prepare_mailbox.takeLatest() orelse return null;
        self.metrics.prepare_takes +%= 1;
        return envelope;
    }

    pub fn takePrepare(self: *TerminalSurface) ?pipeline.RenderRequest {
        const envelope = self.takePrepareEnvelope() orelse return null;
        return envelope.item;
    }

    pub fn publishPrepared(self: *TerminalSurface, prepared: pipeline.PreparedFrame) u64 {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.submit_mailbox.hasPending()) self.metrics.prepared_coalesces +%= 1;
        self.metrics.prepared_publishes +%= 1;
        const seq = self.submit_mailbox.publish(prepared);
        return seq;
    }

    fn takeSubmitEnvelope(self: *TerminalSurface) ?SubmitMailbox.Envelope {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const envelope = self.submit_mailbox.takeLatest() orelse return null;
        self.metrics.submit_takes +%= 1;
        return envelope;
    }

    pub fn takeSubmitTransition(self: *TerminalSurface) SubmitTransition {
        const envelope = self.takeSubmitEnvelope() orelse return .idle;
        if (self.isStalePrepared(envelope.item.token)) return .{ .stale = envelope.item.token };

        const validation = self.validatePrepared(envelope.item);
        if (validation == .valid) {
            lockMutex(&self.mutex);
            defer self.mutex.unlock();
            self.metrics.submit_valid +%= 1;
            return .{ .submit = envelope.item };
        }

        const reason = fullPrepareReason(validation);
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.metrics.submit_rejected +%= 1;
        return .{ .rejected = .{ .prepared = envelope.item, .reason = reason } };
    }

    pub fn requestFullPrepare(self: *TerminalSurface, fallback: pipeline.SnapshotToken) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (!self.visible) return;
        const token = forceFull(self.latest_token orelse fallback);
        if (self.prepare_mailbox.hasPending()) self.metrics.prepare_coalesces +%= 1;
        self.metrics.full_prepare_requests +%= 1;
        self.metrics.prepare_requests +%= 1;
        _ = self.prepare_mailbox.publish(.{
            .token = token,
            .known_target_epoch = self.target_epoch,
            .allow_retained_reuse = false,
            .priority = .opportunistic,
        });
    }

    fn validatePrepared(self: *const TerminalSurface, prepared: pipeline.PreparedFrame) pipeline.SubmitValidation {
        const surface: *TerminalSurface = @constCast(self);
        lockMutex(&surface.mutex);
        defer surface.mutex.unlock();
        const submitted = self.submitted_frame orelse {
            return if (prepared.requiresRetainedBase()) .missing_retained_base else .valid;
        };
        return pipeline.validatePreparedFrame(prepared, submitted);
    }

    pub fn acceptSubmitted(self: *TerminalSurface, frame: pipeline.SubmittedFrame) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.submitted_frame = frame;
        self.target_epoch = frame.target_epoch;
        self.dropPrepareAtOrBefore(frame.token);
        self.metrics.submitted_accepts +%= 1;
    }

    pub fn markPresented(self: *TerminalSurface) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (self.submitted_frame) |frame| {
            self.presented_token = frame.token;
            self.metrics.presents +%= 1;
        }
    }

    pub fn submittedToken(self: *const TerminalSurface) ?pipeline.SnapshotToken {
        const surface: *TerminalSurface = @constCast(self);
        lockMutex(&surface.mutex);
        defer surface.mutex.unlock();
        return if (self.submitted_frame) |frame| frame.token else null;
    }

    pub fn nextAction(self: *TerminalSurface) Action {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        if (!self.visible) return .idle;
        if (self.submit_mailbox.hasPending()) return .submit;
        if (self.prepare_mailbox.hasPending()) return .prepare;
        const submitted = self.submitted_frame orelse return .idle;
        const presented = self.presented_token orelse return .present;
        if (submitted.token.isNewerThan(presented)) return .present;
        return .idle;
    }

    pub fn metricsSnapshot(self: *const TerminalSurface) Metrics {
        const surface: *TerminalSurface = @constCast(self);
        lockMutex(&surface.mutex);
        defer surface.mutex.unlock();
        return self.metrics;
    }

    pub fn resetMetrics(self: *TerminalSurface) void {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        self.metrics = .{};
    }

    pub fn takeMetrics(self: *TerminalSurface) Metrics {
        lockMutex(&self.mutex);
        defer self.mutex.unlock();
        const out = self.metrics;
        self.metrics = .{};
        return out;
    }

    fn prepareTokenForCurrentRetainedState(self: *const TerminalSurface, token: pipeline.SnapshotToken) pipeline.SnapshotToken {
        if (!token.requiresRetainedBase()) return token;
        const submitted = self.submitted_frame orelse return forceFull(token);
        if (!submitted.content_valid) return forceFull(token);
        if (submitted.token.geometry_epoch != token.geometry_epoch) return forceFull(token);
        if (submitted.token.snapshot_seq != token.damage_base_seq) return forceFull(token);
        return token;
    }

    fn forceFull(token: pipeline.SnapshotToken) pipeline.SnapshotToken {
        return .{
            .snapshot_seq = token.snapshot_seq,
            .dirty_epoch = token.dirty_epoch,
            .geometry_epoch = token.geometry_epoch,
            .damage_base_seq = 0,
            .damage_kind = .full,
        };
    }

    fn isStalePrepared(self: *const TerminalSurface, token: pipeline.SnapshotToken) bool {
        const surface: *TerminalSurface = @constCast(self);
        lockMutex(&surface.mutex);
        defer surface.mutex.unlock();
        const latest = self.latest_token orelse return false;
        return latest.isNewerThan(token);
    }

    fn dropPrepareAtOrBefore(self: *TerminalSurface, token: pipeline.SnapshotToken) void {
        self.prepare_mailbox.dropAtOrBefore(token);
    }

    pub fn takeValidatedSubmit(self: *TerminalSurface) SubmitDecision {
        return switch (self.takeSubmitTransition()) {
            .idle => .idle,
            .stale => |token| .{ .stale = token },
            .submit => |prepared| .{ .submit = prepared },
            .rejected => |rejected| .{ .needs_full_prepare = rejected.reason },
        };
    }
};

pub fn PreparedSlot(comptime Frame: type) type {
    return struct {
        const Self = @This();

        mutex: ThreadMutex = .{},
        frame: ?Frame = null,

        pub fn deinit(self: *Self) void {
            lockMutex(&self.mutex);
            defer self.mutex.unlock();
            if (self.frame) |*frame| frame.deinit();
            self.frame = null;
        }

        pub fn publish(self: *Self, frame: Frame) void {
            lockMutex(&self.mutex);
            defer self.mutex.unlock();
            if (self.frame) |*old| old.deinit();
            self.frame = frame;
        }

        pub fn take(self: *Self) ?Frame {
            lockMutex(&self.mutex);
            defer self.mutex.unlock();
            const frame = self.frame orelse return null;
            self.frame = null;
            return frame;
        }

        pub fn discard(self: *Self) void {
            lockMutex(&self.mutex);
            defer self.mutex.unlock();
            if (self.frame) |*frame| frame.deinit();
            self.frame = null;
        }

        pub fn hasFrame(self: *Self) bool {
            lockMutex(&self.mutex);
            defer self.mutex.unlock();
            return self.frame != null;
        }
    };
}

pub fn SurfaceExecutor(comptime Frame: type) type {
    return struct {
        const Self = @This();
        const Slot = PreparedSlot(Frame);

        pub const PrepareFn = *const fn (context: *anyopaque, request: pipeline.RenderRequest) anyerror!?Frame;

        pub const PrepareStep = union(enum) {
            idle,
            prepared,
            failed: anyerror,
        };

        surface: TerminalSurface = .{},
        prepared_slot: Slot = .{},

        pub fn deinit(self: *Self) void {
            self.prepared_slot.deinit();
        }

        pub fn publishSnapshot(self: *Self, token: pipeline.SnapshotToken, priority: pipeline.PreparePriority) ?u64 {
            return self.surface.publishSnapshot(token, priority);
        }

        pub fn nextAction(self: *Self) TerminalSurface.Action {
            return self.surface.nextAction();
        }

        pub fn prepareStep(self: *Self, context: *anyopaque, prepare: PrepareFn) PrepareStep {
            if (self.surface.nextAction() != .prepare) return .idle;
            const request = self.surface.takePrepare() orelse return .idle;
            const frame = prepare(context, request) catch |err| return .{ .failed = err };
            const prepared_frame = frame orelse return .idle;
            const prepared_meta = preparedFrameMeta(prepared_frame, request);
            self.prepared_slot.publish(prepared_frame);
            _ = self.surface.publishPrepared(prepared_meta);
            return .prepared;
        }

        pub fn takeValidatedSubmit(self: *Self) TerminalSurface.SubmitDecision {
            return self.surface.takeValidatedSubmit();
        }

        pub fn takePreparedForSubmit(self: *Self) ?Frame {
            return self.prepared_slot.take();
        }

        pub fn discardPrepared(self: *Self) void {
            self.prepared_slot.discard();
        }

        pub fn acceptSubmitted(self: *Self, frame: pipeline.SubmittedFrame) void {
            self.surface.acceptSubmitted(frame);
        }

        pub fn markPresented(self: *Self) void {
            self.surface.markPresented();
        }

    };
}

fn preparedFrameMeta(frame: anytype, request: pipeline.RenderRequest) pipeline.PreparedFrame {
    const Frame = @TypeOf(frame);
    if (@hasDecl(Frame, "pipelineFrame")) return frame.pipelineFrame(request);
    return .{
        .token = request.token,
        .required_base_seq = request.token.damage_base_seq,
        .required_target_epoch = request.known_target_epoch,
    };
}

fn fullPrepareReason(validation: pipeline.SubmitValidation) pipeline.FullPrepareReason {
    return switch (validation) {
        .valid => unreachable,
        .stale_geometry => .geometry_changed,
        .missing_retained_base => .retained_base_missing,
        .stale_retained_base => .retained_base_stale,
        .stale_target => .target_changed,
    };
}

test "surface coalesces snapshots into latest prepare request" {
    var surface = TerminalSurface{};

    _ = surface.publishSnapshot(.{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full }, .opportunistic);
    _ = surface.publishSnapshot(.{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .full }, .opportunistic);

    const request = surface.takePrepareEnvelope() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2), request.sequence);
    try std.testing.expectEqual(@as(u64, 2), request.item.token.snapshot_seq);
    try std.testing.expect(surface.takePrepareEnvelope() == null);
    const metrics_snapshot = surface.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 2), metrics_snapshot.snapshot_publishes);
    try std.testing.expectEqual(@as(u64, 2), metrics_snapshot.prepare_requests);
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.prepare_coalesces);
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.prepare_takes);
}

test "surface turns partial snapshot full without matching retained base" {
    var surface = TerminalSurface{};
    _ = surface.publishSnapshot(.{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial }, .opportunistic);

    const request = surface.takePrepareEnvelope() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(pipeline.DamageKind.full, request.item.token.damage_kind);
    try std.testing.expectEqual(@as(u64, 0), request.item.token.damage_base_seq);
    try std.testing.expectEqual(@as(u64, 1), surface.metricsSnapshot().prepare_forced_full);
}

test "surface preserves partial snapshot with matching retained base" {
    var surface = TerminalSurface{};
    surface.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 3, .damage_base_seq = 0, .damage_kind = .full },
        .target_epoch = 9,
        .content_valid = true,
    });
    surface.bindTargetEpoch(9);

    _ = surface.publishSnapshot(.{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 3, .damage_base_seq = 1, .damage_kind = .partial }, .opportunistic);

    const request = surface.takePrepareEnvelope() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(pipeline.DamageKind.partial, request.item.token.damage_kind);
    try std.testing.expectEqual(@as(u64, 1), request.item.token.damage_base_seq);
    try std.testing.expectEqual(@as(u64, 9), request.item.known_target_epoch);
}

test "surface preserves partial snapshot with matching retained base and history growth" {
    var surface = TerminalSurface{};
    surface.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 3, .damage_base_seq = 0, .damage_kind = .full },
        .target_epoch = 9,
        .content_valid = true,
    });
    surface.bindTargetEpoch(9);

    _ = surface.publishSnapshot(.{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 3, .damage_base_seq = 1, .damage_kind = .partial }, .opportunistic);

    const request = surface.takePrepareEnvelope() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(pipeline.DamageKind.partial, request.item.token.damage_kind);
    try std.testing.expectEqual(@as(u64, 1), request.item.token.damage_base_seq);
    try std.testing.expectEqual(@as(u64, 9), request.item.known_target_epoch);
}

test "surface invalidates retained content when target epoch changes" {
    var surface = TerminalSurface{};
    surface.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
        .target_epoch = 7,
        .content_valid = true,
    });

    surface.bindTargetEpoch(8);
    _ = surface.publishSnapshot(.{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial }, .opportunistic);

    const request = surface.takePrepareEnvelope() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(pipeline.DamageKind.full, request.item.token.damage_kind);
}

test "surface reports bounded next actions" {
    var surface = TerminalSurface{};
    try std.testing.expectEqual(TerminalSurface.Action.idle, surface.nextAction());

    _ = surface.publishSnapshot(.{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full }, .opportunistic);
    try std.testing.expectEqual(TerminalSurface.Action.prepare, surface.nextAction());

    const request = surface.takePrepareEnvelope() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(TerminalSurface.Action.idle, surface.nextAction());

    _ = surface.publishPrepared(.{ .token = request.item.token, .required_target_epoch = request.item.known_target_epoch });
    try std.testing.expectEqual(TerminalSurface.Action.submit, surface.nextAction());

    _ = surface.takeSubmitEnvelope() orelse return error.TestUnexpectedResult;
    surface.acceptSubmitted(.{ .token = request.item.token, .target_epoch = 1, .content_valid = true });
    try std.testing.expectEqual(TerminalSurface.Action.present, surface.nextAction());
    surface.markPresented();
    try std.testing.expectEqual(TerminalSurface.Action.idle, surface.nextAction());
}

test "surface synchronous render consumes pending prepare action" {
    var surface = TerminalSurface{};
    _ = surface.publishSnapshot(.{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full }, .opportunistic);
    try std.testing.expectEqual(TerminalSurface.Action.prepare, surface.nextAction());

    const request = surface.takePrepare() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), request.token.snapshot_seq);
    try std.testing.expectEqual(TerminalSurface.Action.idle, surface.nextAction());
}

test "surface validates submit candidates before GPU mutation" {
    var surface = TerminalSurface{};
    surface.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
        .target_epoch = 5,
        .content_valid = true,
    });
    _ = surface.publishPrepared(.{
        .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial },
        .required_base_seq = 1,
        .required_target_epoch = 5,
    });

    const decision = surface.takeValidatedSubmit();
    switch (decision) {
        .submit => |prepared| try std.testing.expectEqual(@as(u64, 2), prepared.token.snapshot_seq),
        else => return error.TestUnexpectedResult,
    }
    const metrics_snapshot = surface.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.prepared_publishes);
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.submit_takes);
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.submit_valid);
}

test "surface reports stale submit when newer snapshot already won" {
    var surface = TerminalSurface{};
    _ = surface.publishSnapshot(.{ .snapshot_seq = 3, .dirty_epoch = 3, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full }, .opportunistic);
    _ = surface.publishPrepared(.{ .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full } });

    const decision = surface.takeSubmitTransition();
    switch (decision) {
        .stale => |token| try std.testing.expectEqual(@as(u64, 2), token.snapshot_seq),
        else => return error.TestUnexpectedResult,
    }
}

test "surface rejects stale submit and requests full latest prepare" {
    var surface = TerminalSurface{};
    surface.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
        .target_epoch = 5,
        .content_valid = true,
    });
    _ = surface.publishSnapshot(.{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 2, .damage_kind = .partial }, .opportunistic);
    _ = surface.takePrepareEnvelope();
    _ = surface.publishPrepared(.{
        .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 2, .damage_kind = .partial },
        .required_base_seq = 2,
        .required_target_epoch = 5,
    });

    const decision = surface.takeSubmitTransition();
    switch (decision) {
        .rejected => |rejected| try std.testing.expectEqual(pipeline.FullPrepareReason.retained_base_stale, rejected.reason),
        else => return error.TestUnexpectedResult,
    }
    surface.requestFullPrepare(.{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 2, .damage_kind = .partial });
    const request = surface.takePrepareEnvelope() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 2), request.item.token.snapshot_seq);
    try std.testing.expectEqual(pipeline.DamageKind.full, request.item.token.damage_kind);
    const metrics_snapshot = surface.metricsSnapshot();
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.submit_rejected);
    try std.testing.expectEqual(@as(u64, 1), metrics_snapshot.full_prepare_requests);
}

test "surface drops pending prepare at submitted token" {
    var surface = TerminalSurface{};
    _ = surface.publishSnapshot(.{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 1, .damage_kind = .partial }, .opportunistic);

    surface.acceptSubmitted(.{
        .token = .{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full },
        .target_epoch = 1,
        .content_valid = true,
    });

    try std.testing.expect(surface.takePrepareEnvelope() == null);
}

test "surface metrics reset keeps scheduling state" {
    var surface = TerminalSurface{};
    _ = surface.publishSnapshot(.{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full }, .opportunistic);
    try std.testing.expectEqual(TerminalSurface.Action.prepare, surface.nextAction());
    try std.testing.expectEqual(@as(u64, 1), surface.metricsSnapshot().prepare_requests);

    surface.resetMetrics();
    try std.testing.expectEqual(@as(u64, 0), surface.metricsSnapshot().prepare_requests);
    try std.testing.expectEqual(TerminalSurface.Action.prepare, surface.nextAction());
}

test "prepared slot replaces stale frame and owns cleanup" {
    const Frame = struct {
        id: u32,
        drops: *u32,

        pub fn deinit(self: *@This()) void {
            self.drops.* += 1;
        }
    };
    const Slot = PreparedSlot(Frame);
    var drops: u32 = 0;
    var slot = Slot{};

    slot.publish(.{ .id = 1, .drops = &drops });
    slot.publish(.{ .id = 2, .drops = &drops });
    try std.testing.expectEqual(@as(u32, 1), drops);
    try std.testing.expect(slot.hasFrame());

    var frame = slot.take() orelse return error.TestUnexpectedResult;
    defer frame.deinit();
    try std.testing.expectEqual(@as(u32, 2), frame.id);
    try std.testing.expect(!slot.hasFrame());
}

test "surface executor prepares latest request into submit slot" {
    const Frame = struct {
        id: u32,
        pub fn deinit(_: *@This()) void {}
    };
    const Executor = SurfaceExecutor(Frame);
    const Ctx = struct {
        fn prepare(context: *anyopaque, request: pipeline.RenderRequest) anyerror!?Frame {
            const hits: *u32 = @ptrCast(@alignCast(context));
            hits.* += 1;
            return .{ .id = @intCast(request.token.snapshot_seq) };
        }
    };

    var executor = Executor{};
    defer executor.deinit();
    var hits: u32 = 0;
    _ = executor.publishSnapshot(.{ .snapshot_seq = 1, .dirty_epoch = 1, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full }, .opportunistic);
    _ = executor.publishSnapshot(.{ .snapshot_seq = 2, .dirty_epoch = 2, .geometry_epoch = 1, .damage_base_seq = 0, .damage_kind = .full }, .opportunistic);

    try std.testing.expectEqual(TerminalSurface.Action.prepare, executor.nextAction());
    try std.testing.expectEqual(Executor.PrepareStep.prepared, executor.prepareStep(&hits, Ctx.prepare));
    try std.testing.expectEqual(@as(u32, 1), hits);
    try std.testing.expectEqual(TerminalSurface.Action.submit, executor.nextAction());

    var frame = executor.takePreparedForSubmit() orelse return error.TestUnexpectedResult;
    defer frame.deinit();
    try std.testing.expectEqual(@as(u32, 2), frame.id);
}
