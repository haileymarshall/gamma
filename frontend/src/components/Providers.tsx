"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createContext, useContext, useState, type ReactNode } from "react";
import { WagmiProvider, createConfig, http, type Transport } from "wagmi";
import { injected } from "wagmi/connectors";

import { chain, LIVE } from "@/lib/config";
import { useDemoGame } from "@/hooks/useDemoGame";
import { useLiveGame } from "@/hooks/useLiveGame";
import type { GameActions, GameView } from "@/lib/types";

const wagmiConfig = createConfig({
  chains: [chain],
  connectors: [injected()],
  transports: { [chain.id]: http() } as Record<typeof chain.id, Transport>,
  ssr: true,
});

// LIVE is fixed at build time, so the same hook runs on every render.
const useGameSource = LIVE ? useLiveGame : useDemoGame;

const GameContext = createContext<[GameView | null, GameActions] | null>(null);

function GameBridge({ children }: { children: ReactNode }) {
  const value = useGameSource();
  return <GameContext.Provider value={value}>{children}</GameContext.Provider>;
}

export function Providers({ children }: { children: ReactNode }) {
  const [queryClient] = useState(() => new QueryClient());
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <GameBridge>{children}</GameBridge>
      </QueryClientProvider>
    </WagmiProvider>
  );
}

export function useGame() {
  const ctx = useContext(GameContext);
  if (!ctx) throw new Error("useGame outside Providers");
  return ctx;
}
