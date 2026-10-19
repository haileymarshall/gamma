// drand evmnet: the randomness that seeds every epoch. Signatures are fetched here and verified on-chain.

export const DRAND_GENESIS = 1727521075;
export const DRAND_PERIOD = 3;
const API = "https://api.drand.sh/v2/beacons/evmnet/rounds";

export function roundTime(round: number): number {
  return DRAND_GENESIS + (round - 1) * DRAND_PERIOD;
}

export async function fetchRound(round: number): Promise<{ round: number; signature: `0x${string}` } | null> {
  if (roundTime(round) > Date.now() / 1000) return null;
  try {
    const res = await fetch(`${API}/${round}`);
    if (!res.ok) return null;
    const json = (await res.json()) as { round: number; signature: string };
    return { round: json.round, signature: `0x${json.signature}` };
  } catch {
    return null;
  }
}
