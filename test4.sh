#!/bin/bash
# gpg_test_compact.sh — same test as before, but ONE line of output per
# stage, so the whole thing fits on screen without scrolling.
# Full detail (in case anything needs debugging) goes to $LOG.
#
# Run on the Azure Linux VM: sudo bash gpg_test_compact.sh

set -uo pipefail

LOG="/tmp/gpgtest_full.log"
: > "$LOG"   # truncate/create

step() { echo "[$1] $2"; }   # e.g. step "1/8" "checking root..."

if [ "$(id -u)" -ne 0 ]; then
    step "FAIL" "not root — run: sudo bash $0"
    exit 1
fi
step "OK" "running as root"

RELEASEVER=$(source /etc/os-release 2>/dev/null; echo "${VERSION_ID:-3.0}")
step "OK" "releasever=$RELEASEVER"

WORKDIR=$(mktemp -d /tmp/gpgtest.XXXXXX)
GOOD_ROOT="$WORKDIR/root-good"
BAD_ROOT="$WORKDIR/root-bad"
DL_DIR="$WORKDIR/download"
REPO_DIR="$WORKDIR/tamper-repo"
mkdir -p "$GOOD_ROOT" "$BAD_ROOT" "$DL_DIR" "$REPO_DIR"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

{ echo "=== STEP 1: repo config ==="
  for f in /etc/yum.repos.d/*.repo; do
      [ -f "$f" ] || continue
      echo "-- $f --"
      grep -E "^\s*(gpgcheck|repo_gpgcheck|gpgkey)\s*=" "$f"
  done
  grep -E "^\s*gpgcheck\s*=" /etc/tdnf/tdnf.conf
} >> "$LOG" 2>&1
GPGCHECK_GLOBAL=$(grep -E "^\s*gpgcheck\s*=" /etc/tdnf/tdnf.conf 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
step "1/8" "repo config: tdnf.conf gpgcheck=${GPGCHECK_GLOBAL:-unset} (full config -> $LOG)"

SAMPLE_PKG=$(rpm -qa --qf '%{NAME}\n' 2>/dev/null | grep -vE '^gpg-pubkey' | sort -R | head -1)
if [ -z "$SAMPLE_PKG" ]; then
    step "FAIL" "no installed package found to test with"
    exit 2
fi
if ! tdnf download -y --downloadonly --downloaddir="$DL_DIR" "$SAMPLE_PKG" >>"$LOG" 2>&1; then
    tdnf reinstall -y --downloadonly --downloaddir="$DL_DIR" "$SAMPLE_PKG" >>"$LOG" 2>&1
fi
RPM_FILE=$(find "$DL_DIR" -name "*.rpm" | head -1)
if [ -z "$RPM_FILE" ]; then
    step "FAIL" "could not download $SAMPLE_PKG for testing (see $LOG)"
    exit 2
fi
step "2/8" "downloaded $SAMPLE_PKG ok"

GOOD_OUT=$(tdnf install -y --releasever="$RELEASEVER" --installroot="$GOOD_ROOT" "$RPM_FILE" 2>&1)
GOOD_RC=$?
echo "$GOOD_OUT" >> "$LOG"
if [ "$GOOD_RC" -eq 0 ]; then
    step "3/8" "sanity install of UNTOUCHED package: SUCCESS"
    SANITY_OK=1
else
    step "3/8" "sanity install of UNTOUCHED package: FAILED (rc=$GOOD_RC, see $LOG)"
    SANITY_OK=0
fi

TAMPERED_RPM="$REPO_DIR/$(basename "$RPM_FILE")"
cp "$RPM_FILE" "$TAMPERED_RPM"
SIZE=$(stat -c%s "$TAMPERED_RPM")
OFFSET=$(( SIZE > 8192 ? 8192 : SIZE / 2 ))
printf '\xDE\xAD\xBE\xEF' | dd of="$TAMPERED_RPM" bs=1 seek="$OFFSET" count=4 conv=notrunc status=none 2>>"$LOG"
step "4/8" "tampered copy created (4 bytes flipped @ offset $OFFSET)"

REPO_MODE="direct"
if command -v createrepo_c >/dev/null 2>&1; then
    createrepo_c "$REPO_DIR" >>"$LOG" 2>&1
    REPO_MODE="metadata"
fi
step "5/8" "local test repo built (mode=$REPO_MODE)"

if [ "$REPO_MODE" = "metadata" ]; then
    BAD_OUT=$(tdnf --releasever="$RELEASEVER" --installroot="$BAD_ROOT" \
        --repofrompath=tampertest,"$REPO_DIR" --repo=tampertest \
        --setopt=tampertest.gpgcheck=1 install -y "$SAMPLE_PKG" 2>&1)
    BAD_RC=$?
else
    BAD_OUT=$(tdnf install -y --releasever="$RELEASEVER" --installroot="$BAD_ROOT" "$TAMPERED_RPM" 2>&1)
    BAD_RC=$?
fi
echo "$BAD_OUT" >> "$LOG"

INSTALLED_BAD=0
rpm --root="$BAD_ROOT" -q "$SAMPLE_PKG" >/dev/null 2>&1 && INSTALLED_BAD=1
step "6/8" "install PAYLOAD-TAMPERED package: rc=$BAD_RC, landed_in_db=$INSTALLED_BAD"

# --- second attack: corrupt the SIGNATURE bytes instead of the payload ---
# RPM layout: 96-byte lead, then the signature header starts. Flipping
# bytes in the ~100-300 range hits the signature header/data itself
# (magic, index, or the RSA sig blob), rather than the payload digest
# tested above. This exercises a different code path in tdnf/rpm.
SIG_ROOT="$WORKDIR/root-sig"
SIG_REPO="$WORKDIR/sig-repo"
mkdir -p "$SIG_ROOT" "$SIG_REPO"
SIG_TAMPERED="$SIG_REPO/$(basename "$RPM_FILE")"
cp "$RPM_FILE" "$SIG_TAMPERED"
printf '\xDE\xAD\xBE\xEF\xDE\xAD\xBE\xEF' | dd of="$SIG_TAMPERED" bs=1 seek=150 count=8 conv=notrunc status=none 2>>"$LOG"
step "7/8" "signature-area tampered copy created (8 bytes flipped @ offset 150)"

SIG_REPO_MODE="direct"
if command -v createrepo_c >/dev/null 2>&1; then
    createrepo_c "$SIG_REPO" >>"$LOG" 2>&1
    SIG_REPO_MODE="metadata"
fi
if [ "$SIG_REPO_MODE" = "metadata" ]; then
    SIG_OUT=$(tdnf --releasever="$RELEASEVER" --installroot="$SIG_ROOT" \
        --repofrompath=sigtest,"$SIG_REPO" --repo=sigtest \
        --setopt=sigtest.gpgcheck=1 install -y "$SAMPLE_PKG" 2>&1)
    SIG_RC=$?
else
    SIG_OUT=$(tdnf install -y --releasever="$RELEASEVER" --installroot="$SIG_ROOT" "$SIG_TAMPERED" 2>&1)
    SIG_RC=$?
fi
echo "$SIG_OUT" >> "$LOG"
INSTALLED_SIG=0
rpm --root="$SIG_ROOT" -q "$SAMPLE_PKG" >/dev/null 2>&1 && INSTALLED_SIG=1
step "8/8" "install SIGNATURE-TAMPERED package: rc=$SIG_RC, landed_in_db=$INSTALLED_SIG"

echo "-------------------------------------------"
if [ "$INSTALLED_BAD" -eq 1 ] || [ "$INSTALLED_SIG" -eq 1 ]; then
    echo "VERDICT: VULNERABLE — a tampered package was installed!"
    [ "$INSTALLED_BAD" -eq 1 ] && echo "  (payload-tamper case succeeded — digest check bypassed)"
    [ "$INSTALLED_SIG" -eq 1 ] && echo "  (signature-tamper case succeeded — signature check bypassed)"
elif [ "$SANITY_OK" -ne 1 ] && \
     [ "$(echo "$BAD_OUT" | head -2)" = "$(echo "$GOOD_OUT" | head -2)" ]; then
    echo "VERDICT: INCONCLUSIVE — step 3 and 6 hit the same unrelated error,"
    echo "so the tamper was never actually tested. See $LOG"
elif [ "$SANITY_OK" -eq 1 ] && [ "$BAD_RC" -ne 0 ] && [ "$SIG_RC" -ne 0 ]; then
    echo "VERDICT: NOT VULNERABLE — good pkg installed; both payload-tamper"
    echo "and signature-tamper packages were rejected."
else
    echo "VERDICT: INCONCLUSIVE — unexpected combo, check $LOG"
fi
echo "-------------------------------------------"
echo "Full detail saved to: $LOG"
