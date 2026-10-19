"use client";

import { useGame } from "./Providers";
import { clock, fmt } from "@/lib/format";
import { DAY_SECONDS } from "@/lib/gamma";

export function Harvest() {
  const [g] = useGame();
  if (!g) return <div className="panel h-48 animate-pulse" />;
  const frac = 1 - g.harvestIn / DAY_SECONDS;
  const perFail = g.dayFails > 0 ? g.pot / g.dayFails : 0;

  return (
    <div className="panel relative overflow-hidden p-5 sm:p-6">
      <div
        className="pointer-events-none absolute inset-x-0 bottom-0 transition-all"
        style={{
          height: `${Math.max(6, frac * 100)}%`,
          background: "linear-gradient(to top, rgba(209,174,104,0.16), rgba(209,174,104,0.01))",
        }}
        aria-hidden
      />
      <div className="relative">
        <div className="flex items-center justify-between">
          <div className="label">Tonight&apos;s Harvest</div>
          <div className="num rounded-full border border-brass/40 px-2 py-0.5 text-xs text-brass">
            in {clock(g.harvestIn)}
          </div>
        </div>
        <div className="mt-3 font-serif text-5xl text-brass tabular-nums">
          {fmt(g.pot)} <span className="text-base text-dim">GAMMA</span>
        </div>
        <div className="mt-1 text-sm text-muted">
          Split equally among every energy that fails today, on any machine.
        </div>
        <div className="mt-4 grid grid-cols-2 gap-3 text-sm">
          <div>
            <div className="label">Fails so far</div>
            <div className="num text-lg font-semibold">{g.dayFails.toLocaleString()}</div>
          </div>
          <div>
            <div className="label">Per fail (now)</div>
            <div className="num text-lg font-semibold">{perFail ? fmt(perFail, 2) : "–"}</div>
          </div>
        </div>
        <div className="mt-4 text-xs text-dim">
          Fed by 10% of every tranche, 100% of trading fees ({(g.tradingFeeBps / 100).toFixed(0)}% now), ⅓ of every
          claim fee and any Share with no survivor.
        </div>
      </div>
    </div>
  );
}
