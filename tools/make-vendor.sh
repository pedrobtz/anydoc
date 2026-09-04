#!/usr/bin/env sh
# Build the vendored crate archive and print the digest to commit.
#
# Release order matters, and is not the order data.fusion uses. CRAN requires
# the expected checksum to be *inside* the source package, so the archive has to
# exist before the version that references it is tagged:
#
#   1. tools/make-vendor.sh                  # build the archive, print digest
#   2. commit the digest to tools/vendor.sha256
#   3. create the vX.Y.Z release and upload src/rust/vendor.tar.xz to it
#   4. tag/submit
#
# The digest is recorded from the artefact that is actually uploaded, so this
# does not depend on `tar` and `xz` producing byte-identical output on another
# machine.
set -eu

cd "$(dirname "$0")/.."
cd src/rust

# --locked: vendor exactly what Cargo.lock pins. Without it a stale lock is
# silently re-resolved, and the archive whose digest is about to be committed as
# authoritative would hold a different dependency set than the committed lock.
echo "*** cargo vendor"
cargo vendor --locked vendor > /dev/null

# COPYFILE_DISABLE: macOS bsdtar otherwise stores extended attributes as
# separate ._ members, silently changing the contents of the archive the digest
# is taken from.
echo "*** compressing"
rm -f vendor.tar.xz
COPYFILE_DISABLE=1 tar cJf vendor.tar.xz vendor
rm -rf vendor

if tar tf vendor.tar.xz | grep -q '/\._'; then
  echo "ERROR: the archive contains AppleDouble (._) members." >&2
  echo "       Rebuild it with COPYFILE_DISABLE=1 set." >&2
  exit 1
fi

SIZE=$(wc -c < vendor.tar.xz | tr -d ' ')
if command -v shasum > /dev/null 2>&1; then
  DIGEST=$(shasum -a 256 vendor.tar.xz | awk '{print $1}')
else
  DIGEST=$(sha256sum vendor.tar.xz | awk '{print $1}')
fi

echo
echo "Archive : src/rust/vendor.tar.xz (${SIZE} bytes)"
echo "SHA256  : ${DIGEST}"
echo
echo "Write it to tools/vendor.sha256 with:"
echo "  echo ${DIGEST} > tools/vendor.sha256"
