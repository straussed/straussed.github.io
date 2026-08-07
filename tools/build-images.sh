#!/usr/bin/env bash
#
# Build web-ready photo derivatives.
#
#   input:  images/large_image_originals/   (gitignored, full-resolution)
#   output: images/photos/                  (committed, served by GitHub Pages)
#
# For each original, emits WebP + JPEG at each width in WIDTHS. The site's
# content column is 960px (css/style.css:101), so 1920 is already 2x retina
# and nothing needs to be wider.
#
# Requires: ImageMagick (magick), cwebp. On macOS: brew install imagemagick webp
#
# Usage: ./tools/build-images.sh          # skip derivatives that are up to date
#        ./tools/build-images.sh --force  # rebuild everything

set -euo pipefail

cd "$(dirname "$0")/.."

SRC_DIR="images/large_image_originals"
OUT_DIR="images/photos"

WIDTHS=(960 1920)
JPEG_QUALITY=78
WEBP_QUALITY=76

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

for tool in magick cwebp; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found (brew install imagemagick webp)" >&2; exit 1; }
done

[[ -d "$SRC_DIR" ]] || { echo "error: $SRC_DIR not found" >&2; exit 1; }
mkdir -p "$OUT_DIR"

# Per-image quality overrides. Photos that are wall-to-wall high-frequency
# texture (dry grass, foliage) resist compression and need a lower quality to
# land at a reasonable size; the loss is invisible at display resolution.
jpeg_quality_for() {
  case "$1" in
    social-sniff) echo 70 ;;
    *)            echo "$JPEG_QUALITY" ;;
  esac
}

webp_quality_for() {
  case "$1" in
    social-sniff) echo 68 ;;
    *)            echo "$WEBP_QUALITY" ;;
  esac
}

# Issa_with_collar.JPG -> issa-with-collar
slugify() {
  # -E for extended regex: BSD sed (macOS) does not support \+ in basic regex,
  # and fails silently rather than erroring, leaving the name unchanged.
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E -e 's/[^a-z0-9]+/-/g' -e 's/^-//' -e 's/-$//'
}

built=0
skipped=0

shopt -s nullglob nocaseglob
for src in "$SRC_DIR"/*.{jpg,jpeg,png,tif,tiff}; do
  base="$(basename "$src")"
  slug="$(slugify "${base%.*}")"

  for width in "${WIDTHS[@]}"; do
    jpg_out="$OUT_DIR/$slug-$width.jpg"
    webp_out="$OUT_DIR/$slug-$width.webp"

    # A .no-webp marker means "we built the WebP last time and threw it away
    # because it lost to the JPEG" -- without it, dropped WebPs look perpetually
    # out of date and every run re-encodes them.
    if [[ $FORCE -eq 0 && "$jpg_out" -nt "$src" ]] &&
       [[ "$webp_out" -nt "$src" || "$webp_out.no-webp" -nt "$src" ]]; then
      skipped=$((skipped + 1))
      continue
    fi
    rm -f "$webp_out" "$webp_out.no-webp"

    # -auto-orient bakes in the EXIF rotation before -strip discards it.
    # '>' means never upscale an original narrower than the target width.
    magick "$src" \
      -auto-orient \
      -resize "${width}x>" \
      -strip \
      -sampling-factor 4:2:0 \
      -interlace JPEG \
      -quality "$(jpeg_quality_for "$slug")" \
      "$jpg_out"

    # Encode WebP from a lossless intermediate rather than from the JPEG
    # above, so the two formats don't compound each other's artifacts.
    tmp_png="$(mktemp -t buildimg).png"
    magick "$src" -auto-orient -resize "${width}x>" -strip "$tmp_png"
    cwebp -q "$(webp_quality_for "$slug")" -m 6 -quiet "$tmp_png" -o "$webp_out"
    rm -f "$tmp_png"

    # WebP usually wins by 30-50%, but on images that are wall-to-wall
    # high-frequency texture it can lose to JPEG outright. Keeping it then
    # would be actively harmful: <picture> always prefers the WebP source, so
    # modern browsers would download the larger file. Drop it and let those
    # images serve as plain JPEG.
    if [[ "$(stat -f%z "$webp_out")" -ge "$(stat -f%z "$jpg_out")" ]]; then
      rm -f "$webp_out"
      touch "$webp_out.no-webp"
    fi

    built=$((built + 1))
  done
done
shopt -u nullglob nocaseglob

echo
printf '%-34s %10s %10s %10s\n' FILE DIMENSIONS JPEG WEBP
for jpg in "$OUT_DIR"/*.jpg; do
  [[ -e "$jpg" ]] || continue
  webp="${jpg%.jpg}.webp"
  dims="$(magick identify -format '%wx%h' "$jpg")"
  if [[ -f "$webp" ]]; then
    webp_size="$(( $(stat -f%z "$webp") / 1024 ))K"
  else
    webp_size="--"
  fi
  printf '%-34s %10s %9sK %10s\n' \
    "$(basename "${jpg%.jpg}")" "$dims" \
    "$(( $(stat -f%z "$jpg") / 1024 ))" "$webp_size"
done

echo
echo "built $built, skipped $skipped (up to date)"
