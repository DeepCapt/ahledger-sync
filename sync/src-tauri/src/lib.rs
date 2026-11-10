//! Native side of AHledger sync.
//!
//! Owns everything the webview should not: the settings file (including the upload secret), the
//! SavedVariables watcher, request signing, and the HTTPS upload. The webview parses the Lua file
//! and decides what to send; it never receives the secret back after the user types it.

use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicI64, Ordering},
        Mutex,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use base64::Engine;
use hmac::{Hmac, Mac};
use notify::RecursiveMode;
use notify_debouncer_mini::{new_debouncer, DebounceEventResult, Debouncer};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tauri::{AppHandle, Emitter, Manager, State};

const DEFAULT_API_URL: &str = "https://api.ahledger.com";
const DEFAULT_GAME: &str = "forever";
const DEFAULT_REGION: &str = "us";
const SAVED_VARIABLES_FILE: &str = "AHledger.lua";

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub api_url: String,
    pub key_id: String,
    pub secret: String,
    pub saved_variables_path: String,
    pub game: String,
    /// Stands in when the client recorded the region as "unknown" (beta and PTR builds do).
    pub region: String,
    pub auto_upload: bool,
}

impl Settings {
    fn with_defaults(mut self) -> Self {
        if self.api_url.trim().is_empty() {
            self.api_url = DEFAULT_API_URL.to_string();
        }
        if self.game.trim().is_empty() {
            self.game = DEFAULT_GAME.to_string();
        }
        if self.region.trim().is_empty() {
            self.region = DEFAULT_REGION.to_string();
        }
        self
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UploadResult {
    pub status: u16,
    pub body: String,
    /// The unix time the request was signed with, so the webview can compare it with the
    /// server's clock in a 401 and name a clock problem exactly.
    pub sent_ts: u64,
    /// Seconds added to this computer's clock to sign requests (0.2.27): the server's clock less
    /// this one's, learned from a refusal. Zero while the clock is right.
    pub clock_offset: i64,
}

/// The correction learned from the server's clock (0.2.27). A computer whose clock is off by more
/// than the server's five-minute window (often a wrong time zone with the time set by hand to
/// look right, which leaves the real time hours out) had every upload refused. Requests are now
/// signed with this added, and a refusal for the clock sets it from the time the server sends
/// back and tries once more. The server still checks the time window and the nonce, so a
/// captured request cannot be replayed any later than before.
static CLOCK_OFFSET: AtomicI64 = AtomicI64::new(0);

/// The correction a response asks for: on a 401 for the clock window whose body carries the
/// server's clock, that clock less the unix time this computer read when signing. Pure.
fn clock_correction(status: u16, body: &str, local_ts: i64) -> Option<i64> {
    if status != 401 || !body.contains("clock window") {
        return None;
    }
    let parsed: serde_json::Value = serde_json::from_str(body).ok()?;
    let server_ts = parsed.get("serverTs")?.as_i64()?;
    // A server answer outside 2020..2100 is not a clock to follow.
    if !(1_577_836_800..=4_102_444_800).contains(&server_ts) {
        return None;
    }
    Some(server_ts - local_ts)
}

#[derive(Default)]
struct AppState {
    watcher: Mutex<Option<Debouncer<notify::RecommendedWatcher>>>,
    /// The token of a Connect request in progress. It stays on the native side: the webview only
    /// ever sees the code to show and the result.
    pair_token: Mutex<Option<String>>,
}

fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

fn settings_path(app: &AppHandle) -> Result<PathBuf, String> {
    let dir = app.path().app_config_dir().map_err(err)?;
    fs::create_dir_all(&dir).map_err(err)?;
    Ok(dir.join("settings.json"))
}

fn load_settings(app: &AppHandle) -> Result<Settings, String> {
    let path = settings_path(app)?;
    if !path.exists() {
        return Ok(Settings {
            auto_upload: true,
            ..Settings::default()
        }
        .with_defaults());
    }
    let raw = fs::read_to_string(&path).map_err(err)?;
    let parsed: Settings = serde_json::from_str(&raw).map_err(err)?;
    Ok(parsed.with_defaults())
}

/** What the webview sees: everything but the secret itself. */
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PublicSettings {
    pub api_url: String,
    pub key_id: String,
    pub has_secret: bool,
    pub saved_variables_path: String,
    pub game: String,
    pub region: String,
    pub auto_upload: bool,
}

impl From<Settings> for PublicSettings {
    fn from(s: Settings) -> Self {
        PublicSettings {
            api_url: s.api_url,
            key_id: s.key_id,
            has_secret: !s.secret.is_empty(),
            saved_variables_path: s.saved_variables_path,
            game: s.game,
            region: s.region,
            auto_upload: s.auto_upload,
        }
    }
}

#[tauri::command]
fn get_settings(app: AppHandle) -> Result<PublicSettings, String> {
    load_settings(&app).map(PublicSettings::from)
}

/// Writes `contents` to `<path>.<tmp_ext>` and renames that over `path`, so a reader never sees
/// half a file. The temporary file is always created new: anything already at its name, such as
/// a symlink or hard link another account planted in a folder it can write to (game folders on
/// shared Macs often are), is removed rather than written through. `private` makes the file
/// readable by this account only on macOS and Linux.
fn write_replace(path: &Path, tmp_ext: &str, contents: &[u8], private: bool) -> Result<(), String> {
    let tmp = path.with_extension(tmp_ext);
    match fs::remove_file(&tmp) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(err(e)),
    }
    {
        let mut opts = fs::OpenOptions::new();
        opts.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(if private { 0o600 } else { 0o644 });
        }
        #[cfg(not(unix))]
        let _ = private;
        let mut f = opts.open(&tmp).map_err(err)?;
        f.write_all(contents).map_err(err)?;
        f.sync_all().map_err(err)?;
    }
    fs::rename(&tmp, path).map_err(err)
}

/// The settings file holds the upload secret, so nobody else on the machine may read it.
fn write_private(path: &Path, contents: &str) -> Result<(), String> {
    write_replace(path, "json.tmp", contents.as_bytes(), true)
}

/// An empty secret in the form means "keep the one already stored", but only for the same key:
/// a stored secret belongs to its key id, and pairing it with a different id can only fail as a
/// bad signature. With a new id and no secret the secret stays empty, so the form asks for it.
fn keep_stored_secret(next: &mut Settings, stored: &Settings) {
    if next.secret.is_empty() && next.key_id.trim() == stored.key_id.trim() {
        next.secret = stored.secret.clone();
    }
}

/// Saves the form. The webview never has the secret (see keep_stored_secret). Only https API
/// endpoints are accepted in release builds.
#[tauri::command]
fn save_settings(app: AppHandle, settings: Settings) -> Result<PublicSettings, String> {
    let mut next = settings.with_defaults();
    keep_stored_secret(&mut next, &load_settings(&app)?);
    if !next.api_url.starts_with("https://") && !cfg!(debug_assertions) {
        return Err("the API address must start with https://".to_string());
    }
    let path = settings_path(&app)?;
    let json = serde_json::to_string_pretty(&next).map_err(err)?;
    write_private(&path, &json)?;
    Ok(PublicSettings::from(next))
}

/// Look for `WTF/Account/*/SavedVariables/AHledger.lua` under the usual install locations.
#[tauri::command]
fn detect_saved_variables() -> Vec<String> {
    let mut roots: Vec<PathBuf> = Vec::new();
    #[cfg(target_os = "windows")]
    {
        for var in ["ProgramFiles(x86)", "ProgramFiles", "ProgramW6432"] {
            if let Ok(p) = std::env::var(var) {
                roots.push(PathBuf::from(p).join("World of Warcraft"));
            }
        }
        for drive in ["C", "D", "E", "F"] {
            roots.push(PathBuf::from(format!("{drive}:\\Games\\World of Warcraft")));
            roots.push(PathBuf::from(format!("{drive}:\\World of Warcraft")));
            roots.push(PathBuf::from(format!("{drive}:\\Battle.net\\World of Warcraft")));
        }
    }
    #[cfg(target_os = "macos")]
    {
        roots.push(PathBuf::from("/Applications/World of Warcraft"));
        if let Ok(home) = std::env::var("HOME") {
            roots.push(PathBuf::from(home).join("Applications/World of Warcraft"));
        }
    }
    #[cfg(target_os = "linux")]
    {
        if let Ok(home) = std::env::var("HOME") {
            roots.push(PathBuf::from(&home).join("Games/World of Warcraft"));
            roots.push(PathBuf::from(&home).join(".wine/drive_c/Program Files (x86)/World of Warcraft"));
        }
    }

    let mut found: Vec<(SystemTime, String)> = Vec::new();
    for root in roots {
        let Ok(flavors) = fs::read_dir(&root) else { continue };
        for flavor in flavors.flatten() {
            let accounts = flavor.path().join("WTF").join("Account");
            let Ok(accounts) = fs::read_dir(&accounts) else { continue };
            for account in accounts.flatten() {
                let file = account.path().join("SavedVariables").join(SAVED_VARIABLES_FILE);
                if let Ok(meta) = fs::metadata(&file) {
                    let modified = meta.modified().unwrap_or(UNIX_EPOCH);
                    found.push((modified, file.to_string_lossy().into_owned()));
                }
            }
        }
    }
    // Newest first: the file the player is actually using.
    found.sort_by(|a, b| b.0.cmp(&a.0));
    found.into_iter().map(|(_, p)| p).collect()
}

/// `.../WTF/Account/<account>/SavedVariables/AHledger.lua`, and not a symlink. Anything else is
/// refused so the webview cannot be talked into reading arbitrary files.
fn assert_saved_variables_path(path: &Path) -> Result<(), String> {
    let names: Vec<&str> = path
        .components()
        .filter_map(|c| c.as_os_str().to_str())
        .collect();
    let n = names.len();
    let shape_ok = n >= 5
        && names[n - 1] == SAVED_VARIABLES_FILE
        && names[n - 2].eq_ignore_ascii_case("SavedVariables")
        && names[n - 4].eq_ignore_ascii_case("Account")
        && names[n - 5].eq_ignore_ascii_case("WTF");
    if !shape_ok {
        return Err(format!(
            "expected a path ending in WTF/Account/<account>/SavedVariables/{SAVED_VARIABLES_FILE}"
        ));
    }
    if let Ok(meta) = fs::symlink_metadata(path) {
        if meta.file_type().is_symlink() {
            return Err("the SavedVariables file must not be a symlink".to_string());
        }
    }
    Ok(())
}

#[tauri::command]
fn read_scan_file(path: String) -> Result<String, String> {
    let p = Path::new(&path);
    assert_saved_variables_path(p)?;
    fs::read_to_string(p).map_err(err)
}

/// True when a watcher event is about AHledger.lua. The watch is on its folder and not
/// recursive, so every event is for that folder or a file directly in it, and the file name is
/// enough. Comparing whole paths is not: macOS reports the real path, so a game folder reached
/// through a symlink (a game kept on an external drive, say), `/var` that is really
/// `/private/var`, or a path typed in another case never equals the path as entered, and
/// automatic upload silently never fired.
fn is_scan_file_event(event_path: &Path) -> bool {
    event_path
        .file_name()
        .and_then(|n| n.to_str())
        .is_some_and(|n| n.eq_ignore_ascii_case(SAVED_VARIABLES_FILE))
}

/// Watch the file's directory (WoW replaces the file on save, which would orphan a file watch)
/// and tell the webview when AHledger.lua changed. Replaces any previous watch.
#[tauri::command]
fn watch_file(app: AppHandle, state: State<'_, AppState>, path: String) -> Result<(), String> {
    let target = PathBuf::from(&path);
    assert_saved_variables_path(&target)?;
    let dir = target
        .parent()
        .ok_or_else(|| "path has no parent directory".to_string())?
        .to_path_buf();
    if !dir.is_dir() {
        return Err(format!("directory does not exist: {}", dir.display()));
    }
    let handle = app.clone();
    let wanted = target.clone();
    let mut debouncer = new_debouncer(Duration::from_secs(2), move |res: DebounceEventResult| {
        if let Ok(events) = res {
            if events.iter().any(|e| is_scan_file_event(&e.path)) {
                let _ = handle.emit("scan-file-changed", wanted.to_string_lossy().into_owned());
            }
        }
    })
    .map_err(err)?;
    debouncer
        .watcher()
        .watch(&dir, RecursiveMode::NonRecursive)
        .map_err(err)?;
    let mut guard = state.watcher.lock().map_err(|_| "watcher lock poisoned".to_string())?;
    *guard = Some(debouncer);
    Ok(())
}

fn sign(secret: &str, ts: &str, nonce: &str, body_sha256_hex: &str) -> Result<String, String> {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).map_err(err)?;
    mac.update(format!("AHL1\n{ts}\n{nonce}\n{body_sha256_hex}").as_bytes());
    Ok(hex::encode(mac.finalize().into_bytes()))
}

/// Sign and POST a body to the API with the stored key: the upload endpoint and its check
/// endpoint share the headers and the signature, so they share this.
async fn signed_post(
    app: &AppHandle,
    path: &str,
    body: String,
    gzip_body: bool,
) -> Result<UploadResult, String> {
    let settings = load_settings(app)?;
    if settings.key_id.is_empty() || settings.secret.is_empty() {
        return Err("upload key is not configured".to_string());
    }

    let bytes: Vec<u8> = if gzip_body {
        let mut enc = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        enc.write_all(body.as_bytes()).map_err(err)?;
        enc.finish().map_err(err)?
    } else {
        body.into_bytes()
    };

    let hash = hex::encode(Sha256::digest(&bytes));
    let client = reqwest::Client::builder()
        .user_agent(format!("AHledger-sync/{}", env!("CARGO_PKG_VERSION")))
        .timeout(Duration::from_secs(90))
        .build()
        .map_err(err)?;
    if !settings.api_url.starts_with("https://") && !cfg!(debug_assertions) {
        return Err("refusing to upload over a non-https API address".to_string());
    }
    let url = format!("{}{}", settings.api_url.trim_end_matches('/'), path);
    // At most two tries: the second only when the first was refused for the clock and taught a
    // new correction.
    let mut attempt = 0;
    loop {
        attempt += 1;
        let local_ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(err)?
            .as_secs() as i64;
        let offset = CLOCK_OFFSET.load(Ordering::Relaxed);
        let sent_ts = (local_ts + offset).max(0) as u64;
        let ts = sent_ts.to_string();
        let nonce_bytes: [u8; 16] = rand::random();
        let nonce = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(nonce_bytes);
        let signature = sign(&settings.secret, &ts, &nonce, &hash)?;
        let mut req = client
            .post(&url)
            .header("content-type", "application/json")
            .header("x-ahl-key", &settings.key_id)
            .header("x-ahl-ts", ts)
            .header("x-ahl-nonce", nonce)
            .header("x-ahl-signature", signature);
        if gzip_body {
            req = req.header("content-encoding", "gzip");
        }
        let res = req.body(bytes.clone()).send().await.map_err(err)?;
        let status = res.status().as_u16();
        let body = res.text().await.unwrap_or_default();
        if attempt == 1 {
            if let Some(next) = clock_correction(status, &body, local_ts) {
                if next != offset {
                    CLOCK_OFFSET.store(next, Ordering::Relaxed);
                    continue;
                }
            }
        }
        return Ok(UploadResult {
            status,
            body,
            sent_ts,
            clock_offset: CLOCK_OFFSET.load(Ordering::Relaxed),
        });
    }
}

/// Gzip, sign, and POST one scan (the JSON produced by the webview) to `/v1/upload`.
#[tauri::command]
async fn upload_scan(app: AppHandle, body: String) -> Result<UploadResult, String> {
    signed_post(&app, "/v1/upload", body, true).await
}

/// "Test key": a signed request over a tiny body that the server checks like an upload and
/// answers with its own clock, so a wrong secret, a revoked key or a clock that is off shows
/// before the first scan. Nothing is uploaded.
#[tauri::command]
async fn check_key(app: AppHandle) -> Result<UploadResult, String> {
    signed_post(&app, "/v1/upload/check", "{\"check\":true}".to_string(), false).await
}

// ---------------------------------------------------------------------------------------------
// Update check: the site publishes the current release at /api/sync/version. It sits under /api/
// because the site challenges every request that is not a browser outside /api/; up to 0.2.20
// this asked for /sync/version.json, got a 429, and never heard of a release.
// ---------------------------------------------------------------------------------------------

const SITE_URL: &str = "https://ahledger.com";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateInfo {
    pub current: String,
    pub latest: String,
    pub newer: bool,
    pub download_url: String,
    pub page: String,
    pub released: String,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct VersionDoc {
    version: String,
    #[serde(default)]
    released: String,
    download_url: String,
    #[serde(default)]
    page: String,
}

/// Dotted numeric versions: true when `latest` is strictly newer than `current`. Anything that
/// does not parse as digits compares as zero, so a malformed document never claims an update.
fn is_newer(latest: &str, current: &str) -> bool {
    let parse = |v: &str| -> Vec<u64> {
        v.trim_start_matches('v')
            .split('.')
            .map(|p| p.trim().parse::<u64>().unwrap_or(0))
            .collect()
    };
    let (a, b) = (parse(latest), parse(current));
    let n = a.len().max(b.len());
    for i in 0..n {
        let (x, y) = (*a.get(i).unwrap_or(&0), *b.get(i).unwrap_or(&0));
        if x != y {
            return x > y;
        }
    }
    false
}

/// Fetches the current release from the site and says whether it is newer than this build.
#[tauri::command]
async fn check_for_update() -> Result<UpdateInfo, String> {
    let client = reqwest::Client::builder()
        .user_agent(format!("AHledger-sync/{}", env!("CARGO_PKG_VERSION")))
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(err)?;
    let text = client
        .get(format!("{SITE_URL}/api/sync/version"))
        .send()
        .await
        .map_err(err)?
        .error_for_status()
        .map_err(err)?
        .text()
        .await
        .map_err(err)?;
    let doc: VersionDoc = serde_json::from_str(&text).map_err(err)?;
    // Only the site's own download is ever offered, whatever the document says.
    if !doc.download_url.starts_with(&format!("{SITE_URL}/")) {
        return Err("update document names a download outside ahledger.com".to_string());
    }
    let current = env!("CARGO_PKG_VERSION").to_string();
    Ok(UpdateInfo {
        newer: is_newer(&doc.version, &current),
        current,
        latest: doc.version,
        download_url: doc.download_url,
        page: if doc.page.is_empty() { format!("{SITE_URL}/download") } else { doc.page },
        released: doc.released,
    })
}

/// True for an ahledger.com page address made only of letters, digits and `/ . _ -`. Anything a
/// shell or a URL handler could read as more than an address (`& | ^ % " ? #`, spaces, `..`) is
/// refused, so neither the webview nor a reply from the site can turn opening a page into running
/// a command.
fn is_safe_site_url(url: &str) -> bool {
    let Some(path) = url.strip_prefix(&format!("{SITE_URL}/")) else {
        return false;
    };
    path.len() <= 200
        && !path.contains("..")
        && path
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '.' | '_' | '-'))
}

/// Opens an ahledger.com page in the default browser. Only addresses that pass is_safe_site_url
/// are opened, and on Windows through the URL handler directly rather than through cmd, so no
/// shell ever parses the address.
#[tauri::command]
fn open_site_url(url: String) -> Result<(), String> {
    if !is_safe_site_url(&url) {
        return Err("only ahledger.com pages can be opened".to_string());
    }
    // macOS: the system's own `open` by its full path, not whatever `open` comes first on PATH.
    #[cfg(target_os = "windows")]
    let mut child = std::process::Command::new("rundll32")
        .args(["url.dll,FileProtocolHandler", &url])
        .spawn()
        .map_err(err)?;
    #[cfg(target_os = "macos")]
    let mut child = std::process::Command::new("/usr/bin/open").arg(&url).spawn().map_err(err)?;
    #[cfg(all(unix, not(target_os = "macos")))]
    let mut child = std::process::Command::new("xdg-open").arg(&url).spawn().map_err(err)?;
    // Collect the helper's exit status once it hands the address over. On macOS and Linux a child
    // nobody waits for stays in the process table as a zombie until sync quits, one per click.
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// Connect: the site hands this app an upload key after the player approves a short code there
// ---------------------------------------------------------------------------------------------

#[derive(Deserialize)]
struct PairStartDoc {
    code: String,
    token: String,
    #[serde(rename = "expiresIn")]
    expires_in: u64,
    interval: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairStarted {
    pub code: String,
    pub url: String,
    pub expires_in: u64,
    pub interval: u64,
}

#[derive(Deserialize)]
struct PairPollDoc {
    status: String,
    #[serde(rename = "keyId")]
    key_id: Option<String>,
    secret: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairResult {
    pub status: String,
    pub key_id: Option<String>,
    /// For "retry": why this poll did not get an answer, in words for the window.
    pub message: Option<String>,
}

fn pair_result(status: &str, key_id: Option<String>, message: Option<String>) -> PairResult {
    PairResult { status: status.to_string(), key_id, message }
}

/// Withdraws a pending request on the site. Best effort: if it fails the code simply expires.
async fn cancel_on_site(token: &str) {
    if let Ok(client) = site_client() {
        let _ = client
            .post(format!("{SITE_URL}/api/pair/cancel"))
            .header("content-type", "application/json")
            .body(serde_json::json!({ "token": token }).to_string())
            .send()
            .await;
    }
}

const PAIR_ALPHABET: &str = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

/// "ABCD-EFGH" from the site, checked character by character; the approval page address is
/// built here from it rather than taken from the reply.
fn pair_code_ok(code: &str) -> bool {
    let b = code.as_bytes();
    b.len() == 9
        && b[4] == b'-'
        && code
            .chars()
            .enumerate()
            .all(|(i, c)| i == 4 || PAIR_ALPHABET.contains(c))
}

fn upload_key_ok(key_id: &str, secret: &str) -> bool {
    key_id.len() == 20
        && key_id.starts_with("ahl_")
        && key_id[4..].chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        && (32..=64).contains(&secret.len())
        && secret.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// Plain words for a reply that is not a success, so the window never shows a parser error.
fn site_refusal(status: reqwest::StatusCode) -> String {
    match status.as_u16() {
        429 => "ahledger.com is limiting connect attempts from this address; wait a few minutes and press Connect again".to_string(),
        500..=599 => format!("ahledger.com had a problem (HTTP {}); press Connect again in a minute", status.as_u16()),
        n => format!("ahledger.com refused the request (HTTP {n}); press Connect again"),
    }
}

fn site_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .user_agent(format!("AHledger-sync/{}", env!("CARGO_PKG_VERSION")))
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(err)
}

/// Starts a Connect request, keeps its token here, and opens the approval page in the browser.
#[tauri::command]
async fn pair_start(state: State<'_, AppState>) -> Result<PairStarted, String> {
    // A second press withdraws the first code, so an older approval tab cannot mint a key that
    // nothing will collect.
    let previous = {
        let mut guard = state.pair_token.lock().map_err(|_| "pair lock poisoned".to_string())?;
        guard.take()
    };
    if let Some(old) = previous {
        cancel_on_site(&old).await;
    }
    let res = site_client()?
        .post(format!("{SITE_URL}/api/pair/start"))
        .send()
        .await
        .map_err(err)?;
    let status = res.status();
    if !status.is_success() {
        return Err(site_refusal(status));
    }
    let text = res.text().await.map_err(err)?;
    let doc: PairStartDoc = serde_json::from_str(&text)
        .map_err(|_| "ahledger.com sent a reply sync could not read".to_string())?;
    if !pair_code_ok(&doc.code) || doc.token.len() < 40 || doc.token.len() > 64 {
        return Err("ahledger.com sent a code sync does not recognise".to_string());
    }
    let url = format!("{SITE_URL}/connect/{}", doc.code.replace('-', ""));
    {
        let mut guard = state.pair_token.lock().map_err(|_| "pair lock poisoned".to_string())?;
        *guard = Some(doc.token);
    }
    // Opening the browser is a convenience: the code and the address are shown in the window too.
    let _ = open_site_url(url.clone());
    Ok(PairStarted {
        code: doc.code,
        url,
        expires_in: doc.expires_in.min(900),
        interval: doc.interval.clamp(2, 30),
    })
}

/// Asks whether the code was approved. On approval the key id and secret are written straight
/// into the settings file; the secret never reaches the webview.
#[tauri::command]
async fn pair_poll(app: AppHandle, state: State<'_, AppState>) -> Result<PairResult, String> {
    let token = {
        let guard = state.pair_token.lock().map_err(|_| "pair lock poisoned".to_string())?;
        guard.clone()
    };
    let Some(token) = token else {
        return Ok(pair_result("idle", None, None));
    };
    // Network trouble, rate limits and server errors are passing: the window keeps polling
    // until the code expires, so an approval made meanwhile is still collected.
    let sent = site_client()?
        .post(format!("{SITE_URL}/api/pair/poll"))
        .header("content-type", "application/json")
        .body(serde_json::json!({ "token": token }).to_string())
        .send()
        .await;
    let res = match sent {
        Ok(res) => res,
        Err(e) => {
            return Ok(pair_result("retry", None, Some(format!("could not reach ahledger.com ({e})"))));
        }
    };
    let status = res.status();
    if status.as_u16() == 429 || status.is_server_error() {
        return Ok(pair_result("retry", None, Some(site_refusal(status))));
    }
    if !status.is_success() {
        return Err(site_refusal(status));
    }
    let text = res.text().await.map_err(err)?;
    let doc: PairPollDoc = serde_json::from_str(&text)
        .map_err(|_| "ahledger.com sent a reply sync could not read".to_string())?;
    if doc.status == "approved" {
        let (Some(key_id), Some(secret)) = (doc.key_id, doc.secret) else {
            return Err("the site approved the request but sent no key".to_string());
        };
        if !upload_key_ok(&key_id, &secret) {
            return Err("the site sent a key in a shape sync does not recognise; nothing was saved".to_string());
        }
        let mut settings = load_settings(&app)?;
        settings.key_id = key_id.clone();
        settings.secret = secret;
        let path = settings_path(&app)?;
        let json = serde_json::to_string_pretty(&settings).map_err(err)?;
        write_private(&path, &json)?;
        let mut guard = state.pair_token.lock().map_err(|_| "pair lock poisoned".to_string())?;
        *guard = None;
        return Ok(pair_result("approved", Some(key_id), None));
    }
    if doc.status != "pending" {
        let mut guard = state.pair_token.lock().map_err(|_| "pair lock poisoned".to_string())?;
        *guard = None;
    }
    Ok(pair_result(&doc.status, None, None))
}

#[tauri::command]
async fn pair_cancel(state: State<'_, AppState>) -> Result<(), String> {
    let token = {
        let mut guard = state.pair_token.lock().map_err(|_| "pair lock poisoned".to_string())?;
        guard.take()
    };
    if let Some(t) = token {
        cancel_on_site(&t).await;
    }
    Ok(())
}

/// Gzip, sign, and POST the addon's item source table to `/v1/upload/observations`.
#[tauri::command]
async fn upload_observations(app: AppHandle, body: String) -> Result<UploadResult, String> {
    signed_post(&app, "/v1/upload/observations", body, true).await
}

/// Gzip, sign, and POST the addon's auction ledger to `/v1/upload/ledger` (0.2.24).
#[tauri::command]
async fn upload_ledger(app: AppHandle, body: String) -> Result<UploadResult, String> {
    signed_post(&app, "/v1/upload/ledger", body, true).await
}

/// Gzip, sign, and POST the Rank Points the addon read on the player's own characters to
/// `/v1/upload/pvp-points` (0.2.27).
#[tauri::command]
async fn upload_pvp_points(app: AppHandle, body: String) -> Result<UploadResult, String> {
    signed_post(&app, "/v1/upload/pvp-points", body, true).await
}

/// Gzip, sign, and POST the players the addon saw to `/v1/upload/sightings` (0.2.25).
#[tauri::command]
async fn upload_sightings(app: AppHandle, body: String) -> Result<UploadResult, String> {
    signed_post(&app, "/v1/upload/sightings", body, true).await
}

// ---------------------------------------------------------------------------------------------
// Price tables: downloaded from the API and written into the addon's data file
// ---------------------------------------------------------------------------------------------

const DATA_FILE: &str = "AHledger_Data.lua";
/// A market table is a few hundred kilobytes; anything past this is not a table.
const MAX_TABLE_BYTES: usize = 8_000_000;

/// `.../<flavor>/WTF/Account/<account>/SavedVariables/AHledger.lua` ->
/// `.../<flavor>/Interface/AddOns/AHledger/AHledger_Data.lua`. Refuses to write anywhere the
/// addon is not installed.
fn data_file_for(saved_variables: &Path) -> Result<PathBuf, String> {
    assert_saved_variables_path(saved_variables)?;
    // ancestors(): 0 the file, 1 SavedVariables, 2 the account, 3 Account, 4 WTF, 5 the game folder.
    let flavor = saved_variables
        .ancestors()
        .nth(5)
        .ok_or_else(|| "cannot find the game folder above WTF".to_string())?;
    let addon = flavor.join("Interface").join("AddOns").join("AHledger");
    if !addon.join("AHledger.toc").is_file() {
        return Err(format!(
            "the AHledger addon is not installed at {}",
            addon.display()
        ));
    }
    Ok(addon.join(DATA_FILE))
}

#[tauri::command]
fn price_table_path(app: AppHandle) -> Result<String, String> {
    let settings = load_settings(&app)?;
    if settings.saved_variables_path.is_empty() {
        return Err("set the SavedVariables path first".to_string());
    }
    data_file_for(Path::new(&settings.saved_variables_path)).map(|p| p.to_string_lossy().into_owned())
}

#[derive(Deserialize)]
struct MarketsDoc {
    markets: Vec<MarketDoc>,
}
#[derive(Deserialize)]
struct MarketDoc {
    id: String,
    game: String,
}

#[derive(Serialize)]
pub struct RefreshResult {
    pub path: String,
    pub markets: usize,
    pub items: usize,
    /// The newest `updated` (unix seconds) among the tables written; 0 when none had rows.
    pub newest: u64,
    /// What this key added to the site over the last week, when the server answered.
    pub contribution: Option<Contribution>,
    /// The account watchlist written for the addon, when the server answered.
    pub watch: Option<WatchSummary>,
    /// Characters in the PvP table written for the tooltip, when the server had one.
    pub pvp: Option<usize>,
    /// Why the PvP table could not be refreshed this time, when it could not (0.2.27). The last
    /// good table is written instead while there is one.
    #[serde(rename = "pvpError")]
    pub pvp_error: Option<String>,
}

/// The counts `/v1/upload/stats` answers with: nothing about which items or realms.
#[derive(Serialize, Deserialize, Clone, Copy, Default)]
pub struct Contribution {
    #[serde(default)]
    pub at: u64,
    #[serde(default)]
    pub days: u64,
    #[serde(default)]
    pub scans: u64,
    #[serde(default)]
    pub listings: u64,
    #[serde(default)]
    pub sources: u64,
    #[serde(default)]
    pub quests: u64,
    /// This key's place among the week's contributors, when the server works one out.
    #[serde(default)]
    pub rank: Option<u64>,
    #[serde(default)]
    pub contributors: u64,
}

/// The Lua line the addon reads for "Your scans added ...". Integers only, so nothing from
/// the network can change what the file means. The rank rides along when there is one, so the
/// addon can say "you rank 3 of 12" and invite the player to put a name on it.
fn render_contribution(c: &Contribution) -> String {
    let rank = match c.rank {
        Some(r) if r > 0 && c.contributors > 0 => {
            format!(", rank = {}, contributors = {}", r, c.contributors)
        }
        _ => String::new(),
    };
    format!(
        "AHledgerData.contribution = {{ at = {}, days = {}, scans = {}, listings = {}, sources = {}, quests = {}{} }}\n",
        c.at, c.days, c.scans, c.listings, c.sources, c.quests, rank
    )
}

/// The server's answer to `/v1/upload/watch`: the account's watchlist, whole.
#[derive(Deserialize, Default)]
struct WatchAnswer {
    #[serde(default)]
    linked: bool,
    #[serde(default)]
    at: u64,
    #[serde(default, rename = "savedAt")]
    saved_at: u64,
    #[serde(default)]
    items: Vec<WatchItem>,
    /// Ids the addon sent that the account did not keep: not removed on the site, so the addon
    /// keeps them too.
    #[serde(default)]
    dropped: Vec<u64>,
}
#[derive(Deserialize)]
struct WatchItem {
    #[serde(default)]
    id: u64,
}

/// What the webview shows and remembers about the watchlist sync.
#[derive(Serialize, Clone, Copy)]
pub struct WatchSummary {
    pub linked: bool,
    pub at: u64,
    #[serde(rename = "savedAt")]
    pub saved_at: u64,
    pub items: usize,
}

/// The Lua block the addon reads to bring its watchlist level with the account: integers only,
/// sorted, so nothing from the network can change what the file means. Markets are left out;
/// the addon prices a watched item on its own market.
fn render_watch(a: &WatchAnswer) -> String {
    let mut ids: Vec<u64> = a
        .items
        .iter()
        .map(|i| i.id)
        .filter(|&i| i > 0 && i < 100_000_000)
        .collect();
    ids.sort_unstable();
    ids.dedup();
    let body: Vec<String> = ids.iter().map(|i| format!("[{}] = 1", i)).collect();
    let mut dropped: Vec<u64> = a
        .dropped
        .iter()
        .copied()
        .filter(|&i| i > 0 && i < 100_000_000)
        .collect();
    dropped.sort_unstable();
    dropped.dedup();
    let kept_out: Vec<String> = dropped.iter().map(|i| format!("[{}] = 1", i)).collect();
    format!(
        "AHledgerData.watch = {{ at = {}, savedAt = {}, items = {{ {} }}, dropped = {{ {} }} }}\n",
        a.at,
        a.saved_at,
        body.join(", "),
        kept_out.join(", ")
    )
}

/// Sends the saved file's watchlist (the JSON the webview built) and returns the account's
/// list. No key, offline, an older server, or a refusal: none, and the file carries no block.
async fn sync_watch(app: &AppHandle, body: String) -> Option<WatchAnswer> {
    let res = signed_post(app, "/v1/upload/watch", body, false).await.ok()?;
    if res.status != 200 {
        return None;
    }
    serde_json::from_str::<WatchAnswer>(&res.body).ok()
}

/// Asks the site what this key contributed. No key yet, offline, or an older server: none,
/// and the tables are written without the line.
async fn fetch_contribution(app: &AppHandle) -> Option<Contribution> {
    let res = signed_post(app, "/v1/upload/stats", "{\"stats\":true}".to_string(), false)
        .await
        .ok()?;
    if res.status != 200 {
        return None;
    }
    serde_json::from_str::<Contribution>(&res.body).ok()
}

/// Fetches every market's price table for the configured game and writes them as one Lua file
/// the addon reads at login (`AHledgerData[market] = { updated, count, text }`).
#[tauri::command]
async fn refresh_price_tables(
    app: AppHandle,
    watch: Option<String>,
    region: Option<String>,
) -> Result<RefreshResult, String> {
    let settings = load_settings(&app)?;
    if settings.saved_variables_path.is_empty() {
        return Err("set the SavedVariables path first".to_string());
    }
    let target = data_file_for(Path::new(&settings.saved_variables_path))?;
    if !settings.api_url.starts_with("https://") && !cfg!(debug_assertions) {
        return Err("refusing to download over a non-https API address".to_string());
    }
    let base = settings.api_url.trim_end_matches('/').to_string();
    let client = reqwest::Client::builder()
        .user_agent(format!("AHledger-sync/{}", env!("CARGO_PKG_VERSION")))
        .default_headers(sync_key_headers(&settings.key_id))
        .timeout(Duration::from_secs(60))
        .build()
        .map_err(err)?;
    let markets_text = client
        .get(format!("{base}/v1/markets"))
        .send()
        .await
        .map_err(err)?
        .error_for_status()
        .map_err(err)?
        .text()
        .await
        .map_err(err)?;
    let markets: MarketsDoc = serde_json::from_str(&markets_text).map_err(err)?;

    let mut out = String::new();
    out.push_str("-- Written by AHledger sync. Do not edit: it is replaced on every refresh.\n");
    out.push_str("AHledgerData = AHledgerData or {}\n");
    let mut count_markets = 0usize;
    let mut count_items = 0usize;
    let mut newest = 0u64;
    for m in markets.markets.iter().filter(|m| m.game == settings.game) {
        let fetched = fetch_price_table(&app, &client, &base, &m.id).await?;
        let Some((lua, rows, updated)) = render_price_table(&m.id, &fetched.text)? else { continue };
        // Kept only once it reads, so a bad table never replaces the last good one.
        if let Some(tag) = fetched.new_etag.as_deref() {
            keep_price_table(&app, &m.id, &fetched.text, tag);
        }
        out.push_str(&lua);
        count_markets += 1;
        count_items += rows;
        if rows > 0 {
            newest = newest.max(updated);
        }
    }
    // The PvP ladder for the tooltip (0.2.27), for the region the saved file plays on. A server
    // without it, or a table that fails the checks, leaves the block out; prices still go.
    let pvp_region = region
        .filter(|r| r == "us" || r == "eu")
        .unwrap_or_else(|| settings.region.clone());
    let mut pvp_rows = None;
    let mut pvp_error = None;
    if settings.game == "forever" && (pvp_region == "us" || pvp_region == "eu") {
        let (table, problem) = fetch_pvp_table(&app, &client, &base, &pvp_region).await;
        if let Some((lua, rows)) = table {
            out.push_str(&lua);
            pvp_rows = Some(rows);
        }
        pvp_error = problem;
    }
    let contribution = fetch_contribution(&app).await;
    if let Some(c) = contribution.as_ref() {
        out.push_str(&render_contribution(c));
    }
    // The watchlist, when the webview found one in the saved file and the key has an account.
    let answer = match watch {
        Some(body) if !body.is_empty() => sync_watch(&app, body).await,
        _ => None,
    };
    if let Some(a) = answer.as_ref() {
        if a.linked {
            out.push_str(&render_watch(a));
        }
    }
    write_replace(&target, "lua.tmp", out.as_bytes(), false)?;
    Ok(RefreshResult {
        path: target.to_string_lossy().into_owned(),
        markets: count_markets,
        items: count_items,
        newest,
        contribution,
        watch: answer.as_ref().map(|a| WatchSummary {
            linked: a.linked,
            at: a.at,
            saved_at: a.saved_at,
            items: a.items.len(),
        }),
        pvp: pvp_rows,
        pvp_error,
    })
}

/// The upload key's public id, sent with the table downloads (0.2.28) so the API can count sync
/// apart from sites that copy the tables. Never the secret, and nothing when no key is set. The
/// API changes no limit for it.
fn sync_key_headers(key_id: &str) -> reqwest::header::HeaderMap {
    let mut headers = reqwest::header::HeaderMap::new();
    let plain = key_id.len() == 20
        && key_id.starts_with("ahl_")
        && key_id[4..].chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit());
    if plain {
        if let Ok(v) = reqwest::header::HeaderValue::from_str(key_id) {
            headers.insert("x-ahl-sync-key", v);
        }
    }
    headers
}

/// A market's price table as fetched, and the ETag to keep it under when it came from the server.
struct FetchedTable {
    text: String,
    /// Set for a fresh download that carried an ETag; None for the kept copy.
    new_etag: Option<String>,
}

/// The file name a market's kept price table goes under, or None for an id that is not plainly a
/// market id (letters, digits, dots and dashes), which is then never cached: the id comes from the
/// server and must not be able to name a path.
fn price_table_cache_name(market_id: &str) -> Option<String> {
    let plain = !market_id.is_empty()
        && market_id.len() <= 200
        && !market_id.starts_with('.')
        && !market_id.contains("..")
        && market_id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'.' || b == b'-');
    plain.then(|| market_id.to_string())
}

fn price_table_paths(app: &AppHandle, market_id: &str) -> Option<(PathBuf, PathBuf, PathBuf)> {
    let name = price_table_cache_name(market_id)?;
    let dir = app.path().app_data_dir().ok()?.join("pricetables");
    let text = dir.join(format!("{name}.txt"));
    let etag = dir.join(format!("{name}.etag"));
    Some((dir, text, etag))
}

/// One market's price table (0.2.28). The last good table is kept in the app's data folder with
/// its ETag and sent back as If-None-Match, so a refresh that finds nothing new is answered 304,
/// costs a few bytes and never counts toward the server's hourly cap on full downloads. A failed
/// download (a 429 from a busy shared address, a dropped connection) uses the kept table instead
/// of failing the whole refresh; with nothing kept the error stands, as before.
async fn fetch_price_table(
    app: &AppHandle,
    client: &reqwest::Client,
    base: &str,
    market_id: &str,
) -> Result<FetchedTable, String> {
    let paths = price_table_paths(app, market_id);
    let cached = paths.as_ref().and_then(|(_, t, _)| fs::read_to_string(t).ok());
    let etag = paths.as_ref().and_then(|(_, _, e)| fs::read_to_string(e).ok());
    let kept = |problem: String| match cached.clone() {
        Some(text) => Ok(FetchedTable { text, new_etag: None }),
        None => Err(problem),
    };
    let mut req = client.get(format!("{base}/v1/pricetable/{market_id}"));
    if let (Some(tag), Some(_)) = (etag.as_deref(), cached.as_ref()) {
        req = req.header("if-none-match", tag.trim());
    }
    let res = match req.send().await {
        Ok(r) => r,
        Err(e) => return kept(err(e)),
    };
    let status = res.status().as_u16();
    if status == 304 {
        return kept(format!("the server answered 304 for {market_id} but no table is kept"));
    }
    if !(200..300).contains(&status) {
        return kept(format!("HTTP {status} for the {market_id} price table"));
    }
    let new_etag = res
        .headers()
        .get("etag")
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);
    match res.text().await {
        Ok(text) => Ok(FetchedTable { text, new_etag }),
        Err(e) => kept(err(e)),
    }
}

/// Keeps a price table that read cleanly, with its ETag, for the next refresh.
fn keep_price_table(app: &AppHandle, market_id: &str, text: &str, etag: &str) {
    let Some((dir, text_path, etag_path)) = price_table_paths(app, market_id) else { return };
    let _ = fs::create_dir_all(&dir);
    // The ETag goes last and only after the table, so a half-written pair never sends a tag
    // for a table that is not on disk.
    if fs::write(&text_path, text).is_ok() {
        let _ = fs::write(&etag_path, etag);
    }
}

/// The PvP table for a region, as the Lua block and its row count, with why it could not be
/// refreshed when it could not (0.2.27). The last good table is kept in the app's data folder
/// with its ETag: the server answers 304 when nothing changed, so a refresh costs a few bytes,
/// and a failed download or a table that fails the checks writes the last good one instead of
/// dropping the tooltip. The body is asked for gzipped and inflated here.
async fn fetch_pvp_table(
    app: &AppHandle,
    client: &reqwest::Client,
    base: &str,
    region: &str,
) -> (Option<(String, usize)>, Option<String>) {
    let dir = app.path().app_data_dir().ok();
    let text_path = dir.as_ref().map(|d| d.join(format!("pvptable-{region}.txt")));
    let etag_path = dir.as_ref().map(|d| d.join(format!("pvptable-{region}.etag")));
    let cached = text_path.as_ref().and_then(|p| fs::read_to_string(p).ok());
    let etag = etag_path.as_ref().and_then(|p| fs::read_to_string(p).ok());
    let from_cache = |problem: String| match cached.as_deref().map(|t| render_pvp_table(region, t)) {
        Some(Ok(Some(block))) => (Some(block), Some(problem)),
        _ => (None, Some(problem)),
    };
    let mut req = client
        .get(format!("{base}/v1/pvptable/{region}"))
        .header("accept-encoding", "gzip");
    if let (Some(tag), Some(_)) = (etag.as_deref(), cached.as_ref()) {
        req = req.header("if-none-match", tag.trim());
    }
    let res = match req.send().await {
        Ok(r) => r,
        Err(e) => return from_cache(format!("download failed: {e}")),
    };
    let status = res.status().as_u16();
    if status == 304 {
        return match cached.as_deref().map(|t| render_pvp_table(region, t)) {
            Some(Ok(Some(block))) => (Some(block), None),
            _ => (None, Some("the kept table no longer reads".to_string())),
        };
    }
    if !(200..300).contains(&status) {
        return from_cache(format!("HTTP {status}"));
    }
    let new_tag = res
        .headers()
        .get("etag")
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);
    let gzipped = res
        .headers()
        .get("content-encoding")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.eq_ignore_ascii_case("gzip"));
    let bytes = match res.bytes().await {
        Ok(b) => b,
        Err(e) => return from_cache(format!("download failed: {e}")),
    };
    let text = if gzipped {
        use std::io::Read;
        let mut out = String::new();
        let mut dec = flate2::read::GzDecoder::new(&bytes[..]).take(MAX_TABLE_BYTES as u64 + 1);
        if dec.read_to_string(&mut out).is_err() {
            return from_cache("the table did not inflate".to_string());
        }
        out
    } else {
        match String::from_utf8(bytes.to_vec()) {
            Ok(t) => t,
            Err(_) => return from_cache("the table is not text".to_string()),
        }
    };
    match render_pvp_table(region, &text) {
        Ok(Some(block)) => {
            if let (Some(d), Some(tp)) = (dir.as_ref(), text_path.as_ref()) {
                let _ = fs::create_dir_all(d);
                if fs::write(tp, &text).is_ok() {
                    if let (Some(ep), Some(tag)) = (etag_path.as_ref(), new_tag.as_ref()) {
                        let _ = fs::write(ep, tag);
                    }
                }
            }
            (Some(block), None)
        }
        Ok(None) => (None, None),
        Err(e) => from_cache(e),
    }
}

/// Validates the PvP table and renders the Lua block the tooltip reads
/// (`AHledgerData.pvp = { region, updated, count, text }`, rows joined by ";"). Like the price
/// tables, every byte is checked because the game runs this file: the region must be the one
/// asked for, a name is letters (any script) with one space, the rank and kills are digits.
/// Returns `None` for an empty table, and an error for anything that fails, which drops the
/// block without touching the prices.
fn render_pvp_table(region: &str, text: &str) -> Result<Option<(String, usize)>, String> {
    let mut lines = text.lines();
    let Some(header) = lines.next() else { return Ok(None) };
    let parts: Vec<&str> = header.split('|').collect();
    if parts.len() < 4 || parts[0] != "AHP1" || parts[1] != region {
        return Err("unexpected PvP table header".to_string());
    }
    let updated: u64 = parts[2].parse().map_err(|_| "PvP table has a bad timestamp".to_string())?;
    if text.len() > MAX_TABLE_BYTES {
        return Err("PvP table is too large".to_string());
    }
    let digits = |s: &str, max: usize| !s.is_empty() && s.len() <= max && s.bytes().all(|b| b.is_ascii_digit());
    let mut rows: Vec<&str> = Vec::new();
    for line in lines.filter(|l| !l.is_empty()) {
        let fields: Vec<&str> = line.split(':').collect();
        let ok = fields.len() == 3
            && digits(fields[1], 2)
            && digits(fields[2], 9)
            && {
                let names: Vec<&str> = fields[0].split(' ').collect();
                names.len() == 2
                    && names.iter().all(|n| {
                        let count = n.chars().count();
                        (2..=20).contains(&count) && n.chars().all(char::is_alphabetic)
                    })
            };
        // A row that fails is left out, never written: one odd name must not cost the table.
        if ok {
            rows.push(line);
        }
    }
    if rows.is_empty() {
        return Ok(None);
    }
    let lua = format!(
        "AHledgerData.pvp = {{ region = \"{}\", updated = {}, count = {}, text = [==[\n;{};\n]==] }}\n",
        region,
        updated,
        rows.len(),
        rows.join(";")
    );
    Ok(Some((lua, rows.len())))
}

/// Validates one market's price table and renders the Lua block the addon reads. Returns
/// `None` for an empty response. This file is executed by the game as Lua, so every byte that
/// lands in it is checked: the market key must be the one we asked for (lowercase letters,
/// digits, slashes, dashes), the timestamp must be a number, rows may hold digits and colons
/// only, and the table has a size ceiling. Anything else aborts the whole refresh.
fn render_price_table(
    market_id: &str,
    text: &str,
) -> Result<Option<(String, usize, u64)>, String> {
    let mut lines = text.lines();
    let Some(header) = lines.next() else { return Ok(None) };
    let parts: Vec<&str> = header.split('|').collect();
    if parts.len() < 4 || parts[0] != "AHL1" {
        return Err(format!("unexpected price table header for {market_id}"));
    }
    let market = parts[1];
    if market != market_id.replace('.', "/")
        || !market
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'/' || b == b'-')
    {
        return Err(format!("price table for {market_id} names an unexpected market"));
    }
    let updated: u64 = parts[2]
        .parse()
        .map_err(|_| format!("price table for {market_id} has a bad timestamp"))?;
    if text.len() > MAX_TABLE_BYTES {
        return Err(format!(
            "price table for {market_id} is larger than {} MB",
            MAX_TABLE_BYTES / 1_000_000
        ));
    }
    let rows: Vec<&str> = lines.filter(|l| !l.is_empty()).collect();
    if rows
        .iter()
        .any(|l| l.len() > 200 || !l.bytes().all(|b| b.is_ascii_digit() || b == b':'))
    {
        return Err(format!("price table for {market_id} contains unexpected characters"));
    }
    let lua = format!(
        "AHledgerData[\"{}\"] = {{ updated = {}, count = {}, text = [==[\n{}\n]==] }}\n",
        market,
        updated,
        rows.len(),
        rows.join(";")
    );
    Ok(Some((lua, rows.len(), updated)))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            get_settings,
            save_settings,
            detect_saved_variables,
            read_scan_file,
            watch_file,
            upload_scan,
            check_key,
            upload_observations,
            upload_ledger,
            upload_sightings,
            upload_pvp_points,
            check_for_update,
            open_site_url,
            price_table_path,
            refresh_price_tables,
            pair_start,
            pair_poll,
            pair_cancel
        ])
        .run(tauri::generate_context!())
        .expect("error while running AHledger sync");
}

#[cfg(test)]
mod tests {
    #[test]
    fn table_downloads_carry_only_a_plain_upload_key_id() {
        use super::sync_key_headers;
        let h = sync_key_headers("ahl_abcdefghij012345");
        assert_eq!(h.get("x-ahl-sync-key").unwrap(), "ahl_abcdefghij012345");
        assert_eq!(h.len(), 1);
        for bad in ["", "ahl_short", "ahl_ABCDEFGHIJ012345", "xyz_abcdefghij012345", "ahl_abcdefghij01234
"] {
            assert!(sync_key_headers(bad).is_empty(), "{bad}");
        }
    }

    #[test]
    fn only_a_plain_market_id_names_a_kept_price_table() {
        use super::price_table_cache_name as name;
        assert_eq!(name("forever.pvp.horde.us").as_deref(), Some("forever.pvp.horde.us"));
        assert_eq!(name("forever.rp-pvp.alliance.eu").as_deref(), Some("forever.rp-pvp.alliance.eu"));
        for bad in ["", "../x", "a/b", "a\\b", ".hidden", "a..b", "Forever.pvp", "a:b", "x y"] {
            assert_eq!(name(bad), None, "{bad}");
        }
    }

    #[test]
    fn a_clock_refusal_teaches_the_correction() {
        use super::clock_correction;
        let body = r#"{"error":"x-ahl-ts is outside the accepted clock window","serverTime":"2026-11-07T18:13:52.000Z","serverTs":1794161632}"#;
        // This computer read a time eight hours ahead of the server's.
        assert_eq!(
            clock_correction(401, body, 1794161632 + 8 * 3600),
            Some(-8 * 3600)
        );
        assert_eq!(clock_correction(401, body, 1794161632 - 420), Some(420));
        // Any other refusal, status, or a body without a believable clock teaches nothing.
        assert_eq!(clock_correction(200, body, 0), None);
        assert_eq!(
            clock_correction(401, r#"{"error":"bad signature","serverTs":1794161632}"#, 0),
            None
        );
        assert_eq!(
            clock_correction(401, r#"{"error":"clock window","serverTs":12}"#, 0),
            None
        );
        assert_eq!(clock_correction(401, "clock window", 0), None);
    }

    #[test]
    fn a_stored_secret_stays_with_its_key() {
        use super::{keep_stored_secret, Settings};
        let stored = Settings {
            key_id: "ahl_aaaaaaaaaaaaaaaa".into(),
            secret: "old".into(),
            ..Default::default()
        };
        let form = |id: &str, secret: &str| Settings {
            key_id: id.into(),
            secret: secret.into(),
            ..Default::default()
        };
        // Same key, blank secret: kept.
        let mut same = form("ahl_aaaaaaaaaaaaaaaa", "");
        keep_stored_secret(&mut same, &stored);
        assert_eq!(same.secret, "old");
        // A different key with a blank secret: not paired with the old one.
        let mut other = form("ahl_bbbbbbbbbbbbbbbb", "");
        keep_stored_secret(&mut other, &stored);
        assert_eq!(other.secret, "");
        // A new secret always wins.
        let mut typed = form("ahl_bbbbbbbbbbbbbbbb", "new");
        keep_stored_secret(&mut typed, &stored);
        assert_eq!(typed.secret, "new");
    }

    #[test]
    fn site_urls_are_strict() {
        use super::is_safe_site_url;
        assert!(is_safe_site_url("https://ahledger.com/download"));
        assert!(is_safe_site_url("https://ahledger.com/connect/ABCD2345"));
        assert!(!is_safe_site_url("https://ahledger.com/connect/AB&calc"));
        assert!(!is_safe_site_url("https://ahledger.com/x|y"));
        assert!(!is_safe_site_url("https://ahledger.com/a b"));
        assert!(!is_safe_site_url("https://ahledger.com/a%26b"));
        assert!(!is_safe_site_url("https://ahledger.com/download?v=1&x"));
        assert!(!is_safe_site_url("https://ahledger.com/../x"));
        assert!(!is_safe_site_url("https://ahledger.com.evil.example/x"));
        assert!(!is_safe_site_url("https://evil.example/https://ahledger.com/"));
    }

    #[test]
    fn pair_codes_and_keys_are_checked() {
        use super::{pair_code_ok, upload_key_ok};
        let secret = "test-secret_not-a-real-key_0123456789abcd";
        assert!(pair_code_ok("ABCD-EFGH"));
        assert!(pair_code_ok("SQ8Y-YTCS"));
        assert!(!pair_code_ok("ABCD-EFG0"));
        assert!(!pair_code_ok("ABCDEFGH"));
        assert!(!pair_code_ok("ABCD-EF&H"));
        assert!(upload_key_ok("ahl_abcdefghij012345", secret));
        assert!(!upload_key_ok("ahl_ABCDEFGHIJ012345", secret));
        assert!(!upload_key_ok("ahl_abcdefghij012345", "short"));
        assert!(!upload_key_ok("ahl_abcdefghij012345", "test-secret_not-a-real-key_0123456789\nab"));
    }

    use super::{
        data_file_for, is_newer, render_contribution, render_price_table, render_pvp_table, render_watch,
        sign,
        Contribution, WatchAnswer, WatchItem,
    };
    use std::fs;

    #[test]
    fn watch_renders_sorted_integer_ids_only() {
        let a = WatchAnswer {
            linked: true,
            at: 1790000100,
            saved_at: 1790000000,
            items: vec![
                WatchItem { id: 12784 },
                WatchItem { id: 2589 },
                WatchItem { id: 2589 },
                WatchItem { id: 0 },
                WatchItem { id: 999_999_999 },
            ],
            dropped: vec![7073, 7073, 0],
        };
        assert_eq!(
            render_watch(&a),
            "AHledgerData.watch = { at = 1790000100, savedAt = 1790000000, items = { [2589] = 1, [12784] = 1 }, dropped = { [7073] = 1 } }\n"
        );
        let empty = WatchAnswer { linked: true, at: 5, saved_at: 0, items: vec![], dropped: vec![] };
        assert_eq!(
            render_watch(&empty),
            "AHledgerData.watch = { at = 5, savedAt = 0, items = {  }, dropped = {  } }\n"
        );
    }

    #[test]
    fn newer_versions_compare_numerically() {
        assert!(is_newer("0.2.7", "0.2.6"));
        assert!(is_newer("0.3.0", "0.2.9"));
        assert!(is_newer("1.0.0", "0.9.9"));
        assert!(is_newer("0.2.10", "0.2.9"));
        assert!(is_newer("v0.2.7", "0.2.6"));
        assert!(!is_newer("0.2.6", "0.2.6"));
        assert!(!is_newer("0.2.5", "0.2.6"));
        assert!(!is_newer("garbage", "0.2.6"));
    }

    #[test]
    fn signature_matches_reference_vector() {
        // Same inputs as the TypeScript signing test on the server side would produce.
        let sig = sign("s3cret", "1", "n", "abc").unwrap();
        assert_eq!(sig.len(), 64);
        assert_eq!(sig, sign("s3cret", "1", "n", "abc").unwrap());
        assert_ne!(sig, sign("other", "1", "n", "abc").unwrap());
    }

    #[test]
    fn contribution_renders_integers_only() {
        let c = Contribution { at: 1790000000, days: 7, scans: 3, listings: 1240, sources: 12, quests: 36, rank: None, contributors: 0 };
        assert_eq!(
            render_contribution(&c),
            "AHledgerData.contribution = { at = 1790000000, days = 7, scans = 3, listings = 1240, sources = 12, quests = 36 }\n"
        );
        // With a rank the line carries it, still integers only.
        let ranked = Contribution { rank: Some(3), contributors: 12, ..c };
        assert_eq!(
            render_contribution(&ranked),
            "AHledgerData.contribution = { at = 1790000000, days = 7, scans = 3, listings = 1240, sources = 12, quests = 36, rank = 3, contributors = 12 }\n"
        );
        let unranked: Contribution = serde_json::from_str(r#"{"ok":true,"scans":1,"rank":null,"contributors":4}"#).unwrap();
        assert!(!render_contribution(&unranked).contains("rank"));
        let parsed: Contribution = serde_json::from_str(r#"{"ok":true,"keyId":"ahl_x","at":5,"days":7,"scans":1,"listings":2,"sources":0,"quests":0}"#).unwrap();
        assert_eq!(parsed.listings, 2);
        let partial: Contribution = serde_json::from_str(r#"{"ok":true}"#).unwrap();
        assert_eq!(partial.scans, 0);
    }

    #[test]
    fn price_table_renders_valid_lua() {
        let text = "AHL1|forever/pvp/horde/us|1789782752|2\n2589:20:18:30:22:21:18:25\n12784:1500000:1400000:2:::1200000:1800000\n";
        let (lua, rows, updated) = render_price_table("forever.pvp.horde.us", text).unwrap().unwrap();
        assert_eq!(rows, 2);
        assert_eq!(updated, 1789782752);
        assert!(lua.starts_with("AHledgerData[\"forever/pvp/horde/us\"] = { updated = 1789782752, count = 2, text = [==[\n"));
        assert!(lua.contains("2589:20:18:30:22:21:18:25;12784:1500000:1400000:2:::1200000:1800000"));
        assert!(lua.ends_with("\n]==] }\n"));
    }

    #[test]
    fn price_table_rejects_anything_that_could_escape_the_lua_string() {
        let good = "AHL1|forever/pvp/horde/us|1789782752|1\n2589:20:18:30:22:21:18:25\n";
        assert!(render_price_table("forever.pvp.horde.us", good).is_ok());
        // Wrong market in the header.
        assert!(render_price_table("forever.normal.horde.us", good).is_err());
        // Market key with characters outside the allowed set.
        assert!(render_price_table("forever.pvp.horde.us", "AHL1|forever/pvp/horde/us\"]|1|1\n1:2\n").is_err());
        // Row with a Lua long-bracket terminator or letters.
        assert!(render_price_table("forever.pvp.horde.us", "AHL1|forever/pvp/horde/us|1|1\n2589:20]==]\n").is_err());
        assert!(render_price_table("forever.pvp.horde.us", "AHL1|forever/pvp/horde/us|1|1\nabc:1\n").is_err());
        // Bad timestamp and bad header.
        assert!(render_price_table("forever.pvp.horde.us", "AHL1|forever/pvp/horde/us|soon|1\n1:2\n").is_err());
        assert!(render_price_table("forever.pvp.horde.us", "AHL2|forever/pvp/horde/us|1|1\n1:2\n").is_err());
        // An empty body is skipped, not an error.
        assert!(render_price_table("forever.pvp.horde.us", "").unwrap().is_none());
    }

    #[test]
    fn pvp_table_renders_letters_and_digits_only() {
        let text = "AHP1|us|1794074400|2\nAlla Jin:5:1234\nPacalkirály Rezsibiztos:0:7\n";
        let (lua, rows) = render_pvp_table("us", text).unwrap().unwrap();
        assert_eq!(rows, 2);
        assert_eq!(
            lua,
            "AHledgerData.pvp = { region = \"us\", updated = 1794074400, count = 2, text = [==[\n;Alla Jin:5:1234;Pacalkirály Rezsibiztos:0:7;\n]==] }\n"
        );
        assert!(render_pvp_table("us", "AHP1|us|1|0\n").unwrap().is_none());
    }

    #[test]
    fn pvp_table_rejects_anything_that_could_escape_the_lua_string() {
        for bad in [
            "AHP1|us|1|1\nAlla]==] Jin:5:1\n",
            "AHP1|us|1|1\nAlla Jin:5:1:9\n",
            "AHP1|us|1|1\nAlla  Jin:5:1\n",
            "AHP1|us|1|1\nAlla Jin\"):5:1\n",
            "AHP1|us|1|1\nAlla Jin:x:1\n",
            "AHP1|us|1|1\nAlla Jin Third:5:1\n",
            "AHP1|us|1|1\nA Jin:5:1\n",
        ] {
            // The bad row is left out; with no other rows there is no table.
            assert!(render_pvp_table("us", bad).unwrap().is_none(), "{bad}");
            let with_good = format!("{bad}Bo Ko:1:2\n");
            let (lua, rows) = render_pvp_table("us", &with_good).unwrap().unwrap();
            assert_eq!(rows, 1, "{bad}");
            assert!(lua.contains("[==[\n;Bo Ko:1:2;\n]==]"), "{lua}");
        }
        // Carriage returns, an empty name part, kills past nine digits: left out too.
        for bad in [
            "AHP1|us|1|1\nAlla Jin:5:1\r\rx\n",
            "AHP1|us|1|1\nAlla :5:1\n",
            "AHP1|us|1|1\nAlla Jin:5:1000000000\n",
        ] {
            assert!(render_pvp_table("us", bad).unwrap().is_none(), "{bad}");
        }
        assert!(render_pvp_table("us", "AHP1|us|soon|1\nAlla Jin:5:1\n").is_err());
        // Past the size ceiling: refused whole.
        let huge = format!("AHP1|us|1|1\n{}", "Alla Jin:5:1\n".repeat(super::MAX_TABLE_BYTES / 10));
        assert!(render_pvp_table("us", &huge).is_err());
        assert!(render_pvp_table("us", "AHP1|eu|1|1\nAlla Jin:5:1\n").is_err());
        assert!(render_pvp_table("us", "AHL1|us|1|1\nAlla Jin:5:1\n").is_err());
    }

    #[test]
    fn data_file_sits_beside_the_installed_addon() {
        let root = std::env::temp_dir().join(format!("ahledger-sync-test-{}", std::process::id()));
        let flavor = root.join("_classic_beta_");
        let sv = flavor.join("WTF").join("Account").join("1#1").join("SavedVariables");
        fs::create_dir_all(&sv).unwrap();
        fs::write(sv.join("AHledger.lua"), "AHledgerDB = {}\n").unwrap();
        let sv_file = sv.join("AHledger.lua");
        // No addon installed: refuse.
        assert!(data_file_for(&sv_file).is_err());
        let addon = flavor.join("Interface").join("AddOns").join("AHledger");
        fs::create_dir_all(&addon).unwrap();
        fs::write(addon.join("AHledger.toc"), "## Interface: 16001\n").unwrap();
        let target = data_file_for(&sv_file).unwrap();
        assert_eq!(target, addon.join("AHledger_Data.lua"));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn scan_file_events_match_by_file_name() {
        use super::is_scan_file_event;
        use std::path::Path;
        assert!(is_scan_file_event(Path::new("/private/var/x/SavedVariables/AHledger.lua")));
        assert!(is_scan_file_event(Path::new("/Volumes/Games/WTF/Account/A/SavedVariables/ahledger.lua")));
        assert!(!is_scan_file_event(Path::new("/x/SavedVariables/AHledger.lua.bak")));
        assert!(!is_scan_file_event(Path::new("/x/SavedVariables/AHledger.lua.tmp")));
        assert!(!is_scan_file_event(Path::new("/x/SavedVariables/Other.lua")));
        assert!(!is_scan_file_event(Path::new("/x/SavedVariables")));
    }

    /// The real watcher, on a folder reached through a symlink, sees the game replace the file.
    /// On macOS the temporary folder is itself behind one (/var is /private/var), so this is the
    /// case that never fired there before is_scan_file_event.
    #[cfg(unix)]
    #[test]
    fn watcher_sees_saves_through_a_symlinked_folder() {
        use super::{is_scan_file_event, SAVED_VARIABLES_FILE};
        use notify::{RecursiveMode, Watcher};
        use notify_debouncer_mini::new_debouncer;
        use std::{sync::mpsc, time::Duration, time::Instant};

        let root = std::env::temp_dir().join(format!("ahledger-sync-watch-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let real = root.join("real");
        let sv = real.join("WTF").join("Account").join("A").join("SavedVariables");
        fs::create_dir_all(&sv).unwrap();
        std::os::unix::fs::symlink(&real, root.join("linked")).unwrap();
        let watched = root.join("linked").join("WTF").join("Account").join("A").join("SavedVariables");
        fs::write(watched.join(SAVED_VARIABLES_FILE), "AHledgerDB = {}\n").unwrap();

        let (tx, rx) = mpsc::channel();
        let mut debouncer = new_debouncer(Duration::from_millis(300), tx).unwrap();
        debouncer.watcher().watch(&watched, RecursiveMode::NonRecursive).unwrap();
        std::thread::sleep(Duration::from_millis(500));
        // The way the game saves: the old file kept as .bak, the new one written in its place.
        fs::rename(watched.join(SAVED_VARIABLES_FILE), watched.join("AHledger.lua.bak")).unwrap();
        fs::write(watched.join(SAVED_VARIABLES_FILE), "AHledgerDB = { n = 2 }\n").unwrap();

        let deadline = Instant::now() + Duration::from_secs(15);
        let mut seen = Vec::new();
        let mut matched = false;
        while !matched && Instant::now() < deadline {
            if let Ok(Ok(events)) = rx.recv_timeout(Duration::from_millis(500)) {
                for e in events {
                    matched |= is_scan_file_event(&e.path);
                    seen.push(e.path);
                }
            }
        }
        drop(debouncer);
        let _ = fs::remove_dir_all(&root);
        assert!(matched, "no event for {SAVED_VARIABLES_FILE}; saw {seen:?}");
    }

    #[test]
    fn replaced_files_are_written_fresh_and_private() {
        use super::write_replace;
        let dir = std::env::temp_dir().join(format!("ahledger-sync-write-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("settings.json");
        // A leftover temporary file from a crash is replaced, not appended to or refused.
        fs::write(dir.join("settings.json.tmp"), "leftover").unwrap();
        write_replace(&path, "json.tmp", b"{\"a\":1}", true).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "{\"a\":1}");
        assert!(!dir.join("settings.json.tmp").exists());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
            // A symlink planted at the temporary name is removed, never written through.
            let victim = dir.join("victim.txt");
            fs::write(&victim, "untouched").unwrap();
            std::os::unix::fs::symlink(&victim, dir.join("settings.json.tmp")).unwrap();
            write_replace(&path, "json.tmp", b"{\"a\":2}", true).unwrap();
            assert_eq!(fs::read_to_string(&victim).unwrap(), "untouched");
            assert_eq!(fs::read_to_string(&path).unwrap(), "{\"a\":2}");
        }
        let _ = fs::remove_dir_all(&dir);
    }
}
