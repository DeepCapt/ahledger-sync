/**
 * Market vocabulary. A market is one auction house economy: game x ruleset x faction x region.
 * Brand guide section 9: markets are named "PvP Horde", "Normal Alliance", never realms or servers.
 */
export const RULESETS = ['normal', 'pvp', 'rp', 'hardcore', 'era'] as const;
export type Ruleset = (typeof RULESETS)[number];

/**
 * The ruleset a Forever realm name carries. Forever is realmless, so the "realm" the client
 * reports names the ruleset: "Classic Beta PvP", "Classic Beta PvE", and so on. The addon has
 * applied this rule to pick a market since its first release; the server applies the same one
 * to an upload from a realm it has not seen, rather than refusing the scan and asking the player
 * to report the name.
 */
export function rulesetFromRealmName(name: string): Ruleset {
  const r = name.toLowerCase();
  if (r.includes('hardcore')) return 'hardcore';
  // European clients name the ruleset in their own language: JcJ (French, Spanish), JxJ
  // (Portuguese) for PvP; JdR (French), GdR (Italian), Rol (Spanish) for RP. German and Russian
  // clients say PvP and RP. The addon applies the same words (AHledger.lua rulesetFromRealm).
  if (r.includes('pvp') || /(^|[^a-z])(jcj|jxj)([^a-z]|$)/.test(r)) return 'pvp';
  if (/(^|[^a-z])(rp|jdr|gdr|rol)([^a-z]|$)/.test(r)) return 'rp';
  return 'normal';
}

export const FACTIONS = ['alliance', 'horde', 'neutral'] as const;
export type Faction = (typeof FACTIONS)[number];

export const REGIONS = ['us', 'eu', 'kr', 'tw', 'cn'] as const;
export type Region = (typeof REGIONS)[number];

/**
 * The game a scan's client build belongs to, from the version the addon records ("1.60.1 (70170)"
 * is Forever, "1.15.9 (63008)" is Classic Era), or null when the build is missing or is neither.
 * Forever is versioned 1.16 and up; Classic Era is 1.13 to 1.15.
 */
export function gameForClientBuild(
  build: string | null | undefined,
): 'forever' | 'classic-era' | null {
  const minor = /^\s*1\.(\d+)\./.exec(build ?? '')?.[1];
  if (minor === undefined) return null;
  const n = Number(minor);
  if (n >= 16) return 'forever';
  if (n >= 13) return 'classic-era';
  return null;
}

/**
 * The game a SavedVariables file belongs to, from the client folder it sits in, when the folder
 * says so unambiguously. Classic Era installs live under _classic_era_ (and _classic_era_ptr_);
 * other folder names are left to the client build, since more than one game has used them.
 */
export function gameForSavedVariablesPath(path: string | null | undefined): 'classic-era' | null {
  return /[\\/]_classic_era(_ptr)?_[\\/]/i.test(path ?? '') ? 'classic-era' : null;
}

/**
 * When a saved file's game disagrees with the game it would be uploaded as: the file's game from
 * its folder, or else from the build its newest scan recorded, against the sync app's Game
 * setting. Null when they agree or the file's game cannot be told.
 */
export function savedFileGameMismatch(input: {
  path: string | null | undefined;
  newestBuild: string | null | undefined;
  settingGame: string;
}): { fileGame: 'forever' | 'classic-era'; settingGame: 'forever' | 'classic-era' } | null {
  const { settingGame } = input;
  if (settingGame !== 'forever' && settingGame !== 'classic-era') return null;
  const fileGame = gameForSavedVariablesPath(input.path) ?? gameForClientBuild(input.newestBuild);
  return fileGame && fileGame !== settingGame ? { fileGame, settingGame } : null;
}

/** The Forever beta's realms: "Classic Beta PvE", "Classic Beta PvP 2" and so on. */
export const FOREVER_BETA_REALM = /^classic beta\b/i;

/**
 * The region whose market a scan belongs to. The Forever beta runs one set of realms, hosted in
 * the US, and players from every region are routed to them, but a European account can still
 * report its home region, and the sync app's region setting fills in Europe for a European
 * player. While that holds, a beta realm belongs to the US market whatever region came with the
 * scan; uploads tagged EU were being refused although they were scans of the US realms.
 *
 * The beta realm name is English; a Chinese client names the same realms in Chinese. So the
 * clock is the second rule: before a region's servers open (launchAtFor), every Forever scan is
 * a beta scan, and belongs to the US market. From the region's launch instant, its realms keep
 * their region. `observedAt` is the scan's own time in milliseconds, so a scan taken before
 * launch and uploaded after it is still placed where it was taken.
 */
export function marketRegionFor(
  gameSlug: string,
  region: Region,
  realmName: string,
  observedAt: number = Date.now(),
): Region {
  if (gameSlug !== 'forever') return region;
  if (FOREVER_BETA_REALM.test(realmName.trim())) return 'us';
  if (observedAt < launchAtFor(region)) return 'us';
  return region;
}

const RULESET_LABEL: Record<Ruleset, string> = {
  normal: 'Normal',
  pvp: 'PvP',
  rp: 'RP',
  hardcore: 'Hardcore',
  era: 'Era',
};

const FACTION_LABEL: Record<Faction, string> = {
  alliance: 'Alliance',
  horde: 'Horde',
  neutral: 'Neutral',
};

export function rulesetLabel(r: Ruleset): string {
  return RULESET_LABEL[r];
}

export function factionLabel(f: Faction): string {
  return FACTION_LABEL[f];
}

/**
 * "PvP Horde US". Forever runs the same six markets in more than one region, so the label names
 * the region; without it the US and EU houses read the same in every title, menu and email. A
 * neutral market carries the ruleset name alone.
 */
export function marketLabel(ruleset: Ruleset, faction: Faction, region?: Region): string {
  const base =
    faction === 'neutral'
      ? rulesetLabel(ruleset)
      : `${rulesetLabel(ruleset)} ${factionLabel(faction)}`;
  return region ? `${base} ${region.toUpperCase()}` : base;
}

/**
 * "PvP Horde US" to "PvP Horde": for text that names the region on its own, such as the market
 * page title "PvP Horde auction house prices (US)", which stays as it was indexed.
 */
export function labelWithoutRegion(label: string, region: string): string {
  const suffix = ` ${region.toUpperCase()}`;
  return label.endsWith(suffix) ? label.slice(0, -suffix.length) : label;
}

/** "PvP Horde" to "PvP Horde US", leaving a label that already names its region alone. */
export function labelWithRegion(label: string, region: string): string {
  return label.toUpperCase().endsWith(` ${region.toUpperCase()}`)
    ? label
    : `${label} ${region.toUpperCase()}`;
}

/**
 * The moment World of Warcraft: Forever launches, in every region at once: 3 pm Pacific on
 * 4 November 2026 in the US and midnight CET on 5 November in Europe are the same instant.
 */
export const FOREVER_LAUNCH_AT = Date.parse('2026-11-04T23:00:00Z');

/**
 * The China servers open at 6 am China Standard Time on 5 November 2026, which is 22:00 UTC on
 * 4 November, an hour before the worldwide instant, as announced for the region. One constant,
 * so correcting the hour is one edit.
 */
export const FOREVER_LAUNCH_AT_CN = Date.parse('2026-11-04T22:00:00Z');

/** The instant a region's servers open: China has its own, every other region the worldwide one. */
export function launchAtFor(region: string): number {
  return region === 'cn' ? FOREVER_LAUNCH_AT_CN : FOREVER_LAUNCH_AT;
}

const LAUNCH_PHRASE: Record<string, string> = {
  eu: 'midnight CET on 5 November',
  cn: '6 am China time on 5 November',
};

/** The launch moment the way a region's players tell it: "midnight CET on 5 November". */
export function launchPhrase(region: string): string {
  return LAUNCH_PHRASE[region] ?? '5 November';
}

/**
 * Why a market flagged unopened has no prices, as a phrase that fits after "is" or in brackets.
 * The EU and CN markets open with the game; the US ones that are flagged were left closed in the
 * beta. Once the game is out, any reads "not open yet", so nothing on the site goes stale.
 */
export function unopenedReason(region: string, now: number = Date.now()): string {
  if (now >= launchAtFor(region)) return 'not open yet';
  return region === 'us'
    ? 'not open in the beta yet'
    : `opening at launch, ${launchPhrase(region)}`;
}

/** The same in two or three words, for menus and pickers: "opens at launch" or "not open yet". */
export function unopenedShort(region: string, now: number = Date.now()): string {
  return now < launchAtFor(region) && region !== 'us' ? 'opens at launch' : 'not open yet';
}

/** "PvP Horde EU opens at launch, midnight CET on 5 November." as a whole sentence. */
export function unopenedSentence(label: string, region: string, now: number = Date.now()): string {
  if (now < launchAtFor(region) && region !== 'us')
    return `${label} opens at launch, ${launchPhrase(region)}.`;
  return `${label} is ${unopenedReason(region, now)}.`;
}

/** "Opens at launch, midnight CET on 5 November." or "Not open in the beta yet." */
export function unopenedLine(region: string, now: number = Date.now()): string {
  if (now < launchAtFor(region) && region !== 'us')
    return `Opens at launch, ${launchPhrase(region)}.`;
  const r = unopenedReason(region, now);
  return `${r[0]!.toUpperCase()}${r.slice(1)}.`;
}

/** The region of a market slug, `forever/pvp/horde/eu` to `eu`; `us` when the slug has none. */
export function regionOfSlug(slug: string): string {
  return slug.split(/[/.]/)[3] ?? 'us';
}

/** Stable market slug: `forever/pvp/horde/us`. */
export function marketSlug(
  gameSlug: string,
  ruleset: Ruleset,
  faction: Faction,
  region: Region,
): string {
  return `${gameSlug}/${ruleset}/${faction}/${region}`;
}

export function isRuleset(v: string): v is Ruleset {
  return (RULESETS as readonly string[]).includes(v);
}

export function isFaction(v: string): v is Faction {
  return (FACTIONS as readonly string[]).includes(v);
}

export function isRegion(v: string): v is Region {
  return (REGIONS as readonly string[]).includes(v);
}

/**
 * Blizzard Classic auction house ids (see `/connected-realm/{id}/auctions/index`).
 * 2 = Alliance, 6 = Horde, 7 = Blackwater (neutral, cross-faction).
 */
export const BLIZZARD_CLASSIC_AH_ID: Record<Faction, number> = {
  alliance: 2,
  horde: 6,
  neutral: 7,
};

/**
 * Which markets have no prices yet and why, as one sentence: "RP Alliance US and RP Horde US are
 * not open in the beta yet, the six EU markets open with the game at midnight CET on 5 November,
 * and the six CN markets open with the game at 6 am China time on 5 November." Empty when the
 * list is. Regions come in the order US, EU, CN, then anything else.
 */
export function unopenedSummary(
  unopened: Array<{ label: string; slug: string }>,
  now: number = Date.now(),
): string {
  const and = (xs: string[]) =>
    xs.length <= 1 ? (xs[0] ?? '') : `${xs.slice(0, -1).join(', ')} and ${xs.at(-1)}`;
  const be = (xs: unknown[]) => (xs.length === 1 ? 'is' : 'are');
  const order = ['us', 'eu', 'cn'];
  const regions = [...new Set(unopened.map((m) => regionOfSlug(m.slug)))].sort((a, b) => {
    const ia = order.indexOf(a);
    const ib = order.indexOf(b);
    return (ia < 0 ? order.length : ia) - (ib < 0 ? order.length : ib) || a.localeCompare(b);
  });
  const parts: string[] = [];
  for (const region of regions) {
    const ms = unopened.filter((m) => regionOfSlug(m.slug) === region);
    const launched = now >= launchAtFor(region);
    if (region === 'us') {
      parts.push(
        `${and(ms.map((m) => m.label))} ${be(ms)} ${launched ? 'not open yet' : 'not open in the beta yet'}`,
      );
    } else if (launched) {
      parts.push(`${and(ms.map((m) => m.label))} ${be(ms)} not open yet`);
    } else if (ms.length === 6) {
      parts.push(
        `the six ${region.toUpperCase()} markets open with the game at ${launchPhrase(region)}`,
      );
    } else {
      parts.push(
        `${and(ms.map((m) => m.label))} ${ms.length === 1 ? 'opens' : 'open'} with the game at ${launchPhrase(region)}`,
      );
    }
  }
  if (!parts.length) return '';
  const out =
    parts.length <= 2
      ? parts.join(', and ')
      : `${parts.slice(0, -1).join(', ')}, and ${parts.at(-1)}`;
  return `${out[0]!.toUpperCase()}${out.slice(1)}.`;
}
