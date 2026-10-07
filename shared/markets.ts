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

export const REGIONS = ['us', 'eu', 'kr', 'tw'] as const;
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
 * scan; uploads tagged EU were being refused although they were scans of the US realms. Launch
 * realms will have names of their own, so nothing outside the beta is moved.
 */
export function marketRegionFor(gameSlug: string, region: Region, realmName: string): Region {
  return gameSlug === 'forever' && FOREVER_BETA_REALM.test(realmName.trim()) ? 'us' : region;
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
 * Why a market flagged unopened has no prices, as a phrase that fits after "is" or in brackets.
 * The EU markets open with the game; the US ones that are flagged were left closed in the beta.
 * Once the game is out, either reads "not open yet", so nothing on the site goes stale.
 */
export function unopenedReason(region: string, now: number = Date.now()): string {
  if (now >= FOREVER_LAUNCH_AT) return 'not open yet';
  return region === 'us'
    ? 'not open in the beta yet'
    : 'opening at launch, midnight CET on 5 November';
}

/** The same in two or three words, for menus and pickers: "opens at launch" or "not open yet". */
export function unopenedShort(region: string, now: number = Date.now()): string {
  return now < FOREVER_LAUNCH_AT && region !== 'us' ? 'opens at launch' : 'not open yet';
}

/** "PvP Horde EU opens at launch, midnight CET on 5 November." as a whole sentence. */
export function unopenedSentence(label: string, region: string, now: number = Date.now()): string {
  if (now < FOREVER_LAUNCH_AT && region !== 'us')
    return `${label} opens at launch, midnight CET on 5 November.`;
  return `${label} is ${unopenedReason(region, now)}.`;
}

/** "Opens at launch, midnight CET on 5 November." or "Not open in the beta yet." */
export function unopenedLine(region: string, now: number = Date.now()): string {
  if (now < FOREVER_LAUNCH_AT && region !== 'us')
    return 'Opens at launch, midnight CET on 5 November.';
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
 * not open in the beta yet, and the six EU markets open with the game at midnight CET on
 * 5 November." Empty when the list is.
 */
export function unopenedSummary(
  unopened: Array<{ label: string; slug: string }>,
  now: number = Date.now(),
): string {
  const launched = now >= FOREVER_LAUNCH_AT;
  const and = (xs: string[]) =>
    xs.length <= 1 ? (xs[0] ?? '') : `${xs.slice(0, -1).join(', ')} and ${xs.at(-1)}`;
  const eu = unopened.filter((m) => regionOfSlug(m.slug) !== 'us');
  const us = unopened.filter((m) => regionOfSlug(m.slug) === 'us');
  const be = (xs: unknown[]) => (xs.length === 1 ? 'is' : 'are');
  const parts: string[] = [];
  if (us.length) {
    parts.push(
      `${and(us.map((m) => m.label))} ${be(us)} ${launched ? 'not open yet' : 'not open in the beta yet'}`,
    );
  }
  if (eu.length) {
    parts.push(
      launched
        ? `${and(eu.map((m) => m.label))} ${be(eu)} not open yet`
        : eu.length === 6
          ? 'the six EU markets open with the game at midnight CET on 5 November'
          : `${and(eu.map((m) => m.label))} ${eu.length === 1 ? 'opens' : 'open'} with the game at midnight CET on 5 November`,
    );
  }
  if (!parts.length) return '';
  const out = parts.join(', and ');
  return `${out[0]!.toUpperCase()}${out.slice(1)}.`;
}
