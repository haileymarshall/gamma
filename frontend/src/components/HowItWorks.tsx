const STEPS = [
  {
    n: "01",
    title: "Burn for energies",
    body: "One energy = 1,000 GAMMA bought with IMD on the pool and burned. 100% of what you pay buys GAMMA; the game keeps nothing.",
  },
  {
    n: "02",
    title: "Pick a machine",
    body: "Earth, Water, Fire, Air. Each energy fails independently at 10%, 30%, 60% or 90%. Risk is the only difference.",
  },
  {
    n: "03",
    title: "Every 10 minutes",
    body: "The Reserve releases a fixed tranche. 90% is dealt 60/20/20/0 to the machines at random; survivors split their machine's Share.",
  },
  {
    n: "04",
    title: "Every evening",
    body: "The Harvest pot (10% of tranches, all trading fees, ⅓ of claim fees) is split equally among every energy that failed that day.",
  },
  {
    n: "05",
    title: "Claim when ready",
    body: "Claiming is the only exit. The fee falls from 80% to 10% over 24 hours, and a third of it pays the people still waiting.",
  },
];

const IDEAS = [
  {
    t: "The crowd is the difficulty",
    b: "No difficulty algorithm. When mining pays, miners arrive and burn supply until the margin is gone. When it doesn't, they leave.",
  },
  {
    t: "Risk is priced, not punished",
    b: "Shares pay the same average on every machine. The Harvest pays per failure, so Air collects ~9× more Harvest per energy than Earth.",
  },
  {
    t: "Patience is a strategy",
    b: "Every early exit funds those who wait. Lower fee + unclaimed bonus = fewer people dump right after the Harvest.",
  },
  {
    t: "Traders pay the miners",
    b: "The hook's fee (99% at launch, 3% forever after minute 96) goes 100% to the Harvest. Snipers fund the first night's miners.",
  },
];

export function HowItWorks() {
  return (
    <section id="how" className="mx-auto max-w-7xl px-4 py-20 sm:px-6">
      <div className="label">How it works</div>
      <h2 className="mt-3 max-w-3xl text-4xl sm:text-6xl">
        A token with no way to buy in at launch. <em>Only a way to play in.</em>
      </h2>
      <div className="mt-10 grid gap-3 md:grid-cols-5">
        {STEPS.map((s) => (
          <div key={s.n} className="panel p-5">
            <div className="num text-sm text-gamma">{s.n}</div>
            <div className="mt-3 text-lg font-semibold">{s.title}</div>
            <p className="mt-2 text-sm leading-relaxed text-muted">{s.body}</p>
          </div>
        ))}
      </div>
      <div className="mt-12 grid gap-3 sm:grid-cols-2">
        {IDEAS.map((i) => (
          <div key={i.t} className="rounded-2xl border border-line bg-bg-2 p-6">
            <div className="text-lg font-semibold">{i.t}</div>
            <p className="mt-2 text-sm leading-relaxed text-muted">{i.b}</p>
          </div>
        ))}
      </div>
    </section>
  );
}
