# shellcheck shell=bash
# ============================================================================
#  Kodak RED OPS  —  advanced ops layer for D4M13N
#  Maintained by Marcus Landon.  Sourced AFTER ~/.kodak/kodak.sh + kodak-ops.sh
#  (it reuses their _k_* helpers: colors, confirm, sudo, release, units).
#
#  Design rules:
#    * Never prints secret values (tokens compared/used, never echoed).
#    * Destructive ops (rollback, ban, unban, purge, deploy) confirm unless -y.
#    * Degrades cleanly with no TTY / NO_COLOR.
#    * Logs non-secret actions to ~/.kodak/red-ops.log (+ optional audit webhook).
#  Run `redops help` or `khelp` for the full surface.
# ============================================================================
[[ -n ${BASH_VERSION:-} ]] || return 0
declare -F _k_colors >/dev/null || { echo "red-ops: load ~/.kodak/kodak.sh first" >&2; return 0; }

: "${REDOPS_SRC:=$HOME/src}"
: "${REDOPS_REPOS_CONF:=$KODAK_HOME/repos.conf}"
: "${REDOPS_LOG:=$KODAK_HOME/red-ops.log}"
: "${REDOPS_CF_DIR:=$KODAK_HOME/cf-workers}"
: "${KODAK_GUILD_ID:=1520100176969072801}"
: "${KODAK_OWNER_ID:=1517795632763506752}"

# ---------------------------------------------------------------- small utils
_ro_yes()  { [[ " $* " == *" --yes "* || " $* " == *" -y "* ]]; }
_ro_ask()  { local q=$1; shift; _ro_yes "$@" && return 0; _k_confirm "$q"; }
_ro_ts()   { date +%Y-%m-%dT%H:%M:%S%z; }
_ro_log()  {   # _ro_log "action text (no secrets)"
  printf '%s  %s\n' "$(_ro_ts)" "$*" >> "$REDOPS_LOG" 2>/dev/null
  if [[ -n ${KODAK_AUDIT_WEBHOOK:-} ]]; then
    curl -fsS --max-time 4 -H 'Content-Type: application/json' \
      -d "$(printf '{"content":"🔴 redops: %s"}' "${*//\"/\\\"}")" \
      "$KODAK_AUDIT_WEBHOOK" >/dev/null 2>&1 || true
  fi
}
_ro_need() { _k_has "$1" || { _k_err "missing: $1 ($2)"; return 1; }; }

# ============================================================ GITHUB REPO REGISTRY
_ro_seed_repos() {   # write a default registry if none exists
  [[ -f $REDOPS_REPOS_CONF ]] && return 0
  cat > "$REDOPS_REPOS_CONF" <<'CONF'
# Kodak Red Ops repo registry  —  tag|owner/repo|local_path|tags/description
# Edit freely. No secrets. `krepos` lists, `kclone <tag>` clones into ~/src.
play|Ashes2Ashley/kodak-play|/opt/kodak-play|site,prod
bot|Ashes2Ashley/kodak-discord-bot|/opt/kodak-discord-bot|bot,prod
hq|Ashes2Ashley/kodakhq|~/kodakhq|hq,pm,cf
gp|Ashes2Ashley/kodakgp|~/kodakgp|site,cf,marketplace
ssh|Ashes2Ashley/d4m13n-ssh|~/d4m13n-ssh|infra,tunnel
intel|Ashes2Ashley/redops-intel|~/redops-intel|ops,cf,dashboard
redops|Ashes2Ashley/redops-framework|~/src/redops-framework|ops,recon,python
osint|Ashes2Ashley/agency-osint-dashboard|~/agency-osint-dashboard|ops,cf,dashboard
assess|Ashes2Ashley/authorized-assessment-gui|~/src/authorized-assessment-gui|ops,governance
originip|Ashes2Ashley/originiphunter|~/src/originiphunter|ops,infra,go
freebands|Ashes2Ashley/freebands|~/freebands|cf,marketplace
CONF
}
_ro_repo_line() {   # _ro_repo_line <tag> -> matching conf line (exact tag)
  _ro_seed_repos
  awk -F'|' -v t="$1" '!/^#/ && NF>=3 && $1==t {print; exit}' "$REDOPS_REPOS_CONF"
}
_ro_repo_path() {   # resolve ~ in field 3
  local p=$1; p=${p/#\~/$HOME}; printf '%s' "$p"
}
krepos() {   # list registered repos with tags + local presence
  _ro_seed_repos; _k_colors
  _k_title "Red Ops repo registry  ($REDOPS_REPOS_CONF)"
  printf '  %s%-10s %-34s %-10s %s%s\n' "$_kD" TAG REPO LOCAL TAGS "$_k0"
  local tag repo path tags lp mark
  while IFS='|' read -r tag repo path tags; do
    [[ $tag == \#* || -z $tag ]] && continue
    lp=$(_ro_repo_path "$path")
    if [[ -d $lp/.git ]]; then mark="${_kG}✓ cloned${_k0}"; else mark="${_kY}– missing${_k0}"; fi
    printf '  %s%-10s%s %-34s %b %s\n' "$_kC" "$tag" "$_k0" "$repo" "$mark" "$tags"
  done < "$REDOPS_REPOS_CONF"
  printf '\n  %skclone <tag>%s · %skpull <tag|all>%s · %skcd <tag>%s · %skchain <cmd…>%s\n\n' \
    "$_kC" "$_k0" "$_kC" "$_k0" "$_kC" "$_k0" "$_kC" "$_k0"
}
kclone() {   # kclone <tag|owner/repo>
  (( $# >= 1 )) || { echo "usage: kclone <tag|owner/repo> [--yes]"; krepos; return 1; }
  _ro_need git "clone repos" || return 1
  local arg=$1 line repo path
  line=$(_ro_repo_line "$arg")
  if [[ -n $line ]]; then
    IFS='|' read -r _ repo path _ <<<"$line"; path=$(_ro_repo_path "$path")
  else
    repo=$arg; path="$REDOPS_SRC/${arg##*/}"
  fi
  if [[ -d $path/.git ]]; then _k_ok "already cloned: $path"; return 0; fi
  mkdir -p "$(dirname "$path")"
  _k_title "Clone $repo -> $path"
  if _k_has gh; then gh repo clone "$repo" "$path" || return 1
  else git clone "https://github.com/$repo.git" "$path" || return 1; fi
  _ro_log "cloned $repo -> $path"; _k_ok "done."
}
kpull() {   # kpull <tag|all>
  (( $# >= 1 )) || { echo "usage: kpull <tag|all>"; return 1; }
  _ro_seed_repos
  local target=$1 tag repo path lp
  while IFS='|' read -r tag repo path _; do
    [[ $tag == \#* || -z $tag ]] && continue
    [[ $target != all && $target != "$tag" ]] && continue
    lp=$(_ro_repo_path "$path")
    [[ -d $lp/.git ]] || { _k_warn "skip $tag (not cloned)"; continue; }
    _k_title "pull $tag ($repo)"
    git -C "$lp" pull --ff-only 2>&1 | sed 's/^/  /'
  done < "$REDOPS_REPOS_CONF"
  _ro_log "kpull $target"
}
kchain() {   # kchain [--tags t1,t2] <cmd...>  : run cmd in each repo dir (or tag-filtered)
  (( $# >= 1 )) || { echo "usage: kchain [--tags a,b] <cmd...>   e.g. kchain git status -s"; return 1; }
  _ro_seed_repos
  local filter="" tag repo path lp
  if [[ $1 == --tags ]]; then filter=$2; shift 2; fi
  while IFS='|' read -r tag repo path tags; do
    [[ $tag == \#* || -z $tag ]] && continue
    lp=$(_ro_repo_path "$path"); [[ -d $lp/.git ]] || continue
    if [[ -n $filter ]]; then
      local hit=0 f; for f in ${filter//,/ }; do [[ ",$tags," == *",$f,"* ]] && hit=1; done
      (( hit )) || continue
    fi
    _k_title "[$tag] $lp"
    ( cd "$lp" && "$@" 2>&1 | sed 's/^/  /' )
  done < "$REDOPS_REPOS_CONF"
}
# chain presets -------------------------------------------------------------
kchain-status() { _k_title "== ops repo status =="; kchain --tags prod,ops,cf git status -s -b; }
kchain-pull()   { kpull all; }

# override kcd: tag -> repo dir, else fall back to original kcd ---------------
if declare -F kcd >/dev/null && ! declare -F _ro_kcd_base >/dev/null; then
  eval "$(declare -f kcd | sed '1s/^kcd/_ro_kcd_base/')"
fi
kcd() {
  local line path
  line=$(_ro_repo_line "${1:-}")
  if [[ -n $line ]]; then
    IFS='|' read -r _ _ path _ <<<"$line"; path=$(_ro_repo_path "$path")
    [[ -d $path ]] && { cd "$path" || return 1; pwd; return 0; }
    _k_warn "$1 not cloned; try: kclone $1"; return 1
  fi
  if declare -F _ro_kcd_base >/dev/null; then _ro_kcd_base "$@"; else
    echo "usage: kcd <tag>  (krepos to list)  or play|gp|hq|vault"; krepos; fi
}

# ============================================================ CLOUDFLARE OPS
_ro_wrangler() { if _k_has wrangler; then wrangler "$@"; else npx --yes wrangler "$@"; fi; }
_ro_cf_auth() {   # 0 if wrangler/API usable, else explain
  if [[ -n ${CLOUDFLARE_API_TOKEN:-} || -n ${CF_API_TOKEN:-} ]]; then return 0; fi
  _ro_wrangler whoami >/dev/null 2>&1 && return 0
  _k_err "No Cloudflare auth. Run 'wrangler login', or export CLOUDFLARE_API_TOKEN (Workers+Cache scope)."
  _k_warn "Never paste a token into chat; set it in ~/.kodak/secrets.env (chmod 600)."
  return 1
}
kcf() {
  local sub=${1:-help}; shift 2>/dev/null || true
  case $sub in
    help|"")
      cat <<'TXT'
  kcf workers              list Cloudflare Workers (wrangler/API)
  kcf tunnels             list cloudflared tunnels + known Kodak tunnel status
  kcf list                workers + tunnels overview
  kcf init <name>         scaffold a new ops Worker under ~/.kodak/cf-workers/<name>
  kcf dev <name>          wrangler dev for that Worker
  kcf deploy <name> [-y]  wrangler deploy (confirms first)
  kcf tail <name>         live-tail a deployed Worker's logs
  Secrets are never printed. DNS is never changed here.
TXT
      ;;
    workers)
      _ro_cf_auth || return 1
      _k_title "Cloudflare Workers"
      _ro_wrangler deployments list 2>/dev/null | sed 's/^/  /' || \
      _ro_wrangler whoami 2>&1 | sed 's/^/  /'
      _k_warn "Tip: per-project 'kcf deploy <name>' / wrangler list inside each worker dir."
      ;;
    tunnels)
      _k_title "Cloudflared tunnels"
      if _k_has cloudflared; then cloudflared tunnel list 2>&1 | sed 's/^/  /'; else _k_warn "cloudflared not installed"; fi
      _k_title "Known Kodak endpoints"
      local e
      for e in play.kodakgp.com ssh.kodakgp.com; do
        if curl -fsS --max-time 4 -o /dev/null -w '%{http_code}' "https://$e" >/dev/null 2>&1; then
          printf '  %s%-22s up%s\n' "$_kG" "$e" "$_k0"
        else printf '  %s%-22s no https answer%s\n' "$_kY" "$e" "$_k0"; fi
      done
      _k_title "Local tunnel units"
      _k_sudo systemctl is-active "$KODAK_UNIT_TUNNEL" "$KODAK_UNIT_SSH_TUNNEL" 2>/dev/null | sed 's/^/  /'
      ;;
    list) kcf workers; kcf tunnels ;;
    init|make|makenit)
      local name=${1:-}; [[ -n $name ]] || { echo "usage: kcf init <name>"; return 1; }
      name=${name//[^a-zA-Z0-9_-]/-}
      local dir="$REDOPS_CF_DIR/$name"
      [[ -e $dir ]] && { _k_warn "exists: $dir"; return 1; }
      mkdir -p "$dir/src"
      cat > "$dir/wrangler.toml" <<TOML
name = "$name"
main = "src/index.js"
compatibility_date = "$(date +%Y-%m-%d)"
# routes/DNS intentionally left unset — add via dashboard or ask before changing DNS.
TOML
      cat > "$dir/src/index.js" <<'JS'
// Kodak ops worker — scaffolded by `kcf init`. Defensive/admin use only.
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname === "/healthz") return new Response("ok", { status: 200 });
    return new Response("kodak ops worker", { status: 200 });
  },
};
JS
      cat > "$dir/package.json" <<JSON
{ "name": "$name", "private": true, "scripts": { "dev": "wrangler dev", "deploy": "wrangler deploy" } }
JSON
      _ro_log "kcf init worker $name -> $dir"
      _k_ok "Scaffolded $dir"; echo "  next: kcf dev $name   then   kcf deploy $name"
      ;;
    dev)
      local name=${1:-}; local dir="$REDOPS_CF_DIR/$name"
      [[ -d $dir ]] || dir=$PWD
      ( cd "$dir" && _ro_wrangler dev ) ;;
    deploy)
      local name=${1:-}; shift 2>/dev/null || true
      local dir="$REDOPS_CF_DIR/$name"; [[ -d $dir ]] || dir=$PWD
      _ro_cf_auth || return 1
      _ro_ask "Deploy Cloudflare Worker from $dir?" "$@" || { echo "Cancelled."; return 1; }
      ( cd "$dir" && _ro_wrangler deploy ) && _ro_log "kcf deploy ${name:-$PWD}" ;;
    tail)
      local name=${1:-}; local dir="$REDOPS_CF_DIR/$name"; [[ -d $dir ]] || dir=$PWD
      ( cd "$dir" && _ro_wrangler tail ) ;;
    *) echo "unknown: kcf $sub"; kcf help; return 1 ;;
  esac
}

# ============================================================ EXTRA OPS HELPERS
krel() {   # show live release SHA quickly
  _k_title "Live release"
  local r; r=$(_k_release "${KODAK_PLAY_URL}" 2>/dev/null); printf '  local  %s\n' "${r:-unknown}"
  r=$(curl -fsS --max-time 5 https://play.kodakgp.com/ 2>/dev/null | grep -oiE 'data-release="[^"]+"|sha[: ][0-9a-f]{7}' | head -1)
  printf '  public %s\n' "${r:-(no marker exposed)}"
}
kwatch() {   # tail both site + bot logs together
  _k_title "watching site + bot (Ctrl-C to stop)"
  _k_sudo journalctl -u "$KODAK_UNIT_PLAY" -u "$KODAK_UNIT_BOT" -f --no-hostname 2>/dev/null
}
kpanic() {   # emergency snapshot: status dump + quick backup, no destructive action
  local out="$KODAK_HOME/logs/panic-$(date +%Y%m%d-%H%M%S).txt"
  mkdir -p "$KODAK_HOME/logs"
  _k_title "PANIC snapshot -> $out"
  { echo "== $(date) =="; echo "## kstatus"; kstatus; echo "## kdeploy-check"; kdeploy-check;
    echo "## disk"; df -h / 2>/dev/null; echo "## units";
    _k_sudo systemctl --failed 2>/dev/null; } &> "$out"
  _k_ok "snapshot: $out"
  _ro_log "kpanic snapshot $out"
  _k_warn "Review it, then: krestart all  /  krollback  if needed."
}

# ============================================================ HELP + MENU
_ro_help_rows() {
  cat <<'TABLE'
#Red Ops — repos
krepos~list registered GitHub repos + local clone status (~/.kodak/repos.conf)
kclone <tag|owner/repo>~clone a repo into its registered path (or ~/src)
kcd <tag>~cd into a repo clone (falls back to play|gp|hq|vault)
kpull <tag|all>~git pull one repo or every cloned one
kchain [--tags a,b] <cmd…>~run a command across repos (filter by tag)
kchain-status~git status -s across prod/ops/cf repos
#Red Ops — Cloudflare
kcf workers~list Cloudflare Workers (wrangler/API; clear error if no auth)
kcf tunnels~list cloudflared tunnels + play/ssh endpoint + local unit status
kcf init <name>~scaffold a new ops Worker (~/.kodak/cf-workers/<name>)
kcf dev|deploy|tail <name>~wrangler dev / deploy (confirms) / live tail
#Red Ops — fast ops
krel~show live release SHA (local + public)
kwatch~tail site + bot journald logs together
kpanic~emergency snapshot: status + deploy-check + failed units to a file
redops~interactive Red Ops menu (help|status|repos|cf|…)
TABLE
}
# extend the existing khelp (which already appends kodak-ops rows)
if declare -F khelp >/dev/null && ! declare -F _ro_khelp_base >/dev/null; then
  eval "$(declare -f khelp | sed '1s/^khelp/_ro_khelp_base/')"
  khelp() {
    _ro_khelp_base
    _k_colors
    local row
    while IFS='~' read -r -a row; do
      if [[ ${row[0]} == "#"* ]]; then printf '%s%s%s\n' "$_kR" "${row[0]#\#}" "$_k0"; continue; fi
      printf '  %s%-28s%s %s\n' "$_kC" "${row[0]}" "$_k0" "${row[1]}"
    done < <(_ro_help_rows)
    printf '\n%sRed Ops: ~/.kodak/red-ops.sh · registry: ~/.kodak/repos.conf · log: ~/.kodak/red-ops.log%s\n\n' "$_kD" "$_k0"
  }
fi

_ro_banner() {
  _k_colors
  printf '%s' "$_kR"
  cat <<'ART'
  ╦╔═╔═╗╔╦╗╔═╗╦╔═  ╦═╗╔═╗╔╦╗  ╔═╗╔═╗╔═╗
  ╠╩╗║ ║ ║║╠═╣╠╩╗  ╠╦╝║╣  ║║  ║ ║╠═╝╚═╗
  ╩ ╩╚═╝═╩╝╩ ╩╩ ╩  ╩╚═╚═╝═╩╝  ╚═╝╩  ╚═╝
ART
  printf '%s  defensive ops + admin · play.kodakgp.com%s\n' "$_kD" "$_k0"
}
redops() {
  local sub=${1:-menu}; shift 2>/dev/null || true
  case $sub in
    help)    khelp ;;
    status)  kstatus ;;
    repos)   krepos ;;
    cf)      kcf "${@:-list}" ;;
    rel)     krel ;;
    panic)   kpanic ;;
    menu|"")
      _ro_banner
      local PS3=$'\n'"redops> " c
      select c in "Status" "Deploy check" "Repos" "Cloudflare" "Release SHA" "Watch logs" "Panic snapshot" "Full help" "Quit"; do
        case $REPLY in
          1) kstatus;; 2) kdeploy-check;; 3) krepos;; 4) kcf list;; 5) krel;;
          6) kwatch;; 7) kpanic;; 8) khelp;; *) break;;
        esac; break
      done ;;
    *) echo "redops: unknown '$sub'"; khelp; return 1;;
  esac
}

complete -W "help status repos cf rel panic menu" redops 2>/dev/null
complete -W "workers tunnels list init dev deploy tail help" kcf 2>/dev/null
_ro_complete_tags() { local c; COMPREPLY=(); local tags; tags=$(awk -F'|' '!/^#/&&NF>=3{print $1}' "$REDOPS_REPOS_CONF" 2>/dev/null); COMPREPLY=($(compgen -W "$tags all" -- "${COMP_WORDS[COMP_CWORD]}")); }
complete -F _ro_complete_tags kcd kclone kpull 2>/dev/null

_ro_seed_repos
