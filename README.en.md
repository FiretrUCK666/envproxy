# EnvProxy — automatic proxy for your terminal

English | [简体中文](./README.md)

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

Almost always nothing. Of the three cases below, only the first needs nothing from you; the other two cost at most reopening one window.

| Your situation | What happens | What you do |
|---|---|---|
| **A window or program opened after installing** | It reads the current state when it starts | **Nothing** |
| **A window kept open, proxy changed later** | The window still holds the old state | Press Enter once (a cmd window has to be reopened) |
| **A window opened before installing** | The sync code was never loaded into it | Open a new window; to avoid reopening, load it by hand with the command in 3.1 |

### Why an open window needs one Enter press

Each program reads the environment variables once, at startup, and keeps that copy. Changing them later in the system does not reach a window that is already running.

So new windows are always right, and old ones need to read again. EnvProxy reads at the moment a command finishes and the cursor comes back, which happens all the time anyway.

### AI tools, editors, IDEs

They usually open a terminal as a new process, so they are correct automatically.

Two need a restart: it was already open before you installed EnvProxy, or it runs in the background rather than on demand. If unsure, restart it once.

## 1. Install (3 steps, 5 minutes)

1. Click **[here to download the Windows package](https://github.com/FiretrUCK666/envproxy/releases/latest/download/EnvProxy-win.zip)** (Mac: [`EnvProxy-mac.tar.gz`](https://github.com/FiretrUCK666/envproxy/releases/latest/download/EnvProxy-mac.tar.gz))
2. Unzip anywhere; the folder can be renamed. Open `win` and double-click **`打开菜单.cmd`** (Mac: open `mac`, double-click **`打开菜单.command`**), pick **`1 Install / Repair`**
3. When you see the monitor started message, you are done

Installing does four things: it saves your current variable values (restored on uninstall), registers start at login, adds a small sync script to your terminal's startup configuration, and starts the monitor plus corrects the variables once.

Progress is reported as steps 1–4. The order differs: Windows does (1) start at login, (2) monitor, (3) variables, (4) terminal sync; Mac does (1) start at login, (2) terminal sync, (3) monitor, (4) variables. Saving your original values happens before step 1, so it has no number of its own.

<img src="./assets/readme/first-run.en.svg" width="100%" alt="Install in three steps: download the package for your platform, double-click the menu and choose 1 Install / Repair, see the monitor started message; below, a side by side comparison: a window opened after the install takes effect right away, and a window that was open before also catches up once you reopen it or load the sync script by hand">

If something goes wrong, open the menu and pick **`1 Install / Repair`**. It fixes most problems, does not install a second copy, does not cut your network, and does not lose your settings.

> If the downloaded file is blocked the first time you double-click it: right-click, Properties, Unblock (or run `Unblock-File .\EnvProxy-win.zip`). Do not change your execution policy.

### Updating

Open the menu and pick **`3 Check for updates`**. It reports the latest version number and what changed, and installs only after you agree.

- **Updating does not need the proxy running**: most networks connect as they are. If it reports it cannot connect, toggle your proxy app once and retry.
- **Checksums are verified before installing**: they are compared before installation, and nothing is installed if they do not match. A broken install is more trouble than no install. When an older release carries no checksum, or the file was just downloaded and antivirus still holds it open, this step is skipped and the install continues.
- **Only program files are replaced**: your files, logs and the run markers in `monitor\` are left alone. The monitor restarts on the new code afterwards.

## 2. Open the menu

Double-click `打开菜单.cmd` (Mac: `打开菜单.command`). It only passes the number you pick to the real program; it does not modify any file itself.

| Menu item | What it does | What it affects |
|---|---|---|
| **Everyday** | | |
| **1 Install / Repair** | Use it the first time, and whenever something feels wrong | Start at login + terminal sync script + environment variables + background monitor |
| **2 Show status** | Monitor, proxy, terminal sync, environment variables, version | Read-only, changes nothing |
| **3 Check for updates** | Explains what changed first, installs only if you agree | Program files only, then the monitor restarts on the new code |
| **4 Help** | Read it when you forget how something works | Prints text only, changes nothing |
| **Upkeep** | | |
| **5 Stop the monitor** | Temporary; it returns at next login | Monitor process + environment variables |
| **6 Full restore** | Complete uninstall, back to before installing | Everything (log optionally kept) |
| **Quit** | | |
| **0 Quit** | Closes the menu | Nothing |

The numbers run top to bottom and are grouped by how often you need them, so there is nothing to memorise.

**Pressing Enter directly means show status**, the item you look at most. The menu header shows whether the monitor is running and the current version, so you do not need to go in.

The menu and help use only two actions: **type a number** to do that thing; **press Enter** to go back — in the main menu that means show status, in help it means go back one level. There are no other keys to remember.

Pick `4` for help: one entry answers one question, chosen by what you are stuck on.

| No. | One entry answers one question |
|---|---|
| 1 | What is this for |
| 2 | What do I do after installing |
| 3 | Pin this window to a direct connection / go back to automatic |
| 4 | Send this window through a corporate proxy |
| 5 | Make one command skip the proxy |
| 6 | What each menu item does |
| 7 | Installed but still cannot reach the internet / status looks wrong |
| 8 | Still not working / I want to remove it |

Once inside, the bottom line lists every number, with the one you are reading in brackets.

<img src="./assets/readme/buttons.en.svg" width="100%" alt="What each menu item affects: install changes start at login, the terminal sync script, environment variables and the background monitor; status is read-only; stop clears the monitor and the environment variables; full restore clears everything but the log; show status and help change nothing; check for updates only when a newer version exists replaces program files and restarts the monitor, and does nothing when already current">

### Logs

`monitor\monitor.log` (Mac: `mac/monitor/monitor.log`) records the decisions it made. It is capped at 200KB and keeps only the most recent 200 lines once full.

Uninstalling asks whether to keep it. Keep it and this is the only file left; everything else is removed.

## 3. Everyday commands on one page

**You do not normally need this section.** The proxy app switching on and off is all it takes; the terminal follows without any command. Read on only when you want to manage one specific window, or want to confirm the install really took.

Each subsection stands on its own; there is no need to read them in order.

First, work out which terminal you are in. The four take different commands:

| Prompt looks like | What you are using | How to open it |
|---|---|---|
| `PS C:\...>` | PowerShell (ships with Windows) | Start menu, search PowerShell |
| `C:\...>` | cmd (Command Prompt, ships with Windows) | Start menu, search Command Prompt |
| `name@host MINGW64 ~ $` | Git Bash (a bash shell **on Windows**) | Start menu, search Git Bash |
| `name@host ~ %` | Mac Terminal (zsh by default) | Launchpad, search Terminal |

Three things that trip people up:

- **Git Bash is a Windows thing.** It comes with Git for Windows; there is no such name on a Mac. It and the Mac Terminal both use bash-style syntax, which is why the sections below often cover them together.
- **The Mac Terminal is not bash by default, it is zsh**, so the prompt ends with `%` rather than `$`. The syntax is the same as bash, so the commands below work as written.
- Windows Terminal is only the window that hosts a shell: what you open inside it (PowerShell, cmd or Git Bash) is your choice. It is not a shell itself.

**Follows automatically**: PowerShell, Git Bash, and the Mac Terminal (zsh and bash both work). **Does not follow**: cmd (no prompt hook available) and fish (another Mac shell; the hook cannot reach it).

### 3.1 A window you already have open needs one Enter press

EnvProxy follows the proxy app: connect it and the terminal uses the proxy; disconnect it and the terminal goes direct again. **A newly opened window is always current.**

A window that was already open does not change on its own. Every program reads the environment once, at the moment it starts; after that it cannot see later changes. To update it, **press Enter in that window** (or run any command).

| Your window | What state it holds | What to do |
|---|---|---|
| Opened after installing | Already current | Nothing |
| Kept open while the proxy app was switched | The old state | Press Enter once |
| Opened before installing EnvProxy | The sync code was never loaded | Open a new window |

**A cmd window can only be reopened.** Pressing Enter does nothing there: cmd has no "run this before every prompt" mechanism.

If you would rather not reopen and not press Enter, load it by hand once:

| Window | Command |
|---|---|
| PowerShell | `. $PROFILE` |
| Git Bash | `source ~/.bashrc` |
| Mac Terminal | `. ~/.envproxy/prompt-sync.sh` |

The leading `.` and the space after it are both required; it means "run this file in this window". It affects only this window, so other open windows each need their own. If EnvProxy was never installed from this window, you may see a red "cannot find path" error: that is expected, just open a new window.

### 3.2 Pin this window to a direct connection / go back to automatic

**Pin this window to a direct connection**

To keep **this one window** off the proxy, set a switch inside it.

**PowerShell**

```
$env:ENVPROXY_TERM = 'off'
```

**Git Bash / Mac Terminal**

```
export ENVPROXY_TERM=off
```

Once the switch is set, the proxy variables in that window are cleared at the next prompt, and it stays direct from then on (a command run on the same line still sees the old values).

**cmd has no such switch** (it has no prompt hook), so clear the five variables yourself. One per line:

```
set HTTP_PROXY=
set HTTPS_PROXY=
set ALL_PROXY=
set NO_PROXY=
set NODE_USE_ENV_PROXY=
```

All on one line also works:

```
set HTTP_PROXY=&set HTTPS_PROXY=&set ALL_PROXY=&set NO_PROXY=&set NODE_USE_ENV_PROXY=
```

Leave no spaces around `&`. A space makes the value a single space instead of empty, and the proxy keeps working.

**Do not use `unset HTTP_PROXY ...`**: the hook writes the lower-case spellings (`http_proxy` and friends) into Git Bash. Unsetting the upper-case one leaves the lower-case one behind, and curl in Git Bash honours it — so you would still be going through the proxy. The next prompt puts them all back too. The switch above is the only real takeover.

---

**Going back to following the proxy app**

| Window | Command |
|---|---|
| PowerShell | `Remove-Item Env:ENVPROXY_TERM` |
| Git Bash / Mac Terminal | `unset ENVPROXY_TERM` |
| cmd | Reopen the window |

These changes only live in that window. Close it and they are gone.

### 3.3 Send this window through a corporate proxy

Two steps, **in this order**: pin to direct in 3.2 first, then set the address. Without stopping auto-follow, the next change the proxy app makes overwrites the address you just set.

Replace `your-host:port` with what your company gave you — ask IT; they usually hand you a proxy setup note. This is **not** the local proxy app's port, so do not go looking there.

**PowerShell**:

```
$env:HTTPS_PROXY = 'http://your-host:port'
```

**cmd**:

```
set HTTPS_PROXY=http://your-host:port
```

**Git Bash / Mac**:

```
export HTTPS_PROXY=http://your-host:port
```

Values you set are never deleted — a corporate proxy, a capture tool, another port all stay as they are, as long as they differ from what we wrote.

**Check which one is in effect** (a value means through the proxy, empty means direct):

| PowerShell | cmd | Git Bash / Mac |
|---|---|---|
| `$env:HTTPS_PROXY` | `set HTTPS_PROXY` | `echo $HTTPS_PROXY` |

### 3.4 Make one command skip the proxy

Tools differ, and there is no single universal command.

| Tool | PowerShell | cmd | Git Bash / Mac |
|---|---|---|---|
| `curl` | `curl.exe --noproxy "*" URL` | `curl --noproxy "*" URL` | `curl --noproxy '*' URL` |
| `git` | `git -c http.proxy= -c https.proxy= clone REPO` | same | same |
| `npm` | `npm --noproxy=registry.npmjs.org install PKG` | same | same |
| `wget` | not bundled; if installed, `wget.exe --no-proxy URL` | same | `wget --no-proxy URL` |
| `docker` | change Docker's own settings; no per-command flag | same | same |

Three traps, all measured:

- **Only in PowerShell 5.1 are `curl` and `wget` aliases** pointing at `Invoke-WebRequest`, so typing them there fails with "parameter not found" and you must write `curl.exe`. **In cmd and in PowerShell 7, `curl` is the real curl.exe**, so the plain form works.
- **npm's `--noproxy` accepts domains only; `*` does nothing.** It does not complain, requests still go through the proxy, and you think you bypassed it. Use a real domain.
- **`npm --no-proxy` is read as `--proxy=false`**, which is not the same as "skip the proxy". Use `--noproxy=domain`.

Also: `git`'s `-c http.proxy=` must be left empty — empty means "this command skips the proxy", any other value means "use that proxy instead". npm reads only `HTTPS_PROXY`, not `HTTP_PROXY`; EnvProxy writes both, so npm works, but if you set only `HTTP_PROXY` yourself npm will not be proxied.

These flags belong to each tool, not to EnvProxy. Without them, the tools read the variables EnvProxy wrote.

### 3.5 How to confirm it really took

Pick **2 Check status** in the menu and look at the "terminal sync" line:

| Shown | Meaning | What to do |
|---|---|---|
| Active | Normal | Nothing |
| Installed but cannot run (reason given) | Windows execution policy stops PowerShell from running the profile. Windows only | Follow the hint on the second line (see section 4), then open a new window |
| Markers in the profile are unpaired | Something else edited your profile | Run **1 Install / repair** once |
| No sync block in the profile | Never installed, or it was cleaned away | Run **1 Install / repair** once |
| Cannot read the profile path this time (Windows only) | Rare; this run cannot tell | Look again in a few seconds; if it stays, run **1 Install / repair** once |

### 3.6 Use it without the menu (scripts, remote sessions)

The menu is for double-clicking. When you write a script, or connect remotely with no graphical desktop, use the command-line parameters. The first six rows match the six menu items one to one; the last two have no menu entry.

| Goal | Windows | Mac |
|---|---|---|
| Install / repair | `-Install` | `install` |
| Show status | `-Status` | `status` |
| Check for updates | `-Update` | `update` |
| Help | `-Help` | `help` |
| Stop the monitor | `-Stop` | `stop` |
| Full restore | `-Uninstall` | `uninstall` |
| Open the menu | `-Menu` | `menu` |
| Self-check (troubleshooting) | — | `self-test` |

The order matches the menu: four everyday items first, then the two upkeep ones. The last row is a Mac-only troubleshooting command: it runs an internal check inside a throwaway sandbox and touches neither your profile nor your environment variables.

`-Purge` (Mac: `--purge`) pairs with full restore only and means delete the log too. `-Yes` (Mac: `--yes`) pairs with check-for-updates only and means stop asking before installing.

Go into the folder that holds the program first. **Skipping this gives "file not found"**, because the program lives under `win\` and `mac\`.

Windows (cmd or PowerShell):

```
cd win
powershell -ExecutionPolicy Bypass -File envproxy.ps1 -Status
```

macOS (Terminal):

```
cd mac
bash envproxy.sh status
```

**Spell the switch out; abbreviations are rejected.** `-Instal` missing one letter is refused on purpose — otherwise a typo would turn into a real install.

## 4. Something is wrong: check in this order

**Work through the list in order, finishing one step before starting the next.**

| What you see | Most likely cause | What to do |
|---|---|---|
| "Unrecognized switch" (Windows) or "unrecognized argument" (Mac) | A typo, or an abbreviation | Parameters must be written in full; abbreviations are rejected. Compare with the forms listed in the menu |
| The terminal still cannot use the proxy | This window was opened before installing | Open a new window. To avoid reopening, load it as shown in 3.1 |
| Still cannot use the proxy, and a new window does not help | The monitor is not running | Open the menu and pick 1 (Install / Repair) |
| "Installation incomplete, missing program files" | The folder was not copied in full, or files were deleted | Download again from the Releases page and unzip over this folder. **Upgrading through Check for updates removes the old files for your platform automatically** |
| Environment variables reappear after being removed | The node itself is unstable, and the monitor writes what it observes | Expected. If it keeps happening the node is poor; switch to another |
| Variables linger after disconnecting | The app's "disconnect" does not stop its core, and the node is still reachable | Expected. Quit the proxy app to stop it immediately |
| "Terminal sync" in the status shows "installed but cannot run" | Windows execution policy stops PowerShell from running the profile | Follow the hint on the second line, then open a new window. If you only need the variables to work, you can leave this alone for now |
| Everything above tried and it still fails | — | Open the menu, pick 2 and screenshot the status; then pick 1 to repair |

> Most problems are solved by **picking 1** in the menu. It does not install a second copy, does not cut your network, and does not lose your own settings.

## 5. How it decides whether you are behind a proxy

It checks every 2 to 3 seconds (2 while proxying, 3 while direct), but **it does not trust a port just because it exists**. Three conditions must hold:

<img src="./assets/readme/mechanism.en.svg" width="100%" alt="Three-condition flow: every 2 to 3 seconds it enumerates listening ports and keeps those that answer a CONNECT handshake; then it tests each candidate for real connectivity; only then are the proxy variables written">

1. **A port is listening** — some program on this machine opened a proxy port
2. **It really is a proxy** — a `CONNECT` handshake must answer `HTTP/1.x 200`. This rules out development servers and ordinary web servers
3. **It really reaches the internet** — the port is used to reach **7 different endpoints**, and **any one** returning a real response is enough

All three must hold before any variable is written. A web server on your machine is never mistaken for a proxy.

It does not rely on brands, process names or port numbers — those only speed up scanning; the decision always goes through these three.

<img src="./assets/readme/states.en.svg" width="100%" alt="Three everyday states: connecting the proxy app writes the full set of proxy variables in 6 to 10 seconds; disconnecting or quitting removes them and restores a direct connection, in about 8 seconds after quitting or 15 to 50 seconds after disconnecting only, and reconnecting takes about 10 to 25 seconds; new ports, new apps and flapping are followed automatically and the variables are rewritten to the new port">

**Deciding "disconnected" is far more cautious than deciding "connected"**: one failed probe is not a disconnect; it takes 10 seconds of continuous failure and at least 3 probes. A single success counts as connected immediately. Removing your variables by mistake costs more than waiting a little. After a conclusion it keeps watching for another 1 minute, so a wrong call corrects itself.

| Action | Takes effect in |
|---|---|
| Starting the proxy app | about 6-10 seconds |
| Quitting the proxy app entirely | about 8 seconds |
| Disconnecting only, without quitting | about 15–50 seconds |
| Reconnecting after a drop | about 10–25 seconds |

**Which variables it writes** (the whole set goes in and comes out together):

| Variable | Value | Purpose |
|---|---|---|
| `HTTP_PROXY` | `http://127.0.0.1:port` | Proxy for http:// requests |
| `HTTPS_PROXY` | `http://127.0.0.1:port` | Proxy for https:// requests |
| `ALL_PROXY` | `http://127.0.0.1:port` | Fallback for protocols the others do not cover |
| `NO_PROXY` | `localhost,127.0.0.1,::1` | Local addresses bypass the proxy |
| `NODE_USE_ENV_PROXY` | `1` | Makes newer Node tools read the proxy from the environment |

Windows gets 5, macOS gets 9 (the same 5 plus lowercase spellings). Windows variable names are case-insensitive, so a lowercase entry only overwrites the same one; macOS treats each case separately and some tools read only lowercase.

<details>
<summary>Why these settings are what they are (does not affect usage, expand to read)</summary>

- Proxy values always use `http://`, never `socks5://`. The local proxy port answers both protocols, some tools accept only `http://`, and unifying gives the widest compatibility with no loss of function. Tools such as `dsh` warn and skip when they see a SOCKS value.
- Why Windows gets only one spelling: the two spellings are the same variable there, and a duplicate makes .NET hosts fail while building their table with `An item with the same key has already been added`, affecting everything running in that terminal window.
- IPv6 addresses inside `NO_PROXY` must be written as bare `::1`. Written as `[::1]`, httpx treats it as an ordinary domain, builds an invalid pattern, and every request afterwards fails with `InvalidURL`. Brackets are URL literal syntax, in the wrong position here.
- Your own `NO_PROXY` entries are never removed, only added to. Uninstalling reclaims only what this tool wrote.
- If another program corrupts the variables (overwrites, clears, or drops an entry), nothing needs doing: the monitor re-checks the whole table every 30 rounds and writes back only what is missing.
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

The rule is: **when unsure, do nothing.**

- **Cannot read it, do not act**: if the port list cannot be read, it does not treat that as "no proxy" and delete your variables. It keeps the previous state.
- **Only our own values are cleared**: values you changed, corporate proxies, other ports — none are touched. With no ownership record it changes nothing.
- **Backup before editing**: `$PROFILE` and the Mac rc files get a `.envproxy.bak` copy first. If the write fails, nothing changes at all.
- **Writes keep files intact**: content goes to a temporary file and then replaces the original. A power cut or a forced stop leaves the original complete.
- **Re-installing is harmless**: when everything is already right it does not touch your settings.
- **Uninstalling checks each item**: everything is read back, and any residue is reported as "incomplete" rather than claimed as success.

## 7. Performance and traffic

- **Almost no overhead once stable**: each port is probed at most once every 15 seconds, reading only response headers, under 1KB each time.
- **Shorter intervals while gathering evidence**: when failures appear but stay below the threshold it probes every 5 seconds. After the conclusion flips it keeps watching for another 60 seconds at that rate (so it does not flip straight back), then returns to 15 seconds.
- **No residue after uninstalling**: variables, start at login, the locator script and the sync block are all removed, leaving only the log if you kept it.
- **Delay at the prompt is imperceptible**: before each prompt it reads the local state once (PowerShell reads the registry, Git Bash reads a small state file, Mac reads `proxy.env`) and starts no external process at all.

## 8. What is in the folder

Unzipping gives roughly this. The folder can be renamed; each package contains only its own platform, so the Windows package has no `mac\` and vice versa.

```
EnvProxy\
  win\                   Windows version
    打开菜单.cmd         the only file you double-click on Windows
    envproxy.ps1         the program
    locator.ps1          source for the login locator (generated into %LOCALAPPDATA%\EnvProxy\launcher.ps1)
    lib\                 program library (leave it alone)
    monitor\             created at runtime, holds the log
  mac\                   Mac version, same layout
    打开菜单.command       the only file you double-click on a Mac
    envproxy.sh          the program
    locator.sh           source for the login locator (counterpart of win's locator.ps1)
    prompt-sync.sh       the terminal sync script (zsh/bash)
    test-mac-pure.sh     self-test script (used by self-test; ships with the package)
    lib\  monitor\        program library; created at runtime, holds the log
  README.md  README.en.md  Chinese and English docs
  LICENSE  VERSION         license and version
  release-notes\          what changed per release (shown by Check for updates)
  assets\readme\          images used by the README
```

The two sides line up one to one. Only two files are Mac-only: `prompt-sync.sh` and `test-mac-pure.sh` (the Windows terminal sync script is generated by the installer, so it is not in the folder).

Three areas with different rules:

- **Program files**: `win\`, `mac\`, `release-notes\`, `assets\`. Updates overwrite these — **do not put your own files there**.
- **Runtime folder**: `monitor\`. Logs and run markers, **never overwritten, never deleted**.
- **Top level**: only files of the same name are overwritten, **your own things are never deleted**.

Day to day you only open `win\` (or `mac\`).

### Where the installer writes things

All of it is **outside** this folder, so an update that overwrites the program files never touches them:

| Where | What | What it is for |
|---|---|---|
| `%LOCALAPPDATA%\EnvProxy\` | `launcher.ps1` | the locator script; the login item uses it to find the program |
| | `terminal.env` | the mirror file Git Bash reads: current state and proxy address |
| `HKCU\Environment` | those 5 proxy variables | where the terminal actually picks up the proxy |
| `HKCU\Software\EnvProxy` | the `Owned` and `Backup` keys | which values we wrote, and what yours were before |
| `HKCU\...\Run` | one start-up entry | launches the background program when you log in |
| Your PowerShell profile | one small block (marked `EnvProxy` at both ends) | syncs once on every return to the prompt |
| Your Git Bash `~/.bashrc` | one small block (same markers) | Git Bash reads the mirror file on every prompt |
| `win\monitor\` | `monitor.log`, `monitor.pid` | the decisions it made, and the process id |

Uninstalling removes all of the above, keeping only the `monitor.log` you chose to keep.

<img src="./assets/readme/boundary.en.svg" width="100%" alt="Three areas: the program folder (overwritten by updates, do not keep your files there), the runtime folder (logs and run markers never overwritten or deleted), and the top level (only same-name files are overwritten, your things are never deleted)">

## 9. Copying and backing up the folder

**It can be copied, renamed and moved.** One thing to know: **once the original location is renamed or moved, the running monitor can no longer find its own program.** It exits by itself and clears the proxy variables, so no stale setting is left behind.

Two ways to bring it back:

- **Wait for the next login**: the locator script finds the new location and takes over.
- **Bring it back now**: double-click Install / Repair once.

The search covers two areas: **six levels** down from the common locations (Desktop, Documents, Downloads, OneDrive, `.config`), and **four levels** under the root of each non-system drive (the system drive's root is skipped, so it does not walk the whole disk). That is why `C:\Projects\EnvProxy` is not found but `D:\Projects\EnvProxy` is. Move it outside those areas and you have to double-click Install once.

A copied backup **is never mistaken for the live one**, since log activity decides which is running, so backups can stay in place.

## 10. Setting it up for a friend or a new machine

1. Get the package onto the new machine, either way: click **[Windows download](https://github.com/FiretrUCK666/envproxy/releases/latest/download/EnvProxy-win.zip)**, or copy the whole unzipped folder over (USB drive, cloud storage, or an archive all work)
2. Double-click `win\打开菜单.cmd` and pick `1 Install / Repair`
3. Done. No administrator rights are needed, and nothing else has to be installed

> Windows users can stop here. Each platform has its own package: Mac users download the Mac package, and an existing folder that contains `mac\` works as it is.

## 11. Technical limits (5)

<img src="./assets/readme/limits.en.svg" width="100%" alt="Five technical limits: pure TUN mode is not handled, system proxy settings are never modified, already-running programs are not changed, tools that need their own proxy configuration are out of scope, and there is no interface">

| Limit | Reason | Effect |
|---|---|---|
| **Pure TUN mode is not handled** | No local port to judge | Its traffic already goes through the app, so nothing is needed |
| **System proxy settings are not modified** | Doing so would affect browsers and other programs | Only user-level environment variables are written, and you can confirm in system settings that nothing else was touched |
| **Already-running programs are not changed** | Variables are read once, at startup | Windows opened earlier need one Enter press (section 0) |
| **Tools that need their own proxy configuration are out of scope** | They do not read these variables | Maven, Gradle, Docker and others are covered by the collapsed table in section 5 |
| **No interface** | Zero dependencies is the install premise | There is only a menu: no tray icon and no window |

Why pure TUN mode is left alone: it cannot be told apart from a corporate VPN. A wrong decision there would remove your only proxy path, so it is better to do nothing.

Mac adds one: **the `launchctl` environment is cleared at login and reboot**, so the monitor writes it again every 30 rounds and it returns by itself after a restart.

## 12. macOS version

### 12.1 Difference from the Windows version

Windows writes the registry and broadcasts a change notification; Mac writes `~/.envproxy/proxy.env` and calls `launchctl setenv`. Both paths are updated together, so the behaviour you see is the same.

On the terminal side, the Mac default shell is `zsh` (since macOS 10.15) and `bash` 3.2 is still shipped. **Both are supported**: the installer drops one line into `.zshenv`/`.zshrc` and into `.bash_profile`/`.bashrc`, so either shell follows along. `fish` is not supported: it does not read those files.

<img src="./assets/readme/mac-paths.en.svg" width="100%" alt="macOS writes two paths: terminals read ~/.envproxy/proxy.env, and programs launched from the Dock read the launchctl environment; both paths are updated together">

### 12.2 Install (3 steps)

1. Put the Mac package (`EnvProxy-mac.tar.gz`) anywhere on the Mac, or copy the whole folder that contains `mac\` (USB drive, AirDrop, or an archive all work)
2. Open `mac` and double-click `打开菜单.command`, then pick `1 Install / Repair`
3. Once you see the monitor started message, you are done

No Homebrew, Python or Node is needed, no `sudo`, and the `zsh` that ships with macOS 12 and later is enough. (Mac only: download [`EnvProxy-mac.tar.gz`](https://github.com/FiretrUCK666/envproxy/releases/latest/download/EnvProxy-mac.tar.gz).)

### 12.3 Menu (identical to Windows)

The numbers, behaviour and what each item affects are identical to Windows, including `4 Help` and `0 Quit`. Pressing Enter directly means show status.

### 12.4 What is in the `mac` folder

See the folder structure in section 8. Two files are Mac-only with no Windows counterpart: `prompt-sync.sh` (the terminal sync script used by zsh and bash) and `test-mac-pure.sh` (the self-test script).

The locator has a source file on each platform — `locator.sh` on Mac, `win\locator.ps1` on Windows. The installer uses it to generate the copy that actually runs at login, in a fixed location (Windows: `%LOCALAPPDATA%\EnvProxy\launcher.ps1`).

### 12.5 Three problems you may hit on first install on a Mac

<img src="./assets/readme/mac-blockers.en.svg" width="100%" alt="Three problems on first install on a Mac: the downloaded file is quarantined, the script is not executable, and macOS asks to access your Documents folderhe background item">

| Symptom | Cause | What to do |
|---|---|---|
| Double-clicking does nothing, or "cannot be opened" | The downloaded file is quarantined by the system | Right-click, then Open; or run `xattr -d com.apple.quarantine 打开菜单.command` in a terminal |
| "Permission denied" | The script is not executable | Run `chmod +x 打开菜单.command` in a terminal |
| Installed, but the status says it is not running | macOS blocked the background item, or the "access your Documents folder" prompt was denied | Background item: System Settings, General, Login Items & Extensions, allow it to run. Folder access: System Settings, Privacy & Security, Files and Folders. Then run Install / Repair once more from the menu |

### 12.6 What the installer adds

Installing writes files to three places. **None of them is the folder you downloaded.**

| Where | Files | What they are for |
|---|---|---|
| `~/.envproxy/` | `locator.sh` | the locator script (tells start-at-login where the program is) |
| | `prompt-sync.sh` | the terminal sync script, referenced by one line in the rc files |
| | `path.conf` | records where the project folder currently is |
| | `proxy.env` | the environment variables for the terminal path and the current state |
| | `owned.env` | the values we wrote, so clearing removes only those (absent if the proxy has never been on) |
| | `prev.env` | the original values saved at install time, restored on uninstall |
| | `monitor.stdout.log` | what the background program prints (look here when login start-up misbehaves) |
| | `monitor.stderr.log` | errors the background program reports |
| `~/Library/LaunchAgents/` | one `*.plist` | the start-at-login item that launches it when you log in |
| `mac/monitor/` inside the project folder | `monitor.log` | the decisions it made (black box) |
| | `monitor.pid` | the process id of the background program |

Your shell config files (`~/.zshrc`, `~/.bashrc` and the like) also gain one small block, marked `EnvProxy` at both ends; removing that block turns off auto-follow for that terminal.

**The project folder can be moved anywhere**: it is located again at the next login, and a backup folder is never picked up by mistake. Uninstalling removes all of the above, keeping only the `monitor.log` you chose to keep.

### 12.7 Setting it up for a friend or a new Mac

Copy the whole folder over, open `mac`, double-click `打开菜单.command`, pick `1 Install / Repair`, and you are done.

## 13. License and feedback

MIT license, free to use and modify.

Report problems at **[GitHub Issues](https://github.com/FiretrUCK666/envproxy/issues)**. Including these saves a lot of back and forth:

- A screenshot of `2 Show status` from the menu
- The last 20 lines of `monitor\monitor.log` (Mac: `mac/monitor/monitor.log`)
- Your operating system version, and the name of the proxy app you use
