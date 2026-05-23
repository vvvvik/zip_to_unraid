#!/bin/bash
# =============================================================================
# zip_to_unraid.sh
# Призначення : Архівування нових папок пацієнтів (DICOM→ZIP)
#               та rsync на Unraid і/або USB (холодний архів)
# Автор       : Вік
# Версія      : 2.10
# =============================================================================

# =============================================================================
# СЕЛЕКТОР ПРИЗНАЧЕННЯ
# onlyZip = тільки архівування, без rsync
# remote  = тільки Unraid
# usb     = тільки USB диск
# both    = Unraid + USB
# =============================================================================

TARGET="remote"

# =============================================================================
# НАЛАШТУВАННЯ — змінювати щомісяця
# =============================================================================

YEAR="2026"
MONTH="05"
MONTH_DIR="05-mis"

# =============================================================================
# ШЛЯХИ — формуються автоматично з змінних вище
# =============================================================================

# Джерело: папки пацієнтів з DICOM
SOURCE_DIR="/volume1/exams26/SCREENING/${YEAR}/${MONTH_DIR}"

# Локальне сховище ZIP архівів
ZIP_DIR="/volume1/exams_zip/${YEAR}/${MONTH_DIR}"

# Віддалений Unraid (змонтований через NFS/SMB)
REMOTE_DIR="/volume1/remotes/Leo_backups/Leo/${YEAR}/${MONTH_DIR}"

# USB диск (змонтований локально)
USB_DIR="/volumeUSB1/usbshare/MA/${YEAR}/${MONTH_DIR}"

# Логи та база даних
LOG_DIR="/volume1/scripts/log"
LOG_FILE="${LOG_DIR}/zip_to_unraid_${YEAR}_${MONTH}.log"
CSV_FILE="${LOG_DIR}/processed_${YEAR}_${MONTH}.csv"

# =============================================================================
# НАЛАШТУВАННЯ ZIP
# =============================================================================

ZIP_LEVEL=2        # Рівень стиснення (1-9, 2 оптимально для DICOM)

# =============================================================================
# ІНІЦІАЛІЗАЦІЯ
# =============================================================================

# Захист від паралельного запуску
LOCK_FILE="/tmp/zip_to_unraid.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Скрипт вже запущено. Виходимо." ; exit 0; }

# Створити директорії якщо не існують
mkdir -p "$ZIP_DIR" "$LOG_DIR"

# Функція логування
log() {
    local level="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${level}] ${message}" | tee -a "$LOG_FILE"
}

# Ініціалізація CSV бази якщо не існує
if [ ! -f "$CSV_FILE" ]; then
    echo "processed_at,year,month,patient_dir,zip_name,zip_size_bytes,rsync_remote_ok,rsync_usb_ok" > "$CSV_FILE"
    log "INFO" "Створено нову базу даних: $CSV_FILE"
fi

# =============================================================================
# ПЕРЕВІРКИ
# =============================================================================

# Перевірити чи існує джерело
if [ ! -d "$SOURCE_DIR" ]; then
    log "ERROR" "Директорія джерела не знайдена: $SOURCE_DIR"
    exit 1
fi

# Перевірити доступність призначень
if [[ "$TARGET" == "remote" || "$TARGET" == "both" ]]; then
    if [ ! -d "$REMOTE_DIR" ]; then
        log "WARN" "Віддалена директорія не знайдена: $REMOTE_DIR — rsync на Unraid буде пропущено"
    fi
fi

if [[ "$TARGET" == "usb" || "$TARGET" == "both" ]]; then
    if [ ! -d "$USB_DIR" ]; then
        log "WARN" "USB директорія не знайдена: $USB_DIR — rsync на USB буде пропущено"
    fi
fi

# =============================================================================
# ФУНКЦІЇ
# =============================================================================

# Перевірити статус пацієнта в CSV відносно поточного TARGET
# Повертає: 0 = не в базі (повна обробка)
#           1 = повністю оброблено (пропустити)
#           2 = ZIP є, але rsync не завершено (повтор rsync)
patient_status() {
    local patient_dir="$1"
    local row
    row=$(grep -F "\"${patient_dir}\"" "$CSV_FILE" 2>/dev/null | tail -1)

    [ -z "$row" ] && return 0  # не в базі

    if [[ "$TARGET" == "onlyZip" ]]; then
        return 1  # rsync не потрібен
    fi

    local remote_ok usb_ok
    remote_ok=$(echo "$row" | cut -d',' -f7 | tr -d '"')
    usb_ok=$(echo "$row" | cut -d',' -f8 | tr -d '"')

    if [[ "$TARGET" == "remote" || "$TARGET" == "both" ]]; then
        [ "$remote_ok" == "false" ] && return 2
    fi
    if [[ "$TARGET" == "usb" || "$TARGET" == "both" ]]; then
        [ "$usb_ok" == "false" ] && return 2
    fi

    return 1  # все OK
}

# Санітизація імені: замінити пробіли, крапки, апострофи на підкреслення
sanitize_name() {
    echo "$1" | sed "s/[[:space:]\.'\`]/_/g"
}

# Отримати розмір файлу в байтах
file_size() {
    stat -c%s "$1" 2>/dev/null || echo "0"
}

# Rsync в одне призначення. Повертає: 0=OK, 1=помилка
do_rsync() {
    local zip_path="$1"
    local dest_dir="$2"
    local label="$3"
    local zip_name
    zip_name=$(basename "$zip_path")

    if [ ! -d "$dest_dir" ]; then
        log "WARN" "Rsync пропущено (${label}) — директорія недоступна: $dest_dir"
        return 1
    fi

    rsync -av "$zip_path" "$dest_dir/" >> "$LOG_FILE" 2>&1
    if [ $? -eq 0 ]; then
        log "INFO" "Rsync OK (${label}): $zip_name → $dest_dir"
        return 0
    else
        log "ERROR" "Rsync FAILED (${label}): $zip_name"
        return 1
    fi
}

# Архівування та копіювання одного пацієнта
process_patient() {
    local patient_path="$1"
    local patient_name
    patient_name=$(basename "$patient_path")
    local zip_name
    zip_name="$(sanitize_name "$patient_name").zip"
    local zip_path="${ZIP_DIR}/${zip_name}"
    local rsync_remote_ok="false"
    local rsync_usb_ok="false"

    log "INFO" "Обробка: $patient_name"

    # --- Архівування ---
    if [ ! -f "$zip_path" ]; then
        # Subshell щоб cd не змінював CWD скрипту
        ( cd "$(dirname "$patient_path")" && zip -r -"${ZIP_LEVEL}" "$zip_path" "$patient_name" > /dev/null 2>&1 )
        local zip_status=$?

        if [ $zip_status -ne 0 ]; then
            log "ERROR" "Помилка архівування: $patient_name (код: $zip_status)"
            rm -f "$zip_path"
            return 1
        fi

        # Зберегти оригінальну дату модифікації
        touch -r "$patient_path" "$zip_path"
        log "INFO" "ZIP створено: $zip_name ($(du -sh "$zip_path" | cut -f1))"
    else
        log "INFO" "ZIP вже існує: $zip_name — пропускаємо архівування"
    fi

    # --- Rsync згідно з TARGET ---
    if [[ "$TARGET" == "remote" || "$TARGET" == "both" ]]; then
        if do_rsync "$zip_path" "$REMOTE_DIR" "Remote"; then
            rsync_remote_ok="true"
        fi
    fi

    if [[ "$TARGET" == "usb" || "$TARGET" == "both" ]]; then
        if do_rsync "$zip_path" "$USB_DIR" "USB"; then
            rsync_usb_ok="true"
        fi
    fi

    # --- Записати в CSV (завжди, навіть при помилці rsync) ---
    local zip_size safe_name
    zip_size=$(file_size "$zip_path")
    safe_name="${patient_name//\"/''}"
    echo "\"$(date '+%Y-%m-%d %H:%M:%S')\",\"${YEAR}\",\"${MONTH}\",\"${safe_name}\",\"${zip_name}\",\"${zip_size}\",\"${rsync_remote_ok}\",\"${rsync_usb_ok}\"" >> "$CSV_FILE"

    # Якщо rsync провалився для потрібного призначення — повернути помилку
    if [[ "$TARGET" == "remote" || "$TARGET" == "both" ]] && [ "$rsync_remote_ok" == "false" ]; then
        return 1
    fi
    if [[ "$TARGET" == "usb" || "$TARGET" == "both" ]] && [ "$rsync_usb_ok" == "false" ]; then
        return 1
    fi

    return 0
}

# =============================================================================
# ГОЛОВНА ЛОГІКА
# =============================================================================

log "INFO" "========================================================"
log "INFO" "Запуск скрипту : ${YEAR}/${MONTH_DIR}"
log "INFO" "Призначення    : $TARGET"
log "INFO" "Джерело        : $SOURCE_DIR"
log "INFO" "ZIP сховище    : $ZIP_DIR"
log "INFO" "Unraid         : $REMOTE_DIR"
log "INFO" "USB            : $USB_DIR"
log "INFO" "========================================================"

NEW_COUNT=0
RETRY_COUNT=0
SKIP_COUNT=0
ERROR_COUNT=0

while IFS= read -r -d '' patient_path; do
    patient_name=$(basename "$patient_path")

    patient_status "$patient_name"
    status=$?

    if [ $status -eq 1 ]; then
        log "INFO" "Вже оброблено: $patient_name"
        (( SKIP_COUNT++ ))
        continue
    fi

    if [ $status -eq 2 ]; then
        log "INFO" "Повтор rsync: $patient_name"
        if process_patient "$patient_path"; then
            (( RETRY_COUNT++ ))
        else
            (( ERROR_COUNT++ ))
        fi
        continue
    fi

    # status=0 — повна обробка
    if process_patient "$patient_path"; then
        (( NEW_COUNT++ ))
    else
        (( ERROR_COUNT++ ))
    fi

done < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

# =============================================================================
# ПІДСУМОК
# =============================================================================

log "INFO" "========================================================"
log "INFO" "ПІДСУМОК ${YEAR}/${MONTH_DIR}:"
log "INFO" "  Призначення      : $TARGET"
log "INFO" "  Оброблено нових  : $NEW_COUNT"
log "INFO" "  Повтор rsync     : $RETRY_COUNT"
log "INFO" "  Пропущено (вже є): $SKIP_COUNT"
log "INFO" "  Помилок          : $ERROR_COUNT"
log "INFO" "  База даних       : $CSV_FILE"
log "INFO" "========================================================"

# Вийти з помилкою якщо були проблеми
if [ $ERROR_COUNT -gt 0 ]; then
    exit 1
fi

exit 0
