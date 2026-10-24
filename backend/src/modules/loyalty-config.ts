/**
 * The loyalty program's rules. This is the single source of truth: the engine in loyalty.ts reads it, and the
 * apps receive it from GET /loyalty/program instead of hard-coding their own copy.
 */
export type TierCode = 'STANDARD' | 'GOLDEN' | 'DIAMOND' | 'LIGHT';
export type RewardType = 'discount_50_percent' | 'free_session' | 'free_burger';

export interface TierRule {
  code: TierCode;
  title: string;
  theme: string;
  /** Completed cards needed at this tier before advancing (or, for the final tier, to reach maximum status). */
  cardsRequired: number;
  /** Card position (1-10) -> reward unlocked when that position is stamped. Other positions are plain stamps. */
  rewards: Record<number, RewardType>;
  final: boolean;
}

export const STAMPS_PER_CARD = 10;

export const TIERS: readonly TierRule[] = [
  { code: 'STANDARD', title: 'Loyalty Card', theme: 'blue', cardsRequired: 2, rewards: { 5: 'discount_50_percent', 10: 'free_session' }, final: false },
  { code: 'GOLDEN', title: 'Golden Loyalty Card', theme: 'gold', cardsRequired: 3, rewards: { 4: 'discount_50_percent', 8: 'free_session', 9: 'free_session', 10: 'free_session' }, final: false },
  { code: 'DIAMOND', title: 'Diamond Loyalty Card', theme: 'cyan', cardsRequired: 3, rewards: { 2: 'free_session', 8: 'free_session', 9: 'free_session', 10: 'free_session' }, final: false },
  { code: 'LIGHT', title: 'Light Loyalty Card', theme: 'black-red', cardsRequired: 1, rewards: { 5: 'discount_50_percent', 10: 'free_burger' }, final: true },
];

export const REWARD_INFO: Record<RewardType, { label: string; description: string }> = {
  discount_50_percent: { label: '50% OFF', description: '50% off the price of one skating session (session price only; not extensions or other purchases).' },
  free_session: { label: '1 FREE SESSION', description: 'One skating session free of charge.' },
  free_burger: { label: '1 FREE BURGER', description: 'One free burger, handed over by staff.' },
};

export function tierRule(code: string): TierRule {
  const t = TIERS.find((x) => x.code === code);
  if (!t) throw new Error(`unknown loyalty tier ${code}`);
  return t;
}

export function nextTier(code: string): TierRule | null {
  const i = TIERS.findIndex((x) => x.code === code);
  return i >= 0 && i < TIERS.length - 1 ? TIERS[i + 1] : null;
}

export function programDescription() {
  return {
    stampsPerCard: STAMPS_PER_CARD,
    tiers: TIERS.map((t) => ({
      code: t.code, title: t.title, theme: t.theme, cardsRequired: t.cardsRequired, final: t.final,
      positions: Array.from({ length: STAMPS_PER_CARD }, (_, i) => {
        const r = t.rewards[i + 1];
        return { position: i + 1, rewardType: r ?? null, label: r ? REWARD_INFO[r].label : null };
      }),
    })),
    rewards: REWARD_INFO,
  };
}
