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

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root (sudo)."
  exit 1
fi

echo "=== nuke-histories: starting (dry-run=$DRY_RUN, wipe-logs=$WIPE_LOGS, disable-save=$DISABLE_SAVE) ==="

mapfile -t HOMEDIRS < <(getent passwd | awk -F: '{print $6}' | sort -u)
if ! printf '%s\n' "${HOMEDIRS[@]}" | grep -qx "/root"; then
  HOMEDIRS+=("/root")
fi

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

SWAP_PATTERNS=( "*.swp" ".*.swp" ".vimswap*" ".vimrc.swp" ".*.swo" "*.swo" )

# Remove history files in each home dir
for dir in "${HOMEDIRS[@]}"; do
  [ -d "$dir" ] || continue
  echo "Processing home: $dir"

  # Regular (non-glob) and simple path patterns
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    target="$dir/$pattern"

    # If pattern contains a glob, handle separately below
    if [[ "$pattern" == *"*"* || "$pattern" == *"?"* || "$pattern" == *"["*"]"* ]]; then
      # glob pattern
      shopt -s nullglob dotglob
      matches=()
      # quote "$dir"/$pattern to allow globbing while keeping $dir intact
      for f in "$dir"/$pattern; do
        matches+=("$f")
      done
      if [ ${#matches[@]} -gt 0 ]; then
        printf ' removing: %s\n' "${matches[@]}"
        run rm -f -- "${matches[@]}"
      fi
      shopt -u nullglob dotglob
    else
      # exact path
      if [ -e "$target" ]; then
        echo " removing: $target"
        run rm -f -- "$target"
      fi
    fi
  done <<< "$FILE_PATTERNS"

  # vim swap and similar globs
  shopt -s nullglob dotglob
  for gp in "${SWAP_PATTERNS[@]}"; do
    matches=()
    for f in "$dir"/$gp; do
      matches+=("$f")
    done
    if [ ${#matches[@]} -gt 0 ]; then
      printf ' removing: %s\n' "${matches[@]}"
      run rm -f -- "${matches[@]}"
    fi
  done
  shopt -u nullglob dotglob
done

# Extra sweep for common history files
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

# Best-effort truncation of in-use HISTFILEs
echo "Attempting best-effort truncation of in-use HISTFILEs for running shells..."
for pid in $(ps -eo pid=); do
  envfile="/proc/$pid/environ"
  if [ -r "$envfile" ]; then
    hist="$(tr '\0' '\n' <"$envfile" 2>/dev/null | awk -F= '/^HISTFILE=/ {print $2; exit}')" || true
    home="$(tr '\0' '\n' <"$envfile" 2>/dev/null | awk -F= '/^HOME=/ {print $2; exit}')" || true
    if [ -n "${hist:-}" ] && [ -f "$hist" ]; then
      echo " truncating: $hist (pid $pid)"
      run : > "$hist"
    elif [ -n "${home:-}" ] && [ -f "$home/.bash_history" ]; then
      echo " truncating: $home/.bash_history (pid $pid)"
      run : > "$home/.bash_history"
    fi
  fi
done

# Optional: wipe logs
if [ "$WIPE_LOGS" -eq 1 ]; then
  echo "Truncating /var/log files (destructive)."
  mapfile -t LOGFILES < <(find /var/log -type f -maxdepth 4 -mindepth 1 2>/dev/null || true)
  for lf in "${LOGFILES[@]}"; do
    echo " truncating: $lf"
    run truncate -s 0 "$lf"
  done
  for f in /var/log/wtmp /var/log/btmp /var/log/lastlog /var/log/utmp; do
    if [ -e "$f" ]; then
      echo " truncating: $f"
      run truncate -s 0 "$f"
    fi
  done
fi

# Optional: disable future history saving
if [ "$DISABLE_SAVE" -eq 1 ]; then
  echo "Adding history-disable lines to /etc/profile (idempotent)."
  block="# BEGIN NO-HISTORY ADDED BY nuke-histories.sh
export HISTFILE=/dev/null
export HISTSIZE=0
export HISTFILESIZE=0
# END NO-HISTORY"
  if grep -q "NO-HISTORY ADDED BY nuke-histories.sh" /etc/profile 2>/dev/null; then
    echo " /etc/profile already contains history-disable block, skipping."
  else
    run bash -c "printf '%s\n' \"$block\" >> /etc/profile"
    echo " Appended block to /etc/profile"
  fi
fi

echo "=== nuke-histories: completed ==="
if [ "$DRY_RUN" -eq 1 ]; then
  echo "NOTE: this was a dry-run. Rerun without --dry-run to perform deletions."
fi

