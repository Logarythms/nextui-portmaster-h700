#!/bin/sh
. "$(dirname -- "$0")/helpers.sh"

# F67: some ports link libcurl.so.4 and bundle none, expecting the firmware to
# provide it (issue #2: Sonic 3 AIR died with "libcurl.so.4: cannot open shared
# object file"; upstream Doom 3/dhewm3 has the same hard dependency). NextUI-h700
# has no libcurl, but rc11 does ship Ubuntu jammy's libssl.so.3/libcrypto.so.3,
# zlib and /etc/ssl/certs/ca-certificates.crt. The pak ships a slim libcurl
# (HTTP/HTTPS only) built from a pinned curl tarball in an ubuntu:22.04 arm64
# container (make libcurl) against exactly those, exporting the Debian/Ubuntu
# symbol version CURL_OPENSSL_4 that such ports bind to. Device-proven on the
# RG SP (rc11) 2026-09-30: the loader resolves it, an HTTPS request verifies.
LIB="$ROOT/assets/libcurl.so.4"; TXT="$ROOT/assets/libcurl.txt"
MK="$ROOT/Makefile"; BUILD="$ROOT/build/build-pak.sh"; SCRIPT="$ROOT/build/libcurl.sh"

# ---------- the committed asset: aarch64, right soname, right symbol version, slim ----------
[ -f "$LIB" ] || { echo "assets/libcurl.so.4 missing (run make libcurl)"; exit 1; }
file "$LIB" | grep -q 'ELF 64-bit.*aarch64' \
  || { echo "libcurl.so.4 is not an aarch64 shared object: $(file "$LIB")"; exit 1; }
for s in libcurl.so.4 CURL_OPENSSL_4 curl_easy_init curl_easy_setopt curl_easy_perform curl_easy_cleanup \
         libssl.so.3 libcrypto.so.3 libz.so.1; do
  [ "$(grep -a -c "$s" "$LIB")" -ge 1 ] || { echo "libcurl.so.4 lacks '$s'"; exit 1; }
done
# a GnuTLS-flavoured build (CURL_GNUTLS_3) would not satisfy ports linked
# against Ubuntu's OpenSSL libcurl4, and every extra dependency is a lib the
# device does not have
for s in CURL_GNUTLS_3 libnghttp2 libpsl libidn2 libbrotli libzstd libssh libldap libgssapi librtmp; do
  [ "$(grep -a -c "$s" "$LIB")" -eq 0 ] || { echo "libcurl.so.4 references '$s' (not the slim build)"; exit 1; }
done

# ---------- provenance: pinned to the Makefile, hash of the shipped bytes ----------
mk_ver=$(grep '^CURL_VERSION' "$MK" | awk '{print $3}')
mk_sha=$(grep '^CURL_SHA256' "$MK" | awk '{print $3}')
mk_img=$(grep '^LIBCURL_IMAGE' "$MK" | awk '{print $3}')
printf '%s' "$mk_ver" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "Makefile CURL_VERSION is not x.y.z: '$mk_ver'"; exit 1; }
printf '%s' "$mk_sha" | grep -Eq '^[0-9a-f]{64}$' || { echo "Makefile CURL_SHA256 is not a 64-hex sha256: '$mk_sha'"; exit 1; }
printf '%s' "$mk_img" | grep -Eq '^ubuntu@sha256:[0-9a-f]{64}$' || { echo "Makefile LIBCURL_IMAGE is not a digest-pinned ubuntu image: '$mk_img'"; exit 1; }
[ -f "$TXT" ] || { echo "assets/libcurl.txt missing"; exit 1; }
assert_contains "$TXT" "^curl: $mk_ver\$"
assert_contains "$TXT" "^tarball sha256: $mk_sha\$"
assert_contains "$TXT" "^image: $mk_img\$"
so_sha=$(shasum -a 256 "$LIB" | cut -d' ' -f1)
assert_contains "$TXT" "^sha256: $so_sha\$"

# ---------- the build lane: Makefile runs the container script, which pins what the fix depends on ----------
sh -n "$SCRIPT" || { echo "build/libcurl.sh does not parse"; exit 1; }
assert_contains "$MK" 'build/libcurl.sh'
assert_contains "$SCRIPT" '\-\-enable-versioned-symbols'
assert_contains "$SCRIPT" '\-\-with-openssl'
assert_contains "$SCRIPT" '\-\-with-ca-bundle=/etc/ssl/certs/ca-certificates.crt'

# ---------- staging: straight into lib/ (on every port's LD_LIBRARY_PATH), fail closed on arch ----------
sh -n "$BUILD" || { echo "build-pak.sh does not parse"; exit 1; }
# shellcheck disable=SC2016
assert_contains "$BUILD" 'cp "\$ASSETS/libcurl.so.4" "\$assembled/lib/libcurl.so.4"'
assert_contains "$BUILD" 'libcurl.so.4 is not an aarch64 shared object'

echo "test-38-libcurl: OK"
