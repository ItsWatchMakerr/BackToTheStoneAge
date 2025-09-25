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

for arg in "${@:-}"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    --disable) DO_DISABLE=1 ;;
    -h|--help)
      cat <<'USAGE'
nuke-hist-min.sh
  Remove ONLY bash/zsh/fish, nano, and vim histories for users in /home/* and /root.
  Optionally disable future history collection (bash, zsh, vim, nano).

Options:
  --dry-run, -n   Show what would be deleted without deleting
  --disable       Also write system-wide configs to stop future history saving
  -h, --help      Show this help

Examples:
  sudo ./nuke-hist-min.sh --dry-run
  sudo ./nuke-hist-min.sh
  sudo ./nuke-hist-min.sh --disable
USAGE
      exit 0
      ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  endesac
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

if [[ $DO_DISABLE -eq 1 ]]; then
  echo "=== writing system-wide 'no history' configs ==="

  # Bash: disable history (all shells)
  bash_snip='/etc/profile.d/no-history.sh'
  run "install -m 0644 /dev/null '$bash_snip'"
  run "cat > '$bash_snip' <<'EOS'
# Added by nuke-hist-min.sh: disable bash history
export HISTFILE=/dev/null
export HISTSIZE=0
export HISTFILESIZE=0
# Prevent PROMPT_COMMAND from re-appending history
unset PROMPT_COMMAND
EOS"

  # Zsh: disable history
  # Prefer zshenv.d if present, else append to /etc/zsh/zshenv
  if [[ -d /etc/zsh/zshenv.d ]]; then
    zsh_snip='/etc/zsh/zshenv.d/00-no-history.zsh'
  else
    zsh_snip='/etc/zsh/zshenv'
  fi
  # Make sure file exists
  run "touch '$zsh_snip'"
  run "chmod 0644 '$zsh_snip'"
  run "awk 'BEGIN{f=1} /BEGIN NO-HISTORY by nuke-hist-min/{f=0} END{if(f) print \"# BEGIN NO-HISTORY by nuke-hist-min\"}' '$zsh_snip' >/dev/null"
  run "grep -q 'BEGIN NO-HISTORY by nuke-hist-min' '$zsh_snip' || cat >> '$zsh_snip' <<'EOS'
# BEGIN NO-HISTORY by nuke-hist-min
HISTFILE=/dev/null
HISTSIZE=0
SAVEHIST=0
# END NO-HISTORY by nuke-hist-min
EOS"

  # Vim: stop persisting history
  # Use vimrc.local if supported, else /etc/vim/vimrc
  vim_sys_rc='/etc/vim/vimrc'
  [[ -f /etc/vim/vimrc.local ]] && vim_sys_rc='/etc/vim/vimrc.local'
  run "touch '$vim_sys_rc'"
  run "chmod 0644 '$vim_sys_rc'"
  run "grep -q 'nuke-hist-min viminfo' '$vim_sys_rc' || cat >> '$vim_sys_rc' <<'EOS'
\" nuke-hist-min viminfo
set viminfo=
EOS"

  # Nano: disable history log
  run "touch /etc/nanorc"
  run "chmod 0644 /etc/nanorc"
  # Remove any existing 'set historylog' and ensure 'unset historylog'
  run "sed -i 's/^\\s*set\\s\\+historylog/# disabled by nuke-hist-min/g' /etc/nanorc"
  run "grep -q '^unset\\s\\+historylog' /etc/nanorc || echo 'unset historylog' >> /etc/nanorc"

  echo "=== disable done ==="
fi

echo "=== done ==="
echo "Note: active shells keep in-memory history until a new session. Open a new terminal or re-login."