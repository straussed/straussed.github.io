#!/usr/bin/env bash
#
# Build web-ready photo derivatives.
#
#   input:  images/large_image_originals/         (gitignored, full-resolution)
#           images/large_image_originals/news/    (ditto, for news photos)
#   output: images/photos/                  (committed, served by GitHub Pages)
#           images/team/                    (ditto, for people-page headshots)
#           images/news/                    (ditto, for the news gallery)
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
TEAM_OUT_DIR="images/team"
NEWS_OUT_DIR="images/news"
VIDEO_OUT_DIR="images/video"

WIDTHS=(960 1920)
JPEG_QUALITY=78
WEBP_QUALITY=76

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

for tool in magick cwebp; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found (brew install imagemagick webp)" >&2; exit 1; }
done

[[ -d "$SRC_DIR" ]] || { echo "error: $SRC_DIR not found" >&2; exit 1; }
mkdir -p "$OUT_DIR" "$TEAM_OUT_DIR" "$NEWS_OUT_DIR"

# Per-image quality overrides. Photos that are wall-to-wall high-frequency
# texture (dry grass, foliage) resist compression and need a lower quality to
# land at a reasonable size; the loss is invisible at display resolution.
jpeg_quality_for() {
  case "$1" in
    social-sniff) echo 70 ;;
    # Plots are line art, not photographs: thin strokes and small text ring
    # badly at photo quality, and flat backgrounds compress so well that the
    # higher setting costs almost nothing.
    infanticide-mortality-figure) echo 92 ;;
    *)            echo "$JPEG_QUALITY" ;;
  esac
}

webp_quality_for() {
  case "$1" in
    social-sniff) echo 68 ;;
    infanticide-mortality-figure) echo 90 ;;  # line art; see jpeg_quality_for
    *)            echo "$WEBP_QUALITY" ;;
  esac
}

# People-page headshots. These differ from the rest on all three axes, so one
# list drives them: they render in a square cell of the three-column people
# grid (css/style.css), so they get a centre crop to 1:1, narrower widths than
# the rest of the site, and they land in images/team/ rather than images/photos/.
is_headshot() {
  case "$1" in
    tamu|eli-strauss|hyena-placeholder) return 0 ;;
    *)                                  return 1 ;;
  esac
}

# Per-image width overrides. Journal covers render as small thumbnails, so the
# default 960/1920 pair would ship ~10x more pixels than are ever displayed.
widths_for() {
  case "$1" in
    pnas-cover)      echo "300 600" ;;
    hz-cohort-small) echo "400" ;;
    # Only 1440px wide to begin with. -resize '>' would refuse to upscale, so a
    # file named -1920 would really be 1440 and the srcset would overstate it.
    social-hyenas-janawoerner) echo "960 1440" ;;
    # Sits in the 280px image column of .pub-item, so 600 covers 2x.
    infanticide-mortality-figure) echo "600 1200" ;;
    # A grid cell is ~290px at the 960px container, so 320 covers 1x and 640
    # covers retina.
    *)               is_headshot "$1" && echo "320 640" || echo "${WIDTHS[@]}" ;;
  esac
}

out_dir_for() {
  is_headshot "$1" && echo "$TEAM_OUT_DIR" || echo "$OUT_DIR"
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
# News photos are routed by folder rather than by a per-image list: there will
# be a lot of them and they all want the default treatment, so the only thing
# that distinguishes them is where they land.
for src in "$SRC_DIR"/*.{jpg,jpeg,png,tif,tiff,heic} \
           "$SRC_DIR"/news/*.{jpg,jpeg,png,tif,tiff,heic}; do
  base="$(basename "$src")"
  slug="$(slugify "${base%.*}")"

  # Expanded below as ${crop_args[@]+"${crop_args[@]}"}: macOS ships bash 3.2,
  # where "${empty_array[@]}" trips `set -u` instead of expanding to nothing.
  crop_args=()
  is_headshot "$slug" && crop_args=(-gravity center -crop 1:1 +repage)
  dest="$(out_dir_for "$slug")"
  [[ "$src" == "$SRC_DIR"/news/* ]] && dest="$NEWS_OUT_DIR"

  for width in $(widths_for "$slug"); do
    jpg_out="$dest/$slug-$width.jpg"
    webp_out="$dest/$slug-$width.webp"

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
      ${crop_args[@]+"${crop_args[@]}"} \
      -resize "${width}x>" \
      -strip \
      -sampling-factor 4:2:0 \
      -interlace JPEG \
      -quality "$(jpeg_quality_for "$slug")" \
      "$jpg_out"

    # Encode WebP from a lossless intermediate rather than from the JPEG
    # above, so the two formats don't compound each other's artifacts.
    tmp_png="$(mktemp -t buildimg).png"
    magick "$src" -auto-orient ${crop_args[@]+"${crop_args[@]}"} -resize "${width}x>" -strip "$tmp_png"
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

# ---- animated GIFs ----
# These need gif2webp, not the magick+cwebp path above: cwebp reads a single
# frame, so the still path would silently flatten the animation to frame 0.
# Lossless beats lossy here — these are plot animations, flat colour and thin
# lines, where lossy both looks worse and (measured) barely saves anything.
# Note gif2webp compresses inter-frame deltas, so dropping frames to save
# bytes backfires: half the frames measured 2670K vs 1428K for all of them.
shopt -s nullglob nocaseglob
for src in "$SRC_DIR"/*.gif; do
  base="$(basename "$src")"
  slug="$(slugify "${base%.*}")"

  for width in $(widths_for "$slug"); do
    webp_out="$OUT_DIR/$slug-$width.webp"

    if [[ $FORCE -eq 0 && "$webp_out" -nt "$src" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    tmp_gif="$(mktemp -t buildimg).gif"
    magick "$src" -coalesce -resize "${width}x>" -layers optimize "$tmp_gif"
    gif2webp -m 6 -mt -quiet "$tmp_gif" -o "$webp_out"
    rm -f "$tmp_gif"

    built=$((built + 1))
  done
done
shopt -u nullglob nocaseglob

# ---- video ----
# avconvert ships with macOS, so this needs no extra install. Use the QUALITY
# presets, not the resolution ones: Preset640x480 & friends only change
# dimensions and leave the bitrate alone, which measured a 1.4% saving on a
# 1080p source (10292K -> 10147K at one ninth the pixels). PresetMediumQuality
# took the same file to 3114K. PresetLowQuality reaches 563K but drops to
# 224x128, which is below the 400px column and illegible for map/data clips.
# avconvert writes fast-start output by default (moov before mdat).
#
# Posters are NOT generated here: with no ffmpeg there is no frame extractor,
# so images/video/*-poster.jpg is produced by hand and committed.
# Listed explicitly as "<source file>|<output name>|<preset>" rather than
# globbed: large_image_originals also holds untrimmed masters we don't ship.
VIDEOS=(
  "night_jan2_video_trimmed.mp4|night-jan2-568.mp4|PresetMediumQuality"
)

if command -v avconvert >/dev/null; then
  mkdir -p "$VIDEO_OUT_DIR"
  for entry in "${VIDEOS[@]}"; do
    IFS='|' read -r vsrc vout vpreset <<< "$entry"
    src="$SRC_DIR/$vsrc"
    out="$VIDEO_OUT_DIR/$vout"

    [[ -f "$src" ]] || { echo "  (skipping $vsrc — not in $SRC_DIR)"; continue; }

    if [[ $FORCE -eq 0 && "$out" -nt "$src" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    avconvert --source "$src" --output "$out" \
      --preset "$vpreset" --multiPass --replace >/dev/null 2>&1
    built=$((built + 1))
  done
fi

echo
printf '%-34s %10s %10s %10s\n' FILE DIMENSIONS JPEG WEBP
for jpg in "$OUT_DIR"/*.jpg "$TEAM_OUT_DIR"/*.jpg "$NEWS_OUT_DIR"/*.jpg; do
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

# Animated WebPs have no JPEG counterpart, so the loop above misses them.
for webp in "$OUT_DIR"/*.webp "$TEAM_OUT_DIR"/*.webp "$NEWS_OUT_DIR"/*.webp; do
  [[ -e "$webp" && ! -e "${webp%.webp}.jpg" ]] || continue
  printf '%-34s %10s %10s %9sK  (%s frames)\n' \
    "$(basename "${webp%.webp}")" \
    "$(magick identify -format '%wx%h' "$webp[0]")" "--" \
    "$(( $(stat -f%z "$webp") / 1024 ))" \
    "$(magick identify "$webp" | wc -l | tr -d ' ')"
done

echo
echo "built $built, skipped $skipped (up to date)"
