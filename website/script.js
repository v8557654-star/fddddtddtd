/* -------------------------------------------------------------
  Trailer canvas animation – first‑person “bodycam” flight
  escaping a monster.  Pure CSS‑filter style, no external libs.
  ------------------------------------------------------------- */

const canvas = document.getElementById('trailerCanvas');
const ctx = canvas.getContext('2d');

function setCanvasSize() {
  canvas.width = window.innerWidth;
  canvas.height = window.innerHeight * 0.6; // 60% of viewport
}
setCanvasSize();
window.addEventListener('resize', setCanvasSize);

// ---- Game-like variables ----
let t = 0; // overall time
const player = { x: 0, y: 0, zoom: 1 };
const monster = { x: 0, y: 0 };
const obstacles = []; // simple static walls (random)

// ---- Simple level geometry (2D pseudo-3D corridor) ----
const wallHeight = 60; // pixel height of each strip
const numRays = canvas.width / 2; // horizontal resolution

// generate a static maze-like corridor using sine waves
function generateWalls() {
  obstacles.length = 0;
  const amp = 80; // amplitude of wiggle
  const freq = 0.02; // frequency
  for (let i = 0; i < numRays; i++) {
    const offset = Math.sin((i / numRays) * Math.PI * 2 + t * 0.3) * amp;
    const y = canvas.height / 2 + offset;
    obstacles.push({ x: i, y: y, halfW: 30 }); // 30px wide column
  }
}
generateWalls();

// ---- Player ray casting (simplified) ----
function castRays(dt) {
  t += dt;
  // move player forward (negative z -> approaching screen)
  player.x -= 0.8 * dt; // moving towards left of screen (camera forward)
  player.y = Math.sin(t * 0.5) * 30; // subtle bob

  // move monster chasing from behind
  monster.x += 0.4 * dt;
  monster.y = Math.cos(t * 0.4) * 40 + 80;

  // redraw
  ctx.fillStyle = '#0a0a0a';
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  // draw ceiling & floor color split
  ctx.fillStyle = '#111';
  ctx.fillRect(0, 0, canvas.width, canvas.height / 2);
  ctx.fillStyle = '#0d0d0d';
  ctx.fillRect(0, canvas.height / 2, canvas.width, canvas.height / 2);

  // draw walls as vertical strips
  for (let i = 0; i < numRays; i++) {
    const obs = obstacles[i];
    // simple fish‑eye projection: distance = player.x + offset
    const dist = Math.max(1, player.x + i * 2);
    const projHeight = (wallHeight * canvas.height) / (dist + 1);
    const top = (canvas.height - projHeight) / 2;

    // color based on distance (darker far)
    const alpha = Math.max(0.2, 1 - dist / (canvas.width * 1.5));
    ctx.fillStyle = `rgba(30,30,30,${alpha})`;

    // slight chromatic aberration offset for bodycam feel
    ctx.fillRect(obs.x, top, obs.halfW * 2, projHeight);
    // duplicate with slight offset for glitch
    ctx.fillStyle = `rgba(35,35,35,${alpha * 0.8})`;
    ctx.fillRect(obs.x + 1, top + 1, obs.halfW * 2 - 2, projHeight - 2);
  }

  // draw monster as a red silhouette approaching
  const mx = Math.round(monster.x) % canvas.width;
  const my = Math.round(monster.y) % (canvas.height / 2);
  ctx.fillStyle = '#ff4d4d';
  ctx.beginPath();
  ctx.arc(mx, my + canvas.height / 4, 25, 0, Math.PI * 2);
  ctx.fill();

  // request next frame
  requestAnimationFrame(castRays);
}

// start animation loop (dt approx 1/60)
castRays(0);

// -------------------------------------------------------------
// Simple glitch overlay on the whole page (CSS already adds scanlines)
// we add occasional "flash" via JS for drama
// -------------------------------------------------------------
let flashTimeout = null;
function triggerGlitchFlash() {
  const overlay = document.createElement('div');
  overlay.style.position = 'fixed';
  overlay.style.inset = 0;
  overlay.style.background = 'rgba(255,0,0,0.4)';
  overlay.style.pointerEvents = 'none';
  overlay.style.zIndex = 9999;
  overlay.style.animation = 'flash 0.1s forwards';
  document.body.appendChild(overlay);
  setTimeout(() => overlay.remove(), 120);
}
function startGlitchInterval() {
  flashTimeout = setInterval(triggerGlitchFlash, 3000 + Math.random() * 2000);
}
startGlitchInterval();

// stop interval when leaving page (simple)
window.addEventListener('beforeunload', () => clearInterval(flashTimeout));

/* -------------------------------------------------------------
   Optional: pause / play button (just toggles the interval)
   ------------------------------------------------------------- */
let isPaused = false;
document.querySelector('.play-btn')?.addEventListener('click', (e) => {
  e.preventDefault();
  isPaused = !isPaused;
  if (isPaused) {
    clearInterval(flashTimeout);
    flashTimeout = null;
    e.target.textContent = 'Продолжить';
  } else {
    startGlitchInterval();
    e.target.textContent = 'Посмотреть трейлер';
  }
});

/* ---- Respect reduced motion ---- */
if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
  clearInterval(flashTimeout);
  flashTimeout = null;
}