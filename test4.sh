#!/bin/bash
# check_repogpgcheck_plugin.sh — verifies whether repo_gpgcheck=1 in your
# repo config is actually enforced by a loaded plugin, or silently a no-op.

echo "1) Is the plugin package installed?"
rpm -q tdnf-plugin-repogpgcheck 2>&1 | sed 's/^/   /'
echo

echo "2) Is the plugin .so present?"
find / -xdev -iname "libtdnfrepogpgcheck.so*" 2>/dev/null | sed 's/^/   found: /'
[ -z "$(find / -xdev -iname 'libtdnfrepogpgcheck.so*' 2>/dev/null)" ] && echo "   NOT FOUND"
echo

echo "3) Is the plugin config present and enabled?"
CONF=/etc/tdnf/pluginconf.d/tdnfrepogpgcheck.conf
if [ -f "$CONF" ]; then
    cat "$CONF" | sed 's/^/   /'
else
    echo "   MISSING: $CONF"
fi
echo

echo "4) Does tdnf report plugins as enabled at all?"
grep -iE "^\s*plugins\s*=" /etc/tdnf/tdnf.conf | sed 's/^/   /'
echo

echo "5) Live check — force a metadata refresh and look for repogpgcheck activity"
tdnf clean expire-cache >/dev/null 2>&1
tdnf makecache -v 2>&1 | grep -i "gpg\|plugin\|repogpgcheck" | sed 's/^/   /'
echo "   (if nothing printed above, the plugin likely never ran)"
