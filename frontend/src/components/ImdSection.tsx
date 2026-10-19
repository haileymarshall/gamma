import { ADDRESSES, LINKS, LIVE } from "@/lib/config";

const POINTS = [
  {
    t: "Every play is an IMD buy",
    b: "Energies are paid in IMD. It goes into the GAMMA/IMD pool and stays there: steady, game-driven demand for IMD.",
  },
  {
    t: "Launched by the swarm",
    b: "Hook, token and pool deployed through explorer.imd.fun/launch on Robinhood Chain. 10% of supply goes to the IMD swarm: 8% to NFT seats, 2% to the agents that built it.",
  },
  {
    t: "A real v4 hook",
    b: "Decaying launch fee (99% → 3%) taken through Uniswap v4 return deltas and routed on-chain to the miners. The game's own swaps are exempt.",
  },
  {
    t: "Audited by IMD agents",
    b: "Code imported through IMD's audit-imported-code and audit panel before deployment, plus 50+ Foundry unit, fuzz and invariant tests.",
  },
  {
    t: "Unbiasable randomness",
    b: "Each epoch is seeded by a future drand round. Its BLS signature is verified on-chain (BN254), so no player, sequencer or deployer can bias a draw.",
  },
  {
    t: "Nothing to rug",
    b: "No owner, no mint, no withdraw. The configurator can wire the pool once and has no power after that.",
  },
];

export function ImdSection() {
  return (
    <section id="imd" className="mx-auto max-w-7xl px-4 py-20 sm:px-6">
      <div className="label">Built on IMD</div>
      <h2 className="mt-3 max-w-3xl text-4xl sm:text-6xl">
        A game that makes the swarm&apos;s token <em>more useful every 10 minutes.</em>
      </h2>
      <div className="mt-10 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {POINTS.map((p) => (
          <div key={p.t} className="panel p-6">
            <div className="text-lg font-semibold">{p.t}</div>
            <p className="mt-2 text-sm leading-relaxed text-muted">{p.b}</p>
          </div>
        ))}
      </div>

      <div className="panel mt-6 grid gap-4 p-6 text-sm sm:grid-cols-2 lg:grid-cols-4">
        {[
          ["Game", ADDRESSES.game],
          ["GAMMA", ADDRESSES.gamma],
          ["Hook", ADDRESSES.hook],
          ["IMD", ADDRESSES.imd],
        ].map(([k, v]) => (
          <div key={k}>
            <div className="label">{k}</div>
            {v ? (
              <a
                href={`${LINKS.explorer}/address/${v}`}
                target="_blank"
                rel="noreferrer"
                className="num mt-1 block truncate text-muted hover:text-gamma"
              >
                {v}
              </a>
            ) : (
              <div className="num mt-1 text-dim">{LIVE ? "–" : "launching on Robinhood Chain"}</div>
            )}
          </div>
        ))}
      </div>
    </section>
  );
}
