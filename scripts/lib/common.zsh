# Sourced by the scripts in scripts/. Sets ROOT, moves there, and defines shared helpers.

ROOT=${0:A:h:h:h}  # $0 is this file when sourced
cd "$ROOT"

# Loads PLAIN_DEVICE from the environment or scripts/local.env, or stops with a clear message.
require_device() {
  if [[ -z "${PLAIN_DEVICE:-}" && -f scripts/local.env ]]; then
    source scripts/local.env
  fi
  if [[ -z "${PLAIN_DEVICE:-}" || "$PLAIN_DEVICE" == 00000000-* ]]; then
    print -u2 "error: no device. Set PLAIN_DEVICE or copy scripts/local.env.example to scripts/local.env."
    exit 1
  fi
}

# Returns 0 when the device is reachable and unlocked; otherwise prints why and returns 2.
# devicectl's own timeout keeps it from hanging on a sleeping or absent device.
check_device_unlocked() {
  local json
  if ! json=$(xcrun devicectl device info lockState --device "$PLAIN_DEVICE" --timeout 30 -q -j - 2>/dev/null); then
    print -u2 "the device is not reachable. Wake it, keep it on the same Wi-Fi (or plug it in), and retry."
    return 2
  fi
  if [[ $(jq -r '.result.passcodeRequired' <<<"$json") != false ]]; then
    print -u2 "the device is locked. Unlock it (and set Auto-Lock to Never while measuring), then retry."
    return 2
  fi
}
