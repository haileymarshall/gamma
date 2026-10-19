"use client";

import { useState } from "react";
import { Header } from "@/components/Header";
import { Hero } from "@/components/Hero";
import { Reactor } from "@/components/Reactor";
import { Machines } from "@/components/Machines";
import { BuyPanel } from "@/components/BuyPanel";
import { Harvest } from "@/components/Harvest";
import { Batches } from "@/components/Batches";
import { Feed } from "@/components/Feed";
import { HowItWorks } from "@/components/HowItWorks";
import { Economy } from "@/components/Economy";
import { ImdSection } from "@/components/ImdSection";
import { Footer } from "@/components/Footer";
import { useGame } from "@/components/Providers";
import type { MachineId } from "@/lib/gamma";

export default function Home() {
  const [machine, setMachine] = useState<MachineId>(3);
  const [g] = useGame();

  return (
    <>
      <Header />
      <main>
        <Hero />
        <section id="play" className="mx-auto max-w-7xl scroll-mt-20 px-4 py-10 sm:px-6">
          {g?.mode === "demo" && (
            <div className="mb-4 rounded-xl border border-gamma/30 bg-gamma/5 px-4 py-3 text-sm text-gamma">
              Demo mode: the real game rules running against a simulated crowd with demo IMD. Speed up time on the clock
              to watch a full day and its Harvest.
            </div>
          )}
          <div className="grid gap-3 lg:grid-cols-12">
            <div className="lg:col-span-4">
              <Reactor />
            </div>
            <div className="lg:col-span-8">
              <Machines selected={machine} onSelect={setMachine} />
            </div>
            <div className="lg:col-span-5">
              <BuyPanel machine={machine} />
            </div>
            <div className="flex flex-col gap-3 lg:col-span-3">
              <Harvest />
            </div>
            <div className="lg:col-span-4">
              <Feed />
            </div>
            <div className="lg:col-span-12">
              <Batches />
            </div>
          </div>
        </section>
        <HowItWorks />
        <Economy />
        <ImdSection />
      </main>
      <Footer />
    </>
  );
}
