#!/bin/bash
USB_MA="/volumeUSB1/usbshare/MA/2025"
USB_LEO="/volumeUSB1/usbshare/LEO/2025"
REF="/volume1/exams24/2025"

for month_dir in "$USB_MA"/*/; do
    month=$(basename "$month_dir")
    ref_dir="$REF/$month"
    leo_dir="$USB_LEO/$month"
    MONTH_COUNT=0

    if [ ! -d "$ref_dir" ]; then
        echo "[$month] немає в еталоні — пропускаємо"
        continue
    fi

    while IFS= read -r file; do
        [ -z "$file" ] && continue
        mkdir -p "$leo_dir"
        mv "$month_dir/$file" "$leo_dir/"
        echo "[$month] MOVED: $file"
        (( MONTH_COUNT++ ))
    done < <(comm -23 <(ls "$month_dir" | sort) <(ls "$ref_dir" | sort))

    echo "[$month] --- Перенесено: $MONTH_COUNT файлів ---"
done

echo "======================================="
echo "Готово."
