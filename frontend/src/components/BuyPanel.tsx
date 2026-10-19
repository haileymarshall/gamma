"use client";

import { useState } from "react";
import { useGame } from "./Providers";
import { ENERGY_COST, MACHINES, MAX_BATCH, type MachineId } from "@/lib/gamma";
import { fmt } from "@/lib/format";

const PRESETS = [10, 50, 100, 250, 500];

export function BuyPanel({ machine }: { machine: MachineId }) {
  const [g, a] = useGame();
  const [energies, setEnergies] = useState(50);
  const m = MACHINES[machine];

  const burn = energies * ENERGY_COST;
  const cost = g ? energies * g.energyPriceImd : 0;
  const playing = g ? g.machines.reduce((s, x) => s + x.energies, 0) : 0;
  const onMachine = g?.machines[machine].energies ?? 0;
  // Expected Share per energy is the same on every machine: the tranche's 90% over everyone playing.
  const expShare = g ? (g.tranche * 0.9) / Math.max(1, playing + energies) : 0;
  const expFails = energies * m.fail;
  const canBuy = g && (g.mode === "demo" || g.connected) && !g.busy && cost <= g.imdBalance;

  return (
    <div className="panel p-5 sm:p-6" style={{ ["--accent" as string]: m.hex }}>
      <div className="flex items-center justify-between">
        <div className="label">Place energies</div>
        <div className="num text-xs text-muted">
          Balance {g ? fmt(g.imdBalance, 2) : "–"} IMD{g?.mode === "demo" && " (demo)"}
        </div>
      </div>

      <div className="mt-4 flex items-end justify-between">
        <div>
          <div className="font-serif text-6xl tabular-nums" style={{ color: m.hex }}>
            {energies}
          </div>
          <div className="text-sm text-muted">
            energies on <span style={{ color: m.hex }}>{m.name}</span>
          </div>
        </div>
        <div className="text-right">
          <div className="num text-2xl font-semibold">{fmt(cost, 2)} IMD</div>
          <div className="num text-xs text-dim">burns {fmt(burn)} GAMMA</div>
        </div>
      </div>

      <input
        type="range"
        min={1}
        max={MAX_BATCH}
        value={energies}
        onChange={(e) => setEnergies(Number(e.target.value))}
        className="mt-5"
        style={{ ["--fill" as string]: `${((energies - 1) / (MAX_BATCH - 1)) * 100}%` }}
        aria-label="Energies"
      />
      <div className="mt-3 flex gap-1.5">
        {PRESETS.map((p) => (
          <button
            key={p}
            onClick={() => setEnergies(p)}
            className={`num flex-1 rounded-lg py-1.5 text-xs ${
              energies === p ? "text-bg" : "bg-white/5 text-muted hover:text-text"
            }`}
            style={energies === p ? { background: m.hex } : undefined}
          >
            {p}
          </button>
        ))}
      </div>

      <div className="mt-5 grid grid-cols-3 gap-2 text-xs">
        <div className="rounded-xl border border-line p-2.5">
          <div className="text-dim">Expected survivors</div>
          <div className="num mt-0.5 text-sm font-semibold">{Math.round(energies * (1 - m.fail))}</div>
        </div>
        <div className="rounded-xl border border-line p-2.5">
          <div className="text-dim">Expected fails</div>
          <div className="num mt-0.5 text-sm font-semibold">{Math.round(expFails)}</div>
        </div>
        <div className="rounded-xl border border-line p-2.5">
          <div className="text-dim">Avg Share / energy</div>
          <div className="num mt-0.5 text-sm font-semibold">{fmt(expShare, 1)}</div>
        </div>
      </div>
      <p className="mt-3 text-xs leading-relaxed text-dim">
        {onMachine.toLocaleString()} energies already on {m.name} this epoch. Every machine pays the same average
        Share; riskier machines earn more of tonight&apos;s Harvest. The crowd decides the margin.
      </p>

      {g?.mode === "live" && !g.connected ? (
        <button className="btn btn-primary mt-5 w-full" onClick={a.connect}>
          Connect wallet to mine
        </button>
      ) : (
        <button
          className="btn btn-primary mt-5 w-full text-base"
          disabled={!canBuy}
          onClick={() => a.buy(machine, energies)}
          style={{ background: m.hex, boxShadow: "4px 4px 0 var(--text)" }}
        >
          {g?.busy ? `${g.busy}…` : cost > (g?.imdBalance ?? 0) ? "Not enough IMD" : `Burn & mine on ${m.name}`}
        </button>
      )}
      {g?.error && (
        <button onClick={a.clearError} className="mt-3 w-full rounded-lg bg-danger/10 px-3 py-2 text-left text-xs text-danger">
          {g.error} <span className="text-dim">(dismiss)</span>
        </button>
      )}
    </div>
  );
}
