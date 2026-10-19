"use client";

import { useMemo, useState } from "react";
import { claimFeeBps, dailyEmission, tradingFeeBps } from "@/lib/gamma";
import { fmt } from "@/lib/format";

const ALLOCATION = [
  { label: "Reserve · mined by playing", value: 80, color: "var(--gamma)" },
  { label: "Pool · single-sided vs IMD", value: 10, color: "var(--water)" },
  { label: "IMD swarm · 8% to NFT seats, 2% to builders", value: 10, color: "var(--air)" },
  { label: "Team · presale · treasury", value: 0, color: "var(--danger)" },
];

function Donut() {
  const R = 70;
  const C = 2 * Math.PI * R;
  const slices = ALLOCATION.filter((a) => a.value > 0);
  const offsets = slices.map((_, i) => slices.slice(0, i).reduce((s, a) => s + (a.value / 100) * C, 0));
  return (
    <svg viewBox="0 0 200 200" className="h-48 w-48 -rotate-90">
      <circle cx="100" cy="100" r={R} fill="none" stroke="rgba(255,255,255,0.05)" strokeWidth="26" />
      {slices.map((a, i) => {
        const len = (a.value / 100) * C;
        return (
          <circle
            key={a.label}
            cx="100"
            cy="100"
            r={R}
            fill="none"
            stroke={a.color}
            strokeWidth="26"
            strokeDasharray={`${len - 2} ${C - len + 2}`}
            strokeDashoffset={-offsets[i]}
          />
        );
      })}
    </svg>
  );
}

type Pt = { x: number; y: number };

function LineChart({
  points,
  color,
  xLabel,
  yFmt,
  xTicks,
  hoverLabel,
  area = true,
}: {
  points: Pt[];
  color: string;
  xLabel: (x: number) => string;
  yFmt: (y: number) => string;
  xTicks: number[];
  hoverLabel: (p: Pt) => string;
  area?: boolean;
}) {
  const [hover, setHover] = useState<Pt | null>(null);
  const W = 520;
  const H = 200;
  const P = { l: 44, r: 10, t: 12, b: 26 };
  const xMax = points[points.length - 1].x;
  const yMax = Math.max(...points.map((p) => p.y)) * 1.08;
  const sx = (x: number) => P.l + (x / xMax) * (W - P.l - P.r);
  const sy = (y: number) => H - P.b - (y / yMax) * (H - P.t - P.b);
  const d = points.map((p, i) => `${i ? "L" : "M"}${sx(p.x).toFixed(1)},${sy(p.y).toFixed(1)}`).join("");
  const yTicks = [0, yMax / 2, yMax];

  return (
    <div className="relative">
      <svg
        viewBox={`0 0 ${W} ${H}`}
        className="w-full"
        onMouseMove={(e) => {
          const r = e.currentTarget.getBoundingClientRect();
          const x = (((e.clientX - r.left) / r.width) * W - P.l) / (W - P.l - P.r);
          const target = Math.max(0, Math.min(1, x)) * xMax;
          let best = points[0];
          for (const p of points) if (Math.abs(p.x - target) < Math.abs(best.x - target)) best = p;
          setHover(best);
        }}
        onMouseLeave={() => setHover(null)}
      >
        {yTicks.map((t) => (
          <g key={t}>
            <line x1={P.l} x2={W - P.r} y1={sy(t)} y2={sy(t)} stroke="rgba(255,255,255,0.06)" />
            <text x={P.l - 6} y={sy(t) + 3} textAnchor="end" fontSize="10" fill="var(--dim)" className="num">
              {yFmt(t)}
            </text>
          </g>
        ))}
        {xTicks.map((t) => (
          <text key={t} x={sx(t)} y={H - 8} textAnchor="middle" fontSize="10" fill="var(--dim)" className="num">
            {xLabel(t)}
          </text>
        ))}
        {area && <path d={`${d}L${sx(xMax)},${sy(0)}L${sx(0)},${sy(0)}Z`} fill={color} opacity="0.1" />}
        <path d={d} fill="none" stroke={color} strokeWidth="2" />
        {hover && (
          <g>
            <line x1={sx(hover.x)} x2={sx(hover.x)} y1={P.t} y2={H - P.b} stroke="rgba(255,255,255,0.2)" />
            <circle cx={sx(hover.x)} cy={sy(hover.y)} r="4" fill={color} />
          </g>
        )}
      </svg>
      {hover && (
        <div className="num pointer-events-none absolute right-2 top-0 rounded-md bg-black/70 px-2 py-1 text-xs">
          {hoverLabel(hover)}
        </div>
      )}
    </div>
  );
}

export function Economy() {
  const emission = useMemo(
    () => Array.from({ length: 6 * 365 / 7 }, (_, i) => ({ x: i * 7, y: dailyEmission(i * 7) })),
    [],
  );
  const claimCurve = useMemo(
    () => Array.from({ length: 49 }, (_, i) => ({ x: i * 0.5 * 3600, y: claimFeeBps(i * 0.5 * 3600) / 100 })),
    [],
  );
  const tradeCurve = useMemo(
    () => Array.from({ length: 121 }, (_, i) => ({ x: i, y: tradingFeeBps(i * 60) / 100 })),
    [],
  );

  return (
    <section id="economy" className="mx-auto max-w-7xl px-4 py-20 sm:px-6">
      <div className="label">Economy</div>
      <h2 className="mt-3 max-w-2xl text-3xl font-bold tracking-tight sm:text-5xl">
        1,000,000,000 GAMMA. Minted once. Supply only goes down.
      </h2>

      <div className="mt-10 grid gap-3 lg:grid-cols-3">
        <div className="panel p-6">
          <div className="label">Allocation</div>
          <div className="mt-4 flex justify-center">
            <Donut />
          </div>
          <ul className="mt-4 space-y-2 text-sm">
            {ALLOCATION.map((a) => (
              <li key={a.label} className="flex items-center justify-between gap-3">
                <span className="flex items-center gap-2 text-muted">
                  <span className="h-2.5 w-2.5 rounded-sm" style={{ background: a.color }} />
                  {a.label}
                </span>
                <span className="num font-semibold">{a.value}%</span>
              </li>
            ))}
          </ul>
        </div>

        <div className="panel p-6 lg:col-span-2">
          <div className="flex items-baseline justify-between">
            <div className="label">Reserve emission per day</div>
            <div className="num text-xs text-dim">year 1: 500M, halving every 120 days · then 300M forever</div>
          </div>
          <div className="mt-4">
            <LineChart
              points={emission}
              color="var(--gamma)"
              xTicks={[0, 365, 730, 1095, 1460, 1825]}
              xLabel={(x) => (x === 0 ? "launch" : `yr ${x / 365}`)}
              yFmt={(y) => fmt(y)}
              hoverLabel={(p) => `day ${p.x}: ${fmt(p.y)} GAMMA/day`}
            />
          </div>
          <div className="mt-4 grid grid-cols-3 gap-3 text-sm">
            <div>
              <div className="label">Day 0</div>
              <div className="num font-semibold">{fmt(dailyEmission(0))}/day</div>
            </div>
            <div>
              <div className="label">Day 364</div>
              <div className="num font-semibold">{fmt(dailyEmission(364))}/day</div>
            </div>
            <div>
              <div className="label">Tail half-life</div>
              <div className="num font-semibold">≈ 522 days</div>
            </div>
          </div>
        </div>

        <div className="panel p-6">
          <div className="label">Claim fee · time since Harvest</div>
          <div className="mt-4">
            <LineChart
              points={claimCurve}
              color="var(--earth)"
              area={false}
              xTicks={[0, 6 * 3600, 12 * 3600, 18 * 3600, 24 * 3600]}
              xLabel={(x) => `${x / 3600}h`}
              yFmt={(y) => `${y.toFixed(0)}%`}
              hoverLabel={(p) => `${(p.x / 3600).toFixed(1)}h: ${p.y.toFixed(1)}%`}
            />
          </div>
          <p className="mt-3 text-xs text-dim">⅓ burned · ⅓ to unclaimed winnings · ⅓ to tonight&apos;s Harvest</p>
        </div>

        <div className="panel p-6">
          <div className="label">Trading fee · minutes since launch</div>
          <div className="mt-4">
            <LineChart
              points={tradeCurve}
              color="var(--fire)"
              area={false}
              xTicks={[0, 30, 60, 96, 120]}
              xLabel={(x) => `${x}m`}
              yFmt={(y) => `${y.toFixed(0)}%`}
              hoverLabel={(p) => `minute ${p.x}: ${p.y}%`}
            />
          </div>
          <p className="mt-3 text-xs text-dim">Uniswap v4 hook · 100% to the Harvest · anti-sniper by design</p>
        </div>

        <div className="panel p-6">
          <div className="label">Supply sinks</div>
          <ul className="mt-4 space-y-3 text-sm">
            <li className="flex justify-between gap-3">
              <span className="text-muted">Every energy</span>
              <span className="num">1,000 GAMMA burned</span>
            </li>
            <li className="flex justify-between gap-3">
              <span className="text-muted">Every claim</span>
              <span className="num">⅓ of fee burned</span>
            </li>
            <li className="flex justify-between gap-3">
              <span className="text-muted">Mint function</span>
              <span className="num">none</span>
            </li>
            <li className="flex justify-between gap-3">
              <span className="text-muted">Admin keys</span>
              <span className="num">none</span>
            </li>
            <li className="flex justify-between gap-3">
              <span className="text-muted">Recycling of burned GAMMA</span>
              <span className="num">never</span>
            </li>
          </ul>
        </div>
      </div>
    </section>
  );
}
