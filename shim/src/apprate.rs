//! `AppRate`: the shim's QUIC congestion controller (spike S3, burst credit from S10).
//!
//! The Zig core owns the send rate. This controller never reacts to loss on its own: it
//! paces at the target the core sets with `iroh_conn_set_target_bitrate`, keeps the window
//! at 2x BDP (plus the burst) so it never binds below that rate, and counts loss, acks and
//! stalls so the core can read them.
//!
//! iroh builds one controller per network path. Every controller of a connection shares one
//! [`RateKnob`]; the knob records which controller belongs to the selected path, and only that
//! one paces at the target. The others pace at [`IDLE_PATH_BPS`] (or the target, if lower), so
//! the rate moves with the path when iroh switches.
//!
//! Burst credit: a frame arrives all at once. Credit accumulates at the target rate up to
//! `burst_us` worth of bytes; once it is full, the controller reports a pacing rate of
//! [`BURST_GAIN`] x the target until the credit is spent, so a frame leaves at close to line rate and the bottleneck
//! queue, not the pacer, absorbs it (S10: 2.2 -> ~0.6 ms added p99 for one frame of credit).

use std::any::Any;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering::Relaxed};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use iroh::endpoint::{Controller, ControllerFactory, ControllerMetrics, RttEstimator};

/// Pacing rate multiplier while burst credit is available.
pub const BURST_GAIN: u64 = 10;
/// Pacing rate of a path that is not selected (keep-alives, probes), unless the target is lower.
pub const IDLE_PATH_BPS: u64 = 1_000_000;
/// Window used when no target is set (no pacing rate either).
const UNLIMITED_WINDOW: u64 = 64 * 1024 * 1024;
/// RTT floor for window sizing, so sub-ms LAN RTTs don't starve the window.
const MIN_RTT_FOR_WINDOW: Duration = Duration::from_millis(5);
/// No controller selected yet: every path paces at the target.
pub const NO_SELECTION: u32 = u32::MAX;

/// Process-wide monotonic epoch for the shim's microsecond timestamps.
pub fn epoch() -> Instant {
    static EPOCH: OnceLock<Instant> = OnceLock::new();
    *EPOCH.get_or_init(Instant::now)
}

pub fn now_us() -> u64 {
    epoch().elapsed().as_micros() as u64
}

fn instant_us(t: Instant) -> u64 {
    t.saturating_duration_since(epoch()).as_micros() as u64
}

/// Shared rate settings for all controllers of one connection.
#[derive(Debug)]
pub struct RateKnob {
    /// Target send rate in bits/s. 0 means no pacing rate (window only).
    pub target_bps: AtomicU64,
    /// Burst credit in microseconds of the target rate. 0 disables burst credit.
    pub burst_us: AtomicU64,
    /// Controller index (see [`PathCounters::ctl_index`]) of the selected path.
    pub selected: AtomicU32,
}

impl RateKnob {
    pub fn new(target_bps: u64, burst_us: u64) -> Self {
        Self {
            target_bps: AtomicU64::new(target_bps),
            burst_us: AtomicU64::new(burst_us),
            selected: AtomicU32::new(NO_SELECTION),
        }
    }
}

/// Per-controller (one per QUIC path) counters, readable from any thread.
#[derive(Debug, Default)]
pub struct PathCounters {
    /// Build order within the connection's factory.
    pub ctl_index: u32,
    pub sent_bytes: AtomicU64,
    pub acked_bytes: AtomicU64,
    pub congestion_events: AtomicU64,
    pub lost_bytes: AtomicU64,
    pub ecn_events: AtomicU64,
    pub srtt_us: AtomicU64,
    pub min_rtt_us: AtomicU64,
    /// Base pacing rate (without burst gain) the controller last reported, bits/s (0 = unpaced).
    pub pacing_bps: AtomicU64,
    /// Shim-clock time (us) of the last ack; 0 = never.
    pub last_ack_us: AtomicU64,
    /// Shim-clock time (us) of the first send since the last ack; 0 = nothing unacked.
    pub unacked_since_us: AtomicU64,
}

impl PathCounters {
    /// How long ack-eliciting data has gone unacknowledged on this path, in us (0 = none).
    pub fn ack_stall_us(&self, now_us: u64) -> u64 {
        match self.unacked_since_us.load(Relaxed) {
            0 => 0,
            t => now_us.saturating_sub(t),
        }
    }
}

/// One factory per connection, installed through that connection's transport config.
#[derive(Debug)]
pub struct AppRateFactory {
    pub knob: Arc<RateKnob>,
    /// Every controller this factory built, in build order.
    pub built: Mutex<Vec<Arc<PathCounters>>>,
}

impl AppRateFactory {
    pub fn new(knob: Arc<RateKnob>) -> Arc<Self> {
        Arc::new(Self { knob, built: Mutex::new(Vec::new()) })
    }
}

impl ControllerFactory for AppRateFactory {
    fn build(self: Arc<Self>, now: Instant, current_mtu: u16) -> Box<dyn Controller> {
        let mut built = self.built.lock().unwrap();
        let counters = Arc::new(PathCounters { ctl_index: built.len() as u32, ..Default::default() });
        built.push(counters.clone());
        Box::new(AppRate {
            knob: self.knob.clone(),
            counters,
            mtu: current_mtu,
            srtt: Duration::from_millis(1),
            credit: 0,
            credit_at: now,
            bursting: Arc::new(AtomicBool::new(false)),
        })
    }
}

/// The controller. `Connection::congestion_state(path)` returns a clone, which the shim
/// downcasts to map a path ID to its counters.
#[derive(Debug, Clone)]
pub struct AppRate {
    pub knob: Arc<RateKnob>,
    pub counters: Arc<PathCounters>,
    mtu: u16,
    srtt: Duration,
    /// Burst credit in bytes as of `credit_at`.
    credit: u64,
    credit_at: Instant,
    /// Reporting the boosted rate. Turns on only once the credit is full again and off when it
    /// runs out: noq's pacer refills at whatever rate is reported for the whole time since it
    /// last refilled, so flipping on at every MTU of credit would leak rate above the target.
    bursting: Arc<AtomicBool>,
}

impl AppRate {
    /// Target for this path in bytes/s (0 = unlimited).
    fn rate_bytes(&self) -> u64 {
        let target = self.knob.target_bps.load(Relaxed);
        let sel = self.knob.selected.load(Relaxed);
        let bps = if target == 0 || sel == NO_SELECTION || sel == self.counters.ctl_index {
            target
        } else {
            target.min(IDLE_PATH_BPS)
        };
        bps / 8
    }

    fn burst_cap(&self, rate: u64) -> u64 {
        let us = self.knob.burst_us.load(Relaxed);
        (rate as u128 * us as u128 / 1_000_000) as u64
    }

    fn credit_at(&self, rate: u64, now: Instant) -> u64 {
        let dt = now.saturating_duration_since(self.credit_at);
        let earned = (rate as u128 * dt.as_nanos() / 1_000_000_000) as u64;
        self.credit.saturating_add(earned).min(self.burst_cap(rate))
    }
}

impl Controller for AppRate {
    fn on_sent(&mut self, now: Instant, bytes: u64, _largest_pn: u64) {
        self.counters.sent_bytes.fetch_add(bytes, Relaxed);
        let rate = self.rate_bytes();
        self.credit = self.credit_at(rate, now).saturating_sub(bytes);
        self.credit_at = now;
        if self.credit < self.mtu as u64 {
            self.bursting.store(false, Relaxed);
        }
    }

    /// Only ack-eliciting packets: pure ACKs never get acked, so they must not start a stall.
    fn on_packet_sent(&mut self, now: Instant, _bytes: u16, _pn: u64) {
        if self.counters.unacked_since_us.load(Relaxed) == 0 {
            self.counters.unacked_since_us.store(instant_us(now).max(1), Relaxed);
        }
    }

    fn on_ack(&mut self, now: Instant, _sent: Instant, bytes: u64, _pn: u64, _app_limited: bool, rtt: &RttEstimator) {
        self.srtt = rtt.get();
        self.counters.acked_bytes.fetch_add(bytes, Relaxed);
        self.counters.srtt_us.store(rtt.get().as_micros() as u64, Relaxed);
        self.counters.min_rtt_us.store(rtt.min().as_micros() as u64, Relaxed);
        self.counters.last_ack_us.store(instant_us(now).max(1), Relaxed);
        self.counters.unacked_since_us.store(0, Relaxed);
    }

    fn on_congestion_event(
        &mut self,
        _now: Instant,
        _sent: Instant,
        _is_persistent_congestion: bool,
        is_ecn: bool,
        lost_bytes: u64,
        _largest_lost_pn: u64,
    ) {
        // Deliberately no window cut: the core's rate controller reacts, not QUIC.
        self.counters.congestion_events.fetch_add(1, Relaxed);
        self.counters.lost_bytes.fetch_add(lost_bytes, Relaxed);
        if is_ecn {
            self.counters.ecn_events.fetch_add(1, Relaxed);
        }
    }

    fn on_mtu_update(&mut self, new_mtu: u16) {
        self.mtu = new_mtu;
    }

    fn window(&self) -> u64 {
        let rate = self.rate_bytes();
        if rate == 0 {
            return UNLIMITED_WINDOW;
        }
        // 2x BDP headroom so the window never binds below the target, plus the burst.
        let rtt = self.srtt.max(MIN_RTT_FOR_WINDOW);
        let bdp = (rate as u128 * rtt.as_nanos() / 1_000_000_000) as u64;
        (2 * bdp).max(4 * self.mtu as u64) + self.burst_cap(rate)
    }

    fn metrics(&self) -> ControllerMetrics {
        let mut m = ControllerMetrics::default();
        m.congestion_window = self.window();
        let rate = self.rate_bytes();
        if rate > 0 {
            let cap = self.burst_cap(rate);
            let mut bursting = self.bursting.load(Relaxed);
            if !bursting && cap >= self.mtu as u64 && self.credit_at(rate, Instant::now()) >= cap {
                bursting = true;
                self.bursting.store(true, Relaxed);
            }
            let paced = if bursting { rate * BURST_GAIN } else { rate };
            self.counters.pacing_bps.store(rate * 8, Relaxed);
            m.pacing_rate = Some(paced);
            m.send_quantum = Some(2 * self.mtu as u64);
            m.bandwidth_estimate = Some(rate * 8);
        } else {
            self.counters.pacing_bps.store(0, Relaxed);
        }
        m
    }

    fn clone_box(&self) -> Box<dyn Controller> {
        Box::new(self.clone())
    }

    fn initial_window(&self) -> u64 {
        self.window()
    }

    fn into_any(self: Box<Self>) -> Box<dyn Any> {
        self
    }
}
