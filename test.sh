#!/bin/bash
# verify_gpg_runtime.sh
#
# Run this ON the Azure Linux VM itself (not remotely — there is no network
# service to test here). Checks whether the LIVE system currently enforces
# GPG signature checking for package installs, and prints a short verdict
# at the end.
#
# IMPORTANT SCOPE NOTE (read before trusting the verdict):
# This checks RUNTIME tdnf/rpm config on the booted system. It does NOT
# and cannot confirm whether Microsoft's build pipeline passed
# VALIDATE_IMAGE_GPG=y when this image was originally built — that step
# ran once, off-VM, before this system existed, and no script running here
# can observe it. A "NOT VULNERABLE" verdict below means "this system's
# current tdnf config enforces gpgcheck", not "the image build did."

set -uo pipefail

ISSUES=()

echo "=== 1. tdnf repo gpgcheck config ==="
repo_issue=0
found_any_repo=0
for f in /etc/yum.repos.d/*.repo; do
    [ -f "$f" ] || continue
    found_any_repo=1
    val=$(grep -E "^\s*gpgcheck\s*=" "$f" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
    if [ "$val" = "0" ]; then
        echo "  [BAD] $f -> gpgcheck=0"
        ISSUES+=("repo $f has gpgcheck=0")
        repo_issue=1
    elif [ -z "$val" ]; then
        echo "  [WARN] $f -> gpgcheck not set (falls back to tdnf.conf default)"
    else
        echo "  [OK]   $f -> gpgcheck=$val"
    fi
done
[ "$found_any_repo" = 0 ] && echo "  [WARN] no .repo files found in /etc/yum.repos.d/"

global_val=$(grep -E "^\s*gpgcheck\s*=" /etc/tdnf/tdnf.conf 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' ')
if [ "$global_val" = "0" ]; then
    echo "  [BAD] /etc/tdnf/tdnf.conf -> gpgcheck=0 (global default)"
    ISSUES+=("tdnf.conf global gpgcheck=0")
elif [ -n "$global_val" ]; then
    echo "  [OK]   /etc/tdnf/tdnf.conf -> gpgcheck=$global_val"
else
    echo "  [WARN] /etc/tdnf/tdnf.conf has no explicit gpgcheck setting"
fi
echo

echo "=== 2. Trusted GPG keys imported into RPM db ==="
keycount=$(rpm -qa 'gpg-pubkey*' 2>/dev/null | wc -l)
if [ "$keycount" -eq 0 ]; then
    echo "  [BAD] 0 gpg-pubkey entries — no trust anchor exists"
    ISSUES+=("no gpg-pubkey trust anchor imported")
else
    echo "  [OK]   $keycount key(s) imported"
    rpm -qa 'gpg-pubkey*' 2>/dev/null | while read -r k; do
        rpm -qi "$k" 2>/dev/null | grep -E "^(Name|Summary)"
    done
fi
echo

echo "=== 3. Installed package signature sample (first 20) ==="
unsigned_count=0
checked_count=0
while read -r pkg; do
    [ -z "$pkg" ] && continue
    checked_count=$((checked_count+1))
    sig=$(rpm -q --qf '%{RSAHEADER:pgpsig}\n' "$pkg" 2>/dev/null)
    if [ -z "$sig" ] || [ "$sig" = "(none)" ]; then
        echo "  [BAD] unsigned: $pkg"
        unsigned_count=$((unsigned_count+1))
    fi
done < <(rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | head -20)
echo "  checked: $checked_count, unsigned: $unsigned_count"
if [ "$unsigned_count" -gt 0 ]; then
    ISSUES+=("$unsigned_count/$checked_count sampled packages unsigned")
fi
echo

if [ "${#ISSUES[@]}" -eq 0 ]; then
    echo "  RESULT: NOT VULNERABLE (runtime signature enforcement looks intact)"
else
    echo "  RESULT: VULNERABLE (runtime signature enforcement is weak/missing)"
    echo "  Reasons:"
    for i in "${ISSUES[@]}"; do
        echo "    - $i"
    done
fi
echo
echo "  Does NOT confirm/deny whether the original image BUILD enforced"
echo "  GPG checks (VALIDATE_IMAGE_GPG) — only Microsoft can answer that."
