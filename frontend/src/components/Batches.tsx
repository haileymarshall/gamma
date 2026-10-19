"use client";

import { useGame } from "./Providers";
import { MACHINES } from "@/lib/gamma";
import { fmt, pct } from "@/lib/format";

export function Batches() {
  const [g, a] = useGame();
  if (!g) return null;

  const ready = g.batches.filter((b) => b.harvested && !b.claimed);
  const matured = ready.filter((b) => b.feeBps <= 1_000);
  const totalNet = ready.reduce((s, b) => s + b.winnings * (1 - b.feeBps / 10_000) + b.bonus, 0);
  const totalBonus = ready.reduce((s, b) => s + b.bonus, 0);

  return (
    <div className="panel p-5 sm:p-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <div className="label">Your batches</div>
          <div className="num mt-1 text-sm text-muted">
            {g.gammaBalance > 0 && <>Wallet: {fmt(g.gammaBalance, 2)} GAMMA · </>}
            Claimable now: <span className="text-text">{fmt(totalNet, 2)} GAMMA</span>
            {totalBonus > 0 && <span className="text-earth"> (incl. {fmt(totalBonus, 2)} bonus)</span>}
          </div>
        </div>
        <div className="flex gap-2">
          <button
            className="btn btn-ghost !py-2 text-sm"
            disabled={matured.length === 0 || Boolean(g.busy)}
            onClick={() => a.claim(matured.map((b) => b.id), true)}
            title="Only batches whose day matured: 10% fee"
          >
            Claim matured (10%)
          </button>
          <button
            className="btn btn-primary !py-2 text-sm"
            disabled={ready.length === 0 || Boolean(g.busy)}
            onClick={() => a.claim(ready.map((b) => b.id), false)}
          >
            Claim all
          </button>
        </div>
      </div>

      {g.batches.length === 0 ? (
        <div className="mt-6 rounded-xl border border-dashed border-line p-8 text-center text-sm text-dim">
          No batches yet. Place energies on a machine to start mining.
        </div>
      ) : (
        <div className="mt-5 overflow-x-auto">
          <table className="w-full min-w-[640px] text-sm">
            <thead>
              <tr className="label text-left">
                <th className="pb-2 font-normal">Machine</th>
                <th className="pb-2 font-normal">Epoch</th>
                <th className="pb-2 font-normal">Energies</th>
                <th className="pb-2 font-normal">Survived</th>
                <th className="pb-2 font-normal">Status</th>
                <th className="pb-2 text-right font-normal">Winnings</th>
                <th className="pb-2 text-right font-normal">Claim fee</th>
              </tr>
            </thead>
            <tbody className="num">
              {g.batches.map((b) => {
                const m = MACHINES[b.machine];
                const status = b.claimed
                  ? "Claimed"
                  : b.harvested
                    ? b.feeBps <= 1_000
                      ? "Matured"
                      : "Harvested"
                    : b.drawn
                      ? "Drawn · awaiting Harvest"
                      : "In play";
                return (
                  <tr key={b.id} className="border-t border-line">
                    <td className="py-2.5">
                      <span style={{ color: m.hex }}>
                        {m.glyph} {m.name}
                      </span>
                    </td>
                    <td className="py-2.5 text-muted">#{b.epoch}</td>
                    <td className="py-2.5">{b.energies}</td>
                    <td className="py-2.5">{b.drawn ? `${b.survivors} / ${b.energies}` : "…"}</td>
                    <td className="py-2.5">
                      <span
                        className={`rounded-md px-1.5 py-0.5 text-xs ${
                          b.claimed
                            ? "bg-white/5 text-dim"
                            : b.harvested
                              ? "bg-gamma/15 text-gamma"
                              : "bg-white/5 text-muted"
                        }`}
                      >
                        {status}
                      </span>
                    </td>
                    <td className="py-2.5 text-right">
                      {b.harvested ? fmt(b.winnings, 2) : "–"}
                      {b.bonus > 0 && !b.claimed && <span className="text-earth"> +{fmt(b.bonus, 2)}</span>}
                    </td>
                    <td className="py-2.5 text-right text-muted">{b.harvested && !b.claimed ? pct(b.feeBps) : "–"}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      <p className="mt-4 text-xs text-dim">
        Claiming is the only exit. The fee starts at 80% right after the Harvest and falls to 10% over 24 hours. A third
        is burned, a third goes to everyone who hasn&apos;t claimed yet (pro rata), a third to tonight&apos;s miners.
        Waiting is paid twice.
      </p>
    </div>
  );
}
