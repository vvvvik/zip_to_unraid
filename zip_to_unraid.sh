#!/bin/bash
# =============================================================================
# zip_to_unraid.sh
# Призначення : Архівування нових папок пацієнтів (DICOM→ZIP)
#               та rsync на Unraid (холодний архів)
# Автор       : Leo
# Версія      : 2.1
# =============================================================================

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
SOURCE_DIR="/volume1/exams25/SCREENING/${YEAR}/${MONTH_DIR}"

# Локальне сховище ZIP архівів
ZIP_DIR="/volume1/exams_zip/${MONTH_DIR}"

# Віддалений Unraid (змонтований через NFS/SMB)
REMOTE_DIR="/volume1/remote/backup_DS/${YEAR}/${MONTH_DIR}"

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
    echo "processed_at,year,month,patient_dir,zip_name,zip_size_bytes,rsync_ok" > "$CSV_FILE"
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

# Перевірити чи існує віддалений шлях
if [ ! -d "$REMOTE_DIR" ]; then
    log "WARN" "Віддалена директорія не знайдена: $REMOTE_DIR — rsync буде пропущено"
fi

# =============================================================================
# ФУНКЦІЇ
# =============================================================================

# Перевірити чи папка вже оброблена (пошук в CSV)
is_processed() {
    local patient_dir="$1"
    grep -qF "\"${patient_dir}\"" "$CSV_FILE" 2>/dev/null
}

# Санітизація імені: замінити пробіли, крапки, апострофи на підкреслення
sanitize_name() {
    echo "$1" | sed "s/[[:space:]\.'\`]/_/g"
}

# Отримати розмір файлу в байтах
file_size() {
    stat -c%s "$1" 2>/dev/null || echo "0"
}

# Архівування та копіювання одного пацієнта
process_patient() {
    local patient_path="$1"
    local patient_name
    patient_name=$(basename "$patient_path")
    local zip_name
    zip_name="$(sanitize_name "$patient_name").zip"
    local zip_path="${ZIP_DIR}/${zip_name}"
    local rsync_ok="false"

    log "INFO" "Обробка: $patient_name"

    # --- Архівування ---
    if [ ! -f "$zip_path" ]; then
        # Subshell щоб cd не змінював CWD скрипту
        ( cd "$(dirname "$patient_path")" && zip -r -"${ZIP_LEVEL}" "$zip_path" "$patient_name" > /dev/null 2>&1 )
        local zip_status=$?

        if [ $zip_status -ne 0 ]; then
            log "ERROR" "Помилка архівування: $patient_name (код: $zip_status)"
            rm -f "$zip_path"   # Видалити неповний архів
            return 1
        fi

        # Зберегти оригінальну дату модифікації
        touch -r "$patient_path" "$zip_path"
        log "INFO" "ZIP створено: $zip_name ($(du -sh "$zip_path" | cut -f1))"
    else
        log "INFO" "ZIP вже існує: $zip_name — пропускаємо архівування"
    fi

    # --- Rsync на Unraid ---
    if [ -d "$REMOTE_DIR" ]; then
        rsync -av --checksum "$zip_path" "$REMOTE_DIR/" >> "$LOG_FILE" 2>&1
        local rsync_status=$?

        if [ $rsync_status -eq 0 ]; then
            rsync_ok="true"
            log "INFO" "Rsync OK: $zip_name → $REMOTE_DIR"
        else
            log "ERROR" "Rsync FAILED: $zip_name (код: $rsync_status)"
        fi
    else
        log "WARN" "Rsync пропущено — REMOTE_DIR недоступний"
    fi

    # --- Записати в CSV ---
    local zip_size safe_name
    zip_size=$(file_size "$zip_path")
    safe_name="${patient_name//\"/''}"
    echo "\"$(date '+%Y-%m-%d %H:%M:%S')\",\"${YEAR}\",\"${MONTH}\",\"${safe_name}\",\"${zip_name}\",\"${zip_size}\",\"${rsync_ok}\"" >> "$CSV_FILE"

    return 0
}

# =============================================================================
# ГОЛОВНА ЛОГІКА
# =============================================================================

log "INFO" "========================================================"
log "INFO" "Запуск скрипту: ${YEAR}/${MONTH_DIR}"
log "INFO" "Джерело  : $SOURCE_DIR"
log "INFO" "ZIP сховище : $ZIP_DIR"
log "INFO" "Unraid   : $REMOTE_DIR"
log "INFO" "========================================================"

# Знайти всі папки пацієнтів
NEW_COUNT=0
SKIP_COUNT=0
ERROR_COUNT=0

while IFS= read -r -d '' patient_path; do
    patient_name=$(basename "$patient_path")

    # Пропустити якщо вже в базі
    if is_processed "$patient_name"; then
        log "INFO" "Вже оброблено: $patient_name"
        (( SKIP_COUNT++ ))
        continue
    fi

    # Обробити пацієнта
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
log "INFO" "  Оброблено нових : $NEW_COUNT"
log "INFO" "  Пропущено (вже є): $SKIP_COUNT"
log "INFO" "  Помилок         : $ERROR_COUNT"
log "INFO" "  База даних      : $CSV_FILE"
log "INFO" "========================================================"

# Вийти з помилкою якщо були проблеми
if [ $ERROR_COUNT -gt 0 ]; then
    exit 1
fi

exit 0
