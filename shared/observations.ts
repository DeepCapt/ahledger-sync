/**
 * Item source observations: what players see in game and choose to contribute. A loot window
 * opening on a creature, a vendor's stock, a quest's rewards, a fishing catch, a chest or node.
 * The addon aggregates them per source, item and hour into AHledgerDB.observations; sync uploads
 * that table whole; the server keeps one row per contributor and key with counts taken as the
 * maximum seen, so a table sent twice changes nothing.
 *
 * No character, account or realm data travels with them: a source is a creature, object, quest
 * or vendor id plus the name and zone the client showed.
 */
import type { LuaValue } from './addon';
import { parseLuaSavedVariables } from './addon';
import { ZONES } from './zones';

export const OBSERVATION_KINDS = [
  'drop',
  'vendor',
  'quest',
  'fish',
  'object',
  'container',
] as const;
export type ObservationKind = (typeof OBSERVATION_KINDS)[number];

export const OBSERVATIONS_VERSION = 1;
/** Records per upload; the addon keeps fewer than this in its table. */
export const OBSERVATIONS_MAX_RECORDS = 5000;
export const OBSERVATION_MAX_NAME = 80;
export const OBSERVATION_MAX_COUNT = 1_000_000;
export const OBSERVATION_MAX_ID = 2_147_483_647;

/** One aggregated line as the addon stores it: short keys keep the saved file small. */
export interface ObservationRecord {
  /** Kind of source. */
  k: ObservationKind;
  /** Source id: creature, object or quest id, vendor npc id, container item id; 0 for fishing. */
  s: number;
  /** Source name as shown in the client, when known. */
  n?: string;
  /** uiMapID of the zone, when known. */
  z?: number;
  /** Zone name, when known. */
  zn?: string;
  /** Subzone text, when known. */
  sz?: string;
  /** Item id; 0 on the row that only counts how often the source was opened. */
  i: number;
  /** Hour bucket, unix seconds rounded down to the hour. */
  h: number;
  /** Times the item was seen from this source in the hour. */
  c: number;
  /** Total quantity seen. */
  q?: number;
  /** Loot windows opened on the source in the hour (item 0 rows). */
  o?: number;
  /** Vendor price in copper (vendor rows). */
  p?: number;
  /**
   * Addon session the line was counted in. The beta client starts every session with an empty
   * table, so the same source and hour can arrive from two sessions; the server sums sessions.
   */
  x?: number;
}

/** Quests per upload; the addon keeps fewer than this. */
export const QUESTS_MAX_RECORDS = 1000;
export const QUEST_MAX_ITEMS = 8;
export const QUEST_MAX_OBJECTIVES = 12;

/**
 * What the addon keeps about a quest from its offer window, its log entry and its turn-in:
 * the facts a quest page lists, never its description or dialogue text.
 */
export interface QuestRecord {
  id: number;
  /** Title as the client shows it. */
  t?: string;
  /** Level from the quest log. */
  l?: number;
  /** Giver: creature or object id, kind and name. */
  g?: number;
  gk?: 'npc' | 'obj';
  gn?: string;
  /** Receiver at turn-in: creature or object id, kind and name. */
  e?: number;
  ek?: 'npc' | 'obj';
  en?: string;
  /** uiMapID and name of the zone it was picked up in. */
  z?: number;
  zn?: string;
  /** Money reward in copper. */
  m?: number;
  /** Experience reward. */
  x?: number;
  /** Reward item ids given outright, and the ids offered as a choice. */
  r?: number[];
  c?: number[];
  /** Objectives as the log counts them: a name and, when counted, how many. */
  o?: Array<{ n: string; q?: number }>;
  /** Hour bucket the quest was last seen, unix seconds. */
  h: number;
  /** 1 once the turn-in window was seen. */
  d?: 1;
}

export interface ObservationsUpload {
  v: typeof OBSERVATIONS_VERSION;
  addon: string;
  game: string;
  /** When the table was read, unix seconds. */
  observedAt: number;
  /** Client build of the newest scan in the same file, e.g. "1.60.1 (70170)", when known. */
  build?: string;
  records: ObservationRecord[];
  /** Quests seen, when the addon and sync both know about them. */
  quests?: QuestRecord[];
  /** The game client's language, e.g. "enUS" or "deDE", from addon 0.8.8 and sync 0.2.17. */
  locale?: string;
}

/** The shape of a WoW client locale code. */
const LOCALE_RE = /^[a-z]{2}[A-Z]{2}$/;

/** True for the clients whose names the site shows: everything on the site is in English. */
export function isEnglishLocale(locale: string): boolean {
  return locale === 'enUS' || locale === 'enGB';
}

/**
 * The upload with every name the client wrote in its own language removed: creature, object and
 * zone names, subzones, quest titles, givers, receivers and objectives. Ids, counts, prices,
 * levels and rewards stay, so a player on a German client still adds drop rates and quest facts,
 * only never a German name to an English page.
 */
export function withoutClientNames(upload: ObservationsUpload): ObservationsUpload {
  const records = upload.records.map((r) => {
    const { n: _n, zn: _zn, sz: _sz, ...rest } = r;
    return rest;
  });
  const quests = upload.quests?.map((q) => {
    const { t: _t, gn: _gn, en: _en, zn: _zn, o: _o, ...rest } = q;
    return rest;
  });
  return { ...upload, records, ...(quests ? { quests } : {}) };
}

const ENGLISH_ZONE = new Map(ZONES.map((z) => [z.id, z.name]));

/**
 * Whether an upload that does not say its language came from a client in another one. An English
 * client names a zone exactly as the zone list does ("The Barrens"); a German one writes "Das
 * Brachland". Two zones named differently, or most of the zone names checked, settle it; one
 * stray zone does not, so a map the game renames before the list catches up does not.
 */
export function looksNonEnglish(upload: ObservationsUpload): boolean {
  return zoneNamesLookNonEnglish([...upload.records, ...(upload.quests ?? [])]);
}

/** The zone test of looksNonEnglish over any list of zone ids and the names recorded with them. */
export function zoneNamesLookNonEnglish(
  seen: Iterable<{ z?: number | null; zn?: string | null }>,
): boolean {
  let checked = 0;
  let wrong = 0;
  const wrongZones = new Set<number>();
  for (const { z, zn } of seen) {
    if (!z || !zn) continue;
    const en = ENGLISH_ZONE.get(z);
    if (!en) continue;
    checked++;
    if (en !== zn) {
      wrong++;
      wrongZones.add(z);
    }
  }
  return wrongZones.size >= 2 || (checked >= 3 && wrong * 2 > checked);
}

const KIND_SET = new Set<string>(OBSERVATION_KINDS);
const isInt = (v: unknown, max = OBSERVATION_MAX_ID): v is number =>
  typeof v === 'number' && Number.isInteger(v) && v >= 0 && v <= max;

/** Names as the client shows them, with control characters, link, icon and colour codes stripped. */
export function cleanObservationName(v: unknown): string | undefined {
  if (typeof v !== 'string') return undefined;
  const s = v
    .replace(/\|T[^|]*\|t|\|A[^|]*\|a/g, '')
    .replace(/\|c[0-9a-fA-F]{8}|\|r|\|H[^|]*\|h|\|h/g, '')
    .replace(/[\u0000-\u001f\u007f]/g, '')
    .trim()
    .slice(0, OBSERVATION_MAX_NAME);
  return s.length > 0 ? s : undefined;
}

/** Interface labels that addon versions before 0.8.5 could record as a world object's name. */
const INTERFACE_LABELS = new Set(['Ready cooldowns', 'Search', 'Greed', 'Need', 'Pass']);

/**
 * True for text that is part of the game's interface rather than the name of a chest, vein or
 * plant. Addon versions before 0.8.5 named an object from whatever tooltip was last shown, so
 * the experience bar ("16,343 / 25,200 ( 65% )"), this addon's own minimap button, the quest
 * tracker and help prompts reached the site as object names. Most players are still on those
 * versions, so the check stays at the door.
 */
export function isInterfaceText(name: string): boolean {
  return (
    /\d\s*\/\s*\d/.test(name) ||
    name.includes('%') ||
    /^(AHledger|Press |Click |Left-click|Right-click|Shift-click)/i.test(name) ||
    INTERFACE_LABELS.has(name)
  );
}

/** Validates one record; returns the cleaned record or null. */
export function cleanObservationRecord(v: unknown): ObservationRecord | null {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return null;
  const r = v as Record<string, unknown>;
  if (typeof r['k'] !== 'string' || !KIND_SET.has(r['k'])) return null;
  if (!isInt(r['s']) || !isInt(r['i']) || !isInt(r['h'], 4_102_444_800)) return null;
  if (!isInt(r['c'], OBSERVATION_MAX_COUNT)) return null;
  const out: ObservationRecord = {
    k: r['k'] as ObservationKind,
    s: r['s'],
    i: r['i'],
    h: r['h'] - (r['h'] % 3600),
    c: r['c'],
  };
  const n = cleanObservationName(r['n']);
  if (n && !(out.k === 'object' && isInterfaceText(n))) out.n = n;
  if (isInt(r['z'], 1_000_000)) out.z = r['z'];
  const zn = cleanObservationName(r['zn']);
  if (zn) out.zn = zn;
  const sz = cleanObservationName(r['sz']);
  if (sz) out.sz = sz;
  if (isInt(r['q'], OBSERVATION_MAX_COUNT * 100)) out.q = r['q'];
  if (isInt(r['o'], OBSERVATION_MAX_COUNT)) out.o = r['o'];
  if (isInt(r['p'], 10_000_000_000_000)) out.p = r['p'];
  if (isInt(r['x'], OBSERVATION_MAX_ID) && r['x'] > 0) out.x = r['x'];
  if (out.i === 0 && !out.o) return null; // a source row must count something
  return out;
}

const itemIds = (v: unknown): number[] | undefined => {
  if (!Array.isArray(v)) return undefined;
  const out = [...new Set(v.filter((x): x is number => isInt(x) && x > 0))].slice(
    0,
    QUEST_MAX_ITEMS,
  );
  return out.length > 0 ? out : undefined;
};

/** Validates one quest record; returns the cleaned record or null. */
export function cleanQuestRecord(v: unknown): QuestRecord | null {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return null;
  const r = v as Record<string, unknown>;
  if (!isInt(r['id']) || r['id'] === 0 || !isInt(r['h'], 4_102_444_800)) return null;
  const out: QuestRecord = { id: r['id'], h: r['h'] - (r['h'] % 3600) };
  const t = cleanObservationName(r['t']);
  if (t) out.t = t;
  if (isInt(r['l'], 100) && r['l'] > 0) out.l = r['l'];
  for (const key of ['g', 'e'] as const) {
    if (isInt(r[key]) && r[key] > 0) {
      out[key] = r[key];
      out[`${key}k`] = r[`${key}k`] === 'obj' ? 'obj' : 'npc';
      const name = cleanObservationName(r[`${key}n`]);
      if (name) out[`${key}n`] = name;
    }
  }
  if (isInt(r['z'], 1_000_000) && r['z'] > 0) out.z = r['z'];
  const zn = cleanObservationName(r['zn']);
  if (zn) out.zn = zn;
  if (isInt(r['m'], 10_000_000_000) && r['m'] > 0) out.m = r['m'];
  if (isInt(r['x'], 10_000_000) && r['x'] > 0) out.x = r['x'];
  const rewards = itemIds(r['r']);
  if (rewards) out.r = rewards;
  const choices = itemIds(r['c']);
  if (choices) out.c = choices;
  if (Array.isArray(r['o'])) {
    const o: Array<{ n: string; q?: number }> = [];
    for (const raw of r['o']) {
      if (!raw || typeof raw !== 'object') continue;
      const n = cleanObservationName((raw as Record<string, unknown>)['n']);
      if (!n) continue;
      const q = (raw as Record<string, unknown>)['q'];
      o.push(isInt(q, 100_000) && q > 0 ? { n, q } : { n });
      if (o.length >= QUEST_MAX_OBJECTIVES) break;
    }
    if (o.length > 0) out.o = o;
  }
  if (r['d'] === 1 || r['d'] === true) out.d = 1;
  if (!out.t) return null; // a quest without a title has nothing to say
  return out;
}

/** Cleans a list of quest records, dropping the unusable; empty when absent. */
export function cleanQuestRecords(v: unknown): { quests: QuestRecord[]; dropped: number } {
  if (!Array.isArray(v)) return { quests: [], dropped: 0 };
  const quests: QuestRecord[] = [];
  let dropped = 0;
  for (const raw of v) {
    const q = cleanQuestRecord(raw);
    if (q) quests.push(q);
    else dropped++;
    if (quests.length >= QUESTS_MAX_RECORDS) break;
  }
  return { quests, dropped };
}

export type ObservationsParse =
  { ok: true; upload: ObservationsUpload; dropped: number } | { ok: false; error: string };

/** Validates a decoded upload body from the API or the queue. */
export function parseObservationsUpload(json: unknown): ObservationsParse {
  if (!json || typeof json !== 'object' || Array.isArray(json)) {
    return { ok: false, error: 'invalid upload: body must be an object' };
  }
  const b = json as Record<string, unknown>;
  if (b['v'] !== OBSERVATIONS_VERSION) return { ok: false, error: 'invalid upload: v' };
  if (typeof b['addon'] !== 'string' || b['addon'].length === 0 || b['addon'].length > 32) {
    return { ok: false, error: 'invalid upload: addon' };
  }
  if (typeof b['game'] !== 'string' || !/^[a-z0-9-]{1,40}$/.test(b['game'])) {
    return { ok: false, error: 'invalid upload: game' };
  }
  if (
    b['build'] !== undefined &&
    (typeof b['build'] !== 'string' || !/^[0-9][0-9A-Za-z .()_-]{0,63}$/.test(b['build']))
  ) {
    return { ok: false, error: 'invalid upload: build' };
  }
  if (
    b['locale'] !== undefined &&
    (typeof b['locale'] !== 'string' || !LOCALE_RE.test(b['locale']))
  ) {
    return { ok: false, error: 'invalid upload: locale' };
  }
  if (!isInt(b['observedAt'], 4_102_444_800) || b['observedAt'] === 0) {
    return { ok: false, error: 'invalid upload: observedAt' };
  }
  if (!Array.isArray(b['records'])) return { ok: false, error: 'invalid upload: records' };
  if (b['records'].length > OBSERVATIONS_MAX_RECORDS) {
    return { ok: false, error: `invalid upload: more than ${OBSERVATIONS_MAX_RECORDS} records` };
  }
  const records: ObservationRecord[] = [];
  let dropped = 0;
  for (const raw of b['records']) {
    const rec = cleanObservationRecord(raw);
    if (rec) records.push(rec);
    else dropped++;
  }
  if (b['quests'] !== undefined && !Array.isArray(b['quests'])) {
    return { ok: false, error: 'invalid upload: quests' };
  }
  if (Array.isArray(b['quests']) && b['quests'].length > QUESTS_MAX_RECORDS) {
    return { ok: false, error: `invalid upload: more than ${QUESTS_MAX_RECORDS} quests` };
  }
  const cleaned = cleanQuestRecords(b['quests']);
  dropped += cleaned.dropped;
  if (records.length === 0 && cleaned.quests.length === 0) {
    return { ok: false, error: 'invalid upload: no usable records' };
  }
  return {
    ok: true,
    upload: {
      v: OBSERVATIONS_VERSION,
      addon: b['addon'],
      game: b['game'],
      observedAt: b['observedAt'],
      ...(typeof b['build'] === 'string' ? { build: b['build'] } : {}),
      records,
      ...(cleaned.quests.length > 0 ? { quests: cleaned.quests } : {}),
      ...(typeof b['locale'] === 'string' ? { locale: b['locale'] } : {}),
    },
    dropped,
  };
}

/** The addon's observation table from a SavedVariables file, cleaned; empty when absent. */
export function observationsFromSavedVariables(src: string): ObservationRecord[] {
  const root = parseLuaSavedVariables(src);
  const db = root['AHledgerDB'];
  if (!db || typeof db !== 'object' || Array.isArray(db)) return [];
  const list = (db as Record<string, LuaValue>)['observations'];
  if (!Array.isArray(list)) return [];
  const out: ObservationRecord[] = [];
  for (const raw of list) {
    const rec = cleanObservationRecord(raw);
    if (rec) out.push(rec);
    if (out.length >= OBSERVATIONS_MAX_RECORDS) break;
  }
  return out;
}

/** The addon's quest table from a SavedVariables file, cleaned; empty when absent. */
export function questsFromSavedVariables(src: string): QuestRecord[] {
  const root = parseLuaSavedVariables(src);
  const db = root['AHledgerDB'];
  if (!db || typeof db !== 'object' || Array.isArray(db)) return [];
  return cleanQuestRecords((db as Record<string, LuaValue>)['quests']).quests;
}

/** The client language the addon wrote to the saved file (0.8.8 and later), when it did. */
export function localeFromSavedVariables(src: string): string | undefined {
  const root = parseLuaSavedVariables(src);
  const db = root['AHledgerDB'];
  if (!db || typeof db !== 'object' || Array.isArray(db)) return undefined;
  const locale = (db as Record<string, LuaValue>)['locale'];
  return typeof locale === 'string' && LOCALE_RE.test(locale) ? locale : undefined;
}

/** Whether the addon's "observe" switch is on in the saved file; on when absent. */
export function observationOn(src: string): boolean {
  const root = parseLuaSavedVariables(src);
  const db = root['AHledgerDB'];
  if (!db || typeof db !== 'object' || Array.isArray(db)) return true;
  const settings = (db as Record<string, LuaValue>)['settings'];
  if (!settings || typeof settings !== 'object' || Array.isArray(settings)) return true;
  return (settings as Record<string, LuaValue>)['observe'] !== false;
}

/** Job the API queues for the workers. */
export interface AddonObservationsJob {
  uploadKeyId: number;
  uploaderId: string;
  gameId: number;
  gameSlug: string;
  addon: string;
  observedAt: number;
  recordCount: number;
  /** SHA-256 of the raw request body. */
  payloadHash: string;
  /** Base64 of the gzip-compressed upload body, as received or compressed by the API. */
  bodyGz: string;
}
