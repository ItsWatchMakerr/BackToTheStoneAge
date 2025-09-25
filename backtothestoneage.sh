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
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] $*"
  else
    eval "$@"
  fi
}

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root (sudo)."; exit 1; }

echo "=== nuking CLI/Vim/Nano histories (dry-run=${DRY_RUN}) ==="

# Only these dirs. No getent, no system accounts.
TARGET_HOMES=()
for d in /home/*; do [[ -d "$d" ]] && TARGET_HOMES+=("$d"); done
TARGET_HOMES+=("/root")

# Exact files
HIST_FILES=(
  ".bash_history"
  ".zsh_history"
  ".fish_history"
  ".nano_history"
  ".viminfo"
  ".vim/viminfo"
)

# Vim swap globs
VIM_SWAP_GLOBS=(
  ".*.swp" "*.swp" ".*.swo" "*.swo"
  ".vimswap*" ".vi.swp" ".vimrc.swp"
)

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
  shopt -s nullglob dotglob
  for gp in "${VIM_SWAP_GLOBS[@]}"; do
    for file in "$HOME_DIR"/$gp; do
      [[ -f "$file" ]] || continue
      echo "   removing: $file"
      run rm -f -- "$file"
    done
  done
  shopt -u nullglob dotglob
done

echo "=== done ==="
echo "Note: active shells keep in-memory history until a new session."