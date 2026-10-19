"use client";

import { useGame } from "./Providers";
import { LINKS, chain } from "@/lib/config";
import { short } from "@/lib/format";

/** A pixel bonsai: leaves, trunk and tray on an 8×8 grid. */
const LOGO = [
  "..GGGG..",
  ".GGLLGG.",
  "GG.TT.GG",
  "...TT...",
  "..TT....",
  "...TT...",
  ".BBBBBB.",
  "..BBBB..",
];
const LOGO_FILL: Record<string, string> = { G: "#3f8a67", L: "#7fbf98", T: "#a9432c", B: "#d1ae68" };

export function Logo({ size = 26 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 8 8" shapeRendering="crispEdges" aria-hidden>
      {LOGO.flatMap((row, y) =>
        [...row].map((ch, x) => (ch === "." ? null : <rect key={`${x}-${y}`} x={x} y={y} width="1" height="1" fill={LOGO_FILL[ch]} />)),
      )}
    </svg>
  );
}

export function Header() {
  const [g, a] = useGame();
  const live = g?.mode === "live";

  return (
    <header className="sticky top-0 z-40 border-b border-text/80 bg-bg/90 backdrop-blur-md">
      <div className="mx-auto flex h-16 max-w-7xl items-center justify-between gap-4 px-4 sm:px-6">
        <a href="#" className="flex items-center gap-2.5">
          <Logo />
          <span className="font-serif text-2xl tracking-tight">Gamma</span>
          <span
            className={`num hidden border px-2 py-0.5 text-[10px] tracking-widest sm:inline ${
              live ? "border-earth/40 text-earth" : "border-gamma/40 text-gamma"
            }`}
          >
            {live ? `LIVE · ${chain.name.toUpperCase()}` : "DEMO · SIMULATED"}
          </span>
        </a>
        <nav className="hidden items-center gap-7 text-[15px] text-text/85 md:flex">
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
      <div className="border-t border-line">
        <div className="mx-auto flex max-w-7xl items-center justify-between gap-4 px-4 py-2.5 text-sm text-muted sm:px-6">
          <span className="hidden sm:inline">A token you can only mine by playing</span>
          <span className="truncate">Robinhood Chain · paired with IMD · no team, no admin</span>
          <a href="#play" className="hidden border-b border-text/60 text-text hover:border-gamma hover:text-gamma md:inline">
            Start mining →
          </a>
        </div>
      </div>
    </header>
  );
}
