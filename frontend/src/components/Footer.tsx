import { Logo } from "./Header";
import { LINKS } from "@/lib/config";

export function Footer() {
  const links = [
    ["X", LINKS.x],
    ["GitHub", LINKS.github],
    ["IMD", LINKS.imd],
    ["IMD docs", LINKS.docs],
    ["drand", LINKS.drand],
  ];
  return (
    <footer className="border-t border-line">
      <div className="mx-auto flex max-w-7xl flex-col gap-6 px-4 py-10 sm:flex-row sm:items-center sm:justify-between sm:px-6">
        <div className="flex items-center gap-3">
          <Logo size={28} />
          <div>
            <div className="font-serif text-xl">Gamma</div>
            <div className="text-xs text-dim">Built for the IMD Hackathon. Launched through the swarm.</div>
          </div>
        </div>
        <div className="flex flex-wrap gap-4 text-sm text-muted">
          {links.map(([k, v]) => (
            <a key={k} href={v} target="_blank" rel="noreferrer" className="hover:text-text">
              {k} ↗
            </a>
          ))}
        </div>
      </div>
      <div className="mx-auto max-w-7xl px-4 pb-10 text-xs leading-relaxed text-dim sm:px-6">
        GAMMA is an experimental game of chance paid in crypto. Energies can earn nothing; what is spent is burned, not
        refunded. Its only market is the GAMMA/IMD pool, so its value follows IMD. The contracts cannot be changed. Play
        only with what you can afford to lose and check whether this counts as gambling where you live.
      </div>
    </footer>
  );
}
