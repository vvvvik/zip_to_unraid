#!/bin/bash
# =============================================================================
# status.sh — стан архівування Leo DS718
# =============================================================================

YEAR="2026"
MONTH="06"
MONTH_DIR="06-mis"

SOURCE_DIR="/volume1/exams26/SCREENING/${YEAR}/${MONTH_DIR}"
ZIP_DIR="/volume1/exams_zip/${YEAR}/${MONTH_DIR}"
REMOTE_MOUNT="/volume1/remotes/Leo_backups"
REMOTE_DIR="${REMOTE_MOUNT}/Leo/${YEAR}/${MONTH_DIR}"
CSV_FILE="/volume1/scripts/log/processed_${YEAR}_${MONTH}.csv"

is_mounted() {
    awk -v mp="$1" '$2==mp{found=1;exit} END{exit !found}' /proc/mounts
}

# --- Підрахунок ---

SOURCE_COUNT=$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
ZIP_COUNT=$(find "$ZIP_DIR" -maxdepth 1 -name "*.zip" 2>/dev/null | wc -l | tr -d ' ')
CSV_COUNT=$(tail -n +2 "$CSV_FILE" 2>/dev/null | wc -l | tr -d ' ')

if is_mounted "$REMOTE_MOUNT"; then
    REMOTE_COUNT=$(find "$REMOTE_DIR" -maxdepth 1 -name "*.zip" 2>/dev/null | wc -l | tr -d ' ')
    REMOTE_STATUS="$REMOTE_COUNT"
else
    REMOTE_COUNT=0
    REMOTE_STATUS="NFS не змонтовано!"
fi

# --- Retry: пацієнти де остання запис має rsync_remote_ok=false ---

RETRY_LIST=$(tail -n +2 "$CSV_FILE" 2>/dev/null | awk -F'","' '{
    status[$4] = $7
} END {
    for (p in status) if (status[p] == "false") print p
}' | sort)

if [ -z "$RETRY_LIST" ]; then
    RETRY_COUNT=0
else
    RETRY_COUNT=$(echo "$RETRY_LIST" | wc -l | tr -d ' ')
fi

# --- Не архівовано: папки яких немає в CSV ---

NOT_ARCHIVED=$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | while read -r dir; do
    name=$(basename "$dir")
    if ! grep -qF "\"${name}\"" "$CSV_FILE" 2>/dev/null; then
        echo "$name"
    fi
done)

if [ -z "$NOT_ARCHIVED" ]; then
    NOT_COUNT=0
else
    NOT_COUNT=$(echo "$NOT_ARCHIVED" | wc -l | tr -d ' ')
fi

# --- Вивід ---

echo "=== Leo ${YEAR}/${MONTH_DIR} ==="
echo ""
printf "Папок у джерелі : %s\n" "$SOURCE_COUNT"
printf "ZIP локально    : %s\n" "$ZIP_COUNT"
printf "На Unraid       : %s\n" "$REMOTE_STATUS"
printf "В CSV           : %s\n" "$CSV_COUNT"
echo ""
printf "Потребують retry: %s\n" "$RETRY_COUNT"
printf "Не архівовано   : %s\n" "$NOT_COUNT"

if [ "$RETRY_COUNT" -gt 0 ]; then
    echo ""
    echo "--- Потребують retry ---"
    echo "$RETRY_LIST"
fi

if [ "$NOT_COUNT" -gt 0 ]; then
    echo ""
    echo "--- Не архівовано ---"
    echo "$NOT_ARCHIVED"
fi

echo ""
