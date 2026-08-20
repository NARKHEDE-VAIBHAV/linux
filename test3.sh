#!/bin/bash
# gpg_positive_control_test.sh
#
# Run this ON the Azure Linux VM as root.
#
# WHAT THIS DOES (and why it's different from grepping stdout):
#   1. Confirms the repo config on disk (gpgcheck=, gpgkey=, key file exists).
#   2. Downloads a REAL signed package from the configured repo.
#   3. SANITY CHECK: installs the untouched copy into a scratch installroot,
#      to prove the install path itself works.
#   4. TAMPERS with a copy of the same RPM (flips bytes in the payload,
#      which invalidates the signature/digest without touching the RPM
#      header enough to make tdnf refuse to even parse it).
#   5. Points tdnf at a local file:// repo containing ONLY the tampered RPM,
#      with gpgcheck=1 forced, and tries to install it into a fresh
#      scratch installroot.
#   6. Verdict is based on the EXIT CODE / actual install result of that
#      tampered install attempt — not on keyword-grepping stdout. If tdnf
#      installs a package whose payload doesn't match its signed digest,
#      that is unambiguous proof verification is not enforced.
#
# Nothing here touches your real system: everything installs into a
# throwaway --installroot under /tmp, and it's removed at the end.

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] This script must be run as root (use: sudo bash $0)."
    echo "        Current user: $(whoami), uid=$(id -u)"
    exit 1
fi

WORKDIR=$(mktemp -d /tmp/gpgtest.XXXXXX)
INSTALLROOT_GOOD="$WORKDIR/root-good"
INSTALLROOT_BAD="$WORKDIR/root-bad"
DL_DIR="$WORKDIR/download"
TAMPER_REPO_DIR="$WORKDIR/tamper-repo"
mkdir -p "$INSTALLROOT_GOOD" "$INSTALLROOT_BAD" "$DL_DIR" "$TAMPER_REPO_DIR"

ISSUES=()
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "===================================================================="
echo "STEP 1: Repo config on disk (ground truth, not inference)"
echo "===================================================================="
for f in /etc/yum.repos.d/*.repo; do
    [ -f "$f" ] || continue
    echo "-- $f --"
    grep -E "^\s*(gpgcheck|repo_gpgcheck|gpgkey|enabled)\s*=" "$f" | sed 's/^/   /'
done
echo
gval=$(grep -E "^\s*gpgcheck\s*=" /etc/tdnf/tdnf.conf 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
echo "tdnf.conf global gpgcheck=${gval:-<unset>}"
echo

echo "===================================================================="
echo "STEP 2: Download a real signed package to test with"
echo "===================================================================="
SAMPLE_PKG=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null | grep -vE '^gpg-pubkey' | sort -R | head -1)
if [ -z "$SAMPLE_PKG" ]; then
    echo "  [ERROR] Could not find any installed package to sample. Aborting."
    exit 2
fi
echo "  Using package: $SAMPLE_PKG"

DL_LOG="$WORKDIR/download.log"

# --downloaddir requires --downloadonly on this tdnf version, regardless
# of subcommand (download vs reinstall). Try both forms with --downloadonly.
if ! tdnf download -y --downloadonly --downloaddir="$DL_DIR" "$SAMPLE_PKG" >"$DL_LOG" 2>&1; then
    tdnf reinstall -y --downloadonly --downloaddir="$DL_DIR" "$SAMPLE_PKG" >>"$DL_LOG" 2>&1
fi

RPM_FILE=$(find "$DL_DIR" -name "*.rpm" | head -1)
if [ -z "$RPM_FILE" ]; then
    echo "  [ERROR] Failed to download a package to test with. Log:"
    sed 's/^/    /' "$DL_LOG"
    exit 2
fi
echo "  Downloaded: $RPM_FILE"
echo

echo "===================================================================="
echo "STEP 3: Sanity check — install the UNTOUCHED package (should work)"
echo "===================================================================="
GOOD_OUT=$(tdnf install -y --installroot="$INSTALLROOT_GOOD" "$RPM_FILE" 2>&1)
GOOD_RC=$?
echo "$GOOD_OUT" | sed 's/^/  /'
if [ "$GOOD_RC" -ne 0 ]; then
    echo "  [WARN] Sanity install of the untouched RPM failed for an unrelated"
    echo "         reason (deps, installroot issues, etc). Results below may"
    echo "         be inconclusive — inspect the log above."
    SANITY_OK=0
else
    echo "  [OK] Untouched package installs fine — install path itself works."
    SANITY_OK=1
fi
echo

echo "===================================================================="
echo "STEP 4: Tamper with a COPY of the RPM payload"
echo "===================================================================="
TAMPERED_RPM="$TAMPER_REPO_DIR/$(basename "$RPM_FILE")"
cp "$RPM_FILE" "$TAMPERED_RPM"

# Flip bytes well past the RPM lead/signature header (first ~4KB is
# typically lead+signature+some header) so we're corrupting payload data,
# not just making the file unparseable garbage.
SIZE=$(stat -c%s "$TAMPERED_RPM")
OFFSET=$(( SIZE > 8192 ? 8192 : SIZE / 2 ))
printf '\xDE\xAD\xBE\xEF' | dd of="$TAMPERED_RPM" bs=1 seek="$OFFSET" count=4 conv=notrunc status=none
echo "  Flipped 4 bytes at offset $OFFSET in $(basename "$TAMPERED_RPM")"
echo "  (original untouched, this is a corrupted COPY only)"
echo

echo "===================================================================="
echo "STEP 5: Build a local repo containing ONLY the tampered RPM"
echo "===================================================================="
if command -v createrepo_c >/dev/null 2>&1; then
    createrepo_c "$TAMPER_REPO_DIR" >"$WORKDIR/createrepo.log" 2>&1
    REPO_MODE="metadata"
else
    echo "  [INFO] createrepo_c not available — will install the tampered"
    echo "         RPM file directly (still exercises tdnf's RPM-level"
    echo "         signature/digest check, just not repo metadata checks)."
    REPO_MODE="direct"
fi
echo

echo "===================================================================="
echo "STEP 6: Attempt to install the TAMPERED package (this is the test)"
echo "===================================================================="
if [ "$REPO_MODE" = "metadata" ]; then
    BAD_OUT=$(tdnf --installroot="$INSTALLROOT_BAD" \
        --repofrompath=tampertest,"$TAMPER_REPO_DIR" \
        --repo=tampertest \
        --setopt=tampertest.gpgcheck=1 \
        install -y "$SAMPLE_PKG" 2>&1)
    BAD_RC=$?
else
    BAD_OUT=$(tdnf install -y --installroot="$INSTALLROOT_BAD" "$TAMPERED_RPM" 2>&1)
    BAD_RC=$?
fi
echo "$BAD_OUT" | sed 's/^/  /'
echo "  (exit code: $BAD_RC)"
echo

# Did the tampered package actually land in the scratch installroot's rpmdb?
INSTALLED_IN_BAD=0
if rpm --root="$INSTALLROOT_BAD" -q "$SAMPLE_PKG" >/dev/null 2>&1; then
    INSTALLED_IN_BAD=1
fi

echo "===================================================================="
echo "VERDICT"
echo "===================================================================="
if [ "$INSTALLED_IN_BAD" -eq 1 ]; then
    echo "  RESULT: VULNERABLE"
elif [ "$BAD_RC" -ne 0 ]; then
    echo "  RESULT: NOT VULNERABLE"
    echo "  tdnf refused to install the tampered package (exit $BAD_RC)."
    echo "  Signature/digest verification is being enforced on this system."
    if [ "$SANITY_OK" -ne 1 ]; then
        echo "  NOTE: the sanity install in Step 3 also failed, so treat this"

    fi
else
    echo "  RESULT: INCONCLUSIVE"
fi
echo "===================================================================="
