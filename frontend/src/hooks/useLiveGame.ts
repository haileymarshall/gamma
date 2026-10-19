"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  useConnect,
  useConnection,
  useConnectors,
  useDisconnect,
  usePublicClient,
  useReadContract,
  useReadContracts,
  useSwitchChain,
  useWatchContractEvent,
  useWriteContract,
} from "wagmi";
import { encodeAbiParameters, erc20Abi, formatEther, keccak256, parseEther, type Address, type Hex } from "viem";

import { gameAbi, hookAbi } from "@/lib/abi";
import { ADDRESSES, chain } from "@/lib/config";
import { fetchRound } from "@/lib/drand";
import { ENERGY_COST, EPOCHS_PER_DAY, EPOCH_SECONDS, DAY_SECONDS, MACHINES, type MachineId } from "@/lib/gamma";
import type { BatchView, FeedItem, GameActions, GameView, MachineView } from "@/lib/types";

const GAME = ADDRESSES.game as Address;
const GAMMA = ADDRESSES.gamma as Address;
const IMD = ADDRESSES.imd;
const HOOK = ADDRESSES.hook;
const POOLS_SLOT = 6n;
const Q96 = 2 ** 96;
const SLIPPAGE = 1.04;

const poolManagerAbi = [
  {
    type: "function",
    name: "extsload",
    stateMutability: "view",
    inputs: [{ name: "slot", type: "bytes32" }],
    outputs: [{ name: "", type: "bytes32" }],
  },
] as const;

const n = (v: bigint | undefined) => (v === undefined ? 0 : Number(formatEther(v)));

export function useLiveGame(): [GameView | null, GameActions] {
  const { address, isConnected, chainId } = useConnection();
  const connectors = useConnectors();
  const { mutate: connect } = useConnect();
  const { mutate: disconnect } = useDisconnect();
  const { mutateAsync: switchChain } = useSwitchChain();
  const { mutateAsync: write } = useWriteContract();
  const client = usePublicClient({ chainId: chain.id });

  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [feed, setFeed] = useState<FeedItem[]>([]);
  const [now, setNow] = useState(() => Date.now() / 1000);

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now() / 1000), 1000);
    return () => clearInterval(id);
  }, []);

  const base = { address: GAME, abi: gameAbi, chainId: chain.id } as const;
  const core = useReadContracts({
    contracts: [
      { ...base, functionName: "genesis" },
      { ...base, functionName: "currentEpoch" },
      { ...base, functionName: "totalBurned" },
      { ...base, functionName: "totalEnergies" },
      { ...base, functionName: "cursor" },
      { ...base, functionName: "pendingRound" },
      { ...base, functionName: "poolKey" },
    ],
    query: { refetchInterval: 4_000 },
  });
  const [genesisR, epochR, burnedR, energiesR, cursorR, pendingR, keyR] = core.data ?? [];
  const genesis = Number(genesisR?.result ?? 0n);
  const epoch = genesis ? Math.floor((now - genesis) / EPOCH_SECONDS) : Number(epochR?.result ?? 0n);
  const day = Math.floor(epoch / EPOCHS_PER_DAY);
  const pendingRound = Number(pendingR?.result ?? 0n);

  const detail = useReadContracts({
    contracts: [
      { ...base, functionName: "getEpoch", args: [BigInt(epoch)] },
      { ...base, functionName: "getEpoch", args: [BigInt(Math.max(0, Number(cursorR?.result ?? 1n) - 1))] },
      { ...base, functionName: "getDay", args: [BigInt(day)] },
      { ...base, functionName: "tranche", args: [BigInt(epoch)] },
      { ...base, functionName: "released", args: [BigInt(epoch)] },
    ],
    query: { enabled: genesis > 0, refetchInterval: 4_000 },
  });

  const fee = useReadContract({
    address: HOOK,
    abi: hookAbi,
    functionName: "feeBps",
    chainId: chain.id,
    query: { enabled: Boolean(HOOK), refetchInterval: 15_000 },
  });

  const user = useReadContracts({
    contracts: address
      ? [
          { address: IMD, abi: erc20Abi, functionName: "balanceOf", args: [address], chainId: chain.id },
          { address: GAMMA, abi: erc20Abi, functionName: "balanceOf", args: [address], chainId: chain.id },
          { address: IMD, abi: erc20Abi, functionName: "allowance", args: [address, GAME], chainId: chain.id },
          { ...base, functionName: "userBatches", args: [address, 0n, 60n] },
        ]
      : [],
    query: { enabled: Boolean(address), refetchInterval: 5_000 },
  });

  // Spot price from the pool's slot0, read straight from the PoolManager.
  const key = keyR?.result as
    | { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address }
    | undefined;
  const poolSlot = useMemo(() => {
    if (!key) return undefined;
    const poolId = keccak256(
      encodeAbiParameters(
        [
          { type: "address" },
          { type: "address" },
          { type: "uint24" },
          { type: "int24" },
          { type: "address" },
        ],
        [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks],
      ),
    );
    return keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [poolId, POOLS_SLOT]));
  }, [key]);
  const slot0 = useReadContract({
    address: ADDRESSES.poolManager,
    abi: poolManagerAbi,
    functionName: "extsload",
    args: poolSlot ? [poolSlot] : undefined,
    chainId: chain.id,
    query: { enabled: Boolean(poolSlot), refetchInterval: 8_000 },
  });
  const imdPerGamma = useMemo(() => {
    if (!slot0.data || !key) return 0;
    const sqrt = Number(BigInt(slot0.data) & ((1n << 160n) - 1n)) / Q96;
    const p1per0 = sqrt * sqrt;
    const gammaIs0 = key.currency0.toLowerCase() === GAMMA.toLowerCase();
    return gammaIs0 ? p1per0 : p1per0 > 0 ? 1 / p1per0 : 0;
  }, [slot0.data, key]);

  const onLogs = useCallback((items: FeedItem[]) => setFeed((f) => [...items, ...f].slice(0, 40)), []);
  useWatchContractEvent({
    ...base,
    eventName: "EnergiesBought",
    onLogs: (logs) =>
      onLogs(
        logs.map((l) => ({
          id: `${l.transactionHash}-${l.logIndex}`,
          kind: "buy" as const,
          machine: Number(l.args.machine) as MachineId,
          at: Date.now() / 1000,
          text: `${l.args.owner?.slice(0, 6)}… burned ${(Number(l.args.energies) * ENERGY_COST).toLocaleString()} GAMMA on ${MACHINES[Number(l.args.machine)].name}`,
        })),
      ),
  });
  useWatchContractEvent({
    ...base,
    eventName: "Harvest",
    onLogs: (logs) =>
      onLogs(
        logs.map((l) => ({
          id: `${l.transactionHash}-${l.logIndex}`,
          kind: "harvest" as const,
          at: Date.now() / 1000,
          text: `Harvest day ${l.args.day} · ${Math.round(n(l.args.pot)).toLocaleString()} GAMMA across ${l.args.fails} fails`,
        })),
      ),
  });
  useWatchContractEvent({
    ...base,
    eventName: "Claimed",
    onLogs: (logs) =>
      onLogs(
        logs.map((l) => ({
          id: `${l.transactionHash}-${l.logIndex}`,
          kind: "claim" as const,
          at: Date.now() / 1000,
          text: `${l.args.owner?.slice(0, 6)}… claimed ${Math.round(n(l.args.paid)).toLocaleString()} GAMMA`,
        })),
      ),
  });

  const refresh = useCallback(() => {
    core.refetch();
    detail.refetch();
    user.refetch();
  }, [core, detail, user]);

  const ensureChain = useCallback(async () => {
    if (chainId !== chain.id) await switchChain({ chainId: chain.id });
  }, [chainId, switchChain]);

  const proofs = useCallback(async () => {
    if (!pendingRound) return [];
    const r = await fetchRound(pendingRound);
    return r ? [{ round: BigInt(r.round), signature: r.signature as Hex }] : [];
  }, [pendingRound]);

  const run = useCallback(
    async (label: string, fn: () => Promise<Hex>) => {
      setBusy(label);
      setError(null);
      try {
        await ensureChain();
        const hash = await fn();
        setBusy("Confirming");
        await client?.waitForTransactionReceipt({ hash });
        refresh();
      } catch (e) {
        const msg = e instanceof Error ? e.message.split("\n")[0] : String(e);
        setError(msg.length > 160 ? `${msg.slice(0, 160)}…` : msg);
      } finally {
        setBusy(null);
      }
    },
    [client, ensureChain, refresh],
  );

  const [imdBal, gammaBal, allowance, batchesR] = user.data ?? [];

  const actions: GameActions = {
    buy: async (machine, energies) => {
      const estimate = energies * ENERGY_COST * imdPerGamma * 1.0125 * SLIPPAGE;
      const maxIn = parseEther(estimate.toFixed(6));
      if ((allowance?.result ?? 0n) < maxIn) {
        await run("Approving IMD", () =>
          write({ address: IMD, abi: erc20Abi, functionName: "approve", args: [GAME, maxIn * 10n], chainId: chain.id }),
        );
      }
      const p = await proofs();
      await run("Burning GAMMA", () =>
        write({
          ...base,
          functionName: "buyEnergies",
          args: [machine, BigInt(energies), maxIn, p],
        }),
      );
    },
    claim: (ids, matured) =>
      run("Claiming", () =>
        write({ ...base, functionName: matured ? "claimMatured" : "claim", args: [ids.map((i) => BigInt(i))] }),
      ),
    settle: async () => {
      const p = await proofs();
      await run("Settling", () => write({ ...base, functionName: "settle", args: [64n, p] }));
    },
    setSpeed: () => {},
    connect: () => {
      const c = connectors[0];
      if (c) connect({ connector: c, chainId: chain.id });
      else setError("No browser wallet found. Install MetaMask or Rabby.");
    },
    disconnect: () => disconnect(),
    clearError: () => setError(null),
  };

  if (!genesis) return [null, actions];

  type EpochTuple = readonly [readonly number[], readonly number[], readonly bigint[], readonly number[], boolean, bigint];
  const cur = detail.data?.[0]?.result as EpochTuple | undefined;
  const last = detail.data?.[1]?.result as EpochTuple | undefined;
  const today = detail.data?.[2]?.result as { pot: bigint; fails: bigint } | undefined;

  const machines: MachineView[] = MACHINES.map((_, m) => ({
    energies: cur ? Number(cur[0][m]) : 0,
    last:
      last && last[4]
        ? {
            energies: Number(last[0][m]),
            survivors: Number(last[1][m]),
            payPerSurvivor: n(last[2][m]),
            shareTenths: Number(last[3][m]),
          }
        : null,
  }));

  type RawBatch = {
    id: bigint;
    machine: number;
    epoch: number;
    energies: number;
    survivors: number;
    drawn: boolean;
    claimed: boolean;
    harvested: boolean;
    winnings: bigint;
    bonus: bigint;
    feeBps: bigint;
  };
  const batches: BatchView[] = ((batchesR?.result as readonly RawBatch[] | undefined) ?? []).map((b) => ({
    id: Number(b.id),
    machine: b.machine as MachineId,
    epoch: b.epoch,
    energies: b.energies,
    survivors: b.survivors,
    drawn: b.drawn,
    claimed: b.claimed,
    harvested: b.harvested,
    winnings: n(b.winnings),
    bonus: n(b.bonus),
    feeBps: Number(b.feeBps),
  }));

  return [
    {
      mode: "live",
      ready: true,
      connected: isConnected,
      address,
      now,
      genesis,
      epoch,
      day,
      epochEndsIn: genesis + (epoch + 1) * EPOCH_SECONDS - now,
      harvestIn: genesis + (day + 1) * DAY_SECONDS - now,
      tranche: n(detail.data?.[3]?.result as bigint | undefined),
      machines,
      pot: n(today?.pot),
      dayFails: Number(today?.fails ?? 0n),
      totalBurned: n(burnedR?.result as bigint | undefined),
      totalEnergies: Number(energiesR?.result ?? 0n),
      released: n(detail.data?.[4]?.result as bigint | undefined),
      tradingFeeBps: Number(fee.data ?? 300n),
      energyPriceImd: ENERGY_COST * imdPerGamma * 1.0125,
      imdBalance: n(imdBal?.result as bigint | undefined),
      gammaBalance: n(gammaBal?.result as bigint | undefined),
      batches,
      feed,
      busy,
      error,
      speed: 1,
    },
    actions,
  ];
}
