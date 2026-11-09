// Orb Drift: a tiny HTML5 canvas game for the browser host spike (web/host/README.md).
// Plain canvas 2D, Web Audio, keyboard, mouse, wheel and the Gamepad API, written the
// way small HTML5 games are (rAF loop, window key listeners with legacy keyCode,
// navigator.getGamepads() polled every frame), with nothing moonsec-specific in it.
//
// Controls: arrows/WASD or left stick/d-pad to move, mouse to aim, click (or pad A) to
// pulse, wheel to change size. Collect orbs. Holding L, the left button or pad A turns the
// probe square in the top-left corner white (the latency tests watch it).
(() => {
  const canvas = document.getElementById("game");
  const g = canvas.getContext("2d");
  const W = canvas.width;
  const H = canvas.height;

  const state = {
    x: W / 2,
    y: H / 2,
    r: 18,
    score: 0,
    frame: 0,
    keys: new Set(),
    keyCodes: new Set(),
    mouse: { x: W / 2, y: H / 2, down: false, clicks: 0, moves: 0 },
    wheel: 0,
    pad: { connected: false, id: "", a: false, lx: 0, ly: 0, events: 0 },
    pads: 0,
    pulses: [],
    orbs: [],
    sounds: 0,
  };
  window.game = state;

  // --- audio: a quiet drone plus blips ------------------------------------------------
  const Ctx = window.AudioContext || window.webkitAudioContext;
  const ac = new Ctx();
  const master = ac.createGain();
  master.gain.value = 0.6;
  master.connect(ac.destination);
  const drone = ac.createOscillator();
  drone.frequency.value = 440;
  const droneGain = ac.createGain();
  // ?drone=0 silences it (the media element test listens for another sound).
  droneGain.gain.value = new URLSearchParams(location.search).get("drone") === "0" ? 0 : 0.15;
  drone.connect(droneGain).connect(master);
  drone.start();
  window.addEventListener("pointerdown", () => ac.resume(), { once: true });
  window.addEventListener("keydown", () => ac.resume(), { once: true });

  function blip(freq) {
    const o = ac.createOscillator();
    const e = ac.createGain();
    o.type = "square";
    o.frequency.setValueAtTime(freq, ac.currentTime);
    o.frequency.exponentialRampToValueAtTime(freq * 2, ac.currentTime + 0.08);
    e.gain.setValueAtTime(0.25, ac.currentTime);
    e.gain.exponentialRampToValueAtTime(0.001, ac.currentTime + 0.12);
    o.connect(e).connect(master);
    o.start();
    o.stop(ac.currentTime + 0.13);
    state.sounds++;
  }

  // --- input ---------------------------------------------------------------------------
  window.addEventListener("keydown", (e) => {
    state.keys.add(e.code);
    state.keyCodes.add(e.keyCode);
    if (e.code.startsWith("Arrow") || e.code === "Space") e.preventDefault();
  });
  window.addEventListener("keyup", (e) => {
    state.keys.delete(e.code);
    state.keyCodes.delete(e.keyCode);
  });
  const toCanvas = (e) => {
    const r = canvas.getBoundingClientRect();
    return { x: ((e.clientX - r.left) / r.width) * W, y: ((e.clientY - r.top) / r.height) * H };
  };
  canvas.addEventListener("mousemove", (e) => {
    const p = toCanvas(e);
    state.mouse.x = p.x;
    state.mouse.y = p.y;
    state.mouse.moves++;
  });
  canvas.addEventListener("mousedown", (e) => {
    if (e.button !== 0) return;
    state.mouse.down = true;
    pulse(state.mouse.x, state.mouse.y);
  });
  window.addEventListener("mouseup", (e) => {
    if (e.button === 0) state.mouse.down = false;
  });
  canvas.addEventListener("click", () => state.mouse.clicks++);
  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    state.wheel += Math.sign(e.deltaY);
    state.r = Math.max(8, Math.min(48, state.r - Math.sign(e.deltaY) * 2));
  });
  window.addEventListener("gamepadconnected", (e) => {
    state.pad.events++;
    state.pad.id = e.gamepad.id;
  });
  window.addEventListener("gamepaddisconnected", () => state.pad.events++);

  function pulse(x, y) {
    state.pulses.push({ x, y, t: 0 });
    blip(330);
  }

  // --- world -----------------------------------------------------------------------------
  let seed = 7;
  const rand = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
  for (let i = 0; i < 8; i++) state.orbs.push({ x: 60 + rand() * (W - 120), y: 60 + rand() * (H - 120), hue: rand() * 360 });

  let prevA = false;
  function update() {
    state.frame++;
    let dx = 0;
    let dy = 0;
    const k = state.keys;
    if (k.has("ArrowLeft") || k.has("KeyA")) dx -= 1;
    if (k.has("ArrowRight") || k.has("KeyD")) dx += 1;
    if (k.has("ArrowUp") || k.has("KeyW")) dy -= 1;
    if (k.has("ArrowDown") || k.has("KeyS")) dy += 1;
    const pads = navigator.getGamepads ? navigator.getGamepads() : [];
    const gp = Array.from(pads).find((p) => p && p.connected);
    state.pads = Array.from(pads).filter((p) => p && p.connected).length;
    state.pad.connected = !!gp;
    state.pad.a = false;
    if (gp) {
      state.pad.id = gp.id;
      const ax = gp.axes[0] || 0;
      const ay = gp.axes[1] || 0;
      state.pad.lx = ax;
      state.pad.ly = ay;
      if (Math.abs(ax) > 0.2) dx += ax;
      if (Math.abs(ay) > 0.2) dy += ay;
      if (gp.buttons[14] && gp.buttons[14].pressed) dx -= 1;
      if (gp.buttons[15] && gp.buttons[15].pressed) dx += 1;
      if (gp.buttons[12] && gp.buttons[12].pressed) dy -= 1;
      if (gp.buttons[13] && gp.buttons[13].pressed) dy += 1;
      state.pad.a = !!(gp.buttons[0] && gp.buttons[0].pressed);
      if (state.pad.a && !prevA) pulse(state.x, state.y);
    }
    prevA = state.pad.a;
    state.x = Math.max(state.r, Math.min(W - state.r, state.x + dx * 4));
    state.y = Math.max(state.r, Math.min(H - state.r, state.y + dy * 4));
    for (const o of state.orbs) {
      if (Math.hypot(o.x - state.x, o.y - state.y) < state.r + 10) {
        state.score++;
        o.x = 60 + rand() * (W - 120);
        o.y = 60 + rand() * (H - 120);
        blip(660);
      }
    }
    for (const p of state.pulses) p.t++;
    state.pulses = state.pulses.filter((p) => p.t < 30);
  }

  function draw() {
    g.fillStyle = "#101820";
    g.fillRect(0, 0, W, H);
    g.strokeStyle = "#1f3040";
    for (let x = 0; x < W; x += 40) g.strokeRect(x, 0, 40, H);
    for (const o of state.orbs) {
      g.fillStyle = `hsl(${(o.hue + state.frame) % 360} 80% 60%)`;
      g.beginPath();
      g.arc(o.x, o.y, 10, 0, Math.PI * 2);
      g.fill();
    }
    for (const p of state.pulses) {
      g.strokeStyle = `rgba(255,255,255,${1 - p.t / 30})`;
      g.beginPath();
      g.arc(p.x, p.y, 10 + p.t * 3, 0, Math.PI * 2);
      g.stroke();
    }
    g.fillStyle = "#f4c542";
    g.beginPath();
    g.arc(state.x, state.y, state.r, 0, Math.PI * 2);
    g.fill();
    g.strokeStyle = "#e0f0ff";
    g.beginPath();
    g.moveTo(state.mouse.x - 10, state.mouse.y);
    g.lineTo(state.mouse.x + 10, state.mouse.y);
    g.moveTo(state.mouse.x, state.mouse.y - 10);
    g.lineTo(state.mouse.x, state.mouse.y + 10);
    g.stroke();
    // Probe for the latency tests: white while L, the left button or pad A is held.
    const probe = state.keys.has("KeyL") || state.mouse.down || state.pad.a;
    g.fillStyle = probe ? "#fff" : "#000";
    g.fillRect(0, 0, 48, 48);
    g.fillStyle = "#cde";
    g.font = "16px monospace";
    g.fillText(`score ${state.score}  frame ${state.frame}${state.pad.connected ? "  pad" : ""}`, 60, 24);
  }

  function loop() {
    update();
    draw();
    requestAnimationFrame(loop);
  }
  requestAnimationFrame(loop);
})();
