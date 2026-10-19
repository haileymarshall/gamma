// The demo: GAMMA's rules run locally against a simulated crowd, with time sped up.
// Same constants as the contracts; randomness comes from Math.random instead of drand.

import {
  DAY_SECONDS,
  ENERGY_COST,
  EPOCHS_PER_DAY,
  EPOCH_SECONDS,
  MACHINES,
  claimFeeBps,
  released,
  tradingFeeBps,
  tranche,
  type MachineId,
} from "./gamma";
import type { BatchView, FeedItem, GameView, MachineView } from "./types";

type SimBatch = Omit<BatchView, "harvested" | "winnings" | "bonus" | "feeBps"> & { bonusIndexAt: number };

type SimEpoch = {
  energies: number[];
  crowd: number[];
  survivors: number[];
  pps: number[];
  shareTenths: number[];
  finalized: boolean;
};

type SimDay = { pot: number; fails: number; perFail: number; finalized: boolean; bonusIndex: number };

const DEAL = [6, 2, 2, 0];

function binomialSurvivors(n: number, fail: number): number {
  if (n > 200) {
    const mean = n * (1 - fail);
    const sd = Math.sqrt(n * fail * (1 - fail));
    const z = Math.sqrt(-2 * Math.log(Math.random() || 1e-9)) * Math.cos(2 * Math.PI * Math.random());
    return Math.max(0, Math.min(n, Math.round(mean + z * sd)));
  }
  let s = 0;
  for (let i = 0; i < n; i++) if (Math.random() >= fail) s++;
  return s;
}

function shuffle<T>(a: T[]): T[] {
  const r = [...a];
  for (let i = r.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [r[i], r[j]] = [r[j], r[i]];
  }
  return r;
}

export class GammaSim {
  speed = 60;
  genesis: number;
  now: number;
  private lastReal = 0;
  private cursor = 0;
  epochs = new Map<number, SimEpoch>();
  days = new Map<number, SimDay>();
  batches: SimBatch[] = [];
  feed: FeedItem[] = [];
  imd = 250_000;
  gamma = 0;
  totalBurned = 0;
  totalEnergies = 0;
  price = 0.012; // IMD per GAMMA
  private crowdUnclaimed = 0;
  private bonusIndex = 0;
  private totalUnclaimedUser = 0;
  private listeners = new Set<() => void>();
  private feedSeq = 0;

  constructor() {
    const t = Date.now() / 1000;
    // Start 22 hours into day 0 so the first Harvest arrives within minutes at demo speed.
    this.genesis = t - 22 * 60 * 60;
    this.now = t;
    this.cursor = Math.floor((this.now - this.genesis) / EPOCH_SECONDS);
    this.lastReal = t;
    for (let e = 0; e < this.cursor; e++) {
      this.crowdEpoch(e);
      this.finalize(e);
    }
    this.feed = [];
    this.crowdEpoch(this.cursor);
  }

  subscribe(fn: () => void) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private emit() {
    this.listeners.forEach((l) => l());
  }

  private push(item: Omit<FeedItem, "id" | "at">) {
    this.feed = [{ ...item, id: `f${this.feedSeq++}`, at: this.now }, ...this.feed].slice(0, 40);
  }

  private day(d: number): SimDay {
    let day = this.days.get(d);
    if (!day) {
      day = { pot: 0, fails: 0, perFail: 0, finalized: false, bonusIndex: 0 };
      this.days.set(d, day);
    }
    return day;
  }

  private epoch(e: number): SimEpoch {
    let ep = this.epochs.get(e);
    if (!ep) {
      ep = {
        energies: [0, 0, 0, 0],
        crowd: [0, 0, 0, 0],
        survivors: [0, 0, 0, 0],
        pps: [0, 0, 0, 0],
        shareTenths: [0, 0, 0, 0],
        finalized: false,
      };
      this.epochs.set(e, ep);
    }
    return ep;
  }

  /** The crowd: miners come when the margin is fat and leave when it is thin. */
  private crowdEpoch(e: number) {
    const ep = this.epoch(e);
    const breakEven = tranche(e) / ENERGY_COST;
    const appetite = breakEven * (0.6 + Math.random() * 1.4);
    const weights = [0.32, 0.26, 0.22, 0.2].map((w) => w * (0.6 + Math.random() * 0.8));
    const sum = weights.reduce((a, b) => a + b, 0);
    for (let m = 0; m < 4; m++) {
      const n = Math.round((appetite * weights[m]) / sum);
      ep.crowd[m] += n;
      ep.energies[m] += n;
      this.totalEnergies += n;
      this.totalBurned += n * ENERGY_COST;
    }
  }

  tick() {
    const real = Date.now() / 1000;
    const dt = Math.min(5, real - this.lastReal);
    this.lastReal = real;
    this.now += dt * this.speed;

    const cur = Math.floor((this.now - this.genesis) / EPOCH_SECONDS);
    let steps = 0;
    while (this.cursor < cur && steps < 200) {
      this.finalize(this.cursor);
      this.cursor++;
      if (this.cursor % EPOCHS_PER_DAY === 0) this.harvest(this.cursor / EPOCHS_PER_DAY - 1);
      this.crowdEpoch(this.cursor);
      steps++;
    }
    // Background trading, 3% to the Harvest.
    if (Math.random() < 0.08 * Math.min(4, this.speed / 30)) {
      const vol = 20_000 + Math.random() * 400_000;
      const fee = (vol * tradingFeeBps(1e9)) / 10_000;
      this.day(this.today).pot += fee;
      this.price *= 1 + (Math.random() - 0.48) * 0.01;
      if (Math.random() < 0.35)
        this.push({ kind: "trade", text: `Trader ${Math.random() < 0.5 ? "bought" : "sold"} ${Math.round(vol / 1000)}K GAMMA · ${Math.round(fee).toLocaleString()} to Harvest` });
    }
    this.emit();
  }

  get today() {
    return Math.floor(this.cursor / EPOCHS_PER_DAY);
  }

  private finalize(e: number) {
    const ep = this.epoch(e);
    if (ep.finalized) return;
    const t = tranche(e);
    const pool = t * 0.9;
    let toHarvest = t - pool;
    const deal = shuffle(DEAL);
    let fails = 0;

    const userBatches = this.batches.filter((b) => b.epoch === e);
    for (let m = 0; m < 4; m++) {
      const crowdSurv = binomialSurvivors(ep.crowd[m], MACHINES[m].fail);
      let surv = crowdSurv;
      for (const b of userBatches.filter((b) => b.machine === m)) {
        b.survivors = binomialSurvivors(b.energies, MACHINES[m].fail);
        b.drawn = true;
        surv += b.survivors;
      }
      ep.survivors[m] = surv;
      fails += ep.energies[m] - surv;
      const share = (pool * deal[m]) / 10;
      if (surv === 0) toHarvest += share;
      else {
        ep.pps[m] = share / surv;
        this.crowdUnclaimed += ep.pps[m] * crowdSurv;
      }
    }
    ep.shareTenths = deal;
    ep.finalized = true;
    const day = this.day(Math.floor(e / EPOCHS_PER_DAY));
    day.pot += toHarvest;
    day.fails += fails;

    // The crowd claims a slice of its winnings each epoch; a third of the fee goes to the patient.
    const claimed = this.crowdUnclaimed * 0.015;
    if (claimed > 0) {
      this.crowdUnclaimed -= claimed;
      const fee = claimed * 0.35;
      const total = this.crowdUnclaimed + this.totalUnclaimedUser;
      if (total > 0) this.bonusIndex += fee / 3 / total;
      this.day(this.today).pot += fee / 3;
      this.totalBurned += fee / 3;
    }

    const jackpot = deal.indexOf(6);
    if (userBatches.length > 0 || Math.random() < 0.3) {
      this.push({
        kind: "epoch",
        machine: jackpot as MachineId,
        text: `Epoch ${e} · ${MACHINES[jackpot].name} hit the 60% Share · ${ep.survivors[jackpot]} survivors split ${Math.round((pool * 6) / 10).toLocaleString()}`,
      });
    }
  }

  private harvest(d: number) {
    const day = this.day(d);
    if (day.finalized) return;
    if (day.fails === 0) this.day(d + 1).pot += day.pot;
    else day.perFail = day.pot / day.fails;
    day.finalized = true;
    day.bonusIndex = this.bonusIndex;
    let userWinnings = 0;
    for (const b of this.batches.filter((b) => Math.floor(b.epoch / EPOCHS_PER_DAY) === d)) {
      b.bonusIndexAt = this.bonusIndex;
      userWinnings += this.winnings(b);
    }
    this.totalUnclaimedUser += userWinnings;
    const crowdFails = day.fails - this.batches.filter((b) => Math.floor(b.epoch / EPOCHS_PER_DAY) === d).reduce((a, b) => a + b.energies - b.survivors, 0);
    this.crowdUnclaimed += crowdFails * day.perFail;
    this.push({
      kind: "harvest",
      text: `Harvest day ${d} · ${Math.round(day.pot).toLocaleString()} GAMMA split across ${day.fails.toLocaleString()} failed energies`,
    });
  }

  private winnings(b: SimBatch): number {
    const ep = this.epochs.get(b.epoch);
    const day = this.days.get(Math.floor(b.epoch / EPOCHS_PER_DAY));
    if (!ep || !day?.finalized) return 0;
    return b.survivors * ep.pps[b.machine] + (b.energies - b.survivors) * day.perFail;
  }

  buy(machine: MachineId, energies: number) {
    const cost = energies * ENERGY_COST * this.price * 1.0125;
    if (cost > this.imd) throw new Error("Not enough demo IMD");
    const e = Math.floor((this.now - this.genesis) / EPOCH_SECONDS);
    this.imd -= cost;
    this.totalBurned += energies * ENERGY_COST;
    this.totalEnergies += energies;
    this.price *= 1 + (energies * ENERGY_COST) / 400_000_000;
    const ep = this.epoch(e);
    ep.energies[machine] += energies;
    this.batches.unshift({
      id: this.batches.length,
      machine,
      epoch: e,
      energies,
      survivors: 0,
      drawn: false,
      claimed: false,
      bonusIndexAt: 0,
    });
    this.push({ kind: "buy", machine, text: `You burned ${(energies * ENERGY_COST).toLocaleString()} GAMMA for ${energies} energies on ${MACHINES[machine].name}` });
    this.emit();
  }

  claim(ids: number[], maturedOnly: boolean) {
    let paid = 0;
    let fees = 0;
    for (const id of ids) {
      const b = this.batches.find((x) => x.id === id);
      if (!b || b.claimed) continue;
      const d = Math.floor(b.epoch / EPOCHS_PER_DAY);
      const day = this.days.get(d);
      if (!day?.finalized) continue;
      const feeBps = claimFeeBps(this.now - (this.genesis + (d + 1) * DAY_SECONDS));
      if (maturedOnly && feeBps > 1_000) continue;
      const w = this.winnings(b);
      const bonus = w * (this.bonusIndex - b.bonusIndexAt);
      const fee = (w * feeBps) / 10_000;
      this.totalUnclaimedUser -= w;
      paid += w - fee + bonus;
      fees += fee;
      b.claimed = true;
    }
    if (paid === 0) throw new Error("Nothing ready to claim yet");
    this.gamma += paid;
    this.totalBurned += fees / 3;
    this.day(this.today).pot += fees / 3;
    this.push({ kind: "claim", text: `You claimed ${Math.round(paid).toLocaleString()} GAMMA · ${Math.round(fees).toLocaleString()} in fees (⅓ burned)` });
    this.emit();
  }

  view(): Omit<GameView, "busy" | "error" | "connected" | "address"> {
    const epoch = Math.floor((this.now - this.genesis) / EPOCH_SECONDS);
    const day = Math.floor(epoch / EPOCHS_PER_DAY);
    const cur = this.epoch(epoch);
    const lastEp = this.epochs.get(epoch - 1);
    const machines: MachineView[] = MACHINES.map((_, m) => ({
      energies: cur.energies[m],
      last: lastEp?.finalized
        ? {
            shareTenths: lastEp.shareTenths[m],
            survivors: lastEp.survivors[m],
            energies: lastEp.energies[m],
            payPerSurvivor: lastEp.pps[m],
          }
        : null,
    }));
    const batches: BatchView[] = this.batches.slice(0, 60).map((b) => {
      const d = Math.floor(b.epoch / EPOCHS_PER_DAY);
      const dd = this.days.get(d);
      const harvested = Boolean(dd?.finalized);
      const w = harvested ? this.winnings(b) : 0;
      return {
        id: b.id,
        machine: b.machine,
        epoch: b.epoch,
        energies: b.energies,
        survivors: b.survivors,
        drawn: b.drawn,
        claimed: b.claimed,
        harvested,
        winnings: w,
        bonus: harvested ? w * (this.bonusIndex - b.bonusIndexAt) : 0,
        feeBps: harvested ? claimFeeBps(this.now - (this.genesis + (d + 1) * DAY_SECONDS)) : 8_000,
      };
    });
    const today = this.day(day);
    return {
      mode: "demo",
      ready: true,
      now: this.now,
      genesis: this.genesis,
      epoch,
      day,
      epochEndsIn: this.genesis + (epoch + 1) * EPOCH_SECONDS - this.now,
      harvestIn: this.genesis + (day + 1) * DAY_SECONDS - this.now,
      tranche: tranche(epoch),
      machines,
      pot: today.pot,
      dayFails: today.fails,
      totalBurned: this.totalBurned,
      totalEnergies: this.totalEnergies,
      released: released(epoch),
      tradingFeeBps: 300,
      energyPriceImd: ENERGY_COST * this.price * 1.0125,
      imdBalance: this.imd,
      gammaBalance: this.gamma,
      batches,
      feed: this.feed,
      speed: this.speed,
    };
  }
}
