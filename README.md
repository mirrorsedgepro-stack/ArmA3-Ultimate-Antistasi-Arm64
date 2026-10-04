# 32-Player Arma 3 Dedicated Server - Antistasi Ultimate [RHS]

A production-ready Docker containerization setup for hosting a 32-player **Antistasi Ultimate** campaign with the **RHS Escalation** modset on **Altis**, powered by [BrettMayson/Arma3Server](https://github.com/BrettMayson/Arma3Server).

---

## Architecture & Features

- **Base Image:** `ubuntu:24.04` (ARM64) running [FEX-Emu](https://fex-emu.com/) with a bundled x86_64 Debian userland; SteamCMD, the server and the Headless Clients all run as x86_64 under FEX.
- **Architecture Support:** ARM64 (`aarch64`) hosts. Building the image needs amd64 emulation for the x86 userland stage, which `./scripts/manage.sh start` sets up automatically.
- **Mission Framework:** [Antistasi Ultimate](https://steamcommunity.com/sharedfiles/filedetails/?id=3020755032) mod edition on Altis.
- **Modset:** RHS Escalation suite (AFRF, USAF, GREF, SAF) + CBA_A3.
- **Headless Clients (HCs):** 3 containerized Headless Clients automatically connected via loopback to distribute AI garrisons, patrols, and QRFs across dedicated CPU cores.
- **Engine Tuning:** 64-bit binary (`arma3server_x64`), 60 FPS tickrate cap, and high-throughput `basic.cfg` network tuning (2048 msgs/tick, 1 Gbps max bandwidth).
- **Campaign Persistence:** Automated campaign state resumption (`autoLoadLastGame = 60`) with dedicated automated backup and restore scripts.
- **Client Sync:** Pre-generated `configs/preset.html` for 1-click mod synchronization in the official Arma 3 Launcher.

---

## Directory Structure

```text
.
├── docker-compose.yml       # Docker Compose service definition
├── .env.example             # Configuration and credentials template
├── .gitignore               # Excludes secrets, profile saves, and backups
├── README.md                # Server documentation & operational manual
├── configs/
│   ├── main.cfg             # Server configuration (name, password placeholders, missions, HCs)
│   ├── basic.cfg            # Network performance tuning for 32 players
│   └── preset.html          # Arma 3 Launcher HTML mod preset
├── scripts/
│   ├── manage.sh            # Main server management CLI
│   ├── backup_campaign.sh   # Campaign save snapshot & rotation tool
│   ├── restore_campaign.sh  # Interactive campaign restore tool
│   └── setup_binfmt.sh      # ARM64/x86_64 multi-architecture emulator setup
├── missions/                # Mount for custom .pbo scenarios (if needed)
├── mods/                    # Mount for custom local mods (if needed)
├── servermods/              # Mount for server-only mods (if needed)
└── backups/                 # Storage for timestamped campaign backups
```

---

## Quick Start Guide

### 1. Configure Credentials and Passwords

Copy the `.env.example` file to `.env`:

```bash
cp .env.example .env
```

Open `.env` and fill in your Steam credentials:

```bash
nano .env
```

> **Note:** SteamCMD requires a Steam account to download Arma 3 Workshop mods. For security, using a secondary Steam account is recommended. If your account has Steam Guard enabled, you may be prompted for your 2FA code during the initial SteamCMD login.

In the same `.env`, set the server join password and admin password. They are filled into the `${...}` placeholders in `configs/main.cfg` at startup, so the config itself holds no secrets:

```bash
ARMA_PASSWORD='your_server_join_password'
ARMA_PASSWORD_ADMIN='your_secret_admin_password'
```

### 2. One-Time Steam Guard Authentication (If 2FA is Enabled)

If your Steam account uses Steam Guard (email or mobile authenticator), authenticate your account once:

```bash
# Option A: Interactive prompt
./scripts/manage.sh steam-login

# Option B: Pass code directly (e.g. from your email/authenticator)
./scripts/manage.sh steam-login YOUR_CODE
```

Alternatively, you can specify `STEAM_GUARD_CODE=YOUR_CODE` directly in `.env`.
Once authenticated, the session token (`ssfn` sentry file) is permanently saved in the Docker named volumes (`steam_data` and `steam_root`), so you will never be asked again.


### 3. Start the Server

Start the server using the management script:

```bash
./scripts/manage.sh start
```

This runs pre-flight checks (verifying `.env` and configuring `binfmt` on ARM64 if needed) and launches the container detached.

### 4. Follow Initial Startup & Mod Downloads

On first launch, SteamCMD will download the Arma 3 server binary (~5 GB) and all 42 Workshop mods (~30 GB). You can stream live progress:

```bash
./scripts/manage.sh logs
```

Once you see:
```text
LAUNCHING ARMA SERVER WITH ./arma3server_x64 ...
LAUNCHING ARMA CLIENT 0 WITH ...
LAUNCHING ARMA CLIENT 1 WITH ...
LAUNCHING ARMA CLIENT 2 WITH ...
```
Your server and all Headless Clients are live!

---

## Client Connection & Mod Sync

Joining players can synchronize all 42 required mods in seconds:

1. Send the [configs/preset.html](file:///home/jcee-slave/ArmaA/configs/preset.html) file to your players.
2. In the official **Arma 3 Launcher**:
   - Navigate to the **Mods** tab.
   - Click **Preset** (top right) &rarr; **Import**.
   - Select `preset.html`.
3. The launcher will automatically prompt players to subscribe to and download any missing mods from the Steam Workshop. The full modset (RHS, Antistasi Ultimate, ACE, JSRS, Blastcore and the rest) is listed in `configs/preset.html`, the single source of truth for the server's mods.
4. Players launch Arma 3 with the preset loaded, go to **Server Browser** &rarr; **Direct Connect**, and enter your server IP and port `2302`.

---

## Network & Firewall Requirements

Because `network_mode: host` is enabled for optimal 32-player UDP throughput, ensure the following ports are open on your host firewall and forwarded on your router:

| Port | Protocol | Purpose |
| :--- | :--- | :--- |
| **2302** | UDP | Arma 3 Game Port |
| **2303** | UDP | Steam Query Port |
| **2304** | UDP | Steam Master / Reporting |
| **2305** | UDP | VON (In-Game Voice) |
| **2306** | UDP | BattlEye Anti-Cheat |

On Ubuntu/Debian host:
```bash
sudo ufw allow 2302:2306/udp
```

---

## Server Management CLI (`./scripts/manage.sh`)

| Command | Action |
| :--- | :--- |
| `./scripts/manage.sh start` | Run pre-flight checks and start the server |
| `./scripts/manage.sh stop` | Gracefully shut down the server |
| `./scripts/manage.sh restart` | Restart the server |
| `./scripts/manage.sh status` | View container status, CPU/RAM usage, and active ports |
| `./scripts/manage.sh logs` | Follow live server console output |
| `./scripts/manage.sh hc` | Verify status of the 3 Headless Client worker processes |
| `./scripts/manage.sh fps` | Monitor live server tickrate / FPS |
| `./scripts/manage.sh backup` | Manually trigger a compressed campaign save backup |
| `./scripts/manage.sh restore` | Interactively restore campaign state from a backup |

---

## Antistasi Campaign Administration & In-Game Setup

1. **Logging In as Admin:**
   When connecting to the server, open in-game chat and type:
   ```text
   #login your_secret_admin_password
   ```
2. **First Time Campaign Initialization:**
   - The server auto-launches into `Antistasi_Altis.Altis`.
   - The logged-in admin selects the rebel faction, enemy occupier faction (e.g. RHS USAF or AFRF), and invader faction.
   - Click **Start Campaign**.
3. **Resuming Saved Games:**
   - `main.cfg` includes `autoLoadLastGame = 60;`. When the server restarts, it automatically reloads your campaign state 60 seconds after a player joins.

---

## Automated Backups & Disaster Recovery

Antistasi saves campaign progress into `./configs/profiles/`.

- **Create a Backup:**
  ```bash
  ./scripts/manage.sh backup
  ```
  Archives the profile state to `./backups/antistasi_campaign_YYYYMMDD_HHMMSS.tar.gz` and automatically keeps the 14 most recent snapshots.

- **Restore a Backup:**
  ```bash
  ./scripts/manage.sh restore
  ```
  Stops the server safely, creates a safety snapshot of the existing state, extracts the chosen archive, and restarts the server.

- **Automate with Cron:**
  To schedule a campaign backup every 4 hours, run `crontab -e` and add:
  ```cron
  0 */4 * * * /home/jcee-slave/ArmaA/scripts/backup_campaign.sh >/dev/null 2>&1
  ```
