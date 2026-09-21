# mpv-encoder
This is a fork of ekisu's [mpv-webm][mpv-webm] that adds several new settings, while removing unneeded or broken ones.
![sample](/img/sample.jpg)

## Installation
Simply put the [script][build] into your mpv `scripts` folder. By default, the script is activated with the `e` key.

## Usage
Follow the on-screen instructions. Video files will have audio/subs based on the current playback options (i.e. will be muted if no audio, won't have hardcoded subs if subs aren't visible).

## Distribution
The repository contains the ready-to-use standalone Lua script. No MoonScript compiler or build step is required.

[mpv-webm]: https://github.com/ekisu/mpv-webm
[build]: https://raw.githubusercontent.com/OliverMD15/mpv-encoder/legacy-original/build/encoder.lua
[mpv]: http://mpv.io
