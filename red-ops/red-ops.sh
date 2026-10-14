# shellcheck shell=bash
# ============================================================================
#  Kodak RED OPS  —  advanced ops layer for D4M13N
#  Maintained by Marcus Landon.  Sourced AFTER ~/.kodak/kodak.sh + kodak-ops.sh
#  (it reuses their _k_* helpers: colors, confirm, sudo, release, units).
#
#  Design rules:
#    * Never prints secret values (tokens compared/used, never echoed).
#    * Destructive ops (rollback, ban, unban, purge, deploy, DNS write, recursive chown)
#      confirm unless -y.
#    * Degrades cleanly with no TTY / NO_COLOR.
#    * Logs non-secret actions to ~/.kodak/red-ops.log (+ optional audit webhook).
#  Run `redops help` or `khelp` for the full surface.
# ============================================================================
[[ -n ${BASH_VERSION:-} ]] || return 0
declare -F _k_colors >/dev/null || { echo "red-ops: load ~/.kodak/kodak.sh first" >&2; return 0; }

: "${REDOPS_SRC:=$HOME/.kodak/repos}"
: "${REDOPS_REPOS_CONF:=$KODAK_HOME/repos.conf}"
: "${REDOPS_LOG:=$KODAK_HOME/red-ops.log}"
: "${REDOPS_CF_DIR:=$KODAK_HOME/cf-workers}"
: "${REDOPS_VENV_DIR:=$KODAK_HOME/venvs}"
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
# Edit freely. No secrets.
# kclone <tag> | kclone <https://github.com/owner/repo[.git]> | kclone owner/repo
# Auto-registers new HTTPS/owner/repo clones into this file.
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
_ro_repo_by_slug() {   # find line where field2 == owner/repo
  _ro_seed_repos
  awk -F'|' -v s="$1" '!/^#/ && NF>=3 && $2==s {print; exit}' "$REDOPS_REPOS_CONF"
}
_ro_repo_path() {   # resolve ~ in field 3
  local p=$1; p=${p/#\~/$HOME}; printf '%s' "$p"
}

# Parse GitHub URL / owner/repo / tag-like into owner/repo.
# Sets: _ro_gh_owner _ro_gh_name _ro_gh_slug  (empty if not parseable as github)
_ro_parse_github() {
  local arg=$1
  _ro_gh_owner=; _ro_gh_name=; _ro_gh_slug=
  arg=${arg%%#*}; arg=${arg%%\?*}; arg=${arg%/}
  # https://github.com/owner/repo[.git]  or  http://...  or  git@github.com:owner/repo.git
  if [[ $arg =~ ^(https?://)?(www\.)?github\.com/([^/]+)/([^/]+) ]]; then
    _ro_gh_owner=${BASH_REMATCH[3]}
    _ro_gh_name=${BASH_REMATCH[4]}
  elif [[ $arg =~ ^git@github\.com:([^/]+)/([^/]+) ]]; then
    _ro_gh_owner=${BASH_REMATCH[1]}
    _ro_gh_name=${BASH_REMATCH[2]}
  elif [[ $arg =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]]; then
    _ro_gh_owner=${BASH_REMATCH[1]}
    _ro_gh_name=${BASH_REMATCH[2]}
  else
    return 1
  fi
  _ro_gh_name=${_ro_gh_name%.git}
  _ro_gh_slug="${_ro_gh_owner}/${_ro_gh_name}"
  return 0
}

# Pick a free registry tag from repo name; on collision use owner-repo slug.
_ro_unique_tag() {
  local base=$1 owner=$2
  base=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')
  [[ -n $base ]] || base=repo
  if [[ -z $(_ro_repo_line "$base") ]]; then printf '%s' "$base"; return 0; fi
  local alt
  alt=$(printf '%s-%s' "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')" "$base")
  if [[ -z $(_ro_repo_line "$alt") ]]; then printf '%s' "$alt"; return 0; fi
  local n=2
  while [[ -n $(_ro_repo_line "${alt}-${n}") ]]; do n=$((n+1)); done
  printf '%s' "${alt}-${n}"
}

# Append a registry line if slug not already present. Echoes the tag used.
_ro_register_repo() {
  local tag=$1 slug=$2 path=$3 desc=${4:-cloned}
  _ro_seed_repos
  local existing
  existing=$(_ro_repo_by_slug "$slug")
  if [[ -n $existing ]]; then
    IFS='|' read -r tag _ _ _ <<<"$existing"
    printf '%s' "$tag"
    return 0
  fi
  # keep path tilde-friendly in conf when under $HOME
  local store=$path
  [[ $store == "$HOME"/* ]] && store="~${store#"$HOME"}"
  printf '%s|%s|%s|%s\n' "$tag" "$slug" "$store" "$desc" >> "$REDOPS_REPOS_CONF"
  printf '%s' "$tag"
}

krepos() {   # list registered repos with tags + local presence
  _ro_seed_repos; _k_colors
  _k_title "Red Ops repo registry  ($REDOPS_REPOS_CONF)"
  printf '  %s%-12s %-34s %-10s %s%s\n' "$_kD" TAG REPO LOCAL TAGS "$_k0"
  local tag repo path tags lp mark
  while IFS='|' read -r tag repo path tags; do
    [[ $tag == \#* || -z $tag ]] && continue
    lp=$(_ro_repo_path "$path")
    if [[ -d $lp/.git ]]; then mark="${_kG}✓ cloned${_k0}"; else mark="${_kY}– missing${_k0}"; fi
    printf '  %s%-12s%s %-34s %b %s\n' "$_kC" "$tag" "$_k0" "$repo" "$mark" "$tags"
  done < "$REDOPS_REPOS_CONF"
  printf '\n  %skclone <tag|HTTPS|owner/repo>%s · %skpull <tag|all>%s · %skcd <tag>%s · %skchain <cmd…>%s\n\n' \
    "$_kC" "$_k0" "$_kC" "$_k0" "$_kC" "$_k0" "$_kC" "$_k0"
}

kclone() {   # kclone <tag|https://github.com/o/r[.git]|owner/repo>
  (( $# >= 1 )) || {
    echo "usage: kclone <tag>"
    echo "       kclone <https://github.com/owner/repo[.git]>"
    echo "       kclone <owner/repo>"
    krepos; return 1
  }
  _ro_need git "clone repos" || return 1
  local arg=$1 line repo path tag slug
  # 1) registered tag wins
  line=$(_ro_repo_line "$arg")
  if [[ -n $line ]]; then
    IFS='|' read -r tag repo path _ <<<"$line"
    path=$(_ro_repo_path "$path")
  elif _ro_parse_github "$arg"; then
    slug=$_ro_gh_slug
    line=$(_ro_repo_by_slug "$slug")
    if [[ -n $line ]]; then
      IFS='|' read -r tag repo path _ <<<"$line"
      path=$(_ro_repo_path "$path")
    else
      tag=$(_ro_unique_tag "$_ro_gh_name" "$_ro_gh_owner")
      path="$REDOPS_SRC/${_ro_gh_name}"
      mkdir -p "$REDOPS_SRC"
      tag=$(_ro_register_repo "$tag" "$slug" "$path" "user")
      repo=$slug
      _k_ok "registered tag '$tag' → $slug"
    fi
  else
    _k_err "not a registry tag or GitHub URL/owner/repo: $arg"
    echo "  try: kclone play   or   kclone https://github.com/owner/repo"
    return 1
  fi
  if [[ -d $path/.git ]]; then _k_ok "already cloned: $path  (tag: ${tag:-?})"; return 0; fi
  mkdir -p "$(dirname "$path")"
  _k_title "Clone $repo -> $path"
  if _k_has gh; then gh repo clone "$repo" "$path" || return 1
  else git clone "https://github.com/${repo}.git" "$path" || return 1; fi
  _ro_log "cloned $repo -> $path (tag=${tag:-})"
  _k_ok "done.  kcd ${tag:-$repo}   ·   krepos"
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

# ============================================================ PYTHON VENVS (simple)
kvenv() {
  local sub=${1:-help}; shift 2>/dev/null || true
  mkdir -p "$REDOPS_VENV_DIR"
  case $sub in
    help|"")
      cat <<'TXT'
  kvenv make <name>     create ~/.kodak/venvs/<name>
  kvenv list            list venvs
  kvenv use <name>      activate (in this shell)
  kvenv rm <name> [-y]  remove a venv
TXT
      ;;
    make|new|create)
      local name=${1:-}; [[ -n $name ]] || { echo "usage: kvenv make <name>"; return 1; }
      name=${name//[^a-zA-Z0-9_.-]/-}
      local dir="$REDOPS_VENV_DIR/$name"
      [[ -d $dir ]] && { _k_ok "exists: $dir"; echo "  kvenv use $name"; return 0; }
      _ro_need python3 "create venvs" || return 1
      python3 -m venv "$dir" || return 1
      _ro_log "kvenv make $name"; _k_ok "made $dir"; echo "  next: kvenv use $name"
      ;;
    list|ls)
      _k_title "venvs in $REDOPS_VENV_DIR"
      local d; shopt -s nullglob
      for d in "$REDOPS_VENV_DIR"/*/; do
        printf '  %s\n' "$(basename "$d")"
      done
      shopt -u nullglob
      [[ -n ${VIRTUAL_ENV:-} ]] && printf '  (active: %s)\n' "$VIRTUAL_ENV"
      ;;
    use|on|activate)
      local name=${1:-}; [[ -n $name ]] || { echo "usage: kvenv use <name>"; return 1; }
      local act="$REDOPS_VENV_DIR/$name/bin/activate"
      [[ -f $act ]] || { _k_err "no venv: $name  (kvenv make $name)"; return 1; }
      # shellcheck disable=SC1090
      source "$act"
      _k_ok "using $name  ($VIRTUAL_ENV)"
      ;;
    rm|remove|del)
      local name=${1:-}; shift 2>/dev/null || true
      [[ -n $name ]] || { echo "usage: kvenv rm <name> [-y]"; return 1; }
      local dir="$REDOPS_VENV_DIR/$name"
      [[ -d $dir ]] || { _k_warn "no such venv: $name"; return 1; }
      _ro_ask "Remove venv $dir ?" "$@" || { echo "Cancelled."; return 1; }
      rm -rf "$dir"
      _ro_log "kvenv rm $name"; _k_ok "removed $name"
      ;;
    *) echo "unknown: kvenv $sub"; kvenv help; return 1 ;;
  esac
}

# ============================================================ JSON + IP HELPERS
kjson() {   # pretty-print or query JSON (stdin or file). Needs jq.
  _ro_need jq "kjson" || return 1
  if [[ $# -eq 0 || $1 == - ]]; then
    jq .
  elif [[ -f $1 ]]; then
    local f=$1; shift
    if (( $# )); then jq "$@" "$f"; else jq . "$f"; fi
  else
    # treat args as jq filter, read stdin
    jq "$@"
  fi
}
kipme() {   # show my public + local IPs (no secrets)
  _k_title "My IPs"
  local pub
  pub=$(curl -fsS --max-time 5 https://ifconfig.me/ip 2>/dev/null \
     || curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
     || echo "(offline)")
  printf '  public   %s\n' "$pub"
  local a
  while read -r a; do printf '  local    %s\n' "$a"; done < <(hostname -I 2>/dev/null | tr ' ' '\n' | sed '/^$/d')
  if _k_has tailscale; then
    local tip; tip=$(tailscale ip -4 2>/dev/null || true)
    [[ -n $tip ]] && printf '  tailscale %s\n' "$tip"
  fi
}

# ============================================================ DNS CHECK / FIX / UPDATE
# Expected Kodak hostnames (CNAME/tunnel-facing). No secrets.
_ro_dns_hosts() {
  cat <<'H'
play.kodakgp.com
ssh.kodakgp.com
www.kodakgp.com
kodakgp.com
agents.kodakgp.com
H
}
_ro_cf_token() {
  # never print value
  if [[ -n ${CLOUDFLARE_API_TOKEN:-} ]]; then return 0; fi
  if [[ -n ${CF_API_TOKEN:-} ]]; then return 0; fi
  return 1
}
_ro_cf_token_val() {
  if [[ -n ${CLOUDFLARE_API_TOKEN:-} ]]; then printf '%s' "$CLOUDFLARE_API_TOKEN"; return 0; fi
  if [[ -n ${CF_API_TOKEN:-} ]]; then printf '%s' "$CF_API_TOKEN"; return 0; fi
  return 1
}
kdns() {
  local sub=${1:-help}; shift 2>/dev/null || true
  case $sub in
    help|"")
      cat <<'TXT'
  kdns check              resolve key Kodak hostnames (A/AAAA/CNAME + TTL)
  kdns fix                local-only fixes (resolver cache, cloudflared status)
  kdns update […] [-y]    Cloudflare DNS write — dry-run by default; needs token + confirm
  Standing rule: ask before DNS changes. Secrets never printed.
TXT
      ;;
    check)
      _k_title "DNS check (Kodak hosts)"
      local h rec
      while read -r h; do
        [[ -z $h ]] && continue
        printf '  %s%s%s\n' "$_kC" "$h" "$_k0"
        if _k_has dig; then
          rec=$(dig +noall +answer "$h" A "$h" AAAA "$h" CNAME 2>/dev/null | sed 's/^/    /')
          [[ -n $rec ]] && printf '%s\n' "$rec" || printf '    (no answer)\n'
        elif _k_has getent; then
          getent ahosts "$h" 2>/dev/null | head -5 | sed 's/^/    /' || printf '    (no answer)\n'
        else
          # bash /dev/tcp won't give CNAME; use python
          python3 - "$h" <<'PY' 2>/dev/null | sed 's/^/    /' || printf '    (no resolver tool)\n'
import socket,sys
h=sys.argv[1]
try:
  for fam,_,_,_,sa in socket.getaddrinfo(h, None):
    print(("AAAA" if fam==socket.AF_INET6 else "A"), sa[0])
except Exception as e:
  print("err", e)
PY
        fi
        # quick HTTPS probe (non-fatal)
        code=$(curl -fsS --max-time 4 -o /dev/null -w '%{http_code}' "https://$h/" 2>/dev/null || echo "fail")
        printf '    https   %s\n' "$code"
      done < <(_ro_dns_hosts)
      ;;
    fix)
      _k_title "DNS fix (local only — no Cloudflare writes)"
      # flush local caches where available
      if _k_has resolvectl; then
        _k_sudo resolvectl flush-caches 2>/dev/null && _k_ok "flushed systemd-resolved cache" || _k_warn "could not flush resolved"
      elif _k_has systemd-resolve; then
        _k_sudo systemd-resolve --flush-caches 2>/dev/null && _k_ok "flushed cache" || true
      else
        _k_warn "no resolvectl; skip cache flush"
      fi
      if _k_has cloudflared; then
        cloudflared --version 2>&1 | head -1 | sed 's/^/  /'
        _k_sudo systemctl is-active "$KODAK_UNIT_TUNNEL" "$KODAK_UNIT_SSH_TUNNEL" 2>/dev/null | sed 's/^/  unit /'
      else
        _k_warn "cloudflared not installed"
      fi
      _k_ok "local checks done. For CF record changes use: kdns update (dry-run) then -y after confirm."
      _ro_log "kdns fix (local)"
      ;;
    update)
      # dry-run by default. Real write needs token + -y/confirm.
      if ! _ro_cf_token; then
        _k_err "No Cloudflare API token. Export CLOUDFLARE_API_TOKEN (DNS:Edit) in ~/.kodak/secrets.env — never paste into chat."
        return 1
      fi
      local rest=("$@")
      _k_title "DNS update (Cloudflare) — DRY RUN unless -y"
      printf '  planned: would call Cloudflare DNS API with token present (value not shown)\n'
      printf '  args: %s\n' "${rest[*]:-(none — pass zone/record details when ready)}"
      printf '  standing rule: ask owner before DNS changes.\n'
      if ! _ro_yes "${rest[@]}"; then
        _k_warn "dry-run only. Re-run with -y after owner approval to apply."
        return 0
      fi
      _ro_ask "Apply Cloudflare DNS change now?" "${rest[@]}" || { echo "Cancelled."; return 1; }
      _k_err "No concrete record payload given. Pass zone + record via future kdns update args after owner names the change."
      _ro_log "kdns update attempted (blocked: no payload)"
      return 1
      ;;
    *) echo "unknown: kdns $sub"; kdns help; return 1 ;;
  esac
}

# ============================================================ OWNERSHIP / PERMS
kown() {
  local path=${1:-} ug=${2:-}
  if [[ $path == fix || $path == kodak ]]; then kfix kodak "${@:2}"; return; fi
  [[ -n $path ]] || { echo "usage: kown <path> [user:group]   or  kown fix"; return 1; }
  [[ -e $path ]] || { _k_err "missing: $path"; return 1; }
  if [[ -z $ug ]]; then
    ug="${USER}:$(id -gn 2>/dev/null || echo "$USER")"
    # prefer blitzedbella when that user exists
    if id blitzedbella >/dev/null 2>&1; then ug="blitzedbella:blitzedbella"; fi
  fi
  if [[ -d $path ]]; then
    _ro_ask "Recursive chown -R $ug on $path ?" "${@:3}" || { echo "Cancelled."; return 1; }
    _k_sudo chown -R "$ug" "$path" || return 1
  else
    _k_sudo chown "$ug" "$path" || return 1
  fi
  _ro_log "kown $ug $path"; _k_ok "owner → $ug  $path"
}
kperm() {
  local path=${1:-} mode=${2:-}
  [[ -n $path && -n $mode ]] || { echo "usage: kperm <path> <mode>   e.g. kperm ~/.kodak 750"; return 1; }
  [[ -e $path ]] || { _k_err "missing: $path"; return 1; }
  if [[ -d $path ]]; then
    _ro_ask "chmod -R $mode on $path ?" "${@:3}" || { echo "Cancelled."; return 1; }
    _k_sudo chmod -R "$mode" "$path" || return 1
  else
    _k_sudo chmod "$mode" "$path" || return 1
  fi
  _ro_log "kperm $mode $path"; _k_ok "mode → $mode  $path"
}
kfix() {
  local what=${1:-kodak}; shift 2>/dev/null || true
  case $what in
    kodak|own)
      _k_title "Fix Kodak ownership/modes (safe defaults)"
      local ug="blitzedbella:blitzedbella"
      id blitzedbella >/dev/null 2>&1 || ug="${USER}:$(id -gn)"
      local paths=(/opt/kodak-play /opt/kodak-discord-bot "$HOME/.kodak")
      local p
      for p in "${paths[@]}"; do
        [[ -e $p ]] || { _k_warn "skip missing $p"; continue; }
        printf '  %s → %s (dirs 750 / files keep)\n' "$p" "$ug"
      done
      _ro_ask "Apply chown/chmod on the paths above?" "$@" || { echo "Cancelled."; return 1; }
      for p in "${paths[@]}"; do
        [[ -e $p ]] || continue
        _k_sudo chown -R "$ug" "$p" 2>/dev/null || _k_warn "chown failed: $p"
        if [[ -d $p ]]; then
          _k_sudo find "$p" -type d -exec chmod 750 {} + 2>/dev/null || true
        fi
      done
      # secrets tighter if present
      [[ -f $HOME/.kodak/secrets.env ]] && chmod 600 "$HOME/.kodak/secrets.env" 2>/dev/null || true
      _ro_log "kfix kodak"; _k_ok "kodak paths adjusted"
      ;;
    *) echo "usage: kfix kodak"; return 1 ;;
  esac
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
  Secrets are never printed. DNS is never changed here (use kdns).
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
kclone <tag|HTTPS|owner/repo>~clone + auto-register HTTPS/owner/repo into repos.conf
kcd <tag>~cd into a repo clone (falls back to play|gp|hq|vault)
kpull <tag|all>~git pull one repo or every cloned one
kchain [--tags a,b] <cmd…>~run a command across repos (filter by tag)
kchain-status~git status -s across prod/ops/cf repos
#Red Ops — Cloudflare / DNS
kcf workers|tunnels|list~list Workers / cloudflared tunnels / endpoints
kcf init|dev|deploy|tail <name>~scaffold/dev/deploy/tail an ops Worker
kdns check|fix|update~DNS resolve check / local fix / CF update (dry-run; -y to apply)
#Red Ops — env / files
kvenv make|list|use|rm <name>~simple Python venvs in ~/.kodak/venvs
kjson [file|filter]~pretty-print / query JSON (jq)
kipme~show public + local (+ tailscale) IPs
kown <path> [user:group]~chown (default blitzedbella); confirm if recursive
kperm <path> <mode>~chmod; confirm if recursive
kfix kodak~auto-adjust /opt/kodak-* + ~/.kodak owners/modes
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
      printf '  %s%-36s%s %s\n' "$_kC" "${row[0]}" "$_k0" "${row[1]}"
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
    dns)     kdns "${@:-check}" ;;
    rel)     krel ;;
    panic)   kpanic ;;
    menu|"")
      _ro_banner
      local PS3=$'\n'"redops> " c
      select c in "Status" "Deploy check" "Repos" "Cloudflare" "DNS check" "Release SHA" "Watch logs" "Panic snapshot" "Full help" "Quit"; do
        case $REPLY in
          1) kstatus;; 2) kdeploy-check;; 3) krepos;; 4) kcf list;; 5) kdns check;; 6) krel;;
          7) kwatch;; 8) kpanic;; 9) khelp;; *) break;;
        esac; break
      done ;;
    *) echo "redops: unknown '$sub'"; khelp; return 1;;
  esac
}

complete -W "help status repos cf dns rel panic menu" redops 2>/dev/null
complete -W "workers tunnels list init dev deploy tail help" kcf 2>/dev/null
complete -W "check fix update help" kdns 2>/dev/null
complete -W "make list use rm help" kvenv 2>/dev/null
_ro_complete_tags() { local c; COMPREPLY=(); local tags; tags=$(awk -F'|' '!/^#/&&NF>=3{print $1}' "$REDOPS_REPOS_CONF" 2>/dev/null); COMPREPLY=($(compgen -W "$tags all" -- "${COMP_WORDS[COMP_CWORD]}")); }
complete -F _ro_complete_tags kcd kclone kpull 2>/dev/null

_ro_seed_repos
