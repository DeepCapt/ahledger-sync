/**
 * AHledger sync: watches the addon's SavedVariables file and uploads every new scan.
 *
 * Split of responsibilities: this webview parses the Lua file and decides what is new (the parser
 * lives in @ahledger/shared, the same code the API and CLI use); the Rust side owns the file
 * watcher, the settings file, the upload secret, the HMAC signature, and the HTTP request, so the
 * secret never has to leave native code and CORS never applies.
 */
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { open } from '@tauri-apps/plugin-dialog';
import {
  OBSERVATIONS_VERSION,
  REGIONS,
  betaFolderMove,
  isBetaClientPath,
  launchAtFor,
  ledgerFromSavedVariables,
  localeFromSavedVariables,
  sightingsFromSavedVariables,
  pvpPointsFromSavedVariables,
  type AddonLedgerEntry,
  type AddonPvpCharacter,
  type AddonSighting,
  observationOn,
  observationsFromSavedVariables,
  questsFromSavedVariables,
  parseLuaSavedVariables,
  refusalAdvice,
  savedScanToUpload,
  scansFromSavedVariables,
  type Region,
  type SavedScan,
  savedFileGameMismatch,
} from '@ahledger/shared';

/** What the native side returns: the secret never comes back, only whether one is stored. */
interface Settings {
  apiUrl: string;
  keyId: string;
  hasSecret: boolean;
  savedVariablesPath: string;
  game: string;
  /** Used when the client recorded the region as "unknown" (beta and PTR builds do). */
  region: string;
  autoUpload: boolean;
}

/** What the form sends; an empty secret keeps the stored one. */
interface SettingsInput extends Omit<Settings, 'hasSecret'> {
  secret: string;
}

interface UploadResult {
  status: number;
  body: string;
  /** Unix time the request was signed with; against the server's clock in a 401 it names a clock problem. */
  sentTs: number;
  /** Seconds sync adds to this computer's clock to sign, learned from the server (0.2.27). */
  clockOffset?: number;
}

let clockNotedAt: number | null = null;

/**
 * A signed request through the native side. A computer whose clock is more than five minutes
 * off used to have every upload refused; the native side now signs with the server's time once
 * a refusal tells it, so this only says so, once per correction, with how to fix the clock.
 */
async function signed(cmd: string, args?: Record<string, unknown>): Promise<UploadResult> {
  const res = await invoke<UploadResult>(cmd, args);
  const off = res.clockOffset ?? 0;
  if (Math.abs(off) > 120 && off !== clockNotedAt) {
    clockNotedAt = off;
    const mins = Math.round(Math.abs(off) / 60);
    const span =
      mins >= 90
        ? `${Math.round(mins / 60)} hour${Math.round(mins / 60) === 1 ? '' : 's'}`
        : `${mins} minutes`;
    log(
      `this computer's clock is ${span} ${off > 0 ? 'behind' : 'ahead'} of the real time; sync now signs with the server's time, so uploads go through. To fix the clock itself: Windows Settings, Time & language, Date & time, turn on Set time automatically and Set time zone automatically (or pick your zone), then Sync now.`,
    );
  }
  return res;
}

interface PairStarted {
  code: string;
  url: string;
  expiresIn: number;
  interval: number;
}

interface PairResult {
  status: string;
  keyId: string | null;
  message: string | null;
}

interface UpdateInfo {
  current: string;
  latest: string;
  newer: boolean;
  downloadUrl: string;
  page: string;
  released: string;
}

interface RefreshResult {
  path: string;
  markets: number;
  items: number;
  /** The newest table timestamp written, unix seconds; 0 when no market had prices. */
  newest: number;
  /** What this key added to the site over the last week, when the server answered. */
  contribution: {
    days: number;
    scans: number;
    listings: number;
    sources: number;
    quests: number;
  } | null;
  /** The account watchlist written for the addon, when the server answered. */
  watch: { linked: boolean; at: number; savedAt: number; items: number } | null;
  /** Characters in the PvP table written for the tooltip (0.2.27), when the server had one. */
  pvp?: number | null;
  /** Why the PvP table was not refreshed, when it was not. */
  pvpError?: string | null;
}

const VERSION = '0.2.28';
/** Where the saved-variables file sits, written the way this system writes paths. */
const PATH_EXAMPLE = /Macintosh|Mac OS X/.test(navigator.userAgent)
  ? '/Applications/World of Warcraft/…/WTF/Account/ACCOUNT/SavedVariables/AHledger.lua'
  : '…\\WTF\\Account\\ACCOUNT\\SavedVariables\\AHledger.lua';
const TABLE_REFRESH_MS = 30 * 60_000;
const UPLOADED_KEY = 'ahl.uploaded';
/** The release the person chose not to be reminded of; a newer one shows again. */
const UPDATE_DISMISSED_KEY = 'ahl.updateDismissed';
const UPDATE_CHECK_MS = 24 * 3600_000;
/** How often a copy still on the beta folder looks for the live client's file. */
const FOLDER_CHECK_MS = 5 * 60_000;
/** Hash of the last item source table sent, so an unchanged table is not sent again. */
const OBSERVATIONS_KEY = 'ahl.observations';
const UPLOADED_CAP = 300;
/** How long a scan the server would not place waits before it is offered again on its own. */
const DEFER_MS = 30 * 60_000;
/**
 * The site reads an uploaded scan a little after accepting it, and its price table changes
 * only then. Fetching the tables the moment an upload is accepted got the previous prices, and
 * the next fetch was half an hour away: the addon then said the scan was minutes old and the
 * prices days old. So after an upload the tables are fetched at these delays until the newest
 * table is at least as new as the scan that was sent.
 */
const AFTER_UPLOAD_DELAYS_MS = [45_000, 90_000, 180_000, 300_000];
/** Observed time (unix seconds) of the newest uploaded scan the tables do not carry yet. */
let awaitingSince = 0;
let afterUploadTimer: number | null = null;
/** Scans refused with 422, by scan key, with when they were last tried. Upload now ignores it. */
const deferred = new Map<string, number>();

const app = document.getElementById('app')!;
app.innerHTML = `
  <header class="brand"><span class="mark"></span><h1>AHledger sync</h1><span class="ver">v${VERSION}</span></header>
  <div class="update" id="update" hidden></div>

  <section>
    <h2>Upload key</h2>
    <div id="connectBox">
      <p class="hint">Press Connect, sign in on ahledger.com in the browser that opens, and approve the code shown here. Sync gets its own upload key; nothing to copy.</p>
      <div class="actions">
        <button id="connect" class="primary" type="button">Connect with ahledger.com</button>
      </div>
      <div class="status" id="connectStatus" hidden></div>
    </div>
    <details id="manualKey">
      <summary>Enter a key by hand</summary>
      <label for="keyId">Key id</label>
      <input id="keyId" type="text" placeholder="ahl_xxxxxxxxxxxxxxxx" autocomplete="off" spellcheck="false" />
      <label for="secret">Secret</label>
      <input id="secret" type="password" autocomplete="off" spellcheck="false" />
      <p class="hint" id="secretHint">From the Upload keys card on ahledger.com/account. The secret is stored on this machine only.</p>
    </details>
  </section>

  <section>
    <h2>Game client</h2>
    <label for="path">SavedVariables file</label>
    <div class="row">
      <input id="path" type="text" placeholder="${escapeHtml(PATH_EXAMPLE)}" spellcheck="false" />
      <button id="detect" type="button">Detect</button>
      <button id="browse" type="button">Browse</button>
    </div>
    <label for="game">Game</label>
    <select id="game">
      <option value="forever">World of Warcraft: Forever</option>
      <option value="classic-era">Classic Era</option>
    </select>
    <label for="region">Region</label>
    <select id="region">
      <option value="us">Americas (US)</option>
      <option value="eu">Europe (EU)</option>
      <option value="kr">Korea (KR)</option>
      <option value="tw">Taiwan (TW)</option>
      <option value="cn">China (CN)</option>
    </select>
    <p class="hint">The game reports its own region with each scan, so this is only a fallback for a scan that does not say: pick where you play. Forever has US, EU and CN markets from launch; the beta runs on US servers for everyone, so beta scans always go to the US markets.</p>
    <label class="check"><input id="auto" type="checkbox" /> Upload automatically when the file changes</label>
    <div class="actions">
      <button id="save" class="primary" type="button">Save and start</button>
      <button id="uploadNow" type="button">Upload now</button>
      <button id="testKey" type="button" title="Sends a signed test request; nothing is uploaded">Test key</button>
    </div>
  </section>

  <section>
    <h2>Price tables</h2>
    <p class="hint" id="tableHint">Downloaded from ahledger.com and written into the addon so tooltips and crafting margins stay current. Refreshed every 30 minutes and after each upload; the game reads the new file at login or /reload.</p>
    <div class="actions">
      <button id="refreshTables" type="button">Update price tables now</button>
    </div>
    <div class="status" id="tableStatus">Not refreshed yet.</div>
  </section>

  <section>
    <h2>Status</h2>
    <div class="status" id="status">Not configured.</div>
    <ul class="log" id="log"></ul>
  </section>
`;

const el = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const keyIdInput = el<HTMLInputElement>('keyId');
const secretInput = el<HTMLInputElement>('secret');
const pathInput = el<HTMLInputElement>('path');
const gameSelect = el<HTMLSelectElement>('game');
const regionSelect = el<HTMLSelectElement>('region');
const autoInput = el<HTMLInputElement>('auto');
const statusEl = el<HTMLDivElement>('status');
const logEl = el<HTMLUListElement>('log');
const tableStatusEl = el<HTMLDivElement>('tableStatus');

let settings: Settings = {
  apiUrl: 'https://api.ahledger.com',
  keyId: '',
  hasSecret: false,
  savedVariablesPath: '',
  game: 'forever',
  region: 'us',
  autoUpload: true,
};
let busy = false;
keyIdInput.addEventListener('input', () => {
  secretInput.placeholder = secretPlaceholder();
});
/** A file change that arrived while an upload was running; handled right after it. */
let rerun: string | null = null;

function log(msg: string, cls = ''): void {
  const li = document.createElement('li');
  const t = document.createElement('time');
  t.textContent = new Date().toLocaleTimeString();
  li.appendChild(t);
  const span = document.createElement('span');
  span.textContent = msg;
  if (cls) span.className = cls;
  li.appendChild(span);
  logEl.prepend(li);
  while (logEl.children.length > 100) logEl.lastChild?.remove();
}

/**
 * A refusal the player has to act on stays at the top of the status box, in red, until an
 * upload or a key test succeeds; ordinary status lines render beneath it.
 */
let problem: string | null = null;

function setStatus(html: string): void {
  statusEl.innerHTML = problem ? `<div class="problem">${problem}</div>${html}` : html;
}

function setProblem(html: string): void {
  problem = html;
  setStatus(statusEl.innerHTML.replace(/^<div class="problem">[\s\S]*?<\/div>/, ''));
}

function clearProblem(): void {
  if (problem === null) return;
  problem = null;
  setStatus(statusEl.innerHTML.replace(/^<div class="problem">[\s\S]*?<\/div>/, ''));
}

/** The server's clock from a 401 body, minus the time the request was signed with. */
function skewSeconds(res: UploadResult): number | null {
  try {
    const parsed = JSON.parse(res.body) as { serverTs?: number };
    return typeof parsed.serverTs === 'number' ? parsed.serverTs - res.sentTs : null;
  } catch {
    return null;
  }
}

/** "<summary>. <remedy>." for a refused request, capitalised for the status box. */
function describeRefusal(res: UploadResult): string {
  const cap = (s: string) => s.replace(/^\w/, (c) => c.toUpperCase());
  const a = refusalAdvice(res.status, errorText(res.body), skewSeconds(res));
  return `${cap(a.summary)}. ${cap(a.remedy)}.`;
}

function loadUploaded(): Set<string> {
  try {
    const raw = localStorage.getItem(UPLOADED_KEY);
    return new Set(raw ? (JSON.parse(raw) as string[]) : []);
  } catch {
    return new Set();
  }
}

function saveUploaded(set: Set<string>): void {
  try {
    localStorage.setItem(UPLOADED_KEY, JSON.stringify([...set].slice(-UPLOADED_CAP)));
  } catch {
    // storage is a convenience; the API dedupes by payload hash anyway
  }
}

const scanKey = (s: SavedScan) => `${s.region}|${s.realm}|${s.faction}|${s.ts}`;

function readForm(): SettingsInput {
  return {
    apiUrl: settings.apiUrl,
    keyId: keyIdInput.value.trim(),
    secret: secretInput.value.trim(),
    savedVariablesPath: pathInput.value.trim(),
    game: gameSelect.value,
    region: regionSelect.value,
    autoUpload: autoInput.checked,
  };
}

/** The stored secret belongs to the stored key id; a different id needs its own secret. */
function secretPlaceholder(): string {
  if (!settings.hasSecret) return '';
  return keyIdInput.value.trim() === settings.keyId
    ? '(stored; leave blank to keep)'
    : '(required for a different key id)';
}

function fillForm(s: Settings): void {
  keyIdInput.value = s.keyId;
  secretInput.value = '';
  secretInput.placeholder = s.hasSecret ? '(stored; leave blank to keep)' : '';
  pathInput.value = s.savedVariablesPath;
  gameSelect.value = s.game;
  regionSelect.value = s.region;
  autoInput.checked = s.autoUpload;
}

const KEY_ID = /^ahl_[a-z0-9]{16}$/;

/**
 * Why the settings cannot upload yet, in words that name the field and the mistake, or null
 * when they can. An API key from the account page (ahlk_...) looks enough like an upload key
 * that people paste it here; before this the app saved it and said nothing useful.
 */
function settingsProblem(s: {
  keyId: string;
  hasSecret: boolean;
  savedVariablesPath: string;
}): string | null {
  const id = s.keyId.trim();
  if (!id) return 'Enter the upload key id (ahl_ and 16 letters and digits), then save.';
  if (/^ahlk_/i.test(id))
    return 'That is an API key (ahlk_...), which is for the developer API. Sync needs an upload key: on ahledger.com/account, use the Upload keys card, press Create key, and paste the key id (ahl_ and 16 letters and digits) and its secret here.';
  if (!KEY_ID.test(id))
    return `The key id should be ahl_ followed by 16 lowercase letters and digits; "${id}" is not. Copy it from the Upload keys card on ahledger.com/account.`;
  if (!s.hasSecret)
    return 'Enter the secret shown when the upload key was created, then save. If it was not kept, create a new key.';
  if (!s.savedVariablesPath)
    return 'Choose the SavedVariables file (AHledger.lua) with Detect or Browse, then save.';
  return null;
}

/** The last game-mismatch message logged, so a watched file does not log it on every save. */
let lastMismatch: string | null = null;

async function uploadPending(reason: string): Promise<void> {
  if (busy) {
    rerun = reason;
    return;
  }
  const problem = settingsProblem(settings);
  if (problem) {
    setStatus(`<span class="err">${escapeHtml(problem)}</span>`);
    return;
  }
  busy = true;
  try {
    const text = await invoke<string>('read_scan_file', { path: settings.savedVariablesPath });
    forgetMarksIfIdentityChanged();
    // The ledger is the player's own record for their account page, not a contribution, so it
    // goes up whether or not scans do.
    await uploadLedger(text);
    if (!contributionOn(text)) {
      setStatus(
        `Watching <b>${escapeHtml(settings.savedVariablesPath)}</b><br/>Contribution is off in the addon settings (/ahl), so scans stay on this machine.`,
      );
      return;
    }
    const scans = scansFromSavedVariables(text);
    // Which game this file really comes from: its folder, or the build its newest scan recorded.
    // Sent under the other game, scans and item sources would land on the wrong game's markets
    // and item pages, so nothing is sent until the Game setting matches.
    const newest = [...scans].sort((a, b) => b.ts - a.ts)[0];
    const mismatch = savedFileGameMismatch({
      path: settings.savedVariablesPath,
      newestBuild: newest?.build,
      settingGame: settings.game,
    });
    if (mismatch) {
      const message = `This file is from ${mismatch.fileGame === 'forever' ? 'WoW Forever' : 'Classic Era'}, but Game is set to ${mismatch.settingGame === 'forever' ? 'WoW Forever' : 'Classic Era'}. Change Game below, or choose the other game's SavedVariables file, then press Save and start. Nothing was uploaded.`;
      setStatus(`<span class="err">${escapeHtml(message)}</span>`);
      if (lastMismatch !== message) log(message, 'err');
      lastMismatch = message;
      return;
    }
    lastMismatch = null;
    if (onStaleBetaFolder()) {
      setStatus(`<span class="err">${escapeHtml(STALE_BETA_MESSAGE)}</span>`);
      if (lastMismatch !== STALE_BETA_MESSAGE) log(STALE_BETA_MESSAGE, 'err');
      lastMismatch = STALE_BETA_MESSAGE;
      return;
    }
    // The item source table goes first and on its own terms. Up to 0.2.10 it was sent only
    // after a new scan in the same file write, so a reload that added quests or drops but no
    // scan (every scan already uploaded) never sent them, and a key could upload for weeks
    // without a single source line reaching the site.
    await uploadObservations(text, newest?.addon ?? scans[0]?.addon ?? 'unknown', newest?.build);
    await uploadSightings(text, newest?.region ?? scans[0]?.region ?? settings.region);
    await uploadPvpPoints(text);
    const uploaded = loadUploaded();
    const pending = scans.filter((s) => !uploaded.has(scanKey(s)));
    if (pending.length === 0) {
      setStatus(
        `Watching <b>${escapeHtml(settings.savedVariablesPath)}</b><br/>${scans.length} scan(s) in file, nothing new (${reason}).`,
      );
      return;
    }
    let sent = 0;
    for (const scan of pending) {
      const last = deferred.get(scanKey(scan));
      if (reason !== 'manual' && last !== undefined && Date.now() - last < DEFER_MS) continue;
      const fallback = (REGIONS as readonly string[]).includes(settings.region)
        ? (settings.region as Region)
        : 'us';
      const upload = savedScanToUpload(scan, settings.game, fallback);
      if (!upload) {
        log(
          `skipped ${scan.realm} ${scan.faction} ${scan.region}: unsupported region or faction`,
          'err',
        );
        uploaded.add(scanKey(scan));
        continue;
      }
      const res = await signed('upload_scan', { body: JSON.stringify(upload) });
      const when = new Date(upload.observedAt * 1000).toLocaleString();
      if (res.status === 202) {
        clearProblem();
        sent++;
        awaitingSince = Math.max(awaitingSince, upload.observedAt);
        uploaded.add(scanKey(scan));
        deferred.delete(scanKey(scan));
        log(
          `uploaded ${upload.realm} ${upload.faction}: ${upload.auctions.length} listings from ${when}`,
          'ok',
        );
      } else if (res.status === 422) {
        // The server did not place this scan (an unknown realm, usually). That can change on
        // the server's side, so the scan is not marked done; it is tried again by Upload now,
        // or on its own after DEFER_MS, rather than on every save of the file.
        deferred.set(scanKey(scan), Date.now());
        log(
          `not accepted yet ${upload.realm} ${upload.faction}: ${errorText(res.body)}; will try again`,
          'err',
        );
        setProblem(
          `Scan of ${escapeHtml(upload.realm)} ${upload.faction} from ${when} not placed. ${escapeHtml(describeRefusal(res))}`,
        );
      } else if (res.status === 400) {
        // The server will never accept this exact scan; do not resend it on every file change.
        uploaded.add(scanKey(scan));
        log(`rejected ${upload.realm} ${upload.faction}: ${errorText(res.body)}`, 'err');
        setProblem(
          `Scan of ${escapeHtml(upload.realm)} ${upload.faction} from ${when} refused. ${escapeHtml(describeRefusal(res))}`,
        );
      } else if (res.status === 401) {
        log(`upload key rejected: ${errorText(res.body)}`, 'err');
        setProblem(
          `Upload refused: ${escapeHtml(describeRefusal(res))} Press Test key after fixing it.`,
        );
        break;
      } else {
        log(
          `upload failed (HTTP ${res.status}): ${errorText(res.body)}; will retry on the next change`,
          'err',
        );
        setProblem(`Upload failed. ${escapeHtml(describeRefusal(res))}`);
      }
    }
    saveUploaded(uploaded);
    setStatus(
      `Watching <b>${escapeHtml(settings.savedVariablesPath)}</b><br/>last check ${new Date().toLocaleTimeString()} (${reason}).`,
    );
    if (sent > 0) scheduleAfterUpload(0);
  } catch (err) {
    log(`error: ${String(err)}`, 'err');
    setStatus(`<span class="err">${escapeHtml(String(err))}</span>`);
  } finally {
    busy = false;
    if (rerun) {
      const why = rerun;
      rerun = null;
      void uploadPending(why);
    }
  }
}

/** The addon's own switch: AHledgerDB.settings.contribute. Missing means on (older addon). */
/** A small stable hash for change detection; not security. */
function hashOf(s: string): string {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0).toString(16) + ':' + s.length;
}

/** Hash of the last Rank Points log sent, so an unchanged log is not sent again. */
const PVP_POINTS_KEY = 'ahl.pvpPoints';

/**
 * The Rank Points the addon read on the player's own characters (addon 0.13.0): sent whole
 * whenever the log changed, so the site can show each character's progress to the next rank and
 * what a battleground is worth. Characters on US and EU only, like the ladder. Sent with the
 * key alone; the site keeps the readings against the character, not the account.
 */
async function uploadPvpPoints(text: string): Promise<void> {
  // The addon's own switch: off, nothing goes, whatever it noted before.
  if (!addonSettingOn(text, 'pvpPoints')) return;
  let chars: AddonPvpCharacter[];
  try {
    chars = pvpPointsFromSavedVariables(text);
  } catch {
    return;
  }
  if (chars.length === 0) return;
  const payload = JSON.stringify({ v: 1, game: gameSlug(), chars });
  const hash = hashOf(payload);
  let last: string | null = null;
  try {
    last = localStorage.getItem(PVP_POINTS_KEY);
  } catch {
    last = null;
  }
  if (last === hash) return;
  const remember = () => {
    try {
      localStorage.setItem(PVP_POINTS_KEY, hash);
    } catch {
      // a lost hash only costs one extra send
    }
  };
  try {
    const res = await signed('upload_pvp_points', { body: payload });
    if (res.status === 200) {
      const parsed = JSON.parse(res.body) as {
        characters?: number;
        added?: number;
        deferred?: number;
        refused?: number;
      };
      log(
        `rank points: ${parsed.added ?? 0} new reading(s) for ${parsed.characters ?? 0} character(s)`,
        'ok',
      );
      if (parsed.refused) {
        log(
          `rank points: ${parsed.refused} character(s) already carry another account's Rank Points on ahledger.com; theirs stay until that account stops sending for two weeks`,
        );
      }
      // Readings the server could not take today go again on a later sync.
      if (parsed.deferred) {
        log(`rank points: ${parsed.deferred} reading(s) held back for now; sent again later`);
      } else {
        remember();
      }
    } else if (res.status === 400) {
      log(`rank points refused: ${errorText(res.body)}`, 'err');
      remember();
    } else if (res.status !== 404) {
      log(`rank points not sent (HTTP ${res.status}): ${errorText(res.body)}; will retry`, 'err');
    }
  } catch (err) {
    log(`rank points not sent: ${String(err)}`, 'err');
  }
}

/** Hash of the last sightings table sent, so an unchanged table is not sent again. */
const SIGHTINGS_KEY = 'ahl.sightings';

/**
 * The players the addon saw (0.12.0): names with faction, class, level and ruleset, sent whole
 * whenever the table changed. New names join the PvP ladder on ahledger.com; the server keeps
 * nothing about who saw them. US and EU only: the ladder reads Blizzard's profile API, which
 * covers those two regions.
 */
async function uploadSightings(text: string, region: string): Promise<void> {
  if (region !== 'us' && region !== 'eu') return;
  let items: AddonSighting[];
  try {
    items = sightingsFromSavedVariables(text);
  } catch {
    return;
  }
  if (items.length === 0) return;
  const payload = JSON.stringify({ v: 1, region, items });
  const hash = hashOf(payload);
  let last: string | null = null;
  try {
    last = localStorage.getItem(SIGHTINGS_KEY);
  } catch {
    last = null;
  }
  if (last === hash) return;
  try {
    const res = await signed('upload_sightings', { body: payload });
    if (res.status === 200) {
      const parsed = JSON.parse(res.body) as { added?: number };
      log(
        `players seen: ${items.length} names sent, ${parsed.added ?? 0} new to the PvP ladder`,
        'ok',
      );
      try {
        localStorage.setItem(SIGHTINGS_KEY, hash);
      } catch {
        // a lost hash only costs one extra send
      }
    } else if (res.status === 400) {
      log(`players seen refused: ${errorText(res.body)}`, 'err');
      try {
        localStorage.setItem(SIGHTINGS_KEY, hash);
      } catch {
        // as above
      }
    } else if (res.status !== 404) {
      log(`players seen not sent (HTTP ${res.status}): ${errorText(res.body)}; will retry`, 'err');
    }
  } catch (err) {
    log(`players seen not sent: ${String(err)}`, 'err');
  }
}

/** Hash of the last ledger sent, so an unchanged ledger is not sent again. */
const LEDGER_KEY = 'ahl.ledger';

/**
 * The addon's auction ledger (0.11.0): posts, sales, purchases, expiries and cancellations,
 * sent whole whenever it changed. The server stores each entry once, so a resend adds nothing;
 * the hash saves the round trip. A key with no account is told so once per change.
 */
async function uploadLedger(text: string): Promise<void> {
  let entries: AddonLedgerEntry[];
  try {
    entries = ledgerFromSavedVariables(text);
  } catch {
    return;
  }
  if (entries.length === 0) return;
  const payload = JSON.stringify({ v: 1, game: gameSlug(), entries });
  const hash = hashOf(payload);
  let last: string | null = null;
  try {
    last = localStorage.getItem(LEDGER_KEY);
  } catch {
    last = null;
  }
  if (last === hash) return;
  try {
    const res = await signed('upload_ledger', { body: payload });
    if (res.status === 200) {
      const parsed = JSON.parse(res.body) as { linked?: boolean; stored?: number };
      if (parsed.linked === false) {
        // Not remembered as sent: once the key is paired, the next tick sends it for real.
        if (last !== 'unlinked') {
          log('ledger: this key is not paired with an account, so your sales stay in game only');
        }
        try {
          localStorage.setItem(LEDGER_KEY, 'unlinked');
        } catch {
          // nothing to remember
        }
        return;
      }
      log(
        `ledger: ${entries.length} entries sent, ${parsed.stored ?? 0} new on your account page`,
        'ok',
      );
      try {
        localStorage.setItem(LEDGER_KEY, hash);
      } catch {
        // a lost hash only costs one extra send
      }
    } else if (res.status === 400) {
      log(`ledger refused: ${errorText(res.body)}`, 'err');
      try {
        localStorage.setItem(LEDGER_KEY, hash);
      } catch {
        // as above
      }
    } else if (res.status !== 404) {
      log(`ledger not sent (HTTP ${res.status}): ${errorText(res.body)}; will retry`, 'err');
    }
  } catch (err) {
    log(`ledger not sent: ${String(err)}`, 'err');
  }
}

/**
 * The addon's item source table (what dropped from what, vendor stock, quest rewards), sent
 * whole whenever it changed. The server keeps counts as maxima per line, so sending the same
 * table again would change nothing; the hash just saves the round trip.
 */
async function uploadObservations(text: string, addon: string, build?: string): Promise<void> {
  if (!observationOn(text)) return;
  const records = observationsFromSavedVariables(text);
  const quests = questsFromSavedVariables(text);
  const locale = localeFromSavedVariables(text);
  if (records.length === 0 && quests.length === 0) return;
  const payload = JSON.stringify([records, quests]);
  const hash = hashOf(payload);
  let last: string | null = null;
  try {
    last = localStorage.getItem(OBSERVATIONS_KEY);
  } catch {
    last = null;
  }
  if (last === hash) return;
  const body = {
    v: OBSERVATIONS_VERSION,
    addon,
    game: settings.game,
    observedAt: Math.floor(Date.now() / 1000),
    ...(build ? { build } : {}),
    records,
    ...(quests.length > 0 ? { quests } : {}),
    // The client language: the site keeps names only from English clients.
    ...(locale ? { locale } : {}),
  };
  try {
    const res = await signed('upload_observations', { body: JSON.stringify(body) });
    if (res.status === 202) {
      const parsed = JSON.parse(res.body) as { records?: number; dropped?: number };
      log(
        `item sources: ${(parsed.records ?? records.length).toLocaleString()} lines${quests.length ? ` and ${quests.length} quests` : ''} sent${parsed.dropped ? ` (${parsed.dropped} skipped)` : ''}`,
        'ok',
      );
      try {
        localStorage.setItem(OBSERVATIONS_KEY, hash);
      } catch {
        // a lost hash only costs one extra send
      }
    } else if (res.status === 400) {
      // Never going to be accepted as it stands: do not resend on every save.
      log(`item sources refused: ${errorText(res.body)}`, 'err');
      try {
        localStorage.setItem(OBSERVATIONS_KEY, hash);
      } catch {
        // as above
      }
    } else {
      log(`item sources not sent (HTTP ${res.status}): ${errorText(res.body)}; will retry`, 'err');
    }
  } catch (err) {
    log(`item sources not sent: ${String(err)}`, 'err');
  }
}

/**
 * An addon switch from the saved file; true when the file does not say (an addon from before
 * the switch existed sends nothing it would govern anyway).
 */
function addonSettingOn(luaText: string, key: string): boolean {
  try {
    const root = parseLuaSavedVariables(luaText);
    const db = root['AHledgerDB'];
    if (!db || typeof db !== 'object' || Array.isArray(db)) return true;
    const settings = (db as Record<string, unknown>)['settings'];
    if (!settings || typeof settings !== 'object' || Array.isArray(settings)) return true;
    return (settings as Record<string, unknown>)[key] !== false;
  } catch {
    return true;
  }
}

/**
 * The region the saved file last played on: the newest of its scans and its Rank Points
 * readings, so a player who moved region and has not scanned yet still gets the right PvP table.
 */
function playedRegion(text: string): 'us' | 'eu' | null {
  let best: { at: number; region: string } | null = null;
  for (const s of scansFromSavedVariables(text)) {
    if (!best || s.ts > best.at) best = { at: s.ts, region: s.region };
  }
  try {
    for (const c of pvpPointsFromSavedVariables(text)) {
      for (const r of c.log) if (!best || r.t > best.at) best = { at: r.t, region: c.region };
    }
  } catch {
    // no readings: the scans decide
  }
  return best?.region === 'us' || best?.region === 'eu' ? best.region : null;
}

function contributionOn(luaText: string): boolean {
  try {
    const root = parseLuaSavedVariables(luaText);
    const db = root['AHledgerDB'];
    if (!db || typeof db !== 'object' || Array.isArray(db)) return true;
    const settings = (db as Record<string, unknown>)['settings'];
    if (!settings || typeof settings !== 'object' || Array.isArray(settings)) return true;
    return (settings as Record<string, unknown>)['contribute'] !== false;
  } catch {
    return true;
  }
}

/** When the saved file the server last read was written, so only newer watch changes are sent. */
const WATCH_SINCE_KEY = 'ahl.watchSince';
/** The key id and file the stored marks belong to; a change clears them (0.2.26). */
const IDENTITY_KEY = 'ahl.identity';

/**
 * Every "already sent" mark (scans, item sources, the ledger, the sightings, the watch mark)
 * describes one key on one saved file. Pair a different key, or point sync at another file, and
 * the marks would say the new account already has what it has never seen; so they go.
 */
function forgetMarksIfIdentityChanged(): void {
  const identity = `${settings.keyId}|${settings.savedVariablesPath}`;
  try {
    if (localStorage.getItem(IDENTITY_KEY) === identity) return;
    for (const k of [
      UPLOADED_KEY,
      OBSERVATIONS_KEY,
      LEDGER_KEY,
      SIGHTINGS_KEY,
      PVP_POINTS_KEY,
      WATCH_SINCE_KEY,
    ]) {
      localStorage.removeItem(k);
    }
    localStorage.setItem(IDENTITY_KEY, identity);
  } catch {
    // no storage: nothing was remembered either
  }
}

interface WatchPayload {
  since: number;
  savedAt: number;
  items: Array<{ id: number; addedAt?: number }>;
  removed: Array<{ id: number; at: number }>;
}

/**
 * The addon's watchlist as the saved file holds it (addon 0.10.0): every watched item with
 * when it was added, the removal notes, and when the file was written. Null when the file has
 * no watch table or the addon's watchSync switch is off, in which case nothing is sent and the
 * data file carries no list. Pure apart from the stored `since`.
 */
export function watchPayloadFrom(luaText: string, since: number): WatchPayload | null {
  let root: Record<string, unknown>;
  try {
    root = parseLuaSavedVariables(luaText) as Record<string, unknown>;
  } catch {
    return null;
  }
  const db = root['AHledgerDB'];
  if (!db || typeof db !== 'object' || Array.isArray(db)) return null;
  const d = db as Record<string, unknown>;
  const s = d['settings'];
  if (
    s &&
    typeof s === 'object' &&
    !Array.isArray(s) &&
    (s as Record<string, unknown>)['watchSync'] === false
  ) {
    return null;
  }
  const watch = d['watch'];
  if (!watch || typeof watch !== 'object' || Array.isArray(watch)) return null;
  const id = (k: string) => {
    const n = Number(k);
    return Number.isInteger(n) && n > 0 && n < 100_000_000 ? n : null;
  };
  const items: WatchPayload['items'] = [];
  for (const [k, v] of Object.entries(watch as Record<string, unknown>)) {
    const n = id(k);
    if (n === null) continue;
    const addedAt = v && typeof v === 'object' ? (v as Record<string, unknown>)['addedAt'] : null;
    items.push(
      typeof addedAt === 'number' && addedAt > 0
        ? { id: n, addedAt: Math.floor(addedAt) }
        : { id: n },
    );
  }
  const removed: WatchPayload['removed'] = [];
  const rm = d['watchRemoved'];
  if (rm && typeof rm === 'object' && !Array.isArray(rm)) {
    for (const [k, v] of Object.entries(rm as Record<string, unknown>)) {
      const n = id(k);
      if (n !== null && typeof v === 'number' && v > 0) removed.push({ id: n, at: Math.floor(v) });
    }
  }
  const savedAt =
    typeof d['savedAt'] === 'number' && d['savedAt'] > 0 ? Math.floor(d['savedAt']) : 0;
  return { since: Math.max(0, Math.floor(since) || 0), savedAt, items, removed };
}

/** The game sync is set to, in the words the API uses. */
function gameSlug(): 'forever' | 'classic-era' {
  return settings.game === 'classic-era' ? 'classic-era' : 'forever';
}

function watchSince(): number {
  try {
    return Number(localStorage.getItem(WATCH_SINCE_KEY) ?? 0) || 0;
  } catch {
    return 0;
  }
}

let refreshing = false;
async function refreshTables(reason: string): Promise<RefreshResult | null> {
  if (refreshing || !settings.savedVariablesPath) return null;
  refreshing = true;
  try {
    // The watchlist rides along: what the saved file holds goes up, the account's list comes
    // back in the data file. A file that cannot be read sends nothing.
    forgetMarksIfIdentityChanged();
    let watch: string | null = null;
    // The PvP table follows the region the saved file plays on; the setting stands in.
    let region: string = settings.region;
    try {
      const text = await invoke<string>('read_scan_file', { path: settings.savedVariablesPath });
      const payload = watchPayloadFrom(text, watchSince());
      if (payload) watch = JSON.stringify({ ...payload, game: gameSlug() });
      region = playedRegion(text) ?? region;
    } catch {
      watch = null;
    }
    const res = await invoke<RefreshResult>('refresh_price_tables', { watch, region });
    if (res.watch?.linked) {
      try {
        // The mark is the saved file the server has now processed: a change stamped in game
        // after that file was written is newer than it, whatever the clock said when sync ran.
        localStorage.setItem(WATCH_SINCE_KEY, String(res.watch.savedAt));
      } catch {
        // a lost mark only resends the same changes, which the server applies once
      }
      log(`watchlist: ${res.watch.items} item(s) in step with your account`);
    } else if (res.watch && !res.watch.linked) {
      log(
        'watchlist: this key is not paired with an account, so the in-game list stays on its own',
      );
    }
    if (res.newest >= awaitingSince) awaitingSince = 0;
    tableStatusEl.innerHTML = `${res.items.toLocaleString()} prices across ${res.markets} market(s) written to <b>${escapeHtml(res.path)}</b><br/>at ${new Date().toLocaleTimeString()} (${reason}). Type /reload in game to pick them up.`;
    log(
      `price tables updated: ${res.items.toLocaleString()} prices, ${res.markets} market(s)`,
      'ok',
    );
    if (res.pvp) {
      log(`PvP table: ${res.pvp.toLocaleString()} ${region.toUpperCase()} players for the tooltip`);
    }
    if (res.pvpError) {
      log(
        `PvP table not refreshed (${res.pvpError})${res.pvp ? '; the last one is kept' : ''}`,
        res.pvp ? '' : 'err',
      );
    }
    if (res.contribution) {
      const c = res.contribution;
      log(
        `your last ${c.days} days on the site: ${c.scans} scan(s), ${c.listings.toLocaleString()} listings, ${c.sources.toLocaleString()} item source lines, ${c.quests} quest(s); the addon shows this on its ledger bar`,
      );
    }
    return res;
  } catch (err) {
    tableStatusEl.innerHTML = `<span class="err">${escapeHtml(String(err))}</span>`;
    log(`price tables: ${String(err)}`, 'err');
    return null;
  } finally {
    refreshing = false;
  }
}

/** Fetches the tables after an upload, again and again until they carry the uploaded scan. */
function scheduleAfterUpload(attempt: number): void {
  if (afterUploadTimer !== null) window.clearTimeout(afterUploadTimer);
  const delay = AFTER_UPLOAD_DELAYS_MS[attempt];
  if (delay === undefined) {
    afterUploadTimer = null;
    log(
      'the uploaded scan is not in the price tables yet; the next scheduled update will carry it',
    );
    return;
  }
  afterUploadTimer = window.setTimeout(async () => {
    afterUploadTimer = null;
    await refreshTables('after upload');
    if (awaitingSince > 0) scheduleAfterUpload(attempt + 1);
  }, delay);
}

function errorText(body: string): string {
  try {
    const parsed = JSON.parse(body) as { error?: string };
    return parsed.error ?? body.slice(0, 120);
  } catch {
    return body.slice(0, 120) || 'no response body';
  }
}

function escapeHtml(s: string): string {
  return s.replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!,
  );
}

const STALE_BETA_MESSAGE =
  'This file is in the beta folder (_classic_beta_). Forever is live and the game now saves scans under _forever_, so this file will not change again. Install AHledger in the live game, log in once, and sync moves to the new file by itself within a few minutes (or press Detect, then Save and start). Nothing was uploaded.';

/** Watching the beta client's file for Forever after launch: the game no longer writes to it. */
function onStaleBetaFolder(): boolean {
  return (
    settings.game === 'forever' &&
    isBetaClientPath(settings.savedVariablesPath) &&
    Date.now() >= launchAtFor(settings.region)
  );
}

/**
 * A path saved during the beta keeps pointing at `_classic_beta_`, which the game stopped writing
 * at launch, so a copy set up then sat idle and said nothing. When the live client has an
 * AHledger file, move to it and start watching there. True when it moved.
 */
async function moveOffBetaFolder(): Promise<boolean> {
  if (!onStaleBetaFolder()) return false;
  let candidates: string[] = [];
  try {
    candidates = await invoke<string[]>('detect_saved_variables');
  } catch {
    return false;
  }
  const move = betaFolderMove({
    path: settings.savedVariablesPath,
    candidates,
    settingGame: settings.game,
    region: settings.region,
  });
  if (move === null || move === 'stale') return false;
  const from = settings.savedVariablesPath;
  // Saved from the stored settings, not the form, so a half-typed field is not saved with it.
  try {
    settings = await invoke<Settings>('save_settings', {
      settings: {
        apiUrl: settings.apiUrl,
        keyId: settings.keyId,
        secret: '',
        savedVariablesPath: move.to,
        game: settings.game,
        region: settings.region,
        autoUpload: settings.autoUpload,
      } satisfies SettingsInput,
    });
  } catch (err) {
    log(`could not move to ${move.to}: ${String(err)}`, 'err');
    return false;
  }
  pathInput.value = settings.savedVariablesPath;
  log(`Forever is live and saves scans under _forever_: moved from ${from} to ${move.to}`, 'ok');
  await startWatching();
  return true;
}

async function startWatching(): Promise<void> {
  if (!settings.savedVariablesPath) return;
  // Moving starts watching the new file itself.
  if (await moveOffBetaFolder()) return;
  await invoke('watch_file', { path: settings.savedVariablesPath });
  log(`watching ${settings.savedVariablesPath}`);
  await uploadPending('startup');
  void refreshTables('startup');
}

el<HTMLButtonElement>('refreshTables').addEventListener('click', async () => {
  if (await save()) void refreshTables('manual');
});
setInterval(() => void refreshTables('scheduled'), TABLE_REFRESH_MS);

el<HTMLButtonElement>('detect').addEventListener('click', async () => {
  const found = await invoke<string[]>('detect_saved_variables');
  if (found.length === 0) {
    log('no AHledger.lua found under the usual World of Warcraft folders; use Browse', 'err');
    return;
  }
  pathInput.value = found[0]!;
  if (found.length > 1) log(`found ${found.length} candidates, using the first: ${found[0]}`);
  else log(`found ${found[0]}`);
});

el<HTMLButtonElement>('browse').addEventListener('click', async () => {
  const picked = await open({
    multiple: false,
    directory: false,
    title: 'Select AHledger.lua',
    filters: [{ name: 'SavedVariables', extensions: ['lua'] }],
  });
  if (typeof picked === 'string') pathInput.value = picked;
});

async function save(): Promise<boolean> {
  try {
    settings = await invoke<Settings>('save_settings', { settings: readForm() });
    fillForm(settings);
    const problem = settingsProblem(settings);
    if (problem) {
      log(`settings saved, but: ${problem}`, 'err');
      setStatus(`<span class="err">${escapeHtml(problem)}</span>`);
    } else log('settings saved');
    return true;
  } catch (err) {
    log(`could not save settings: ${String(err)}`, 'err');
    return false;
  }
}

el<HTMLButtonElement>('save').addEventListener('click', async () => {
  if (!(await save())) return;
  try {
    await startWatching();
  } catch (err) {
    log(`could not watch the file: ${String(err)}`, 'err');
    setStatus(`<span class="err">${escapeHtml(String(err))}</span>`);
  }
});

// Save first: the native side uploads with the stored settings, not the form.
el<HTMLButtonElement>('uploadNow').addEventListener('click', async () => {
  if (await save()) void uploadPending('manual');
});

// A signed request over a tiny body: the server checks it like an upload and answers with its
// clock, so a wrong secret, a revoked key or a clock that is off shows before the first scan.
el<HTMLButtonElement>('testKey').addEventListener('click', async () => {
  if (!(await save())) return;
  const problem = settingsProblem(settings);
  if (problem) {
    log(problem, 'err');
    setStatus(`<span class="err">${escapeHtml(problem)}</span>`);
    return;
  }
  try {
    const res = await signed('check_key');
    if (res.status === 200) {
      const parsed = JSON.parse(res.body) as { label?: string | null; skewSeconds?: number };
      const skew = Math.abs(parsed.skewSeconds ?? 0);
      clearProblem();
      const label = parsed.label ? ` (${parsed.label})` : '';
      log(`key ${settings.keyId}${label} accepted; clock within ${skew}s of the server`, 'ok');
      setStatus(
        `<span class="ok">Key accepted${escapeHtml(label)}. Clock within ${skew}s of the server.</span> Uploads from this machine will be taken.`,
      );
    } else {
      log(`key test refused (HTTP ${res.status}): ${errorText(res.body)}`, 'err');
      setProblem(`Key test refused. ${escapeHtml(describeRefusal(res))}`);
    }
  } catch (err) {
    log(`key test failed: ${String(err)}`, 'err');
    setProblem(
      `Key test failed: ${escapeHtml(String(err))}. Check the internet connection and try again.`,
    );
  }
});

/**
 * Connect: the native side starts a request and opens the approval page; this polls until the
 * player approves it on the site, then reloads the settings (now holding the new key), saves the
 * rest of the form, starts watching and tests the key. The secret never passes through here.
 */
const connectButton = el<HTMLButtonElement>('connect');
const connectStatus = el<HTMLDivElement>('connectStatus');
let connectTimer: number | null = null;

function showConnect(html: string): void {
  connectStatus.hidden = false;
  connectStatus.innerHTML = html;
}

function stopConnect(): void {
  if (connectTimer !== null) window.clearTimeout(connectTimer);
  connectTimer = null;
  connectButton.disabled = false;
}

connectButton.addEventListener('click', async () => {
  connectButton.disabled = true;
  try {
    const started = await invoke<PairStarted>('pair_start');
    showConnect(
      `Approve this code on ahledger.com: <b class="code">${escapeHtml(started.code)}</b><br/>A browser tab should have opened at <b>${escapeHtml(started.url)}</b>. Sign in there and press Approve. The code lasts ten minutes.`,
    );
    const deadline = Date.now() + started.expiresIn * 1000;
    let retries = 0;
    const tick = async (): Promise<void> => {
      try {
        const r = await invoke<PairResult>('pair_poll');
        if (r.status === 'approved') {
          stopConnect();
          // The new key is already in the settings file. Put its id in the form and save the
          // rest of the form as it stands, so a path found with Detect but not saved yet is kept.
          const fresh = await invoke<Settings>('get_settings');
          keyIdInput.value = fresh.keyId;
          secretInput.value = '';
          secretInput.placeholder = '(stored; leave blank to keep)';
          log(`connected: upload key ${r.keyId ?? ''} received from ahledger.com`, 'ok');
          const saved = await save();
          if (saved && !settingsProblem(settings)) {
            showConnect(
              `<span class="ok">Connected as key ${escapeHtml(r.keyId ?? '')}.</span> Sync is watching the game file; scan the auction house and /reload.`,
            );
            await startWatching();
          } else {
            showConnect(
              `<span class="ok">Connected as key ${escapeHtml(r.keyId ?? '')}.</span> Choose the SavedVariables file below with Detect, then press Save and start.`,
            );
          }
          return;
        }
        if (r.status === 'retry') {
          // A passing problem: keep the code alive and try again, a little slower each time.
          retries += 1;
          showConnect(
            `Approve this code on ahledger.com: <b class="code">${escapeHtml(started.code)}</b><br/><span class="err">${escapeHtml(r.message ?? 'ahledger.com did not answer')}</span>; still trying.`,
          );
          if (Date.now() > deadline) {
            stopConnect();
            await invoke('pair_cancel');
            showConnect(
              '<span class="err">The code expired before it was approved.</span> Press Connect to get a new one.',
            );
            return;
          }
          connectTimer = window.setTimeout(
            () => void tick(),
            Math.min(started.interval * 1000 * 2 ** Math.min(retries, 3), 20_000),
          );
          return;
        }
        retries = 0;
        if (
          r.status === 'denied' ||
          r.status === 'expired' ||
          r.status === 'consumed' ||
          r.status === 'cancelled' ||
          r.status === 'unknown'
        ) {
          stopConnect();
          showConnect(
            `<span class="err">The request was ${escapeHtml(r.status)}.</span> Press Connect to try again.`,
          );
          return;
        }
        if (Date.now() > deadline) {
          stopConnect();
          await invoke('pair_cancel');
          showConnect(
            '<span class="err">The code expired before it was approved.</span> Press Connect to get a new one.',
          );
          return;
        }
        connectTimer = window.setTimeout(() => void tick(), started.interval * 1000);
      } catch (err) {
        stopConnect();
        showConnect(`<span class="err">${escapeHtml(String(err))}</span>`);
      }
    };
    connectTimer = window.setTimeout(() => void tick(), started.interval * 1000);
  } catch (err) {
    stopConnect();
    showConnect(
      `<span class="err">${escapeHtml(String(err))}</span> Check the internet connection and press Connect again.`,
    );
  }
});

void listen<string>('scan-file-changed', () => {
  if (settings.autoUpload) void uploadPending('file changed');
  else setStatus('File changed; automatic upload is off. Press Upload now.');
});

/**
 * Once a day, ask the site which release is current and offer it when it is newer than this
 * build. A release then announces itself to everyone running sync; nobody has to be emailed.
 */
async function checkForUpdate(): Promise<void> {
  const box = el<HTMLDivElement>('update');
  try {
    const info = await invoke<UpdateInfo>('check_for_update');
    if (!info.newer) {
      box.hidden = true;
      return;
    }
    let dismissed: string | null = null;
    try {
      dismissed = localStorage.getItem(UPDATE_DISMISSED_KEY);
    } catch {
      dismissed = null;
    }
    if (dismissed === info.latest) return;
    box.innerHTML = `<span><b>AHledger sync ${escapeHtml(info.latest)}</b> is available${info.released ? ` (released ${escapeHtml(info.released)})` : ''}; you are on ${escapeHtml(info.current)}. Install it over this one; your settings and key stay.</span><span class="actions"><button type="button" id="updateOpen">Download</button><button type="button" id="updateLater">Later</button></span>`;
    box.hidden = false;
    el<HTMLButtonElement>('updateOpen').addEventListener('click', () => {
      void invoke('open_site_url', { url: info.page || 'https://ahledger.com/download' }).catch(
        (err) =>
          log(
            `could not open the browser: ${String(err)}. Go to https://ahledger.com/download`,
            'err',
          ),
      );
    });
    el<HTMLButtonElement>('updateLater').addEventListener('click', () => {
      box.hidden = true;
      try {
        localStorage.setItem(UPDATE_DISMISSED_KEY, info.latest);
      } catch {
        // then it shows again next start, which is fine
      }
    });
    log(`sync ${info.latest} is available; you are on ${info.current}`);
  } catch (err) {
    // No network, or the site is down: nothing to say; tried again tomorrow.
    log(`update check skipped: ${String(err)}`);
  }
}

(async () => {
  try {
    settings = await invoke<Settings>('get_settings');
    fillForm(settings);
    const problem = settingsProblem(settings);
    if (!problem) await startWatching();
    else setStatus(`<span class="err">${escapeHtml(problem)}</span>`);
  } catch (err) {
    setStatus(`<span class="err">${escapeHtml(String(err))}</span>`);
  }
  void checkForUpdate();
  setInterval(() => void checkForUpdate(), UPDATE_CHECK_MS);
  // A player who installs the addon in the live client after starting sync is picked up here.
  setInterval(() => {
    if (onStaleBetaFolder() && !busy) void moveOffBetaFolder();
  }, FOLDER_CHECK_MS);
})();
