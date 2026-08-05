#!/usr/bin/env bash
# Sign and assemble release assets from a finished per-arch build.
#   tools/release.sh <arch> [out-dir]      e.g. tools/release.sh arm64 out/Default
#   env: UGC_KEYSTORE, UGC_KEYSTORE_ALIAS (default key0), UGC_KEYSTORE_PASSFILE
set -eu
cd "$(dirname "$0")/.."
ARCH="${1:?usage: tools/release.sh <arch> [out-dir]}"
OUT="src/${2:-out/Default}"   # build.sh:217 builds into out/Default; pass a second arg to override

. ./.build_config
VERSION=$(grep -o 'android_override_version_name="[^"]*"' "$OUT/args.gn" 2>/dev/null | cut -d'"' -f2 || true)
[ -n "$VERSION" ] || VERSION="$chromium_version"
REL="releases/${VERSION}-${ungoogled_chromium_android_revision}"
mkdir -p "$REL"
REPO=$(pwd)

APK_IN=$(find "$OUT/apks" -maxdepth 1 -name "ChromePublic.apk" | head -1)
[ -n "$APK_IN" ] || { echo "FATAL: no ChromePublic.apk in $OUT/apks"; exit 1; }
AAB_IN=$(find "$OUT/apks" -maxdepth 1 -name "ChromePublic.aab" | head -1)

KS="${UGC_KEYSTORE:-}"
KS_ALIAS="${UGC_KEYSTORE_ALIAS:-key0}"
KS_PASSFILE="${UGC_KEYSTORE_PASSFILE:-}"
APKSIGNER="${APKSIGNER:-$(ls src/third_party/android_sdk/public/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)}"
[ -x "${APKSIGNER:-}" ] || APKSIGNER=$(ls "$HOME"/android-sdk/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)
_TREE_JDK="src/third_party/jdk/current/bin"
KEYTOOL="${KEYTOOL:-$([ -x "$_TREE_JDK/keytool" ] && echo "$_TREE_JDK/keytool" || command -v keytool)}"
JARSIGNER="${JARSIGNER:-$([ -x "$_TREE_JDK/jarsigner" ] && echo "$_TREE_JDK/jarsigner" || command -v jarsigner)}"
echo "  apksigner: $APKSIGNER"
echo "  jarsigner: $JARSIGNER" 

if [ -n "$KS" ] && [ -f "$KS" ] && [ -n "$KS_PASSFILE" ] && [ -f "$KS_PASSFILE" ]; then
    PW=$(cat "$KS_PASSFILE")

    "$APKSIGNER" sign --ks "$KS" --ks-key-alias "$KS_ALIAS" \
        --ks-pass "pass:$PW" --key-pass "pass:$PW" \
        --in "$APK_IN" --out "$REL/ChromePublic_${ARCH}.apk"

    FP=$("$APKSIGNER" verify --print-certs "$REL/ChromePublic_${ARCH}.apk" 2>/dev/null \
         | grep -m1 "certificate SHA-256 digest" | awk '{print $NF}' \
         | sed 's/../&:/g; s/:$//' | tr 'a-f' 'A-F')
    KFP=$("$KEYTOOL" -list -keystore "$KS" -alias "$KS_ALIAS" -storepass "$PW" -v 2>/dev/null \
          | grep -m1 "SHA256:" | awk '{print $2}')
    [ "$FP" = "$KFP" ] || { echo "FATAL: signed APK cert != keystore (apk=$FP key=$KFP)"; exit 1; }
    echo "signed APK as $KS_ALIAS ($KFP)"

    if [ -n "$AAB_IN" ]; then
        "$JARSIGNER" -sigalg SHA256withRSA -digestalg SHA-256 \
            -keystore "$KS" -storepass "$PW" -keypass "$PW" \
            -signedjar "$REL/ChromePublic_${ARCH}.aab" "$AAB_IN" "$KS_ALIAS" >/dev/null
        "$JARSIGNER" -verify "$REL/ChromePublic_${ARCH}.aab" >/dev/null \
            || { echo "FATAL: .aab signature did not verify"; exit 1; }
        echo "signed bundle"
    else
        echo "WARN: no ChromePublic.aab in $OUT/apks (bundle target not built?)"
    fi
else
    echo "WARN: no keystore supplied (UGC_KEYSTORE / UGC_KEYSTORE_PASSFILE) —"
    echo "      copying build output as-is. Artifacts are DEBUG-SIGNED; do not publish them."
    cp "$APK_IN" "$REL/ChromePublic_${ARCH}.apk"
    [ -n "$AAB_IN" ] && cp "$AAB_IN" "$REL/ChromePublic_${ARCH}.aab"
fi

MAP=$(find "$OUT" -maxdepth 2 -name "ChromePublic.apk.mapping" | head -1)
[ -n "$MAP" ] && cp "$MAP" "$REL/ChromePublic_${ARCH}.apk.mapping" || echo "WARN: no R8 mapping found"

rm -f "$REL/ChromePublic_${ARCH}_symbols.zip"
( cd "$OUT/lib.unstripped" && \
  unzip -Z1 "$REPO/$REL/ChromePublic_${ARCH}.apk" "lib/*" 2>/dev/null | xargs -rn1 basename | sort -u | \
  while read -r so; do [ -f "$so" ] && echo "$so"; done | \
  zip -q "$REPO/$REL/ChromePublic_${ARCH}_symbols.zip" -@ )

( cd "$REL" && sha256sum "ChromePublic_${ARCH}.apk" "ChromePublic_${ARCH}.aab" \
    "ChromePublic_${ARCH}.apk.mapping" "ChromePublic_${ARCH}_symbols.zip" 2>/dev/null >> sha256sums.txt \
    && sort -u -k2 sha256sums.txt -o sha256sums.txt )

echo "=== assembled $REL ($ARCH) ==="
ls -lh "$REL" | sed 's/^/  /'
