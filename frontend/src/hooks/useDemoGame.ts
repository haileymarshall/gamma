"use client";

import { useCallback, useEffect, useState } from "react";
import { GammaSim } from "@/lib/sim";
import type { GameActions, GameView } from "@/lib/types";
import type { MachineId } from "@/lib/gamma";

let shared: GammaSim | null = null;
const getSim = () => (shared ??= new GammaSim());

type SimView = ReturnType<GammaSim["view"]>;

export function useDemoGame(): [GameView | null, GameActions] {
  const [view, setView] = useState<SimView | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  useEffect(() => {
    const sim = getSim();
    const unsub = sim.subscribe(() => setView(sim.view()));
    const id = setInterval(() => sim.tick(), 250);
    return () => {
      clearInterval(id);
      unsub();
    };
  }, []);

  const run = useCallback(async (label: string, fn: () => void) => {
    setBusy(label);
    setError(null);
    await new Promise((r) => setTimeout(r, 450));
    try {
      fn();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(null);
    }
  }, []);

  const actions: GameActions = {
    buy: (machine: MachineId, energies: number) => run("Burning GAMMA", () => getSim().buy(machine, energies)),
    claim: (ids: number[], matured: boolean) => run("Claiming", () => getSim().claim(ids, matured)),
    settle: async () => {},
    setSpeed: (s: number) => {
      const sim = getSim();
      sim.speed = s;
      setView(sim.view());
    },
    connect: () => {},
    disconnect: () => {},
    clearError: () => setError(null),
  };

  if (!view) return [null, actions];
  return [{ ...view, busy, error, connected: true, address: "demo" }, actions];
}
