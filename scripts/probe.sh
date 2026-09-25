#!/bin/sh
# 最新のmp4がブラウザで再生できる形式かを確かめる
set -eu

file="${1:-$(ls -t "$HOME"/Desktop/*.mp4 | head -1)}"
echo "$file"
ffprobe -v error -select_streams v:0 -of default=noprint_wrappers=1 -show_entries \
  stream=codec_name,profile,level,pix_fmt,color_range,width,height,r_frame_rate,avg_frame_rate,nb_frames:format=duration,start_time \
  "$file"
# moovがmdatより先にあれば、ダウンロードし終わる前に再生を始められる（fast start）
echo "atoms: $(ffprobe -v trace "$file" 2>&1 | grep -oE "type:'(moov|mdat)'" | head -2 | tr '\n' ' ')"
