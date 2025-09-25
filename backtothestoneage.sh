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
WIPE_LOGS=0
DISABLE_SAVE=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --logs) WIPE_LOGS=1 ;;
    --disable-save) DISABLE_SAVE=1 ;;
    *) echo "Unknown option: $arg"; echo "Usage: $0 [--logs] [--disable-save] [--dry-run]"; exit 2 ;;
  esac
done

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] $*"
  else
    eval "$@"
  fi
}

# must be root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root (sudo)."
  exit 1
fi

echo "=== backtothestoneage: starting (dry-run=$DRY_RUN, wipe-logs=$WIPE_LOGS, disable-save=$DISABLE_SAVE) ==="

# gather home directories from passwd (works for users with valid home dirs)
mapfile -t HOMEDIRS < <(getent passwd | awk -F: '{print $6}' | sort -u)

# ensure /root is included
if ! printf '%s\n' "${HOMEDIRS[@]}" | grep -qx "/root"; then
  HOMEDIRS+=("/root")
fi

# list of filename patterns to remove inside each home dir
read -r -d '' FILE_PATTERNS <<'EOF' || true
.bash_history
.bash_logout
.zsh_history
.ksh_history
.fish_history
.profile
.viminfo
.vim/viminfo
.viminfo.gz
.viminfo-*
.nano_history
.lesshst
.python_history
.ipython/profile_default/history.sqlite
.pip/pip.log
.wget-hsts
.mysql_history
.pg_history
.psql_history
.mongo_history
.ruby_history
.rbenv-version
.gemrc
EOF

# Also glob patterns for temp/swap files (vim swap, etc.)
SWAP_PATTERNS=( "*.swp" ".*.swp" ".vimswap*" ".vimrc.swp" ".vimswap*" ".vi.swp" ".*.swo" "*.swo" )

# Remove history files in each home dir (if dir exists)
for dir in "${HOMEDIRS[@]}"; do
  [ -d "$dir" ] || continue
  echo "Processing home: $dir"
  # fix spaces properly
  while IFS= read -r pattern; do
    target="$dir/$pattern"
    run bash -c "shopt -s nullglob; files=( $target ); if ((${#files[@]})); then printf ' removing: %s\n' \"\${files[@]}\"; rm -f -- \"\${files[@]}\"; fi"
  done <<< "$FILE_PATTERNS"

  # remove swap/glob patterns
  for gp in "${SWAP_PATTERNS[@]}"; do
    run bash -c "shopt -s nullglob dotglob; files=( \"$dir\"/$gp ); if ((${#files[@]})); then printf ' removing: %s\n' \"\${files[@]}\"; rm -f -- \"\${files[@]}\"; fi"
  done

  # also clear .ssh/known_hosts? (optional - not done by default)
done

# Additionally try to find any remaining history-like dotfiles across /home and /root and remove them
EXTRA_PATTERNS=( ".bash_history" ".zsh_history" ".nano_history" ".viminfo" ".lesshst" ".python_history" ".mysql_history" ".psql_history" )
for p in "${EXTRA_PATTERNS[@]}"; do
  echo "Searching for $p under /home and /root..."
  mapfile -t found < <(find /home /root -xdev -type f -name "$p" 2>/dev/null || true)
  if [ "${#found[@]}" -gt 0 ]; then
    for f in "${found[@]}"; do
      echo " removing: $f"
      run rm -f -- "$f"
    done
  fi
done

# Clear shell history for users currently in /proc (best-effort - cannot clear in-memory histories for other shells)
# We'll attempt to truncate HISTFILE for each live shell if writable
echo "Attempting best-effort truncation of in-use HISTFILEs for running users..."
# For each user, try to detect HISTFILE in their environment via /proc/*/environ (best-effort)
for pid in $(ps -eo pid=); do
  envfile="/proc/$pid/environ"
  if [ -r "$envfile" ]; then
    # extract HISTFILE or HOME
    hist=$(tr '\0' '\n' <"$envfile" 2>/dev/null | awk -F= '/^HISTFILE=/ {print substr($0, index($0,$2))}' | sed -n '1p' || true)
    home=$(tr '\0' '\n' <"$envfile" 2>/dev/null | awk -F= '/^HOME=/ {print substr($0, index($0,$2))}' | sed -n '1p' || true)
    if [ -n "$hist" ] && [ -f "$hist" ]; then
      echo " Truncating $hist (pid $pid)"
      run : > "$hist"
    elif [ -n "$home" ]; then
      # fallback common files
      pf="$home/.bash_history"
      if [ -f "$pf" ]; then
        echo " Truncating $pf (pid $pid)"
        run : > "$pf"
      fi
    fi
  fi
done

# Optionally truncate /var/log files (destructive)
if [ "$WIPE_LOGS" -eq 1 ]; then
  echo "Truncating /var/log files (this is destructive)."
  # Only truncate regular files (skip sockets, compressed archives)
  mapfile -t LOGFILES < <(find /var/log -type f -maxdepth 4 -mindepth 1 2>/dev/null || true)
  for lf in "${LOGFILES[@]}"; do
    echo " truncating: $lf"
    run truncate -s 0 "$lf"
  done
  # Also truncate common wtmp/utmp/lastlog if they exist
  for f in /var/log/wtmp /var/log/btmp /var/log/lastlog /var/log/utmp; do
    if [ -e "$f" ]; then
      echo " truncating: $f"
      run truncate -s 0 "$f"
    fi
  done
fi

# Optionally disable future history saving by appending to /etc/profile (idempotent)
if [ "$DISABLE_SAVE" -eq 1 ]; then
  echo "Adding history-disable lines to /etc/profile (idempotent)."
  block="# BEGIN NO-HISTORY ADDED BY backtothestoneage.sh - do not remove unless you intend to enable history again
export HISTFILE=/dev/null
export HISTSIZE=0
export HISTFILESIZE=0
# END NO-HISTORY"
  if grep -q "NO-HISTORY ADDED BY backtothestoneage.sh" /etc/profile 2>/dev/null; then
    echo " /etc/profile already contains history-disable block, skipping append."
  else
    run bash -c "echo \"$block\" >> /etc/profile"
    echo " Appended block to /etc/profile"
  fi
fi

echo "=== backtothestoneage: completed ==="
if [ "$DRY_RUN" -eq 1 ]; then
  echo "NOTE: this was a dry-run. Rerun without --dry-run to perform deletions."
fi
