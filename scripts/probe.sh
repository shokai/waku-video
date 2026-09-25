#!/bin/sh
# mp4がブラウザで再生できる形式かを確かめ、満たさなければ失敗する
# 使い方: scripts/probe.sh [file]（省略時はデスクトップの最新のmp4）。MIN_DURATION=秒 で長さも検査する
set -eu

file="${1:-$(ls -t "$HOME"/Desktop/*.mp4 | head -1)}"
echo "$file"
info="$(ffprobe -v error -select_streams v:0 -of default=noprint_wrappers=1 -show_entries \
  stream=codec_name,profile,level,pix_fmt,color_range,color_primaries,color_transfer,color_space,width,height,avg_frame_rate,nb_frames:format=duration \
  "$file")"
echo "$info"
# moovがmdatより先にあれば、ダウンロードし終わる前に再生を始められる（fast start）
atoms="$(ffprobe -v trace "$file" 2>&1 | grep -oE "type:'(moov|mdat)'" | head -2 | tr -d '\n')"
echo "atoms: $atoms"

status=0
expect() {
  echo "$info" | grep -qx "$1" || { echo "NG: $1 ではない"; status=1; }
}
expect "codec_name=h264"
expect "pix_fmt=yuv420p"
expect "color_primaries=bt709"
[ "$atoms" = "type:'moov'type:'mdat'" ] || { echo "NG: moovがmdatより前にない"; status=1; }

duration="$(echo "$info" | sed -n 's/^duration=//p')"
if ! awk -v d="$duration" -v min="${MIN_DURATION:-0}" 'BEGIN { exit !(d >= min) }'; then
  echo "NG: duration=$duration が${MIN_DURATION}秒より短い"
  status=1
fi
exit $status
