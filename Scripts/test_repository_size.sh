#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-repository-size.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$TEMP_DIR/Scripts"
cp "$ROOT_DIR/Scripts/check_repository_size.sh" "$TEMP_DIR/Scripts/"
git -C "$TEMP_DIR" init --quiet
printf 'small source file\n' > "$TEMP_DIR/source.txt"
git -C "$TEMP_DIR" add source.txt Scripts/check_repository_size.sh

"$TEMP_DIR/Scripts/check_repository_size.sh" >/dev/null

dd if=/dev/zero of="$TEMP_DIR/untracked.bin" bs=1024 count=2049 2>/dev/null
"$TEMP_DIR/Scripts/check_repository_size.sh" >/dev/null
git -C "$TEMP_DIR" add untracked.bin
if "$TEMP_DIR/Scripts/check_repository_size.sh" >"$TEMP_DIR/large.log" 2>&1; then
  printf 'ERROR: oversized tracked file was accepted.\n' >&2
  exit 1
fi
grep -Fq 'tracked file exceeds 2097152 bytes: untracked.bin' "$TEMP_DIR/large.log"

git -C "$TEMP_DIR" rm --cached --quiet untracked.bin
printf 'release artifact\n' > "$TEMP_DIR/CodexBar-0.0.0.zip"
git -C "$TEMP_DIR" add CodexBar-0.0.0.zip
if "$TEMP_DIR/Scripts/check_repository_size.sh" >"$TEMP_DIR/artifact.log" 2>&1; then
  printf 'ERROR: tracked release artifact was accepted.\n' >&2
  exit 1
fi
grep -Fq 'generated artifact is tracked: CodexBar-0.0.0.zip' "$TEMP_DIR/artifact.log"

printf 'Repository size tests passed.\n'
