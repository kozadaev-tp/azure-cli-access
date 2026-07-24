#!/usr/bin/env bash
# Verify Teleport's Azure CLI proxy (`tsh az`) against batch blob operations:
# `az storage blob upload-batch` and `az storage blob download-batch`, comparing
# tsh az (Teleport-proxied) against native az (direct, your Entra ID user).
#
# Usage:
#   tsh apps login azure-cli --azure-identity teleport-azure
#   az login
#   ./test-azure-cli-batch.sh
#
# Optional:
#   TF_DIR=/path/to/terraform ./test-azure-cli-batch.sh
#   SIZES_MB="1 10 100"       ./test-azure-cli-batch.sh   # per-file sizes
#   FILE_COUNT=20             ./test-azure-cli-batch.sh   # files per batch
#   MAX_CONNECTIONS=4         ./test-azure-cli-batch.sh   # per-blob parallelism

set -uo pipefail

TF_DIR="${TF_DIR:-$(dirname "$0")/terraform}"
SIZES_MB="${SIZES_MB:-1 10 30}"
FILE_COUNT="${FILE_COUNT:-10}"
MAX_CONNECTIONS="${MAX_CONNECTIONS:-2}"

if [ ! -d "$TF_DIR" ]; then
  echo "Terraform directory not found: $TF_DIR" >&2
  exit 2
fi

ACCT="$(terraform -chdir="$TF_DIR" output -raw storage_account_name 2>/dev/null)" || {
  echo "Could not read storage_account_name output. Did you 'terraform apply'?" >&2
  exit 2
}
CTR="$(terraform -chdir="$TF_DIR" output -raw storage_container_name)"
RG="$(terraform -chdir="$TF_DIR" output -raw resource_group_name)"

az account show >/dev/null 2>&1 || { echo "Native 'az' not logged in. Run: az login" >&2; exit 2; }

# Sub-second timer
if command -v gdate >/dev/null; then
  NOW() { gdate +%s.%N; }
elif date +%s.%N 2>/dev/null | grep -q '\.'; then
  NOW() { date +%s.%N; }
else
  NOW() { date +%s; }
fi

echo "Storage account:   $ACCT"
echo "Container:         $CTR"
echo "Resource group:    $RG"
echo "Per-file sizes MB: $SIZES_MB"
echo "Files per batch:   $FILE_COUNT"
echo "Max connections:   $MAX_CONNECTIONS"
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

declare -a RESULTS=()

# time_run "<label>" <bytes> <cmd> [args...]   — PASS/FAIL + duration + MB/s
time_run() {
  local label="$1" bytes="$2"; shift 2
  echo "─── $label"
  echo "    \$ $*"
  local start end secs mbps
  start=$(NOW)
  if "$@" >"$TMP/out" 2>"$TMP/err"; then
    end=$(NOW)
    secs=$(awk -v s="$start" -v e="$end" 'BEGIN { d=e-s; if (d<0.001) d=0.001; printf "%.3f", d }')
    mbps=$(awk -v b="$bytes" -v s="$secs" 'BEGIN { printf "%.2f", (b/1000000)/s }')
    echo "    PASS  ${secs}s  ${mbps} MB/s"
    RESULTS+=("$(printf 'PASS  %-50s  %9ss  %9s MB/s' "$label" "$secs" "$mbps")")
  else
    local code=$?
    end=$(NOW)
    secs=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f", e-s }')
    echo "    FAIL (exit $code after ${secs}s)"
    sed 's/^/      /' "$TMP/err" | head -10
    RESULTS+=("$(printf 'FAIL  %-50s  %9ss' "$label" "$secs")")
  fi
  echo
}

# Build a source directory containing $FILE_COUNT files of $1 MB each.
# Echoes the directory path.
make_batch_dir() {
  local size_mb="$1" tag="$2"
  local dir="$TMP/src-${tag}-${size_mb}m"
  mkdir -p "$dir"
  local i
  for ((i=1; i<=FILE_COUNT; i++)); do
    dd if=/dev/zero of="$dir/file-$(printf '%03d' "$i").bin" \
       bs=1m count="$size_mb" status=none
  done
  echo "$dir"
}

# --- Size matrix: tsh az vs native az batch ops -----------------------------

for SIZE_MB in $SIZES_MB; do
  TOTAL_BYTES=$(( SIZE_MB * 1024 * 1024 * FILE_COUNT ))
  TOTAL_MB=$(( SIZE_MB * FILE_COUNT ))
  echo "######################################################################"
  echo "## ${FILE_COUNT} files x ${SIZE_MB} MB = ${TOTAL_MB} MB total"
  echo "######################################################################"

  TSH_SRC="$(make_batch_dir "$SIZE_MB" tsh)"
  NATIVE_SRC="$(make_batch_dir "$SIZE_MB" native)"
  TSH_DST="$TMP/dl-tsh-${SIZE_MB}m"
  NATIVE_DST="$TMP/dl-native-${SIZE_MB}m"
  mkdir -p "$TSH_DST" "$NATIVE_DST"

  TSH_PREFIX="tsh-batch-${SIZE_MB}m"
  NATIVE_PREFIX="native-batch-${SIZE_MB}m"

  echo "=== tsh az (Teleport + managed identity) — ${FILE_COUNT}x${SIZE_MB}M ==="
  time_run "[${FILE_COUNT}x${SIZE_MB}M] tsh az upload-batch"   "$TOTAL_BYTES" \
    tsh az storage blob upload-batch \
      --account-name "$ACCT" -d "$CTR" -s "$TSH_SRC" \
      --destination-path "$TSH_PREFIX" \
      --max-connections "$MAX_CONNECTIONS" \
      --auth-mode login --overwrite --no-progress

  time_run "[${FILE_COUNT}x${SIZE_MB}M] tsh az download-batch" "$TOTAL_BYTES" \
    tsh az storage blob download-batch \
      --account-name "$ACCT" -s "$CTR" -d "$TSH_DST" \
      --pattern "${TSH_PREFIX}/*" \
      --max-connections "$MAX_CONNECTIONS" \
      --auth-mode login --no-progress

  echo "=== native az (direct + Entra ID user) — ${FILE_COUNT}x${SIZE_MB}M ==="
  time_run "[${FILE_COUNT}x${SIZE_MB}M] native az upload-batch"   "$TOTAL_BYTES" \
    az storage blob upload-batch \
      --account-name "$ACCT" -d "$CTR" -s "$NATIVE_SRC" \
      --destination-path "$NATIVE_PREFIX" \
      --max-connections "$MAX_CONNECTIONS" \
      --auth-mode login --overwrite --no-progress

  time_run "[${FILE_COUNT}x${SIZE_MB}M] native az download-batch" "$TOTAL_BYTES" \
    az storage blob download-batch \
      --account-name "$ACCT" -s "$CTR" -d "$NATIVE_DST" \
      --pattern "${NATIVE_PREFIX}/*" \
      --max-connections "$MAX_CONNECTIONS" \
      --auth-mode login --no-progress

  # Verify download counts match what we uploaded.
  TSH_DL_COUNT=$(find "$TSH_DST" -type f | wc -l | tr -d ' ')
  NATIVE_DL_COUNT=$(find "$NATIVE_DST" -type f | wc -l | tr -d ' ')
  echo "Downloaded counts — tsh: ${TSH_DL_COUNT}/${FILE_COUNT}, native: ${NATIVE_DL_COUNT}/${FILE_COUNT}"
  if [ "$TSH_DL_COUNT" -eq "$FILE_COUNT" ]; then
    RESULTS+=("PASS  [${FILE_COUNT}x${SIZE_MB}M] tsh download count = ${FILE_COUNT}")
  else
    RESULTS+=("FAIL  [${FILE_COUNT}x${SIZE_MB}M] tsh download count = ${TSH_DL_COUNT}/${FILE_COUNT}")
  fi
  if [ "$NATIVE_DL_COUNT" -eq "$FILE_COUNT" ]; then
    RESULTS+=("PASS  [${FILE_COUNT}x${SIZE_MB}M] native download count = ${FILE_COUNT}")
  else
    RESULTS+=("FAIL  [${FILE_COUNT}x${SIZE_MB}M] native download count = ${NATIVE_DL_COUNT}/${FILE_COUNT}")
  fi
  echo

  # Drop sources/downloads between sizes so we don't pile up disk usage.
  rm -rf "$TSH_SRC" "$NATIVE_SRC" "$TSH_DST" "$NATIVE_DST"
done

# --- Summary ----------------------------------------------------------------

echo "=== Summary ==="
for r in "${RESULTS[@]}"; do printf '  %s\n' "$r"; done
echo
echo "Cleanup (optional) — remove uploaded batch prefixes:"
for SIZE_MB in $SIZES_MB; do
  echo "  az storage blob delete-batch --account-name $ACCT -s $CTR --pattern 'tsh-batch-${SIZE_MB}m/*'    --auth-mode login"
  echo "  az storage blob delete-batch --account-name $ACCT -s $CTR --pattern 'native-batch-${SIZE_MB}m/*' --auth-mode login"
done
