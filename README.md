# AHledger sync and the AHledger addon

The source of the two programs that run on a player's machine for [AHledger](https://ahledger.com),
the World of Warcraft: Forever auction house site: the **AHledger addon** (in game) and
**AHledger sync** (the optional Windows app that connects it to the site). It is published so you
can read exactly what they do, and build sync yourself if you would rather not run our installer.

The website, API and database are not part of this repository.

## What the addon does

Plain Lua in [`addon/AHledger`](addon/AHledger), the same files the CurseForge and Wago downloads
contain. It reads the auction house through the API Blizzard gives every addon, the same call
Auctionator and TSM use, and it automates nothing: no buying, bidding, posting or cancelling. A scan
is saved in the game's own SavedVariables file (`WTF/Account/<account>/SavedVariables/AHledger.lua`)
as item ids, quantities, buyout and bid prices, the market and the time. It holds no character
names, no seller names and no account data. Addons cannot reach the internet; that is why sync
exists.

## What sync does

[`sync`](sync) is a small [Tauri 2](https://tauri.app) app: a Rust side
([`sync/src-tauri/src/lib.rs`](sync/src-tauri/src/lib.rs)) and a web view
([`sync/src/main.ts`](sync/src/main.ts)).

- **Reads one file:** the addon's `AHledger.lua` SavedVariables file. Only paths of the shape
  `WTF/Account/<account>/SavedVariables/AHledger.lua` can be read or watched.
- **Sends** new scans, and the item sources and quest facts the addon records, to
  `https://api.ahledger.com`, each request signed with your upload key (HMAC-SHA256). Only
  `https://` addresses are accepted in release builds. Turn off Contribute scans in the addon and
  nothing is sent.
- **Downloads** the price tables for the Forever markets every 30 minutes and writes them to
  `Interface/AddOns/AHledger/AHledger_Data.lua`, which is how tooltips get fresh prices.
- **Stores** its settings, including the upload key secret, in your user profile's app config
  folder. The secret stays on the Rust side: the window never receives it back.
- **Opens web pages** only on ahledger.com (the download page, and the Connect approval page),
  through a strict address check.
- **Installs for the current user only** and needs no administrator rights. It checks
  `https://ahledger.com/sync/version.json` at start and once a day to say when a new version is
  out; it does not update itself.

The shared parsing code the website's API uses to read the same file is in [`shared`](shared).

## Verify a download

Every release on [ahledger.com/download](https://ahledger.com/download) lists the installer's
SHA-256. On Windows:

```powershell
Get-FileHash .\AHledger-sync-<version>-setup.exe -Algorithm SHA256
```

Builds are not byte-for-byte reproducible (the installer embeds build timestamps), so a hash you
build yourself will differ from ours; building it yourself is the way to run code you have read.

## Build sync yourself

Needs Node 20 or newer, pnpm, Rust stable, and on Windows the Visual Studio C++ build tools and
WebView2 (already on Windows 11).

```sh
cd sync
pnpm install
pnpm tauri build     # installer under src-tauri/target/release/bundle/nsis
```

`pnpm tauri dev` runs it with a development window.

## Install the addon from source

Copy [`addon/AHledger`](addon/AHledger) into
`World of Warcraft/_classic_/Interface/AddOns/`. The CurseForge and Wago downloads also carry a
snapshot of current prices (`AHledger_Seed.lua`); here that file is an empty placeholder.

## License

Source-available, all rights reserved: see [LICENSE](LICENSE). You may read the code and build it
for your own use to check what it does. It is not licensed for redistribution or reuse.

## Contact

Questions and reports: the contact form at [ahledger.com/contact](https://ahledger.com/contact).

AHledger is an independent product and is not affiliated with or endorsed by Blizzard
Entertainment. World of Warcraft is a trademark of Blizzard Entertainment, Inc.
