//! Copied from spikes/s3-congestion/src/lib.rs (branch claude/project-thread-m39r02), plus the
//! optional burst credit (`RateKnob::burst_us`) added for spike S10b.
//! Spike S3: an application-driven QUIC congestion controller for iroh.
//!
//! The idea: our delay-gradient rate controller (in the Zig core) owns the send
//! rate. QUIC's controller must not fight it, so this controller does not react
//! to loss on its own. It paces at an externally set target rate and keeps the
//! window large enough that it never binds below that rate. Loss and ACK
//! signals are counted and exposed so the core can read them.
//!
//! Everything here is reachable through iroh's public API:
//! `iroh::endpoint::{Controller, ControllerFactory, ControllerMetrics, RttEstimator}`
//! and `QuicTransportConfig::builder().congestion_controller_factory(..)`.

use std::any::Any;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use iroh::endpoint::{Controller, ControllerFactory, ControllerMetrics, RttEstimator};

/// Shared knob the application (later: the Zig core via the shim C ABI) turns.
#[derive(Debug, Default)]
pub struct RateKnob {
    /// Target send rate in bits/s. 0 means "no limit" (window-only, no pacing rate).
    pub target_bps: AtomicU64,
    /// Burst credit in microseconds at the target rate (S10 follow-up, spike S10b). 0 keeps S3's
    /// behaviour: noq's own pacer at `target_bps`, whose bucket holds ~2 ms of credit.
    pub burst_us: AtomicU64,
}

impl RateKnob {
    pub fn set_target_bps(&self, bps: u64) {
        self.target_bps.store(bps, Relaxed);
    }
}

/// Per-controller (one per QUIC path) counters, readable from outside.
#[derive(Debug, Default)]
pub struct PathCounters {
    pub path_index: u64,
    pub sent_bytes: AtomicU64,
    pub sent_calls: AtomicU64,
    pub acked_bytes: AtomicU64,
    pub ack_calls: AtomicU64,
    pub congestion_events: AtomicU64,
    pub lost_bytes: AtomicU64,
    pub ecn_events: AtomicU64,
    pub srtt_us: AtomicU64,
    pub min_rtt_us: AtomicU64,
    pub mtu: AtomicU64,
}

/// Factory installed through iroh's `QuicTransportConfigBuilder`.
#[derive(Debug)]
pub struct AppRateFactory {
    pub knob: Arc<RateKnob>,
    /// Every controller this factory built, in build order (one per path).
    pub built: Mutex<Vec<Arc<PathCounters>>>,
}

impl AppRateFactory {
    pub fn new(knob: Arc<RateKnob>) -> Arc<Self> {
        Arc::new(Self {
            knob,
            built: Mutex::new(Vec::new()),
        })
    }

    pub fn built_count(&self) -> usize {
        self.built.lock().unwrap().len()
    }
}

impl ControllerFactory for AppRateFactory {
    fn build(self: Arc<Self>, _now: Instant, current_mtu: u16) -> Box<dyn Controller> {
        let mut built = self.built.lock().unwrap();
        let counters = Arc::new(PathCounters {
            path_index: built.len() as u64,
            ..Default::default()
        });
        counters.mtu.store(current_mtu as u64, Relaxed);
        built.push(counters.clone());
        Box::new(AppRate {
            knob: self.knob.clone(),
            counters,
            mtu: current_mtu,
            srtt: Duration::from_millis(1),
            credit: 0.0,
            credit_at: _now,
        })
    }
}

/// The controller itself. Marker type so `Connection::congestion_state` can be
/// downcast to prove it is the one in use.
#[derive(Debug, Clone)]
pub struct AppRate {
    pub knob: Arc<RateKnob>,
    pub counters: Arc<PathCounters>,
    mtu: u16,
    srtt: Duration,
    /// Burst credit in bytes as of `credit_at`, negative while in debt (only used when
    /// `knob.burst_us > 0`).
    credit: f64,
    credit_at: Instant,
}

/// Pacing rate reported while the burst bucket has credit: high enough that noq's pacer
/// releases a burst at line rate (its bucket then holds MAX_BURST_SIZE = 256 packets and
/// refills in ~0.3 ms), so the controller's own bucket is what bounds the burst.
const BURST_PACING_RATE: u64 = 10_000_000_000 / 8;

/// Window used when no target is set.
const UNLIMITED_WINDOW: u64 = 64 * 1024 * 1024;
/// RTT floor for window sizing, so sub-ms LAN RTTs don't starve the window.
const MIN_RTT_FOR_WINDOW: Duration = Duration::from_millis(5);

impl AppRate {
    fn target_bytes_per_sec(&self) -> u64 {
        self.knob.target_bps.load(Relaxed) / 8
    }

    /// Size of the burst bucket in bytes: `burst_us` of traffic at the target rate.
    fn burst_bytes(&self) -> f64 {
        self.target_bytes_per_sec() as f64 * self.knob.burst_us.load(Relaxed) as f64 / 1e6
    }

    /// Credit on hand at `now`: a token bucket refilled at the target rate, capped at
    /// `burst_bytes`. `metrics()` only has `&self`, so this is computed lazily from the
    /// last `on_sent`.
    fn credit_at(&self, now: Instant) -> f64 {
        let dt = now.saturating_duration_since(self.credit_at).as_secs_f64();
        (self.credit + dt * self.target_bytes_per_sec() as f64).min(self.burst_bytes())
    }
}

impl Controller for AppRate {
    fn on_sent(&mut self, now: Instant, bytes: u64, _largest_pn: u64) {
        if self.knob.burst_us.load(Relaxed) > 0 {
            // No floor at zero: noq sends a `send_quantum` batch (2 packets) once one
            // packet's credit is there, and forgiving that overdraft lifts the sustained
            // rate above the target (measured: 93.8 Mbit/s payload on a 90 target).
            self.credit = self.credit_at(now) - bytes as f64;
            self.credit_at = now;
        }
        self.counters.sent_bytes.fetch_add(bytes, Relaxed);
        self.counters.sent_calls.fetch_add(1, Relaxed);
    }

    fn on_ack(
        &mut self,
        _now: Instant,
        _sent: Instant,
        bytes: u64,
        _pn: u64,
        _app_limited: bool,
        rtt: &RttEstimator,
    ) {
        self.srtt = rtt.get();
        self.counters.acked_bytes.fetch_add(bytes, Relaxed);
        self.counters.ack_calls.fetch_add(1, Relaxed);
        self.counters
            .srtt_us
            .store(rtt.get().as_micros() as u64, Relaxed);
        self.counters
            .min_rtt_us
            .store(rtt.min().as_micros() as u64, Relaxed);
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
        // Deliberately no window cut: the app rate controller reacts, not QUIC.
        self.counters.congestion_events.fetch_add(1, Relaxed);
        self.counters.lost_bytes.fetch_add(lost_bytes, Relaxed);
        if is_ecn {
            self.counters.ecn_events.fetch_add(1, Relaxed);
        }
    }

    fn on_mtu_update(&mut self, new_mtu: u16) {
        self.mtu = new_mtu;
        self.counters.mtu.store(new_mtu as u64, Relaxed);
    }

    fn window(&self) -> u64 {
        let rate = self.target_bytes_per_sec();
        if rate == 0 {
            return UNLIMITED_WINDOW;
        }
        // 2x BDP headroom so the window never binds below the target; pacing shapes.
        let rtt = self.srtt.max(MIN_RTT_FOR_WINDOW);
        let bdp = (rate as u128 * rtt.as_nanos() / 1_000_000_000) as u64;
        // The burst must not be window-limited either: add the whole bucket on top.
        (2 * bdp).max(4 * self.mtu as u64) + self.burst_bytes() as u64
    }

    fn metrics(&self) -> ControllerMetrics {
        let mut m = ControllerMetrics::default();
        m.congestion_window = self.window();
        let rate = self.target_bytes_per_sec();
        if rate > 0 {
            // With burst credit, pace at line rate while the controller's bucket holds at
            // least one packet, and at the target once it is spent. noq's pacer re-reads
            // this on every poll and pacing timer, so the switch takes effect per packet.
            let burst = self.knob.burst_us.load(Relaxed) > 0
                && self.credit_at(Instant::now()) >= self.mtu as f64;
            m.pacing_rate = Some(if burst { BURST_PACING_RATE } else { rate });
            m.send_quantum = Some(2 * self.mtu as u64);
            m.bandwidth_estimate = Some(rate * 8);
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
