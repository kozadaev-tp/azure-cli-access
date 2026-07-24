#!/usr/bin/env bash
# Verify Teleport's Azure CLI proxy (`tsh az`) against control- and data-plane
# operations, and run a size matrix (1 MB, 100 MB, 500 MB) comparing tsh az
# (Teleport-proxied) against native az (direct, your Entra ID user).
#
# Usage:
#   tsh apps login azure-cli --azure-identity teleport-azure
#   az login
#   ./test-azure-cli.sh
#
# Optional:
#   TF_DIR=/path/to/terraform ./test-azure-cli.sh
#   SIZES_MB="1 100 500 1024" ./test-azure-cli.sh
#   ./test-azure-cli.sh grant-role     # one-shot: give your AAD user blob role

set -uo pipefail

TF_DIR="${TF_DIR:-$(dirname "$0")/terraform}"
SIZES_MB="${SIZES_MB:-1 100 500}"

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

grant_blob_role() {
  local me scope
  me="$(az ad signed-in-user show --query id -o tsv)"
  scope="$(az storage account show -n "$ACCT" -g "$RG" --query id -o tsv)"
  echo "Granting Storage Blob Data Contributor on $ACCT to AAD user $me"
  az role assignment create \
    --assignee-object-id "$me" \
    --assignee-principal-type User \
    --role "Storage Blob Data Contributor" \
    --scope "$scope"
}

if [ "${1:-}" = "grant-role" ]; then
  grant_blob_role
  exit 0
fi

az account show >/dev/null 2>&1 || { echo "Native 'az' not logged in. Run: az login" >&2; exit 2; }

# Sub-second timer
if command -v gdate >/dev/null; then
  NOW() { gdate +%s.%N; }
elif date +%s.%N 2>/dev/null | grep -q '\.'; then
  NOW() { date +%s.%N; }
else
  NOW() { date +%s; }
fi

echo "Storage account: $ACCT"
echo "Container:       $CTR"
echo "Resource group:  $RG"
echo "Sizes (MB):      $SIZES_MB"
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "hello from teleport $(uuidgen 2>/dev/null || echo $$)" > "$TMP/hello.txt"

declare -a RESULTS=()

# run "<label>" <cmd> [args...]   — PASS/FAIL only, no timing
run() {
  local label="$1"; shift
  echo "─── $label"
  echo "    \$ $*"
  if "$@" >"$TMP/out" 2>"$TMP/err"; then
    echo "    PASS"
    RESULTS+=("PASS  $label")
  else
    local code=$?
    echo "    FAIL (exit $code)"
    sed 's/^/      /' "$TMP/err" | head -10
    RESULTS+=("FAIL  $label")
  fi
  echo
}

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
    RESULTS+=("$(printf 'PASS  %-40s  %9ss  %9s MB/s' "$label" "$secs" "$mbps")")
  else
    local code=$?
    end=$(NOW)
    secs=$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f", e-s }')
    echo "    FAIL (exit $code after ${secs}s)"
    sed 's/^/      /' "$TMP/err" | head -10
    RESULTS+=("$(printf 'FAIL  %-40s  %9ss' "$label" "$secs")")
  fi
  echo
}

# --- Control plane and AAD data-plane sanity checks ------------------------

echo "=== Control plane (ARM, *.management.azure.com) ==="
run "account list"             tsh az storage account list
run "account show"             tsh az storage account show -n "$ACCT"
run "container list (AAD)"     tsh az storage container list --account-name "$ACCT" --auth-mode login
run "account keys list"        tsh az storage account keys list -g "$RG" -n "$ACCT"

echo "=== Data plane via tsh az + AAD (*.blob.core.windows.net) ==="
# --- Size matrix: tsh az vs native az ---------------------------------------

for SIZE_MB in $SIZES_MB; do
  BYTES=$(( SIZE_MB * 1024 * 1024 ))
  SRC="$TMP/src-${SIZE_MB}m.bin"
  echo "######################################################################"
  echo "## ${SIZE_MB} MB"
  echo "######################################################################"
  echo "Creating ${SIZE_MB} MB sparse source file at $SRC"
  dd if=/dev/zero of="$SRC" bs=1m count="$SIZE_MB" status=none

  echo "=== tsh az (Teleport + managed identity) — ${SIZE_MB} MB ==="
  time_run "[${SIZE_MB}M] tsh az upload"   "$BYTES" \
    tsh az storage blob upload   --account-name "$ACCT" -c "$CTR" \
      -f "$SRC" -n "tsh-${SIZE_MB}m.bin" --auth-mode login --overwrite
  time_run "[${SIZE_MB}M] tsh az download" "$BYTES" \
    tsh az storage blob download --account-name "$ACCT" -c "$CTR" \
      -f "$TMP/tsh-dl-${SIZE_MB}m.bin" -n "tsh-${SIZE_MB}m.bin" --auth-mode login

  echo "=== native az (direct + Entra ID user) — ${SIZE_MB} MB ==="
  time_run "[${SIZE_MB}M] native az upload"   "$BYTES" \
    az storage blob upload   --account-name "$ACCT" -c "$CTR" \
      -f "$SRC" -n "native-${SIZE_MB}m.bin" --auth-mode login --overwrite
  time_run "[${SIZE_MB}M] native az download" "$BYTES" \
    az storage blob download --account-name "$ACCT" -c "$CTR" \
      -f "$TMP/native-dl-${SIZE_MB}m.bin" -n "native-${SIZE_MB}m.bin" --auth-mode login

  # Drop the local source between sizes so we don't pile up disk usage.
  rm -f "$SRC" "$TMP/tsh-dl-${SIZE_MB}m.bin" "$TMP/native-dl-${SIZE_MB}m.bin"
done

# --- Summary ----------------------------------------------------------------

echo "=== Summary ==="
for r in "${RESULTS[@]}"; do printf '  %s\n' "$r"; done
echo
echo "Cleanup (optional):"
for SIZE_MB in $SIZES_MB; do
  echo "  az storage blob delete --account-name $ACCT -c $CTR -n tsh-${SIZE_MB}m.bin    --auth-mode login"
  echo "  az storage blob delete --account-name $ACCT -c $CTR -n native-${SIZE_MB}m.bin --auth-mode login"
done
