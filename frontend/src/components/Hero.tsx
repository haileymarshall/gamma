"use client";

import { motion } from "motion/react";
import { useGame } from "./Providers";
import { fmt } from "@/lib/format";
import { RESERVE } from "@/lib/gamma";

export function Hero() {
  const [g] = useGame();

  const stats = [
    { label: "Mined so far", value: g ? fmt(g.released) : "–", unit: "GAMMA" },
    { label: "Burned by miners", value: g ? fmt(g.totalBurned) : "–", unit: "GAMMA" },
    { label: "Left in the Reserve", value: g ? fmt(RESERVE - g.released) : "–", unit: "GAMMA" },
    { label: "Energies played", value: g ? fmt(g.totalEnergies) : "–", unit: "" },
  ];

  return (
    <section className="relative mx-auto max-w-7xl px-4 pb-10 pt-14 sm:px-6 sm:pt-20">
      <motion.div
        initial={{ opacity: 0, y: 16 }}
        animate={{ opacity: 1, y: 0 }}
        transition={{ duration: 0.6 }}
        className="max-w-3xl"
      >
        <div className="label mb-5 flex items-center gap-2">
          <span className="pulse h-1.5 w-1.5 rounded-full bg-gamma" /> Proof-of-play mining on IMD
        </div>
        <h1 className="text-5xl font-bold leading-[0.95] tracking-tight sm:text-7xl">
          Mine it.
          <br />
          <span className="glow-text text-gamma">Don&apos;t buy it.</span>
        </h1>
        <p className="mt-6 max-w-xl text-lg leading-relaxed text-muted">
          GAMMA is a token you can only earn by playing. Burn GAMMA for energies, place them on one of four machines,
          and every 10 minutes a fixed reward is split among the miners. Survivors split the Shares. Failures split
          the evening Harvest.
        </p>
        <div className="mt-8 flex flex-wrap gap-3">
          <a href="#play" className="btn btn-primary">
            Start mining →
          </a>
          <a href="#how" className="btn btn-ghost">
            How it works
          </a>
        </div>
        <div className="mt-6 flex flex-wrap gap-x-5 gap-y-2 text-sm text-muted">
          <span>✓ 0% team, no presale</span>
          <span>✓ No admin keys</span>
          <span>✓ drand randomness, verified on-chain</span>
          <span>✓ Every play buys with IMD</span>
        </div>
      </motion.div>

      <div className="mt-12 grid grid-cols-2 gap-3 lg:grid-cols-4">
        {stats.map((s, i) => (
          <motion.div
            key={s.label}
            initial={{ opacity: 0, y: 12 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: 0.1 + i * 0.06 }}
            className="panel p-4 sm:p-5"
          >
            <div className="label">{s.label}</div>
            <div className="num mt-2 text-2xl font-semibold sm:text-3xl">
              {s.value} <span className="text-sm text-dim">{s.unit}</span>
            </div>
          </motion.div>
        ))}
      </div>
    </section>
  );
}
