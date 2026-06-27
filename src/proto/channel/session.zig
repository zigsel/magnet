//! `Session(comptime cfg: Config)` - magnet's canonical sans-IO transport. One
//! engine (decoupled packet numbers, ack-ranges, RACK, RTT/PTO, pluggable cwnd +
//! pacer, spurious-loss restore) under a multi-channel layer that is **comptime-
//! monomorphized per channel** from `cfg.channels`: each channel's send/receive
//! state is exactly what its reliability mode needs (an `unreliable` channel
//! compiles out the reorder window; `reliable_ordered` carries it), held in
//! heterogeneous per-channel tuples. Independent ordering streams (no cross-channel
//! HOL) and **independent reliable send windows**. The live `pollTransmit` packs
//! across channels through the **WFQ scheduler** (per-channel priority + weight +
//! anti-starvation). Typed `send`/`receive` (serde) and raw `sendRaw`/`receiveRaw`.
//! The tracer (`cfg.tracer`) is zero-cost when Null; the controller (`cfg.congestion`)
//! is selected at comptime (NewReno / Fixed / Cubic / BBR all wire in).
//!
//! Public header: `[flags:u8][cid:8 if flags&0x40][pn: 1–4 B truncated]`.
//!   flags bits0-1 = pn_len-1; bit6 = has-CID (migration); bit7 = handshake datagram.
//! Frame types in the (AEAD-sealed when `.aead`) payload, parsed until end:
//!   0 data       `[ch:u8][dseq:u16][len:u16][payload]`
//!   2 ack        `[ack-ranges]` (RLE, newest→oldest; see `ack.zig`)
//!   3/4 path     `PATH_CHALLENGE / PATH_RESPONSE [token:u64]` (CID migration)
//!   5 fragment   `[ch:u8][dseq:u16][group:u16][index:u16][count:u16][len:u16][payload]`
//!   6/7 ping/pong `[nonce:u64]` (idle keepalive + RTT)
//!   8 nak        `[ack-ranges of MISSING pns]` (fast-NAK, sub-RTT retransmit)
//!   9 disconnect `[reason:u8]` (graceful close)
//! Handshake datagrams (bit7) are cleartext: hello / challenge / response (see `handshake.zig`).

const std = @import("std");
const seq = @import("core").seq;
const SequenceBuffer = @import("core").SequenceBuffer;
const Ring = @import("core").Ring;
const bitpack = @import("wire").bitpack;
const serde = @import("wire").serde;
const delta = @import("wire").delta;
const ack = @import("../delivery/ack.zig");
const loss = @import("../delivery/loss.zig");
const Rtt = @import("../delivery/rtt.zig").Rtt;
const Pacer = @import("../delivery/pacing.zig").Pacer;
const Bridge = @import("bridge.zig").Bridge;
const Mode = @import("ordering.zig").Mode;
const isReliable = @import("ordering.zig").isReliable;
const ordering = @import("ordering.zig");
const blendmod = @import("blend.zig");
const Scheduler = @import("scheduler.zig").Scheduler;
const Config = @import("config").Config;
const trace = @import("trace");
const secure = @import("secure.zig");
const frames = @import("frames.zig");
const handshake = @import("../conn/handshake.zig");
const cidmod = @import("../conn/cid.zig");
const token = @import("../conn/token.zig");

pub const mtu = 1200;
const ftype_data = frames.data;
const ftype_ack = frames.ack;
const ftype_path_challenge = frames.path_challenge;
const ftype_path_response = frames.path_response;
const ftype_fragment = frames.fragment;
const ftype_ping = frames.ping;
const ftype_pong = frames.pong;
const ftype_nak = frames.nak;
const ftype_disconnect = frames.disconnect;
const ftype_padding = frames.padding;
const Mtu = @import("../delivery/mtu.zig").Mtu;
const loss_scan = 64;
const lost_window = 64;
const Reassembler = @import("../delivery/frag.zig").Reassembler;
const FragMeta = @import("../delivery/frag.zig").Meta;

fn MsgT(comptime max_payload: usize) type {
    return struct { len: u16, data: [max_payload]u8 = undefined };
}

/// Receive state for one channel, monomorphized on `mode`: `recv` is the
/// `ordering.Receiver` (which compiles out the reorder/dedup storage a mode does
/// not need), `delivered` is the ready-to-drain ring.
/// 9-byte blend tag prepended to a blended channel's payload (off the wire-frame format).
const blend_tag_len: usize = 9;

fn RecvChannel(comptime mode: Mode, comptime max_payload: usize, comptime cap: usize) type {
    const Msg = MsgT(max_payload);
    const blended = mode == .reliable_ordered_sequenced;
    return struct {
        const Self = @This();
        recv: ordering.Receiver(mode, Msg, cap, u16) = .{},
        delivered: Ring(Msg, cap) = .{},
        // blended channels re-order via a BlendReceiver keyed by the per-message tag.
        blender: if (blended) blendmod.BlendReceiver(Msg, cap) else void = if (blended) .{} else {},

        // For a plain channel, carrier-delivered messages go straight to `delivered`.
        // For a blended channel, each carries a 9-byte tag prefix → decode it, strip it,
        // and feed the BlendReceiver; `pop` then drains in blended order.
        const Pusher = struct {
            d: *Ring(Msg, cap),
            b: if (blended) *blendmod.BlendReceiver(Msg, cap) else void,
            pub fn push(self: *@This(), v: Msg) void {
                if (blended) {
                    if (v.len < blend_tag_len) return; // malformed (no tag)
                    const tag = blendmod.Tag{
                        .order = std.mem.readInt(u32, v.data[0..4], .little),
                        .seq_idx = std.mem.readInt(u32, v.data[4..8], .little),
                        .sequenced = v.data[8] != 0,
                    };
                    var inner = Msg{ .len = v.len - @as(u16, blend_tag_len) };
                    @memcpy(inner.data[0..inner.len], v.data[blend_tag_len..v.len]);
                    self.b.accept(tag, inner);
                } else {
                    _ = self.d.push(v);
                }
            }
        };

        fn accept(self: *Self, dseq: u16, payload: []const u8) void {
            var m = Msg{ .len = @intCast(payload.len) };
            @memcpy(m.data[0..payload.len], payload);
            var p = Pusher{ .d = &self.delivered, .b = if (blended) &self.blender else {} };
            self.recv.accept(dseq, m, &p);
        }
        fn pop(self: *Self) ?Msg {
            if (blended) return self.blender.next();
            return self.delivered.pop();
        }
    };
}

pub const SendError = error{ MessageTooLarge, Backpressure };

pub fn Session(comptime cfg: Config) type {
    const Schema = cfg.channels;
    const N = Schema.count;
    const lim = cfg.limits;
    const max_payload = lim.max_payload;
    const ch_cap = lim.channel_cap;
    const max_msgs = lim.max_msgs_pkt;
    const Cc = cfg.congestion orelse @import("../delivery/cc/reno.zig").Reno; // default NewReno

    const Tracer = cfg.tracer;
    // Comptime contract checks: a malformed tracer / congestion controller fails here
    // naming the missing method, instead of confusingly deep in the send path.
    comptime trace.assertTracer(Tracer);
    comptime @import("../delivery/cc/controller.zig").validate(Cc);
    const has_snapshot = @hasDecl(Cc, "snapshot");
    const modes = Schema.modes;

    // Security: engaged only when `cfg.security.mode == .aead`. When `.none`,
    // `sec` is comptime-false and every security branch/field compiles out, so the
    // default (unencrypted) transport is byte-for-byte the unsecured Session.
    const sec = cfg.security.mode == .aead;
    const cid_on = cfg.security.connection_ids;
    if (cid_on and !sec) @compileError("security.connection_ids requires security.mode = .aead");
    const tokens_on = cfg.security.tokens;
    if (tokens_on and !sec) @compileError("security.tokens requires security.mode = .aead");
    const TokenLen = token.Token.wire_len;
    const Aead = secure.Aead(cfg); // selected AEAD (see secure.zig)
    const SecState = if (sec) secure.SecState(cfg) else void; // per-connection security state
    const hs_interval_ms: i64 = 50; // handshake retransmit cadence
    const cid_hdr: usize = if (cid_on) 8 else 0;
    const has_cid_bit = frames.has_cid_bit;

    // configurable spine: PN width, ack/loss knobs, datagram budget
    const Pn = cfg.seq.packet_number;
    const AckT = ack.Ack(Pn, cfg.delivery.ack_blocks_max);
    const lpt = cfg.delivery.loss_packet_threshold;
    const ltn = cfg.delivery.loss_time_num;
    const ltd = cfg.delivery.loss_time_den;
    // RACK back-scan span: cover the whole in-flight window (bounded by the bridge
    // capacity) so losses are detected on a high-BDP link too, not just within a
    // fixed 64-PN tail. Capped so the per-ack scan stays cheap.
    const loss_window: Pn = @intCast(@min(lim.bridge_cap, 256));
    const scratch_max = cfg.max_datagram; // internal seal/decrypt scratch (≥ any datagram)
    // PacketNumberFilter: occasionally skip an outgoing PN; an ack of a never-sent
    // (skipped) PN is an optimistic-ack attack → close the connection.
    const pn_filter = cfg.delivery.pn_skip_period > 0;
    const skipPn = struct {
        fn f(p: Pn) bool {
            return (p != 0) and ((p *% 0x9E37_79B1) % cfg.delivery.pn_skip_period == 0);
        }
    }.f;

    // Fragmentation (opt-in): large messages split into reliable fragments.
    const pmtud_on = cfg.enable_pmtud;
    const frag_on = cfg.delivery.fragmentation;
    const max_frags = cfg.delivery.max_fragments;
    const block_max = max_payload * max_frags; // largest fragmented message
    const Reasm = if (frag_on) Reassembler(max_payload, max_frags, cfg.delivery.reassembly_slots) else void;

    const OutMsg = struct {
        dseq: u16,
        len: u16,
        data: [max_payload]u8,
        acked: bool,
        ever_sent: bool,
        first_sent: bool,
        last_sent: i64,
        // fragmentation metadata (fcount == 0 ⇒ a plain, non-fragmented message)
        group: u16 = 0,
        findex: u16 = 0,
        fcount: u16 = 0,
    };

    // Per-channel send state, monomorphized on `mode`: reliable channels carry a
    // retransmit window (`SequenceBuffer` + oldest/next cursors); unreliable
    // channels carry only a fire-and-forget ring + a dense sequence counter.
    const SendChannel = struct {
        fn T(comptime mode: Mode) type {
            const reliable = isReliable(mode);
            const blended = mode == .reliable_ordered_sequenced;
            return struct {
                q: if (reliable) SequenceBuffer(OutMsg, ch_cap, u16) else Ring(OutMsg, ch_cap) = .{},
                next: u16 = 0, // reliable: window head (also the dseq); unreliable: dseq counter
                oldest: u16 = 0, // reliable only
                // blend slot counters: ordered sends advance `border`; sequenced sends
                // index `bseq` within the current slot.
                border: if (blended) u32 else void = if (blended) 0 else {},
                bseq: if (blended) u32 else void = if (blended) 0 else {},
            };
        }
    };

    // Heterogeneous per-channel tuples: field i has exactly the state mode[i] needs.
    const SendTypes = blk: {
        var t: [N]type = undefined;
        for (0..N) |i| t[i] = SendChannel.T(modes[i]);
        break :blk t;
    };
    const RecvTypes = blk: {
        var t: [N]type = undefined;
        for (0..N) |i| t[i] = RecvChannel(modes[i], max_payload, ch_cap);
        break :blk t;
    };
    const SendTuple = std.meta.Tuple(&SendTypes);
    const RecvTuple = std.meta.Tuple(&RecvTypes);

    // A bridged reliable message reference: which channel, which per-channel id.
    const Ref = struct { ch: u8, id: u16 };

    return struct {
        const Self = @This();
        pub const config = cfg;

        peer: u64 = 0,
        tracer: Tracer = .{},
        cc: Cc = .{},
        pacer: Pacer = .{},
        sched: Scheduler(N) = .{},

        // packet space + ack bookkeeping
        next_pn: Pn = 0,
        recv_pns: SequenceBuffer(void, lim.recvpn_cap, Pn) = .{},
        have_recv: bool = false,
        most_recent_recv: Pn = 0,
        most_recent_recv_at: i64 = 0,
        unacked_eliciting: bool = false,
        largest_acked: Pn = 0,
        have_largest: bool = false,

        // spurious-loss recovery (only when the controller supports snapshots)
        loss_snapshot: if (has_snapshot) ?Cc.Snapshot else void = if (has_snapshot) null else {},
        lost_pns: SequenceBuffer(void, lost_window, Pn) = .{},
        pto_backoff: u8 = 0, // consecutive loss rounds with no progress (PTO backoff shift)
        inflight_bytes: usize = 0, // bytes in flight, maintained incrementally (see outstandingBytes)

        bridge: Bridge(Pn, Ref, lim.bridge_cap, max_msgs) = .{},
        rtt: Rtt = .{},

        // control frames: keepalive/RTT ping-pong, fast-NAK, graceful disconnect
        last_send_ms: i64 = 0,
        last_recv_ms: i64 = 0,
        had_any_recv: bool = false,
        ping_inflight: bool = false,
        ping_nonce: u64 = 0,
        ping_sent_at: i64 = 0,
        owe_pong: bool = false,
        pong_nonce: u64 = 0,
        owe_nak: bool = false,
        nak_at: i64 = 0,
        nak_largest: Pn = 0,
        nak_missing: SequenceBuffer(void, 64, Pn) = .{}, // gaps awaiting a NAK
        disconnecting: bool = false,
        disc_reason: u8 = 0,
        closed: bool = false,
        pn_skipped: if (pn_filter) SequenceBuffer(void, 64, Pn) else void = if (pn_filter) .{} else {},

        // live PMTUD (compiled out unless cfg.enable_pmtud): DF-padded probes raise the
        // datagram budget on ack, fall back on probe loss / black-hole.
        pmtu: if (pmtud_on) Mtu else void = if (pmtud_on) Mtu.init() else {},
        probe_inflight: if (pmtud_on) bool else void = if (pmtud_on) false else {},
        probe_nonce: if (pmtud_on) u64 else void = if (pmtud_on) 0 else {},
        probe_size: if (pmtud_on) u16 else void = if (pmtud_on) 0 else {},
        probe_sent_at: if (pmtud_on) i64 else void = if (pmtud_on) 0 else {},

        // fragmentation state (compiled out unless `frag_on`)
        reasm: if (frag_on) Reasm else void = if (frag_on) .{} else {},
        block_group: if (frag_on) u16 else void = if (frag_on) 0 else {},
        block_ready: if (frag_on) bool else void = if (frag_on) false else {},
        block_ch: if (frag_on) u8 else void = if (frag_on) 0 else {},
        block_len: if (frag_on) usize else void = if (frag_on) 0 else {},
        block_buf: if (frag_on) [block_max]u8 else void = undefined,

        sec_state: SecState = if (sec) .{} else {},

        tx: SendTuple = undefined, // filled by setup()
        recv: RecvTuple = undefined, // filled by setup()

        fn reliableOf(comptime ci: usize) bool {
            return isReliable(modes[ci]);
        }

        pub fn setup(self: *Self) void {
            inline for (0..N) |i| {
                self.tx[i] = .{};
                self.recv[i] = .{};
                self.sched.configure(i, Schema.priorities[i], Schema.weights[i]);
            }
            self.pacer.burst_bytes = cfg.pacing_opts.burst_bytes;
        }

        // ---- security helpers (compiled out when `sec` is false) ----

        /// Derive the directional key schedule from a shared pre-shared key (or the
        /// session keys carried in a connect token). `initiator` = the connecting
        /// (client) side, which seals with the c2s material and opens with s2c.
        pub fn secSetup(self: *Self, initiator: bool, psk: [32]u8) void {
            if (sec) {
                self.sec_state.initiator = initiator;
                // explicit little-endian salt (not native `toBytes`) so the key schedule
                // is architecture- and cross-language-portable (BE/LE peers agree).
                var salt: [8]u8 = undefined;
                std.mem.writeInt(u64, &salt, cfg.protocol_id, .little);
                self.sec_state.keys = handshake.derive(psk, &salt);
            }
        }
        /// Derive the key schedule from a connect token's session keys (instead of a
        /// raw PSK). `token_in` is the encoded token to echo in the response (client);
        /// pass an empty slice on the server (it re-derives from the verified token).
        pub fn secSetupToken(self: *Self, initiator: bool, c2s_key: [32]u8, s2c_key: [32]u8, token_in: []const u8) void {
            if (sec) {
                self.sec_state.initiator = initiator;
                self.sec_state.keys = handshake.keysFromToken(c2s_key, s2c_key);
                if (tokens_on and token_in.len == TokenLen) @memcpy(&self.sec_state.token_bytes, token_in);
            }
        }
        /// Client API: begin the handshake (emit a hello on the next `pollTransmit`).
        pub fn connect(self: *Self) void {
            if (sec) {
                self.sec_state.initiator = true;
                self.sec_state.state = .hello_sent;
            }
        }
        /// Server API (called by the endpoint once a cookie is validated): mark the
        /// session connected and the peer address validated.
        pub fn secAccept(self: *Self) void {
            if (sec) {
                self.sec_state.state = .connected;
                self.sec_state.amp.validate();
                self.sec_state.force_keepalive = true;
                self.tracer.onHandshake(self.peer, @intFromEnum(handshake.State.connected));
            }
        }
        pub fn isConnected(self: *const Self) bool {
            return if (sec) self.sec_state.state == .connected else true;
        }

        // ---- connection IDs + migration (compiled out when `cid_on` is false) ----

        pub fn localCid(self: *const Self) cidmod.Cid {
            return if (cid_on) self.sec_state.local_cid else cidmod.none;
        }
        pub fn setLocalCid(self: *Self, c: cidmod.Cid) void {
            if (cid_on) self.sec_state.local_cid = c;
        }
        pub fn setRemoteCid(self: *Self, c: cidmod.Cid) void {
            if (cid_on) self.sec_state.remote_cid = c;
        }
        pub fn pathValidated(self: *const Self) bool {
            return if (cid_on) self.sec_state.path.validated else true;
        }
        /// Endpoint hook: the peer's source IP changed. Reset path state (RTT/cc/MTU)
        /// and begin validating the new path; data send pauses until it responds.
        pub fn onPathChange(self: *Self, path_tok: u64) void {
            if (cid_on) {
                self.rtt = .{}; // reset RTT estimate for the new path
                self.cc = .{}; // reset congestion controller (fresh cwnd)
                self.sec_state.path.begin(path_tok);
                self.sec_state.send_challenge = true;
                self.sec_state.path_token = path_tok;
            }
        }

        /// Re-prioritize / re-weight a channel's WFQ lane at runtime (defaults come
        /// from the comptime schema; this lets the app bump a lane live).
        pub fn setPriority(self: *Self, comptime ch: anytype, priority: u8, weight: u32) void {
            self.sched.configure(comptime Schema.idOf(ch), priority, weight);
        }

        pub fn rttMs(self: *const Self) i64 {
            return self.rtt.smoothed_ms;
        }
        pub fn cwnd(self: *const Self) usize {
            return self.cc.window();
        }
        pub fn bytesInFlight(self: *const Self) u32 {
            return @intCast(self.outstandingBytes());
        }
        pub fn congestionEvents(self: *const Self) u32 {
            return if (@hasField(Cc, "congestion_events")) self.cc.congestion_events else 0;
        }

        /// A live per-connection snapshot for `endpoint.stats` / a debug overlay.
        pub const Stats = struct {
            rtt_ms: i64,
            rtt_var_ms: i64,
            cwnd_bytes: usize,
            bytes_in_flight: usize,
            congestion_events: u32,
            connected: bool,

            /// Format a one-line dashboard row into `buf`; returns the slice.
            pub fn line(self: Stats, buf: []u8) []const u8 {
                return std.fmt.bufPrint(buf, "rtt={d}ms±{d} cwnd={d}B inflight={d}B cong={d} up={}", .{
                    self.rtt_ms, self.rtt_var_ms, self.cwnd_bytes, self.bytes_in_flight, self.congestion_events, self.connected,
                }) catch buf[0..0];
            }
        };
        pub fn stats(self: *Self) Stats {
            return .{
                .rtt_ms = self.rtt.smoothed_ms,
                .rtt_var_ms = self.rtt.var_ms,
                .cwnd_bytes = self.cc.window(),
                .bytes_in_flight = self.outstandingBytes(),
                .congestion_events = self.congestionEvents(),
                .connected = self.isConnected(),
            };
        }

        /// Request a graceful close: a DISCONNECT frame is sent, then `isClosed()`.
        pub fn disconnect(self: *Self, reason: u8) void {
            self.disconnecting = true;
            self.disc_reason = reason;
        }
        pub fn isClosed(self: *const Self) bool {
            return self.closed;
        }

        /// Outstanding (unsent + unacked) message count on channel `ch` - the
        /// per-channel depth signal.
        pub fn channelDepth(self: *Self, comptime ch: anytype) u32 {
            const ci = comptime Schema.idOf(ch);
            const s = &self.tx[ci];
            if (comptime isReliable(Schema.modeOf(ch))) {
                return @intCast(s.next -% s.oldest);
            } else {
                return @intCast(s.q.len());
            }
        }

        /// True while any reliable channel still has unacknowledged data.
        pub fn hasUnacked(self: *const Self) bool {
            inline for (0..N) |ci| {
                if (comptime reliableOf(ci)) {
                    const s = &self.tx[ci];
                    if (s.oldest != s.next) return true;
                }
            }
            return false;
        }

        // ---- typed + raw send API ----

        pub fn send(self: *Self, comptime ch: anytype, value: Schema.MessageOf(ch)) SendError!void {
            const blended = comptime Schema.modeOf(ch) == .reliable_ordered_sequenced;
            var buf: [max_payload]u8 = undefined;
            const off: usize = if (blended) blend_tag_len else 0;
            var w = bitpack.Writer.init(buf[off..]);
            serde.write(&w, value);
            if (w.overflowed) return error.MessageTooLarge;
            const vlen = w.finish().len;
            if (blended) {
                self.writeBlendTag(ch, false, &buf); // plain send on a blended channel = the ordered terminator
                return self.sendRaw(ch, buf[0 .. off + vlen]);
            }
            return self.sendRaw(ch, buf[0..vlen]);
        }

        /// Send a **sequenced** update on a `.reliable_ordered_sequenced` channel: it
        /// rides the current ordered slot, only the newest is delivered, and it arrives
        /// before that slot's ordered `send`. Compile error on any other channel mode.
        pub fn sendSequenced(self: *Self, comptime ch: anytype, value: Schema.MessageOf(ch)) SendError!void {
            if (comptime Schema.modeOf(ch) != .reliable_ordered_sequenced)
                @compileError("sendSequenced requires a .reliable_ordered_sequenced channel");
            var buf: [max_payload]u8 = undefined;
            var w = bitpack.Writer.init(buf[blend_tag_len..]);
            serde.write(&w, value);
            if (w.overflowed) return error.MessageTooLarge;
            const vlen = w.finish().len;
            self.writeBlendTag(ch, true, &buf);
            return self.sendRaw(ch, buf[0 .. blend_tag_len + vlen]);
        }

        /// Write the 9-byte blend tag into `buf[0..9]` and advance the channel's slot
        /// counters: an ordered send terminates the current slot; a sequenced send
        /// indexes within it.
        fn writeBlendTag(self: *Self, comptime ch: anytype, sequenced: bool, buf: []u8) void {
            const s = &self.tx[comptime Schema.idOf(ch)];
            const order = s.border;
            var seq_idx: u32 = 0;
            if (sequenced) {
                seq_idx = s.bseq;
                s.bseq += 1;
            } else {
                s.border += 1;
                s.bseq = 0;
            }
            std.mem.writeInt(u32, buf[0..4], order, .little);
            std.mem.writeInt(u32, buf[4..8], seq_idx, .little);
            buf[8] = @intFromBool(sequenced);
        }

        pub fn sendRaw(self: *Self, comptime ch: anytype, bytes: []const u8) SendError!void {
            if (bytes.len > max_payload) return error.MessageTooLarge;
            const cid = comptime Schema.idOf(ch);
            const reliable = comptime isReliable(Schema.modeOf(ch));
            const s = &self.tx[cid];
            // backpressure BEFORE consuming a data-sequence (a burned dseq stalls a
            // reliable-ordered receiver forever). On a full queue, apply the
            // configured degrade policy (backpressure / drop-new / drop-oldest).
            const full = if (reliable) (s.next -% s.oldest >= ch_cap - 1) else s.q.isFull();
            if (full) {
                self.tracer.onDrop(self.peer, .send_queue_full);
                switch (cfg.degrade.on_send_queue_full) {
                    .backpressure => return error.Backpressure,
                    .drop_new => return, // silently drop this message
                    .drop_oldest => if (reliable) {
                        // evict the oldest unacked to make room (loses reliability on it)
                        if (s.q.get(s.oldest)) |old| {
                            if (old.ever_sent and !old.acked) self.inflight_bytes -= frameSize(old);
                            old.acked = true;
                        }
                        self.advanceUnacked();
                    } else {
                        _ = s.q.pop();
                    },
                }
            }
            const dseq = s.next;
            s.next +%= 1;
            var m = OutMsg{ .dseq = dseq, .len = @intCast(bytes.len), .data = undefined, .acked = false, .ever_sent = false, .first_sent = false, .last_sent = 0 };
            @memcpy(m.data[0..bytes.len], bytes);
            if (reliable) {
                s.q.insert(dseq, m);
            } else {
                _ = s.q.push(m);
            }
        }

        /// Send a message larger than `max_payload` by **fragmentation** over a
        /// reliable channel: split into `≤ max_payload` fragments, each a reliable
        /// message; the receiver reassembles. Requires `Config.delivery.fragmentation`.
        pub fn sendBlock(self: *Self, comptime ch: anytype, bytes: []const u8) SendError!void {
            if (!frag_on) @compileError("sendBlock requires Config.delivery.fragmentation = true");
            const reliable = comptime isReliable(Schema.modeOf(ch));
            if (!reliable) @compileError("sendBlock requires a reliable channel");
            if (bytes.len <= max_payload) return self.sendRaw(ch, bytes); // small → one message
            if (bytes.len > block_max) return error.MessageTooLarge;
            const cid = comptime Schema.idOf(ch);
            const s = &self.tx[cid];
            const count: u16 = @intCast((bytes.len + max_payload - 1) / max_payload);
            if (@as(usize, s.next -% s.oldest) + count > ch_cap - 1) return error.Backpressure;
            const group = self.block_group;
            self.block_group +%= 1;
            var i: u16 = 0;
            while (i < count) : (i += 1) {
                const off = @as(usize, i) * max_payload;
                const end = @min(off + max_payload, bytes.len);
                const dseq = s.next;
                s.next +%= 1;
                var m = OutMsg{ .dseq = dseq, .len = @intCast(end - off), .data = undefined, .acked = false, .ever_sent = false, .first_sent = false, .last_sent = 0, .group = group, .findex = i, .fcount = count };
                @memcpy(m.data[0 .. end - off], bytes[off..end]);
                s.q.insert(dseq, m);
            }
        }

        /// Drain a fully-reassembled block for channel `ch` into `out`; returns its
        /// length, or null if none ready. Requires `Config.delivery.fragmentation`.
        pub fn receiveBlock(self: *Self, comptime ch: anytype, out: []u8) ?usize {
            if (!frag_on) @compileError("receiveBlock requires Config.delivery.fragmentation = true");
            const cid = comptime Schema.idOf(ch);
            if (!self.block_ready or self.block_ch != cid) return null;
            @memcpy(out[0..self.block_len], self.block_buf[0..self.block_len]);
            self.block_ready = false;
            return self.block_len;
        }

        pub fn receive(self: *Self, comptime ch: anytype) ?Schema.MessageOf(ch) {
            const cid = comptime Schema.idOf(ch);
            const m = self.recv[cid].pop() orelse return null;
            var r = bitpack.Reader.init(m.data[0..m.len]);
            return serde.read(Schema.MessageOf(ch), &r);
        }

        /// Raw receive: returns a slice valid until the next `receiveRaw` on this channel.
        pub fn receiveRaw(self: *Self, comptime ch: anytype, out: []u8) ?usize {
            const cid = comptime Schema.idOf(ch);
            const m = self.recv[cid].pop() orelse return null;
            @memcpy(out[0..m.len], m.data[0..m.len]);
            return m.len;
        }

        // ---- delivery ----

        /// Bytes in flight (sent, ack-eliciting, not yet acked). Maintained
        /// incrementally - O(1), updated at the four flip points: pack (→in
        /// flight), ack (→done), RACK loss and fast-NAK (→re-eligible). The O(window)
        /// recompute `outstandingBytesSlow` is kept only as a test cross-check.
        fn outstandingBytes(self: *const Self) usize {
            return self.inflight_bytes;
        }
        fn outstandingBytesSlow(self: *const Self) usize {
            var total: usize = 0;
            inline for (0..N) |ci| {
                if (comptime reliableOf(ci)) {
                    const s = &self.tx[ci];
                    var id = s.oldest;
                    while (id != s.next) : (id +%= 1) {
                        if (s.q.getConst(id)) |m| {
                            if (m.ever_sent and !m.acked) total += frameSize(m);
                        }
                    }
                }
            }
            return total;
        }

        fn resendMs(self: *const Self) i64 {
            const base = if (self.rtt.has) @max(self.rtt.pto(), 60) else 200;
            // PTO exponential backoff (RFC 9002 §6.2): each consecutive loss round with
            // no forward progress doubles the probe timeout, so a fully-stalled path
            // stops spamming retransmits. Reset to 0 on any newly-acked packet (capped).
            return base << @intCast(@min(self.pto_backoff, 4));
        }

        /// Write the public header (flags + optional CID + truncated pn) at the
        /// front of `buf`. Returns the header length (== `hdr`).
        fn writeHdr(self: *Self, buf: []u8, pn: Pn, nbytes: usize) void {
            var flags: u8 = @intCast(nbytes - 1);
            var off: usize = 1;
            if (cid_on) {
                flags |= has_cid_bit;
                std.mem.writeInt(u64, buf[1..9], self.sec_state.remote_cid, .little);
                off = 9;
            }
            buf[0] = flags;
            var k: usize = 0;
            while (k < nbytes) : (k += 1) buf[off + k] = @truncate(pn >> @intCast(k * 8));
        }

        /// Header bytes a message occupies on the wire: 6 (data) or 12 (FRAGMENT).
        fn frameSize(m: *const OutMsg) usize {
            const hdr: usize = if (frag_on and m.fcount > 0) 12 else 6;
            return hdr + m.len;
        }

        fn writeData(buf: []u8, pos: usize, ch: u8, m: *const OutMsg) usize {
            if (frag_on and m.fcount > 0) {
                buf[pos] = ftype_fragment;
                buf[pos + 1] = ch;
                std.mem.writeInt(u16, buf[pos + 2 ..][0..2], m.dseq, .little);
                std.mem.writeInt(u16, buf[pos + 4 ..][0..2], m.group, .little);
                std.mem.writeInt(u16, buf[pos + 6 ..][0..2], m.findex, .little);
                std.mem.writeInt(u16, buf[pos + 8 ..][0..2], m.fcount, .little);
                std.mem.writeInt(u16, buf[pos + 10 ..][0..2], m.len, .little);
                @memcpy(buf[pos + 12 ..][0..m.len], m.data[0..m.len]);
                return 12 + m.len;
            }
            buf[pos] = ftype_data;
            buf[pos + 1] = ch;
            std.mem.writeInt(u16, buf[pos + 2 ..][0..2], m.dseq, .little);
            std.mem.writeInt(u16, buf[pos + 4 ..][0..2], m.len, .little);
            @memcpy(buf[pos + 6 ..][0..m.len], m.data[0..m.len]);
            return 6 + m.len;
        }

        /// Comptime arity shim so any shipped controller plugs in: NewReno/Cubic/Fixed
        /// expose `onAck(acked, now)`; BBR needs `onAck(acked, rtt_ms, in_flight, now)`.
        fn ccOnAck(self: *Self, acked: usize, rtt_ms: i64, in_flight: usize, now: i64) void {
            const params = @typeInfo(@TypeOf(Cc.onAck)).@"fn".params.len;
            if (params == 5) {
                self.cc.onAck(acked, rtt_ms, in_flight, now);
            } else {
                self.cc.onAck(acked, now);
            }
        }

        const PackCtx = struct {
            in_flight: usize,
            cwnd_bytes: usize,
            lim: usize,
            allow_reliable: bool,
            refs: [max_msgs]Ref = undefined,
            nids: u8 = 0,
        };

        /// First reliable message id in channel `ci` that is unacked, due, fits the
        /// remaining budget, and (for new data) passes the cwnd gate - or null.
        fn dueReliable(self: *Self, comptime ci: usize, pos: usize, now: i64, ctx: *const PackCtx) ?u16 {
            if (!ctx.allow_reliable or ctx.nids >= max_msgs) return null;
            const s = &self.tx[ci];
            var id = s.oldest;
            while (id != s.next) : (id +%= 1) {
                const m = s.q.get(id) orelse continue;
                if (m.acked) continue;
                const due = !m.ever_sent or (now - m.last_sent) >= self.resendMs();
                if (!due) continue;
                const need = frameSize(m);
                if (pos + need > ctx.lim) return null; // datagram full
                // gate only *new* data by cwnd; retransmits always flow (avoids deadlock)
                if (!m.first_sent and ctx.nids > 0 and ctx.in_flight + need > ctx.cwnd_bytes) continue;
                return id;
            }
            return null;
        }

        /// Can channel `ci` contribute a frame to the datagram at `pos` right now?
        fn canSend(self: *Self, comptime ci: usize, pos: usize, now: i64, ctx: *const PackCtx) bool {
            if (comptime reliableOf(ci)) {
                return self.dueReliable(ci, pos, now, ctx) != null;
            } else {
                const s = &self.tx[ci];
                const m = s.q.peek() orelse return false;
                return pos + 6 + @as(usize, m.len) <= ctx.lim;
            }
        }

        /// Pack exactly one frame from channel `ci`; returns its byte size (0 if none).
        fn packOne(self: *Self, comptime ci: usize, buf: []u8, pos: *usize, now: i64, ctx: *PackCtx) usize {
            if (comptime reliableOf(ci)) {
                const id = self.dueReliable(ci, pos.*, now, ctx) orelse return 0;
                const s = &self.tx[ci];
                const m = s.q.get(id).?;
                const need = writeData(buf, pos.*, @intCast(ci), m);
                pos.* += need;
                ctx.in_flight += need;
                if (!m.ever_sent) self.inflight_bytes += frameSize(m); // first send / re-eligibled retransmit
                if (m.first_sent) self.tracer.onRetransmit(self.peer, @as(u64, self.next_pn)); // a resend of already-sent data
                m.ever_sent = true;
                m.first_sent = true;
                m.last_sent = now;
                ctx.refs[ctx.nids] = .{ .ch = @intCast(ci), .id = id };
                ctx.nids += 1;
                return need;
            } else {
                const s = &self.tx[ci];
                const m = s.q.peek() orelse return 0;
                const need = 6 + @as(usize, m.len);
                if (pos.* + need > ctx.lim) return 0;
                const written = writeData(buf, pos.*, @intCast(ci), &m);
                pos.* += written;
                _ = s.q.pop();
                return written;
            }
        }

        pub fn pollTransmit(self: *Self, buf: []u8, now: i64) ?usize {
            // idle-timeout: a peer that has gone silent past the bound is declared dead.
            if (cfg.delivery.idle_timeout_ms > 0 and self.had_any_recv and !self.closed and
                (now - self.last_recv_ms) > cfg.delivery.idle_timeout_ms)
            {
                self.closed = true;
                return null;
            }
            if (sec) {
                // Handshake datagrams (cleartext) precede the encrypted data path.
                // Time-gated so a `pollTransmit`-drain loop emits at most one per tick.
                const hs_due = !self.sec_state.hs_sent or (now - self.sec_state.hs_at) >= hs_interval_ms;
                switch (self.sec_state.state) {
                    .hello_sent => {
                        if (!hs_due) return null;
                        self.sec_state.hs_sent = true;
                        self.sec_state.hs_at = now;
                        const n = handshake.writeHello(buf, cfg.protocol_id, cfg.app_version);
                        self.sec_state.amp.onSent(n);
                        return n;
                    },
                    .response_sent => {
                        if (!hs_due) return null;
                        self.sec_state.hs_sent = true;
                        self.sec_state.hs_at = now;
                        const n = if (tokens_on)
                            handshake.writeResponseToken(buf, self.sec_state.echo, &self.sec_state.token_bytes)
                        else if (cid_on)
                            handshake.writeResponseCid(buf, self.sec_state.echo, self.sec_state.local_cid)
                        else
                            handshake.writeResponse(buf, self.sec_state.echo);
                        self.sec_state.amp.onSent(n);
                        return n;
                    },
                    .connected => {
                        if (self.sec_state.force_keepalive) {
                            self.sec_state.force_keepalive = false;
                            return self.emitSealed(buf, 0, now); // header-only keepalive
                        }
                    },
                    else => return null, // idle / challenged: nothing to send yet
                }
            }
            // live PMTUD: a probe timing out means the path can't carry that size.
            if (pmtud_on and self.probe_inflight and (now - self.probe_sent_at) > @max(self.resendMs(), 200)) {
                self.pmtu.onProbeLoss();
                self.probe_inflight = false;
            }
            // emit a DF-padded probe (inflated to a candidate size) when one is due.
            if (pmtud_on and !self.probe_inflight and (sec == false or self.isConnected())) {
                if (self.pmtu.nextProbe()) |size| {
                    if (size <= buf.len and size <= cfg.max_datagram) {
                        return self.emitProbe(buf, size, now);
                    }
                    self.pmtu.onProbeLoss(); // can't fit the probe → stop climbing
                }
            }
            // leave room for the AEAD tag when sealing.
            const tag_extra: usize = if (sec) Aead.tag_len else 0;
            const cur_mtu: usize = if (pmtud_on) self.pmtu.mtu() else cfg.mtu;
            const lim_len = (@min(buf.len, cur_mtu)) - tag_extra;
            // PacketNumberFilter: burn the pn(s) the filter wants skipped (never sent).
            if (pn_filter) {
                while (skipPn(self.next_pn)) {
                    self.pn_skipped.insert(self.next_pn, {});
                    self.next_pn +%= 1;
                }
            }
            // truncated packet number: 1–4 bytes vs the largest pn the peer has acked.
            const pn = self.next_pn;
            const nbytes: usize = delta.pnLength(@as(u64, pn), if (self.have_largest) @as(u64, self.largest_acked) else null);
            const hdr = 1 + cid_hdr + nbytes;
            if (lim_len < hdr) return null;
            var pos: usize = hdr;
            var has_ack = false;

            // PATH_CHALLENGE / PATH_RESPONSE (migration path validation) - sent even
            // while the path is unvalidated.
            if (cid_on) {
                if (self.sec_state.send_challenge and pos + 9 <= lim_len) {
                    buf[pos] = ftype_path_challenge;
                    std.mem.writeInt(u64, buf[pos + 1 ..][0..8], self.sec_state.path_token, .little);
                    pos += 9;
                    self.sec_state.send_challenge = false;
                }
                if (self.sec_state.send_response and pos + 9 <= lim_len) {
                    buf[pos] = ftype_path_response;
                    std.mem.writeInt(u64, buf[pos + 1 ..][0..8], self.sec_state.path_token, .little);
                    pos += 9;
                    self.sec_state.send_response = false;
                }
            }

            // ACK frame (piggyback whenever owed)
            if (self.unacked_eliciting and self.have_recv and pos + 1 < lim_len) {
                var f = AckT.generate(&self.recv_pns, self.most_recent_recv, lim.recvpn_cap);
                f.ack_delay = @intCast(std.math.clamp(now - self.most_recent_recv_at, 0, std.math.maxInt(u16)));
                if (AckT.encode(f, buf[pos + 1 .. lim_len])) |alen| {
                    buf[pos] = ftype_ack;
                    pos += 1 + alen;
                    has_ack = true;
                    self.unacked_eliciting = false;
                }
            }

            // control frames: DISCONNECT, PONG (answer a ping), fast-NAK, PING (idle).
            var ctrl = false;
            if (self.disconnecting and pos + 2 <= lim_len) {
                buf[pos] = ftype_disconnect;
                buf[pos + 1] = self.disc_reason;
                pos += 2;
                self.disconnecting = false;
                self.closed = true;
                ctrl = true;
            }
            if (self.owe_pong and pos + 9 <= lim_len) {
                buf[pos] = ftype_pong;
                std.mem.writeInt(u64, buf[pos + 1 ..][0..8], self.pong_nonce, .little);
                pos += 9;
                self.owe_pong = false;
                ctrl = true;
            }
            if (self.owe_nak and now >= self.nak_at and self.nak_missing.latestSeq() != null and pos + 1 < lim_len) {
                const f = AckT.generate(&self.nak_missing, self.nak_largest, 64);
                if (AckT.encode(f, buf[pos + 1 .. lim_len])) |nlen| {
                    buf[pos] = ftype_nak;
                    pos += 1 + nlen;
                    self.owe_nak = false;
                    ctrl = true;
                }
            }
            const idle_ping = (now - self.last_send_ms) >= cfg.delivery.ping_interval_ms;
            if (!self.ping_inflight and idle_ping and pos + 9 <= lim_len) {
                self.ping_nonce +%= 0x9E37_79B9_7F4A_7C15;
                buf[pos] = ftype_ping;
                std.mem.writeInt(u64, buf[pos + 1 ..][0..8], self.ping_nonce, .little);
                pos += 9;
                self.ping_inflight = true;
                self.ping_sent_at = now;
                ctrl = true;
            }

            // pacing / controller rate
            if (cfg.pacing) {
                if (@hasDecl(Cc, "pacingRate")) {
                    const r = self.cc.pacingRate();
                    if (r > 0) self.pacer.setRate(r) else self.pacer.setFromCwnd(self.cc.window(), self.rtt.smoothed_ms);
                } else {
                    self.pacer.setFromCwnd(self.cc.window(), self.rtt.smoothed_ms);
                }
                self.pacer.refill(now);
            }

            var ctx = PackCtx{
                .in_flight = self.outstandingBytes(),
                .cwnd_bytes = self.cc.window(),
                .lim = lim_len,
                .allow_reliable = !cfg.pacing or self.pacer.canSend(),
            };

            // WFQ packing: pick the ready lane with the best priority/virtual-finish
            // time, pack one frame, charge it, repeat until the datagram can take no
            // more. Data pauses while a migrated path is still being validated.
            const path_ok = !cid_on or self.sec_state.path.validated;
            var packed_any = false;
            if (path_ok) while (true) {
                var ready = [_]bool{false} ** N;
                inline for (0..N) |ci| ready[ci] = self.canSend(ci, pos, now, &ctx);
                const lane = self.sched.pickReady(&ready) orelse break;
                var got: usize = 0;
                inline for (0..N) |ci| {
                    if (lane == ci) got = self.packOne(ci, buf, &pos, now, &ctx);
                }
                if (got == 0) break;
                packed_any = true;
                self.sched.charge(lane, @intCast(got), &ready);
            };

            if (!has_ack and !packed_any and !ctrl and pos == hdr) return null;
            self.last_send_ms = now;

            // write the public header (flags + optional CID + truncated pn)
            self.writeHdr(buf, pn, nbytes);
            self.next_pn +%= 1;
            if (ctx.nids > 0) {
                self.bridge.record(pn, ctx.refs[0..ctx.nids], @intCast(pos), now);
            }

            if (sec) {
                // seal the frames region; AAD = the cleartext public header.
                var plain: [scratch_max]u8 = undefined;
                const fl = pos - hdr;
                @memcpy(plain[0..fl], buf[hdr..pos]);
                const sn = Aead.seal(self.sec_state.sealKey(), self.sec_state.sealIv(), @as(u64, pn), buf[0..hdr], plain[0..fl], buf[hdr..]);
                pos = hdr + sn;
                if (!self.sec_state.amp.canSend(pos)) return null; // 3× anti-amplification
                self.sec_state.amp.onSent(pos);
            }

            if (cfg.pacing) self.pacer.onSent(@intCast(pos));
            if (@hasDecl(Cc, "onSent")) self.cc.onSent(pos, now); // feed BBR the send rate
            self.tracer.onPacketSent(self.peer, pos);
            return pos;
        }

        /// Build a sealed datagram carrying `nframes` cleartext frame-bytes already
        /// staged in `buf[hdr..]` (0 ⇒ an empty keepalive); used for the post-accept
        /// proof packet. Returns the final datagram length.
        fn emitSealed(self: *Self, buf: []u8, nframes: usize, now: i64) usize {
            _ = now;
            const pn = self.next_pn;
            const nbytes: usize = delta.pnLength(@as(u64, pn), if (self.have_largest) @as(u64, self.largest_acked) else null);
            const hdr = 1 + cid_hdr + nbytes;
            self.writeHdr(buf, pn, nbytes);
            self.next_pn +%= 1;
            var plain: [scratch_max]u8 = undefined;
            @memcpy(plain[0..nframes], buf[hdr .. hdr + nframes]);
            const sn = Aead.seal(self.sec_state.sealKey(), self.sec_state.sealIv(), @as(u64, pn), buf[0..hdr], plain[0..nframes], buf[hdr..]);
            const total = hdr + sn;
            self.sec_state.amp.onSent(total);
            self.tracer.onPacketSent(self.peer, total);
            return total;
        }

        /// The current discovered path MTU (== cfg.mtu when PMTUD is off).
        pub fn pathMtu(self: *const Self) u16 {
            return if (pmtud_on) self.pmtu.mtu() else cfg.mtu;
        }
        /// Endpoint hook: large datagrams suddenly failing on an established path →
        /// fall back to the safe base MTU (only meaningful with PMTUD on).
        pub fn onBlackHole(self: *Self) void {
            if (pmtud_on) self.pmtu.onBlackHole();
        }

        /// Build a DF-padded PMTUD probe of exactly `size` wire bytes: a PING (so its
        /// PONG confirms the path carried it) + a PADDING frame inflating to `size`.
        fn emitProbe(self: *Self, buf: []u8, size: u16, now: i64) usize {
            const pn = self.next_pn;
            const nbytes: usize = delta.pnLength(@as(u64, pn), if (self.have_largest) @as(u64, self.largest_acked) else null);
            const hdr = 1 + cid_hdr + nbytes;
            const tag_extra: usize = if (sec) Aead.tag_len else 0;
            const frames_len: usize = @as(usize, size) - hdr - tag_extra; // candidates ≫ hdr+tag
            var plain: [scratch_max]u8 = undefined;
            self.probe_nonce +%= 0x9E37_79B9_7F4A_7C15;
            plain[0] = ftype_ping;
            std.mem.writeInt(u64, plain[1..9], self.probe_nonce, .little);
            plain[9] = ftype_padding;
            @memset(plain[10..frames_len], 0);
            self.writeHdr(buf, pn, nbytes);
            self.next_pn +%= 1;
            var total: usize = undefined;
            if (sec) {
                const sn = Aead.seal(self.sec_state.sealKey(), self.sec_state.sealIv(), @as(u64, pn), buf[0..hdr], plain[0..frames_len], buf[hdr..]);
                total = hdr + sn;
                self.sec_state.amp.onSent(total);
            } else {
                @memcpy(buf[hdr .. hdr + frames_len], plain[0..frames_len]);
                total = hdr + frames_len;
            }
            self.probe_inflight = true;
            self.probe_size = size;
            self.probe_sent_at = now;
            self.last_send_ms = now;
            self.tracer.onPacketSent(self.peer, total);
            return total;
        }

        pub fn feed(self: *Self, bytes: []const u8, now: i64) void {
            if (bytes.len < 2) return;
            if (sec and handshake.isHandshake(bytes)) {
                self.onHandshake(bytes);
                return;
            }
            const nbytes: usize = (bytes[0] & 0x3) + 1;
            const co: usize = if (cid_on and (bytes[0] & has_cid_bit != 0)) 8 else 0;
            if (bytes.len < 1 + co + nbytes) return;
            const hdr = 1 + co + nbytes;
            var trunc: u64 = 0;
            var k: usize = 0;
            while (k < nbytes) : (k += 1) trunc |= @as(u64, bytes[1 + co + k]) << @intCast(k * 8);
            const expected: u64 = if (self.have_recv) @as(u64, self.most_recent_recv) + 1 else trunc;
            const pn: Pn = @truncate(delta.reconstructPn(trunc, @intCast(nbytes), expected));

            // decrypt (or pass through) the frames region.
            var framebuf: [scratch_max]u8 = undefined;
            var payload: []const u8 = undefined;
            if (sec) {
                self.sec_state.amp.onRecv(bytes.len);
                const opened = Aead.open(self.sec_state.openKey(), self.sec_state.openIv(), @as(u64, pn), bytes[0..hdr], bytes[hdr..], &framebuf) orelse {
                    self.tracer.onDrop(self.peer, .malformed); // tamper / wrong key
                    return;
                };
                if (!self.sec_state.rwin.accept(pn)) {
                    self.tracer.onDrop(self.peer, .replay);
                    return;
                }
                // first authenticated server datagram confirms the client's path.
                if (self.sec_state.initiator and self.sec_state.state != .connected) {
                    self.sec_state.state = .connected;
                }
                self.sec_state.amp.validate();
                payload = framebuf[0..opened];
            } else {
                payload = bytes[hdr..];
            }
            self.tracer.onPacketRecv(self.peer, bytes.len);
            self.last_recv_ms = now;
            self.had_any_recv = true;

            const had_recv = self.have_recv;
            const prev_recv = self.most_recent_recv;
            self.recv_pns.insert(pn, {});
            self.nak_missing.remove(pn); // this pn is no longer missing
            if (!had_recv or seq.greaterThan(Pn, pn, self.most_recent_recv)) {
                if (had_recv) {
                    // a forward jump → the skipped pns are missing; schedule a fast-NAK
                    var g = prev_recv +% 1;
                    var guard: usize = 0;
                    while (g != pn and guard < loss_scan) : (g +%= 1) {
                        if (!self.recv_pns.exists(g)) {
                            self.nak_missing.insert(g, {});
                            self.nak_largest = g;
                            self.owe_nak = true;
                            self.nak_at = now + cfg.delivery.nack_delay_ms;
                        }
                        guard += 1;
                    }
                }
                self.most_recent_recv = pn;
                self.most_recent_recv_at = now; // for the ACK ack_delay field
                self.have_recv = true;
            }

            var pos: usize = 0;
            var eliciting = false;
            while (pos < payload.len) {
                const ft = payload[pos];
                if (ft == ftype_ack) {
                    const dec = AckT.decode(payload[pos + 1 ..]) orelse break;
                    var actx = AckCtx{ .s = self, .now = now, .ack_delay = dec.frame.ack_delay };
                    AckT.forEachAcked(dec.frame, &actx);
                    self.advanceUnacked();
                    self.detectLoss(dec.frame.largest, now);
                    pos += 1 + dec.len;
                } else if (ft == ftype_data) {
                    if (pos + 6 > payload.len) break;
                    const channel = payload[pos + 1];
                    const dseq = std.mem.readInt(u16, payload[pos + 2 ..][0..2], .little);
                    const len = std.mem.readInt(u16, payload[pos + 4 ..][0..2], .little);
                    pos += 6;
                    if (pos + len > payload.len or len > max_payload or channel >= N) {
                        self.tracer.onDrop(self.peer, .malformed);
                        break;
                    }
                    inline for (0..N) |ci| {
                        if (channel == ci) self.recv[ci].accept(dseq, payload[pos .. pos + len]);
                    }
                    pos += len;
                    eliciting = true;
                } else if (frag_on and ft == ftype_fragment) {
                    if (pos + 12 > payload.len) break;
                    const channel = payload[pos + 1];
                    const group = std.mem.readInt(u16, payload[pos + 4 ..][0..2], .little);
                    const index = std.mem.readInt(u16, payload[pos + 6 ..][0..2], .little);
                    const fcount = std.mem.readInt(u16, payload[pos + 8 ..][0..2], .little);
                    const len = std.mem.readInt(u16, payload[pos + 10 ..][0..2], .little);
                    pos += 12;
                    if (pos + len > payload.len or len > max_payload or channel >= N) {
                        self.tracer.onDrop(self.peer, .malformed);
                        break;
                    }
                    // reliable delivery guarantees each fragment arrives exactly once
                    if (self.reasm.feed(channel, .{ .group = group, .index = index, .count = fcount }, payload[pos .. pos + len])) |complete| {
                        if (!self.block_ready) {
                            @memcpy(self.block_buf[0..complete.bytes.len], complete.bytes);
                            self.block_len = complete.bytes.len;
                            self.block_ch = complete.channel;
                            self.block_ready = true;
                        } else self.tracer.onDrop(self.peer, .reassembly_full);
                    }
                    pos += len;
                    eliciting = true;
                } else if (cid_on and ft == ftype_path_challenge) {
                    if (pos + 9 > payload.len) break;
                    self.sec_state.path_token = std.mem.readInt(u64, payload[pos + 1 ..][0..8], .little);
                    self.sec_state.send_response = true; // echo it back
                    pos += 9;
                    eliciting = true;
                } else if (cid_on and ft == ftype_path_response) {
                    if (pos + 9 > payload.len) break;
                    const tok = std.mem.readInt(u64, payload[pos + 1 ..][0..8], .little);
                    _ = self.sec_state.path.onResponse(tok);
                    pos += 9;
                } else if (ft == ftype_ping) {
                    if (pos + 9 > payload.len) break;
                    self.pong_nonce = std.mem.readInt(u64, payload[pos + 1 ..][0..8], .little);
                    self.owe_pong = true;
                    pos += 9;
                } else if (ft == ftype_pong) {
                    if (pos + 9 > payload.len) break;
                    const nonce = std.mem.readInt(u64, payload[pos + 1 ..][0..8], .little);
                    if (self.ping_inflight and nonce == self.ping_nonce) {
                        self.rtt.sample(now - self.ping_sent_at);
                        self.tracer.onRttUpdate(self.peer, self.rtt.smoothed_ms);
                        self.ping_inflight = false;
                    }
                    if (pmtud_on and self.probe_inflight and nonce == self.probe_nonce) {
                        self.pmtu.onProbeAck(); // the path carried `probe_size` → raise the MTU
                        self.probe_inflight = false;
                    }
                    pos += 9;
                } else if (ft == ftype_nak) {
                    const dec = AckT.decode(payload[pos + 1 ..]) orelse break;
                    var nctx = NakCtx{ .s = self };
                    AckT.forEachAcked(dec.frame, &nctx); // "acked" = NACKed pns → re-eligible now
                    pos += 1 + dec.len;
                } else if (ft == ftype_padding) {
                    break; // PMTUD probe padding: ignore the rest of the datagram
                } else if (ft == ftype_disconnect) {
                    if (pos + 2 > payload.len) break;
                    self.disc_reason = payload[pos + 1];
                    self.closed = true;
                    break; // peer is gone; stop parsing this datagram
                } else break;
            }
            if (eliciting) self.unacked_eliciting = true;
        }

        /// Client-side handshake ingest (server hello/response handled by the endpoint).
        fn onHandshake(self: *Self, bytes: []const u8) void {
            const t = handshake.typeOf(bytes) orelse return;
            if (t == .challenge) {
                const c = handshake.readCookie(bytes) orelse return;
                self.sec_state.echo = c;
                self.sec_state.amp.onRecv(bytes.len);
                if (cid_on) {
                    if (handshake.readConnId(bytes)) |server_cid| self.sec_state.remote_cid = server_cid;
                }
                if (self.sec_state.state == .hello_sent or self.sec_state.state == .idle) {
                    self.sec_state.state = .response_sent;
                    self.sec_state.hs_sent = false; // emit the response promptly
                }
            }
        }

        const AckCtx = struct {
            s: *Self,
            now: i64,
            ack_delay: i64 = 0,
            pub fn ack(self: *@This(), pn: Pn) void {
                self.s.ackPn(pn, self.now, self.ack_delay);
            }
        };

        /// fast-NAK handler: a NACKed pn → its carried messages become re-eligible for
        /// retransmit *immediately* (sub-RTT), without a congestion penalty (it's a hint).
        const NakCtx = struct {
            s: *Self,
            pub fn ack(self: *@This(), pn: Pn) void {
                const e = self.s.bridge.get(pn) orelse return;
                var k: usize = 0;
                while (k < e.n) : (k += 1) {
                    const ref = e.ids[k];
                    inline for (0..N) |ci| {
                        if (comptime reliableOf(ci)) {
                            if (ref.ch == ci) {
                                if (self.s.tx[ci].q.get(ref.id)) |m| {
                                    if (!m.acked and m.ever_sent) {
                                        self.s.inflight_bytes -= frameSize(m);
                                        m.ever_sent = false;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        };

        fn ackPn(self: *Self, pn: Pn, now: i64, ack_delay: i64) void {
            // optimistic-ack defense: an ack of a never-sent (skipped) PN is a protocol
            // violation → close the connection.
            if (pn_filter and self.pn_skipped.exists(pn)) {
                self.tracer.onDrop(self.peer, .malformed);
                self.closed = true;
                return;
            }
            // spurious-loss recovery: a packet we declared lost is being acked.
            if (has_snapshot) {
                if (self.lost_pns.exists(pn)) {
                    if (self.loss_snapshot) |snap| self.cc.restore(snap);
                    self.loss_snapshot = null;
                    self.lost_pns.remove(pn);
                }
            }
            if (!self.have_largest or seq.greaterThan(Pn, pn, self.largest_acked)) {
                self.largest_acked = pn;
                self.have_largest = true;
            }
            const e = self.bridge.get(pn) orelse return;
            self.pto_backoff = 0; // forward progress → clear the PTO backoff
            // subtract the peer's reported ack_delay (time it held the ack) from the
            // sample so RTT reflects path latency - but only when the result stays at or
            // above the current min RTT (RFC 9002 §5.3), so it never deflates below the
            // true path floor.
            const raw = now - e.time;
            const rtt_sample = if (self.rtt.has and raw - ack_delay >= self.rtt.min_ms) raw - ack_delay else raw;
            self.rtt.sample(@max(rtt_sample, 0));
            self.tracer.onRttUpdate(self.peer, self.rtt.smoothed_ms);
            const in_flight = self.outstandingBytes();
            var acked_bytes: usize = 0;
            var k: usize = 0;
            while (k < e.n) : (k += 1) {
                const ref = e.ids[k];
                inline for (0..N) |ci| {
                    if (comptime reliableOf(ci)) {
                        if (ref.ch == ci) {
                            if (self.tx[ci].q.get(ref.id)) |m| {
                                if (!m.acked) {
                                    if (m.ever_sent) self.inflight_bytes -= frameSize(m);
                                    m.acked = true;
                                    acked_bytes += frameSize(m);
                                }
                            }
                        }
                    }
                }
            }
            self.ccOnAck(acked_bytes, rtt_sample, in_flight, now);
            self.tracer.onCwnd(self.peer, self.cc.window(), self.inflight_bytes);
            self.tracer.onAck(self.peer, acked_bytes);
            self.bridge.remove(pn);
        }

        fn advanceUnacked(self: *Self) void {
            inline for (0..N) |ci| {
                if (comptime reliableOf(ci)) {
                    const s = &self.tx[ci];
                    while (s.oldest != s.next) {
                        if (s.q.get(s.oldest)) |m| {
                            if (!m.acked) break;
                            s.q.remove(s.oldest);
                        }
                        s.oldest +%= 1;
                    }
                }
            }
        }

        fn detectLoss(self: *Self, largest: Pn, now: i64) void {
            var pn = largest -% loss_window;
            var any_lost = false;
            while (pn != largest) : (pn +%= 1) {
                const e = self.bridge.get(pn) orelse continue;
                if (loss.isLost(Pn, pn, largest, e.time, now, &self.rtt, lpt, ltn, ltd)) {
                    any_lost = true;
                    var k: usize = 0;
                    while (k < e.n) : (k += 1) {
                        const ref = e.ids[k];
                        inline for (0..N) |ci| {
                            if (comptime reliableOf(ci)) {
                                if (ref.ch == ci) {
                                    if (self.tx[ci].q.get(ref.id)) |m| {
                                        if (!m.acked and m.ever_sent) {
                                            self.inflight_bytes -= frameSize(m);
                                            m.ever_sent = false; // re-eligible
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if (has_snapshot and self.loss_snapshot == null) self.loss_snapshot = self.cc.snapshot();
                    self.lost_pns.insert(pn, {});
                    self.cc.onLoss(now, self.rtt.smoothed_ms);
                    self.tracer.onLoss(self.peer, @truncate(pn));
                    self.tracer.onCongestion(self.peer);
                    self.bridge.remove(pn);
                }
            }
            // a loss round with no concurrent progress backs the PTO off (capped at 4 → 16×)
            if (any_lost and self.pto_backoff < 4) self.pto_backoff += 1;
            // 3 consecutive loss rounds with zero acks between ⇒ persistent congestion:
            // the path went dark, so collapse cwnd to the minimum (RFC 9002 §7.6).
            if (any_lost and self.pto_backoff >= 3 and @hasDecl(Cc, "onPersistentCongestion")) {
                self.cc.onPersistentCongestion();
                self.tracer.onCongestion(self.peer);
            }
        }

        /// Earliest time the session next needs `pollTransmit`, or null if idle.
        pub fn pollDeadline(self: *Self, now: i64) ?i64 {
            if (sec) {
                const st = self.sec_state.state;
                if (st == .hello_sent or st == .response_sent or self.sec_state.force_keepalive) return now;
            }
            if (self.unacked_eliciting or self.owe_pong or self.disconnecting) return now;
            var earliest: ?i64 = if (self.owe_nak) self.nak_at else null;
            if (!self.ping_inflight) {
                const ping_at = self.last_send_ms + cfg.delivery.ping_interval_ms;
                earliest = if (earliest) |e| @min(e, ping_at) else ping_at;
            }
            inline for (0..N) |ci| {
                if (comptime reliableOf(ci)) {
                    const s = &self.tx[ci];
                    var id = s.oldest;
                    while (id != s.next) : (id +%= 1) {
                        const m = s.q.getConst(id) orelse continue;
                        if (m.acked) continue;
                        const due_at = if (m.ever_sent) m.last_sent + self.resendMs() else now;
                        earliest = if (earliest) |e| @min(e, due_at) else due_at;
                    }
                } else {
                    if (!self.tx[ci].q.isEmpty()) earliest = now;
                }
            }
            return earliest;
        }
    };
}

const testing = std.testing;
const channels = @import("schema.zig").channels;

const TestSchema = channels(.{
    .pos = .{ .mode = .unreliable, .Message = struct { x: i16, y: i16 } },
    .events = .{ .mode = .reliable_unordered, .Message = u32 },
    .chat = .{ .mode = .reliable_ordered, .Message = u32 },
});
const TestCfg = Config{ .channels = TestSchema, .limits = .{ .max_payload = 64, .channel_cap = 128, .bridge_cap = 1024, .recvpn_cap = 256 } };
const TestSession = Session(TestCfg);

test "typed multi-channel session: in-process roundtrip across modes" {
    var a: TestSession = .{};
    a.setup();
    var b: TestSession = .{};
    b.setup();

    try a.send(.pos, .{ .x = 5, .y = -7 });
    try a.send(.chat, 100);
    try a.send(.chat, 101);
    try a.send(.events, 9000);

    var buf: [mtu]u8 = undefined;
    var now: i64 = 0;
    var n: usize = 0;
    while (a.pollTransmit(&buf, now)) |len| : (now += 5) {
        b.feed(buf[0..len], now);
        n += 1;
        if (n > 50) break;
    }

    try testing.expectEqual(@as(i16, 5), b.receive(.pos).?.x);
    try testing.expectEqual(@as(u32, 100), b.receive(.chat).?);
    try testing.expectEqual(@as(u32, 101), b.receive(.chat).?);
    try testing.expectEqual(@as(u32, 9000), b.receive(.events).?);
    try testing.expect(b.receive(.chat) == null);
}

test "truncated packet numbers reconstruct correctly across many packets" {
    var a: TestSession = .{};
    a.setup();
    var b: TestSession = .{};
    b.setup();
    var buf: [mtu]u8 = undefined;
    var now: i64 = 0;
    var sent: u32 = 0;
    var count: usize = 0;
    var rounds: usize = 0;
    // send 300 events (forces pn well past 255 → 1-byte truncation must still work),
    // retrying on backpressure and draining each round so the delivery ring never overflows.
    while ((sent < 300 or a.hasUnacked()) and rounds < 4000) : (rounds += 1) {
        while (sent < 300) {
            a.send(.events, sent) catch break;
            sent += 1;
        }
        while (a.pollTransmit(&buf, now)) |len| b.feed(buf[0..len], now);
        while (b.receive(.events)) |_| count += 1;
        while (b.pollTransmit(&buf, now)) |len| a.feed(buf[0..len], now);
        now += 5;
    }
    try testing.expectEqual(@as(usize, 300), count); // all flowed through truncated-PN headers
}

test "pollDeadline schedules a keepalive ping when idle, polls now when work is pending" {
    var a: TestSession = .{};
    a.setup();
    // idle → wakes at the next keepalive-ping time (not never)
    try testing.expect(a.pollDeadline(1000).? >= 1000);
    try a.send(.chat, 1);
    try testing.expect(a.pollDeadline(1000).? <= 1000); // pending data → poll immediately
}

test "BBR plugs in as the congestion controller" {
    const Bbr = @import("../delivery/cc/bbr.zig").Bbr;
    const BbrCfg = Config{ .channels = TestSchema, .congestion = Bbr, .limits = TestCfg.limits };
    const BbrSession = Session(BbrCfg);
    var a: BbrSession = .{};
    a.setup();
    var b: BbrSession = .{};
    b.setup();
    var buf: [mtu]u8 = undefined;
    var now: i64 = 0;
    var sent: u32 = 0;
    var count: usize = 0;
    var rounds: usize = 0;
    while ((sent < 100 or a.hasUnacked()) and rounds < 4000) : (rounds += 1) {
        while (sent < 100) {
            a.send(.chat, sent) catch break;
            sent += 1;
        }
        while (a.pollTransmit(&buf, now)) |len| b.feed(buf[0..len], now);
        while (b.receive(.chat)) |_| count += 1;
        while (b.pollTransmit(&buf, now)) |len| a.feed(buf[0..len], now);
        now += 20;
    }
    try testing.expectEqual(@as(usize, 100), count);
}

test "config knobs: u32 PN width, tighter loss threshold, drop-new degrade" {
    const Schema = channels(.{ .rel = .{ .mode = .reliable_ordered, .Message = void } });
    const Cfg = Config{
        .channels = Schema,
        .seq = .{ .packet_number = u32 },
        .delivery = .{ .loss_packet_threshold = 1, .ack_blocks_max = 8 },
        .degrade = .{ .on_send_queue_full = .drop_new },
        .limits = .{ .channel_cap = 8, .max_payload = 16, .bridge_cap = 64, .recvpn_cap = 64 },
    };
    const Sess = Session(Cfg);
    try testing.expectEqual(u32, @TypeOf(@as(Sess, undefined).next_pn));

    var a: Sess = .{};
    a.setup();
    // fill the tiny reliable window; drop-new means sends never error, just drop.
    var i: usize = 0;
    while (i < 100) : (i += 1) try a.sendRaw(.rel, "x"); // no error.Backpressure under drop_new
}

test "PacketNumberFilter closes the peer on an optimistic ack of a skipped pn" {
    const Schema = channels(.{ .rel = .{ .mode = .reliable_ordered, .Message = u32 } });
    const Cfg = Config{ .channels = Schema, .delivery = .{ .pn_skip_period = 4 }, .limits = .{ .channel_cap = 64, .max_payload = 16, .bridge_cap = 256, .recvpn_cap = 256 } };
    const Sess = Session(Cfg);
    var a: Sess = .{};
    a.setup();
    // drive some sends so the pn space advances and skips at least one pn
    var buf: [mtu]u8 = undefined;
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        a.send(.rel, i) catch {};
        _ = a.pollTransmit(&buf, @intCast(i * 5));
    }
    // find a skipped pn and forge an ack for it (the optimistic-ack attack)
    var skipped_pn: ?u32 = null;
    var p: u32 = 1;
    while (p < a.next_pn) : (p += 1) {
        if (a.pn_skipped.exists(p)) {
            skipped_pn = p;
            break;
        }
    }
    try testing.expect(skipped_pn != null); // the filter actually skipped some pns
    try testing.expect(!a.isClosed());
    a.ackPn(skipped_pn.?, 1000, 0); // forged ack of a never-sent pn
    try testing.expect(a.isClosed()); // protocol violation → connection dropped
}

test "incremental in-flight counter never drifts from the O(window) recompute (under loss)" {
    var a: TestSession = .{};
    a.setup();
    var b: TestSession = .{};
    b.setup();
    var buf: [mtu]u8 = undefined;
    var now: i64 = 0;
    var sent: u32 = 0;
    var got: usize = 0;
    var rounds: usize = 0;
    // drop ~1 in 3 datagrams each way; the counter must equal the recompute every step.
    var prng = std.Random.DefaultPrng.init(0x10F1);
    const rnd = prng.random();
    while ((sent < 120 or a.hasUnacked()) and rounds < 6000) : (rounds += 1) {
        while (sent < 120) {
            a.send(.chat, sent) catch break;
            sent += 1;
        }
        while (a.pollTransmit(&buf, now)) |len| {
            if (!rnd.boolean()) b.feed(buf[0..len], now); // ~50% loss
            try testing.expectEqual(a.outstandingBytesSlow(), a.inflight_bytes); // never drifts
        }
        while (b.receive(.chat)) |_| got += 1;
        while (b.pollTransmit(&buf, now)) |len| a.feed(buf[0..len], now);
        try testing.expectEqual(a.outstandingBytesSlow(), a.inflight_bytes);
        now += 5;
    }
    try testing.expectEqual(@as(usize, 120), got);
    try testing.expectEqual(@as(usize, 0), a.inflight_bytes); // all acked → zero in flight
    try testing.expectEqual(a.outstandingBytesSlow(), a.inflight_bytes);
}
