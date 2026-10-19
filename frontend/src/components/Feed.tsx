"use client";

import { AnimatePresence, motion } from "motion/react";
import { useGame } from "./Providers";
import { MACHINES } from "@/lib/gamma";

const KIND_COLOR: Record<string, string> = {
  buy: "var(--gamma)",
  epoch: "var(--water)",
  harvest: "var(--air)",
  claim: "var(--earth)",
  trade: "var(--muted)",
};

export function Feed() {
  const [g, a] = useGame();
  const items = g?.feed ?? [];

  return (
    <div className="panel flex h-full flex-col p-5 sm:p-6">
      <div className="flex items-center justify-between">
        <div className="label flex items-center gap-2">
          <span className="pulse h-1.5 w-1.5 rounded-full bg-earth" /> Live activity
        </div>
        {g?.mode === "live" && (
          <button className="text-xs text-muted hover:text-text" onClick={a.settle} disabled={Boolean(g.busy)}>
            Settle now ↻
          </button>
        )}
      </div>
      <div className="mt-4 flex-1 space-y-2 overflow-hidden">
        {items.length === 0 && <div className="text-sm text-dim">Waiting for the next event…</div>}
        <AnimatePresence initial={false}>
          {items.slice(0, 9).map((f) => (
            <motion.div
              key={f.id}
              layout
              initial={{ opacity: 0, x: -10 }}
              animate={{ opacity: 1, x: 0 }}
              exit={{ opacity: 0 }}
              className="flex gap-2.5 text-[13px] leading-snug"
            >
              <span
                className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full"
                style={{ background: f.machine !== undefined ? MACHINES[f.machine].hex : KIND_COLOR[f.kind] }}
              />
              <span className="text-muted">{f.text}</span>
            </motion.div>
          ))}
        </AnimatePresence>
      </div>
    </div>
  );
}
