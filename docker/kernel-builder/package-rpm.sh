#!/bin/bash
# Convert the already-built linux-ps5_*.deb into an RPM via alien.
# Runs after package-deb.sh in the kernel-builder container.
set -e

DEB=$(ls -1 /out/linux-ps5_*.deb | head -1)
if [ -z "$DEB" ] || [ ! -f "$DEB" ]; then
    echo "package-rpm.sh: no .deb found in /out — did package-deb.sh run?" >&2
    exit 1
fi

cd /out
# alien --keep-version preserves the upstream version string; --scripts carries
# the postinst over (gets converted to %post). --to-rpm picks the output format.
alien --to-rpm --scripts --keep-version "$DEB"

# alien names the output as linux-ps5-<ver>-<rel>.<arch>.rpm
RPM=$(ls -1t /out/linux-ps5-*.rpm | head -1)
echo "package-rpm.sh: produced $RPM"
ls -lh "$RPM"
