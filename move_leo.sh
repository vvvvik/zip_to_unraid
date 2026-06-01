#!/bin/bash
USB_MA="/volumeUSB1/usbshare/MA/2025"
USB_LEO="/volumeUSB1/usbshare/LEO/2025"
REF="/volume1/exams24/2025"
COUNT=0
for month_dir in "$USB_MA"/*/; do
    month=$(basename "$month_dir")
    ref_dir="$REF/$month"
    if [ ! -d "$ref_dir" ]; then
        echo "[$month] немає в еталоні — весь місяць Leo"
        continue
    fi
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        echo "[$month] MOVE: $file"
        (( COUNT++ ))
    done < <(comm -23 <(ls "$month_dir" | sort) <(ls "$ref_dir" | sort))
done
echo "--- Всього файлів для переносу: $COUNT ---"
