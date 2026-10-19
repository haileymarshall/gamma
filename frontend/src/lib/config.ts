import { defineChain, type Address } from "viem";
import { foundry } from "viem/chains";

export const robinhood = defineChain({
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.mainnet.chain.robinhood.com"] } },
  blockExplorers: { default: { name: "Blockscout", url: "https://robinhoodchain.blockscout.com" } },
});

const env = (v: string | undefined) => (v && v.startsWith("0x") && v.length === 42 ? (v as Address) : undefined);

export const CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? robinhood.id);
export const chain = CHAIN_ID === foundry.id ? foundry : robinhood;

/** The live Robinhood Chain deployment (IMD launches 2215 and 2232). Set an env var to point elsewhere, or set
 * NEXT_PUBLIC_DEMO=1 to run the simulation instead. */
const DEPLOYED = {
  game: "0xb333a22c2c3dd0fe29fd1bf184c5ff2282148535",
  gamma: "0xb30749417fd209f4bfc0a0270375fff8e30a0b44",
  hook: "0x066fa23e6f598838824c2d172d3abd88bcad70cc",
} as const satisfies Record<string, Address>;
const demo = process.env.NEXT_PUBLIC_DEMO === "1";
const deployed = (v: Address) => (demo || CHAIN_ID !== robinhood.id ? undefined : v);

export const ADDRESSES = {
  game: env(process.env.NEXT_PUBLIC_GAME_ADDRESS) ?? deployed(DEPLOYED.game),
  gamma: env(process.env.NEXT_PUBLIC_GAMMA_ADDRESS) ?? deployed(DEPLOYED.gamma),
  hook: env(process.env.NEXT_PUBLIC_HOOK_ADDRESS) ?? deployed(DEPLOYED.hook),
  imd: env(process.env.NEXT_PUBLIC_IMD_ADDRESS) ?? ("0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127" as Address),
  poolManager:
    env(process.env.NEXT_PUBLIC_POOL_MANAGER_ADDRESS) ?? ("0x8366a39cc670b4001a1121b8f6a443a643e40951" as Address),
};

/** Without a deployed game the site runs the same rules as a local simulation. */
export const LIVE = Boolean(ADDRESSES.game && ADDRESSES.gamma);

export const LINKS = {
  imd: "https://imd.fun",
  launch: "https://explorer.imd.fun/launch",
  docs: "https://imd.fun/docs/",
  hackathon: "https://www.imdradar.site/hackathon",
  x: process.env.NEXT_PUBLIC_X_URL ?? "https://x.com/",
  github: process.env.NEXT_PUBLIC_GITHUB_URL ?? "https://github.com/haileymarshall/gamma",
  drand: "https://drand.love",
  explorer: chain.blockExplorers?.default.url ?? "",
};
