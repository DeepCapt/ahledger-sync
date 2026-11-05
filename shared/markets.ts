/**
 * Market vocabulary. A market is one auction house economy: game x ruleset x faction x region.
 * Brand guide section 9: markets are named "PvP Horde", "Normal Alliance", never realms or servers.
 */
export const RULESETS = ['normal', 'pvp', 'rp', 'hardcore', 'era', 'rppvp'] as const;
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
  const pvp = r.includes('pvp') || /(^|[^a-z])(jcj|jxj)([^a-z]|$)/.test(r);
  const rp = /(^|[^a-z])(rp|jdr|gdr|rol)([^a-z]|$)/.test(r);
  // RP PvP realms ("CAMWOW US2 Realm 9 RP PvP") have their own auction house, apart from PvP.
  if (rp && pvp) return 'rppvp';
  if (pvp) return 'pvp';
  if (rp) return 'rp';
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

/** A SavedVariables path inside the beta client's folder, `_classic_beta_`. */
export function isBetaClientPath(path: string | null | undefined): boolean {
  return /[\\/]_classic_beta_[\\/]/i.test(path ?? '');
}

/** A SavedVariables path inside the live Forever client's folder, `_forever_`. */
export function isForeverClientPath(path: string | null | undefined): boolean {
  return /[\\/]_forever_[\\/]/i.test(path ?? '');
}

/**
 * What to do about a sync app still watching the beta client's file once Forever is live. The
 * game writes to `_forever_` from launch, so a path saved during the beta points at a file that
 * never changes again: nothing uploads and nothing says why. `candidates` is the sync app's
 * detection list, newest first. Returns the Forever file to move to when there is one, 'stale'
 * when the player has not run the addon in the live client yet, or null when nothing is wrong.
 */
export function betaFolderMove(input: {
  path: string | null | undefined;
  candidates: readonly string[];
  settingGame: string;
  region: string;
  now?: number;
}): { to: string } | 'stale' | null {
  if (input.settingGame !== 'forever' || !isBetaClientPath(input.path)) return null;
  if ((input.now ?? Date.now()) < launchAtFor(input.region)) return null;
  const to = input.candidates.find(isForeverClientPath);
  return to ? { to } : 'stale';
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

/**
 * A beta scan that reaches the server once the US houses have opened. Every Forever house
 * started empty at launch, so a scan of a beta realm, or any Forever scan taken before its
 * region's launch, says nothing about a launch market and would only drag beta prices into the
 * launch day's buckets. Before the US instant such a scan is still a valid beta scan.
 */
export function isBetaScanAfterLaunch(
  gameSlug: string,
  region: Region,
  realmName: string,
  observedAt: number,
  now: number = Date.now(),
): boolean {
  if (gameSlug !== 'forever') return false;
  if (now < launchAtFor('us')) return false;
  return FOREVER_BETA_REALM.test(realmName.trim()) || observedAt < launchAtFor(region);
}

/** Forever markets per region: four rulesets (Normal, PvP, RP, RP PvP), two factions. */
export const REGION_MARKETS = 8;

const RULESET_LABEL: Record<Ruleset, string> = {
  normal: 'Normal',
  pvp: 'PvP',
  rp: 'RP',
  rppvp: 'RP PvP',
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
 * "PvP Horde US". Forever runs the same eight markets in more than one region, so the label names
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
 * beta. Once the game is out every house is open in game, so a flagged market is one nobody has
 * scanned yet: "waiting for its first scan", and nothing on the site goes stale.
 */
export function unopenedReason(region: string, now: number = Date.now()): string {
  if (now >= launchAtFor(region)) return 'waiting for its first scan';
  return region === 'us'
    ? 'not open in the beta yet'
    : `opening at launch, ${launchPhrase(region)}`;
}

/**
 * The same in two or three words, for menus and pickers: "opens at launch" before the region's
 * launch, "not open yet" for a US house the beta left closed, "no scan yet" once the game is out.
 */
export function unopenedShort(region: string, now: number = Date.now()): string {
  if (now >= launchAtFor(region)) return 'no scan yet';
  return region !== 'us' ? 'opens at launch' : 'not open yet';
}

/** "PvP Horde EU opens at launch, midnight CET on 5 November." as a whole sentence. */
export function unopenedSentence(label: string, region: string, now: number = Date.now()): string {
  if (now < launchAtFor(region) && region !== 'us')
    return `${label} opens at launch, ${launchPhrase(region)}.`;
  return `${label} is ${unopenedReason(region, now)}.`;
}

/**
 * "Opens at launch, midnight CET on 5 November." or "Not open in the beta yet." before launch,
 * "Open in game, waiting for its first scan." after it.
 */
export function unopenedLine(region: string, now: number = Date.now()): string {
  if (now >= launchAtFor(region)) return 'Open in game, waiting for its first scan.';
  if (region !== 'us') return `Opens at launch, ${launchPhrase(region)}.`;
  const r = unopenedReason(region, now);
  return `${r[0]!.toUpperCase()}${r.slice(1)}.`;
}

/**
 * Whether a market is closed in game, which is what pickers, signup forms and saved choices ask.
 * The unopened flag also marks a launched house nobody has scanned yet (the wording helpers above
 * read it that way), but such a house can be watched, subscribed to and chosen like any other:
 * only before its region's launch is a flagged market really closed.
 */
export function marketClosed(
  m: { unopened?: boolean | null; slug: string },
  now: number = Date.now(),
): boolean {
  return Boolean(m.unopened) && now < launchAtFor(regionOfSlug(m.slug));
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
 * not open in the beta yet, the eight EU markets open with the game at midnight CET on 5 November,
 * and the eight CN markets open with the game at 6 am China time on 5 November." Empty when the
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
    if (launched) {
      parts.push(
        ms.length === REGION_MARKETS
          ? `the eight ${region.toUpperCase()} markets have no scan yet`
          : `${and(ms.map((m) => m.label))} ${ms.length === 1 ? 'has' : 'have'} no scan yet`,
      );
    } else if (region === 'us') {
      parts.push(`${and(ms.map((m) => m.label))} ${be(ms)} not open in the beta yet`);
    } else if (ms.length === REGION_MARKETS) {
      parts.push(
        `the eight ${region.toUpperCase()} markets open with the game at ${launchPhrase(region)}`,
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
