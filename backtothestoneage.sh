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
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN] $*"
  else
    eval "$@"
  fi
}

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo)."
  exit 1
fi

echo "=== nuking CLI/Vim/Nano histories (dry-run=${DRY_RUN}) ==="

# Collect home dirs from /etc/passwd + ensure /root
mapfile -t HOMES < <(getent passwd | awk -F: '{print $6}' | sort -u)
if ! printf '%s\n' "${HOMES[@]}" | grep -qx "/root"; then
  HOMES+=("/root")
fi

# Exact history files (no globs)
HIST_FILES=(
  ".bash_history"
  ".zsh_history"
  ".fish_history"
  ".nano_history"
  ".viminfo"
  ".vim/viminfo"
)

# Vim swap patterns (globs) – safe to remove
VIM_SWAP_GLOBS=(
  ".*.swp" "*.swp" ".*.swo" "*.swo"
  ".vimswap*" ".vi.swp" ".vimrc.swp"
)

for HOME_DIR in "${HOMES[@]}"; do
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

  # Remove vim swap files via globs
  shopt -s nullglob dotglob
  for gp in "${VIM_SWAP_GLOBS[@]}"; do
    for file in "$HOME_DIR"/$gp; do
      echo "   removing: $file"
      run rm -f -- "$file"
    done
  done
  shopt -u nullglob dotglob
done

echo "=== done ==="
echo "Note: active shells still hold in-memory history; users should start a new shell/session."