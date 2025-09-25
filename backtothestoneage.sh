#!/usr/bin/env bash
# backtothestoneage.sh
# Usage:
#   sudo ./backtothestoneage.sh [--logs] [--disable-save] [--dry-run]
#
# Options:
#   --logs         : also truncate most files in /var/log (destructive)
#   --disable-save : append settings to /etc/profile to stop future history saves
#   --dry-run      : show what would be done, don't actually delete/truncate



set -euo pipefail

DRY_RUN=0
DO_DISABLE=0

# ---- arg parsing ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=1; shift ;;
    --disable)    DO_DISABLE=1; shift ;;
    -h|--help)
      cat <<'USAGE'
Usage:
  sudo nuke-hist-min.sh             # delete histories
  sudo nuke-hist-min.sh --dry-run   # preview deletions
  sudo nuke-hist-min.sh --disable   # delete + disable future history (bash, zsh, vim, nano)
USAGE
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] $*"
  else
    eval "$@"
  fi
}

echo "=== nuking CLI/Vim/Nano histories (dry-run=${DRY_RUN}, disable=${DO_DISABLE}) ==="

# Only process /home/* and /root
TARGET_HOMES=()
for d in /home/*; do [[ -d "$d" ]] && TARGET_HOMES+=("$d"); done
TARGET_HOMES+=("/root")

# Exact history files
HIST_FILES=(
  ".bash_history"
  ".zsh_history"
  ".fish_history"
  ".nano_history"
  ".viminfo"
  ".vim/viminfo"
)

# Vim swap globs
VIM_SWAP_GLOBS=( ".*.swp" "*.swp" ".*.swo" "*.swo" ".vimswap*" ".vi.swp" ".vimrc.swp" )

shopt -s nullglob dotglob
for HOME_DIR in "${TARGET_HOMES[@]}"; do
  [[ -d "$HOME_DIR" ]] || continue
  echo ">> $HOME_DIR"

  # Remove exact files
  for f in "${HIST_FILES[@]}"; do
    path="$HOME_DIR/$f"
    if [[ -e "$path" ]]; then
      echo "   removing: $path"
      run rm -f -- "$path"
    fi
  done

  # Remove vim swap files via globs inside this HOME only
  for gp in "${VIM_SWAP_GLOBS[@]}"; do
    for file in "$HOME_DIR"/$gp; do
      [[ -f "$file" ]] || continue
      echo "   removing: $file"
      run rm -f -- "$file"
    done
  done
done
shopt -u nullglob dotglob

# ---- disable future history (system-wide) ----
if [[ $DO_DISABLE -eq 1 ]]; then
  echo "=== disabling future history (bash, zsh-if-present, vim, nano) ==="

  # Bash: /etc/profile.d snippet
  bash_snip="/etc/profile.d/00-no-history.sh"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] write $bash_snip"
  else
    cat > "$bash_snip" <<'EOS'
# Added by nuke-hist-min.sh: disable bash history
export HISTFILE=/dev/null
export HISTSIZE=0
export HISTFILESIZE=0
# Avoid auto 'history -a' via PROMPT_COMMAND re-appends
case "$PROMPT_COMMAND" in
  *history*) PROMPT_COMMAND="" ;;
esac
EOS
    chmod 0644 "$bash_snip"
  fi

  # Zsh: only if zsh exists OR any user uses zsh; create /etc/zsh if needed
  if command -v zsh >/dev/null 2>&1 || getent passwd | awk -F: '$7 ~ /zsh/ {found=1} END{exit !found}'; then
    if [[ -d /etc/zsh/zshenv.d ]]; then
      zsh_snip="/etc/zsh/zshenv.d/00-no-history.zsh"
      if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] write $zsh_snip"
      else
        touch "$zsh_snip"; chmod 0644 "$zsh_snip"
        if ! grep -q "BEGIN NO-HISTORY (nuke-hist-min)" "$zsh_snip" 2>/dev/null; then
          cat >> "$zsh_snip" <<'EOS'
# BEGIN NO-HISTORY (nuke-hist-min)
HISTFILE=/dev/null
HISTSIZE=0
SAVEHIST=0
setopt NO_HIST_IGNORE_DUPS
setopt NO_HIST_SAVE_NO_DUPS
# END NO-HISTORY (nuke-hist-min)
EOS
        fi
      fi
    else
      # Ensure /etc/zsh exists, then use /etc/zsh/zshenv
      if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] mkdir -p /etc/zsh && write /etc/zsh/zshenv"
      else
        install -d -m 0755 /etc/zsh
        zsh_snip="/etc/zsh/zshenv"
        touch "$zsh_snip"; chmod 0644 "$zsh_snip"
        if ! grep -q "BEGIN NO-HISTORY (nuke-hist-min)" "$zsh_snip" 2>/dev/null; then
          cat >> "$zsh_snip" <<'EOS'
# BEGIN NO-HISTORY (nuke-hist-min)
HISTFILE=/dev/null
HISTSIZE=0
SAVEHIST=0
setopt NO_HIST_IGNORE_DUPS
setopt NO_HIST_SAVE_NO_DUPS
# END NO-HISTORY (nuke-hist-min)
EOS
        fi
      fi
    fi
  else
    echo "   (zsh not present; skipping zsh config)"
  fi

  # Vim: disable viminfo persistence
  vim_sys_rc="/etc/vim/vimrc"
  [[ -f /etc/vim/vimrc.local ]] && vim_sys_rc="/etc/vim/vimrc.local"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] ensure and write $vim_sys_rc"
  else
    install -d -m 0755 /etc/vim || true
    touch "$vim_sys_rc"; chmod 0644 "$vim_sys_rc"
    if ! grep -q "nuke-hist-min viminfo" "$vim_sys_rc" 2>/dev/null; then
      printf '%s\n' '" nuke-hist-min viminfo' 'set viminfo=' >> "$vim_sys_rc"
    fi
  fi

  # Nano: ensure history logging is disabled
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] modify /etc/nanorc (disable historylog)"
  else
    touch /etc/nanorc; chmod 0644 /etc/nanorc
    sed -i 's/^\s*set\s\+historylog/# disabled by nuke-hist-min: &/' /etc/nanorc || true
    grep -q '^\s*unset\s\+historylog' /etc/nanorc || echo 'unset historylog' >> /etc/nanorc
  fi

  echo "=== disable complete ==="
fi

echo "=== done ==="
echo "Note: active shells keep in-memory history until a new session. Open a new terminal or re-login."