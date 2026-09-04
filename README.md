# Tunnel

**An all-in-one public tunnel launcher for the terminal.**

`Tunnel` exposes a local server to the public internet through four tunnel
providers — **Cloudflared**, **localhost.run**, **Pinggy**, and **Serveo** —
from a single interactive bash tool. No accounts, no API tokens, no signup.
Pick a provider, type a port, and get a public URL.

```
     ┌───────────────────────────────────────────────────────────────────────┐
     │                                                                       │
     │    ────  ╱╲  ────                                                     │
     │                                                                       │
     │              5.6    •    Wanz Xploit                                  │
     │                                                                       │
     │  ╭─────────────────────────────────────────────────────────────────╮  │
     │    │  SELECT PROVIDER                                                 │
     │    │  1  Cloudflared    trycloudflare.com                             │
     │    │  2  localhost.run  SSH reverse tunnel                            │
     │    │  3  Pinggy         ⚠ interstitial                                │
     │    │  4  Serveo         ⚠ interstitial                                │
     │    │  5  Check dependencies                                           │
     │    │  0  Exit                                                         │
     │  ╰─────────────────────────────────────────────────────────────────╯  │
     │                                                                       │
     │    ?  Choice:                                                         │
     └───────────────────────────────────────────────────────────────────────┘
```

---

## Features

- **Four providers, one interface.** Switch between Cloudflared quick tunnels,
  localhost.run, Pinggy, and Serveo from an interactive menu.
- **No signup, no API keys.** Every free tier works out of the box — nothing
  to configure, nothing to authorize.
- **Auto-reconnect with fresh links.** When a session drops, `Tunnel`
  restarts the provider and prints the *new* public URL automatically.
- **Auto-installs its own dependencies.** Detects missing tools and installs
  them silently on first run — no prompts, no manual setup.
- **Portable.** Runs on native Termux (`pkg`), proot-distro, Debian, Ubuntu,
  and other apt-based Linux — `sudo` if present, direct run as root otherwise.
- **Responsive terminal UI.** The frame adapts to your terminal width and
  never wraps, from 42 to 80+ columns.

---

## Quick start

```bash
git clone https://github.com/wanzxploit/Tunnel
cd Tunnel
chmod +x run.sh
./run.sh
```

Choose a provider (1–4), enter the local port to expose, and the tool starts
the tunnel. Your public URL appears in a highlighted box:

```
  ┌──────────────────────────────────────────────────────────────────┐
  │   ● TUNNEL ACTIVE                                                │
  ├──────────────────────────────────────────────────────────────────┤
  │                                                                  │
  │  Provider  [localhost.run]                                       │
  │  Local     127.0.0.1:8080                                        │
  │  Public    https://xxxx.lhr.life                                 │
  └──────────────────────────────────────────────────────────────────┘
```

Press `Ctrl+C` to stop the tunnel cleanly.

---

## Providers

| # | Provider      | Public domain                        | Account | Warning                 |
|---|---------------|--------------------------------------|---------|-------------------------|
| 1 | **Cloudflared** | `*.trycloudflare.com`              | No      | — (warning-free)        |
| 2 | **localhost.run** | `*.lhr.life` / `*.localhost.run` | No      | — (warning-free)        |
| 3 | **Pinggy**     | `*.pinggy.link` / `*.free.pinggy.net` | No    | ⚠ interstitial page     |
| 4 | **Serveo**     | `*.serveo.net` / `*.serveousercontent.com` | No | ⚠ interstitial page |

### How each provider works

- **Cloudflared** — runs a free quick tunnel:
  `cloudflared tunnel --url http://127.0.0.1:PORT`. Best availability and the
  cleanest URLs.
- **localhost.run** — SSH reverse tunnel to `nokey@localhost.run` with no key
  required. Reliable and warning-free.
- **Pinggy** — SSH reverse tunnel to `free@a.pinggy.io`. Free tier sessions
  last 60 minutes.
- **Serveo** — SSH reverse tunnel to `serveo.net`, with automatic fallback to
  port `443` if `22` is blocked. Community-run and occasionally down.

> **Note on interstitial warnings.** Free tiers from Pinggy and Serveo show a
> browser interstitial page on first visit. This cannot be removed on the free
> tier — it is a provider limitation, not a configuration issue.

---

## Auto-reconnect

`Tunnel` keeps your tunnel alive. When the current session ends:

1. It detects the drop and prints `Tunnel lost. Reconnecting (attempt #N)...`
2. It starts a fresh session and waits for the new public URL.
3. It displays the **new link** with an `↻  Auto-reconnect #N` marker.

```
  ┌──────────────────────────────────────────────────────────────────┐
  │   ● TUNNEL ACTIVE                                                │
  ├──────────────────────────────────────────────────────────────────┤
  │                                                                  │
  │  Provider  [pinggy]                                              │
  │  Local     127.0.0.1:8080                                        │
  │  Public    https://abc123.pinggy.link                            │
  │                                                                  │
  │  ↻  Auto-reconnect #1   new link below                           │
  └──────────────────────────────────────────────────────────────────┘
```

---

## Manual installation

`Tunnel` installs dependencies automatically, but each one can be installed
by hand if preferred:

| Dependency | Package manager command                           |
|------------|---------------------------------------------------|
| `cloudflared` | `sudo apt install cloudflared` (adds Cloudflare's repo) |
| `openssh-client` | `sudo apt install openssh-client`                 |
| `curl`      | `sudo apt install curl`                            |

On native Termux, replace `sudo apt` with `pkg`:

```bash
pkg update
pkg install openssh-client curl
pkg install cloudflared
```

---

## Usage modes

### Expose a port
```bash
./run.sh
# → choose provider → enter local port → get public URL
```

### Check / install dependencies
Select menu option **5** in the app, or simply run the app and let
auto-install handle anything missing.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Cloudflared fails to start | Free quick-tunnel endpoint occasionally rate-limits. Retry, or use localhost.run / Pinggy. |
| Serveo won't connect | Serveo is community-run and intermittently down. Try another provider. |
| `sudo: command not found` | proot environments log in as root without `sudo` — `Tunnel` detects this and runs directly. |
| Boxes wrap on a small terminal | Resize the terminal; the UI re-detects width on launch (clamped to 42–80). |

---

## Requirements

- **bash** 4+ (specifically `set -u` compatible)
- One of: **Termux**, **proot-distro**, **Debian**, **Ubuntu**, or another
  apt-based Linux
- An internet connection
- Nothing else — dependencies are installed automatically

---

## License

Released under the MIT License.

---

`Tunnel` was created by **Wanz Xploit**.
