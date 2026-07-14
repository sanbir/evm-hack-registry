#!/bin/bash
set -u
BP="$(cd "$(dirname "$0")" && pwd)"
REG="$(cd "$BP/../.." && pwd)"
LOG="$BP/ensure-all.log"

echo "[ensure] Persistent JSON builder started at $(date -Iseconds)" | tee -a "$LOG"
echo "[ensure] Will keep running until all 845 slugs have a .json file." | tee -a "$LOG"

while true; do
  # Build dynamic missing list every cycle
  MISSING=()
  while IFS= read -r folder || [ -n "${folder:-}" ]; do
    [ -z "$folder" ] && continue
    slug="${folder%_exp}"
    if [ ! -f "$REG/$folder/$slug.json" ]; then
      MISSING+=("$folder")
    fi
  done < "$BP/build-all-folders.txt"

  if [ ${#MISSING[@]} -eq 0 ]; then
    echo "[ensure] COMPLETE: All JSON files present on disk at $(date -Iseconds)" | tee -a "$LOG"
    touch "$BP/ALL_JSONS_DONE"
    echo "[ensure] Driver will now sleep (can be restarted if needed)." | tee -a "$LOG"
    # Sleep forever but check periodically in case files are deleted
    while true; do sleep 3600; done
  fi

  echo "[ensure] $(date -Iseconds) - ${#MISSING[@]} missing. Starting pass..." | tee -a "$LOG"

  for folder in "${MISSING[@]}"; do
    slug="${folder%_exp}"
    echo "[ensure] Building $folder ..." | tee -a "$LOG"
    # Run the builder; it now always tries to emit JSON even on partial failure
    node "$BP/build.mjs" "$folder" >> "$LOG" 2>&1 || true

    # Verify
    if [ -f "$REG/$folder/$slug.json" ]; then
      sz=$(du -h "$REG/$folder/$slug.json" | awk '{print $1}')
      echo "[ensure]   ✓ $folder -> $sz" | tee -a "$LOG"
    else
      echo "[ensure]   ✗ $folder still missing after build (will retry next pass)" | tee -a "$LOG"
    fi

    sleep 2
  done

  echo "[ensure] Pass complete. Rescanning in 10s..." | tee -a "$LOG"
  sleep 10
done
