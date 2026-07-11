#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
DATABASE_PATH="${1:-}"

if [[ -z "$DATABASE_PATH" ]]; then
    print -u2 "用法：zsh Scripts/audit_album_name_cleaning.sh <扫描快照.db>"
    exit 64
fi

AUDIT_BINARY="${TMPDIR:-/tmp/}CoverDropAlbumNameCleaningAudit"

xcrun swiftc \
    "$PROJECT_ROOT/CoverDrop/Domain/Models/AlbumScanRecord.swift" \
    "$PROJECT_ROOT/CoverDrop/Domain/Policies/AlbumNameCleaning.swift" \
    "$PROJECT_ROOT/CoverDrop/Domain/Policies/AlbumDisplayNameCleaning.swift" \
    "$PROJECT_ROOT/Scripts/AlbumNameCleaningAudit.swift" \
    -o "$AUDIT_BINARY"

"$AUDIT_BINARY" "$DATABASE_PATH"
