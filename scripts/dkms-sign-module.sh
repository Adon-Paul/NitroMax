#!/bin/bash
set -e

KERNEL_VER="$1"
MODULE_PATH="$2"
KEY_DIR="/var/lib/damx/secureboot"
PRIV_KEY="${KEY_DIR}/DAMX-MOK.priv"
DER_CERT="${KEY_DIR}/DAMX-MOK.der"
SIGN_FILE="/lib/modules/${KERNEL_VER}/build/scripts/sign-file"

if [ -z "$KERNEL_VER" ] || [ -z "$MODULE_PATH" ]; then
    echo "Usage: $0 <kernel_version> <module_path>"
    exit 1
fi

if [ ! -f "$MODULE_PATH" ]; then
    echo "Module not found at $MODULE_PATH, skipping signing."
    exit 0
fi

# Sign unconditionally if keys and sign-file exist
if [ -x "$SIGN_FILE" ] && [ -f "$PRIV_KEY" ] && [ -f "$DER_CERT" ]; then
    echo "Signing kernel module $MODULE_PATH for kernel $KERNEL_VER using DAMX MOK..."
    "$SIGN_FILE" sha256 "$PRIV_KEY" "$DER_CERT" "$MODULE_PATH"
    echo "Successfully signed $MODULE_PATH"
else
    echo "Kernel signing tool or keys not available ($SIGN_FILE, $PRIV_KEY, $DER_CERT). Skipping signing."
fi
