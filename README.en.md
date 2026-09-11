# EnvProxy — Auto Proxy for Terminals (Environment Variables)

[![check](https://github.com/FiretrUCK666/envproxy/actions/workflows/check.yml/badge.svg)](https://github.com/FiretrUCK666/envproxy/actions/workflows/check.yml)
[![release](https://img.shields.io/github/v/release/FiretrUCK666/envproxy)](https://github.com/FiretrUCK666/envproxy/releases)
[![license](https://img.shields.io/github/license/FiretrUCK666/envproxy?v=1)](LICENSE)
[![stars](https://img.shields.io/github/stars/FiretrUCK666/envproxy?v=1)](https://github.com/FiretrUCK666/envproxy/stargazers)

[中文](README.md)

> VPN app on = terminal auto-proxies; VPN app off = terminal back to direct. Zero clicks, zero residue, zero admin rights.

## 目录

<!-- toc:start -->

- [What it does (in one paragraph)](#what-it-does-in-one-paragraph)
- [1. Install (3 steps, 5 minutes)](#1-install-3-steps-5-minutes)
- [2. What the four buttons do (must-read for beginners)](#2-what-the-four-buttons-do-must-read-for-beginners)
- [2.5 About the log (monitor.log)](#25-about-the-log-monitorlog)
- [3. Daily use (nothing to do after install)](#3-daily-use-nothing-to-do-after-install)
- [4. How it tells "VPN on or off" (plain words)](#4-how-it-tells-vpn-on-or-off-plain-words)
- [5. Safety nets (why it's "stable")](#5-safety-nets-why-its-stable)
- [6. Troubleshooting](#6-troubleshooting)
- [7. Performance & traffic](#7-performance-traffic)
- [8. What's in the folder](#8-whats-in-the-folder)
- [9. About copied backup folders](#9-about-copied-backup-folders)
- [10. Deploy to a friend's / new machine](#10-deploy-to-a-friends-new-machine)
- [11. Honest technical limits (4 items)](#11-honest-technical-limits-4-items)
- [12. macOS edition (same behavior as Windows, files live side by side)](#12-macos-edition-same-behavior-as-windows-files-live-side-by-side)
- [13. License & feedback](#13-license-feedback)

<!-- toc:end -->

## What it does (in one paragraph)

Your VPN app (MonoCloud, Clash, v2rayN, Hiddify… anything with a local proxy port) makes your **browser** cross the wall, but **command-line tools** (OpenCode, git, npm, curl, etc.) ignore it completely — because those tools only read "environment variables".

**EnvProxy is the translator**: it watches "is the VPN app actually proxying right now", writes the proxy into environment variables when it is, and deletes them when it isn't. You do nothing.

> Note: it only manages **environment variables** (the command-line world) and never touches the **system proxy** (the browser world). The two worlds don't interfere.

### Variables it injects (`ALL_PROXY` uses the uniform `http://` form)

Written as a set when proxying, deleted as a set when not — all or nothing:

| Variable | Value written | Purpose |
|---|---|---|
| `HTTP_PROXY` / `http_proxy` | `http://127.0.0.1:port` | proxy for http:// requests |
| `HTTPS_PROXY` / `https_proxy` | `http://127.0.0.1:port` | proxy for https:// requests |
| `ALL_PROXY` / `all_proxy` | `http://127.0.0.1:port` | fallback for protocols the specific ones don't cover |
| `NO_PROXY` | `localhost,127.0.0.1,::1` | local addresses go direct, no proxy |
| `NODE_USE_ENV_PROXY` | `1` | makes newer Node-based tools (native fetch) honor env proxies |

> Why this form: all proxy values uniformly use the `http://` scheme (never the old `ALL_PROXY=socks5://`). Local proxy ports (MonoCloud/Clash etc.) are mixed ports that answer both HTTP and SOCKS5; but some tools only understand `http://` and reject `socks5://` (e.g. dsh prints "all_proxy names a SOCKS proxy, which is not supported" and skips it). Uniform `http://` works with the most tools, with zero behavior loss.

## 1. Install (3 steps, 5 minutes)

1. Put the whole `EnvProxy` folder wherever you like (**any location, any name**)
2. In the `win` folder, double-click **`1-安装.cmd`**
3. Done when you see "monitor process started"

Install does three things:

- Registers the monitor for **auto-start on boot** (it just works after reboot, no more clicks)
- Starts the monitor right away
- Corrects environment variables on the spot (inject what should be injected, clean what should be cleaned)

> Later, to update or fix anything: in the `win` folder, just **double-click `1-安装.cmd` again**. It's the "universal fix button" — no double install, no network break, nothing lost.

## 2. What the four buttons do (must-read for beginners)

> All four buttons live in the `win` folder: "double-click" below means double-clicking inside `win`.

| Button | Does what | Leaves behind | When to use |
|---|---|---|---|
| **1-安装** | auto-start + start monitor + correct variables | everything in place | first install / whenever "something feels off", click it |
| **2-停止监控** | stops monitor + **deletes env variables** (back to direct immediately) | **keeps** auto-start + locator + path record (monitor returns on next boot) | pause temporarily, want it back next boot |
| **3-一键恢复** | stops monitor + deletes variables + **removes auto-start + locator + path record** | log kept or deleted — **you choose on the spot** (default: keep) | you want this feature gone completely |
| **4-查看状态** | shows monitor/auto-start/VPN/variables/recent log | — | check how it's doing |

One-line memory:

- **2-停止 = pause** (comes back by itself next boot)
- **3-一键恢复 = uninstall, asks "keep the log?"**
- **1-安装 = universal fix** (whatever the problem, click it)

> Double-clicking "3-一键恢复" **stops and asks**: keep history log? Enter = keep (black box); type `N` + Enter = delete it too. Two choices, no extra buttons.
>
> Note: no button ever deletes the `EnvProxy` folder itself (after uninstall nothing remains on the system, but folder and scripts stay put — handy for reinstalling later, or just delete the folder manually).

## 2.5 About the log (monitor.log)

- It only records "state changes" (start/exit/inject/delete/errors) — writes nothing while stable
- Hard cap of **200KB**: over that it truncates to the newest 200 lines — won't grow forever in years of use
- It's your **black box**: for any future "wait, what happened then", read it
- Uninstall asks keep-or-delete: Enter = keep; type `N` = delete

## 3. Daily use (nothing to do after install)

| Your action | Happens automatically | Takes about |
|---|---|---|
| connect the VPN app | proxy detected → variables written | ~4–10 s |
| disconnect/quit the VPN app | no proxy detected → variables deleted | ~8 s after quitting the app; ≤35 s after disconnecting |
| reconnect on any changed port | new port auto-discovered → value updated | ~10 s |
| switch to another VPN app | new app's port auto-discovered | seconds |
| connect/disconnect rapidly within seconds | debounce absorbs it, variables untouched | — |
| reboot (VPN app still connected at shutdown) | leftover variables corrected at boot | zero clicks |
| move the whole folder anywhere (anytime, even while monitoring) | old monitor exits itself in 2–3 s and cleans the old spot; restart auto-starts from the new spot | zero clicks |

## 4. How it tells "VPN on or off" (plain words)

```
Every 2-3 seconds, take a look: is any local proxy port "open for business"?
    ↓ a port is listening
Then ask: does this port answer a proxy handshake? (CONNECT probe)
    ↓ yes
Then really try it: fetch the outside world once through it — reachable? (real-node check)
    ↓ reachable = truly proxying → write variables
    ↓ unreachable (e.g. disconnected but app kernel still alive) → delete variables
```

Three layers, all required. So it can't be fooled by "fake proxies", won't mistake a "disconnected app" for proxying, and won't miss a "new app on a new port".

**Why it works with any VPN app**: it doesn't recognize brands, process names, or port numbers — only "who is really serving proxy traffic". Every VPN app with a local proxy port (entire Clash family, v2rayN, Shadowsocks, Hiddify, sing-box, NekoBox, Surge…) works.

## 5. Safety nets (why it's "stable")

| Mechanism | Purpose |
|---|---|
| double-round confirm (debounce) | acts only after 2 consecutive confirming rounds — rapid connect/disconnect flapping never writes garbage |
| node hysteresis | declares "down" only after 2 consecutive probe failures — a shaky node won't cause deletes |
| multi-endpoint check | 7 connectivity endpoints across vendors/networks (Google main / gstatic / YouTube / Wikipedia / Twitter); **fast-lane first**: normally probes only the "last good endpoint" (milliseconds, 1 request), on failure probes the rest **in parallel**, any success = "up" and becomes the new fast lane — one poisoned/slow network segment can't cause a false delete |
| probe throttling | real probes at most once per 15 s — saves traffic (~1–2 MB/day, only while proxying) |
| boot alignment | corrects variables immediately at boot — stale dead ports from shutdown wiped instantly |
| monitor self-exit | folder moved/deleted → monitor notices in 2–3 s and exits, old spot cleaned |
| locator fallback cleanup | moved then powered off right away (monitor never got to self-exit) → locator cleans the old spot next boot |
| activity-first locating | locator searches ordered by "recently active" — your copied backup folder never gets picked by mistake |
| graceful cross-location stop | when stopping the old monitor, the signal is written into "its own" directory — graceful exit, never kill -9 |
| shared file stream | zero lock conflicts on log writes; monitor's own truncation never collides |
| auto-start self-heal | self-checks every 60 s, rebuilds broken locator/auto-start entries |
| single-instance lock | exactly one monitor process, never piles up |

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| terminal still can't proxy after install | terminal window was opened before install | close it completely and open a new one |
| variables deleted late after disconnect | your app's "disconnect" didn't really stop (kernel still alive), or the node is still reachable | normal; to stop immediately, **quit** the VPN app |
| variables deleted then restored back and forth | your node itself is flapping (reachable/unreachable), monitor faithfully reflects it | multi-endpoint check already cushions this; if it persists, the node quality is poor — switch nodes |
| shows "variables deleted" while VPN app is connected | nodes temporarily can't reach the **check endpoints' networks** (e.g. Google main hit by DNS pollution/routing issues) while all endpoints were in that network → false "down" | new versions expanded endpoints to 7 cross-network ones (fast lane + parallel fallback), this is fixed at the root; on an old version, double-click "install" once in `win` to update |
| "detection error" in log | one probe round errored (harmless overall) | ignore, self-recovers; click "install" once if it keeps happening |
| install prints a pile of "unexpected token ) / }" (syntax errors) | script file encoding damaged: PowerShell 5.1 on non-UTF-8-codepage systems reads BOM-less scripts as ANSI → Chinese text breaks syntax | this version ships UTF-8 BOM at the root (works on any system as-is); if it still errors, the file was re-saved by some text tool — **re-copy an official folder** over it |
| VPN app moved into a very deep directory (D:\a\b\c\d\e\f) | auto-search doesn't cover that depth | double-click "install" once in `win` |
| want to go back to before-install | — | double-click "3-一键恢复" in `win`, keep-or-delete log chosen on the spot |

## 7. Performance & traffic

- CPU: **~0.2%** (measured over a 30 s window)
- Memory: ~140 MB (PowerShell runtime overhead, about one browser tab)
- Traffic: real node probes normally hit **1 endpoint** (~200 bytes each), at most once per 15 s; parallel fallback to the rest only when that endpoint misbehaves (brief, rare). **Generated only while proxying** — no proxying = zero traffic
- Writes: only once per state change (idempotent), not a byte while stable

## 8. What's in the folder

```
EnvProxy\
  win\            Windows edition (4 buttons + core script, Mac users skip this)
    1-安装.cmd      install (universal fix)
    2-停止监控.cmd   pause (keeps auto-start)
    3-一键恢复.cmd   uninstall (keep-or-delete log chosen on the spot)
    4-查看状态.cmd   status
    envproxy.ps1    core script (all logic)
    monitor\        runtime folder (auto-created; log kept or deleted per your uninstall choice)
      monitor.log   black-box log (state changes only, 200KB cap with auto-truncate)
      monitor.pid   run marker
      stop.flag     stop signal (temp file, deleted after use)
  mac\            Mac edition (mirrors win\, see section 12.4)
  README.md       Chinese docs (authoritative)
  README.en.md    this file
```

> Daily use only enters `win` (or `mac` on a Mac); the docs in the root stay untouched.

## 9. About copied backup folders

Copying the whole `EnvProxy` folder elsewhere as a **backup** is completely harmless:

- Boot auto-start, registry, locator **only reference the folder you installed** — backups are never referenced
- Even if the original folder moves, the locator re-searches ordered by **activity** — the recently used one (with log activity) wins, backups never get picked by mistake
- Only rule: **don't double-click "`win\1-安装.cmd`" inside the backup** (clicking it promotes the backup to the live install)

## 10. Deploy to a friend's / new machine

1. Get the code onto the new machine (either way): `git clone https://github.com/FiretrUCK666/envproxy.git` (recommended — later updates are just `git pull`); or copy the **whole folder** (USB/drive/zip all fine, just **don't re-save the .ps1 files in a text editor** — that breaks the UTF-8 BOM encoding)
2. Double-click `win\1-安装.cmd`
3. Done

To update later: `git pull` for the latest, then double-click `1-安装.cmd` once in `win` (universal fix: loads new code and corrects variables).

> Encoding note: `win\envproxy.ps1` / logs use **UTF-8 BOM** so PowerShell 5.1 reads them correctly on **any Chinese/English Windows** (without BOM, Chinese systems read GBK and English systems Latin1 — both can cause syntax errors or mojibake). **If you ever edit `win\envproxy.ps1`, save it as UTF-8 with BOM** (VS Code / Notepad++ / Notepad all offer "UTF-8 with BOM"), then double-click "install" once in `win` so the monitor loads the new code.

Needs nothing installed (no Node/Python), no admin rights — stock Windows 10/11 PowerShell is enough.

## 11. Honest technical limits (4 items)

1. **Pure TUN mode** VPN apps (no local HTTP port): TUN already takes over globally (terminal proxies automatically), this tool sees no port → injects nothing → **that's correct behavior**, it's not needed.
2. **"Disconnected" ≠ quit the app**: most apps' "disconnect" button doesn't stop the kernel, the port stays alive. This tool follows "traffic truth": reachable-through = inject, otherwise delete.
3. **Moved into an extremely deep directory** (past search depth): double-click "install" once in `win` as fallback, everything else is automatic.
4. **Previously hand-set proxies get taken over**: manually set system/user proxy variables get overwritten on install, deleted (not restored) on uninstall — rare on personal machines; on corporate intranet machines, note down original values first.

---

## 12. macOS edition (same behavior as Windows, files live side by side)

> Windows users can stop here. Below is only about Macs. Windows files live in `win\`, Mac files in `mac\` — two parallel sets; copy the whole folder to a Mac and it works.

### 12.1 The one difference

Windows writes variables into the registry and one broadcast makes them global; macOS has no registry, so the Mac edition **writes both channels at once**: terminals read `~/.envproxy/proxy.env` (new terminals auto-load it), Dock-launched apps read `launchctl setenv`. Both channels move together, you feel no difference.

The Mac edition injects the same set of 9 variables (`HTTP_PROXY/http_proxy/HTTPS_PROXY/https_proxy/ALL_PROXY/all_proxy` uniform `http://127.0.0.1:port`, `NO_PROXY/no_proxy=localhost,127.0.0.1,::1`, `NODE_USE_ENV_PROXY=1`), same parameters as Windows: 2 s/3 s polling, double-round confirm, 2 consecutive failures to declare down, 7 fast-lane + parallel-fallback endpoints, 15 s throttle, 200KB log cap, 60 s auto-start self-heal.

### 12.2 Install (3 steps)

1. Copy the whole `EnvProxy` folder to the Mac, anywhere (USB/AirDrop/zip all fine)
2. In the `mac` folder, double-click **`1-安装.command`** (first time may need right-click → Open to pass Gatekeeper once, see 12.5)
3. Done when you see "monitor process started"; **open a new terminal** to verify: `env | grep -i proxy`

Install does the same three things: boot auto-start (LaunchAgent) + start monitor now + correct variables on the spot. Later, any weirdness: double-click `1-安装.command` once in `mac` = universal fix.

### 12.3 Four buttons (same semantics as Windows)

> All four buttons live in the `mac` folder: "double-click" below means double-clicking inside `mac`.

| Button | Does what |
|---|---|
| **1-安装.command** | auto-start + start monitor + correct variables (universal fix) |
| **2-停止监控.command** | stop monitor + delete variables (keeps auto-start, back next login) |
| **3-一键恢复.command** | stop monitor + delete variables + remove auto-start/locator/hook, keep-or-delete log asked on the spot |
| **4-查看状态.command** | monitor/auto-start/VPN/variables/recent log |

Terminal users can also run (from the project root): `bash mac/install.sh` / `bash mac/stop.sh` / `bash mac/uninstall.sh` (add `--purge` to delete the log too, no questions) / `bash mac/status.sh`. The `.command` files are just "double-click shells", all logic lives in the `.sh` files.

### 12.4 What's in the `mac` folder

```
EnvProxy/
  mac/
    envproxy.sh          Mac core (mirrors win\envproxy.ps1, single file, stock commands only)
    locator.sh           locator template (copied to ~/.envproxy/locator.sh on install)
    install.sh / stop.sh / uninstall.sh / status.sh
    1-安装.command … 4-查看状态.command (double-click entries)
    monitor/             shared (monitor.log / monitor.pid / stop.flag, same format)
```

`~/.envproxy/` is the fixed spot (`locator.sh` + `path.conf` path record + `proxy.env`); the project folder can move freely, next login re-locates automatically. Copy backup folders freely, never picked by mistake (ordered by log activity).

### 12.5 Three Mac-only "roadblocks" (all normal, all solvable)

1. **Double-click does nothing / "cannot open"**: that's Gatekeeper. Three fixes, pick one: right-click → Open to allow once; or run `bash mac/install.sh` in a terminal (always works); or `xattr -d com.apple.quarantine mac/1-安装.command` then double-click.
2. **Lost `chmod` bits** (common when copied from Windows): in a terminal, `cd` into the `mac` folder and run `chmod +x *.command *.sh` once.
3. **First login pops "Terminal wants to access Documents/Desktop"**: click "OK" (locator needs to search the new spot). Clicking "Don't Allow" is harmless too: one manual double-click on install corrects it.

### 12.6 Mac technical limits (3 Windows ones carry over + 2 new)

Carry-overs: pure TUN not injected (correct behavior); "disconnect ≠ quit", traffic truth rules; very deep directories fixed by one install click.

New:

1. **Old terminals must be reopened** (same as Windows): already-open windows don't change, only new terminals/apps take effect.
2. **Core language is shell, not python**: macOS's built-in `/usr/bin/python3` is the old Xcode-bundled one that errors on new systems missing components, so the Mac edition deliberately uses only `zsh/bash/curl/lsof/launchctl` (all factory-shipped) — truly zero dependencies. **Save edited `mac/envproxy.sh` as LF, no BOM** (opposite of Windows UTF-8 BOM — a BOM kills the shebang).

### 12.7 Deploy to a friend's / new Mac

Copy the whole folder → double-click `1-安装.command` in `mac` → done. No Homebrew/Python/Node, no `sudo`, stock macOS 12+ `zsh` is enough.

---

## 13. License & feedback

This project is MIT-licensed (see `LICENSE`): use, modify, redistribute freely, keep the copyright notice.

Issue? Read section 6 troubleshooting first; still stuck → open an issue: `https://github.com/FiretrUCK666/envproxy/issues`. Include: your OS version, the full output of `4-查看状态` (`win`, or the `mac` counterpart), recent relevant lines of `monitor/monitor.log` under the same folder. To hack on the code, read `CONTRIBUTING.md` first.
