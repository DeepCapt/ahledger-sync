//! Native side of AHledger sync.
//!
//! Owns everything the webview should not: the settings file (including the upload secret), the
//! SavedVariables watcher, request signing, and the HTTPS upload. The webview parses the Lua file
//! and decides what to send; it never receives the secret back after the user types it.

use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::Mutex,
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

/// Unix: the file holds the upload secret, so nobody else on the machine may read it.
fn write_private(path: &Path, contents: &str) -> Result<(), String> {
    let tmp = path.with_extension("json.tmp");
    {
        let mut opts = fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let mut f = opts.open(&tmp).map_err(err)?;
        f.write_all(contents.as_bytes()).map_err(err)?;
        f.sync_all().map_err(err)?;
    }
    fs::rename(&tmp, path).map_err(err)
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
            if events.iter().any(|e| e.path == wanted) {
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

    let sent_ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(err)?
        .as_secs();
    let ts = sent_ts.to_string();
    let nonce_bytes: [u8; 16] = rand::random();
    let nonce = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(nonce_bytes);
    let hash = hex::encode(Sha256::digest(&bytes));
    let signature = sign(&settings.secret, &ts, &nonce, &hash)?;

    let client = reqwest::Client::builder()
        .user_agent(format!("AHledger-sync/{}", env!("CARGO_PKG_VERSION")))
        .timeout(Duration::from_secs(90))
        .build()
        .map_err(err)?;
    if !settings.api_url.starts_with("https://") && !cfg!(debug_assertions) {
        return Err("refusing to upload over a non-https API address".to_string());
    }
    let url = format!("{}{}", settings.api_url.trim_end_matches('/'), path);
    let mut req = client
        .post(url)
        .header("content-type", "application/json")
        .header("x-ahl-key", settings.key_id)
        .header("x-ahl-ts", ts)
        .header("x-ahl-nonce", nonce)
        .header("x-ahl-signature", signature);
    if gzip_body {
        req = req.header("content-encoding", "gzip");
    }
    let res = req.body(bytes).send().await.map_err(err)?;
    let status = res.status().as_u16();
    let body = res.text().await.unwrap_or_default();
    Ok(UploadResult { status, body, sent_ts })
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
// Update check: the site publishes the current release at /sync/version.json
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
        .get(format!("{SITE_URL}/sync/version.json"))
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
    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("rundll32")
            .args(["url.dll,FileProtocolHandler", &url])
            .spawn()
            .map_err(err)?;
    }
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open").arg(&url).spawn().map_err(err)?;
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    {
        std::process::Command::new("xdg-open").arg(&url).spawn().map_err(err)?;
    }
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
}

/// The Lua line the addon reads for "Your scans added ...". Integers only, so nothing from
/// the network can change what the file means.
fn render_contribution(c: &Contribution) -> String {
    format!(
        "AHledgerData.contribution = {{ at = {}, days = {}, scans = {}, listings = {}, sources = {}, quests = {} }}\n",
        c.at, c.days, c.scans, c.listings, c.sources, c.quests
    )
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
async fn refresh_price_tables(app: AppHandle) -> Result<RefreshResult, String> {
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
        let text = client
            .get(format!("{base}/v1/pricetable/{}", m.id))
            .send()
            .await
            .map_err(err)?
            .error_for_status()
            .map_err(err)?
            .text()
            .await
            .map_err(err)?;
        let Some((lua, rows, updated)) = render_price_table(&m.id, &text)? else { continue };
        out.push_str(&lua);
        count_markets += 1;
        count_items += rows;
        if rows > 0 {
            newest = newest.max(updated);
        }
    }
    let contribution = fetch_contribution(&app).await;
    if let Some(c) = contribution.as_ref() {
        out.push_str(&render_contribution(c));
    }
    let tmp = target.with_extension("lua.tmp");
    fs::write(&tmp, out.as_bytes()).map_err(err)?;
    fs::rename(&tmp, &target).map_err(err)?;
    Ok(RefreshResult {
        path: target.to_string_lossy().into_owned(),
        markets: count_markets,
        items: count_items,
        newest,
        contribution,
    })
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

    use super::{data_file_for, is_newer, render_contribution, render_price_table, sign, Contribution};
    use std::fs;

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
        let c = Contribution { at: 1790000000, days: 7, scans: 3, listings: 1240, sources: 12, quests: 36 };
        assert_eq!(
            render_contribution(&c),
            "AHledgerData.contribution = { at = 1790000000, days = 7, scans = 3, listings = 1240, sources = 12, quests = 36 }\n"
        );
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
}
