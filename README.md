# cps — Claude Profile Switch

Switch between isolated Claude Code profiles in seconds.

Manage multiple Claude Code configurations — different accounts, skills, MCP servers, settings — and switch between them with a single command. Git-backed with optional encryption.

## Features

- **Full isolation** — each profile gets its own credentials, settings, skills, commands, agents, MCP config
- **Instant switching** — uses `CLAUDE_CONFIG_DIR` (official Claude Code env var), no file copying on switch
- **Per-terminal profiles** — run `work` in one terminal and `personal` in another
- **Git-backed** — every change auto-committed, rollback anytime
- **Encrypted credentials** — `age` encryption for `.credentials.json` in git
- **Shell integration** — auto-activates profile on shell start, tab completions included

## Install

```sh
git clone https://github.com/guibes/claude-profile-switch.git ~/.local/share/cps-bin
ln -sf ~/.local/share/cps-bin/bin/cps ~/.local/bin/cps
```

Or with the installer:

```sh
curl -fsSL https://raw.githubusercontent.com/guibes/claude-profile-switch/main/install.sh | bash
```

## Quick Start

```sh
# 1. Initialize — snapshots current config as 'default' profile
cps init

# 2. Add shell integration to your rc file
echo 'eval "$(cps shell-init)"' >> ~/.zshrc
source ~/.zshrc

# 3. Create profiles
cps create work
cps create personal --from default

# 4. Switch
cps use work
```

## Commands

### Profile Management

| Command | Description |
|---------|-------------|
| `cps init` | Initialize, snapshot current config as `default` |
| `cps init --key <path>` | Import age key on new machine |
| `cps create <name>` | Create profile from active profile |
| `cps create <name> --from <p>` | Create profile from another profile |
| `cps use <name>` | Switch to profile |
| `cps list` | List all profiles (active marked with `*`) |
| `cps current` | Print active profile name |
| `cps delete <name>` | Delete profile (cannot delete active) |

### Git Backup

| Command | Description |
|---------|-------------|
| `cps save [message]` | Commit current state |
| `cps log [profile]` | Show change history |
| `cps rollback <commit>` | Restore to previous state |
| `cps remote [url]` | Get/set git remote |
| `cps push` | Push to remote |
| `cps pull` | Pull from remote |

### Utility

| Command | Description |
|---------|-------------|
| `cps diff [p1] [p2]` | Compare profiles |
| `cps edit [name]` | Open profile in `$EDITOR` |
| `cps doctor` | Health check |
| `cps shell-init` | Output shell integration code |

## Shell Integration

### Oh My Zsh (recommended for zsh users)

```sh
# Symlink into custom plugins
ln -sf ~/.local/share/cps-bin/oh-my-zsh/cps ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/cps
```

Add `cps` to your plugins in `~/.zshrc`:

```sh
plugins=(... cps)
```

Includes: shell integration, completions, aliases (`cpsu`, `cpsl`, `cpsc`, `cpss`), and an opt-in prompt segment.

To show active profile in your prompt, add `CPS_PROMPT=1` and `$(cps_prompt_info)` to your `PROMPT` or `RPROMPT`:

```sh
export CPS_PROMPT=1
RPROMPT='$(cps_prompt_info)'
```

### Manual (bash or zsh without oh-my-zsh)

Add to `~/.zshrc` or `~/.bashrc`:

```sh
eval "$(cps shell-init)"
```

This does three things:
1. Reads your active profile on shell start
2. Exports `CLAUDE_CONFIG_DIR` pointing to the profile's config
3. Wraps `cps` so `cps use` updates `CLAUDE_CONFIG_DIR` in the current shell

### Tab Completions (without oh-my-zsh)

```sh
# Bash
source /path/to/cps/completions/cps.bash

# Zsh (add to fpath before compinit)
fpath=(/path/to/cps/completions $fpath)
```

## Encryption

If [age](https://github.com/FiloSottile/age) is installed during `cps init`, credentials are automatically encrypted in git using clean/smudge filters.

```sh
# Setup happens automatically on init
cps init

# On a new machine, import your age key
cps init --key ~/age-key.txt
```

**Back up your `age-key.txt`** — without it, encrypted credentials cannot be recovered.

The key is stored at `~/.local/share/cps/age-key.txt` and is gitignored.

## How It Works

### Storage Layout

```
~/.local/share/cps/          # Git repo
├── profiles/
│   ├── default/
│   │   ├── claude/           # ← CLAUDE_CONFIG_DIR points here
│   │   │   ├── .credentials.json
│   │   │   ├── config.json
│   │   │   ├── settings.json
│   │   │   ├── CLAUDE.md
│   │   │   ├── skills/
│   │   │   ├── commands/
│   │   │   └── agents/
│   │   └── claude.json       # ← swapped into ~/.claude.json
│   └── work/
│       ├── claude/
│       └── claude.json
├── active                    # Current profile name
├── age-key.txt               # Encryption key (gitignored)
└── age-recipient.txt         # Public key
```

### Switch Mechanism

`cps use <name>` does:

1. Saves current `~/.claude.json` back to the active profile
2. Auto-commits if anything changed
3. Copies target profile's `claude.json` → `~/.claude.json`
4. Updates the `active` file
5. Shell wrapper exports `CLAUDE_CONFIG_DIR` to the new profile's `claude/` dir

Claude Code reads `CLAUDE_CONFIG_DIR` on startup to locate its config directory. Combined with the `~/.claude.json` swap, this gives complete profile isolation.

## License

MIT
