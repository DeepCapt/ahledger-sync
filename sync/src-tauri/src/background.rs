//! Running in the background (0.2.29): a notification-area icon, hiding the window instead of
//! quitting, and starting when the player signs in to Windows. Both options are off unless the
//! player turns them on in the window; nothing here runs, and nothing is written outside the
//! app's own settings file, until they do. An unsigned app that registers itself to run at boot
//! is a classic antivirus pattern, so the startup entry is one plain value in the current user's
//! Run key, written only when the player ticks the box and removed when they untick it. The
//! only registry access without a tick is reading whether that value is still there, and
//! deleting it when the settings say it should be off.

use std::sync::atomic::{AtomicBool, Ordering};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, Runtime, WebviewWindow, WindowEvent};

/// The argument the startup entry passes, so a start at sign-in opens out of the way.
pub const AUTOSTART_FLAG: &str = "--autostart";
const TRAY_ID: &str = "ahledger-sync";
const MAIN_WINDOW: &str = "main";

/// Whether background mode is in force right now (the icon exists), so window events do not
/// read the settings file. It can be false while the settings say true: the icon could not be
/// made, and the app then behaves, and reports itself, as a normal window.
static RUN_IN_BACKGROUND: AtomicBool = AtomicBool::new(false);

pub fn run_in_background() -> bool {
    RUN_IN_BACKGROUND.load(Ordering::Relaxed)
}

/// Brings the window back: shown, restored if minimized, in front. Done in one go on the main
/// thread, so a window event cannot land between the steps.
pub fn show_main<R: Runtime>(app: &AppHandle<R>) {
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(w) = handle.get_webview_window(MAIN_WINDOW) {
            let _ = w.show();
            let _ = w.unminimize();
            let _ = w.set_focus();
        }
    });
}

/// Turns the background mode on or off now: the icon is added or removed, and with it off a
/// hidden window is shown again so the app is never left running with no way back to it.
pub fn apply_run_in_background<R: Runtime>(app: &AppHandle<R>, enabled: bool) -> Result<(), String> {
    let exists = app.tray_by_id(TRAY_ID).is_some();
    if enabled && !exists {
        // No icon means no way back to a hidden window: stay a normal window.
        build_tray(app)?;
    } else if !enabled && exists {
        let _ = app.remove_tray_by_id(TRAY_ID);
    }
    RUN_IN_BACKGROUND.store(enabled, Ordering::Relaxed);
    if !enabled {
        let hidden = app
            .get_webview_window(MAIN_WINDOW)
            .map(|w| !w.is_visible().unwrap_or(true))
            .unwrap_or(false);
        if hidden {
            show_main(app);
        }
    }
    Ok(())
}

fn build_tray<R: Runtime>(app: &AppHandle<R>) -> Result<(), String> {
    let e = |x: tauri::Error| x.to_string();
    let open = MenuItem::with_id(app, "open", "Open AHledger sync", true, None::<&str>).map_err(e)?;
    let quit = MenuItem::with_id(app, "quit", "Quit AHledger sync", true, None::<&str>).map_err(e)?;
    let menu = Menu::with_items(app, &[&open, &quit]).map_err(e)?;
    let icon = app
        .default_window_icon()
        .cloned()
        .ok_or_else(|| "no app icon for the notification area".to_string())?;
    TrayIconBuilder::with_id(TRAY_ID)
        .icon(icon)
        .tooltip("AHledger sync")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_main(app),
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                show_main(tray.app_handle());
            }
        })
        .build(app)
        .map_err(e)?;
    Ok(())
}

/// With background mode on, closing or minimizing hides the window to the notification area;
/// with it off, both do what they always did.
pub fn on_window_event<R: Runtime>(window: &tauri::Window<R>, event: &WindowEvent) {
    if window.label() != MAIN_WINDOW || !run_in_background() {
        return;
    }
    match event {
        WindowEvent::CloseRequested { api, .. } => {
            api.prevent_close();
            let _ = window.hide();
        }
        WindowEvent::Resized(_) => {
            if window.is_minimized().unwrap_or(false) {
                let _ = window.hide();
            }
        }
        _ => {}
    }
}

/// The window starts hidden (tauri.conf.json); this shows it, unless the app was started at
/// sign-in: then it stays in the notification area with background mode on, or opens minimized.
/// It stays hidden only when the icon is really there: Windows can fail to add an icon while the
/// shell is still busy at sign-in, and the tray library reports success anyway, so a hidden
/// window would have no way back. No set_focus here: show() brings a new window forward, and a
/// failed set_focus makes tao fake an Alt key press to force it.
pub fn show_on_start<R: Runtime>(window: &WebviewWindow<R>, started_at_sign_in: bool) {
    if started_at_sign_in && run_in_background() && icon_is_shown(window.app_handle()) {
        return;
    }
    let _ = window.show();
    if started_at_sign_in {
        let _ = window.minimize();
    }
}

/// Whether the notification-area icon exists as far as the shell is concerned. An icon tucked
/// under the ^ overflow still counts. Retried briefly, since the shell can be slow at sign-in.
fn icon_is_shown<R: Runtime>(app: &AppHandle<R>) -> bool {
    let Some(tray) = app.tray_by_id(TRAY_ID) else {
        return false;
    };
    for attempt in 0..5 {
        if matches!(tray.rect(), Ok(Some(_))) {
            return true;
        }
        if attempt < 4 {
            std::thread::sleep(std::time::Duration::from_millis(200));
        }
    }
    false
}

pub fn started_at_sign_in() -> bool {
    std::env::args().skip(1).any(|a| a == AUTOSTART_FLAG)
}

/// The startup entry's command line: the app, quoted, and the flag.
#[cfg(any(windows, test))]
pub fn autostart_command(exe: &std::path::Path) -> String {
    format!("\"{}\" {}", exe.display(), AUTOSTART_FLAG)
}

#[cfg(windows)]
mod win {
    use winreg::enums::{HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_SET_VALUE};
    use winreg::RegKey;

    const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
    /// The value's name: the product name, which Tauri's NSIS uninstaller deletes from this key
    /// on uninstall (and when a newer setup removes the old copy first), so uninstalling never
    /// leaves the entry behind.
    pub const VALUE_NAME: &str = "AHledger sync";

    pub fn set_named(name: &str, enabled: bool) -> Result<(), String> {
        let key = RegKey::predef(HKEY_CURRENT_USER)
            .open_subkey_with_flags(RUN_KEY, KEY_SET_VALUE | KEY_QUERY_VALUE)
            .map_err(|e| format!("could not open the Windows startup list: {e}"))?;
        if enabled {
            let exe = std::env::current_exe().map_err(|e| e.to_string())?;
            key.set_value(name, &super::autostart_command(&exe))
                .map_err(|e| format!("could not add AHledger sync to Windows startup: {e}"))
        } else {
            match key.delete_value(name) {
                Ok(()) => Ok(()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(e) => Err(format!("could not remove AHledger sync from Windows startup: {e}")),
            }
        }
    }

    /// Read only: whether the value is there. Only "not found" means absent; any other error
    /// (access denied, say) is unknown, and an unknown answer never changes a setting.
    pub fn present_named(name: &str) -> Result<bool, String> {
        match RegKey::predef(HKEY_CURRENT_USER)
            .open_subkey_with_flags(RUN_KEY, KEY_QUERY_VALUE)
            .and_then(|k| k.get_raw_value(name))
        {
            Ok(_) => Ok(true),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e.to_string()),
        }
    }

    /// Read only: whether the player turned the entry off in Task Manager or Settings > Apps >
    /// Startup. Windows keeps that choice beside the Run value, in StartupApproved, as a binary
    /// value whose first byte is odd when the entry is disabled. Never written here: that choice
    /// is the player's and Windows'.
    pub fn disabled_named(name: &str) -> bool {
        const APPROVED_KEY: &str =
            r"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
        RegKey::predef(HKEY_CURRENT_USER)
            .open_subkey_with_flags(APPROVED_KEY, KEY_QUERY_VALUE)
            .and_then(|k| k.get_raw_value(name))
            .map(|v| v.bytes.first().is_some_and(|b| b & 1 == 1))
            .unwrap_or(false)
    }
}

/// Adds or removes the startup entry. Windows only; elsewhere the option is not offered.
pub fn set_start_with_windows(enabled: bool) -> Result<(), String> {
    #[cfg(windows)]
    {
        win::set_named(win::VALUE_NAME, enabled)
    }
    #[cfg(not(windows))]
    {
        let _ = enabled;
        Ok(())
    }
}

/// Whether the startup entry exists (a read; never writes): None when it could not be read.
/// Always Some(false) off Windows.
pub fn start_with_windows_present() -> Option<bool> {
    #[cfg(windows)]
    {
        win::present_named(win::VALUE_NAME).ok()
    }
    #[cfg(not(windows))]
    {
        Some(false)
    }
}

/// Whether Windows has the startup entry turned off (Task Manager or Settings). A read.
pub fn start_with_windows_disabled_by_windows() -> bool {
    #[cfg(windows)]
    {
        win::disabled_named(win::VALUE_NAME)
    }
    #[cfg(not(windows))]
    {
        false
    }
}

/// One copy at a time. With the window hidden in the notification area, opening the app again
/// from the Start menu would otherwise start a second copy watching and uploading the same file.
/// The first copy holds a named mutex and waits on a named event; a second copy sets the event
/// (the first then shows its own window through Tauri, see listen_for_second_copy) and exits.
/// Returns false in a second copy.
#[cfg(windows)]
pub fn claim_single_instance() -> bool {
    use windows_sys::Win32::Foundation::{
        CloseHandle, GetLastError, ERROR_ACCESS_DENIED, ERROR_ALREADY_EXISTS,
    };
    use windows_sys::Win32::System::Threading::{CreateEventW, CreateMutexW, SetEvent};
    use windows_sys::Win32::UI::WindowsAndMessaging::{AllowSetForegroundWindow, ASFW_ANY};
    let mutex_name = wide(r"Local\com.ahledger.sync.single-instance");
    let event_name = wide(r"Local\com.ahledger.sync.show-window");
    // The mutex handle is kept for the life of the process on purpose: it is the claim.
    let mutex = unsafe { CreateMutexW(std::ptr::null(), 0, mutex_name.as_ptr()) };
    let last_error = unsafe { GetLastError() };
    // Access denied: a copy started as administrator holds the mutex with an admin-only access
    // list. It is running all the same; a second copy would upload the same file twice.
    let already_running = if mutex.is_null() {
        last_error == ERROR_ACCESS_DENIED
    } else {
        last_error == ERROR_ALREADY_EXISTS
    };
    // Open-or-create in both copies (auto-reset, not signalled): a second copy started before
    // the first made the event still leaves the signal for the first copy's listener.
    let event = unsafe { CreateEventW(std::ptr::null(), 0, 0, event_name.as_ptr()) };
    if !already_running {
        SHOW_EVENT.store(event as usize, Ordering::Relaxed);
        return true;
    }
    if !event.is_null() {
        unsafe {
            // Lets the first copy bring its window to the front for the player who just
            // opened the app.
            AllowSetForegroundWindow(ASFW_ANY);
            SetEvent(event);
            CloseHandle(event);
        }
    }
    false
}

#[cfg(windows)]
fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// The first copy's show-window event, kept as an address so it can cross to the listener.
#[cfg(windows)]
static SHOW_EVENT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// In the first copy: shows the window each time a second copy is opened.
#[cfg(windows)]
pub fn listen_for_second_copy<R: Runtime>(app: &AppHandle<R>) {
    use windows_sys::Win32::Foundation::WAIT_OBJECT_0;
    use windows_sys::Win32::System::Threading::{WaitForSingleObject, INFINITE};
    let event = SHOW_EVENT.load(Ordering::Relaxed);
    if event == 0 {
        return;
    }
    let app = app.clone();
    std::thread::spawn(move || loop {
        let signalled = unsafe { WaitForSingleObject(event as _, INFINITE) };
        if signalled != WAIT_OBJECT_0 {
            return;
        }
        show_main(&app);
    });
}

#[cfg(not(windows))]
pub fn claim_single_instance() -> bool {
    true
}

#[cfg(not(windows))]
pub fn listen_for_second_copy<R: Runtime>(_app: &AppHandle<R>) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_startup_entry_quotes_the_path_and_passes_the_flag() {
        let cmd = autostart_command(std::path::Path::new(
            r"C:\Users\A Player\AppData\Local\AHledger sync\ahledger-sync.exe",
        ));
        assert_eq!(
            cmd,
            "\"C:\\Users\\A Player\\AppData\\Local\\AHledger sync\\ahledger-sync.exe\" --autostart"
        );
    }

    /// Writes a test value (never the real one) in the current user's Run key, so it only runs
    /// when asked for: `cargo test -- --ignored startup_entry`. A guard removes the value even
    /// if an assertion fails.
    #[cfg(windows)]
    #[test]
    #[ignore]
    fn the_startup_entry_is_added_and_removed_and_removing_twice_is_fine() {
        const NAME: &str = "AHledger sync (test run)";
        struct Cleanup;
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = win::set_named(NAME, false);
            }
        }
        let _cleanup = Cleanup;
        win::set_named(NAME, true).unwrap();
        assert_eq!(win::present_named(NAME), Ok(true));
        assert!(!win::disabled_named(NAME));
        win::set_named(NAME, false).unwrap();
        assert_eq!(win::present_named(NAME), Ok(false));
        win::set_named(NAME, false).unwrap();
    }
}
