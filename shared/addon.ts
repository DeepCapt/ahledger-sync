/**
 * Addon scan uploads: the wire format the companion (or the CLI) posts to `POST /v1/upload`, the
 * compact encoding the addon writes into SavedVariables, and a small Lua table reader for that
 * file. Pure TypeScript so the companion, the API, and the workers all share one definition.
 *
 * Wire format v1 (JSON, optionally gzip with `Content-Encoding: gzip`, at most UPLOAD_MAX_BYTES):
 *   { v: 1, addon, game, region, realm, faction, observedAt, full, build?, auctions: [[...], ...] }
 * Each auction is `[itemId, quantity, buyout, bid, timeLeft]` in copper / units / 0-4.
 *
 * Every request is signed with a per-install key: headers `x-ahl-key`, `x-ahl-ts` (unix seconds),
 * `x-ahl-nonce`, `x-ahl-signature` = hex HMAC-SHA256(secret, uploadSigningString(...)) over the
 * SHA-256 of the raw body bytes exactly as sent (compressed or not).
 */
import type { BlizzardClassicAuction } from './auctions';
import { marketRegionFor, type Region } from './markets';

export const UPLOAD_VERSION = 1;
export const ADDON_UPLOAD_QUEUE = 'addon-upload';
export const UPLOAD_MAX_BYTES = 5 * 1024 * 1024;
export const UPLOAD_MAX_AUCTIONS = 250_000;
/** Accepted clock skew between the uploader and the API. */
export const UPLOAD_SKEW_MS = 5 * 60_000;
/** Nonces are remembered this long; requests older than the skew window are refused anyway. */
export const UPLOAD_NONCE_TTL_S = 15 * 60;
/** Listings priced above this multiple of the item's 30-day median, or below 1/multiple, are dropped. */
export const UPLOAD_OUTLIER_MULTIPLE = 20;
/** Scans observed further back than this are refused at the API (the ingest horizon is 90 days). */
export const UPLOAD_MAX_AGE_S = 7 * 86_400;
/** Bounds for one listing: item ids are int4 in the database; stacks never exceed a few thousand. */
export const UPLOAD_MAX_ITEM_ID = 2_147_483_647;
export const UPLOAD_MAX_QUANTITY = 10_000;
/** Copper. The gold cap is under 1e12; anything above is garbage or an overflow attempt. */
export const UPLOAD_MAX_COPPER = 10_000_000_000_000;
/** Limits for the SavedVariables reader: file size and table nesting. */
export const LUA_MAX_BYTES = 64 * 1024 * 1024;
export const LUA_MAX_DEPTH = 32;

export type UploadAuction = [
  itemId: number,
  quantity: number,
  buyout: number,
  bid: number,
  timeLeft: number,
];

export type UploadFaction = 'alliance' | 'horde';

export interface UploadScan {
  v: typeof UPLOAD_VERSION;
  /** Addon version string, e.g. "0.1.0". */
  addon: string;
  /** Game slug the uploader is playing: "forever", "classic-era". */
  game: string;
  region: Region;
  /** Realm name as the client reports it. */
  realm: string;
  faction: UploadFaction;
  /** Server time of the scan, unix seconds. */
  observedAt: number;
  /** True when the scan covered the whole auction house. */
  full: boolean;
  /** Client build, e.g. "1.15.7 (58187)". */
  build?: string;
  auctions: UploadAuction[];
}

/** Job the API enqueues for the workers after signature and market checks pass. */
export interface AddonUploadJob {
  /** upload_keys.id */
  uploadKeyId: number;
  /** Public key id; recorded as scans.uploader_id. */
  uploaderId: string;
  marketId: number;
  gameId: number;
  marketSlug: string;
  observedAt: number;
  full: boolean;
  realm: string;
  addon: string;
  build: string | null;
  /** SHA-256 of the raw request body; doubles as the scan's payload hash. */
  payloadHash: string;
  /** Base64 of the gzip-compressed upload body (the whole UploadScan JSON), exactly as received. */
  bodyGz: string;
  auctionCount: number;
}

export function uploadSigningString(ts: string, nonce: string, bodySha256Hex: string): string {
  return `AHL1\n${ts}\n${nonce}\n${bodySha256Hex}`;
}

export const UPLOAD_NONCE = /^[A-Za-z0-9_-]{8,64}$/;
export const UPLOAD_KEY_ID = /^ahl_[a-z0-9]{16}$/;

const KEY_ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789';

function randomBytesWeb(n: number): Uint8Array {
  const out = new Uint8Array(n);
  globalThis.crypto.getRandomValues(out);
  return out;
}

function base64url(bytes: Uint8Array): string {
  let bin = '';
  for (const b of bytes) bin += String.fromCharCode(b);
  const b64 = typeof btoa === 'function' ? btoa(bin) : Buffer.from(bytes).toString('base64');
  return b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/**
 * `ahl_` + 16 unbiased base-36 characters, and a 256-bit secret shown once. Uses Web Crypto so
 * it runs in Node and in the browser alike.
 */
export function generateUploadKey(): { keyId: string; secret: string } {
  let id = '';
  while (id.length < 16) {
    for (const b of randomBytesWeb(32)) {
      if (b < 252) id += KEY_ALPHABET[b % 36]!; // 252 = 7 * 36: reject the biased tail
      if (id.length === 16) break;
    }
  }
  return { keyId: `ahl_${id}`, secret: base64url(randomBytesWeb(32)) };
}

// ---------------------------------------------------------------------------------------------
// Compact scan encoding (what the addon writes)
// ---------------------------------------------------------------------------------------------

/**
 * "itemID:count:buyout:bid:timeLeft;itemID:..." Malformed entries are skipped, never fatal:
 * one bad listing must not cost a whole scan.
 */
export function parseCompactAuctions(data: string): UploadAuction[] {
  const out: UploadAuction[] = [];
  if (!data) return out;
  for (const entry of data.split(';')) {
    if (!entry) continue;
    const parts = entry.split(':');
    if (parts.length !== 5) continue;
    const nums = parts.map((p) => Number(p));
    if (!nums.every((n) => Number.isSafeInteger(n) && n >= 0)) continue;
    const [itemId, quantity, buyout, bid, timeLeft] = nums as [
      number,
      number,
      number,
      number,
      number,
    ];
    if (itemId <= 0 || itemId > UPLOAD_MAX_ITEM_ID) continue;
    if (quantity <= 0 || quantity > UPLOAD_MAX_QUANTITY) continue;
    if (buyout > UPLOAD_MAX_COPPER || bid > UPLOAD_MAX_COPPER) continue;
    out.push([itemId, quantity, buyout, bid, Math.min(timeLeft, 4)]);
  }
  return out;
}

export function encodeCompactAuctions(auctions: readonly UploadAuction[]): string {
  return auctions.map((a) => a.join(':')).join(';');
}

/** Shape uploads into the Blizzard Classic auction shape the ingest pipeline already speaks. */
export function uploadToBlizzardAuctions(
  auctions: readonly UploadAuction[],
): BlizzardClassicAuction[] {
  return auctions.map(([itemId, quantity, buyout, bid], i) => ({
    id: i + 1,
    item: { id: itemId },
    quantity,
    buyout,
    bid,
  }));
}

/**
 * Structural check for a decoded upload; the API layers zod on top for messages. Bounds keep one
 * crafted listing from overflowing int4 columns or dominating quantity-weighted percentiles.
 */
export function isUploadAuction(v: unknown): v is UploadAuction {
  if (!Array.isArray(v) || v.length !== 5) return false;
  if (!v.every((n) => Number.isSafeInteger(n) && n >= 0)) return false;
  const [itemId, quantity, buyout, bid, timeLeft] = v as number[];
  return (
    itemId! > 0 &&
    itemId! <= UPLOAD_MAX_ITEM_ID &&
    quantity! > 0 &&
    quantity! <= UPLOAD_MAX_QUANTITY &&
    buyout! <= UPLOAD_MAX_COPPER &&
    bid! <= UPLOAD_MAX_COPPER &&
    timeLeft! <= 4
  );
}

// ---------------------------------------------------------------------------------------------
// SavedVariables reader
// ---------------------------------------------------------------------------------------------

/** One scan as the addon stores it in `AHledgerDB.scans`. */
export interface SavedScan {
  realm: string;
  faction: string;
  region: string;
  /** Unix seconds (GetServerTime). */
  ts: number;
  build?: string;
  addon?: string;
  full?: boolean;
  count?: number;
  data: string;
}

export type LuaValue = null | boolean | number | string | LuaValue[] | { [k: string]: LuaValue };

/**
 * Parse the subset of Lua that WoW writes into SavedVariables files: top-level `Name = value`
 * assignments, table constructors with `[key] =`, `name =`, and positional entries, strings,
 * numbers, booleans, nil, and `--` comments. Tables whose keys are exactly 1..n become arrays.
 */
export function parseLuaSavedVariables(src: string): Record<string, LuaValue> {
  if (src.length > LUA_MAX_BYTES) {
    throw new Error(`lua parse error: input exceeds ${LUA_MAX_BYTES} bytes`);
  }
  const p = new LuaParser(src);
  const out: Record<string, LuaValue> = {};
  p.skipTrivia();
  while (!p.eof()) {
    const name = p.identifier();
    p.skipTrivia();
    p.expect('=');
    p.skipTrivia();
    out[name] = p.value();
    p.skipTrivia();
  }
  return out;
}

const NUMBER_RE = /-?(?:0[xX][0-9a-fA-F]+|\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?)/y;

class LuaParser {
  private i = 0;
  private depth = 0;
  constructor(private readonly s: string) {}

  eof(): boolean {
    return this.i >= this.s.length;
  }

  private fail(msg: string): never {
    throw new Error(`lua parse error at ${this.i}: ${msg}`);
  }

  skipTrivia(): void {
    const s = this.s;
    for (;;) {
      while (this.i < s.length && /\s/.test(s[this.i]!)) this.i++;
      if (s.startsWith('--', this.i)) {
        const nl = s.indexOf('\n', this.i);
        this.i = nl === -1 ? s.length : nl + 1;
        continue;
      }
      return;
    }
  }

  expect(ch: string): void {
    if (this.s[this.i] !== ch) this.fail(`expected "${ch}"`);
    this.i++;
  }

  identifier(): string {
    const m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(this.s.slice(this.i, this.i + 128));
    if (!m) this.fail('expected identifier');
    this.i += m[0].length;
    return m[0];
  }

  value(): LuaValue {
    const c = this.s[this.i];
    if (c === '{') return this.table();
    if (c === '"' || c === "'") return this.string(c);
    if (c === '[' && this.s[this.i + 1] === '[') return this.longString();
    const rest = this.s.slice(this.i, this.i + 64);
    if (/^true\b/.test(rest)) {
      this.i += 4;
      return true;
    }
    if (/^false\b/.test(rest)) {
      this.i += 5;
      return false;
    }
    if (/^nil\b/.test(rest)) {
      this.i += 3;
      return null;
    }
    NUMBER_RE.lastIndex = this.i;
    const num = NUMBER_RE.exec(this.s);
    if (num) {
      this.i += num[0].length;
      return Number(num[0]);
    }
    return this.fail('unexpected token');
  }

  private string(quote: string): string {
    this.i++;
    let out = '';
    const s = this.s;
    while (this.i < s.length) {
      const c = s[this.i]!;
      if (c === quote) {
        this.i++;
        return out;
      }
      if (c === '\\') {
        const n = s[this.i + 1] ?? '';
        const simple: Record<string, string> = {
          n: '\n',
          t: '\t',
          r: '\r',
          '\\': '\\',
          '"': '"',
          "'": "'",
          '\n': '\n',
          a: '\x07',
          b: '\b',
          f: '\f',
          v: '\v',
        };
        if (n in simple) {
          out += simple[n];
          this.i += 2;
          continue;
        }
        const dec = /^\d{1,3}/.exec(s.slice(this.i + 1, this.i + 4));
        if (dec) {
          out += String.fromCharCode(Number(dec[0]));
          this.i += 1 + dec[0].length;
          continue;
        }
        this.fail('bad escape');
      }
      out += c;
      this.i++;
    }
    return this.fail('unterminated string');
  }

  private longString(): string {
    const end = this.s.indexOf(']]', this.i + 2);
    if (end === -1) this.fail('unterminated long string');
    const out = this.s.slice(this.i + 2, end);
    this.i = end + 2;
    return out;
  }

  private table(): LuaValue {
    if (++this.depth > LUA_MAX_DEPTH) this.fail(`table nesting deeper than ${LUA_MAX_DEPTH}`);
    try {
      return this.tableBody();
    } finally {
      this.depth--;
    }
  }

  private tableBody(): LuaValue {
    this.expect('{');
    const entries: Array<[string | number, LuaValue]> = [];
    let positional = 1;
    for (;;) {
      this.skipTrivia();
      const c = this.s[this.i];
      if (c === '}') {
        this.i++;
        break;
      }
      if (c === undefined) this.fail('unterminated table');
      let key: string | number;
      if (c === '[' && this.s[this.i + 1] !== '[') {
        this.i++;
        this.skipTrivia();
        const k = this.value();
        if (typeof k !== 'string' && typeof k !== 'number') this.fail('bad table key');
        key = k;
        this.skipTrivia();
        this.expect(']');
        this.skipTrivia();
        this.expect('=');
        this.skipTrivia();
      } else {
        const ident = /^[A-Za-z_][A-Za-z0-9_]*\s*=/.exec(this.s.slice(this.i, this.i + 160));
        if (ident && !/^(true|false|nil)\s*=/.test(ident[0])) {
          key = this.identifier();
          this.skipTrivia();
          this.expect('=');
          this.skipTrivia();
        } else {
          key = positional++;
        }
      }
      entries.push([key, this.value()]);
      this.skipTrivia();
      const sep = this.s[this.i];
      if (sep === ',' || sep === ';') this.i++;
    }
    const isArray =
      entries.length > 0 && entries.every(([k], idx) => typeof k === 'number' && k === idx + 1);
    if (isArray) return entries.map(([, v]) => v);
    const obj: { [k: string]: LuaValue } = {};
    for (const [k, v] of entries) obj[String(k)] = v;
    return obj;
  }
}

function str(v: LuaValue | undefined): string | undefined {
  return typeof v === 'string' ? v : undefined;
}

/** Extract the scans the addon saved. Unknown shapes are skipped rather than thrown. */
export function scansFromSavedVariables(src: string): SavedScan[] {
  const root = parseLuaSavedVariables(src);
  const db = root['AHledgerDB'];
  if (!db || typeof db !== 'object' || Array.isArray(db)) return [];
  const scans = db['scans'];
  if (!Array.isArray(scans)) return [];
  const out: SavedScan[] = [];
  for (const s of scans) {
    if (!s || typeof s !== 'object' || Array.isArray(s)) continue;
    const realm = str(s['realm']);
    const faction = str(s['faction']);
    const region = str(s['region']);
    const data = str(s['data']);
    const ts = typeof s['ts'] === 'number' ? s['ts'] : undefined;
    if (!realm || !faction || !region || data === undefined || ts === undefined) continue;
    out.push({
      realm,
      faction,
      region,
      ts,
      data,
      build: str(s['build']),
      addon: str(s['addon']),
      full: typeof s['full'] === 'boolean' ? s['full'] : undefined,
      count: typeof s['count'] === 'number' ? s['count'] : undefined,
    });
  }
  return out;
}

const REGION_ALIASES: Record<string, Region> = { us: 'us', eu: 'eu', kr: 'kr', tw: 'tw' };

/**
 * Build an upload from a saved scan. Returns null when the scan cannot map onto a market. Beta
 * and PTR clients may record the region as "unknown"; `defaultRegion` fills that in.
 */
export function savedScanToUpload(
  scan: SavedScan,
  game: string,
  defaultRegion?: Region,
): UploadScan | null {
  const reported = REGION_ALIASES[scan.region.toLowerCase()] ?? defaultRegion;
  const faction = scan.faction.toLowerCase();
  if (!reported || (faction !== 'alliance' && faction !== 'horde')) return null;
  // A beta realm is a US realm whatever the client or the region setting said.
  const region = marketRegionFor(game, reported, scan.realm);
  return {
    v: UPLOAD_VERSION,
    addon: scan.addon ?? 'unknown',
    game,
    region,
    realm: scan.realm,
    faction,
    observedAt: Math.floor(scan.ts),
    full: scan.full ?? true,
    build: scan.build,
    auctions: parseCompactAuctions(scan.data),
  };
}
