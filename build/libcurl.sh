#!/bin/sh
# build/libcurl.sh — F67: build a slim libcurl.so.4 (HTTP/HTTPS only) from a
# pinned curl release tarball. Runs INSIDE the digest-pinned linux/arm64
# ubuntu:22.04 container that `make libcurl` starts (repo mounted at /repo;
# CURL_VERSION, CURL_SHA256 and LIBCURL_IMAGE in the env).
# Outputs: assets/libcurl.so.4 (stripped) + assets/libcurl.txt (provenance).
# Why: ports like Sonic 3 AIR and Doom 3 (dhewm3) link libcurl.so.4, bundle
# none, and die in the loader on NextUI-h700, which has no libcurl. rc11 does
# ship Ubuntu jammy's libssl.so.3/libcrypto.so.3, zlib and
# /etc/ssl/certs/ca-certificates.crt, so this lane is jammy (not the pak's
# usual bullseye, whose OpenSSL is 1.1): the library links the device's own
# TLS stack and CA bundle and adds no other dependency. Ports bind the
# Debian/Ubuntu symbol version CURL_OPENSSL_4; --enable-versioned-symbols
# with the OpenSSL backend produces exactly that.
# Ubuntu's snapshot archive serves no arm64 (ubuntu-ports 401s), so apt is not
# date-pinned: the base image is digest-pinned instead and the toolchain /
# header package versions are recorded in the provenance file.
set -eu
: "${CURL_VERSION:?CURL_VERSION must be set (see Makefile)}"
: "${CURL_SHA256:?CURL_SHA256 must be set (see Makefile)}"
: "${LIBCURL_IMAGE:?LIBCURL_IMAGE must be set (see Makefile)}"
export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::Retries=3 update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl gcc make libc6-dev binutils file \
  libssl-dev zlib1g-dev pkg-config >/dev/null
rm -rf /tmp/curl && mkdir -p /tmp/curl && cd /tmp/curl
curl -fsSL -o curl.tar.gz "https://curl.se/download/curl-$CURL_VERSION.tar.gz"
echo "$CURL_SHA256  curl.tar.gz" | sha256sum -c - >/dev/null || { echo "curl-$CURL_VERSION.tar.gz sha256 mismatch" >&2; exit 1; }
tar xzf curl.tar.gz
cd "curl-$CURL_VERSION"
# HTTP(S) only: every protocol and optional dependency off except OpenSSL +
# zlib (both on the device). The CA bundle path is rc11's; libcurl ignores
# SSL_CERT_FILE, so the default has to be compiled in.
CONFIGURE_FLAGS="--disable-static --enable-shared --with-openssl --with-zlib --enable-versioned-symbols \
--with-ca-bundle=/etc/ssl/certs/ca-certificates.crt --with-ca-path=/etc/ssl/certs \
--without-libpsl --without-libidn2 --without-nghttp2 --without-nghttp3 --without-ngtcp2 \
--without-brotli --without-zstd --without-libssh2 --without-libssh --without-librtmp --without-gssapi \
--disable-ldap --disable-ldaps --disable-manual --disable-docs \
--disable-dict --disable-gopher --disable-imap --disable-pop3 --disable-smtp --disable-telnet \
--disable-tftp --disable-rtsp --disable-mqtt --disable-smb --disable-ftp --disable-file --disable-ipfs \
--disable-websockets"
# shellcheck disable=SC2086
./configure --prefix=/tmp/curl/out $CONFIGURE_FLAGS >/tmp/curl/configure.log 2>&1 \
  || { tail -30 /tmp/curl/configure.log >&2; exit 1; }
make -C lib -j"$(nproc)" >/tmp/curl/make.log 2>&1 || { tail -30 /tmp/curl/make.log >&2; exit 1; }
so=$(find lib/.libs -name 'libcurl.so.4.*' -type f | head -1)
[ -n "$so" ] || { echo "curl build produced no libcurl.so.4.*" >&2; exit 1; }
cp "$so" /tmp/curl/libcurl.so.4
lib=/tmp/curl/libcurl.so.4
strip --strip-unneeded "$lib"

# The contract, checked on the stripped bytes that ship:
readelf -h "$lib" | grep -q 'AArch64' || { echo "built libcurl is not aarch64" >&2; exit 1; }
readelf -d "$lib" | grep -q 'Library soname: \[libcurl.so.4\]' || { echo "soname is not libcurl.so.4" >&2; exit 1; }
needed=$(readelf -d "$lib" | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/\1/p' | sort | tr '\n' ' ')
[ "$needed" = "ld-linux-aarch64.so.1 libc.so.6 libcrypto.so.3 libssl.so.3 libz.so.1 " ] \
  || { echo "unexpected DT_NEEDED set: $needed" >&2; exit 1; }
for f in curl_easy_init curl_easy_setopt curl_easy_perform curl_easy_cleanup; do
  objdump -T "$lib" | grep -Eq " CURL_OPENSSL_4 +$f\$" || { echo "$f not exported as CURL_OPENSSL_4" >&2; exit 1; }
done
# glibc floor: the device runs jammy's 2.35
glibc_max=$(objdump -T "$lib" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)
[ "$(printf '%s\nGLIBC_2.35\n' "$glibc_max" | sort -V | tail -1)" = "GLIBC_2.35" ] \
  || { echo "needs $glibc_max, newer than the device's GLIBC_2.35" >&2; exit 1; }

cp "$lib" /repo/assets/libcurl.so.4
{
  echo "slim libcurl (HTTP/HTTPS only), shipped as lib/libcurl.so.4 - F67"
  echo "source: https://curl.se/download/curl-$CURL_VERSION.tar.gz (curl license, MIT-style)"
  echo "curl: $CURL_VERSION"
  echo "tarball sha256: $CURL_SHA256"
  echo "image: $LIBCURL_IMAGE"
  echo "built: $(date -u +%Y-%m-%dT%H:%MZ) linux/arm64 (build/libcurl.sh), stripped --strip-unneeded"
  echo "toolchain: $(dpkg-query -W -f='${Package} ${Version}, ' gcc-11 libc6-dev libssl-dev zlib1g-dev | sed 's/, $//')"
  echo "configure: $CONFIGURE_FLAGS"
  echo "size: $(wc -c < /repo/assets/libcurl.so.4) bytes"
  echo "sha256: $(sha256sum /repo/assets/libcurl.so.4 | cut -d' ' -f1)"
  echo
  echo "DT_NEEDED (all on NextUI-h700 rc11; libz.so.1 also ships in the pak's lib/):"
  readelf -d "$lib" | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/  \1/p'
  echo
  echo "symbol versions required:"
  objdump -T "$lib" | awk '$0 ~ /\*UND\*/ {print $(NF-1)}' | grep -v '^\*UND\*$' | sed 's/^(\(.*\))$/\1/' | sort -uV | sed 's/^/  /'
  echo
  echo "symbol version exported: CURL_OPENSSL_4"
} > /repo/assets/libcurl.txt
cat /repo/assets/libcurl.txt
