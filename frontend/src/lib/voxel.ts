// Voxel scenes for the four machines, drawn by components/VoxelCanvas. Y is up; models are centred on x = z = 0.

export type RGB = [number, number, number];
export type Voxel = [x: number, y: number, z: number, c: RGB];
export type Scene = {
  /** Static scenes are built once; animated ones every frame from the time in seconds. */
  build: (t: number) => Voxel[];
  animated: boolean;
  /** Half-width in voxels the camera must fit, and the vertical centre of the model. */
  radius: number;
  centerY: number;
};

export const hex = (h: string): RGB => {
  const n = parseInt(h.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
};

function rng(seed: number) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Stable per-cell noise in [0, 1). */
function hash3(x: number, y: number, z: number) {
  const s = Math.sin(x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453;
  return s - Math.floor(s);
}

/** Small brightness jitter so flat areas read as voxels, not plastic. */
function tint(c: RGB, x: number, y: number, z: number, amount = 0.08): RGB {
  const k = 1 + (hash3(x, y, z) - 0.5) * 2 * amount;
  return [c[0] * k, c[1] * k, c[2] * k];
}

class Grid {
  private cells = new Map<string, Voxel>();
  set(x: number, y: number, z: number, c: RGB) {
    x = Math.round(x);
    y = Math.round(y);
    z = Math.round(z);
    this.cells.set(`${x},${y},${z}`, [x, y, z, c]);
  }
  has(x: number, y: number, z: number) {
    return this.cells.has(`${Math.round(x)},${Math.round(y)},${Math.round(z)}`);
  }
  list() {
    return [...this.cells.values()];
  }
}

// ---------------------------------------------------------------- Earth: a bonsai in a clay tray

const BARK = ["#7a2e22", "#8f3a2a", "#a9432c"].map(hex);
const LEAF = ["#24533d", "#2f6b4f", "#3f8a67", "#57a07a", "#7fbf98"].map(hex);
const CLAY = hex("#6b4a2f");
const CLAY_DARK = hex("#4e3522");
const SOIL = hex("#2e2418");
const MOSS = hex("#4f7a3a");

type Pad = { at: number; angle: number; reach: number; size: number };
type Canopy = (g: Grid, x: number, y: number, z: number, size: number, t: number) => void;

/** Tray, trunk and bare branches; returns where each branch ends so a canopy can grow there. */
function bonsaiFrame(scale: number, seed: number, pads: Pad[]) {
  const g = new Grid();
  const r = rng(seed);
  const S = (v: number) => v * scale;

  // tray
  const tw = Math.round(S(9)), td = Math.round(S(6)), th = Math.max(2, Math.round(S(3)));
  for (let x = -tw; x <= tw; x++)
    for (let z = -td; z <= td; z++)
      for (let y = 0; y < th; y++) {
        const edge = Math.abs(x) === tw || Math.abs(z) === td;
        const inset = y === 0 && (Math.abs(x) === tw || Math.abs(z) === td);
        if (inset) continue;
        if (edge || y < th - 1) g.set(x, y, z, tint(y === th - 1 ? CLAY : CLAY_DARK, x, y, z));
        else g.set(x, y, z, tint(r() < 0.25 ? MOSS : SOIL, x, y, z, 0.15));
      }

  // trunk: a leaning S-curve, thick at the base
  const H = S(17);
  const trunk: [number, number, number][] = [];
  for (let i = 0; i <= H; i++) {
    const f = i / H;
    const x = Math.sin(f * 3.2) * S(4.2) - f * S(1.5);
    const z = Math.sin(f * 2.1 + 1) * S(1.6);
    trunk.push([x, th + i, z]);
    const w = Math.max(0.6, S(2.4) * (1 - f) + 0.5);
    for (let dx = -2; dx <= 2; dx++)
      for (let dz = -2; dz <= 2; dz++)
        if (dx * dx + dz * dz <= w * w) g.set(x + dx, th + i, z + dz, tint(BARK[(((i + dx) % 3) + 3) % 3], x + dx, i, z + dz, 0.1));
  }

  // branches out to the canopies
  const ends: [number, number, number, number][] = [];
  for (const { at, angle, reach, size } of pads) {
    const [bx, by, bz] = trunk[Math.min(trunk.length - 1, Math.round(at * H))];
    const ex = bx + Math.cos(angle) * S(reach);
    const ez = bz + Math.sin(angle) * S(reach);
    const ey = by + S(2) + r() * S(1.5);
    const steps = Math.ceil(S(reach) * 1.4);
    for (let s = 0; s <= steps; s++) {
      const k = s / steps;
      g.set(bx + (ex - bx) * k, by + (ey - by) * k + Math.sin(k * Math.PI) * S(1), bz + (ez - bz) * k, tint(BARK[1], s, by, k, 0.1));
    }
    ends.push([ex, ey, ez, S(size)]);
  }
  return { base: g.list(), ends };
}

/** A flattened, ragged ellipsoid; `paint` picks each cell's colour from its relative height (0 bottom, 1 top). */
function blob(g: Grid, cx: number, cy: number, cz: number, size: number, paint: (h: number, x: number, y: number, z: number) => RGB | null) {
  const rx = size, ry = size * 0.42, rz = size * 0.85;
  for (let x = Math.floor(-rx); x <= rx; x++)
    for (let y = Math.floor(-ry); y <= ry + 1; y++)
      for (let z = Math.floor(-rz); z <= rz; z++) {
        const d = (x * x) / (rx * rx) + (y * y) / (ry * ry) + (z * z) / (rz * rz);
        if (d > 0.72 + hash3(cx + x, cy + y, cz + z) * 0.5) continue;
        const c = paint((y + ry) / (2 * ry), x, y, z);
        if (c) g.set(cx + x, cy + y, cz + z, c);
      }
}

const leaves: Canopy = (g, cx, cy, cz, size) =>
  blob(g, cx, cy, cz, size, (h, x, y, z) => tint(LEAF[Math.min(4, Math.max(0, Math.floor(h * 3.2 + hash3(x, y, z) * 1.8)))], x, y, z, 0.06));

/** Water foliage: blue leaves with light rippling across them and drops falling off. */
const waterLeaves: Canopy = (g, cx, cy, cz, size, t) => {
  blob(g, cx, cy, cz, size, (h, x, y, z) => {
    const ripple = Math.sin(t * 2.4 + x * 0.6 + z * 0.4 - y * 0.8) * 0.9;
    return WATER[Math.min(4, Math.max(0, Math.round(h * 2.6 + ripple + hash3(x, y, z) * 0.8)))];
  });
  for (let i = 0; i < 4; i++) {
    const ph = (t * 0.7 + i * 0.27) % 1;
    g.set(cx + ((i * 3) % 5) - 2, cy - size * 0.45 - ph * 9, cz + ((i * 2) % 3) - 1, WATER[3 + (i % 2)]);
  }
};

/** Fire foliage: a flat pad of flame colours with heat flickering across it. */
const fireLeaves: Canopy = (g, cx, cy, cz, size, t) =>
  blob(g, cx, cy, cz, size, (h, x, y, z) => {
    const flicker = Math.sin(t * 3.1 + x * 0.7 - z * 0.5 + y) * 0.9;
    return FLAME[Math.min(4, Math.max(0, Math.round(h * 2.6 + flicker + hash3(x, y, z) * 0.8)))];
  });

/** Air foliage: a flat pad of cloud with pale wind drifting across it. */
const airLeaves: Canopy = (g, cx, cy, cz, size, t) =>
  blob(g, cx, cy, cz, size, (h, x, y, z) => {
    const gust = Math.sin(t * 1.8 + x * 0.5 + z * 0.3) * 0.8;
    const c = Math.round(h * 2.4 + gust + hash3(x, y, z) * 0.8);
    return c > 3 ? WIND[1] : CLOUD[Math.max(0, c)];
  });

function grow(frame: ReturnType<typeof bonsaiFrame>, canopies: Canopy[], t: number) {
  const g = new Grid();
  for (const [x, y, z, c] of frame.base) g.set(x, y, z, c);
  frame.ends.forEach(([x, y, z, size], i) => canopies[i % canopies.length](g, x, y, z, size, t));
  return g.list();
}

// The hero tree: one branch for each machine, its canopy made of that element.
const ELEMENT_PADS: Pad[] = [
  { at: 0.5, angle: 0.3, reach: 8, size: 6.4 },
  { at: 0.66, angle: 0.3 + Math.PI / 2, reach: 7.5, size: 6 },
  { at: 0.82, angle: 0.3 + Math.PI, reach: 7, size: 5.8 },
  { at: 1.0, angle: 0.3 + (3 * Math.PI) / 2, reach: 5.5, size: 5.8 },
];
let elementFrame: ReturnType<typeof bonsaiFrame> | undefined;
function elementTree(t: number) {
  elementFrame ??= bonsaiFrame(1, 7, ELEMENT_PADS);
  return grow(elementFrame, [leaves, waterLeaves, fireLeaves, airLeaves], t);
}

const EARTH_PADS: Pad[] = [
  { at: 0.55, angle: Math.PI, reach: 7.5, size: 5.5 },
  { at: 0.72, angle: 0.2, reach: 6.5, size: 5 },
  { at: 0.88, angle: Math.PI - 0.6, reach: 5, size: 4.5 },
  { at: 1.0, angle: 0.8, reach: 5.5, size: 5.5 },
];
function bonsai(scale: number, seed: number) {
  return grow(bonsaiFrame(scale, seed, EARTH_PADS), [leaves], 0);
}

// ---------------------------------------------------------------- Water: a stone basin with a fountain

const STONE = ["#4a463c", "#5f5a4c", "#6f6a5b"].map(hex);
const WATER = ["#1f4a63", "#2c5d7c", "#3f7ea3", "#74b3d6", "#b9e0f2"].map(hex);

function basin(t: number): Voxel[] {
  const g = new Grid();
  const R = 7;
  for (let x = -R; x <= R; x++)
    for (let z = -R; z <= R; z++) {
      const rim = Math.abs(x) === R || Math.abs(z) === R;
      if (rim) {
        for (let y = 0; y < 5; y++) g.set(x, y, z, tint(STONE[(x + z + y + 30) % 3], x, y, z, 0.12));
        continue;
      }
      g.set(x, 0, z, tint(STONE[0], x, 0, z));
      const wave = Math.sin(x * 0.7 + t * 2.2) + Math.cos(z * 0.6 + t * 1.7) + Math.sin((x + z) * 0.4 - t * 1.3);
      const top = 3 + Math.round(wave * 0.55);
      for (let y = 1; y <= top; y++) {
        const idx = y === top ? (wave > 1 ? 4 : 3) : y === top - 1 ? 2 : y > 1 ? 1 : 0;
        g.set(x, y, z, tint(WATER[idx], x, y, z, 0.05));
      }
    }
  // fountain jet and falling drops
  const jet = 7 + Math.round(Math.sin(t * 3) * 1.2);
  for (let y = 3; y < 3 + jet; y++) {
    g.set(0, y, 0, WATER[y > jet ? 4 : 3]);
    if (y < 6) {
      g.set(1, y, 0, WATER[3]);
      g.set(0, y, 1, WATER[3]);
    }
  }
  for (let i = 0; i < 10; i++) {
    const a = (i / 10) * Math.PI * 2 + t * 0.4;
    const ph = (t * 1.1 + i * 0.37) % 1;
    const d = 1 + ph * 4.5;
    const y = 3 + jet - ph * ph * (jet + 1);
    if (y > 3) g.set(Math.cos(a) * d, y, Math.sin(a) * d, WATER[4]);
  }
  return g.list();
}

// ---------------------------------------------------------------- Fire: an iron brazier with a living flame

const IRON = ["#26241e", "#3a372f", "#4d493e"].map(hex);
const EMBER = ["#5a1d12", "#a9432c"].map(hex);
const FLAME = ["#a9432c", "#c4561f", "#e0876d", "#ecbb48", "#fff1c4"].map(hex);

function brazier(t: number): Voxel[] {
  const g = new Grid();
  // legs
  for (const [lx, lz] of [[-4, -4], [4, -4], [-4, 4], [4, 4]])
    for (let y = 0; y < 3; y++) g.set(lx, y, lz, IRON[1]);
  // bowl
  for (let y = 3; y < 6; y++) {
    const R = 3 + (y - 3) * 1.5;
    for (let x = -6; x <= 6; x++)
      for (let z = -6; z <= 6; z++) {
        const d = Math.sqrt(x * x + z * z);
        if (d <= R && (d > R - 1.3 || y === 3)) g.set(x, y, z, tint(IRON[(x + y + z + 30) % 3], x, y, z, 0.1));
      }
  }
  // coals
  for (let x = -5; x <= 5; x++)
    for (let z = -5; z <= 5; z++)
      if (x * x + z * z <= 20) g.set(x, 5, z, hash3(x, Math.floor(t * 3), z) > 0.6 ? EMBER[1] : EMBER[0]);
  // flame: a noisy cone that flickers with time
  const H = 14;
  for (let y = 6; y < 6 + H; y++) {
    const f = (y - 6) / H;
    const R = (1 - f) * 4.6 + 0.4;
    const sway = Math.sin(t * 2.6 + f * 4) * f * 1.6;
    for (let x = -5; x <= 5; x++)
      for (let z = -5; z <= 5; z++) {
        const d = Math.sqrt((x - sway) ** 2 + z * z);
        const n = hash3(x, y - Math.floor(t * 9), z);
        if (d > R * (0.7 + n * 0.5)) continue;
        if (f > 0.55 && n < 0.45) continue;
        const heat = 1 - d / (R + 0.01);
        const idx = Math.max(0, Math.min(4, Math.round(heat * 3.2 + (1 - f) * 1.4 - 0.6)));
        g.set(x, y, z, FLAME[idx]);
      }
  }
  // sparks
  for (let i = 0; i < 8; i++) {
    const ph = (t * 0.6 + i * 0.131) % 1;
    const a = i * 2.4;
    g.set(Math.cos(a) * (1 + ph * 3), 10 + ph * 12, Math.sin(a) * (1 + ph * 3), FLAME[3 + (i % 2)]);
  }
  return g.list();
}

// ---------------------------------------------------------------- Air: a drifting cloud with wind around it

const CLOUD = ["#9d9686", "#cdc6b5", "#e2dccb", "#f4efe2"].map(hex);
const WIND = ["#8f88c8", "#b8b2e0"].map(hex);

const CLOUD_PUFFS: [number, number, number, number][] = [
  [0, 0, 0, 5],
  [-5, -1, 1, 3.6],
  [5, -1, -1, 3.8],
  [2, 2, 1, 3.4],
  [-2, 1.5, -2, 3],
];

function cloud(t: number): Voxel[] {
  const g = new Grid();
  const bob = Math.round(Math.sin(t * 1.2) * 1);
  const base = 10 + bob;
  for (const [cx, cy, cz, r] of CLOUD_PUFFS)
    for (let x = Math.floor(-r); x <= r; x++)
      for (let y = Math.floor(-r * 0.7); y <= r * 0.7; y++)
        for (let z = Math.floor(-r); z <= r; z++) {
          const d = (x * x + z * z) / (r * r) + (y * y) / (r * r * 0.49);
          if (d > 0.8 + hash3(cx + x, y, cz + z) * 0.3) continue;
          const h = (y + r * 0.7) / (r * 1.4);
          g.set(cx + x, base + cy + y, cz + z, CLOUD[Math.min(3, Math.floor(h * 3.4 + 0.3))]);
        }
  // three wind streams orbiting at different heights and speeds
  for (let s = 0; s < 3; s++) {
    const R = 9 + s * 1.5;
    const y0 = 4 + s * 5;
    for (let i = 0; i < 26; i++) {
      const a = (i / 40) * Math.PI * 2 + t * (0.9 + s * 0.35) + s * 2;
      g.set(Math.cos(a) * R, y0 + Math.sin(a * 2 + t) * 1.2, Math.sin(a) * R, WIND[i > 18 ? 1 : 0]);
    }
  }
  // rain of tiny particles drifting off the cloud
  for (let i = 0; i < 6; i++) {
    const ph = (t * 0.5 + i * 0.17) % 1;
    g.set(-6 + i * 2.4 + ph * 4, base - 4 - ph * 8, (i % 3) - 1, CLOUD[1]);
  }
  return g.list();
}

export const SCENES: Record<"bonsai" | "earth" | "water" | "fire" | "air", Scene> = {
  bonsai: { build: elementTree, animated: true, radius: 17, centerY: 13 },
  earth: { build: () => bonsai(0.72, 11), animated: false, radius: 8.5, centerY: 9 },
  water: { build: basin, animated: true, radius: 10.5, centerY: 5 },
  fire: { build: brazier, animated: true, radius: 9.5, centerY: 10 },
  air: { build: cloud, animated: true, radius: 12, centerY: 9 },
};

export const MACHINE_SCENE = ["earth", "water", "fire", "air"] as const;
