# Developer PC Architecture — Design & Requirements

## Goal
Design a complete development workstation setup from scratch on a fresh SSD. The architecture centers around per-project VM isolation for safely running AI coding agents, with a reproducible host environment and unified toolchain management across host and VMs.

## Hardware
- Laptop with i7-1365U (2P+8E cores, 12 threads), 32GB RAM
- Fresh 2TB SSD install
  - Partition 1: 1GB EFI (FAT32)
  - Partition 2: 2GB Recovery (Alpine Linux, ext4)
  - Partition 3: ~1.997TB Root (btrfs, zstd, subvolumes: @, @home, @var, @nix, @snapshots)
  - No swap partition (zram instead)
- Host OS: Arch Linux with Sway (Wayland, i3-compatible tiling compositor)

## Core Architecture Decisions

### VM Technology: Incus (KVM-backed)
- Incus over Vagrant (no per-project config files committed to repos)
- Incus over Firecracker (need persistent stateful VMs, not ephemeral)
- Incus over Qubes OS (too opinionated, takes over entire OS)
- Incus supports both stateful hibernate and full VM lifecycle management

### No GUI Inside VMs
- VMs are headless — no display server, no SPICE/VNC needed
- Web apps accessed from host browser via VM hostnames (e.g., `vm1.incus:3000`)
- Incus built-in DNS resolves VM names automatically on the managed bridge network
- Agents use headless Chromium/Playwright inside the VM for browser testing
- Optional: noVNC inside a special "agent-debug" image for watching agent browser activity

### Storage Backend: btrfs (copy-on-write)
- All VMs share common base images via btrfs reflinks; each VM only stores diffs
- Makes hundreds of persistent VMs viable storage-wise
- Hibernation writes full RAM to disk (~4GB per VM), factor this into planning
- btrfs over ZFS because:
  - In mainline kernel — no module breakage on Arch rolling kernel updates
  - No RAM overhead beyond normal page cache (ZFS ARC competes with VM RAM budgets on 32GB)
  - Transparent compression (zstd) saves meaningful space on dev workloads
  - Single-disk setup — ZFS's self-healing and real-time dedup advantages require mirrors or 64GB+ RAM
  - First-class Incus support, each VM maps to a btrfs subvolume
- **Snapper + snap-pac** for automatic btrfs snapshots before/after every `pacman -Syu` — enables instant rollback of bad Arch updates
- **Alpine Linux recovery partition** (2GB, ext4) — bootable via systemd-boot, allows rollback even when Arch won't boot, no USB needed
- **No swap partition** — zram (compressed swap in RAM) configured via bootstrap.sh, avoids SSD wear

### VM Lifecycle: Persistent + Hibernate
- VMs are long-lived, one per project
- `incus stop --stateful` hibernates: zero RAM, full state preserved (processes, open files, etc.)
- `incus start` resumes exactly where left off — all processes inside the VM's tmux session survive (dev servers, agents, etc.)
- VMs are NOT regularly destroyed/recreated; they accumulate project state over time
- **Hibernate resume failure handling:** if resume fails (corrupt state from power loss, Incus/QEMU version change on Arch rolling update, etc.), wrapper falls back to cold start automatically — disk image is intact, only RAM state (open terminals, running processes) is lost. Wrapper logs a warning. If cold start also fails, suggest `vm rebuild`.

### Laptop Sleep Workflow
- No host hibernation (suspend-to-disk) — host only uses suspend-to-RAM (sleep)
- `vm sleep` command: hibernates all running VMs (freeing their RAM), then suspends the laptop via `systemctl suspend`
- On wake: laptop resumes instantly, but all VMs are hibernated — resume whichever one you need with `vm start`
- This ensures VMs are safely persisted before the laptop sleeps — no risk of corrupt VM state from unexpected power loss during sleep
- Script lives in dotfiles alongside the `vm` CLI

### Resource Allocation
- RAM: 4GB default per VM, overridable via `vm start --ram 8G` or similar flag
- CPU: no restriction — all VMs share full CPU (all 12 threads on i7-1365U)
- Host Linux scheduler handles contention naturally; burst to all cores when only one VM is busy
- CPU limits can be applied reactively if an agent or build goes haywire (`incus config set project limits.cpu 2`)
- **RAM safety check on `vm start`:**
  - Before starting/resuming a VM, wrapper checks available host RAM
  - If remaining RAM after the new VM would drop below a threshold (e.g., ~4GB free for host), warn interactively
  - Show list of currently running VMs with their RAM usage
  - Prompt: start anyway, or hibernate one of the running VMs first to free RAM
  - Prevents accidentally swapping the host into unusability

### Multiple Base Images
- "personal" image: lean Linux with dev tools, no SSH keys (deploy keys used per-project)
- "work" image: personal image + corporate VPN, internal certs, proprietary tooling, work SSH key for repo access
- All images semver-versioned (e.g., personal-v1.0.0, work-v2.3.0)
- Images managed and versioned outside of any project repo
- Base image configs live in the wrapper tooling, not in project directories
- Each VM records which image version it was created from

### Environment Management: Hybrid (Nix for Toolchains, Golden Images for System)

Two separate concerns, two separate mechanisms:

**Nix as unified package manager on host AND VMs:**
- Nix (the package manager, not NixOS) installed on Arch host and inside every VM
- Single shared flake repo (e.g., `github:user/devenv`) with layered profiles:
  - `common` — fish shell, nix-your-shell, neovim, tmux, git, ripgrep, fd, jq, curl, all CLI tools (shared by host and VMs, ~80% of packages)
  - `host` — Sway-specific tools, browser, fonts, notification daemon, Incus client, anything needing a display
  - `vm-base` — headless Chromium, Playwright, build essentials, things only VMs need
  - `vm-work` — extends vm-base with corporate-specific tooling
  - `vm-personal` — extends vm-base with personal tooling if needed
- Host runs `nix profile install .#host` (gets common + host layers)
- VMs run `nix profile install .#vm-work` or `.#vm-personal` (gets common + vm layers)
- Single lockfile pins all versions — host and VMs guaranteed to be on same versions of shared tools, zero drift
- Updating a tool in common layer propagates to host and all VMs on next update

**Package manager responsibilities — what goes where:**
- Pacman (host only): linux kernel, systemd, sway, pipewire/audio, NetworkManager, graphics drivers, incus, base system — things tightly coupled to hardware/kernel
- apt/dnf/whatever (VMs only): minimal base OS packages the golden image needs
- Nix (host + VMs): everything userspace — shell, editor, tmux, all CLI tools, language toolchains, dev utilities — anything you care about controlling the version of

**Nix for developer toolchains (frequent changes):**
- Go, Node, Python, Rust, CLI tools, dev utilities — all managed by Nix via the shared flake
- Nix flake repo lives on the host — host is always the source of truth
- On VM start/resume, wrapper compares a hash of the entire flake directory (flake.nix + flake.lock + any other flake files) on host vs inside VM (instant, no network)
- If identical → attach immediately, zero delay
- If different → push updated flake into VM via `incus file push`, then run `nix profile upgrade` inside VM via `incus exec` (VM pulls derivations from Nix binary cache over internet)
- This catches both input changes (new package versions via flake.lock) and profile changes (adding/removing tools in flake.nix)
- Routine updates (new Go version, new Node LTS) = update flake repo on host, all VMs converge on next start/resume
- No manual intervention, no scripts, no per-VM commands
- Host can auto-update on login or manually via same mechanism
- Project-level deps (node_modules, Go modules) reinstalled from lockfiles as part of rebuild

**Golden images for system-level config (rare changes):**
- VPN client, corporate certs, base OS config, system services — baked into versioned base images
- Images are semver-versioned
- Every image change is treated as a breaking change — no migration scripts, no in-place updates
- **On start/resume, if a newer image version exists:**
  - Wrapper pauses and notifies: "Image personal-v1.1.0 is available, VM is on personal-v1.0.0"
  - Warns about uncommitted/unpushed files: "If you have uncommitted work, start on the old image first and push before upgrading"
  - Prompts: continue on old image, or stop and rebuild on new image
  - If continue → VM starts normally on old image, no data loss
  - If rebuild → VM is destroyed, recreated from new image, repo re-cloned from metadata, Nix + lockfiles restore environment
- This avoids trapping VMs — user always has the choice to defer the upgrade
- Rebuild is deterministic and mostly automatic thanks to Nix + lockfiles
- Expected to be rare (system-level changes are infrequent)

**No migration scripts exist.** The concept is eliminated entirely. System change → new image, full rebuild. Toolchain change → push flake, automatic convergence.

**Per-project toolchain overrides (opt-in, rare):**
- 99% of projects use the global flake with no extra config
- If a project needs a different version (e.g., Node 18 instead of 22), drop a local Nix file (e.g., `.nix-local`) in the project directory
- Local Nix config takes precedence over the global flake for that project
- The override filename is added to Git's global ignore file (`~/.config/git/ignore`) — configured once in dotfiles, applies to all repos, never accidentally committed
- Global gitignore file is part of the dotfiles repo, symlinked by bootstrap
- **`.nix-local` is saved to project metadata on the host** — survives `vm rebuild` (use `vm secrets save` to pull it from the VM into metadata)

### Dependency Isolation: Full Duplication, No Sharing
- Each VM has its own node_modules, Go module cache, etc.
- No shared pnpm store or Go proxy across VMs
- Trades storage for security: a compromised agent in one VM cannot poison or inspect another project's dependencies
- On 2TB SSD this is acceptable even with hundreds of projects
- Dependencies install once per VM and persist (VMs are long-lived)

### Code Lives Inside VMs
- No source code on the host — host has no project directories
- Code, dependencies, build artifacts all inside the VM filesystem
- Eliminates path compatibility issues between host and VM
- Code is in git remotes for backup/sharing purposes
- Onboarding new project: `vm start myproject --repo git@github.com:user/myproject.git` — creates VM, clones repo, stores URL in project metadata
- Rebuilding: `vm rebuild myproject` — re-clones from the repo URL stored in metadata, no need to specify again

### Git Authentication
- Provider-agnostic — works with GitHub, GitLab, Bitbucket, self-hosted, anything supporting SSH
- Two auth strategies, chosen per project (defaults based on image type):

**`image-key` (default for work images):**
- SSH key baked into the golden image during image build
- Every VM from that image can access any repo the key has access to
- Zero onboarding friction — `vm start myproject --repo url` just clones, no key setup
- No per-project isolation between work repos (acceptable — same corporate identity)
- Work SSH key, org keys, etc. managed as part of the golden image definition

**`deploy-key` (default for personal images):**
- Per-repo SSH deploy key generated by `vm` CLI during project creation (`ssh-keygen`)
- Private key stored in project metadata on the host (host is trusted, never runs agents)
- `vm` CLI injects only that project's deploy key into the VM on creation/rebuild via `incus file push`
- Agent inside VM can only access the one repo that deploy key is scoped to
- Deploy keys don't expire — generate once, works forever, zero recurring maintenance
- Only manual step: adding the public key to the repo settings (printed by `vm` CLI during setup)
- On `vm rebuild`: deploy key already in metadata, re-injected automatically

- Auth strategy stored in project metadata, overridable per project
- Future optimization: API integration to automatically add deploy keys to repos (provider-specific, not needed for v1)

### Project Secrets Management
- Dev secrets (.env files, API keys, test credentials) stored in project metadata on the host
- Injected into VM on start/rebuild via `incus file push` — survives VM destruction
- `vm secrets save` — pulls secret files from inside the VM into host-side metadata (run after editing secrets in VM)
- `vm secrets inject` — pushes secrets from metadata into the VM (automatic on start/rebuild, manual if needed)
- Secret files are never in git — they exist only in host metadata and inside VMs
- **Policy: only dev secrets go into VMs.** Production credentials, prod database access, anything touching real data or real money never enters a VM. Prod access happens from the host browser or dedicated tools, not from agent-accessible dev environments
- Agents have full root in the VM and can read dev secrets — this is accepted since dev secrets have limited blast radius
- Host metadata could be encrypted at rest (age, sops, GPG) as a future improvement, not required for v1

## User Workflow

### Host Environment
- Arch Linux + Sway (Wayland compositor, i3-compatible config/keybindings)
- Ghostty terminal emulator (OSC52 support for VM clipboard, tabs for project switching)
- Fish shell (on host and inside VMs)
- Nix for all userspace tooling (neovim, tmux, git, CLI tools, etc.)
- Pacman only for system-level packages (kernel, systemd, sway, drivers, incus)
- Neovim as editor (runs inside VMs, not on host)
- Host browser for accessing web apps via VM hostnames
- No tmux on host — Ghostty tabs + Sway workspaces handle project switching

### Reproducible Host Setup
- Entire host environment reproducible from a dotfiles repo + bootstrap script
- Goal: install Arch → clone dotfiles → run bootstrap.sh → fully working system, zero manual steps after that
- All config is declarative files in the repo
- Incus preseed YAML and resolved DNS config must agree on bridge IP (both in same repo, easy to keep in sync)

## Bootstrap Process

The bootstrap script is the single entry point for turning a fresh Arch install into a fully working development environment. It runs once after the base Arch installation (which is manual: partitioning, pacstrap, bootloader, create user, enable networking — the standard `archinstall` or manual process).

### Prerequisites (done manually as part of Arch install — see companion installation guide)
- Arch base system installed and booting (btrfs root with subvolumes, snapper + snap-pac configured)
- Alpine recovery partition installed and bootable
- User account created with sudo access
- Internet connectivity working
- Git available (part of base or installed via pacman)

### Stage 1 — System Packages (pacman)
Responsibility: hardware-coupled and system-level software that Nix should not manage.
- linux kernel, linux-firmware, microcode
- systemd (already there from base)
- sway, swaylock, swayidle, swaybg
- pipewire, wireplumber (audio)
- NetworkManager or systemd-networkd
- Graphics drivers (mesa, vulkan, intel-media-driver for i7-1365U)
- incus
- zram-generator (compressed swap in RAM — no swap partition needed)
- base-devel (for AUR helper if needed)
- AUR helper (yay or paru) for packages not in official repos
- Minimal set — everything else comes from Nix

### Stage 2 — Nix Installation
Responsibility: install Nix the package manager on Arch.
- Install Nix via the official multi-user installer
- Enable flakes and nix-command in Nix config
- This is the foundation for all userspace tooling

### Stage 3 — Userspace Tooling (Nix)
Responsibility: all user-facing tools, editor, shell, CLI utilities.
- Clone the shared flake repo (e.g., `github:user/devenv`)
- Run `nix profile install .#host` — installs the host profile (common + host layers)
- This provides: Go (for building vm CLI), neovim, tmux, git, ripgrep, fd, jq, curl, fish shell, nix-your-shell, Ghostty terminal emulator, browser, fonts, and all other daily-use tools
- Single command, fully reproducible, version-pinned by the flake lockfile

### Stage 4 — Dotfile Symlinks & Build vm CLI
Responsibility: configuration for all tools installed in stages 1–3, plus building the vm CLI.
- Compile `vm` CLI from source: `cd ~/dotfiles/vm && go build -o ~/.local/bin/vm`
- Symlink config files from the dotfiles repo to their expected locations:
  - `~/.config/fish/config.fish` — fish shell config (includes Nix PATH integration)
  - `~/.config/ghostty/config` — Ghostty terminal config (OSC52 enabled)
  - `~/.config/sway/config` — Sway compositor config
  - `~/.config/tmux/tmux.conf` — tmux config
  - `~/.config/nvim/` — Neovim config
  - `/etc/systemd/resolved.conf.d/incus-dns.conf` — DNS forwarding for `.incus` zone (requires sudo)
  - `/etc/systemd/zram-generator.conf` — zram swap configuration (requires sudo)
  - `~/.config/git/ignore` — global gitignore (ignores `.nix-local` and other local-only files across all repos)
  - Any other tool configs
- Uses stow, a custom symlink script, or plain `ln -sf` calls

### Stage 5 — Incus Initialization
Responsibility: set up the VM infrastructure.
- Initialize Incus from a preseed YAML file (stored in dotfiles repo):
  - Create btrfs storage pool
  - Create managed bridge network (`incusbr0`) with subnet and DNS
  - Create default profiles with `security.port_isolation=true` on the NIC device (prevents VM-to-VM traffic)
  - Set default resource allocation templates
- Enable and start the Incus systemd service
- Bridge IP in preseed must match the IP in the resolved DNS config from stage 4

### Stage 6 — systemd Services
Responsibility: enable all services that need to run persistently.
- `systemctl enable --now incus`
- `systemctl enable --now systemd-resolved`
- `systemctl enable --now NetworkManager` (or systemd-networkd)
- `systemctl enable --now pipewire pipewire-pulse wireplumber`
- Any other services

### Stage 7 — Golden Image Build (optional, can be deferred)
Responsibility: build the initial base images for VMs.
- Run `vm image build personal` — creates the first personal base image
- Run `vm image build work` — creates the first work base image (if work VPN/certs are available)
- Can be deferred to later — only needed before creating the first VM

### Bootstrap Idempotency
- The script should be safe to run multiple times (idempotent)
- pacman installs skip already-installed packages
- Nix profile install is idempotent
- Symlinks overwrite existing links
- Incus init skips if already initialized
- Service enables are idempotent
- Running bootstrap again after a dotfiles update should apply any changes cleanly

### Distro Choice Rationale
- Arch over Debian: fresher packages, AUR for niche tools (Incus, Niri if explored later), Arch Wiki
- Arch over Ubuntu: no Canonical corporate decisions (snaps, telemetry)
- Arch over EndeavourOS/CachyOS: pure upstream Arch, no extra layers
- Sway over i3: Wayland benefits (security model, better scaling), near-identical config/keybindings to i3, minimal workflow disruption
- Sway over Hyprland: i3 familiarity preserved, more mature, less opinionated
- Niri (infinite horizontal scroll) considered for future exploration but deferred to avoid too many changes at once

### Project Switching via Ghostty Tabs + Sway
- No tmux on the host — Ghostty tabs replace host-level session management
- Each project is a Ghostty tab running `incus exec project -- tmux new-session -A -s main`
- All project tabs on a single Sway workspace — switch between projects via Ghostty tab switching
- **tmux runs inside every VM — required for processes to survive hibernate/resume cycles**
  - Without tmux inside the VM, `incus exec` PTY is torn down on hibernate, killing all attached processes (dev servers, etc.)
  - On first start: creates a new tmux session inside the VM
  - On resume: re-attaches to the existing tmux session — dev server, agents, everything still running
  - Also used as regular tmux inside VM: create windows and panes for coding, logs, agents, etc.
- No tmux-inside-tmux conflict — only one tmux layer exists (inside the VM)
- `vm start` opens a new Ghostty tab connected to the VM's tmux (or attaches to existing)
- `vm stop` hibernates the VM, tab closes
- Switching projects = switching Ghostty tabs

### Agent Workflow
- AI coding agents (Claude Code, etc.) run inside the VM
- Agent has full permissions inside VM (can install packages, modify system, run as root)
- Agent uses headless browser for web app testing
- Agent's blast radius is limited to one disposable/restorable VM
- Interactive/conversational usage: agent is another terminal pane in tmux session
- If agent breaks something badly: destroy VM, recreate from base image + nix rebuild

### Network Isolation
- Each VM has its own network namespace and IP
- Multiple projects can all use port 3000 simultaneously without conflict
- Host accesses each via distinct hostname (e.g., `project-a.incus:3000`, `project-b.incus:3000`)
- Incus managed bridge (e.g., `incusbr0`) with built-in dnsmasq for DHCP + DNS
- VMs get private IPs (e.g., 10.x.x.x), outbound traffic NAT'd through host
- **VM-to-VM traffic blocked** via `security.port_isolation=true` on the default Incus NIC profile — kernel-level bridge port isolation prevents VMs from reaching each other, only host-to-VM and VM-to-internet are allowed. Set once in the Incus preseed YAML, applies to all VMs automatically.
- Host DNS resolution via systemd-resolved forwarding `.incus` zone to Incus's dnsmasq on the bridge IP
- One-time config: drop-in file in `/etc/systemd/resolved.conf.d/` — no manual IP management, no /etc/hosts hacking
- New VMs immediately resolvable by name, destroyed VMs disappear automatically

## Wrapper CLI: `vm`

### Implementation
- Written in Go — single compiled binary, no runtime dependencies
- Source lives in the dotfiles repo (e.g., `dotfiles/vm/`)
- Compiled binary placed at `~/.local/bin/vm`
- Uses cobra for subcommands, stdlib for subprocess/JSON/file IO
- Go comes from Nix (part of the host flake profile) — no pacman Go needed
- Bootstrap Stage 3 installs Go via Nix, Stage 4 compiles `vm` from source
- Re-running bootstrap recompiles `vm` to pick up any changes

### Pluggable Runner Architecture
- `vm` is not tied to Incus — Incus is the first "runner" (backend), but the design supports others
- Future runners could include: DigitalOcean, Hetzner, AWS, or any SSH-accessible VM provider
- Commands stay the same from the user's perspective (`vm start`, `vm stop`, etc.)
- Behavior differs per runner:
  - Incus: local VMs, hibernate/resume, local Nix sync
  - Cloud runner: remote VMs, no hibernation (just SSH), possibly snapshot-based stop/start, no local Nix store copy
- Runner-specific logic is isolated behind a common interface (create, start, stop, destroy, exec, etc.)

### Project Metadata
- Each project has metadata tracked by `vm` (stored locally, e.g., `~/.config/vm/projects/`)
- Metadata per project:
  - Project name
  - Runner type (e.g., `incus`, `digitalocean`)
  - Runner-specific details (Incus instance name, or droplet ID + IP, etc.)
  - Base image name + version the VM was created from
  - Git repo URL (for onboarding / rebuild)
  - Git auth strategy (`image-key` or `deploy-key`, defaults based on image type)
  - SSH deploy key pair (only for `deploy-key` strategy)
  - Project secrets (`.env` files, API keys, etc. — stored on host, injected into VM)
  - Local Nix override (`.nix-local` file, if project uses a per-project toolchain override — stored on host, injected into VM, survives rebuild)
  - Any project-specific overrides (RAM, image type, etc.)
- Metadata lives outside the VM — survives VM destruction and rebuild

### Commands
- `vm start [project]` — create or resume VM for a project, attach shell
  - If no VM exists → create from latest image, set up git auth, push dotfiles, inject secrets, clone repo, run Nix install, attach
  - If VM is hibernated → resume, check for newer image (prompt if available), compare Nix lockfile hashes and sync if needed, sync dotfiles if changed, attach
  - If VM is running → attach
- `vm start [project] --repo [url]` — create new VM and clone the given repo (stores URL in metadata for future rebuilds)
- `vm stop [project]` — hibernate the VM (stateful stop for Incus, runner-specific for others)
- `vm destroy [project]` — full teardown (metadata preserved for easy rebuild)
- `vm rebuild [project]` — destroy + recreate from latest image, re-clone repo, inject secrets + `.nix-local`, run Nix install
- `vm secrets save [project]` — pull secret files and `.nix-local` from VM into host-side metadata
- `vm list` — show all projects with VM status, runner, and image version
- `vm sleep` — hibernate ALL running VMs, then suspend the laptop (`systemctl suspend`)
- `vm image build [name] [version]` — build a new base image version
- `vm image list` — show available base images with versions
- Automatic Incus profile selection based on project needs

### Golden Image Build Process
- Built via `vm image build personal v1.0.0` (or `work v1.0.0`)
- vm handles the full lifecycle:
  1. Launch a temporary VM from a stock cloud image (e.g., `images:debian/12`)
  2. Push and execute a setup script inside the VM (install Nix, configure user, install Incus agent, set up basics)
  3. For "work" images: additionally install VPN client, corporate certs, etc.
  4. Write image version marker to `/etc/vm-image-version`
  5. Stop the temporary VM
  6. Publish as Incus image with alias (e.g., `personal-v1.0.0`)
  7. Delete the temporary VM
- New image is immediately available; existing VMs are prompted interactively on next start/resume
- Setup scripts live in the dotfiles repo alongside vm (e.g., `dotfiles/vm/images/personal-setup.sh`, `dotfiles/vm/images/work-setup.sh`)
- Reproducible: running the same build command produces the same image
- No external tooling (no Packer, no distrobuilder) — just vm + Incus CLI + bash setup scripts

### PATH & Shell Integration
- Shell: fish (on both host and VMs, configured via dotfiles)
- Nix PATH priority handled by Nix's official fish integration — one `source` line in `~/.config/fish/config.fish`
- Nix paths prepended to PATH, so Nix binaries always take priority over system packages (`/usr/bin`)
- `nix-your-shell` installed via Nix so that `nix develop` drops into fish instead of bash (needed for per-project overrides)
- Fish config lives in dotfiles — symlinked on host by bootstrap, pushed into VMs by `vm` wrapper on start/resume

### Clipboard: OSC52 via Ghostty
- Neovim runs inside VMs (headless, no Wayland socket) — standard clipboard (`"+y`) won't work out of the box
- Solution: Neovim configured to use OSC52 escape sequences for clipboard operations (built-in support)
- OSC52 sends copied text as ANSI escape codes through the terminal stream — Ghostty intercepts and places it on the host Sway clipboard
- Works transparently over `incus exec`, tmux, SSH — any terminal connection
- Pasting into Neovim already works (terminal emulator translates host clipboard into keystrokes)
- Ghostty config and Neovim clipboard config both live in dotfiles

### Dotfiles Sync into VMs
- Dotfiles repo lives on the host — host is the source of truth (same as Nix flake)
- `vm` wrapper pushes relevant config files into VMs via `incus file push` on start/resume
- Synced configs: neovim, fish, tmux, git config, and any other tool configs used inside VMs
- Hash/timestamp comparison to skip sync if nothing changed (same pattern as Nix lockfile check)
- Changing a Neovim plugin, fish prompt, or tmux binding → next VM start/resume picks it up automatically
- On new VM creation: dotfiles pushed as part of initial setup
- Host-only configs (sway, ghostty, resolved) are NOT synced — only configs relevant inside VMs
- This is not a migration — just pushing personal config files, same as Nix toolchain sync

