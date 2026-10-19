"use client";

import { useGame } from "./Providers";
import { clock, fmt } from "@/lib/format";
import { EPOCH_SECONDS, DAY_SECONDS, ENERGY_COST } from "@/lib/gamma";

/** The epoch clock: a ring that fills every 10 minutes, and the day ring around it that ends in the Harvest. */
export function Reactor() {
  const [g, a] = useGame();
  if (!g) return <div className="panel h-[420px] animate-pulse" />;

  const epochFrac = 1 - g.epochEndsIn / EPOCH_SECONDS;
  const dayFrac = 1 - g.harvestIn / DAY_SECONDS;
  const R1 = 120;
  const R2 = 142;
  const c1 = 2 * Math.PI * R1;
  const c2 = 2 * Math.PI * R2;
  const playing = g.machines.reduce((s, m) => s + m.energies, 0);
  const breakEven = g.tranche / ENERGY_COST;
  const profitable = playing < breakEven;

  return (
    <div className="panel relative overflow-hidden p-5 sm:p-6">
      <div className="flex items-start justify-between">
        <div>
          <div className="label">Epoch</div>
          <div className="num text-2xl font-semibold">#{g.epoch.toLocaleString()}</div>
        </div>
        <div className="text-right">
          <div className="label">Day {g.day}</div>
          <div className="num text-sm text-muted">Harvest in {clock(g.harvestIn)}</div>
        </div>
      </div>

      <div className="relative mx-auto my-2 aspect-square w-full max-w-[320px]">
        <svg viewBox="0 0 320 320" className="h-full w-full -rotate-90">
          <circle cx="160" cy="160" r={R2} fill="none" stroke="rgba(236,230,214,0.07)" strokeWidth="4" />
          <circle
            cx="160"
            cy="160"
            r={R2}
            fill="none"
            stroke="var(--brass)"
            strokeWidth="4"
            strokeLinecap="round"
            strokeDasharray={c2}
            strokeDashoffset={c2 * (1 - dayFrac)}
            opacity="0.7"
          />
          <circle cx="160" cy="160" r={R1} fill="none" stroke="rgba(236,230,214,0.07)" strokeWidth="14" />
          <circle
            cx="160"
            cy="160"
            r={R1}
            fill="none"
            stroke="url(#ring)"
            strokeWidth="14"
            strokeLinecap="butt"
            strokeDasharray={c1}
            strokeDashoffset={c1 * (1 - epochFrac)}
            style={{ transition: "stroke-dashoffset 0.25s linear" }}
          />
          <defs>
            <linearGradient id="ring" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0%" stopColor="#c4f0d7" />
              <stop offset="100%" stopColor="#3f8a67" />
            </linearGradient>
          </defs>
        </svg>
        <div className="absolute inset-0 flex flex-col items-center justify-center text-center">
          <div className="label">Next draw in</div>
          <div className="mt-1 font-serif text-6xl text-gamma tabular-nums">{clock(g.epochEndsIn)}</div>
          <div className="mt-3 label">This epoch pays</div>
          <div className="num text-xl font-semibold">
            {fmt(g.tranche)} <span className="text-xs text-dim">GAMMA</span>
          </div>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-3 text-sm">
        <div className="rounded-xl border border-line bg-white/[0.02] p-3">
          <div className="label">Energies in play</div>
          <div className="num mt-1 text-lg font-semibold">{playing.toLocaleString()}</div>
        </div>
        <div className="rounded-xl border border-line bg-white/[0.02] p-3">
          <div className="label">Break-even</div>
          <div className="num mt-1 text-lg font-semibold">{breakEven.toFixed(1)}</div>
        </div>
      </div>
      <div
        className={`mt-3 rounded-xl border px-3 py-2 text-xs ${
          profitable ? "border-earth/30 bg-earth/5 text-earth" : "border-fire/30 bg-fire/5 text-fire"
        }`}
      >
        {profitable
          ? "Fewer energies than break-even: on average, mining pays out more than it burns right now."
          : "More energies than break-even: on average, miners burn more than they win. Supply shrinks."}
      </div>

      {g.mode === "demo" && (
        <div className="mt-4 flex items-center justify-between gap-2">
          <span className="label">Demo speed</span>
          <div className="flex gap-1">
            {[1, 60, 300, 1200].map((s) => (
              <button
                key={s}
                onClick={() => a.setSpeed(s)}
                className={`num rounded-lg px-2.5 py-1 text-xs ${
                  g.speed === s ? "bg-text text-bg" : "bg-white/5 text-muted hover:text-text"
                }`}
              >
                {s}×
              </button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
