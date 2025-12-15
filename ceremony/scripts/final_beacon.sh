#!/usr/bin/env bash
set -euo pipefail

CIRCUIT_NAME="giftcard_merkle"
ROOT_DIR="$(cd "$(dirname "$0")/../../" && pwd)"
OUT="$ROOT_DIR/ceremony/output"
R1CS="$ROOT_DIR/circuits/build/${CIRCUIT_NAME}.r1cs"
PTAU="$ROOT_DIR/circuits/ptau/powersOfTau28_hez_final_18.ptau"

# -----------------------------
# Input: precommitted drand round
# -----------------------------
DRAND_ROUND="${1:-}"
if [ -z "${DRAND_ROUND}" ]; then
  echo "Usage: $0 <drand_round>" >&2
  echo "ERROR: drand_round is required and must be precommitted in advance." >&2
  exit 1
fi
if ! [[ "$DRAND_ROUND" =~ ^[0-9]+$ ]]; then
  echo "ERROR: drand_round must be numeric. Got: ${DRAND_ROUND}" >&2
  exit 1
fi

FINAL_ZKEY="$OUT/${CIRCUIT_NAME}_final.zkey"
FINAL_VKEY="$OUT/${CIRCUIT_NAME}_verification_key.json"

# -----------------------------
# Idempotency / safety
# -----------------------------
if [ -f "$FINAL_ZKEY" ]; then
  echo "✅ Final zkey already exists at: $FINAL_ZKEY"
  echo "Refusing to re-finalize. (No-op)"
  exit 0
fi

# -----------------------------
# Preconditions
# -----------------------------
mkdir -p "$OUT"

if [ ! -f "$R1CS" ]; then
  echo "ERROR: Missing R1CS at $R1CS" >&2
  exit 1
fi

if [ ! -f "$PTAU" ]; then
  echo "ERROR: Missing PTAU at $PTAU" >&2
  exit 1
fi

# Find latest non-final zkey in the ceremony chain
LAST_ZKEY="$(ls "$OUT"/${CIRCUIT_NAME}_*.zkey 2>/dev/null | grep -v "_final.zkey" | sort | tail -n 1 || true)"
if [ -z "${LAST_ZKEY:-}" ]; then
  echo "ERROR: No intermediate zkey found in ${OUT} (expected ${CIRCUIT_NAME}_XXXX.zkey)" >&2
  exit 1
fi

echo "Using last chain zkey: $LAST_ZKEY"

# -----------------------------
# Fetch public randomness (drand) - robust for CI
# -----------------------------
DRAND_URL="https://api.drand.sh/public/${DRAND_ROUND}"

echo "Fetching public randomness from drand round ${DRAND_ROUND}..."
RESPONSE="$(curl -sS -L \
  --retry 5 --retry-all-errors --retry-delay 2 \
  --connect-timeout 10 --max-time 20 \
  "$DRAND_URL" || true)"

# If empty response, don't fail the workflow; let schedule retry later.
if [ -z "${RESPONSE:-}" ]; then
  echo "⚠️ Empty response from drand. Round may not be available yet or transient network issue."
  echo "No-op; try again on next scheduled run."
  exit 0
fi

# If response indicates "future" or not ready, exit 0 so schedule can retry.
if echo "$RESPONSE" | grep -qiE 'future|Requested future beacon|not found'; then
  echo "ℹ️ Drand round ${DRAND_ROUND} not available yet (per response)."
  echo "No-op; try again on next scheduled run."
  exit 0
fi

# Extract randomness from JSON safely (avoid JSONDecodeError)
RANDOMNESS="$(python3 - << 'PY' <<< "$RESPONSE"
import sys, json
raw = sys.stdin.read().strip()
try:
    data = json.loads(raw)
    print(data.get("randomness","") or "")
except Exception:
    print("")
PY
)"

if [ -z "${RANDOMNESS:-}" ]; then
  echo "⚠️ Drand response did not contain valid JSON randomness."
  echo "Raw response (first 400 chars):"
  echo "${RESPONSE:0:400}"
  echo "No-op; try again on next scheduled run."
  exit 0
fi

echo "drand randomness (hex): $RANDOMNESS"

# Derive beacon hash from the public randomness
BEACON_HASH="$(echo -n "$RANDOMNESS" | sha256sum | cut -d' ' -f1)"
echo "Derived beacon hash (sha256 of drand randomness): $BEACON_HASH"

# -----------------------------
# Apply beacon
# -----------------------------
echo "Running snarkjs zkey beacon..."
snarkjs zkey beacon "$LAST_ZKEY" "$FINAL_ZKEY" "$BEACON_HASH" 10

echo "Computing SHA-256 checksum of final zkey..."
sha256sum "$FINAL_ZKEY" > "$FINAL_ZKEY.sha256"

echo "Verifying final zkey against R1CS and PTAU..."
snarkjs zkey verify "$R1CS" "$PTAU" "$FINAL_ZKEY"

# Export verification key (typical)
echo "Exporting verification key..."
snarkjs zkey export verificationkey "$FINAL_ZKEY" "$FINAL_VKEY"
sha256sum "$FINAL_VKEY" > "$FINAL_VKEY.sha256"

echo "✅ Final beacon completed successfully."
echo "Final zkey path:        $FINAL_ZKEY"
echo "Final zkey sha256 line: $(cat "$FINAL_ZKEY.sha256")"
echo "Verification key path:  $FINAL_VKEY"
echo "Verification key sha256 line: $(cat "$FINAL_VKEY.sha256")"
