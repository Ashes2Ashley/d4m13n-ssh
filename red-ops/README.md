# Kodak Red Ops toolkit

Advanced defensive-ops + admin bash layer for D4M13N. Loaded on top of
\`~/.kodak/kodak.sh\` (reuses its \`_k_*\` helpers).

## Install
\`\`\`bash
cp red-ops/red-ops.sh ~/.kodak/red-ops.sh
cp red-ops/repos.conf.example ~/.kodak/repos.conf   # edit freely, no secrets
# wired automatically from ~/.kodak/kodak.sh:
#   [[ -f \$KODAK_HOME/red-ops.sh ]] && . \"\$KODAK_HOME/red-ops.sh\"
\`\`\`

## Cheat sheet
- Repos:  \`krepos\` · \`kclone <tag>\` · \`kcd <tag>\` · \`kpull <tag|all>\` · \`kchain [--tags a,b] <cmd…>\`
- Cloudflare:  \`kcf workers|tunnels|list\` · \`kcf init|dev|deploy|tail <name>\`
- Fast ops:  \`krel\` · \`kwatch\` · \`kpanic\` · \`redops\` (menu) · \`khelp\` (full)
- Existing k* (status/deploy/ban/ssh toggles) unchanged.

Destructive ops confirm unless \`-y\`. Secrets are never printed. DNS is never changed here.
