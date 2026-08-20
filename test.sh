#!/bin/bash
# verify_gpg_runtime.sh
#
# Run this ON the Azure Linux VM itself (not against it remotely — there is
# no network service to test here). This checks a DIFFERENT, but related,
# question than the build-pipeline finding: whether the live system's
# package manager currently enforces GPG signature checking, and whether
# packages already installed carry valid signatures.
#
# This does NOT prove or disprove anything about the VALIDATE_IMAGE_GPG
# build-pipeline flag — that can only be confirmed by Microsoft, since it
# controls a build step that already happened before this image existed.

set -uo pipefail

echo "===================================================================="
echo "1. tdnf repo gpgcheck configuration"
echo "===================================================================="
echo "Checking gpgcheck= setting in every configured repo:"
echo
for f in /etc/yum.repos.d/*.repo /etc/tdnf/tdnf.conf; do
    [ -f "$f" ] || continue
    echo "--- $f ---"
    grep -E "^\s*(gpgcheck|gpgkey|repo_gpgcheck)\s*=" "$f" 2>/dev/null || echo "  (no gpgcheck directive found — check tdnf.conf default)"
    echo
done

echo "Global tdnf.conf default:"
grep -E "^\s*gpgcheck\s*=" /etc/tdnf/tdnf.conf 2>/dev/null || echo "  gpgcheck not explicitly set in tdnf.conf"
echo
echo "  NOTE: if gpgcheck=0 anywhere above, tdnf will install packages from"
echo "  that repo WITHOUT verifying signatures, on this running system."
echo

echo "===================================================================="
echo "2. Are the vendor GPG keys actually present/imported?"
echo "===================================================================="
rpm -qa gpg-pubkey* 2>/dev/null | while read -r key; do
    rpm -qi "$key" 2>/dev/null | grep -E "^(Name|Summary|Packager)"
    echo "---"
done
if [ -z "$(rpm -qa gpg-pubkey* 2>/dev/null)" ]; then
    echo "  WARNING: NO gpg-pubkey entries found in the RPM database."
    echo "  This means the local RPM db has no trusted keys imported at all —"
    echo "  'rpm --checksig' against ANY installed package will report the"
    echo "  signature as unverifiable (NOKEY), regardless of tdnf's gpgcheck setting."
fi
echo

echo "===================================================================="
echo "3. Signature status recorded for currently INSTALLED packages"
echo "===================================================================="
echo "Checking header signature presence directly from the RPM db"
echo "(sampling first 20 for speed; drop 'head -20' to check everything):"
echo

rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | head -20 | while read -r pkg; do
    sig=$(rpm -q --qf '%{RSAHEADER:pgpsig}\n' "$pkg" 2>/dev/null)
    if [ -z "$sig" ] || [ "$sig" = "(none)" ]; then
        echo "  UNSIGNED or no header sig recorded: $pkg"
    else
        echo "  signed: $pkg"
    fi
done

echo
echo "===================================================================="
echo "Summary of what this script actually tells you"
echo "===================================================================="
echo "- Section 1 shows whether NEW installs on this VM will be signature-checked."
echo "- Section 2 shows whether there's even a trust anchor to check against."
echo "- Section 3 gives a rough signal on packages already installed."
echo
echo "None of this confirms or refutes whether Microsoft's build pipeline"
echo "passed VALIDATE_IMAGE_GPG=y when THIS image was built — that step"
echo "already happened, off-VM, before this system ever booted. Only"
echo "Microsoft/the Azure Linux team can answer that part."
