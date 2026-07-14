#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="/etc/ssh/sshd_config"
DROPIN_DIR="/etc/ssh/sshd_config.d"
MANAGED_BEGIN="# BEGIN ssh-server-setup managed settings"
MANAGED_END="# END ssh-server-setup managed settings"

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    log "Root privileges are required; restarting this script with sudo."
    exec sudo -- "$0" "$@"
  fi
  die "Run this script as root or install/use sudo."
fi

for required_command in awk cat cmp cp date grep id mkdir mktemp printf; do
  command -v "$required_command" >/dev/null 2>&1 || die "Required command not found: $required_command"
done

[[ -f "$CONFIG_FILE" ]] || die "SSH configuration not found: $CONFIG_FILE"
[[ ! -L "$CONFIG_FILE" ]] || die "Refusing to edit a symlinked $CONFIG_FILE."

SSHD_BIN="$(command -v sshd || true)"
if [[ -z "$SSHD_BIN" && -x /usr/sbin/sshd ]]; then
  SSHD_BIN=/usr/sbin/sshd
fi
[[ -n "$SSHD_BIN" ]] || die "OpenSSH server (sshd) is not installed."

shopt -s nullglob
DROPIN_FILES=()
if [[ -d "$DROPIN_DIR" ]]; then
  DROPIN_FILES=("$DROPIN_DIR"/*.conf)
fi

for dropin_file in "${DROPIN_FILES[@]}"; do
  [[ ! -L "$dropin_file" ]] || die "Refusing to edit symlinked drop-in: $dropin_file"
  [[ -f "$dropin_file" ]] || die "Drop-in is not a regular file: $dropin_file"
done

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/etc/ssh/ssh-server-setup-backup-${TIMESTAMP}-$$"
MANIFEST="$BACKUP_DIR/dropins.tsv"
umask 077
mkdir -p -- "$BACKUP_DIR"

cp -a -- "$CONFIG_FILE" "$BACKUP_DIR/sshd_config"
cmp -s -- "$CONFIG_FILE" "$BACKUP_DIR/sshd_config" || die "Main configuration backup verification failed."
: > "$MANIFEST"

dropin_index=0
for dropin_file in "${DROPIN_FILES[@]}"; do
  dropin_index=$((dropin_index + 1))
  backup_name="dropin-$(printf '%04d' "$dropin_index").conf"
  cp -a -- "$dropin_file" "$BACKUP_DIR/$backup_name"
  cmp -s -- "$dropin_file" "$BACKUP_DIR/$backup_name" || die "Backup verification failed for $dropin_file"
  printf '%s\t%s\n' "$backup_name" "$dropin_file" >> "$MANIFEST"
done

[[ -r "$BACKUP_DIR/sshd_config" && -r "$MANIFEST" ]] || die "Backup is not readable."
log "Verified backup created at: $BACKUP_DIR"

CHANGES_STARTED=0
ROLLBACK_DONE=0

rollback() {
  local reason="${1:-unspecified error}"
  local backup_name original_path

  if [[ $CHANGES_STARTED -eq 0 || $ROLLBACK_DONE -eq 1 ]]; then
    return 0
  fi

  trap - ERR INT TERM
  set +e
  warn "Restoring SSH configuration because: $reason"
  cp -a -- "$BACKUP_DIR/sshd_config" "$CONFIG_FILE"
  while IFS=$'\t' read -r backup_name original_path; do
    [[ -n "$backup_name" && -n "$original_path" ]] || continue
    cp -a -- "$BACKUP_DIR/$backup_name" "$original_path"
  done < "$MANIFEST"
  ROLLBACK_DONE=1
  warn "Original SSH configuration restored. SSH was not restarted."
}

on_error() {
  local exit_code=$?
  rollback "a command failed (exit $exit_code)"
  exit "$exit_code"
}

on_signal() {
  rollback "the script was interrupted"
  exit 130
}

trap on_error ERR
trap on_signal INT TERM

rewrite_config_file() {
  local target_file=$1
  local add_managed_block=$2
  local filtered_file output_file

  filtered_file="$(mktemp)"
  output_file="$(mktemp)"

  awk -v managed_begin="$MANAGED_BEGIN" -v managed_end="$MANAGED_END" '
    BEGIN { in_managed_block = 0 }
    {
      trimmed = $0
      sub(/^[[:space:]]+/, "", trimmed)

      if (trimmed == managed_begin) {
        in_managed_block = 1
        next
      }
      if (trimmed == managed_end) {
        in_managed_block = 0
        next
      }
      if (in_managed_block) {
        next
      }

      lowered = tolower(trimmed)
      if (lowered ~ /^(permitrootlogin|passwordauthentication)([[:space:]]+|=)/) {
        print "# ssh-server-setup disabled previous setting: " $0
      } else {
        print $0
      }
    }
  ' "$target_file" > "$filtered_file"

  if [[ "$add_managed_block" == "yes" ]]; then
    {
      printf '%s\n' "$MANAGED_BEGIN"
      printf '%s\n' 'PermitRootLogin yes'
      printf '%s\n' 'PasswordAuthentication yes'
      printf '%s\n\n' "$MANAGED_END"
      cat "$filtered_file"
    } > "$output_file"
  else
    cat "$filtered_file" > "$output_file"
  fi

  cat "$output_file" > "$target_file"
  rm -f -- "$filtered_file" "$output_file"
}

CHANGES_STARTED=1
log "Applying PermitRootLogin yes and PasswordAuthentication yes."
rewrite_config_file "$CONFIG_FILE" yes

for dropin_file in "${DROPIN_FILES[@]}"; do
  log "Neutralizing conflicting directives in: $dropin_file"
  rewrite_config_file "$dropin_file" no
done

log "Checking SSH syntax with: $SSHD_BIN -t"
if ! "$SSHD_BIN" -t -f "$CONFIG_FILE"; then
  rollback "sshd -t rejected the new configuration"
  exit 1
fi

if ! EFFECTIVE_CONFIG="$($SSHD_BIN -T -f "$CONFIG_FILE" -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null)"; then
  rollback "sshd could not calculate the effective root configuration"
  exit 1
fi

if ! grep -Eqi '^permitrootlogin[[:space:]]+yes$' <<< "$EFFECTIVE_CONFIG"; then
  rollback "effective PermitRootLogin value is not yes"
  exit 1
fi

if ! grep -Eqi '^passwordauthentication[[:space:]]+yes$' <<< "$EFFECTIVE_CONFIG"; then
  rollback "effective PasswordAuthentication value is not yes"
  exit 1
fi

trap - ERR INT TERM
CHANGES_STARTED=0
log "SSH configuration syntax and effective values are valid."

restart_ssh_service() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files ssh.service --no-legend 2>/dev/null | grep -q '^ssh\.service'; then
      systemctl restart ssh
      RESTARTED_SERVICE=ssh
      return 0
    fi
    if systemctl list-unit-files sshd.service --no-legend 2>/dev/null | grep -q '^sshd\.service'; then
      systemctl restart sshd
      RESTARTED_SERVICE=sshd
      return 0
    fi
  fi

  if command -v service >/dev/null 2>&1; then
    if service ssh restart >/dev/null 2>&1; then
      RESTARTED_SERVICE=ssh
      return 0
    fi
    if service sshd restart >/dev/null 2>&1; then
      RESTARTED_SERVICE=sshd
      return 0
    fi
  fi

  return 1
}

RESTARTED_SERVICE=""
if ! restart_ssh_service; then
  die "Configuration is valid, but neither the ssh nor sshd service could be restarted. Backup: $BACKUP_DIR"
fi

printf '\n[SUCCESS] SSH configuration updated and %s service restarted.\n' "$RESTARTED_SERVICE"
printf '[SUCCESS] Effective setting: PermitRootLogin yes\n'
printf '[SUCCESS] Effective setting: PasswordAuthentication yes\n'
printf '[SUCCESS] Backup retained at: %s\n' "$BACKUP_DIR"
printf '\n[IMPORTANT] This script does not set a password. Set the root password yourself:\n'
printf '  sudo passwd root\n'
printf '\n[SECURITY] Root password login increases attack risk. Restrict network access and disable it when no longer needed.\n'
