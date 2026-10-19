// The GAMMA rules, mirrored from src/ for charts, estimates and the demo.

export const EPOCH_SECONDS = 600;
export const EPOCHS_PER_DAY = 144;
export const DAY_SECONDS = 86_400;
export const ENERGY_COST = 1_000; // GAMMA per energy
export const MAX_BATCH = 500;
export const SHARES_BPS = 9_000;

export const TOTAL_SUPPLY = 1_000_000_000;
export const RESERVE = 800_000_000;
export const YEAR1 = 500_000_000;
export const TAIL = 300_000_000;
export const YEAR1_EPOCHS = 365 * EPOCHS_PER_DAY;

const K = Math.pow(2, -1 / 17_280);
const K_YEAR1 = Math.pow(K, YEAR1_EPOCHS);
const G = Math.pow(1 - 0.001327, 1 / 144);

export type MachineId = 0 | 1 | 2 | 3;

export const MACHINES = [
  {
    id: 0,
    name: "Earth",
    glyph: "◆",
    fail: 0.1,
    color: "var(--earth)",
    hex: "#7fbf98",
    profile: "Steady",
    blurb: "9 in 10 energies survive. Small, frequent Share payouts.",
  },
  {
    id: 1,
    name: "Water",
    glyph: "◈",
    fail: 0.3,
    color: "var(--water)",
    hex: "#74b3d6",
    profile: "Balanced",
    blurb: "7 in 10 survive. A middle path between Shares and Harvest.",
  },
  {
    id: 2,
    name: "Fire",
    glyph: "▲",
    fail: 0.6,
    color: "var(--fire)",
    hex: "#e0876d",
    profile: "Aggressive",
    blurb: "4 in 10 survive. Fewer people split each Share.",
  },
  {
    id: 3,
    name: "Air",
    glyph: "✦",
    fail: 0.9,
    color: "var(--air)",
    hex: "#b8b2e0",
    profile: "Volatile",
    blurb: "1 in 10 survive. Collects ~9× more Harvest per energy than Earth.",
  },
] as const;

/** Total GAMMA released by the start of epoch n. */
export function released(n: number): number {
  if (n <= 0) return 0;
  if (n >= YEAR1_EPOCHS) return YEAR1 + TAIL * (1 - Math.pow(G, n - YEAR1_EPOCHS));
  return (YEAR1 * (1 - Math.pow(K, n))) / (1 - K_YEAR1);
}

export function tranche(e: number): number {
  return released(e + 1) - released(e);
}

export function dailyEmission(day: number): number {
  return released((day + 1) * EPOCHS_PER_DAY) - released(day * EPOCHS_PER_DAY);
}

/** Energies per epoch (all machines) below which the Shares pay out more than the miners burn. */
export function breakEvenEnergies(e: number): number {
  return tranche(e) / ENERGY_COST;
}

/** Claim fee in bps for a day whose Harvest happened `elapsed` seconds ago. */
export function claimFeeBps(elapsed: number): number {
  if (elapsed <= 0) return 8_000;
  if (elapsed >= DAY_SECONDS) return 1_000;
  return Math.floor(8_000 - (7_000 * elapsed) / DAY_SECONDS);
}

/** Hook trading fee in bps, `seconds` after the pool opened. */
export function tradingFeeBps(seconds: number): number {
  const decay = Math.floor(seconds / 60) * 100;
  return Math.max(300, 9_900 - decay);
}

export function epochOf(now: number, genesis: number): number {
  return Math.max(0, Math.floor((now - genesis) / EPOCH_SECONDS));
}

export const DEAD = "0x000000000000000000000000000000000000dEaD" as const;
