#!/usr/bin/env bash
#
# Build web-ready photo derivatives.
#
#   input:  images/large_image_originals/         (gitignored, full-resolution)
#           images/large_image_originals/news/    (ditto, for news photos)
#   output: images/photos/                  (committed, served by GitHub Pages)
#           images/team/                    (ditto, for people-page headshots)
#           images/news/                    (ditto, for the news gallery)
#           images/video/                   (ditto, for the home hero and research-page clips)
#
# For each original, emits WebP + JPEG at each width in WIDTHS. The site's
# content column is 960px (css/style.css:101), so 1920 is already 2x retina
# and nothing needs to be wider.
#
# Requires: ImageMagick (magick), cwebp, and — for the video section only —
# ffmpeg. On macOS: brew install imagemagick webp ffmpeg
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
    infanticide-mortality-figure|domarchive-phylogeny) echo 92 ;;
    *)            echo "$JPEG_QUALITY" ;;
  esac
}

webp_quality_for() {
  case "$1" in
    social-sniff) echo 68 ;;
    infanticide-mortality-figure|domarchive-phylogeny) echo 90 ;;  # line art; see jpeg_quality_for
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
    # Only 1440px wide to begin with. -resize '>' would refuse to upscale, so a
    # file named -1920 would really be 1440 and the srcset would overstate it.
    social-hyenas-janawoerner) echo "960 1440" ;;
    # Sits in the 280px image column of .pub-item, so 600 covers 2x.
    infanticide-mortality-figure) echo "600 1200" ;;
    # Same 280px column, but the only available source (the PMC copy of the
    # published figure) is 698px wide, so 1200 would not be a real 1200.
    domarchive-phylogeny) echo "300 600" ;;
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

  # hz_cohort_small.gif is superseded by the hz.mp4 encodes in the video section
  # below — same animation, 2x the resolution, a third of the bytes. Skipped
  # rather than deleted because the GIF is still the only copy of some renders.
  [[ "$slug" == "hz-cohort-small" ]] && continue

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
# Every clip is embedded as autoplaying, looping, muted <video> (the motion is
# the point, and no master carries an audio track), so every visitor
# downloads them: size matters as much as it does for the photos.
#
# This used to shell out to macOS's avconvert, whose QUALITY presets are the
# only ones that actually move the bitrate but expose no other knob — no target
# width, no CRF, no still extraction. ffmpeg gives all three, so the clips are
# now encoded at a real 2x for their 400px column (800px wide) and the posters
# are generated here rather than cut by hand and committed.
#
# Two encodes per clip. VP9 is listed first in the page's <source> list and wins
# where supported; the H.264 is the fallback that plays everywhere. The CRF
# scales are NOT comparable between the two codecs — the pairs below were
# matched by eye on a frame with fine text, not by arithmetic.
#
# Listed explicitly as "<source>|<slug>|<width>|<x264 crf>|<vp9 crf>|<x264 extra>"
# rather than globbed: large_image_originals also holds untrimmed masters we
# don't ship, and each clip needs its own settings.
#
# hz.mp4 is a 4800x3200 render of the same cohort animation as
# hz_cohort_small.gif. Encoding from it rather than from the GIF skips a
# 256-colour palette round trip, and -tune animation is x264's mode for exactly
# this content: flat fills and thin strokes. The night clip is photographic
# satellite imagery and wants the default tune.
#
# The sunset clip is the full-width home-page banner, encoded twice: the page's
# <source media> picks 1920 on wide windows and 1280 everywhere else, so phones
# don't pay for pixels they can't show. 45s of wind-blown grass is about the
# worst case for a codec (1600 at CRF 24 came to 20MB), hence the high CRFs:
# 1280/30 is ~3.7MB and 1920/32 ~6.4MB, both clean by eye on the hyenas. Both
# entries write the same poster; the 1920 one is listed last so its poster wins.
VIDEOS=(
  "night_jan2_video_trimmed.mp4|night-jan2|800|24|36|"
  "hz.mp4|hz-cohort|800|20|30|-tune animation"
  "brgr_sunset_stroll_16x9.mp4|sunset-stroll|1280|30|42|"
  "brgr_sunset_stroll_16x9.mp4|sunset-stroll|1920|32|44|"
)

if command -v ffmpeg >/dev/null; then
  mkdir -p "$VIDEO_OUT_DIR"
  for entry in "${VIDEOS[@]}"; do
    IFS='|' read -r vsrc slug width x264_crf vp9_crf x264_extra <<< "$entry"
    src="$SRC_DIR/$vsrc"
    mp4_out="$VIDEO_OUT_DIR/$slug-$width.mp4"
    webm_out="$VIDEO_OUT_DIR/$slug-$width.webm"
    poster_out="$VIDEO_OUT_DIR/$slug-poster.jpg"

    [[ -f "$src" ]] || { echo "  (skipping $vsrc — not in $SRC_DIR)"; continue; }

    if [[ $FORCE -eq 0 && "$mp4_out" -nt "$src" && "$webm_out" -nt "$src" \
          && "$poster_out" -nt "$src" ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    # -2 rather than -1: yuv420p subsamples chroma 2x, so an odd height fails.
    scale="scale=$width:-2:flags=lanczos"

    # -an drops audio unconditionally. No master has any, and a silent
    # track would only cost bytes and block autoplay on stricter browsers.
    # +faststart moves the moov atom ahead of the mdat so playback can begin
    # before the whole file has arrived.
    ffmpeg -y -v error -i "$src" -an -vf "$scale" \
      -c:v libx264 -profile:v high -preset slow -crf "$x264_crf" $x264_extra \
      -pix_fmt yuv420p -movflags +faststart \
      "$mp4_out"

    # cpu-used 1 rather than the usual 2: measured 2438K -> 1968K on the night
    # clip for ~15s more encode time, which is free at build time.
    ffmpeg -y -v error -i "$src" -an -vf "$scale" \
      -c:v libvpx-vp9 -crf "$vp9_crf" -b:v 0 -row-mt 1 -deadline good -cpu-used 1 \
      -pix_fmt yuv420p \
      "$webm_out"

    # VP9 normally wins, but not always. Keeping a WebM that lost would be
    # actively harmful for the same reason as a WebP that loses to its JPEG:
    # the <source> order means supporting browsers always take it.
    if [[ "$(stat -f%z "$webm_out")" -ge "$(stat -f%z "$mp4_out")" ]]; then
      rm -f "$webm_out"
      echo "  (dropped $slug-$width.webm — larger than the mp4)"
    fi

    # Not frame 0: these clips fade in, so the very first frame is black.
    ffmpeg -y -v error -ss 0.5 -i "$src" -frames:v 1 -vf "$scale" -q:v 3 \
      "$poster_out"

    built=$((built + 1))
  done
else
  echo "  (skipping video — ffmpeg not found; brew install ffmpeg)"
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

# Video lands in its own directory and has no still counterpart, so neither
# loop above sees it. These are the heaviest things the site ships and they now
# autoplay, so they are the numbers most worth watching.
if command -v ffprobe >/dev/null; then
  for vid in "$VIDEO_OUT_DIR"/*.mp4 "$VIDEO_OUT_DIR"/*.webm; do
    [[ -e "$vid" ]] || continue
    printf '%-34s %10s %10s %9sK\n' \
      "$(basename "$vid")" \
      "$(ffprobe -v error -select_streams v:0 \
           -show_entries stream=width,height -of csv=p=0:s=x "$vid")" \
      "--" \
      "$(( $(stat -f%z "$vid") / 1024 ))"
  done
fi

echo
echo "built $built, skipped $skipped (up to date)"
