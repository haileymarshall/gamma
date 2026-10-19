"use client";

import { useGame } from "./Providers";
import { LINKS, chain } from "@/lib/config";
import { short } from "@/lib/format";

export function Logo({ size = 32 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 40 40" aria-hidden>
      <defs>
        <radialGradient id="lg" cx="50%" cy="40%" r="60%">
          <stop offset="0%" stopColor="#f4ffb0" />
          <stop offset="60%" stopColor="#d8ff3e" />
          <stop offset="100%" stopColor="#6f8f00" />
        </radialGradient>
      </defs>
      <circle cx="20" cy="20" r="18" fill="none" stroke="url(#lg)" strokeWidth="1.5" opacity="0.5" />
      <circle cx="20" cy="20" r="12" fill="none" stroke="url(#lg)" strokeWidth="1" opacity="0.3" />
      <path
        d="M11 13c3 0 5 2 7 7l3 7m0 0c1 3 1 6-1 7m1-7c2-6 5-11 8-14"
        fill="none"
        stroke="url(#lg)"
        strokeWidth="2.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export function Header() {
  const [g, a] = useGame();
  const live = g?.mode === "live";

  return (
    <header className="sticky top-0 z-40 border-b border-line bg-bg/70 backdrop-blur-xl">
      <div className="mx-auto flex max-w-7xl items-center justify-between gap-4 px-4 py-3 sm:px-6">
        <a href="#" className="flex items-center gap-2.5">
          <Logo />
          <span className="text-lg font-bold tracking-[0.2em]">GAMMA</span>
          <span
            className={`hidden rounded-full border px-2 py-0.5 text-[10px] font-semibold tracking-widest sm:inline ${
              live ? "border-earth/40 text-earth" : "border-gamma/40 text-gamma"
            }`}
          >
            {live ? `LIVE · ${chain.name.toUpperCase()}` : "DEMO · SIMULATED"}
          </span>
        </a>
        <nav className="hidden items-center gap-6 text-sm text-muted md:flex">
          <a href="#play" className="hover:text-text">
            Play
          </a>
          <a href="#how" className="hover:text-text">
            How it works
          </a>
          <a href="#economy" className="hover:text-text">
            Economy
          </a>
          <a href="#imd" className="hover:text-text">
            IMD
          </a>
        </nav>
        <div className="flex items-center gap-2">
          {live ? (
            g?.connected ? (
              <button className="btn btn-ghost num !py-2 text-sm" onClick={a.disconnect} title="Disconnect">
                <span className="h-2 w-2 rounded-full bg-earth" />
                {short(g.address)}
              </button>
            ) : (
              <button className="btn btn-primary !py-2 text-sm" onClick={a.connect}>
                Connect wallet
              </button>
            )
          ) : (
            <a className="btn btn-ghost !py-2 text-sm" href={LINKS.hackathon} target="_blank" rel="noreferrer">
              IMD Hackathon ↗
            </a>
          )}
        </div>
      </div>
    </header>
  );
}
