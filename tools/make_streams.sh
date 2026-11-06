#!/usr/bin/env bash
# Generate Annex-B test streams for tools/mock_host.py and the Windows client's
# embedded probe clips (windows/assets). Requires ffmpeg with libx265/libx264.
set -euo pipefail
cd "$(dirname "$0")"
F=${FFMPEG:-ffmpeg}
mkdir -p streams ../windows/assets

if [[ "${1:-}" != "--clips-only" ]]; then
  SRC=(-f lavfi -i testsrc2=size=2560x1440:rate=60 -t 10)
  X265="keyint=300:min-keyint=300:bframes=0:repeat-headers=1:log-level=error"
  $F -y -v error "${SRC[@]}" -pix_fmt yuv420p -c:v libx265 -preset fast -b:v 20M -x265-params "$X265" -f hevc streams/hevc420_1440p.h265
  $F -y -v error "${SRC[@]}" -pix_fmt yuv444p -c:v libx265 -preset fast -b:v 25M -x265-params "$X265" -f hevc streams/hevc444_1440p.h265
  $F -y -v error "${SRC[@]}" -pix_fmt yuv420p -c:v libx264 -preset fast -tune zerolatency -b:v 25M -g 300 -bf 0 -f h264 streams/h264_1440p.h264
fi

# Small probe clips (640x360, 10 frames) embedded into glide-client.exe for --probe.
S=(-f lavfi -i testsrc2=size=640x360:rate=30 -frames:v 10)
X="keyint=30:bframes=0:repeat-headers=1:log-level=error"
A=../windows/assets
$F -y -v error "${S[@]}" -pix_fmt yuv420p     -c:v libx265 -preset ultrafast -x265-params "$X" -f hevc $A/hevc_main_420_8.h265
$F -y -v error "${S[@]}" -pix_fmt yuv420p10le -c:v libx265 -preset ultrafast -x265-params "$X" -f hevc $A/hevc_main10_420_10.h265
$F -y -v error "${S[@]}" -pix_fmt yuv444p     -c:v libx265 -preset ultrafast -x265-params "$X" -f hevc $A/hevc_rext_444_8.h265
$F -y -v error "${S[@]}" -pix_fmt yuv444p10le -c:v libx265 -preset ultrafast -x265-params "$X" -f hevc $A/hevc_rext_444_10.h265
$F -y -v error "${S[@]}" -pix_fmt yuv422p10le -c:v libx265 -preset ultrafast -x265-params "$X" -f hevc $A/hevc_rext_422_10.h265
$F -y -v error "${S[@]}" -pix_fmt yuv420p     -c:v libx264 -preset ultrafast -bf 0 -g 30 -f h264 $A/h264_high_420_8.h264
echo ok
