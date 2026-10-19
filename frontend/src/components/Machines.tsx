"use client";

import { motion } from "motion/react";
import { useMemo } from "react";
import { useGame } from "./Providers";
import { MACHINES, type MachineId } from "@/lib/gamma";
import { fmt } from "@/lib/format";

function Particles({ color, rate }: { color: string; rate: number }) {
  const dots = useMemo(
    () =>
      Array.from({ length: 14 }, (_, i) => ({
        left: `${(i * 37) % 100}%`,
        delay: `${(i * 0.73) % 4}s`,
        dur: `${2.4 + ((i * 1.3) % 2.6)}s`,
      })),
    [],
  );
  return (
    <div className="pointer-events-none absolute inset-x-0 bottom-0 h-40 overflow-hidden" aria-hidden>
      {dots.slice(0, Math.max(3, Math.round(rate * 14))).map((d, i) => (
        <span
          key={i}
          className="particle"
          style={{ left: d.left, animationDelay: d.delay, animationDuration: d.dur, background: color, boxShadow: `0 0 8px ${color}` }}
        />
      ))}
    </div>
  );
}

export function Machines({ selected, onSelect }: { selected: MachineId; onSelect: (m: MachineId) => void }) {
  const [g] = useGame();
  const total = g ? g.machines.reduce((s, m) => s + m.energies, 0) || 1 : 1;

  return (
    <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
      {MACHINES.map((m) => {
        const mv = g?.machines[m.id];
        const active = selected === m.id;
        const share = (mv?.energies ?? 0) / total;
        return (
          <motion.button
            key={m.id}
            onClick={() => onSelect(m.id as MachineId)}
            whileHover={{ y: -2 }}
            whileTap={{ scale: 0.98 }}
            className="panel scan relative overflow-hidden p-4 text-left transition-colors"
            style={{
              borderColor: active ? m.hex : undefined,
              boxShadow: active ? `0 0 0 1px ${m.hex}, 0 20px 60px -20px ${m.hex}` : undefined,
            }}
            aria-pressed={active}
          >
            <Particles color={m.hex} rate={m.fail} />
            <div className="relative flex items-start justify-between">
              <div>
                <div className="flex items-center gap-2">
                  <span className="text-xl" style={{ color: m.hex }}>
                    {m.glyph}
                  </span>
                  <span className="text-lg font-bold">{m.name}</span>
                </div>
                <div className="label mt-1" style={{ color: m.hex }}>
                  {m.profile}
                </div>
              </div>
              <div className="text-right">
                <div className="num text-2xl font-bold" style={{ color: m.hex }}>
                  {Math.round(m.fail * 100)}%
                </div>
                <div className="label">fail rate</div>
              </div>
            </div>

            <div className="relative mt-4">
              <div className="flex justify-between text-xs text-muted">
                <span>This epoch</span>
                <span className="num">{(mv?.energies ?? 0).toLocaleString()} energies</span>
              </div>
              <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-white/5">
                <motion.div
                  className="h-full rounded-full"
                  style={{ background: m.hex }}
                  animate={{ width: `${Math.max(2, share * 100)}%` }}
                  transition={{ type: "spring", stiffness: 80, damping: 20 }}
                />
              </div>
            </div>

            <div className="relative mt-3 min-h-[38px] text-xs">
              {mv?.last ? (
                <div className="flex items-center justify-between">
                  <span
                    className="num rounded-md px-1.5 py-0.5 font-semibold"
                    style={{
                      background: mv.last.shareTenths === 6 ? m.hex : "rgba(255,255,255,0.06)",
                      color: mv.last.shareTenths === 6 ? "#000" : "var(--muted)",
                    }}
                  >
                    last: {mv.last.shareTenths * 10}% share
                  </span>
                  <span className="num text-muted">
                    {mv.last.survivors}/{mv.last.energies} survived
                    {mv.last.payPerSurvivor > 0 && <> · {fmt(mv.last.payPerSurvivor, 1)} each</>}
                  </span>
                </div>
              ) : (
                <span className="text-dim">{m.blurb}</span>
              )}
            </div>
          </motion.button>
        );
      })}
    </div>
  );
}
