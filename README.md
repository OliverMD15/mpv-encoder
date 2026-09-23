# mpv-encoder
An mpv Lua script that uses an external FFmpeg process to encode the currently playing media.  
Prefer mpv's built-in encoding? See the [legacy-refactor branch](https://github.com/OliverMD15/mpv-encoder/tree/legacy-refactor).

![Sample](/img/sample.jpg)

## Usage
Press `e` while playing a file to open the overlay.  
Alternatively, add `script-binding encoder/display-encoder` to `input.conf`.

Encoding follows the current playback settings: muted audio is omitted, and the selected subtitles are burned in only while subtitles are visible (where supported).

## Features
- H.264/AVC (`libx264`) and H.265/HEVC (`libx265`) video encoding.
- VP9 (`libvpx-vp9`) and AV1 (`libsvtav1`) video encoding.
- NVIDIA NVENC H.264/AVC, H.265/HEVC, and AV1 encoding when supported.
- Audio-only Opus (`.ogg`), AAC (`.m4a`), and MP3 (`.mp3`) output.
- Animated WebP output with quality and compression controls.
- Basket output with H.264 or VP9 video and separate Opus audio (`.ogg`).
- Preview and target-size encoding controls.
- Trimming and subtitle burning.
- Interactive cropping with freeform or aspect-ratio-constrained crop boxes, movement controls, and pixel-level fine-tuning.
- FPS conversion, duplicate-frame removal, and optional Variable Frame Rate.
- Progress reporting, cancellation, staging, and failure cleanup.

## Requirements
- mpv with Lua scripting support.
- FFmpeg available as `ffmpeg` on `PATH`. On Windows, `ffmpeg.exe` beside `mpv.exe` also works.
- An FFmpeg build containing the encoders required for the selected output.
- FFmpeg subtitle/libass support for burned subtitles.
- NVENC requires a compatible NVIDIA GPU, driver, and NVENC-enabled FFmpeg build.
- AV1 hardware encoding requires an AV1-capable GPU.

## Installation
Copy [`encoder.lua`](build/encoder.lua) into mpv's `scripts` directory.  
Optionally copy [`encoder.conf`](build/encoder.conf) into mpv's `script-opts` directory.

## Dev note — September 2026
The refactor in this revision was written by OpenAI Codex, not by the repository owner.  
This note is included for transparency, not as an endorsement.
