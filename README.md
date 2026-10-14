# d4m13n-ssh

One-command permanent SSH tunnel setup for D4M13N (public key only, no secrets).

## Red Ops (`red-ops/`)

Advanced bash ops toolkit installed on the laptop as `~/.kodak/red-ops.sh` (sourced from `~/.kodak/kodak.sh`).

### Clone any GitHub repo (simple)

```bash
kclone play                                          # registered tag
kclone https://github.com/owner/repo.git             # HTTPS URL
kclone https://github.com/owner/repo                 # HTTPS without .git
kclone owner/repo                                    # short form
```

HTTPS / `owner/repo` clones land in `~/.kodak/repos/<repo-name>` and **auto-register** into `~/.kodak/repos.conf`, so they show up in `krepos` and work with `kcd` / `kpull` / `kchain` immediately.

### Other quick commands

| Cmd | Does |
|---|---|
| `krepos` | list registry + clone status |
| `kvenv make\|list\|use\|rm NAME` | simple Python venvs in `~/.kodak/venvs` |
| `kcf workers\|tunnels\|list` | Cloudflare Workers / tunnels |
| `kcf init\|dev\|deploy\|tail NAME` | ops Workers under `~/.kodak/cf-workers` |
| `kdns check\|fix\|update` | DNS check / local fix / CF update (dry-run; `-y` + token to apply) |
| `kjson` / `kipme` | JSON helper (jq) / show my IPs |
| `kown` / `kperm` / `kfix kodak` | ownership + modes helpers |
| `krel` / `kwatch` / `kpanic` / `redops` | release SHA / logs / snapshot / menu |

`khelp` lists everything. Never paste secrets into chat; put Cloudflare tokens in `~/.kodak/secrets.env` (chmod 600). Ask before DNS changes.
