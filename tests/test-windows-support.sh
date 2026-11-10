#!/usr/bin/env bash
# Guardrails for the Windows/WSL2 installation path.
#
# Native PowerShell/Git Bash/MSYS2 is not supported: the host workflow is GNU
# make + Bash and assumes Unix paths, UIDs, and file modes. Windows users run it
# from WSL2 with Docker Desktop's WSL integration. This test checks that the
# repo keeps the line-ending policy and the documentation/doctor guidance in
# place.
#
# Run from anywhere: bash tests/test-windows-support.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0
fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
has()   { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else no "$3"; fi; }

# --- line endings the checkout cannot silently break ------------------------
GITATTR="$(cat "$REPO_ROOT/.gitattributes" 2>/dev/null || true)"
has "text=auto eol=lf" "$GITATTR" ".gitattributes forces LF line endings"

if command -v git >/dev/null 2>&1; then
    ATTR="$(git -C "$REPO_ROOT" check-attr eol -- bin/pictl Makefile 2>/dev/null || true)"
    has "bin/pictl: eol: lf" "$ATTR" "bin/pictl is checked out with LF"
    has "Makefile: eol: lf" "$ATTR" "Makefile is checked out with LF"
else
    echo "SKIP  git check-attr (git is not installed here)"
fi

# --- documentation names the supported path --------------------------------
README="$(cat "$REPO_ROOT/README.md" 2>/dev/null || true)"
has "WSL2" "$README" "README points Windows users at WSL2"
has "MSYS2 are not supported" "$README" "README rules out native Windows shells"

USAGE="$(cat "$REPO_ROOT/USAGE.md" 2>/dev/null || true)"
has "Windows: use WSL2" "$USAGE" "USAGE has a Windows/WSL2 section"
has "Docker Desktop" "$USAGE" "USAGE requires Docker Desktop integration"
has "sudo apt install -y make git openssh-client openssl curl" "$USAGE" \
    "USAGE lists the WSL host packages"
has "/mnt/c/" "$USAGE" "USAGE warns about Windows-drive mounts"
has "tmux" "$USAGE" "USAGE mentions tmux for background sessions"
has "keychain:" "$USAGE" "USAGE notes the macOS-only keychain source"
has ".gitattributes" "$USAGE" "USAGE explains the LF checkout policy"

# --- doctor diagnoses the unsupported shell --------------------------------
DOCTOR="$(cat "$REPO_ROOT/scripts/doctor.sh" 2>/dev/null || true)"
has "native Windows shell detected" "$DOCTOR" "doctor warns on native Windows shells"
has "CRLF line endings" "$DOCTOR" "doctor detects CRLF line endings"

echo
echo "windows support tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
