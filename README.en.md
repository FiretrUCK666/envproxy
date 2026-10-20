# EnvProxy — automatic proxy for your terminal

[![check](https://github.com/FiretrUCK666/envproxy/actions/workflows/check.yml/badge.svg)](https://github.com/FiretrUCK666/envproxy/actions/workflows/check.yml)
[![release](https://img.shields.io/github/v/release/FiretrUCK666/envproxy)](https://github.com/FiretrUCK666/envproxy/releases)
[![license](https://img.shields.io/github/license/FiretrUCK666/envproxy?v=1)](LICENSE)
[![stars](https://img.shields.io/github/stars/FiretrUCK666/envproxy?v=1)](https://github.com/FiretrUCK666/envproxy/stargazers)

[中文](README.md)

<p align="center">
  <img src="./assets/readme/hero.en.svg" width="100%" alt="EnvProxy: while your proxy app is connected, the terminal goes through it; when you disconnect, the terminal is direct again. On the right is a real excerpt from the status output.">
</p>

<p align="center">
  <b><a href="https://github.com/FiretrUCK666/envproxy/releases/latest/download/EnvProxy-win.zip">Download the Windows build</a></b> · <b><a href="https://github.com/FiretrUCK666/envproxy/releases/latest/download/EnvProxy-mac.tar.gz">Mac build here</a></b> · unzip anywhere, then double-click <code>打开菜单.cmd</code> in <code>win</code> (on Mac, in <code>mac</code>) — see <a href="#1-install-3-steps-5-minutes">section 1</a>
</p>

> Connect your proxy app and the terminal follows. Disconnect it and the terminal goes direct again. Nothing to operate, no admin rights, and nothing left behind in your system configuration.

**Who it is for**: people who use a proxy app and also run command line tools — `git`, `npm`, `curl`, and CLI tools such as dsh or OpenCode.

**Who it is not for**: TUN mode users (all traffic is already captured, the terminal works anyway), people who only need their browser to go through the proxy, and people who never open a terminal.

## Contents

<!-- toc:start -->

- [What it does](#what-it-does)
- [1. Install (3 steps, 5 minutes)](#1-install-3-steps-5-minutes)
- [1.5 Updating](#15-updating)
- [2. The menu](#2-the-menu)
- [2.5 The log (monitor.log)](#25-the-log-monitorlog)
- [3. Day to day (nothing to do after install)](#3-day-to-day-nothing-to-do-after-install)
- [4. How it decides whether the proxy is working](#4-how-it-decides-whether-the-proxy-is-working)
- [5. Why it rarely gets it wrong](#5-why-it-rarely-gets-it-wrong)
- [6. Troubleshooting](#6-troubleshooting)
- [7. Performance and traffic](#7-performance-and-traffic)
- [8. What is inside the folder](#8-what-is-inside-the-folder)
- [9. Copying the folder as a backup](#9-copying-the-folder-as-a-backup)
- [10. Deploying to a friend or a new machine](#10-deploying-to-a-friend-or-a-new-machine)
- [11. Technical limits (5 points)](#11-technical-limits-5-points)
- [12. macOS](#12-macos)
- [13. License and feedback](#13-license-and-feedback)

<!-- toc:end -->

## What it does

Your proxy app lets the browser through, but `git`, `npm`, `curl` and friends do not read its settings — they only read environment variables.
EnvProxy fills that gap: it watches whether your proxy app is actually carrying traffic, writes the proxy into the environment variables when it is, and removes them when it is not.

| What you do | Without EnvProxy | With EnvProxy |
|---|---|---|
| Connect the proxy app | The browser works, the terminal does not: command line tools slow down or time out, and anything that reads environment variables cannot connect at all | The terminal goes through the proxy too |
| Disconnect the proxy app | The proxy variables stay behind and the terminal reports connection refused | The variables are removed and the terminal is direct again |
| Change the port, or switch to another proxy app | Copy the port by hand, set the variables by hand, remember to undo it later | The new port is found and applied automatically |

### Which variables it sets

Written as one set while the proxy is up, removed as one set when it goes down:

| Variable | Value | Purpose |
|---|---|---|
| `HTTP_PROXY` | `http://127.0.0.1:PORT` | proxy for http:// requests |
| `HTTPS_PROXY` | `http://127.0.0.1:PORT` | proxy for https:// requests |
| `ALL_PROXY` | `http://127.0.0.1:PORT` | catch-all for protocols the specific variables miss |
| `NO_PROXY` | `localhost,127.0.0.1,::1` | local addresses bypass the proxy |
| `NODE_USE_ENV_PROXY` | `1` | lets newer Node based tools (native fetch) read the proxy from the environment |

The proxy value always uses the `http://` form rather than `socks5://`. Local proxy ports answer both protocols, while some tools only accept `http://`, so the `http://` form covers the most ground with no downside.

Windows gets 5 variables, macOS gets 9 — the same 5 plus lowercase spellings. This is a platform difference, not something missing: on Windows variable names are case insensitive, so a lowercase copy would only overwrite the uppercase one, while on macOS the two spellings are separate variables and some tools read only the lowercase one.

<details>
<summary>Why these choices (nothing here affects normal use)</summary>

- No `socks5://`: some tools (dsh, for example) warn about SOCKS values and skip them, while a local mixed port answers HTTP anyway.
- No lowercase copies on Windows: they are the same variable there, and the duplicate makes .NET based hosts throw `An item with the same key has already been added` when they build their environment table, which affects everything started from that terminal window.
- IPv6 in `NO_PROXY` is written bare as `::1`. Written as `[::1]` httpx treats it as an ordinary domain name, builds an invalid match pattern, and then fails every request with `InvalidURL`. Square brackets belong to URL literals, not here.
- Your own `NO_PROXY` entries are never removed — the tool only adds to them — and uninstalling removes only the values this tool wrote.
- If something else damages a variable (overwrites, clears, or drops one), it does not matter: the monitor re-checks the whole table every 60–90 seconds and fills in what is missing.
- The tools below do not read these 5 variables — configure them separately (not a bug in this tool):

| Tool | Where to configure it |
|---|---|
| Maven | `<proxies>` in `settings.xml` |
| Gradle | `systemProp.http(s).proxyHost/Port` in `gradle.properties` |
| Native JDK HttpClient | JVM system properties (or `java.net.useSystemProxies` for the system proxy) |
| `docker pull` in Docker Desktop | Docker Desktop's own settings (it ignores proxy settings in `daemon.json`) |

- `NODE_USE_ENV_PROXY` only works on recent Node: `node:http(s)` needs 22.21 / 24.5 or later, `fetch()` needs 22.21 / 24.0 or later. On older versions it does nothing, which is expected.

</details>

## 1. Install (3 steps, 5 minutes)

1. Click **[download the Windows package](https://github.com/FiretrUCK666/envproxy/releases/latest/download/EnvProxy-win.zip)** (Mac: [`EnvProxy-mac.tar.gz`](https://github.com/FiretrUCK666/envproxy/releases/latest/download/EnvProxy-mac.tar.gz))
2. Unzip it anywhere — rename the folder if you like. Open `win` and double-click **`打开菜单.cmd`** (on Mac, open `mac` and double-click **`打开菜单.command`**), then choose **`1 Install / Fix`**
3. When you see the monitor started message, you are done

Installing does four things: it snapshots existing variables with the same names first (used to restore them on uninstall), registers the monitor to start at login, starts it right away, and corrects the environment variables once.

<img src="./assets/readme/first-run.en.svg" width="100%" alt="Install in three steps: download your platform's package, double-click the menu and choose Install, see the monitor started message; below, a side by side comparison: windows that are already open stay unchanged, newly opened ones pick the proxy up right away">

If anything seems off, open the menu and choose **`1 Install / Fix`**. It is the universal fix: it will not install twice, will not drop your connection, and will not lose anything.

> If the first double-click is blocked on a package downloaded from the web: right-click the file, Properties, Unblock (or run `Unblock-File` once) — do not change the execution policy.

## 1.5 Updating

Choose **`5 Check for updates`** in the menu: it shows the new version and what the release changed, and installs only after you agree.

- **No VPN needed for this**: most networks work as they are. If it ever says it cannot connect, toggle your proxy app once and retry.
- **Checked before install**: the download is compared against the checksum GitHub publishes, and a mismatch is refused — a broken install is worse than no install.
- **Only program files are touched**: your own files, the log and the run markers in `monitor\` stay as they are, and the monitor restarts on the new code afterwards.
- **Failures say why**: cannot connect, rate limited, GitHub trouble, a bad package — each with its own next step, so nothing is left to guess.

<details>
<summary>Updating from a terminal instead</summary>

Windows: `powershell -ExecutionPolicy Bypass -File win\envproxy.ps1 -Update` (add `-Yes` to skip the prompt)

Mac: `bash mac/envproxy.sh update` (add `--yes` to skip the prompt)

Exit codes: `0` success; `1` failed (the message says why); `2` wrong argument.

</details>

> A normal install updates in place. A `git clone` copy is left alone; sync it with `git pull` (see section 13).

## 2. The menu

Only one thing lives in `win\` to double-click (in `mac/` on Mac). The rest stays out of your way:

| Menu item | What it does | When to use it |
|---|---|---|
| **1 Install / Fix** | registers start at login + starts the monitor + corrects the variables | first install; any time something feels wrong |
| **2 Show status** | shows monitor, start at login, proxy state, variables, version, recent log | you want to confirm it is working |
| **3 Stop monitor** | stops the monitor and deletes the variables (direct connection immediately), keeps start at login so it returns on the next boot | you want to pause it |
| **4 Full restore** | stops the monitor, deletes the variables, removes start at login, the locator and the path record | you are done with it |
| **5 Check for updates** | checks the latest release, shows what changed, installs after you agree | you want to upgrade |

If you remember nothing else: **open the menu — 1 fixes everything, 2 checks, 3 pauses, 4 uninstalls, 5 upgrades.**

"The monitor" in the menu is this tool's background checker; "Full restore" means uninstalling cleanly.

Choosing "Full restore" stops and asks one question: keep the log? Press Enter to keep it, type `N` and press Enter to delete it along with everything else.

No menu item deletes the `EnvProxy` folder itself. After uninstalling, nothing is left in the system, and the folder stays where it is — keep it for later or delete the whole folder yourself.

<img src="./assets/readme/buttons.en.svg" width="100%" alt="Which parts each menu item touches: Install writes start at login, starts the monitor and writes the variables; Stop stops the monitor and clears the variables while keeping start at login; Restore clears everything and keeps only the log; Status and Check for updates are read only">

## 2.5 The log (monitor.log)

`win\monitor\monitor.log` (on Mac, `mac\monitor\`) records state changes: when the variables were written, when they were removed, the monitor starting and stopping, self-healing of start at login, and any errors. While everything is stable it writes nothing at all. The file is capped at 200KB and is truncated to the most recent 200 lines when it grows past that, so it never gets bigger over the years.

It is the black box for troubleshooting. When you report a problem, include the relevant recent lines — in most cases that is enough to see what happened.

## 3. Day to day (nothing to do after install)

| What you do | What it does | How long |
|---|---|---|
| Connect the proxy app | sees the proxy working, writes the variables | 4–10 seconds (up to about 30 seconds for apps and ports that are not in the common tables) |
| Disconnect or quit the proxy app | sees it gone, removes the variables | about 5 seconds after quitting; about 15–50 seconds after disconnecting (usually around twenty) |
| Change the port, reconnect | finds the new port and applies it | about 10 seconds |
| Reconnect after disconnecting | sees the node is back and restores the variables | about 3 seconds |

<details>
<summary>Other cases (also nothing to do)</summary>

| What you do | What it does |
|---|---|
| Switch to another proxy app | finds the new app's port in a few seconds |
| Run two proxy apps at once | uses the one that verifies, the other takes over when the first stops |
| Connect and disconnect quickly | the jitter is absorbed, the variables do not move |
| Reboot | corrects leftover variables right after login |
| Move the folder somewhere else | the old monitor exits by itself, the next start comes from the new location (search range in section 11, point 3) |

</details>

<img src="./assets/readme/states.en.svg" width="100%" alt="Day to day in three states: connecting writes the variables, disconnecting removes them, new ports and flapping are followed automatically — nothing to do">

## 4. How it decides whether the proxy is working

<p align="center">
  <img src="./assets/readme/mechanism.en.svg" width="100%" alt="Three layer verification: every 2-3 seconds it checks whether a local port is listening, whether that port really forwards requests, and whether the outside world is reachable through it. All three passing means the proxy variables are written; any layer failing means the whole set is removed.">
</p>

Every 2–3 seconds it checks whether any local port is listening. If one is, it verifies two more things: whether that port behaves like a real proxy, and whether the outside world is reachable through it.
All three passing counts as being behind a proxy, and the variables are written. Any layer failing counts as not being behind one, so the variables are removed and the terminal goes direct — "disconnected but the app's core is still running" lands here.

It does not care about brands, process names or port numbers; it only cares who is really serving as a proxy. Clash, v2rayN, Shadowsocks, Hiddify, sing-box, NekoBox, Surge and others all work, and switching apps or ports needs no configuration change.

## 5. Why it rarely gets it wrong

| Mechanism | What it prevents |
|---|---|
| Two round confirmation | changes happen only after the state is confirmed twice — connecting and disconnecting within seconds will not make the variables flip |
| Conservative disconnect | two conditions must both hold before the variables are removed: 10 seconds of continuous failure, and at least 3 probes that could not get through. One success is accepted immediately. Removing the variables notifies every application, so the cost of being wrong is much higher than waiting a little |
| Several outside sites agree | 7 different sites are used together; normally only the one that worked last time is asked, and others only when it fails, so one site having a bad day never deletes your variables |
| Cheap probing | while everything is healthy each port is probed at most once every 15 seconds, and only the response headers are read, not the body, so each probe stays under 1KB. When something looks wrong the interval shortens to every 5 seconds, and it keeps watching for another minute after the question is settled just to be sure it was not a brief glitch |
| One monitor process only | a single instance lock, so processes do not pile up |
| Local dev servers are not proxies | a listening port is not enough; it must really forward requests, so a local service on 8080 or 8888 is never mistaken for a proxy |

<details>
<summary>The remaining safeguards (nothing here affects normal use)</summary>

| Mechanism | What it prevents |
|---|---|
| Startup correction | variables are corrected right after login, so dead ports left over from shutdown disappear at once |
| Snapshot before install | variables with the same names are snapshotted before they are overwritten, and restored on uninstall — only our own values are ever removed |
| Monitor self exit | if the folder is moved or deleted, the monitor notices within 2–3 seconds, exits, removes the injected variables first and then cleans up the old location |
| Locator clean-up | if the machine is shut down before the monitor can exit, the locator removes the leftovers from the old location on the next boot; if no new location is found it also clears leftover proxy variables so new terminals stop reading stale ones |
| Activity based location | all search roots are collected first and then sorted by log activity, so a copied backup folder is never picked up by mistake |
| Graceful cross-location stop | stopping a monitor in another location writes the signal into that monitor's own folder, so it exits gracefully instead of being killed |
| Self healing start at login | every 30 rounds (about 60–90 seconds) it checks and puts the login item back if it was cleared or is out of date |
| Candidate testing | candidate ports are tested in order, the one that worked last time is preferred, and two apps running side by side hand over automatically |

</details>

## 6. Troubleshooting

| Symptom | Cause | What to do |
|---|---|---|
| The terminal still cannot reach the internet after installing | the terminal was opened before the install, and windows already open never change by themselves | open a new window first; if it still shows the old values, close the whole terminal application and start it again (a limit of the operating system, not of this tool) |
| Variables are not removed after disconnecting | the app's disconnect does not stop its core, and the node is still reachable | expected. Quit the proxy app if you want it to stop right away |
| Variables are removed and then come back | your node itself is flapping, and the monitor reports what it sees | expected behaviour. If it keeps happening the node is poor quality; switch to another one |
| A tool reports `An item with the same key has already been added`, or cannot read all variables | the session carries two spellings of the same variable (`HTTP_PROXY` and `http_proxy`) | close that terminal and everything started from it. The registry itself is clean, so no logout is needed |
| The proxy app is connected, but the variables are reported as removed | the outside sites it checks against are temporarily unreachable | it tries other sites, so one of them failing should not trigger this. If it still happens, open the menu and choose "Install / Fix" once |
| The log shows a detection error | a single round failed, the whole run is unaffected | ignore it, it recovers. If it keeps appearing, open the menu and choose "Install / Fix" once |

<details>
<summary>Updates and the command line</summary>

| Symptom | Cause | What to do |
|---|---|---|
| Update check reports a check failure | the message says which kind of failure it is: unreachable, GitHub rate limit, server error, or something else | follow the message: for **unreachable**, toggle your proxy app once and retry; for **rate limit** (60 requests per hour), wait an hour; for a **server error**, retry in a while |
| An error during an update | the download, extraction, verification or write step failed; the message says which kind of failure it is | follow the message; or download the package by hand, unzip it over the folder and open the menu to run "Install / Fix" once |
| A command line update exits with a code other than 0 | the exit code is there for scripts: 1 = it did not succeed (the message says why), 2 = the argument or subcommand is wrong | 1: follow the message (see the rows above); 2: copy the command correctly — Windows only knows `-Update`, Mac only knows `update` |
| It says the argument is wrong and exits with code 2 | a switch has to follow the command it belongs to: `-Purge` only with `-Uninstall`, `-Yes` only with `-Update`; on Mac `--purge` only with `uninstall` and `--yes` only with `update` | move the switch behind its command: on Windows `powershell -File win\envproxy.ps1 -Uninstall -Purge`, on Mac `bash mac/envproxy.sh uninstall --purge` |
| "This version does not provide a package" | that release did not get its package uploaded | download your platform's package from the Releases page by hand, unzip it over the folder and open the menu to run "Install / Fix" once. Nothing is wrong with your machine |
| "The GitHub API quota is exhausted" | anonymous access to the GitHub API allows 60 requests per hour per IP, and asking too often gets you rate limited | it clears by itself after an hour. Meanwhile you can download the package by hand from the Releases page |

</details>

<details>
<summary>Install, uninstall and special cases</summary>

| Symptom | Cause | What to do |
|---|---|---|
| The folder contains `AGENTS.md`, `CONTRIBUTING.md`, `.github` or `tests/` | you cloned the whole repository — only a clone has these developer files; no package downloaded from the site (installer, source code or branch) contains them | for daily use download your platform's package from Releases; keep the clone for code and sync it with `git pull` |
| "This is a development copy" | the folder contains `.git`, so it is a git working tree | expected: the updater leaves git copies alone, use `git pull` to sync |
| You want to undo everything | — | open the menu and choose "Full restore", then answer the log question |
| The terminal already works under TUN / enhanced mode | traffic is captured globally, so with no local port detected nothing is written | expected, nothing to do (either state is correct) |
| Install or start at login is blocked by antivirus | Run keys and scripts in user folders are heuristic engines' favourite suspects | "Install / Fix" in the menu reads the setting back and tells you when it did not stick; whitelist the install folder (in Huorong, turn off HTTPS scanning features first) and do not turn the antivirus off |
| After "Install / Fix" it reports the monitor could not be confirmed | a second copy on the same machine already holds the single-instance lock (only one monitor runs at a time), or the launch was blocked | open the menu and choose "Show status" to see the real state; if you no longer need that other copy, run "Full restore" inside its folder, then choose "Install / Fix" once |
| Browsers cannot open pages, but the terminal is fine | the proxy app was shut down or rebooted without disconnecting, leaving a dead address in the **system proxy** (the browsers' world, not the variables this tool writes) | open the menu and choose "Show status" — it tells you directly whether the system proxy is a leftover. Turn it off under system settings, network, proxy — or open the proxy app and disconnect cleanly once |
| "安装不完整，缺少程序文件" (incomplete install, the missing files are listed below it) | the folder was not copied over completely, or files inside it were deleted (the program is one entry plus seven libraries under `lib\`; missing any one of them means nothing runs) | download your platform's package again from the Releases page and copy it over the folder. **Updating through the menu cleans your platform's old files automatically** (the other platform's folder is left alone); only hand-covering needs leftover files deleted by hand. Opening the menu to run "Install / Fix" cannot fix this — it needs those same files to run |

</details>

<details>
<summary>Less common cases</summary>

| Symptom | Cause | What to do |
|---|---|---|
| Installing reports syntax errors about unexpected tokens | the script encoding was damaged by a text editor. PowerShell 5.1 reads a script without a BOM as ANSI on non UTF-8 systems, and the mangled Chinese breaks the syntax | the script in the official package is always UTF-8 with a BOM; copy a fresh official folder over the old one |
| Nothing happens after putting the folder in an unusual place | the locator only searches six levels below your home folders and four levels below other drive roots (`C:\Tools`, `~/Projects` and very deep paths are outside that range) | open `win` and open the menu to run "Install / Fix" once |
| Your local proxy requires a username and password | an unauthenticated handshake gets a 407, and treating it as unavailable is the conservative answer | turn off local authentication (it is off by default) or use a port that needs none |
| It does nothing inside fish | fish does not understand the `export` syntax, so automatic injection only covers bash/zsh | fish has no native support yet, bash/zsh work fine; a later version may add it |
| A corporate EDR flags or blocks it | a Run key plus user-folder scripts plus environment writes looks exactly like persistence attacks, so it gets extra attention | ask IT to allowlist the folder by path; uninstalling wipes everything clean and it can be verified. The scripts are plain text and auditable — no obfuscation, downloads or elevation |
| The terminal inside WSL2 is not affected | WSL2 does not inherit Windows user environment variables by default | expected; set the proxy variables inside WSL separately |
| An administrator terminal is not affected | an elevated process belongs to another account and does not inherit your variables | expected; use a normal, non elevated terminal |
| Proxy variables you had before are gone | installing snapshots variables with the same names before overwriting them, and restores the snapshot on uninstall (system level variables and the system proxy are never touched) | safe to install on a corporate machine; only values added after the install are outside the snapshot |
| A service bound to `[::1]` is not bypassed in Node | the undici bundled with Node cannot parse a bare `::1` (it splits it into host `:` plus port `1`); writing `[::1]` instead would break httpx everywhere, so the bare form stays | only "service explicitly bound to `[::1]` plus native Node fetch" hits this; use `localhost` / `127.0.0.1` |
| `NODE_USE_ENV_PROXY` is set but Node still ignores the proxy | it only works on recent Node | `node:http(s)` needs 22.21 / 24.5 or later, `fetch()` needs 22.21 / 24.0 or later; older versions are expected behaviour |

</details>

## 7. Performance and traffic

| Item | Roughly |
|---|---|
| CPU | not noticeable. A round of probing takes milliseconds; what you see is mainly the footprint of one PowerShell process (on Mac it is bash, which has no such footprint) |
| Memory | tens of MB, again mostly the process itself |
| Outside traffic | a few MB even if the proxy runs 24 hours a day. While everything is healthy a probe happens at most once every 15 seconds per port and stays under 1KB |
| File writes | one write per state change; nothing at all while the state is stable |

One detail worth spelling out: **outside traffic only happens while something local is still answering proxy requests.** With the proxy app fully quit the traffic really is zero. "Disconnected but the core is still running" is not zero: the port still answers, a probe normally runs every 15 seconds, and that probing is the only way to tell "disconnected" from "behind the proxy". When something looks wrong the interval shortens to every 5 seconds until the question is settled, and it keeps watching for another minute after that — the whole episode lasts a couple of minutes at most, costs a handful of extra probes and a few KB, and does not change the totals above.

To see the actual numbers, look in Task Manager for the powershell process whose command line contains `envproxy.ps1`.

## 8. What is inside the folder

After unzipping you have roughly this (the folder name is yours to change; a split package simply lacks the other platform folder):

```
EnvProxy\
  win\                    Windows build: one menu, the entry script and the libraries
    打开菜单.cmd         the only thing to double-click: the menu (install/status/stop/restore/update)
    envproxy.ps1          entry: parses arguments, takes the op lock, verifies and loads the libraries, dispatches
    lib\                  seven libraries: base / probe / env / runtime / package / update / ops
    monitor\              created at runtime: monitor.log, monitor.pid, stop.flag
  mac\                    Mac build: the same single menu, entry script and libraries
    打开菜单.command     the only thing to double-click: the menu (same as Windows)
    envproxy.sh           entry (counterpart of win\envproxy.ps1)
    locator.sh           locator template (copied to ~/.envproxy/locator.sh on install)
    lib\                  seven libraries (same names, same jobs as on Windows)
    monitor\             created at runtime (same as Windows, same log format)
  README.md               Chinese documentation
  README.en.md            English documentation
  LICENSE                 MIT license
  VERSION                 version number
  release-notes\          what each release changed (shown by the update check)
  assets\readme\          images used by these READMEs
```

- **One package per platform**: `EnvProxy-win.zip` is Windows (`win\` plus the shared files), `EnvProxy-mac.tar.gz` is Mac (`mac\` plus the same shared files). Each side updates from its own package and never touches the other folder.
- **The program's own ground**: `win\`, `mac\`, `release-notes\` and `assets\` — updating aligns them with the package. For daily use you only ever open `win\` (on Mac, `mac\`).
- **Your own files**: the top level only overwrites same-named files and never deletes anything; nothing inside `monitor\` is ever overwritten or deleted.

<img src="./assets/readme/boundary.en.svg" width="100%" alt="Three zones: the program folders (the updater overwrites them, do not keep your own files there), the runtime folder (the log and the run marker are never overwritten or deleted), and the top level of the folder (only same-named files are overwritten, nothing of yours is deleted)">

## 9. Copying the folder as a backup

| What you want to do | What happens |
|---|---|
| Copy the whole folder as a backup | Copy freely, it causes no harm. Start at login, the registry entries and the locator all point at the copy you installed; the locator sorts by log activity, so a backup is never picked up by mistake |
| Run the install inside a backup folder | **Do not** — that turns the backup into the live installation |
| Delete the whole folder | Run "Full restore" from the menu first, otherwise the login item and the locator stay behind. They cost nothing and leave no dead proxy (the locator keeps cleaning variables on every login), and reinstalling puts everything back |
| Move it, or keep two copies on one machine | One installation per machine. Run "Full restore" in the old location, then "Install / Fix" in the new one. A single instance lock and migration protection keep two monitors from fighting over the same variables; the rule exists so the old login item and path record are not left behind |

## 10. Deploying to a friend or a new machine

1. Get the package onto the new machine, either way works: click **[the Windows download](https://github.com/FiretrUCK666/envproxy/releases/latest/download/EnvProxy-win.zip)**, or copy the already unzipped folder over (USB drive, cloud storage, an archive — all fine)
2. Double-click `win\打开菜单.cmd` (on Mac, `mac\打开菜单.command`), then choose `1 Install / Fix`
3. Done

Nothing needs to be installed (no Node, no Python), no administrator rights are needed, and the PowerShell that ships with Windows 10 and 11 is enough.

<details>
<summary>If you edit the files by hand, mind the encoding</summary>

- Every `.ps1` under `win\` (the entry and the libraries in `lib\`) is **UTF-8 with a BOM**. That is what lets PowerShell 5.1 read it correctly on both Chinese and English systems: without a BOM, a Chinese system reads it as GBK and an English one as Latin-1, and either can produce syntax errors. If you edit it, save as "UTF-8 with BOM" and open the menu to run "Install / Fix" once so the monitor loads the new code.
- The log `monitor\monitor.log` is the opposite: **UTF-8 without a BOM**, with UTF-8 specified explicitly on both the writing and reading side, so it never looks wrong on any code page (CRLF line endings on Windows, LF on Mac). Do not "unify" the log to a BOM either — the three extra bytes at the start would be read as log content.
- When copying the folder around, do not re-save the `.ps1` files with a text editor, which would break the BOM.

</details>

## 11. Technical limits (5 points)

| Limit | Why it is like that | What you do about it |
|---|---|---|
| **TUN mode gets nothing** | TUN already captures all traffic globally, so the terminal works without help and no local proxy port can be found | Nothing — this is correct behaviour, not a bug. The same applies to system wide VPNs such as Outline and to SOCKS only ports with no HTTP socket |
| **"Disconnected" is not the same as quitting** | the disconnect button in most proxy apps leaves the core running and the port alive | Nothing. Traffic decides: if traffic gets through, the variables are written; if not, they are removed |
| **Moving outside the search range needs one manual step** | the locator does not scan the whole disk; it looks for the new location, sorted by activity, inside your home folders (Desktop, Documents, Downloads, OneDrive, .config, six levels deep) and the roots of other drives (four levels deep) | if the folder moves outside that range (`C:\Tools`, `~/Projects`, any very deep path), open the menu and run "Install / Fix" once; everything else is automatic |
| **Proxy variables you set by hand before are taken over** | installing snapshots user level variables with the same names before overwriting them and restores the snapshot on uninstall; system level variables and the system proxy are never touched | Nothing; rare on a personal machine and safe on a corporate one |
| **Security software may block the scripts** (Windows) | what it does looks like something suspicious: writing user level environment variables, adding a startup entry to the registry, and putting scripts in your home folder | if it is blocked, allow it or whitelist it in the security tool, or install this tool somewhere the tool already trusts. Never turn the protection off for it |

<img src="./assets/readme/limits.en.svg" width="100%" alt="Five technical limits: pure TUN gets nothing, disconnected is not quitting, manual takeover outside the range, hand-set variables snapshotted, security software may block the scripts">

---

## 12. macOS

> Windows users can stop here. Each side ships its own package: Mac users download the Mac package directly; an old folder that already contains `mac\` works as-is.

### 12.1 How it differs from Windows, in one sentence

Windows writes the variables into the registry and broadcasts once, which makes them global. macOS has no registry, so the Mac build writes through two paths at the same time: terminals read `~/.envproxy/proxy.env` (loaded automatically by new terminals), and apps launched from the Dock are covered by `launchctl setenv`. The two paths move together.

The Mac build sets all 9 variables, the extra four being lowercase spellings — macOS is genuinely case sensitive, so the two spellings are separate variables and some tools read only the lowercase ones (the reason is under the variable table above). Everything else matches Windows exactly: when it switches, how long it waits before deciding, the log cap, and the self healing login item. Stopping the monitor means the same thing as on Windows: stopped stays stopped until the next login.

<img src="./assets/readme/mac-paths.en.svg" width="100%" alt="macOS writes the variables through two paths: the terminal reads proxy.env through a shell hook, and apps started from the Dock read the same set through launchctl setenv; both paths always change together">

### 12.2 Install (3 steps)

1. Get the Mac package (`EnvProxy-mac.tar.gz`) onto any location on the Mac (or copy over a whole folder that contains `mac\`: USB drive, AirDrop, an archive — all fine)
2. Open `mac` and double-click **`打开菜单.command`**, then choose **`1 Install / Fix`** (the first run may need a right-click and Open, see 12.5)
3. When you see the monitor started message, you are done. Verify in a **new terminal**: `env | grep -i proxy`

Installing does five things: it snapshots existing variables with the same names first (used to restore them on uninstall), registers start at login (a LaunchAgent), writes the terminal integration (a marked hook inside `~/.zshenv`, `~/.zshrc` and, if they exist, `~/.bash_profile` and `~/.bashrc`, which new terminals use to load `proxy.env`), starts the monitor right away, and corrects the variables once. If anything seems off later, open the menu and choose "Install / Fix" — it is the universal fix.

> A note for fish users: fish does not understand the `export` syntax, so there is no native support yet. The workaround is to install bass and add `bass source "$HOME/.envproxy/proxy.env"` to `config.fish` (it re-reads the file in every new window, so port changes are picked up).

### 12.3 The menu (same meaning as Windows)

Only one thing lives in the `mac` folder to double-click. The menu is identical to the Windows one ([see section 2](#2-the-menu)) — open to compare:

<details>
<summary>Menu comparison (open to view)</summary>

| Menu item | What it does |
|---|---|
| **1 Install / Fix** | start at login + start the monitor + correct the variables (universal fix) |
| **2 Show status** | shows monitor, start at login, proxy state, variables, version, recent log |
| **3 Stop monitor** | stop the monitor and delete the variables (start at login stays, it returns on the next login) |
| **4 Full restore** | stop the monitor, delete the variables, remove start at login, the locator and the hook; asks about the log |
| **5 Check for updates** | checks the latest release and installs after you agree |

</details>

Terminal users can also run the commands directly from the project root: `bash mac/envproxy.sh install`, `bash mac/envproxy.sh stop`, `bash mac/envproxy.sh uninstall` (add `--purge` to delete the log without asking), `bash mac/envproxy.sh status`, `bash mac/envproxy.sh update` (add `--yes` to skip the confirmation). The `.command` file is only a double-click shell; the logic lives in the entry script and the libraries under `lib/`.

A switch has to follow the command it belongs to: `--purge` goes with `uninstall`, `--yes` goes with `update`. Put it anywhere else and the script says the argument is wrong and exits with code 2, without touching your proxy settings.

### 12.4 What is inside the `mac` folder

```
EnvProxy/
  mac/
    envproxy.sh          entry (counterpart of win\envproxy.ps1, system tools only)
    lib/                 seven libraries: base / probe / env / runtime / package / update / ops
    locator.sh           locator template (copied to ~/.envproxy/locator.sh at install time)
    打开菜单.command     the only thing to double-click: the menu (same as Windows)
    monitor/             created at runtime (monitor.log, monitor.pid, stop.flag; same log format as Windows)
```

`~/.envproxy/` is a fixed location. After installing it holds `locator.sh` (the locator), `path.conf` (the path record), `proxy.env` (the variables for the terminal path), `prev.env` (the snapshot of your own values taken at install time, used to restore them on uninstall), and two output redirection files used by launchd. The project folder can be moved anywhere and is located again on the next login; backup copies are never picked up by mistake. Uninstalling removes all of these, keeping only the `monitor.log` black box you chose to keep.

### 12.5 Three things that may block the first install on a Mac

1. **Double-clicking does nothing, or macOS says the file cannot be opened**: Gatekeeper. Try these in order of effort:
   - double-click once so it warns you, then go to System Settings, Privacy and Security and click "Open Anyway" (the button only appears after you tried; on Sequoia and later, right-clicking no longer offers a bypass)
   - or run `bash mac/envproxy.sh install` from the project root (always works)
   - otherwise run `xattr -d com.apple.quarantine mac/打开菜单.command` from the project root, then double-click again
   - do **not** turn off Gatekeeper as a whole with `spctl --master-disable`: a `.command` file is just an unsigned script, signing would not fix anything, and disabling it opens the door to malware
2. **The executable bit is lost** (common when the folder came from Windows): run `chmod +x *.command *.sh` once inside the `mac` folder.
3. **The first login asks whether the terminal may access Documents or Desktop**: click OK (the locator searches for new locations). Clicking "Do Not Allow" is not fatal either — open the menu and run "Install / Fix" once and it is corrected.

<img src="./assets/readme/mac-blockers.en.svg" width="100%" alt="Three Mac first-install hurdles: unblock in Settings, chmod back the bit, click OK on the prompt">

### 12.6 macOS technical limits (the first 4 Windows ones still apply, the 5th changes shape, plus 2 unique)

The Windows ones: TUN mode gets nothing (correct behaviour); "disconnected" is not quitting, traffic decides; moving outside the search range needs one manual install; user level proxy variables you set by hand are snapshotted first and restored on uninstall.

The 5th changes shape: on Windows the blocker is security software (antivirus, EDR); on a Mac the counterpart is Gatekeeper — the first run of a `.command` may say the developer cannot be verified, and a right-click then Open clears it (see 12.5).

Two more, unique to macOS:

1. **Old terminals must be reopened**: existing windows do not change, only newly opened terminals and apps pick up the variables (same as Windows).
2. **The core is shell, not python**: the `/usr/bin/python3` that ships with macOS is an old version bundled with Xcode, and it fails outright on newer systems when components are missing. So the Mac build uses only `zsh`, `bash` and system tools (`curl`, `lsof`, `nc`, `netstat`, `ps`, `launchctl`, `awk`, `sed`, `tar`, `cmp` and the like), and installs nothing. **After editing any `.sh` under `mac` (the entry and the libraries in `lib/`), save it as LF with no BOM** — the opposite of Windows, where the BOM is required; here a BOM would displace the shebang and the script would not run.

### 12.7 Deploying to a friend or a new Mac

Copy the whole folder over, open `mac` and double-click `打开菜单.command`, then choose `1 Install / Fix`, done. No Homebrew, Python or Node, no `sudo`, and the `zsh` that ships with macOS 12 or later is enough. (Mac only: grab [`EnvProxy-mac.tar.gz`](https://github.com/FiretrUCK666/envproxy/releases/latest/download/EnvProxy-mac.tar.gz).)

To update: open the menu and choose `5 Check for updates`. It asks first, then installs, and keeps the log.

---

## 13. License and feedback

This project is open source under the MIT license (see `LICENSE`): use it, change it and redistribute it freely, as long as the copyright notice stays.

To contribute (report a bug, propose a change), read `CONTRIBUTING.md` first — it covers the question format, the fork flow and the gates to run before submitting. Pull requests that skip it will be sent back.

If something goes wrong, start with section 6. If that does not help, open an issue at `https://github.com/FiretrUCK666/envproxy/issues` with your system version, the full "Show status" output, and the relevant recent lines of `win\monitor\monitor.log` (on Mac, the same file names under `mac`).

Repository: `https://github.com/FiretrUCK666/envproxy`. To change the code, read `CONTRIBUTING.md` first; a `git clone` copy carries `.git`, so sync upstream with `git pull` — the updater recognises such copies and leaves your working tree alone.
