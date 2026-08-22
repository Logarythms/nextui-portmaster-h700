#!/bin/sh
# pins.sh — pinned upstream URLs + SHA-256 for the h700 PortMaster build.
# Sourced by build/build-pak.sh. Every download is verified against these.

MP_URL="https://github.com/josegonzalez/minui-presenter/releases/download/0.13.0/minui-presenter-h700-nextui"
MP_SHA256=6156dfa1032c8729d0bb606eb6d37d23defbcdd41c9ef2888f2e1e1ffc8a2def
PM_PAK_URL="https://github.com/ben16w/minui-portmaster/releases/download/2.13.0/PORTS.pak.zip"
PM_PAK_SHA256=67c291e94e96d58c08a33e982f61bfe6ec016b47dbe5c41a87f5511583e2939c   # observed sha, double-download cross-checked (upstream publishes none)
# gate finding 2026-08-22: pak bundles Debian bullseye python3.11, whose _ctypes
# needs libffi.so.7 (TrimUI supplies it via /usr/trimui/lib; h700 has none —
# BaseOS ships only ABI-incompatible libffi.so.8). Ship libffi7 3.3-6 (the exact
# bullseye version the bundled python targets); sha is the .deb's own sha256,
# double-download cross-checked (upstream publishes none for pool files).
PM_LIBFFI_DEB_URL="http://deb.debian.org/debian/pool/main/libf/libffi/libffi7_3.3-6_arm64.deb"
PM_LIBFFI_DEB_SHA256=eb748e33ae4ed46f5a4c14b7a2a09792569f2029ede319d0979c373829ba1532
# gate finding F3 (2026-08-22): NextUI's system lib dir has no SDL2_mixer and a
# too-old SDL2_ttf (2.0.13 < pysdl2's 2.0.14 minimum); pysdl2's vendored dll.py
# also can't handle a multi-entry PYSDL2_DLL_PATH, so on h700 the pak's own
# lib/ must carry the WHOLE SDL2_ttf dependency chain itself. Bullseye's
# CURRENT per-package version (checked against dists/bullseye/.../Packages —
# freetype6 and libpng16-16 had since moved to a later point-release security
# update than the plain pool copy; libbrotli1 and libsdl2-ttf-2.0-0 had not).
# All four .deb shas are the .deb's own sha256, double-download cross-checked
# (upstream publishes a sha256 for these in Packages.xz; independently
# reproduced, not just copied).
PM_SDL2TTF_DEB_URL="http://deb.debian.org/debian/pool/main/libs/libsdl2-ttf/libsdl2-ttf-2.0-0_2.0.15+dfsg1-1_arm64.deb"
PM_SDL2TTF_DEB_SHA256=8919e0490fa6383425e98f43b0922f664bc69deb5caaaab647c137be2da7b252
PM_FREETYPE_DEB_URL="http://deb.debian.org/debian-security/pool/updates/main/f/freetype/libfreetype6_2.10.4+dfsg-1+deb11u2_arm64.deb"
PM_FREETYPE_DEB_SHA256=0e8e39f26802a8e7695c058ac4fe704fbcc0b4e2c911bfdf2b53c31939e8c029
PM_PNG16_DEB_URL="http://deb.debian.org/debian-security/pool/updates/main/libp/libpng1.6/libpng16-16_1.6.37-3+deb11u4_arm64.deb"
PM_PNG16_DEB_SHA256=c2d7462269c4ffcb97253ad9ab503b90a9614c187a9807a4d47b7d62a366ff0f
PM_BROTLI_DEB_URL="http://deb.debian.org/debian/pool/main/b/brotli/libbrotli1_1.0.9-2+b2_arm64.deb"
PM_BROTLI_DEB_SHA256=52ca7f90de6cb6576a0a5cf5712fc4ae7344b79c44b8a1548087fd5d92bf1f64
# gate finding F5 (2026-08-22), same "h700 lib gap" story as F3 above: NextUI's
# libSDL2_image is built without JPEG support, and the GUI theme loads a .jpg —
# so the pak's own lib/ must also carry a full-featured SDL2_image plus its
# whole codec chain (jpeg/tiff/webp/jbig/deflate; png16/z/zstd/lzma are already
# covered by the F3 ttf-stack pins or upstream — not duplicated here). Same
# sourcing rule as F3: probe pool/main first, then debian-security/updates
# (tiff needed it this round, same as freetype/png16 did for F3). All six
# .deb shas are the .deb's own sha256, double-download cross-checked and
# cross-referenced against Packages.xz.
PM_SDL2IMAGE_DEB_URL="http://deb.debian.org/debian/pool/main/libs/libsdl2-image/libsdl2-image-2.0-0_2.0.5+dfsg1-2_arm64.deb"
PM_SDL2IMAGE_DEB_SHA256=299a8d7568bf930f7171a849265d6b1bd0c7491c231c142ddfe4e29c2dded571
PM_JPEG_DEB_URL="http://deb.debian.org/debian/pool/main/libj/libjpeg-turbo/libjpeg62-turbo_2.0.6-4_arm64.deb"
PM_JPEG_DEB_SHA256=8903394de23dc6ead5abfc80972c8fd44300c9903ad4589d0df926e71977d881
PM_TIFF_DEB_URL="http://deb.debian.org/debian-security/pool/updates/main/t/tiff/libtiff5_4.2.0-1+deb11u8_arm64.deb"
PM_TIFF_DEB_SHA256=5bbf4670b8a7285abe014afe94ff2ea2e73ea4447f0cc050721f6237c549b7ee
PM_WEBP_DEB_URL="http://deb.debian.org/debian/pool/main/libw/libwebp/libwebp6_0.6.1-2.1+deb11u2_arm64.deb"
PM_WEBP_DEB_SHA256=edeb260e528fecae77457a63a468e55837a98079fdd7f1e20e9813c358f8c755
PM_JBIG_DEB_URL="http://deb.debian.org/debian/pool/main/j/jbigkit/libjbig0_2.1-3.1+b2_arm64.deb"
PM_JBIG_DEB_SHA256=b71b3e62e162f64cb24466bf7c6e40b05ce2a67ca7fed26d267d498f2896d549
PM_DEFLATE_DEB_URL="http://deb.debian.org/debian/pool/main/libd/libdeflate/libdeflate0_1.7-1_arm64.deb"
PM_DEFLATE_DEB_SHA256=a1adc22600ea5e44e8ea715972ac2af7994cc7ff4d94bba8e8b01abb9ddbdfd0
# gate finding F7 (2026-08-22), same "h700 lib gap" story: port launches run
# through the pak's bundled DYNAMIC bash (5.2.0), which needs libncurses.so.5;
# TrimUI provides it via /usr/trimui/lib, h700 has none, so every port launch
# died at loader time ("error while loading shared libraries: libncurses.so.5")
# — verified fixed on-device (`bash --version` OK under the pak env). Both
# .deb shas are the .deb's own sha256, double-download cross-checked and
# matched against Packages.xz on the first try (no debian-security fallback
# needed this round).
PM_NCURSES5_DEB_URL="http://deb.debian.org/debian/pool/main/n/ncurses/libncurses5_6.2+20201114-2+deb11u2_arm64.deb"
PM_NCURSES5_DEB_SHA256=cebc7c767c8892bb49b82ff70b3ec3d13ffe3dc79ed0188c98b542fa5ea378c9
PM_TINFO5_DEB_URL="http://deb.debian.org/debian/pool/main/n/ncurses/libtinfo5_6.2+20201114-2+deb11u2_arm64.deb"
PM_TINFO5_DEB_SHA256=98a4b48202fa7f3f3191b5dc08bcee436b10ff7d01f9710a06309172b35677fb
# gate finding F9 (2026-08-22), same "h700 lib gap" story: OpenAL audio chain
# for GL/gl4es ports; TrimUI provides it, h700 doesn't (full missing chain
# found via LD_TRACE_LOADED_OBJECTS on the stuntcarracer port binary:
# libopenal.so.1 -> libsndio.so.7.0 -> libbsd.so.0 -> libmd.so.0). All four
# .deb shas are the .deb's own sha256, double-download cross-checked and
# matched against Packages.xz on the first try (no debian-security fallback
# needed this round).
PM_OPENAL_DEB_URL="http://deb.debian.org/debian/pool/main/o/openal-soft/libopenal1_1.19.1-2_arm64.deb"
PM_OPENAL_DEB_SHA256=848f7cb93823c780ab58c0da67535316ef797666934d06ed6d64e902d4e2df11
PM_SNDIO_DEB_URL="http://deb.debian.org/debian/pool/main/s/sndio/libsndio7.0_1.5.0-3_arm64.deb"
PM_SNDIO_DEB_SHA256=5d3fcdcde0de0021ee217769e0866dcd524734a04f961c2ecc33488db47ba545
PM_LIBBSD_DEB_URL="http://deb.debian.org/debian/pool/main/libb/libbsd/libbsd0_0.11.3-1+deb11u1_arm64.deb"
PM_LIBBSD_DEB_SHA256=614d36d41b670955a75526865bd321703f2accb6e0c07ee4c283fbba12e494df
PM_LIBMD_DEB_URL="http://deb.debian.org/debian/pool/main/libm/libmd/libmd0_1.0.3-3_arm64.deb"
PM_LIBMD_DEB_SHA256=3c490cdcce9d25e702e6587b6166cd8e7303fce8343642d9d5d99695282a9e5c
# gate finding F10 (2026-08-22): the LÖVE 11.5 runtime's liblove links
# vorbisfile/theoradec/mpg123 (readelf-verified) with pixman/fontconfig/uuid
# pulled in transitively; TrimUI provides them, h700 doesn't. Gate-validated
# on-device 2026-08-22: with these hot-pushed, `love.aarch64 --version` runs
# on the RG SP ("LOVE 11.5 (Mysterious Mysteries)"). All seven .deb shas are
# the .deb's own sha256, double-download cross-checked and cross-referenced
# against Packages.xz. libmpg123-0's pool/main baseline (1.26.4-1) does NOT
# reproduce the extracted-file hash pinned below for libmpg123.so.0.45.3 — the
# debian-security point release (1.26.4-1+deb11u1) does (same soname, patched
# bytes); same "probe pool/main first, then debian-security" story as F3's
# freetype6/libpng16-16. The other six matched pool/main on the first try.
# Each PM_*_SO_SHA256 below is the MANDATORY hash of the EXTRACTED library
# file itself (verified below, separately from the .deb-level pin fetch()
# checks) — hash mismatch on any extracted file blocks staging.
PM_VORBISFILE_DEB_URL="http://deb.debian.org/debian/pool/main/libv/libvorbis/libvorbisfile3_1.3.7-1_arm64.deb"
PM_VORBISFILE_DEB_SHA256=f8f418e15f99905d4a2d532617511a11d700e814f8ead1a883deea2f7241970c
PM_VORBISFILE_SO_SHA256=719c0288d8fc1b553d084be0c55ff72917f8159de438686d3701c97128128358
PM_VORBIS_DEB_URL="http://deb.debian.org/debian/pool/main/libv/libvorbis/libvorbis0a_1.3.7-1_arm64.deb"
PM_VORBIS_DEB_SHA256=2f902ae456bcada7b0d494d7bd7c994feb81c4158209d8a12c0b2d9e255edda7
PM_VORBIS_SO_SHA256=7a47392715d2868d0ea2d1fe1a4e955fe3ba519da15a9b3d0c8ad3568551d72f
PM_THEORA_DEB_URL="http://deb.debian.org/debian/pool/main/libt/libtheora/libtheora0_1.1.1+dfsg.1-15_arm64.deb"
PM_THEORA_DEB_SHA256=e1ca65eaa5c90af2f88a5ba157e4b61b38b3cdf7ca8b83f20db4ee2dc271c344
PM_THEORADEC_SO_SHA256=5136ae940d31655f48285b7b8a37cf788127e2e6562b4537dc702fad57a47d45
PM_MPG123_DEB_URL="http://deb.debian.org/debian-security/pool/updates/main/m/mpg123/libmpg123-0_1.26.4-1+deb11u1_arm64.deb"
PM_MPG123_DEB_SHA256=725874446743de55934f6cdaa782f1d2667edbf3fc70ce2f6b1dd554e1fdd868
PM_MPG123_SO_SHA256=a6b440e30be338b010468370ba97e832f3a5a682b1484aebd17f4713ff66234d
PM_PIXMAN_DEB_URL="http://deb.debian.org/debian/pool/main/p/pixman/libpixman-1-0_0.40.0-1.1~deb11u1_arm64.deb"
PM_PIXMAN_DEB_SHA256=f891c7a1015e3c234d6dc1219caa1fecb9fc2abffd3072d93a5fbf1a4b0a1756
PM_PIXMAN_SO_SHA256=e1dfb301bdc6b510d71a581f7cec1547def276fb3b50670147e89c1e42d3c0bc
PM_FONTCONFIG_DEB_URL="http://deb.debian.org/debian/pool/main/f/fontconfig/libfontconfig1_2.13.1-4.2_arm64.deb"
PM_FONTCONFIG_DEB_SHA256=18b13ef8a46e9d79ba6a6ba2db0c86e42583277b5d47f6942f3223e349c22641
PM_FONTCONFIG_SO_SHA256=53748e544be7bc8262359f2cd0696d9184788f1146813fc006649330e9e0c363
PM_UUID_DEB_URL="http://deb.debian.org/debian/pool/main/u/util-linux/libuuid1_2.36.1-8+deb11u2_arm64.deb"
PM_UUID_DEB_SHA256=2b3df73a725c3fe4ec8565ec04124e556122370fc63fd7886f7dfa25092df0ba
PM_UUID_SO_SHA256=7581f2a9879fcd79db160f57889e80c912cad564edcf446bb3d0d06394c57e67
