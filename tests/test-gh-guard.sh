#!/usr/bin/env bash
# Test the gh guardrail wrapper (src/gh-guard.sh) without Docker.
#
# The guard runs /usr/bin/gh only on the allow path; on a host without gh that
# exec fails with 127. Blocked paths exit 1 with a "[SYSTEM BLOCK]" message.
# So the test treats "exit code != 1" as "not blocked by the guard".

set -u

GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src/gh-guard.sh"

pass=0
fail=0

# expect_blocked <desc> <args...>
expect_blocked() {
    local desc="$1"; shift
    local out rc
    out="$(GH_TOKEN=x bash "$GUARD" "$@" 2>&1)"
    rc=$?
    if [ "$rc" -eq 1 ] && [[ "$out" == *"[SYSTEM BLOCK]"* ]]; then
        echo "PASS  $desc"
        pass=$((pass+1))
    else
        echo "FAIL  $desc (rc=$rc, out=$out)"
        fail=$((fail+1))
    fi
}

# expect_allowed <desc> <args...>
# The guard runs /usr/bin/gh on the allow path; blocked paths exit 1 with a
# "[SYSTEM BLOCK]" message. gh itself may also exit 1 (e.g. 401 with a fake
# token), so the distinguishing signal is the absence of "[SYSTEM BLOCK]".
expect_allowed() {
    local desc="$1"; shift
    local out rc
    out="$(GH_TOKEN=x bash "$GUARD" "$@" 2>&1)"
    rc=$?
    if [[ "$out" != *"[SYSTEM BLOCK]"* ]]; then
        echo "PASS  $desc"
        pass=$((pass+1))
    else
        echo "FAIL  $desc (rc=$rc, out=$out)"
        fail=$((fail+1))
    fi
}

# --- command-level deny list (D2) -------------------------------------------
expect_blocked "alias set is blocked"        alias set foo "echo hi"
expect_blocked "extension install is blocked" extension install owner/repo
expect_blocked "gist create is blocked"      gist create file.txt
expect_blocked "copilot suggest is blocked"  copilot suggest "hello"
expect_blocked "codespace create is blocked" codespace create

# --- gh api read-only enforcement (D2) --------------------------------------
expect_blocked "api POST method is blocked"      api -X POST repos/o/r
expect_blocked "api --method=DELETE is blocked"  api --method=DELETE repos/o/r
expect_blocked "api -XDELETE compact is blocked" api -XDELETE repos/o/r
expect_blocked "api PUT (long flag) is blocked"  api --method PUT repos/o/r
expect_blocked "api Authorization header blocked" api -H "Authorization: Bearer x" /user
expect_blocked "api Cookie header blocked"       api --header "Cookie: a=b" /user
expect_blocked "api --hostname blocked"          api --hostname evil /user
expect_blocked "api body field blocked"          api graphql -f query='{ viewer { login } }'
expect_blocked "api --input blocked"             api --input body.json /user

# --- gh api read-only allow path (D2) ---------------------------------------
expect_allowed "api GET is allowed"            api repos/o/r
expect_allowed "api GET --jq is allowed"       api repos/o/r --jq '.name'
expect_allowed "api GET with safe header"      api -H "Accept: application/vnd.github+json" /user
expect_allowed "api explicit GET is allowed"   api --method GET /user

# --- pre-existing behaviour must not regress ---------------------------------
expect_blocked "auth login still blocked"       auth login
expect_blocked "repo delete still blocked"      repo delete o/r
expect_blocked "secret list still blocked"      secret list
expect_blocked "config set still blocked"       config set git_protocol ssh
expect_blocked "ssh-key add still blocked"      ssh-key add ~/.ssh/id.pub

echo
echo "gh-guard tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
