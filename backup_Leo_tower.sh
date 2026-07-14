#!/bin/bash
# =============================================================================
# backup_Leo_tower.sh — архівування Leo → Unraid Tower
# Версія: 3.0
# =============================================================================

# =============================================================================
# РЕДАГУЙ ЩОМІСЯЦЯ
# =============================================================================

YEAR="2026"
MONTH="07"
MONTH_DIR="07-mis"

# =============================================================================
# НАЛАШТУВАННЯ КЛІНІКИ (не чіпати)
# =============================================================================

CLINIC_NAME="Leo"

# onlyZip = тільки архівування, без rsync
# remote  = тільки Unraid
# usb     = тільки USB диск
# both    = Unraid + USB
TARGET="remote"
ZIP_LEVEL=2

SOURCE_DIR="/volume1/exams26/SCREENING/${YEAR}/${MONTH_DIR}"
ZIP_DIR="/volume1/exams_zip/${YEAR}/${MONTH_DIR}"
REMOTE_MOUNT="/volume1/remotes/Leo_backups"
REMOTE_DIR="${REMOTE_MOUNT}/Leo/${YEAR}/${MONTH_DIR}"
USB_DIR="/volumeUSB1/usbshare/Leo/${YEAR}/${MONTH_DIR}"
STATUS_JSON="${REMOTE_MOUNT}/status/${CLINIC_NAME}.json"

LOG_DIR="/volume1/scripts/log"
LOG_FILE="${LOG_DIR}/backup_${CLINIC_NAME}_${YEAR}_${MONTH}.log"
CSV_FILE="${LOG_DIR}/processed_${YEAR}_${MONTH}.csv"

# =============================================================================
# ІНІЦІАЛІЗАЦІЯ
# =============================================================================

LOCK_FILE="/tmp/backup_${CLINIC_NAME}.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Скрипт вже запущено."; exit 0; }

mkdir -p "$ZIP_DIR" "$LOG_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${1}] ${2}" | tee -a "$LOG_FILE"
}

is_mounted() {
    awk -v mp="$1" '$2==mp{found=1;exit} END{exit !found}' /proc/mounts
}

if [ ! -f "$CSV_FILE" ]; then
    echo "processed_at,year,month,patient_dir,zip_name,zip_size_bytes,rsync_remote_ok,rsync_usb_ok" > "$CSV_FILE"
fi

# =============================================================================
# ПЕРЕВІРКИ
# =============================================================================

if [ ! -d "$SOURCE_DIR" ]; then
    log "ERROR" "Джерело не знайдено: $SOURCE_DIR"
    exit 1
fi

DESTINATIONS_OK=true

if [[ "$TARGET" == "remote" || "$TARGET" == "both" ]]; then
    if ! is_mounted "$REMOTE_MOUNT"; then
        log "ERROR" "NFS не змонтована: $REMOTE_MOUNT"
        DESTINATIONS_OK=false
    elif mkdir -p "$REMOTE_DIR" 2>/dev/null; then
        log "INFO" "Remote DIR: OK — $REMOTE_DIR"
    else
        log "ERROR" "Remote DIR недоступний: $REMOTE_DIR"
        DESTINATIONS_OK=false
    fi
fi

if [[ "$TARGET" == "usb" || "$TARGET" == "both" ]]; then
    if mkdir -p "$USB_DIR" 2>/dev/null; then
        log "INFO" "USB DIR: OK — $USB_DIR"
    else
        log "ERROR" "USB DIR недоступний: $USB_DIR"
        DESTINATIONS_OK=false
    fi
fi

if [ "$DESTINATIONS_OK" = false ]; then
    log "ERROR" "Не всі призначення доступні. Зупинено."
    exit 1
fi

# =============================================================================
# ФУНКЦІЇ
# =============================================================================

sanitize_name() {
    echo "$1" | sed "s/[[:space:]\.'\`]/_/g"
}

file_size() {
    stat -c%s "$1" 2>/dev/null || echo "0"
}

is_folder_active() {
    find "$1" -type f -mmin -10 | grep -q .
}

patient_status() {
    local row
    row=$(grep -F "\"${1}\"" "$CSV_FILE" 2>/dev/null | tail -1)
    [ -z "$row" ] && return 0
    [[ "$TARGET" == "onlyZip" ]] && return 1
    local remote_ok usb_ok
    remote_ok=$(echo "$row" | cut -d',' -f7 | tr -d '"')
    usb_ok=$(echo "$row" | cut -d',' -f8 | tr -d '"')
    [[ "$TARGET" == "remote" || "$TARGET" == "both" ]] && [ "$remote_ok" == "false" ] && return 2
    [[ "$TARGET" == "usb"    || "$TARGET" == "both" ]] && [ "$usb_ok"    == "false" ] && return 2
    return 1
}

do_rsync() {
    local zip_path="$1" dest_dir="$2" label="$3"
    local zip_name
    zip_name=$(basename "$zip_path")

    if [[ "$label" == "Remote" ]] && ! is_mounted "$REMOTE_MOUNT"; then
        log "ERROR" "Rsync FAILED (${label}): NFS відвалилась"
        return 1
    fi

    mkdir -p "$dest_dir" 2>/dev/null || { log "WARN" "Rsync пропущено (${label}): не вдалось створити $dest_dir"; return 1; }

    if [[ "$label" == "USB" ]]; then
        rsync -rtv --no-perms --no-owner --no-group --no-times "$zip_path" "$dest_dir/" >> "$LOG_FILE" 2>&1
    else
        rsync -av "$zip_path" "$dest_dir/" >> "$LOG_FILE" 2>&1
    fi

    if [ $? -eq 0 ]; then
        log "INFO" "Rsync OK (${label}): $zip_name"
        return 0
    else
        log "ERROR" "Rsync FAILED (${label}): $zip_name"
        return 1
    fi
}

write_status() {
    local run_status="$1" new="$2" retry="$3" skipped="$4" errors="$5"
    mkdir -p "$(dirname "$STATUS_JSON")" 2>/dev/null
    cat > "$STATUS_JSON" <<EOF
{
  "clinic": "${CLINIC_NAME}",
  "year": "${YEAR}",
  "month": "${MONTH}",
  "month_dir": "${MONTH_DIR}",
  "target": "${TARGET}",
  "status": "${run_status}",
  "new": ${new},
  "retry": ${retry},
  "skipped": ${skipped},
  "errors": ${errors},
  "last_run": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
    chmod 644 "$STATUS_JSON" 2>/dev/null
}

process_patient() {
    local patient_path="$1"
    local patient_name zip_name zip_path
    patient_name=$(basename "$patient_path")
    zip_name="$(sanitize_name "$patient_name").zip"
    zip_path="${ZIP_DIR}/${zip_name}"
    local rsync_remote_ok="false" rsync_usb_ok="false"

    log "INFO" "Обробка: $patient_name"

    if [ ! -f "$zip_path" ]; then
        ( cd "$(dirname "$patient_path")" && zip -r -"${ZIP_LEVEL}" "$zip_path" "$patient_name" > /dev/null 2>&1 )
        if [ $? -ne 0 ]; then
            log "ERROR" "Помилка архівування: $patient_name"
            rm -f "$zip_path"
            return 1
        fi
        touch -r "$patient_path" "$zip_path"
        log "INFO" "ZIP створено: $zip_name ($(du -sh "$zip_path" | cut -f1))"
    else
        log "INFO" "ZIP вже існує: $zip_name"
    fi

    if [[ "$TARGET" == "remote" || "$TARGET" == "both" ]]; then
        do_rsync "$zip_path" "$REMOTE_DIR" "Remote" && rsync_remote_ok="true"
    fi
    if [[ "$TARGET" == "usb" || "$TARGET" == "both" ]]; then
        do_rsync "$zip_path" "$USB_DIR" "USB" && rsync_usb_ok="true"
    fi

    local safe_name="${patient_name//\"/''}"
    echo "\"$(date '+%Y-%m-%d %H:%M:%S')\",\"${YEAR}\",\"${MONTH}\",\"${safe_name}\",\"${zip_name}\",\"$(file_size "$zip_path")\",\"${rsync_remote_ok}\",\"${rsync_usb_ok}\"" >> "$CSV_FILE"

    [[ "$TARGET" == "remote" || "$TARGET" == "both" ]] && [ "$rsync_remote_ok" == "false" ] && return 1
    [[ "$TARGET" == "usb"    || "$TARGET" == "both" ]] && [ "$rsync_usb_ok"    == "false" ] && return 1
    return 0
}

# =============================================================================
# ГОЛОВНА ЛОГІКА
# =============================================================================

log "INFO" "========================================================"
log "INFO" "Клініка  : ${CLINIC_NAME}"
log "INFO" "Період   : ${YEAR}/${MONTH_DIR}"
log "INFO" "Ціль     : $TARGET"
log "INFO" "Джерело  : $SOURCE_DIR"
log "INFO" "========================================================"

NEW_COUNT=0; RETRY_COUNT=0; SKIP_COUNT=0; ERROR_COUNT=0

while IFS= read -r -d '' patient_path; do
    patient_name=$(basename "$patient_path")

    if is_folder_active "$patient_path"; then
        log "INFO" "Активний запис (< 10 хв): $patient_name"
        (( SKIP_COUNT++ ))
        continue
    fi

    patient_status "$patient_name"
    status=$?

    if [ $status -eq 1 ]; then
        log "INFO" "Вже оброблено: $patient_name"
        (( SKIP_COUNT++ ))
        continue
    fi

    if [ $status -eq 2 ]; then
        log "INFO" "Повтор rsync: $patient_name"
        if process_patient "$patient_path"; then (( RETRY_COUNT++ )); else (( ERROR_COUNT++ )); fi
        continue
    fi

    if process_patient "$patient_path"; then (( NEW_COUNT++ )); else (( ERROR_COUNT++ )); fi

done < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

# =============================================================================
# ПІДСУМОК
# =============================================================================

log "INFO" "========================================================"
log "INFO" "ПІДСУМОК ${CLINIC_NAME} ${YEAR}/${MONTH_DIR}:"
log "INFO" "  Нових    : $NEW_COUNT"
log "INFO" "  Retry    : $RETRY_COUNT"
log "INFO" "  Пропущено: $SKIP_COUNT"
log "INFO" "  Помилок  : $ERROR_COUNT"
log "INFO" "========================================================"

if [ $ERROR_COUNT -gt 0 ]; then
    write_status "error" $NEW_COUNT $RETRY_COUNT $SKIP_COUNT $ERROR_COUNT
    exit 1
fi

write_status "ok" $NEW_COUNT $RETRY_COUNT $SKIP_COUNT $ERROR_COUNT
exit 0
