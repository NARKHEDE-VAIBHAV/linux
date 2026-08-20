#!/bin/bash
# followup_gpg_check.sh — run on the VM as root after the first script
# flagged "no gpg-pubkey trust anchor imported".
#
# Goal: figure out whether that means tdnf genuinely installs packages
# with zero signature verification, or whether it verifies per-transaction
# against gpgkey= in the repo file without persisting to the rpm db.

echo "=== A. What gpgkey= do the repo files actually point to? ==="
for f in /etc/yum.repos.d/*.repo; do
    [ -f "$f" ] || continue
    echo "--- $f ---"
    grep -E "^\s*(baseurl|gpgkey|gpgcheck)\s*=" "$f"
    echo
done

echo "=== B. tdnf.conf full contents (global defaults) ==="
cat /etc/tdnf/tdnf.conf 2>/dev/null
echo

echo "=== C. Live test: does tdnf actually enforce/prompt for signature on a real transaction? ==="
echo "Doing a DRY RUN reinstall of a small already-installed package to observe tdnf's own behavior."
echo "(Nothing is changed — using --downloadonly avoids modifying the system.)"
SAMPLE_PKG=$(rpm -qa --qf '%{NAME}\n' | grep -vE '^gpg-pubkey' | head -1)
echo "Using sample package: $SAMPLE_PKG"
echo
tdnf reinstall -y --downloadonly --downloaddir=/tmp/tdnf-gpg-test "$SAMPLE_PKG" 2>&1
echo
echo "Look for: 'GPG check', 'signature', 'NOKEY', 'skipping gpg check', or any mention of"
echo "verification in the output above. Its presence/absence is the real answer, not just"
echo "the empty gpg-pubkey list."
rm -rf /tmp/tdnf-gpg-test

echo
echo "=== D. rpm db keyring path sanity check ==="
echo "Some systems keep an alternate keyring path — confirm rpm is even looking where you think:"
rpm --eval '%{_dbpath}'
rpm -E '%{__gpg}' 2>/dev/null
