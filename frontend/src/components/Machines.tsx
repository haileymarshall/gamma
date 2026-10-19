"use client";

import { motion } from "motion/react";
import { useGame } from "./Providers";
import { MACHINES, type MachineId } from "@/lib/gamma";
import { fmt } from "@/lib/format";
import { MACHINE_SCENE } from "@/lib/voxel";
import { VoxelCanvas } from "./VoxelCanvas";

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
            className="panel relative overflow-hidden text-left transition-colors"
            style={{
              borderColor: active ? m.hex : undefined,
              boxShadow: active ? `4px 4px 0 ${m.hex}` : undefined,
            }}
            aria-pressed={active}
          >
            <div className="relative h-36 border-b border-line bg-bg-2">
              <VoxelCanvas scene={MACHINE_SCENE[m.id]} spin={0.3} className="h-full w-full" label={`${m.name} machine`} />
              {active && <span className="num absolute left-3 top-3 text-[10px] tracking-widest" style={{ color: m.hex }}>SELECTED</span>}
            </div>
            <div className="p-4">
            <div className="relative flex items-start justify-between">
              <div>
                <div className="flex items-center gap-2">
                  <span className="font-serif text-2xl">{m.name}</span>
                </div>
                <div className="label mt-1" style={{ color: m.hex }}>
                  {m.profile}
                </div>
              </div>
              <div className="text-right">
                <div className="num text-2xl font-medium" style={{ color: m.hex }}>
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
                      background: mv.last.shareTenths === 6 ? m.hex : "rgba(236,230,214,0.06)",
                      color: mv.last.shareTenths === 6 ? "var(--bg)" : "var(--muted)",
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
            </div>
          </motion.button>
        );
      })}
    </div>
  );
}
