import type { MachineId } from "./gamma";

export type BatchView = {
  id: number;
  machine: MachineId;
  epoch: number;
  energies: number;
  survivors: number;
  drawn: boolean;
  claimed: boolean;
  harvested: boolean;
  winnings: number;
  bonus: number;
  feeBps: number;
};

export type MachineView = {
  /** Energies placed this epoch. */
  energies: number;
  /** Last finalized epoch on this machine. */
  last: { shareTenths: number; survivors: number; energies: number; payPerSurvivor: number } | null;
};

export type FeedItem = {
  id: string;
  kind: "buy" | "epoch" | "harvest" | "claim" | "trade";
  text: string;
  machine?: MachineId;
  at: number;
};

export type GameView = {
  mode: "live" | "demo";
  ready: boolean;
  connected: boolean;
  address?: string;
  now: number;
  genesis: number;
  epoch: number;
  day: number;
  epochEndsIn: number;
  harvestIn: number;
  tranche: number;
  machines: MachineView[];
  pot: number;
  dayFails: number;
  totalBurned: number;
  totalEnergies: number;
  released: number;
  tradingFeeBps: number;
  /** IMD for one energy at the current pool price. */
  energyPriceImd: number;
  imdBalance: number;
  gammaBalance: number;
  batches: BatchView[];
  feed: FeedItem[];
  busy: string | null;
  error: string | null;
  speed: number;
};

export type GameActions = {
  buy: (machine: MachineId, energies: number) => Promise<void>;
  claim: (ids: number[], maturedOnly: boolean) => Promise<void>;
  settle: () => Promise<void>;
  setSpeed: (speed: number) => void;
  connect: () => void;
  disconnect: () => void;
  clearError: () => void;
};
