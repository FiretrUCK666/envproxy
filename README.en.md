# EnvProxy — automatic proxy for your terminal

[![check](https://github.com/FiretrUCK666/envproxy/actions/workflows/check.yml/badge.svg)](https://github.com/FiretrUCK666/envproxy/actions/workflows/check.yml)
[![release](https://img.shields.io/github/v/release/FiretrUCK666/envproxy)](https://github.com/FiretrUCK666/envproxy/releases)
[![license](https://img.shields.io/github/license/FiretrUCK666/envproxy?v=1)](LICENSE)
[![stars](https://img.shields.io/github/stars/FiretrUCK666/envproxy?v=1)](https://github.com/FiretrUCK666/envproxy/stargazers)

<img src="./assets/readme/hero.en.svg" width="100%" alt="EnvProxy: with the proxy app running, git, npm and curl in your terminal go through it automatically; when you quit it, they return to a direct connection with no extra steps">

A proxy app covers your browser but not your terminal. `git`, `npm` and `curl` learn the proxy address from a set of settings called "environment variables", and without them they cannot reach the internet.

EnvProxy maintains those settings for you. While the proxy app is running it writes the proxy address in; when you quit it, it removes them. Day to day there are no commands to remember.

<img src="./assets/readme/quickstart.en.svg" width="100%" alt="After installing, only three things matter: a new window needs no action; a window that is already open catches up after one Enter press; if something feels wrong, open the menu and pick 1 Install / Repair, which fixes most problems without touching your own settings">

## Table of contents

<!-- toc:start -->

- [0. What happens after installing](#0-what-happens-after-installing)
- [1. Install (3 steps, 5 minutes)](#1-install-3-steps-5-minutes)
- [2. Open the menu](#2-open-the-menu)
- [3. Everyday commands on one page](#3-everyday-commands-on-one-page)
- [4. Something is wrong: check in this order](#4-something-is-wrong-check-in-this-order)
- [5. How it decides whether you are behind a proxy](#5-how-it-decides-whether-you-are-behind-a-proxy)
- [6. Why it rarely breaks](#6-why-it-rarely-breaks)
- [7. Performance and traffic](#7-performance-and-traffic)
- [8. What is in the folder](#8-what-is-in-the-folder)
- [9. Copying and backing up the folder](#9-copying-and-backing-up-the-folder)
- [10. Setting it up for a friend or a new machine](#10-setting-it-up-for-a-friend-or-a-new-machine)
- [11. Technical limits (5)](#11-technical-limits-5)
- [12. macOS version](#12-macos-version)
- [13. License and feedback](#13-license-and-feedback)

<!-- toc:end -->

## 0. What happens after installing

Most of the time you do not need to do anything. There are three cases, and only the third one needs action.

| Your situation | What happens | What you need to do |
|---|---|---|
| **A window or program opened after installing** | It reads the current state when it starts | **Nothing at all** |
| **Opened after installing, but the proxy changed later** | The state has to be read again | Press Enter once, or run any command |
| **A window opened before installing** | The sync script was never loaded into it | Reopen it, or load it by hand once |

### Why an already-open window needs one Enter press

Each program reads the environment variables from the system once, when it starts, and keeps that copy for its whole lifetime. Changing the value in the system afterwards does not reach a program that is already running.

So a newly opened window always reads the current values, while a window that is already open keeps the values from the moment it started. The only way to update it is to make it read again.

EnvProxy reads the state every time a command finishes and the terminal shows the prompt again. The prompt is the text waiting for your input, such as `C:\Users\yourname>` or `$`. It reappears after every command, so this timing needs nothing extra from you.

### About AI tools, editors and IDEs

They usually start a new process when they open a terminal, and a new process reads the current environment variables, so nothing is needed.

Two cases require restarting the tool: it was already open before you installed EnvProxy, or it is a long-running background service rather than something started on demand. The check is simple: if it cannot connect, restart it once.

## 1. Install (3 steps, 5 minutes)

1. Click **[here to download the Windows package](https://github.com/FiretrUCK666/envproxy/releases/latest/download/EnvProxy-win.zip)** (Mac: [`EnvProxy-mac.tar.gz`](https://github.com/FiretrUCK666/envproxy/releases/latest/download/EnvProxy-mac.tar.gz))
2. Unzip it anywhere; the folder can be renamed. Open the `win` folder and double-click **`打开菜单.cmd`** (Mac: open `mac` and double-click **`打开菜单.command`**), then pick **`1 Install / Repair`**
3. Once you see the monitor started message, you are done

Installing does five things: it saves the current values of any variables with the same names (used to restore them on uninstall), registers automatic start at login, adds a script to your terminal's startup configuration (on Windows that is PowerShell's `$PROFILE`, written to both the 5.1 and the 7 location; on Mac it is the shell rc files), starts the monitor, and corrects the environment variables once. Progress is reported step by step on screen (4 steps on Windows, 3 on Mac; the snapshot is folded into step 1).

<img src="./assets/readme/first-run.en.svg" width="100%" alt="Install in three steps: download the package for your platform, double-click the menu and choose 1 Install / Repair, see the monitor started message; below, a side by side comparison: a window opened after the install takes effect right away, and a window that was open before also catches up once you reopen it or load the sync script by hand">

If something goes wrong, open the menu and pick **`1 Install / Repair`**. It fixes most problems, does not install a second copy, does not cut your network, and does not lose your settings.

> If the downloaded file is blocked the first time you double-click it: right-click, Properties, Unblock (or run `Unblock-File .\EnvProxy-win.zip`). Do not change your execution policy.

### Updating

Open the menu and pick **`5 Check for updates`**. It reports the latest version number and what changed, and installs only after you agree.

- **Updating does not need the proxy running**: most networks connect as they are. If it reports it cannot connect, toggle your proxy app once and retry.
- **Checksums are verified before installing**: they are compared before installation, and nothing is installed if they do not match. A broken install is more trouble than no install.
- **Only program files are replaced**: your files, logs and the run markers in `monitor\` are left alone. The monitor restarts on the new code afterwards.

## 2. Open the menu

Double-click `打开菜单.cmd` (Mac: `打开菜单.command`). It only passes the number you pick to the real program; it does not modify any file itself.

| Pick | What it does | What it affects |
|---|---|---|
| **1** | Install / Repair. Use it for a first install, or whenever something feels wrong | Program files + start at login + terminal sync script + environment variables |
| **2** | Show status: monitor, proxy, environment variables, version | Read-only, changes nothing |
| **3** | Stop the monitor. Temporary; it returns at next login | Monitor process + environment variables |
| **4** | Full restore. Complete uninstall, back to before installing | Everything (log optionally kept) |
| **5** | Check for updates. Explains first, installs only if you agree | Program files only |
| **6** | Help. Read it when you forget how something works | Prints text only, changes nothing |
| **0** | Quit the menu | Nothing |

**Pressing Enter directly means show status**, the item you look at most. The menu header shows whether the monitor is running and the current version, so you do not need to go in.

<img src="./assets/readme/buttons.en.svg" width="100%" alt="What each menu item affects: install affects program files, start at login, the terminal sync script and environment variables; status is read-only; stop clears the monitor and the environment variables; full restore clears everything but the log; check for updates replaces program files only">

### Logs

`monitor\monitor.log` (Mac: `mac/monitor/monitor.log`) records the decisions it made. It is capped at 200KB and keeps only the most recent 200 lines once full.

Uninstalling asks whether to keep it. Keep it and this is the only file left; everything else is removed.

## 3. Everyday commands on one page

Every command you need to type by hand, collected in one place. **Windows and Mac differ; do not copy the wrong line.**

### 3.1 Keep one window on a direct connection

Run this in that window:

| | Command |
|---|---|
| Windows | `$env:ENVPROXY_TERM = 'off'` |
| Mac | `export ENVPROXY_TERM=off` |

**Press Enter once to apply.** Afterwards this window stays direct whether the proxy app is running or not. **Other windows are unaffected.**

To go back to following the proxy app:

| | Command |
|---|---|
| Windows | `Remove-Item Env:ENVPROXY_TERM -ErrorAction SilentlyContinue` |
| Mac | `unset ENVPROXY_TERM` |

Press Enter once again.

### 3.2 Give one window a different proxy, such as a corporate proxy

**The order matters: pin the window first, then set the proxy.**

| Step | Windows | Mac |
|---|---|---|
| 1. Pin it | `$env:ENVPROXY_TERM = 'off'` | `export ENVPROXY_TERM=off` |
| 2. Set the proxy | `$env:HTTPS_PROXY = 'http://your-host:port'` | `export HTTPS_PROXY=http://your-host:port` |

Why pin first: while the proxy app is running, any update it makes to this window replaces the proxy address with its own. Once the window is pinned, it stops touching it.

**Values we wrote and values you set are told apart.** A corporate proxy, your own capture tool, or an address on another port stays in place as long as the value differs from what we wrote.

### 3.3 Check whether traffic currently goes through a proxy

| | Command |
|---|---|
| Windows | `$env:HTTPS_PROXY` |
| Mac | `echo $HTTPS_PROXY` |

A value means traffic goes through the proxy; empty means a direct connection.

### 3.4 Bypass the proxy for one command

Sometimes you want a single command to skip the proxy:

| | Command |
|---|---|
| Windows | `curl.exe --noproxy "*" URL` |
| Mac | `curl --noproxy '*' URL` |

On Windows you must write `curl.exe`. PowerShell resolves `curl` to the `Invoke-WebRequest` alias, and plain `curl` fails with a parameter error.

Other tools have their own flags (`git` uses `-c http.proxy=`, `npm` uses `--no-proxy`), which are outside what this tool handles.

### 3.5 Make an already-open window catch up immediately

If you would rather not reopen the window, run this once in it:

| | Command |
|---|---|
| Windows | `. $PROFILE` |
| Mac | `. ~/.envproxy/prompt-sync.sh` |

Afterwards this window follows along on every Enter press.

## 4. Something is wrong: check in this order

**Work through the list in order, finishing one step before starting the next.**

| What you see | Most likely cause | What to do |
|---|---|---|
| "Unrecognized switch" or a usage error | A typo, or an abbreviation | Parameters must be written in full; abbreviations are rejected. Compare with the forms listed in the menu |
| The terminal still cannot use the proxy | This window was opened before installing | Open a new window. To avoid reopening, run the command in 3.5 |
| Still cannot use the proxy, and a new window does not help | The monitor is not running | Open the menu and pick 1 (Install / Repair) |
| "Installation incomplete, missing program files" | The folder was not copied in full, or files were deleted | Download again from the Releases page and unzip over this folder. **Upgrading through Check for updates removes the old files for your platform automatically** |
| Environment variables reappear after being removed | The node itself is unstable, and the monitor writes what it observes | Expected. If it keeps happening the node is poor; switch to another |
| Variables linger after disconnecting | The app's "disconnect" does not stop its core, and the node is still reachable | Expected. Quit the proxy app to stop it immediately |
| Everything above tried and it still fails | — | Open the menu, pick 2 and screenshot the status; then pick 1 to repair |

> Most problems are solved by **picking 1** in the menu. It does not install a second copy, does not cut your network, and does not lose your own settings.

## 5. How it decides whether you are behind a proxy

It checks every 2 to 3 seconds (2 while proxying, 3 while direct), but **it does not trust a port just because it exists**. Three conditions must hold:

<img src="./assets/readme/mechanism.en.svg" width="100%" alt="Three-condition flow: every 2 to 3 seconds it enumerates listening ports and keeps those that answer a CONNECT handshake; then it tests each candidate for real connectivity; only then are the proxy variables written">

1. **A port is listening** — some program on this machine has opened a proxy port
2. **It really is a proxy** — a `CONNECT` handshake is sent, and only an `HTTP/1.x 200` reply counts. This rules out development servers and ordinary web servers
3. **It really reaches the internet** — the proxy port is used to reach the **7 different sites** in the candidate list, and **any one** of them returning a real response is enough (the last known-good one is tried first, the rest in parallel if it fails)

**All three must hold before it decides you are behind a proxy and writes the variables.** A web server running on your machine is therefore never mistaken for a proxy.

It does not rely on brands, process names or port numbers. Those only speed up scanning; the decision always goes through the three conditions above.

<img src="./assets/readme/states.en.svg" width="100%" alt="Three everyday states: connecting the proxy app writes the full set of proxy variables in 4 to 10 seconds; disconnecting or quitting removes them and restores a direct connection, in about 5 seconds after quitting or 15 to 50 seconds after disconnecting only, and reconnecting takes about 10 to 25 seconds; new ports, new apps and flapping are followed automatically and the variables are left intact">

**Deciding "down" is more cautious than deciding "up"**: a single failed probe does not count as disconnected. It takes 10 seconds of continuous failure and at least 3 probes. A single success counts as connected immediately. Removing your environment variables by mistake costs more than waiting a little.

What you will actually notice:

| Action | Takes effect in |
|---|---|
| Starting the proxy app | 4-10 seconds |
| Quitting the proxy app entirely | about 5 seconds |
| Disconnecting only, without quitting | about 15-50 seconds |
| Reconnecting after a drop | about 10-25 seconds |

After reaching a conclusion it keeps watching closely for **another 1 minute**, so a wrong call corrects itself.

**Which environment variables it writes** (the whole set goes in together and comes out together):

| Variable | Value | Purpose |
|---|---|---|
| `HTTP_PROXY` | `http://127.0.0.1:port` | Proxy for http:// requests |
| `HTTPS_PROXY` | `http://127.0.0.1:port` | Proxy for https:// requests |
| `ALL_PROXY` | `http://127.0.0.1:port` | Fallback used by protocols the other variables do not cover |
| `NO_PROXY` | `localhost,127.0.0.1,::1` | Local addresses bypass the proxy |
| `NODE_USE_ENV_PROXY` | `1` | Makes newer Node tools (native fetch) read the proxy from the environment |

Windows gets 5, macOS gets 9 (the same 5 plus lowercase spellings). This comes from the platforms themselves: Windows variable names are case-insensitive, so writing lowercase only overwrites the same entry, while macOS treats each case as a separate variable and some tools read only the lowercase form.

<details>
<summary>Why these settings are what they are (does not affect usage, expand to read)</summary>

- Proxy values always use `http://`, never `socks5://`. The local proxy port answers both protocols, some tools accept only `http://`, and unifying gives the widest compatibility with no loss of function. Tools such as `dsh` warn and skip when they see a SOCKS value.
- Why Windows gets only one spelling: the two spellings are the same variable there, and a duplicate makes .NET hosts fail while building their table with `An item with the same key has already been added`, affecting everything running in that terminal window.
- IPv6 addresses inside `NO_PROXY` must be written as bare `::1`. Written as `[::1]`, httpx treats it as an ordinary domain, builds an invalid pattern, and every request afterwards fails with `InvalidURL`. Brackets are URL literal syntax, in the wrong position here.
- Your own `NO_PROXY` entries are never removed, only added to. Uninstalling reclaims only what this tool wrote.
- If another program corrupts the variables (overwrites, clears, or drops an entry), nothing needs doing: the monitor re-checks the whole table every 30 rounds and fills in whatever is missing.
- The tools below do not read those 5 variables and need separate configuration. This is not a defect in this tool:

| Tool | Where to configure it |
|---|---|
| Maven | `<proxies>` in `settings.xml` |
| Gradle | `systemProp.http(s).proxyHost/Port` in `gradle.properties` |
| JDK native HttpClient | JVM system properties (or `java.net.useSystemProxies` to use the system proxy) |
| Docker Desktop `docker pull` | Docker Desktop's own settings; it ignores the proxy in `daemon.json` |

- `NODE_USE_ENV_PROXY` only affects newer Node: `node:http(s)` needs 22.21 / 24.5 or later, and `fetch()` needs 22.21 / 24.0 or later. Older versions ignore it, which is expected.

</details>

## 6. Why it rarely breaks

The design rule is: when it cannot tell, it changes nothing.

- **Unreadable information leads to no action**: if the port list cannot be read, it does not treat that as "no proxy" and delete your environment variables. It keeps the previous state instead.
- **Only values still equal to ours are cleared**: values you changed by hand, corporate proxies, and addresses on other ports are all left alone. With no ownership record it changes nothing, so your own configuration is never removed.
- **Configuration files are backed up before edits**: both PowerShell's `$PROFILE` and the Mac rc files get a `.envproxy.bak` copy first. If the write cannot happen, nothing is changed at all.
- **Writes keep files intact**: the content goes into a temporary file first and then replaces the original as a whole. A power loss or a forced stop mid-way leaves the original file complete.
- **Re-installing has no side effects**: when everything is already correct it does not touch your settings, and running it again causes no problems.
- **Uninstalling verifies each item**: every item is read back afterwards, and any residue is reported as "incomplete" rather than claimed as success.

## 7. Performance and traffic

- **Little overhead once stable**: after the state settles, each port is probed at most once every 15 seconds, reading only response headers, under 1KB each time.
- **Shorter intervals while gathering evidence**: when failures appear but stay below the threshold, it probes every 5 seconds and returns to 15 seconds as soon as the conclusion is settled.
- **No residue after uninstalling**: environment variables, start at login, the locator script and the terminal sync script block are all removed, leaving only the log if you chose to keep it.
- **Almost no delay at the prompt**: it reads one local file before each prompt is shown and starts no external process.

## 8. What is in the folder

Unzipping gives roughly this (the folder name can be changed; each package contains only its own platform, so the Windows package has no `mac\` and vice versa):

```
EnvProxy\
  win\                    Windows version: menu + entry + libraries
    打开菜单.cmd         the only file to double-click: the menu (install/status/stop/restore/update/help)
    envproxy.ps1         entry: parse arguments, take the operation lock, load self-checks, dispatch
    lib\                 seven libraries: base / probe / env / runtime / package / update / ops
    monitor\              created at runtime: monitor.log, monitor.pid, stop.flag
  mac\                    Mac version: the same menu + entry + libraries
    打开菜单.command      the only file to double-click: the menu (same as Windows)
    envproxy.sh           entry (counterpart of win\envproxy.ps1)
    locator.sh            locator script template (copied to ~/.envproxy/locator.sh on install)
    prompt-sync.sh        terminal sync script template (copied to ~/.envproxy/prompt-sync.sh; the rc files only reference it in one line)
    lib\                 seven libraries (same names and duties as Windows)
    monitor\             created at runtime (same as Windows, same log format)
  README.md               Chinese documentation
  README.en.md            English documentation (this file)
  LICENSE                 MIT license
  VERSION                 version number
  release-notes\          what changed in each version (shown by Check for updates)
  assets\readme\          images used by the README
```

- **Each package covers one platform**: `EnvProxy-win.zip` installs Windows (`win\` plus shared files), and `EnvProxy-mac.tar.gz` installs Mac (`mac\` plus shared files). Download the one you need; the other platform's folder is not affected.
- **The program's files**: `win\`, `mac\`, `release-notes\` and `assets\` are managed by the update process and kept aligned with the package manifest. Day to day you only open `win\` (or `mac\`).
- **Your own files**: the top level only overwrites files of the same name and never deletes; logs and run markers in `monitor\` are never overwritten or deleted.

<img src="./assets/readme/boundary.en.svg" width="100%" alt="Three areas: the program folder (overwritten by updates, do not keep your files there), the runtime folder (logs and run markers never overwritten or deleted), and the top level (only same-name files are overwritten, your things are never deleted)">

## 9. Copying and backing up the folder

**It can be copied, renamed and moved.** One thing to know first: **once the original location is renamed or moved, the running monitor can no longer find its own script.** It exits by itself and clears the proxy variables, which prevents a stale proxy setting from being left behind.

So after renaming or moving, there are two ways to get it running again:

- **Wait until the next login**: the locator script finds the new location and takes over.
- **Restore it immediately**: double-click Install / Repair once. Use this if you want it back straight away.

The search covers **six levels** down from the common locations (Desktop, Documents, Downloads, OneDrive, `.config`) and **four levels** under each drive root. Moved outside those, such as `C:\Projects\EnvProxy`, the locator script cannot find it and you must double-click Install once.

A copied backup **is never mistaken for the copy in use**, because activity in the log decides which one is live, so backup folders can stay in place.

## 10. Setting it up for a friend or a new machine

1. Get the package onto the new machine, either way: click **[Windows download](https://github.com/FiretrUCK666/envproxy/releases/latest/download/EnvProxy-win.zip)**, or copy the whole unzipped folder over (USB drive, cloud storage, or an archive all work)
2. Double-click `win\打开菜单.cmd` and pick `1 Install / Repair`
3. Done. No administrator rights are needed, and nothing else has to be installed

> Windows users can stop here. Each platform has its own package: Mac users download the Mac package, and an existing folder that contains `mac\` works as it is.

## 11. Technical limits (5)

<img src="./assets/readme/limits.en.svg" width="100%" alt="Five technical limits: pure TUN mode is not handled, system proxy settings are never modified, already-running programs are not changed, tools that need their own proxy configuration are out of scope, and there is no interface">

| Limit | Reason | Effect |
|---|---|---|
| **Pure TUN mode is not handled** | It listens on no local port, so there is no port to judge | All traffic already goes through it in that mode, so no extra setting is needed. It cannot be told apart from a corporate VPN, and a wrong decision would remove your only proxy path, so it is left alone |
| **System proxy settings are not modified** | Doing so would affect browsers and other programs | Only user-level environment variables are written, and you can confirm in system settings that nothing else was touched |
| **Already-running programs are not changed** | A program reads the environment variables once, at startup | Windows already open need one Enter press; this is how the operating system works, see section 0 |
| **Tools that need their own proxy configuration are out of scope** | They do not read these variables | Maven, Gradle, Docker and others are covered by the collapsed table in section 5 |
| **No interface** | Zero dependencies is the install premise | There is only a menu: no tray icon and no window |

## 12. macOS version

### 12.1 Difference from the Windows version

Windows writes the registry and broadcasts a change notification; Mac writes `~/.envproxy/proxy.env` and calls `launchctl setenv`. Both paths are updated together, so the behaviour you see is the same.

<img src="./assets/readme/mac-paths.en.svg" width="100%" alt="macOS writes two paths: terminals read ~/.envproxy/proxy.env, and programs launched from the Dock read the launchctl environment; both paths are updated together">

### 12.2 Install (3 steps)

1. Put the Mac package (`EnvProxy-mac.tar.gz`) anywhere on the Mac, or copy the whole folder that contains `mac\` (USB drive, AirDrop, or an archive all work)
2. Open `mac` and double-click `打开菜单.command`, then pick `1 Install / Repair`
3. Once you see the monitor started message, you are done

No Homebrew, Python or Node is needed, no `sudo`, and the `zsh` that ships with macOS 12 and later is enough. (Mac only: download [`EnvProxy-mac.tar.gz`](https://github.com/FiretrUCK666/envproxy/releases/latest/download/EnvProxy-mac.tar.gz).)

### 12.3 Menu (identical to Windows)

The numbers, behaviour and what each item affects are identical to Windows, including `6 Help` and `0 Quit`. Pressing Enter directly means show status.

### 12.4 What is in the `mac` folder

See the folder structure in section 8. Mac has two extra template files: `locator.sh` (the locator script) and `prompt-sync.sh` (the terminal sync script).

### 12.5 Three problems you may hit on first install on a Mac

<img src="./assets/readme/mac-blockers.en.svg" width="100%" alt="Three problems on first install on a Mac: the downloaded file is quarantined, the script is not executable, and system settings block the background item">

| Symptom | Cause | What to do |
|---|---|---|
| Double-clicking does nothing, or "cannot be opened" | The downloaded file is quarantined by the system | Right-click, then Open; or run `xattr -d com.apple.quarantine 打开菜单.command` in a terminal |
| "Permission denied" | The script is not executable | Run `chmod +x 打开菜单.command` in a terminal |
| Installed, but the status says it is not running | System settings blocked the background item | System Settings, General, Login Items & Extensions, allow it to run |

### 12.6 Mac technical limits

The first four limits for Windows apply here too (TUN, system proxy, running programs, tools needing their own configuration), and the fifth takes the Mac form, since Mac has no interface either. Two more:

- **The `launchctl` environment is cleared at login and reboot**: the monitor therefore writes it again every 30 rounds, so it returns by itself after a restart.
- **`~/.envproxy/` is a fixed location**: after installing it holds these files. `locator.sh` is the locator script. `prompt-sync.sh` is the terminal sync script, referenced by one line in the rc files. `path.conf` records the project path. `proxy.env` holds the environment variables for the terminal path and the current state. `owned.env` records the values we wrote, so that clearing removes only those. `prev.env` is the original values saved at install time, used to restore them on uninstall. There are also the launchd output redirection files. The project folder can be moved elsewhere and is located again at the next login, and a backup folder is never picked up by mistake. Uninstalling removes all of these, keeping only the `monitor.log` you chose to keep.

### 12.7 Setting it up for a friend or a new Mac

Copy the whole folder over, open `mac`, double-click `打开菜单.command`, pick `1 Install / Repair`, and you are done.

## 13. License and feedback

MIT license, free to use and modify.

Report problems at **[GitHub Issues](https://github.com/FiretrUCK666/envproxy/issues)**. Including these saves a lot of back and forth:

- A screenshot of `2 Show status` from the menu
- The last 20 lines of `monitor\monitor.log` (Mac: `mac/monitor/monitor.log`)
- Your operating system version, and the name of the proxy app you use
