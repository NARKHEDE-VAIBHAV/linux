#!/bin/bash
# followup_gpg_check.sh — run on the VM as root after the first script
# flagged "no gpg-pubkey trust anchor imported".
#
# Goal: disambiguate whether that means tdnf genuinely installs packages
# with zero signature verification, or whether it verifies per-transaction
# against gpgkey= in the repo file without persisting to the rpm db.
# Ends with a compact VULNERABLE / NOT VULNERABLE verdict.

set -uo pipefail
ISSUES=()

echo "=== A. Repo file gpgcheck/gpgkey settings ==="
repo_bad=0
for f in /etc/yum.repos.d/*.repo; do
    [ -f "$f" ] || continue
    val=$(grep -E "^\s*gpgcheck\s*=" "$f" | tail -1 | cut -d= -f2 | tr -d ' ')
    key=$(grep -E "^\s*gpgkey\s*=" "$f" | tail -1 | cut -d= -f2- | tr -d ' ')
    if [ "$val" = "0" ]; then
        echo "  [BAD] $f -> gpgcheck=0"
        repo_bad=1
    elif [ -z "$key" ] && [ "$val" != "0" ]; then
        echo "  [WARN] $f -> gpgcheck=$val but no gpgkey= set (nothing to verify against)"
        repo_bad=1
    else
        echo "  [OK]   $f -> gpgcheck=$val, gpgkey=$key"
    fi
done
[ "$repo_bad" = 1 ] && ISSUES+=("repo config disables or cannot perform gpg verification")
echo

echo "=== B. tdnf.conf global gpgcheck ==="
gval=$(grep -E "^\s*gpgcheck\s*=" /etc/tdnf/tdnf.conf 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
echo "  gpgcheck=${gval:-<unset>}"
[ "$gval" = "0" ] && ISSUES+=("tdnf.conf global gpgcheck=0")
echo

echo "=== C. Live transaction test (download-only, no changes made) ==="
SAMPLE_PKG=$(rpm -qa --qf '%{NAME}\n' | grep -vE '^gpg-pubkey' | head -1)
echo "  sample package: $SAMPLE_PKG"
OUT=$(tdnf reinstall -y --downloadonly --downloaddir=/tmp/tdnf-gpg-test "$SAMPLE_PKG" 2>&1)
echo "$OUT" | sed 's/^/  /'
rm -rf /tmp/tdnf-gpg-test

if echo "$OUT" | grep -qiE "gpg check|signature|nokey|untrusted"; then
    echo
    echo "  [OK]   tdnf output references signature/GPG checking"
else
    echo
    echo "  [BAD]  tdnf transaction produced no signature/GPG mention at all"
    ISSUES+=("live tdnf transaction shows no signature verification activity")
fi
echo

echo "===================================================================="
echo "VERDICT"
echo "===================================================================="
if [ "${#ISSUES[@]}" -eq 0 ]; then
    echo "  RESULT: NOT VULNERABLE (tdnf appears to verify signatures on installs)"
else
    echo "  RESULT: VULNERABLE (package installs are not being signature-verified)"
    echo "  Reasons:"
    for i in "${ISSUES[@]}"; do
        echo "    - $i"
    done
fi
echo
echo "  Still does NOT confirm/deny the original image BUILD's GPG enforcement"
echo "  (VALIDATE_IMAGE_GPG) — only Microsoft can answer that part."
echo "===================================================================="
