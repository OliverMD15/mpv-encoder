local mp = require("mp")
local assdraw = require("mp.assdraw")
local msg = require("mp.msg")
local utils = require("mp.utils")
local mpopts = require("mp.options")
local is_windows = type(package) == "table" and type(package.config) == "string" and package.config:sub(1, 1) == "\\"
local default_mpv_executable = is_windows and "mpv.exe" or "mpv"

-- User configuration. Keep this block limited to settings a user might edit;
-- runtime state, helpers, and implementation details belong below it.
local options = {
	-- General
	keybind = "e",
	output_directory = "",
	output_template = "%T-[%S-%E]",
	output_format = "mp4", -- mp4, WebM, NVENC, Audio, Animated, or Basket
	scale_height = -1,
	fps = -1,
	apply_current_filters = true, -- inherit mpv's active video filters
	downmix_audio = true,
	mpv_executable = default_mpv_executable, -- child mpv executable; may be an absolute path

	-- UI
	font_size = 20,
	margin = 20,
	message_duration = 3,

	-- MP4 / AVC
	video_codec_mp4 = "libx265", -- libx264 or libx265
	audio_codec_muxed = "libopus", -- libopus or aac
	crf_mp4 = 28,
	target_size_mp4_mb = 0, -- 0 = Off, 20 or 200 MB; complete file including audio
	preset_avc = "slow", -- medium, slow, slower, or veryslow
	preset_hevc = "fast", -- fast, medium, slow, or slower
	tune_avc = "", -- empty, film, animation, or grain
	tune_hevc = "", -- empty, animation, or grain
	color_filter_8bit = "format=yuv420p",

	-- WebM / VP9 and AV1
	video_codec_webm = "libsvtav1", -- libsvtav1 or libvpx-vp9
	crf_webm = 50,
	preset_av1 = "6", -- 8, 6, or 4
	color_filter_10bit = "format=yuv420p10le",
	target_size_av1_mb = 0, -- 0 = Off, 20 or 200 MB; complete file including audio

	-- NVENC
	video_codec_nvenc = "av1_nvenc", -- h264_nvenc, hevc_nvenc, or av1_nvenc
	cq_nvenc = 30,
	cq_nvenc_av1 = 35,
	target_size_nvenc_mb = 0, -- 0 = Off, 20 or 200 MB; complete file including audio

	-- Audio-only
	audio_codec_audio = "libopus", -- libopus, aac, or libmp3lame
	aac_bitrate = 128000,
	opus_bitrate = 96000,
	mp3_bitrate = 192000,

	-- Animated WebP
	quality_webp = 80, -- 0-100; higher = better quality/larger files (still lossy)
	compression_level_webp = 4, -- 2 (fast), 4 (balanced), or 6 (very slow)

	-- Basket
	video_codec_basket = "libx264", -- libx264 or libvpx-vp9
	target_size_basket_mb = 4,
	-- Native two-pass target mode uses a fast analysis pass and these final
	-- settings. Audio remains a separate .ogg file outside the video target.
	basket_final_preset = "veryslow",
	basket_first_pass_speed = 4,
	basket_search_second_pass_speed = 2,
	basket_final_second_pass_speed = 0
}

-- Read legacy names as aliases so existing encoder.conf files keep working.
-- New names win when both forms are set to different non-default values.
local legacy_option_aliases = {
  bvideo2 = "video_codec_mp4",
  baudio = "audio_codec_muxed",
  crf_264 = "crf_mp4",
  preset = "preset_avc",
  preset_265 = "preset_hevc",
  tune = "tune_avc",
  tune_265 = "tune_hevc",
  hdr = "color_filter_8bit",
  bvideo3 = "video_codec_webm",
  crf = "crf_webm",
  preset3 = "preset_av1",
  color3 = "color_filter_10bit",
  bvideo = "video_codec_nvenc",
  cq = "cq_nvenc",
  cq_av1 = "cq_nvenc_av1",
  baudio2 = "audio_codec_audio",
  bvideo4 = "video_codec_basket",
  target_size_mb = "target_size_basket_mb"
}
local canonical_option_defaults = { }
local legacy_option_unset = { }
for legacyName, canonicalName in pairs(legacy_option_aliases) do
  local defaultValue = options[canonicalName]
  canonical_option_defaults[canonicalName] = defaultValue
  local unsetValue = type(defaultValue) == "number" and -1e300 or "__encoder_legacy_unset__"
  legacy_option_unset[legacyName] = unsetValue
  options[legacyName] = unsetValue
end

mpopts.read_options(options)
local migratedLegacyOptions = { }
for legacyName, canonicalName in pairs(legacy_option_aliases) do
  local legacyValue = options[legacyName]
  if legacyValue ~= legacy_option_unset[legacyName] then
    if options[canonicalName] == canonical_option_defaults[canonicalName] then
      options[canonicalName] = legacyValue
    end
    migratedLegacyOptions[#migratedLegacyOptions + 1] = legacyName .. "->" .. canonicalName
  end
  options[legacyName] = nil
end
if #migratedLegacyOptions > 0 then
  table.sort(migratedLegacyOptions)
  msg.warn("Deprecated encoder options detected: " .. table.concat(migratedLegacyOptions, ", "))
end
if options.output_format == "GIF" then
  msg.warn("Deprecated output_format=GIF detected; using Animated")
  options.output_format = "Animated"
end
if options.target_size_mp4_mb ~= 0 and options.target_size_mp4_mb ~= 20 and options.target_size_mp4_mb ~= 200 then
  msg.warn("target_size_mp4_mb must be 0, 20, or 200; using Off")
  options.target_size_mp4_mb = 0
end
if options.target_size_av1_mb ~= 0 and options.target_size_av1_mb ~= 20 and options.target_size_av1_mb ~= 200 then
  msg.warn("target_size_av1_mb must be 0, 20, or 200; using Off")
  options.target_size_av1_mb = 0
end
if options.target_size_nvenc_mb ~= 0 and options.target_size_nvenc_mb ~= 20 and options.target_size_nvenc_mb ~= 200 then
  msg.warn("target_size_nvenc_mb must be 0, 20, or 200; using Off")
  options.target_size_nvenc_mb = 0
end
local bold
bold = function(text)
  return "{\\b1}" .. tostring(text) .. "{\\b0}"
end
local message
message = function(text, duration)
  local ass = mp.get_property_osd("osd-ass-cc/0")
  ass = ass .. text
  return mp.osd_message(ass, duration or options.message_duration)
end
local append
append = function(a, b)
  local lastIndex = 0
  for key, _ in pairs(b) do
    if type(key) == "number" and key > lastIndex and key == math.floor(key) then
      lastIndex = key
    end
  end
  for i = 1, lastIndex do
    local val = b[i]
    if val == nil then
      error("Sparse argument list: missing value at index " .. tostring(i))
    end
    a[#a + 1] = val
  end
  return a
end
local copy_list
copy_list = function(a)
  local out = { }
  for _, val in ipairs(a) do
    out[#out + 1] = val
  end
  return out
end
local seconds_to_time_string
seconds_to_time_string = function(seconds, no_ms, full)
  if seconds < 0 then
    return "unknown"
  end
  local ret = ""
  if not (no_ms) then
    ret = string.format(".%03d", seconds * 1000 % 1000)
  end
  ret = string.format("%02d:%02d%s", math.floor(seconds / 60) % 60, math.floor(seconds) % 60, ret)
  if full or seconds > 3600 then
    ret = string.format("%d:%s", math.floor(seconds / 3600), ret)
  end
  return ret
end
local seconds_to_path_element
seconds_to_path_element = function(seconds, no_ms, full)
  local time_string = seconds_to_time_string(seconds, no_ms, full)
  local _
  time_string, _ = time_string:gsub(":", ".")
  return time_string
end
local file_exists
file_exists = function(name)
  local info = utils.file_info(name)
  if info ~= nil then
    return true
  end
  return false
end
local file_is_nonempty
file_is_nonempty = function(name)
  local info = utils.file_info(name)
  return info ~= nil and type(info.size) == "number" and info.size > 0
end
local expand_properties
expand_properties = function(text, magic)
  if magic == nil then
    magic = "$"
  end
  for prefix, raw, prop, colon, fallback, closing in text:gmatch("%" .. magic .. "{([?!]?)(=?)([^}:]*)(:?)([^}]*)(}*)}") do
    local err
    local prop_value
    local compare_value
    local original_prop = prop
    local get_property = mp.get_property_osd
    if raw == "=" then
      get_property = mp.get_property
    end
    if prefix ~= "" then
      for actual_prop, compare in prop:gmatch("(.-)==(.*)") do
        prop = actual_prop
        compare_value = compare
      end
    end
    if colon == ":" then
      prop_value, err = get_property(prop, fallback)
    else
      prop_value, err = get_property(prop, "(error)")
    end
    prop_value = tostring(prop_value)
    if prefix == "?" then
      if compare_value == nil then
        prop_value = err == nil and fallback .. closing or ""
      else
        prop_value = prop_value == compare_value and fallback .. closing or ""
      end
      prefix = "%" .. prefix
    elseif prefix == "!" then
      if compare_value == nil then
        prop_value = err ~= nil and fallback .. closing or ""
      else
        prop_value = prop_value ~= compare_value and fallback .. closing or ""
      end
    else
      prop_value = prop_value .. closing
    end
    if colon == ":" then
      local _
      text, _ = text:gsub("%" .. magic .. "{" .. prefix .. raw .. original_prop:gsub("%W", "%%%1") .. ":" .. fallback:gsub("%W", "%%%1") .. closing .. "}", expand_properties(prop_value))
    else
      local _
      text, _ = text:gsub("%" .. magic .. "{" .. prefix .. raw .. original_prop:gsub("%W", "%%%1") .. closing .. "}", prop_value)
    end
  end
  return text
end
local format_filename
format_filename = function(startTime, endTime, videoFormat)
  local hasAudioCodec = videoFormat:getAudioCodec() ~= ""
  local replaceFirst = {
    ["%%mp"] = "%%mH.%%mM.%%mS",
    ["%%mP"] = "%%mH.%%mM.%%mS.%%mT",
    ["%%p"] = "%%wH.%%wM.%%wS",
    ["%%P"] = "%%wH.%%wM.%%wS.%%wT"
  }
  local replaceTable = {
    ["%%wH"] = string.format("%02d", math.floor(startTime / (60 * 60))),
    ["%%wh"] = string.format("%d", math.floor(startTime / (60 * 60))),
    ["%%wM"] = string.format("%02d", math.floor(startTime / 60 % 60)),
    ["%%wm"] = string.format("%d", math.floor(startTime / 60)),
    ["%%wS"] = string.format("%02d", math.floor(startTime % 60)),
    ["%%ws"] = string.format("%d", math.floor(startTime)),
    ["%%wf"] = string.format("%s", startTime),
    ["%%wT"] = string.sub(string.format("%.3f", startTime % 1), 3),
    ["%%mH"] = string.format("%02d", math.floor(endTime / (60 * 60))),
    ["%%mh"] = string.format("%d", math.floor(endTime / (60 * 60))),
    ["%%mM"] = string.format("%02d", math.floor(endTime / 60 % 60)),
    ["%%mm"] = string.format("%d", math.floor(endTime / 60)),
    ["%%mS"] = string.format("%02d", math.floor(endTime % 60)),
    ["%%ms"] = string.format("%d", math.floor(endTime)),
    ["%%mf"] = string.format("%s", endTime),
    ["%%mT"] = string.sub(string.format("%.3f", endTime % 1), 3),
    ["%%f"] = mp.get_property("filename"),
    ["%%F"] = mp.get_property("filename/no-ext"),
    ["%%s"] = seconds_to_path_element(startTime),
    ["%%S"] = seconds_to_path_element(startTime, true),
    ["%%e"] = seconds_to_path_element(endTime),
    ["%%E"] = seconds_to_path_element(endTime, true),
    ["%%T"] = mp.get_property("media-title"),
    ["%%M"] = (mp.get_property_native('aid') and not mp.get_property_native('mute') and hasAudioCodec) and '-audio' or '',
    ["%%R"] = (options.scale_height ~= -1) and "-" .. tostring(options.scale_height) .. "p" or "-" .. tostring(mp.get_property_native('height')) .. "p",
    ["%%t%%"] = "%%"
  }
  local filename = options.output_template
  for format, value in pairs(replaceFirst) do
    local _
    filename, _ = filename:gsub(format, value)
  end
  for format, value in pairs(replaceTable) do
    local _
    filename, _ = filename:gsub(format, value)
  end
  if mp.get_property_bool("demuxer-via-network", false) then
    local _
    filename, _ = filename:gsub("%%X{([^}]*)}", "%1")
    filename, _ = filename:gsub("%%x", "")
  else
    local x = string.gsub(mp.get_property("stream-open-filename", ""), string.gsub(mp.get_property("filename", ""), "%W", "%%%1") .. "$", "")
    local _
    filename, _ = filename:gsub("%%X{[^}]*}", x)
    filename, _ = filename:gsub("%%x", x)
  end
  filename = expand_properties(filename, "%")
  for format in filename:gmatch("%%t([aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZ])") do
    local _
    filename, _ = filename:gsub("%%t" .. format, os.date("%" .. format))
  end
  local _
  filename, _ = filename:gsub("[<>:\"/\\|?*]", "")
  return tostring(filename) .. "." .. tostring(videoFormat:getExtension())
end
local parse_directory
parse_directory = function(dir)
  local home_dir = os.getenv("HOME")
  if not home_dir then
    home_dir = os.getenv("USERPROFILE")
  end
  if not home_dir then
    local drive = os.getenv("HOMEDRIVE")
    local path = os.getenv("HOMEPATH")
    if drive and path then
      home_dir = utils.join_path(drive, path)
    else
      msg.warn("Couldn't find home dir.")
      home_dir = ""
    end
  end
  local _
  dir, _ = dir:gsub("^~", home_dir)
  return dir
end
local calculate_scale_factor
calculate_scale_factor = function()
  local baseResY = 720
  local _, osd_h = mp.get_osd_size()
  return osd_h / baseResY
end
-- Unique per running mpv instance -- lets multiple concurrent encodes
-- (different mpv processes) avoid clobbering each other's temp attempt
-- files and two-pass log files when they land in the same output
-- directory. PID is used when available (mpv 0.33+); older mpv falls
-- back to a time+random token.
local instance_id
do
  local pid = mp.get_property_number("pid", 0)
  math.randomseed(os.time() + pid + math.floor(os.clock() * 1e6))
  if pid > 0 then
    instance_id = tostring(pid)
  else
    instance_id = tostring(os.time()) .. tostring(math.random(100000, 999999))
  end
end
local get_pass_logfile_path
get_pass_logfile_path = function(encode_out_path)
  -- mpv's libavcodec encoding driver chooses this path automatically when
  -- AV_CODEC_FLAG_PASS1/PASS2 is enabled.
  return tostring(encode_out_path) .. "-video-pass1.log"
end
local dimensions_changed = true
local _video_dimensions = { }
local get_video_dimensions
get_video_dimensions = function()
  if not (dimensions_changed) then
    return _video_dimensions
  end
  local video_params = mp.get_property_native("video-out-params")
  if not video_params then
    return nil
  end
  dimensions_changed = false
  local keep_aspect = mp.get_property_bool("keepaspect")
  local w = video_params["w"]
  local h = video_params["h"]
  local dw = video_params["dw"]
  local dh = video_params["dh"]
  if mp.get_property_number("video-rotate") % 180 == 90 then
    w, h = h, w
    dw, dh = dh, dw
  end
  _video_dimensions = {
    top_left = { },
    bottom_right = { },
    ratios = { }
  }
  local window_w, window_h = mp.get_osd_size()
  if window_w <= 0 or window_h <= 0 then
    -- Headless/VO-null runs have no OSD surface. Keep crop coordinates in
    -- source pixels instead of allowing a zero-sized display to create NaN.
    _video_dimensions.top_left.x = 0
    _video_dimensions.bottom_right.x = w
    _video_dimensions.top_left.y = 0
    _video_dimensions.bottom_right.y = h
  elseif keep_aspect then
    local unscaled = mp.get_property_native("video-unscaled")
    local panscan = mp.get_property_number("panscan")
    local fwidth = window_w
    local fheight = math.floor(window_w / dw * dh)
    if fheight > window_h or fheight < h then
      local tmpw = math.floor(window_h / dh * dw)
      if tmpw <= window_w then
        fheight = window_h
        fwidth = tmpw
      end
    end
    local vo_panscan_area = window_h - fheight
    local f_w = fwidth / fheight
    local f_h = 1
    if vo_panscan_area == 0 then
      vo_panscan_area = window_h - fwidth
      f_w = 1
      f_h = fheight / fwidth
    end
    if unscaled or unscaled == "downscale-big" then
      vo_panscan_area = 0
      if unscaled or (dw <= window_w and dh <= window_h) then
        fwidth = dw
        fheight = dh
      end
    end
    local scaled_width = fwidth + math.floor(vo_panscan_area * panscan * f_w)
    local scaled_height = fheight + math.floor(vo_panscan_area * panscan * f_h)
    local split_scaling
    split_scaling = function(dst_size, scaled_src_size, zoom, align, pan)
      scaled_src_size = math.floor(scaled_src_size * 2 ^ zoom)
      align = (align + 1) / 2
      local dst_start = math.floor((dst_size - scaled_src_size) * align + pan * scaled_src_size)
      if dst_start < 0 then
        dst_start = dst_start + 1
      end
      local dst_end = dst_start + scaled_src_size
      if dst_start >= dst_end then
        dst_start = 0
        dst_end = 1
      end
      return dst_start, dst_end
    end
    local zoom = mp.get_property_number("video-zoom")
    local align_x = mp.get_property_number("video-align-x")
    local pan_x = mp.get_property_number("video-pan-x")
    _video_dimensions.top_left.x, _video_dimensions.bottom_right.x = split_scaling(window_w, scaled_width, zoom, align_x, pan_x)
    local align_y = mp.get_property_number("video-align-y")
    local pan_y = mp.get_property_number("video-pan-y")
    _video_dimensions.top_left.y, _video_dimensions.bottom_right.y = split_scaling(window_h, scaled_height, zoom, align_y, pan_y)
  else
    _video_dimensions.top_left.x = 0
    _video_dimensions.bottom_right.x = window_w
    _video_dimensions.top_left.y = 0
    _video_dimensions.bottom_right.y = window_h
  end
  _video_dimensions.ratios.w = w / (_video_dimensions.bottom_right.x - _video_dimensions.top_left.x)
  _video_dimensions.ratios.h = h / (_video_dimensions.bottom_right.y - _video_dimensions.top_left.y)
  return _video_dimensions
end
local set_dimensions_changed
set_dimensions_changed = function()
  dimensions_changed = true
end
local monitor_dimensions
monitor_dimensions = function()
  local properties = {
    "keepaspect",
    "video-out-params",
    "video-unscaled",
    "panscan",
    "video-zoom",
    "video-align-x",
    "video-pan-x",
    "video-align-y",
    "video-pan-y",
    "osd-width",
    "osd-height"
  }
  for _, p in ipairs(properties) do
    mp.observe_property(p, "native", set_dimensions_changed)
  end
end
local clamp
clamp = function(min, val, max)
  if val <= min then
    return min
  end
  if val >= max then
    return max
  end
  return val
end
local clamp_point
clamp_point = function(top_left, point, bottom_right)
  return {
    x = clamp(top_left.x, point.x, bottom_right.x),
    y = clamp(top_left.y, point.y, bottom_right.y)
  }
end
-- Shared constructor for the page and format classes.
local function make_class(definition)
  local methods = definition.__base
  local parent = definition.__parent
  methods.__index = methods
  if parent then
    setmetatable(methods, parent.__base)
  end
  local class = setmetatable(definition, {
    __index = function(_, name)
      local value = rawget(methods, name)
      if value ~= nil then
        return value
      end
      return parent and parent[name]
    end,
    __call = function(cls, ...)
      local instance = setmetatable({}, methods)
      cls.__init(instance, ...)
      return instance
    end
  })
  methods.__class = class
  if parent and parent.__inherited then
    parent.__inherited(parent, class)
  end
  return class
end
local VideoPoint
do
  local _class_0
  local _base_0 = {
    set_from_screen = function(self, sx, sy)
      local d = get_video_dimensions()
      local point = clamp_point(d.top_left, {
        x = sx,
        y = sy
      }, d.bottom_right)
      self.x = math.floor(d.ratios.w * (point.x - d.top_left.x) + 0.5)
      self.y = math.floor(d.ratios.h * (point.y - d.top_left.y) + 0.5)
    end,
    to_screen = function(self)
      local d = get_video_dimensions()
      return {
        x = math.floor(self.x / d.ratios.w + d.top_left.x + 0.5),
        y = math.floor(self.y / d.ratios.h + d.top_left.y + 0.5)
      }
    end
  }
  _base_0.__index = _base_0
  _class_0 = setmetatable({
    __init = function(self)
      self.x = -1
      self.y = -1
    end,
    __base = _base_0,
    __name = "VideoPoint"
  }, {
    __index = _base_0,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  VideoPoint = _class_0
end
local Region
do
  local _class_0
  local _base_0 = {
    is_valid = function(self)
      return self.x > -1 and self.y > -1 and self.w > -1 and self.h > -1
    end,
    set_from_points = function(self, p1, p2)
      self.x = math.min(p1.x, p2.x)
      self.y = math.min(p1.y, p2.y)
      self.w = math.abs(p1.x - p2.x)
      self.h = math.abs(p1.y - p2.y)
    end
  }
  _base_0.__index = _base_0
  _class_0 = setmetatable({
    __init = function(self)
      self.x = -1
      self.y = -1
      self.w = -1
      self.h = -1
    end,
    __base = _base_0,
    __name = "Region"
  }, {
    __index = _base_0,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  Region = _class_0
end
local formats = { }
local video_codec_profiles = {
  ["libvpx-vp9"] = {
    displayName = "VP9", extension = "webm",
    deferPlainColorFilter = true, clampFilter = "lavfi-limiter=min=0:max=1023",
    normalTwoPass = true, targetTwoPass = true, targetSize = true,
    bitrateMin = 64000, bitrateMax = 100000000
  },
  ["libx264"] = {
    displayName = "AVC", extension = "mp4",
    targetTwoPass = true, targetSize = true,
    bitrateMin = 64000, bitrateMax = 100000000
  },
  ["libx265"] = {
    displayName = "HEVC", extension = "mp4",
    targetTwoPass = false, targetSize = true,
    bitrateMin = 48000, bitrateMax = 100000000
  },
  ["libsvtav1"] = {
    displayName = "AV1", extension = "webm",
    targetTwoPass = false, targetSize = true,
    bitrateMin = 32000, bitrateMax = 100000000
  },
  ["h264_nvenc"] = {
    displayName = "NVENC AVC", extension = "mp4",
    targetTwoPass = false, targetSize = true, requiresNativeMultipass = true,
    bitrateMin = 128000, bitrateMax = 200000000
  },
  ["hevc_nvenc"] = {
    displayName = "NVENC HEVC", extension = "mp4",
    targetTwoPass = false, targetSize = true, requiresNativeMultipass = true,
    bitrateMin = 96000, bitrateMax = 200000000
  },
  ["av1_nvenc"] = {
    displayName = "NVENC AV1", extension = "mp4",
    targetTwoPass = false, targetSize = true, requiresNativeMultipass = true,
    bitrateMin = 96000, bitrateMax = 200000000
  }
}
local get_codec_color_filters
get_codec_color_filters = function(codec, configuredFilter)
  local profile = video_codec_profiles[codec] or { }
  local filter = tostring(configuredFilter)
  local preFilters = { }
  local postFilters = { }
  if profile.deferPlainColorFilter and not filter:find("libplacebo", 1, true) then
    -- Keep real tone mapping before scale, but defer a plain 8->10-bit
    -- format conversion until afterward. That keeps Lanczos ringing in the
    -- clamped 8-bit range before libvpx's strict 10-bit input validation.
    postFilters[#postFilters + 1] = filter
  else
    preFilters[#preFilters + 1] = filter
  end
  if profile.clampFilter then
    postFilters[#postFilters + 1] = profile.clampFilter
  end
  return preFilters, postFilters
end
local get_audio_bitrate
get_audio_bitrate = function(codec)
  if codec == "aac" then
    return options.aac_bitrate
  elseif codec == "libmp3lame" then
    return options.mp3_bitrate
  end
  return options.opus_bitrate
end
local get_native_audio_codec
get_native_audio_codec = function(codec)
  -- Current libavcodec exposes the native Opus encoder to mpv as "opus"
  -- even though the conventional library-style name is "libopus".
  if codec == "libopus" then
    return "opus"
  end
  return tostring(codec)
end
local get_audio_encode_flags
get_audio_encode_flags = function(codec)
  return {
    "--oac=" .. get_native_audio_codec(codec),
    "--oacopts-add=b=" .. tostring(get_audio_bitrate(codec))
  }
end
local get_video_color_params
get_video_color_params = function()
  return mp.get_property_native("video-params") or { }
end

local normalize_color_name
normalize_color_name = function(value)
  local name = string.lower(tostring(value or ""))
  name = name:gsub("[%.%-%_]", "")
  return name
end

local is_hdr_source
is_hdr_source = function()
  local params = get_video_color_params()
  local gamma = normalize_color_name(params["gamma"])
  return gamma == "pq" or gamma == "smpte2084" or gamma == "hlg" or gamma == "aribstdb67"
end

local get_color_tag_flags
get_color_tag_flags = function(prefilter_value)
  -- Standard SDR outputs use BT.709 primaries/matrix/transfer and limited
  -- range. HDR is left alone when Tone Mapping is Off. Any libplacebo
  -- prefilter is already explicitly producing the BT.709/tv target.
  local has_libplacebo = tostring(prefilter_value):find("libplacebo", 1, true) ~= nil
  if has_libplacebo or not is_hdr_source() then
    return {
      "--ovcopts-add=colorspace=bt709",
      "--ovcopts-add=color_primaries=bt709",
      "--ovcopts-add=color_trc=bt709",
      "--ovcopts-add=color_range=tv"
    }
  end
  return { }
end

local get_sdr_normalization_filter
get_sdr_normalization_filter = function(format)
  -- Normalize only when the SDR source actually needs it. This performs the
  -- real conversion (range, matrix, primaries and/or transfer), rather than
  -- merely changing the metadata. Sources already in BT.709/limited pass
  -- through without an extra libplacebo conversion.
  if not format or format:getVideoCodec() == "" then
    return nil
  end
  if is_hdr_source() then
    return nil
  end
  local prefilters = format:getPreFilters()
  for _, filter in ipairs(prefilters) do
    if tostring(filter):find("libplacebo", 1, true) then
      return nil
    end
  end

  local params = get_video_color_params()
  local matrix = normalize_color_name(params["colormatrix"])
  local primaries = normalize_color_name(params["primaries"])
  local gamma = normalize_color_name(params["gamma"])
  local levels = normalize_color_name(params["colorlevels"])

  local needs_range = levels == "full" or levels == "pc"
  local needs_matrix = matrix ~= "" and matrix ~= "unknown" and matrix ~= "bt709"
  local needs_primaries = primaries ~= "" and primaries ~= "unknown" and primaries ~= "bt709" and primaries ~= "srgb"
  local needs_transfer = gamma ~= "" and gamma ~= "unknown" and gamma ~= "bt709"

  if not (needs_range or needs_matrix or needs_primaries or needs_transfer) then
    return nil
  end

  return "libplacebo=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv"
end

local get_vp9_video_flags
get_vp9_video_flags = function(pass, speed, ctx)
  local fps = options.fps > -1 and options.fps or (mp.get_property_native("container-fps") or 30)
  local flags = {
    "--ovc=libvpx-vp9",
    "--ovcopts-add=deadline=good",
    "--ovcopts-add=speed=" .. tostring(speed or (pass == 1 and 4 or 0)),
    "--ovcopts-add=profile=2",
    "--ovcopts-add=row-mt=1",
    "--ovcopts-add=tile-columns=0",
    "--ovcopts-add=aq-mode=1",
    "--ovcopts-add=g=" .. tostring(math.floor(fps * 10 + 0.5)),
    "--ovcopts-add=frame-parallel=0"
  }
  if ctx and ctx.targetBitrate then
    flags[#flags + 1] = "--ovcopts-add=b=" .. tostring(ctx.targetBitrate)
  else
    flags[#flags + 1] = "--ovcopts-add=crf=" .. tostring(options.crf_webm)
    flags[#flags + 1] = "--ovcopts-add=b=0"
  end
  if pass ~= 1 then
    append(flags, {
      "--ovcopts-add=lag-in-frames=25",
      "--ovcopts-add=auto-alt-ref=6",
      "--ovcopts-add=arnr-maxframes=7",
      "--ovcopts-add=arnr-strength=4",
      "--ovcopts-add=arnr-type=3",
      "--ovcopts-add=enable-tpl=1"
    })
  end
  append(flags, get_color_tag_flags(options.color_filter_10bit))
  return flags
end
local get_mp4_video_flags
get_mp4_video_flags = function(codec, ctx, presetOverride)
  local preset = codec == "libx265" and options.preset_hevc or options.preset_avc
  preset = presetOverride or preset
  local tune = codec == "libx265" and options.tune_hevc or options.tune_avc
  local flags = {
    "--ovc=" .. codec,
    "--ovcopts-add=preset=" .. tostring(preset),
    "--ofopts-add=movflags=+faststart"
  }
  if ctx and ctx.targetBitrate then
    flags[#flags + 1] = "--ovcopts-add=b=" .. tostring(ctx.targetBitrate)
  else
    flags[#flags + 1] = "--ovcopts-add=crf=" .. tostring(options.crf_mp4)
  end
  if tune ~= "" then
    flags[#flags + 1] = "--ovcopts-add=tune=" .. tostring(tune)
  end
  append(flags, get_color_tag_flags(options.color_filter_8bit))
  return flags
end
local get_svt_av1_video_flags
get_svt_av1_video_flags = function(ctx)
  local preset = tonumber(options.preset_av1) or 6
  local flags = {
    "--ovc=libsvtav1",
    "--ovcopts-add=preset=" .. tostring(preset),
    "--ovcopts-add=svtav1-params=tune=1:enable-variance-boost=1:enable-qm=1:ac-bias=1:tf-strength=1:qp-scale-compress-strength=1:sharpness=1:keyint=10s"
  }
  if ctx and ctx.targetBitrate then
    flags[#flags + 1] = "--ovcopts-add=b=" .. tostring(ctx.targetBitrate)
  else
    flags[#flags + 1] = "--ovcopts-add=crf=" .. tostring(options.crf_webm)
  end
  append(flags, get_color_tag_flags(options.color_filter_10bit))
  return flags
end
local get_basket_x264_video_flags
get_basket_x264_video_flags = function(_pass, ctx)
  -- libx264 requires pass-affecting settings (including the preset's b-frame
  -- policy) to match between both native passes. Its own fast-first-pass path
  -- supplies the analysis optimization; changing presets makes pass 2 reject
  -- the statistics file.
  local preset = options.basket_final_preset
  local flags = get_mp4_video_flags("libx264", ctx, preset)
  flags[#flags + 1] = "--ovcopts-add=tune=animation"
  return flags
end
video_codec_profiles["libx264"].mp4Flags = function(ctx)
  return get_mp4_video_flags("libx264", ctx)
end
video_codec_profiles["libx264"].basketFlags = get_basket_x264_video_flags
video_codec_profiles["libx265"].mp4Flags = function(ctx)
  return get_mp4_video_flags("libx265", ctx)
end
video_codec_profiles["libsvtav1"].flags = get_svt_av1_video_flags
video_codec_profiles["libvpx-vp9"].flags = get_vp9_video_flags
local get_nvenc_video_flags
get_nvenc_video_flags = function(codec, ctx)
  local tune = codec == "h264_nvenc" and "hq" or "uhq"
  local cq = codec == "av1_nvenc" and options.cq_nvenc_av1 or options.cq_nvenc
  local flags = {
    "--ovc=" .. codec,
    "--ovcopts-add=preset=p7",
    "--ovcopts-add=tune=" .. tune,
    "--ovcopts-add=spatial-aq=1",
    "--ovcopts-add=temporal-aq=1",
    "--ovcopts-add=rc-lookahead=32",
    "--ovcopts-add=b_ref_mode=each",
    "--ofopts-add=movflags=+faststart"
  }
  if ctx and ctx.targetBitrate then
    local bitrate = tostring(ctx.targetBitrate)
    append(flags, {
      "--ovcopts-add=multipass=fullres",
      "--ovcopts-add=rc=cbr",
      "--ovcopts-add=b=" .. bitrate,
      "--ovcopts-add=minrate=" .. bitrate,
      "--ovcopts-add=maxrate=" .. bitrate,
      "--ovcopts-add=bufsize=" .. tostring(ctx.targetBitrate * 2)
    })
  else
    append(flags, {
      "--ovcopts-add=rc=vbr",
      "--ovcopts-add=cq=" .. tostring(cq)
    })
  end
  if codec == "av1_nvenc" then
    flags[#flags + 1] = "--ovcopts-add=lookahead_level=3"
  end
  append(flags, get_color_tag_flags(options.color_filter_8bit))
  return flags
end
video_codec_profiles["h264_nvenc"].flags = function(ctx)
  return get_nvenc_video_flags("h264_nvenc", ctx)
end
video_codec_profiles["hevc_nvenc"].flags = function(ctx)
  return get_nvenc_video_flags("hevc_nvenc", ctx)
end
video_codec_profiles["av1_nvenc"].flags = function(ctx)
  return get_nvenc_video_flags("av1_nvenc", ctx)
end
local Format
do
  local _class_0
  local _base_0 = {
    getPreFilters = function(self)
      return { }
    end,
    getPostFilters = function(self)
      return { }
    end,
    getFlags = function(self)
      return { }
    end,
    getVideoCodec = function(self)
      return self.videoCodec
    end,
    getAudioCodec = function(self)
      return self.audioCodec
    end,
    getCodecProfile = function(self)
      return video_codec_profiles[self:getVideoCodec()] or { }
    end,
    getTargetSizeProfile = function(self)
      return self:getCodecProfile().targetSize
    end,
    supportsTwoPass = function(self, ctx)
      local profile = self:getCodecProfile()
      if ctx and ctx.targetBitrate then
        return profile.targetTwoPass == true
      end
      return profile.normalTwoPass == true
    end,
    getCodecFlags = function(self)
      local codecs = { }
      if self:getVideoCodec() == "" then
        codecs[#codecs + 1] = "--vid=no"
      end
      if self:getAudioCodec() == "" then
        codecs[#codecs + 1] = "--aid=no"
      end
      return codecs
    end,
    getMuxer = function(self)
      return self.outputMuxer
    end,
    getExtension = function(self)
      return self.outputExtension
    end
  }
  _base_0.__index = _base_0
  _class_0 = setmetatable({
    __init = function(self)
      self.displayName = "Basic"
      self.videoCodec = ""
      self.audioCodec = ""
      self.outputExtension = ""
      self.outputMuxer = nil
    end,
    __base = _base_0,
    __name = "Format"
  }, {
    __index = _base_0,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  Format = _class_0
end
local MP4
do
  local _class_0
  local _parent_0 = Format
  local _base_0 = {
    getVideoCodec = function(self)
      return tostring(options.video_codec_mp4)
    end,
    getAudioCodec = function(self)
      return tostring(options.audio_codec_muxed)
    end,
    getPreFilters = function(self)
      return {
        tostring(options.color_filter_8bit)
      }
    end,
    getFlags = function(self, ctx, pass)
      local flags = self:getCodecProfile().mp4Flags(ctx)
      if pass ~= 1 then
        append(flags, get_audio_encode_flags(options.audio_codec_muxed))
      end
      return flags
    end
  }
  _base_0.__index = _base_0
  _class_0 = make_class({
    __init = function(self)
      self.displayName = "MP4"
      self.videoCodec = tostring(options.video_codec_mp4)
      self.audioCodec = tostring(options.audio_codec_muxed)
      self.outputExtension = "mp4"
      self.outputMuxer = "mp4"
    end,
    __base = _base_0,
    __name = "MP4",
    __parent = _parent_0
  })
  MP4 = _class_0
end
formats["mp4"] = MP4()
local WebM
do
  local _class_0
  local _parent_0 = Format
  local _base_0 = {
    getVideoCodec = function(self)
      return tostring(options.video_codec_webm)
    end,
    getPreFilters = function(self)
      local preFilters = get_codec_color_filters(self:getVideoCodec(), options.color_filter_10bit)
      return preFilters
    end,
    getPostFilters = function(self)
      local _, postFilters = get_codec_color_filters(self:getVideoCodec(), options.color_filter_10bit)
      return postFilters
    end,
    getExtension = function(self)
      return self:getCodecProfile().extension or self.outputExtension
    end,
    getFlags = function(self, ctx, pass)
      local flags
      if self:getVideoCodec() == "libsvtav1" then
        flags = self:getCodecProfile().flags(ctx)
      else
        flags = self:getCodecProfile().flags(pass, nil, ctx)
      end
      if pass ~= 1 then
        append(flags, get_audio_encode_flags("libopus"))
      end
      return flags
    end
  }
  _base_0.__index = _base_0
  _class_0 = make_class({
    __init = function(self)
      self.displayName = "WebM"
      self.videoCodec = "libsvtav1"
      self.audioCodec = "libopus"
      self.outputExtension = "webm"
      self.outputMuxer = "webm"
    end,
    __base = _base_0,
    __name = "WebM",
    __parent = _parent_0
  })
  WebM = _class_0
end
formats["WebM"] = WebM()
local Audio
do
  local _class_0
  local _parent_0 = Format
  local _base_0 = {
    getAudioCodec = function(self)
      return tostring(options.audio_codec_audio)
    end,
    getExtension = function(self)
      if options.audio_codec_audio == "libmp3lame" then
        return "mp3"
      elseif options.audio_codec_audio == "aac" then
        return "m4a"
      end
      return "ogg"
    end,
    getMuxer = function(self)
      if options.audio_codec_audio == "aac" then
        return "ipod"
      elseif options.audio_codec_audio == "libmp3lame" then
        return "mp3"
      end
      return "ogg"
    end,
    getFlags = function(self)
      return get_audio_encode_flags(options.audio_codec_audio)
    end
  }
  _base_0.__index = _base_0
  _class_0 = make_class({
    __init = function(self)
      self.displayName = "Audio"
      self.videoCodec = ""
      self.audioCodec = "libopus"
      self.outputExtension = "ogg"
      self.outputMuxer = "ogg"
    end,
    __base = _base_0,
    __name = "Audio",
    __parent = _parent_0
  })
  Audio = _class_0
end
formats["Audio"] = Audio()
local Animated
do
  local _class_0
  local _parent_0 = Format
  local _base_0 = {
    getVideoCodec = function(self)
      return "libwebp_anim"
    end,
    getExtension = function(self)
      return "webp"
    end,
    getFlags = function(self)
      return {
        "--ovc=libwebp_anim",
        "--ofopts-add=loop=0",
        "--ovcopts-add=lossless=0",
        "--ovcopts-add=compression_level=" .. tostring(options.compression_level_webp),
        "--ovcopts-add=quality=" .. tostring(options.quality_webp)
      }
    end
  }
  _base_0.__index = _base_0
  _class_0 = make_class({
    __init = function(self)
      self.displayName = "Animated"
      self.videoCodec = "libwebp_anim"
      self.audioCodec = ""
      self.outputExtension = "webp"
      self.outputMuxer = "webp"
    end,
    __base = _base_0,
    __name = "Animated",
    __parent = _parent_0
  })
  Animated = _class_0
end
formats["Animated"] = Animated()
local NVENC
do
  local _class_0
  local _parent_0 = Format
  local _base_0 = {
    getVideoCodec = function(self)
      return tostring(options.video_codec_nvenc)
    end,
    getAudioCodec = function(self)
      return tostring(options.audio_codec_muxed)
    end,
    getPreFilters = function(self)
      local filter = tostring(options.color_filter_8bit)
      -- AV1 NVENC is the only NVENC profile here which intentionally uses
      -- a 10-bit input surface. Keep that decision with the codec that owns
      -- it instead of leaking it into the MP4 software-encoder family.
      if self:getVideoCodec() == "av1_nvenc" then
        filter = filter:gsub("format=yuv420p$", "format=yuv420p10le")
        filter = filter:gsub("format=yuv420p,", "format=yuv420p10le,")
      end
      return {
        filter
      }
    end,
    getFlags = function(self, ctx, pass)
      local flags = self:getCodecProfile().flags(ctx)
      if pass ~= 1 then
        append(flags, get_audio_encode_flags(options.audio_codec_muxed))
      end
      return flags
    end
  }
  _base_0.__index = _base_0
  _class_0 = make_class({
    __init = function(self)
      self.displayName = "NVENC"
      self.videoCodec = "nvenc"
      self.audioCodec = "libopus"
      self.outputExtension = "mp4"
      self.outputMuxer = "mp4"
    end,
    __base = _base_0,
    __name = "NVENC",
    __parent = _parent_0
  })
  NVENC = _class_0
end
formats["NVENC"] = NVENC()
local Basket
do
  local _class_0
  local _parent_0 = Format
  local _base_0 = {
    getVideoCodec = function(self)
      return tostring(options.video_codec_basket)
    end,
    getPreFilters = function(self)
      if self:getVideoCodec() == "libvpx-vp9" then
        local preFilters = get_codec_color_filters(self:getVideoCodec(), options.color_filter_10bit)
        return preFilters
      end
      return {
        tostring(options.color_filter_8bit)
      }
    end,
    getPostFilters = function(self)
      if self:getVideoCodec() == "libvpx-vp9" then
        local _, postFilters = get_codec_color_filters(self:getVideoCodec(), options.color_filter_10bit)
        return postFilters
      end
      return { }
    end,
    getExtension = function(self)
      return self:getCodecProfile().extension or self.outputExtension
    end,
    getMuxer = function(self)
      return self:getVideoCodec() == "libvpx-vp9" and "webm" or "mp4"
    end,
    getFlags = function(self, ctx, pass)
      local profile = self:getCodecProfile()
      if self:supportsTwoPass(ctx) and self:getVideoCodec() == "libvpx-vp9" then
        local speed
        if pass == 1 then
          speed = options.basket_first_pass_speed
        elseif ctx and ctx.targetBitrate then
          speed = options.basket_final_second_pass_speed
        else
          speed = options.basket_search_second_pass_speed
        end
        return profile.flags(pass, speed, ctx)
      end
      return profile.basketFlags(pass, ctx)
    end
  }
  _base_0.__index = _base_0
  _class_0 = make_class({
    __init = function(self)
      self.displayName = "Basket"
      self.videoCodec = "video"
      self.audioCodec = ""
      self.outputExtension = "mp4"
      self.outputMuxer = "mp4"
    end,
    __base = _base_0,
    __name = "Basket",
    __parent = _parent_0
  })
  Basket = _class_0
end
formats["Basket"] = Basket()
local Page
do
  local _class_0
  local _base_0 = {
    add_keybinds = function(self)
      if not self.keybinds then
        return 
      end
      for key, func in pairs(self.keybinds) do
        mp.add_forced_key_binding(key, key, func, {
          repeatable = true
        })
      end
    end,
    remove_keybinds = function(self)
      if not self.keybinds then
        return 
      end
      for key, _ in pairs(self.keybinds) do
        mp.remove_key_binding(key)
      end
    end,
    observe_properties = function(self)
      self.sizeCallback = function()
        return self:draw()
      end
      local properties = {
        "keepaspect",
        "video-out-params",
        "video-unscaled",
        "panscan",
        "video-zoom",
        "video-align-x",
        "video-pan-x",
        "video-align-y",
        "video-pan-y",
        "osd-width",
        "osd-height"
      }
      for _index_0 = 1, #properties do
        local p = properties[_index_0]
        mp.observe_property(p, "native", self.sizeCallback)
      end
    end,
    unobserve_properties = function(self)
      if self.sizeCallback then
        mp.unobserve_property(self.sizeCallback)
        self.sizeCallback = nil
      end
    end,
    clear = function(self)
      local window_w, window_h = mp.get_osd_size()
      mp.set_osd_ass(window_w, window_h, "")
      return mp.osd_message("", 0)
    end,
    prepare = function(self)
      return nil
    end,
    dispose = function(self)
      return nil
    end,
    show = function(self)
      if self.visible then
        return 
      end
      self.visible = true
      self:observe_properties()
      self:add_keybinds()
      self:prepare()
      self:clear()
      return self:draw()
    end,
    hide = function(self)
      if not self.visible then
        return 
      end
      self.visible = false
      self:unobserve_properties()
      self:remove_keybinds()
      self:clear()
      return self:dispose()
    end,
    setup_text = function(self, ass)
      local scale = calculate_scale_factor()
      local margin = options.margin * scale
      ass:append("{\\an7}")
      ass:pos(margin, margin)
      return ass:append("{\\fs" .. tostring(options.font_size * scale) .. "}")
    end
  }
  _base_0.__index = _base_0
  _class_0 = setmetatable({
    __init = function() end,
    __base = _base_0,
    __name = "Page"
  }, {
    __index = _base_0,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  Page = _class_0
end
-- One coroutine owns a complete job, including Basket audio/video staging and
-- native two-pass encodes.
local active_encode
local function track_encode_file(path)
  if active_encode and path then active_encode.files[path] = true end
  return path
end
local function cancel_encode()
  if not active_encode then return end
  active_encode.cancelled = true
  if active_encode.request then active_encode.request:abort() end
end
local function retain_encode_file(path)
  if path and active_encode then active_encode.files[path] = nil end
end
local function finish_encode(job, status, attempt)
  local pending = false
  for path in pairs(job.files) do
    if not os.remove(path) and file_exists(path) then pending = true end
  end
  -- Windows can briefly retain file handles after an aborted process exits.
  if pending and attempt < 20 then
    mp.add_timeout(0.1, function() finish_encode(job, status, attempt + 1) end)
    return
  end
  if pending then msg.warn("Some encoder temporary files could not be removed") end
  active_encode = nil
  if job.unloadHook then job.unloadHook:cont() end
  msg.info("Encode job " .. status)
  mp.commandv("script-message", "encoder-finished", status)
end
local function resume_encode(...)
  local job = active_encode
  if not job then return end
  local ok, err = coroutine.resume(job.thread, ...)
  if not ok or coroutine.status(job.thread) == "dead" then
    if not ok then
      msg.error("Encode error: " .. tostring(err))
      if job.request then job.request:abort() end
      if job.timer then job.timer:kill() end
      if job.page then job.page:hide() end
      for path in pairs(job.files) do os.remove(path) end
      message("Encode failed; see mpv log")
    elseif job.cancelled then
      message("Encode cancelled")
    end
    finish_encode(job, job.cancelled and "cancelled" or (ok and err == true and "finished" or "failed"), 0)
  end
end
-- Defer unloading long enough to reap child mpv and clean its files. This also
-- covers normal window closing, before mpv tears down the scripting runtime.
mp.add_hook("on_unload", 50, function(hook)
  if not active_encode then return end
  hook:defer()
  active_encode.unloadHook = hook
  cancel_encode()
end)
mp.register_event("shutdown", function()
  if not active_encode then return end
  cancel_encode()
  if active_encode.timer then active_encode.timer:kill() end
  for path in pairs(active_encode.files) do os.remove(path) end
end)
local EncodeWithProgress
-- Windows uses an inherited anonymous pipe instead of a temporary progress
-- script/file. CreateProcessW also avoids the console window from io.popen.
local windows_progress_process
if is_windows then
  local available, ffi = pcall(require, "ffi")
  if available then
    ffi.cdef[[
      typedef void *HANDLE;
      typedef unsigned long DWORD;
      typedef int BOOL;
      typedef unsigned short WORD;
      typedef struct {
        DWORD nLength; void *lpSecurityDescriptor; BOOL bInheritHandle;
      } SECURITY_ATTRIBUTES;
      typedef struct {
        DWORD cb; wchar_t *lpReserved; wchar_t *lpDesktop; wchar_t *lpTitle;
        DWORD dwX; DWORD dwY; DWORD dwXSize; DWORD dwYSize;
        DWORD dwXCountChars; DWORD dwYCountChars; DWORD dwFillAttribute;
        DWORD dwFlags; WORD wShowWindow; WORD cbReserved2;
        unsigned char *lpReserved2; HANDLE hStdInput; HANDLE hStdOutput;
        HANDLE hStdError;
      } STARTUPINFOW;
      typedef struct {
        HANDLE hProcess; HANDLE hThread; DWORD dwProcessId; DWORD dwThreadId;
      } PROCESS_INFORMATION;
      BOOL __stdcall CreatePipe(HANDLE *, HANDLE *, SECURITY_ATTRIBUTES *, DWORD);
      BOOL __stdcall SetHandleInformation(HANDLE, DWORD, DWORD);
      BOOL __stdcall CloseHandle(HANDLE);
      BOOL __stdcall CreateProcessW(const wchar_t *, wchar_t *, void *, void *,
        BOOL, DWORD, void *, const wchar_t *, STARTUPINFOW *, PROCESS_INFORMATION *);
      BOOL __stdcall PeekNamedPipe(HANDLE, void *, DWORD, DWORD *, DWORD *, DWORD *);
      BOOL __stdcall ReadFile(HANDLE, void *, DWORD, DWORD *, void *);
      DWORD __stdcall WaitForSingleObject(HANDLE, DWORD);
      BOOL __stdcall GetExitCodeProcess(HANDLE, DWORD *);
      BOOL __stdcall TerminateProcess(HANDLE, unsigned int);
      int __stdcall MultiByteToWideChar(unsigned int, DWORD, const char *, int,
        wchar_t *, int);
      DWORD __stdcall GetLastError(void);
    ]]
    local win = ffi.load("kernel32")
    local function wide(value)
      local count = win.MultiByteToWideChar(65001, 0, value, #value, nil, 0)
      if count == 0 then return nil end
      local buffer = ffi.new("wchar_t[?]", count + 1)
      if win.MultiByteToWideChar(65001, 0, value, #value, buffer, count) == 0 then
        return nil
      end
      return buffer
    end
    local function quote_arg(value)
      value = tostring(value)
      local parts, slashes = { '"' }, 0
      for i = 1, #value do
        local c = value:sub(i, i)
        if c == "\\" then
          slashes = slashes + 1
        elseif c == '"' then
          parts[#parts + 1] = string.rep("\\", slashes * 2 + 1) .. '"'
          slashes = 0
        else
          parts[#parts + 1] = string.rep("\\", slashes) .. c
          slashes = 0
        end
      end
      parts[#parts + 1] = string.rep("\\", slashes * 2) .. '"'
      return table.concat(parts)
    end
    windows_progress_process = function(args)
      local parts = {}
      for i, arg in ipairs(args) do parts[i] = quote_arg(arg) end
      local command = wide(table.concat(parts, " "))
      if not command then return nil, "Could not convert encoder command to UTF-16" end
      local attributes = ffi.new("SECURITY_ATTRIBUTES")
      attributes.nLength = ffi.sizeof(attributes)
      attributes.bInheritHandle = 1
      local outputRead, outputWrite = ffi.new("HANDLE[1]"), ffi.new("HANDLE[1]")
      local inputRead, inputWrite = ffi.new("HANDLE[1]"), ffi.new("HANDLE[1]")
      if win.CreatePipe(outputRead, outputWrite, attributes, 0) == 0 then
        return nil, "CreatePipe failed (" .. tonumber(win.GetLastError()) .. ")"
      end
      if win.CreatePipe(inputRead, inputWrite, attributes, 0) == 0 then
        win.CloseHandle(outputRead[0])
        win.CloseHandle(outputWrite[0])
        return nil, "CreatePipe failed (" .. tonumber(win.GetLastError()) .. ")"
      end
      local function close_setup_handles()
        win.CloseHandle(outputRead[0])
        win.CloseHandle(outputWrite[0])
        win.CloseHandle(inputRead[0])
        win.CloseHandle(inputWrite[0])
      end
      if win.SetHandleInformation(outputRead[0], 1, 0) == 0 or
          win.SetHandleInformation(inputWrite[0], 1, 0) == 0 then
        local code = tonumber(win.GetLastError())
        close_setup_handles()
        return nil, "SetHandleInformation failed (" .. code .. ")"
      end
      local startup = ffi.new("STARTUPINFOW")
      startup.cb = ffi.sizeof(startup)
      startup.dwFlags = 0x100 -- STARTF_USESTDHANDLES
      startup.hStdInput = inputRead[0]
      startup.hStdOutput = outputWrite[0]
      startup.hStdError = outputWrite[0]
      local info = ffi.new("PROCESS_INFORMATION")
      local started = win.CreateProcessW(nil, command, nil, nil, 1,
        0x08000000, nil, nil, startup, info) -- CREATE_NO_WINDOW
      local code = tonumber(win.GetLastError())
      win.CloseHandle(outputWrite[0])
      win.CloseHandle(inputRead[0])
      win.CloseHandle(inputWrite[0])
      if started == 0 then
        win.CloseHandle(outputRead[0])
        return nil, "CreateProcessW failed (" .. code .. ")"
      end
      win.CloseHandle(info.hThread)
      local process = { handle = info.hProcess, output = outputRead[0], buffer = "" }
      function process:read_lines(on_line)
        local availableBytes, bytesRead = ffi.new("DWORD[1]"), ffi.new("DWORD[1]")
        for _ = 1, 64 do
          if win.PeekNamedPipe(self.output, nil, 0, nil, availableBytes, nil) == 0 or
              availableBytes[0] == 0 then break end
          local count = math.min(tonumber(availableBytes[0]), 8192)
          local chunk = ffi.new("char[?]", count)
          if win.ReadFile(self.output, chunk, count, bytesRead, nil) == 0 or
              bytesRead[0] == 0 then break end
          self.buffer = self.buffer .. ffi.string(chunk, tonumber(bytesRead[0]))
          while true do
            local boundary = self.buffer:find("[\r\n]")
            if not boundary then break end
            local line = self.buffer:sub(1, boundary - 1)
            self.buffer = self.buffer:sub(boundary + 1)
            if line ~= "" then on_line(line) end
          end
          if #self.buffer > 65536 then self.buffer = self.buffer:sub(-65536) end
        end
      end
      function process:finished()
        return win.WaitForSingleObject(self.handle, 0) == 0
      end
      function process:exit_code()
        local exitCode = ffi.new("DWORD[1]")
        if win.GetExitCodeProcess(self.handle, exitCode) == 0 then return nil end
        return tonumber(exitCode[0])
      end
      function process:abort()
        win.TerminateProcess(self.handle, 1)
      end
      function process:close()
        win.CloseHandle(self.output)
        win.CloseHandle(self.handle)
      end
      return process
    end
  end
end
local function popen_progress_process(args)
  local quoted = {}
  for i, arg in ipairs(args) do
    quoted[i] = "'" .. tostring(arg):gsub("'", "'\\''") .. "'"
  end
  return io.popen(table.concat(quoted, " ") .. " 2>&1")
end
do
  local _class_0
  local _parent_0 = Page
  local _base_0 = {
    draw = function(self)
      local progress = 0
      if self.duration > 0 then
        progress = math.max(0, math.min(100, 100 * self.elapsed / self.duration))
      end
      local progressText = string.format("%d%%", progress)
      local window_w, window_h = mp.get_osd_size()
      local ass = assdraw.ass_new()
      ass:new_event()
      self:setup_text(ass)
      ass:append(tostring(self.label) .. " (" .. tostring(bold(progressText)) .. ")")
      if is_windows and windows_progress_process then ass:append("\\NESC: Cancel") end
      return mp.set_osd_ass(window_w, window_h, ass.text)
    end,
    parseProgress = function(self, value)
      local timePos = tonumber(value:match("Encode time%-pos:%s*([%d%.]+)"))
      if timePos and timePos >= 0 then
        self.elapsed = math.max(self.elapsed, timePos - self.startTime)
        local percent = self.duration > 0 and
          math.floor(math.max(0, math.min(100, 100 * self.elapsed / self.duration))) or 0
        if percent ~= self.lastLoggedPercent then
          self.lastLoggedPercent = percent
          msg.verbose("Encode progress: " .. percent .. "%")
        end
      end
    end,
    startEncode = function(self, command_line)
      local copy_command_line
      do
        local _accum_0 = { }
        local _len_0 = 1
        for _index_0 = 1, #command_line do
          local arg = command_line[_index_0]
          _accum_0[_len_0] = arg
          _len_0 = _len_0 + 1
        end
        copy_command_line = _accum_0
      end
      local job = active_encode
      if job.cancelled then return false end
      job.sequence = job.sequence + 1
      append(copy_command_line, {
        "--term-status-msg=Encode time-pos: " .. "$" .. "{=time-pos}\\n"
      })
      self:show()
      job.page = self
      if is_windows then
        if not windows_progress_process then
          self:hide()
          job.page = nil
          msg.error("File-free progress on Windows requires an mpv build with LuaJIT FFI")
          return false
        end
        local process, startError = windows_progress_process(copy_command_line)
        if not process then
          self:hide()
          job.page = nil
          msg.error("Couldn't start child mpv: " .. tostring(startError))
          return false
        end
        local lastOutput = ""
        local function on_line(line)
          lastOutput = (lastOutput .. line .. "\n"):sub(-8192)
          self:parseProgress(line)
          self:draw()
        end
        job.request = process
        job.timer = mp.add_periodic_timer(0.1, function()
          process:read_lines(on_line)
          if not process:finished() then return end
          process:read_lines(on_line)
          if process.buffer ~= "" then on_line(process.buffer) end
          local exitCode = process:exit_code()
          process:close()
          job.request = nil
          job.timer:kill()
          job.timer = nil
          self:hide()
          job.page = nil
          if exitCode ~= 0 and not job.cancelled then
            msg.error("Child mpv failed (" .. tostring(exitCode) .. "): " .. lastOutput)
          end
          resume_encode(exitCode == 0 and not job.cancelled)
        end)
        mp.commandv("script-message", "encoder-stage", tostring(job.sequence))
        return coroutine.yield()
      end
      -- On Unix, retain the original mpv-webm streaming reader. It blocks
      -- this script's event handling, not the player's playback core.
      local process, startError = popen_progress_process(copy_command_line)
      if not process then
        self:hide()
        job.page = nil
        msg.error("Couldn't start child mpv: " .. tostring(startError))
        return false
      end
      local lastOutput = ""
      for line in process:lines() do
        lastOutput = (lastOutput .. line .. "\n"):sub(-8192)
        self:parseProgress(line)
        self:draw()
      end
      local closeOk = process:close()
      self:hide()
      job.page = nil
      if not closeOk and not job.cancelled then
        msg.error("Child mpv failed: " .. lastOutput)
      end
      return closeOk == true and not job.cancelled
    end
  }
  _base_0.__index = _base_0
  _class_0 = make_class({
    __init = function(self, startTime, endTime, label)
      self.duration = endTime - startTime
      self.startTime = startTime
      self.elapsed = 0
      self.label = label or "Encoding"
      self.keybinds = is_windows and { ESC = cancel_encode } or {}
    end,
    __base = _base_0,
    __name = "EncodeWithProgress",
    __parent = _parent_0
  })
  EncodeWithProgress = _class_0
end
local run_encode_command
run_encode_command = function(command, startTime, endTime, label)
  msg.verbose("Command line:", table.concat(command, " "))
  local progress = EncodeWithProgress(startTime, endTime, label)
  return progress:startEncode(command)
end
local get_active_tracks
get_active_tracks = function()
  local accepted = {
    video = true,
    audio = not mp.get_property_bool("mute"),
    sub = mp.get_property_bool("sub-visibility", true)
  }
  local active = { video = { }, audio = { }, sub = { } }
  for _, track in ipairs(mp.get_property_native("track-list") or { }) do
    if track.selected and accepted[track.type] and active[track.type] then
      active[track.type][#active[track.type] + 1] = track
    end
  end
  return active
end
local append_track
append_track = function(out, track)
  local externalFlag = { audio = "audio-file", sub = "sub-file" }
  local internalFlag = { video = "vid", audio = "aid", sub = "sid" }
  if track.external and externalFlag[track.type] and track["external-filename"] then
    out[#out + 1] = "--" .. externalFlag[track.type] .. "=" .. tostring(track["external-filename"])
  elseif internalFlag[track.type] and track.id then
    out[#out + 1] = "--" .. internalFlag[track.type] .. "=" .. tostring(track.id)
  end
end
local append_audio_tracks
append_audio_tracks = function(out, tracks)
  local internal = { }
  for _, track in ipairs(tracks) do
    if track.external then
      append_track(out, track)
    else
      internal[#internal + 1] = track
    end
  end
  if #internal > 1 then
    local labels = { }
    for _, track in ipairs(internal) do
      labels[#labels + 1] = "[aid" .. tostring(track.id) .. "]"
    end
    out[#out + 1] = "--lavfi-complex=" .. table.concat(labels) .. "amix[ao]"
  elseif #internal == 1 then
    append_track(out, internal[1])
  end
end
local get_track_flags
get_track_flags = function(format)
  local out = { }
  local active = get_active_tracks()
  local wants = {
    video = format:getVideoCodec() ~= "",
    audio = format:getAudioCodec() ~= "" and not mp.get_property_bool("mute"),
    sub = format:getVideoCodec() ~= "" and mp.get_property_bool("sub-visibility", true)
  }
  for _, kind in ipairs({ "video", "audio", "sub" }) do
    local tracks = wants[kind] and active[kind] or { }
    if kind == "audio" then
      append_audio_tracks(out, tracks)
    else
      for _, track in ipairs(tracks) do
        append_track(out, track)
      end
    end
    if #tracks == 0 then
      out[#out + 1] = "--" .. ({ video = "vid", audio = "aid", sub = "sid" })[kind] .. "=no"
    end
  end
  return out
end
local get_scale_filters
get_scale_filters = function()
  local filters = { }
  if options.scale_height > 0 then
    append(filters, {
      "lavfi-scale=-2:" .. tostring(options.scale_height) .. ":flags=lanczos+accurate_rnd+full_chroma_inp"
    })
  end
  return filters
end
local get_fps_filters
get_fps_filters = function()
	-- Explicit FPS conversion always removes near-duplicate frames first. The
	-- one-frame drop cap catches the common A,A / B,B pattern without letting a
	-- long low-motion scene collapse into a handful of frames.
	if options.fps > -1 then
		return {
			"lavfi-mpdecimate=max=1",
			"fps=" .. tostring(options.fps)
		}
	end
	return { }
end
local append_current_filters
append_current_filters = function(filters)
  local vf = mp.get_property_native("vf")
  if not vf then
    return 
  end
  for _index_0 = 1, #vf do
    local filter = vf[_index_0]
    if filter["enabled"] ~= false then
      local name = tostring(filter.name)
      local params = filter["params"] or { }
      local parts = { }
      for key, value in pairs(params) do
        value = tostring(value)
        parts[#parts + 1] = tostring(key) .. "=%" .. tostring(#value) .. "%" .. value
      end
      table.sort(parts)
      if #parts > 0 then
        name = name .. ":" .. table.concat(parts, ":")
      end
      filters[#filters + 1] = name
    end
  end
end
local get_video_filters
get_video_filters = function(format, region)
  local filters = { }
  append(filters, format:getPreFilters())
  if options.apply_current_filters then
    append_current_filters(filters)
  end
  if region and region:is_valid() then
    append(filters, {
      "lavfi-crop=" .. tostring(region.w) .. ":" .. tostring(region.h) .. ":" .. tostring(region.x) .. ":" .. tostring(region.y)
    })
  end
  append(filters, get_scale_filters())
  append(filters, get_fps_filters())
  local sdrNormalizationFilter = get_sdr_normalization_filter(format)
  if sdrNormalizationFilter then
    append(filters, {
      sdrNormalizationFilter
    })
  end
  append(filters, format:getPostFilters())
  return filters
end
local build_video_filter_args
build_video_filter_args = function(ctx)
  local args = { }
  for _, filter in ipairs(get_video_filters(ctx.format, ctx.region)) do
    args[#args + 1] = "--vf-add=" .. filter
  end
  return args
end
local function append_property(out, propertyName, optionName)
  local value = mp.get_property(propertyName)
  if value and value ~= "" then
    out[#out + 1] = "--" .. tostring(optionName or propertyName) .. "=" .. tostring(value)
  end
end
local get_playback_options
get_playback_options = function()
  local out = { }
  append_property(out, "video-rotate")
  append_property(out, "deinterlace")
  return out
end
local get_sub_options
get_sub_options = function()
  local out = { }
  for _, name in ipairs({
    "sub-ass-override", "sub-ass-style-overrides", "sub-ass-use-video-data",
    "sub-pos", "sub-delay", "sub-scale", "sub-font", "sub-font-size",
    "sub-bold", "sub-italic", "sub-color", "sub-back-color",
    "sub-border-color", "sub-border-size", "sub-shadow-color",
    "sub-shadow-offset", "sub-use-margins", "sub-margin-x", "sub-margin-y",
    "sub-align-x", "sub-align-y", "sub-spacing", "sub-justify",
    "sub-gauss", "sub-gray"
  }) do
    append_property(out, name)
  end
  return out
end
local build_encode_command
build_encode_command = function(ctx)
  local command = {
    tostring(options.mpv_executable),
    ctx.path,
    "--no-config",
    "--start=" .. seconds_to_time_string(ctx.startTime, false, true),
    "--end=" .. seconds_to_time_string(ctx.endTime, false, true),
    "--loop-file=no",
    "--no-pause",
    "--no-keep-open",
    "--input-default-bindings=no",
    "--osc=no"
  }
  append(command, get_track_flags(ctx.format))
  append(command, ctx.format:getCodecFlags())
  local muxer = ctx.format:getMuxer()
  if muxer then
    command[#command + 1] = "--of=" .. tostring(muxer)
  end
  if ctx.format:getAudioCodec() ~= "" and options.downmix_audio then
    command[#command + 1] = "--audio-channels=stereo"
  end
  if ctx.format:getVideoCodec() == "" then
    return command
  end
  append(command, get_playback_options())
  append(command, get_sub_options())
  append(command, build_video_filter_args(ctx))
  return command
end
local build_encode_variants
build_encode_variants = function(ctx, targetPath)
  local format = ctx.format
  local baseCommand = copy_list(ctx.baseCommand or build_encode_command(ctx))
  local variants = {
    passlog = nil,
    x264Stats = nil,
    pass1 = nil,
    final = nil
  }
  if format:supportsTwoPass(ctx) then
    variants.passlog = get_pass_logfile_path(targetPath)
    track_encode_file(variants.passlog)
    track_encode_file(variants.passlog .. ".mbtree")
    -- Older mpv releases used the VO driver's historical name here.
    track_encode_file(targetPath .. "-vo-lavc-pass1.log")
    track_encode_file(targetPath .. "-vo-lavc-pass1.log.mbtree")
    if format:getVideoCodec() == "libx264" then
      variants.x264Stats = track_encode_file(targetPath .. "-x264_2pass.log")
      track_encode_file(variants.x264Stats .. ".mbtree")
    end
    variants.pass1 = copy_list(baseCommand)
    append(variants.pass1, format:getFlags(ctx, 1))
    if variants.x264Stats then
      variants.pass1[#variants.pass1 + 1] = "--ovcopts-add=stats=" .. variants.x264Stats
    end
    append(variants.pass1, {
      "--aid=no",
      "--ovcopts-add=flags=+pass1",
      "--o=" .. targetPath
    })
    variants.final = copy_list(baseCommand)
    append(variants.final, format:getFlags(ctx, 2))
    if variants.x264Stats then
      variants.final[#variants.final + 1] = "--ovcopts-add=stats=" .. variants.x264Stats
    end
    append(variants.final, {
      "--ovcopts-add=flags=+pass2",
      "--o=" .. targetPath
    })
  else
    variants.final = baseCommand
    append(variants.final, format:getFlags(ctx, nil))
    table.insert(variants.final, "--o=" .. targetPath)
  end
  return variants
end
local remove_pass_logs
remove_pass_logs = function(passlog, x264Stats)
  if not passlog then
    return
  end
  os.remove(passlog)
  os.remove(passlog .. ".mbtree")
  local legacyPasslog = passlog:gsub("%-video%-pass1%.log$", "-vo-lavc-pass1.log")
  os.remove(legacyPasslog)
  os.remove(legacyPasslog .. ".mbtree")
  if x264Stats then
    os.remove(x264Stats)
    os.remove(x264Stats .. ".mbtree")
  end
end
local run_encode_variants
run_encode_variants = function(variants, startTime, endTime, label)
  if variants.pass1 then
    msg.info("Encoding pass 1/2 (analysis)")
    if not run_encode_command(variants.pass1, startTime, endTime, label .. " pass 1/2") then
      remove_pass_logs(variants.passlog, variants.x264Stats)
      return false, "pass1"
    end
    -- Pass 1 may leave a non-publishable analysis container at --o. The
    -- second child mpv must start with a clean destination.
    for _, arg in ipairs(variants.pass1) do
      local passOutput = arg:match("^%-%-o=(.+)$")
      if passOutput then os.remove(passOutput) end
    end
  end

  local finalLabel = variants.pass1 and label .. " pass 2/2" or label
  local ok = run_encode_command(variants.final, startTime, endTime, finalLabel)
  remove_pass_logs(variants.passlog, variants.x264Stats)
  if not ok then
    return false, "final"
  end
  return true
end
local find_path
find_path = function(startTime, endTime)
  local path = mp.get_property('path')
  if not path then
    return nil, nil, nil, nil, nil
  end
  local is_stream = not file_exists(path)
  local is_temporary = false
  if is_stream then
    if mp.get_property('file-format') == 'hls' then
      path = utils.join_path(parse_directory('~'), 'cache_dump_' .. instance_id .. '.ts')
      mp.command_native({
        'dump_cache',
        seconds_to_time_string(startTime, false, true),
        seconds_to_time_string(endTime + 5, false, true),
        path
      })
      endTime = endTime - startTime
      startTime = 0
      is_temporary = true
    end
  end
  return path, is_stream, is_temporary, startTime, endTime
end
local cleanup_temporary_source
cleanup_temporary_source = function(job)
  if job.isTemporarySource then
    os.remove(job.sourcePath)
  end
end
local cleanup_failed_encode
cleanup_failed_encode = function(job, removeOutput, extraPaths)
  for _, extraPath in ipairs(extraPaths or { }) do
    if extraPath then
      os.remove(extraPath)
    end
  end
  if removeOutput then
    os.remove(job.outputPath)
  end
  if job.audioOutputPath then
    os.remove(job.audioOutputPath)
  end
  cleanup_temporary_source(job)
end
local available_encoder_names
local function get_available_encoder_names()
  if available_encoder_names then return available_encoder_names end
  local encoders = mp.get_property_native("encoder-list")
  if type(encoders) ~= "table" then return nil end
  local names = { }
  for _, encoder in ipairs(encoders) do
    if encoder.driver then names[tostring(encoder.driver)] = true end
    if encoder.codec then names[tostring(encoder.codec)] = true end
  end
  available_encoder_names = names
  return names
end
local function ensure_encoder_available(codec, kind)
  if not codec or codec == "" then return true end
  local names = get_available_encoder_names()
  if not names or names[codec] then return true end
  local detail = "This mpv build does not expose the " .. tostring(kind) .. " encoder '" .. tostring(codec) .. "'"
  msg.error(detail)
  message(detail)
  return false
end
local function validate_encode_capabilities(ctx)
  local videoCodec = ctx.format:getVideoCodec()
  local audioCodec = get_native_audio_codec(ctx.format:getAudioCodec())
  if not ensure_encoder_available(videoCodec, "video") then return false end
  if not ensure_encoder_available(audioCodec, "audio") then return false end
  -- Do not probe --ovcopts=help via mpv's subprocess command here: some
  -- Windows builds return "init" before starting that probe even though
  -- the real child encode supports the option. Let the encode report failure.
  return true
end
local calculate_target_video_bitrate
calculate_target_video_bitrate = function(format, duration, targetMB, basketVideoOnly)
  duration = tonumber(duration)
  targetMB = tonumber(targetMB)
  if not duration or duration <= 0 then
    return nil, "source duration is unavailable"
  end
  if not targetMB or targetMB <= 0 then
    return nil, "target size is invalid"
  end
  local profile = format:getCodecProfile()
  if not profile.targetSize then
    return nil, "the selected encoder has no native target-bitrate mode"
  end
  -- Match the binary units shown as "MB" by Windows Explorer and mpv.
  local totalBits = targetMB * 1024 * 1024 * 8
  -- Leave a small first-pass reserve; the measured-size retry below enforces
  -- the hard cap if the encoder or container overshoots.
  local overheadBits = math.max(totalBits * 0.0025, 16 * 1024 * 8)
  local audioBits = 0
  if not basketVideoOnly and format:getAudioCodec() ~= "" then
    audioBits = get_audio_bitrate(format:getAudioCodec()) * duration
  end
  local videoBits = totalBits - overheadBits - audioBits
  if videoBits <= 0 then
    return nil, "audio and container overhead consume the complete target budget"
  end
  local rawBitrate = math.floor(videoBits / duration + 0.5)
  local bitrate = math.max(profile.bitrateMin or 1, math.min(profile.bitrateMax or rawBitrate, rawBitrate))
  return bitrate, nil, {
    rawBitrate = rawBitrate,
    audioBits = audioBits,
    overheadBits = overheadBits
  }
end
local calculate_retry_video_bitrate
calculate_retry_video_bitrate = function(currentBitrate, measuredBytes, targetBytes, profile)
  if not measuredBytes or measuredBytes <= 0 or not targetBytes or targetBytes <= 0 then
    return nil
  end
  local minimum = profile.bitrateMin or 1
  if currentBitrate <= minimum then return nil end
  -- Native rate control can overshoot. Scale to the measured result, then
  -- reserve another 2% so a small fluctuation does not force a third encode.
  local nextBitrate = math.floor(currentBitrate * targetBytes / measuredBytes * 0.98)
  nextBitrate = math.max(minimum, nextBitrate)
  if nextBitrate >= currentBitrate then return nil end
  return nextBitrate
end
local build_basket_audio_command
build_basket_audio_command = function(ctx, outputPath)
  local audioFormat = {
    getVideoCodec = function() return "" end,
    getAudioCodec = function() return "libopus" end,
    getCodecFlags = function() return { "--vid=no" } end,
    getMuxer = function() return "ogg" end
  }
  local audioCtx = {
    format = audioFormat, path = ctx.path,
    startTime = ctx.startTime, endTime = ctx.endTime
  }
  local command = build_encode_command(audioCtx)
  append(command, get_audio_encode_flags("libopus"))
  command[#command + 1] = "--o=" .. outputPath
  return command
end
-- Preserve both the old output and the successful candidate if publishing
-- fails. Windows cannot rename over an existing destination.
local function publish_encode_result(candidatePath, outputPath)
  local backupPath
  if file_exists(outputPath) then
    backupPath = outputPath .. ".previous-" .. instance_id
    local suffix = 0
    while file_exists(backupPath) do
      suffix = suffix + 1
      backupPath = outputPath .. ".previous-" .. instance_id .. "-" .. suffix
    end
    local saved, saveError = os.rename(outputPath, backupPath)
    if not saved then
      return false, "Cannot preserve existing output: " .. tostring(saveError)
    end
  end
  local published, publishError = os.rename(candidatePath, outputPath)
  if not published then
    if backupPath then
      local restored, restoreError = os.rename(backupPath, outputPath)
      if not restored then
        msg.error("Previous output retained at " .. backupPath .. ": " .. tostring(restoreError))
      end
    end
    return false, publishError
  end
  if backupPath then
    local removed, removeError = os.remove(backupPath)
    if not removed then
      msg.warn("Previous output retained at " .. backupPath .. ": " .. tostring(removeError))
    end
  end
  return true
end
local encode_basket_audio
local function staged_output_path(outputPath)
  local dir, filename = utils.split_path(outputPath)
  local index = 0
  local path
  repeat
    index = index + 1
    path = utils.join_path(dir, ".encoder-" .. instance_id .. "-" .. index .. "-" .. filename)
  until not file_exists(path)
  return track_encode_file(path)
end
encode_basket_audio = function(ctx, outputPath)
  local command = build_basket_audio_command(ctx, outputPath)
  msg.info("Encoding audio to", outputPath)
  if run_encode_command(command, ctx.startTime, ctx.endTime, "Basket audio") and file_is_nonempty(outputPath) then
    message("Audio encode finished")
    return true
  end
  os.remove(outputPath)
  message("Audio encode failed")
  return false
end
local encode_standard_job
encode_standard_job = function(ctx, job)
  local format = ctx.format
  if not validate_encode_capabilities(ctx) then
    cleanup_failed_encode(job, false)
    return false
  end
  local stagedPath = staged_output_path(job.outputPath)
  local variants = build_encode_variants(ctx, stagedPath)
  local passLabel = format:getCodecProfile().displayName or format:getVideoCodec()
  msg.info("Encoding to", job.outputPath)
  local label = variants.pass1 and passLabel or "Encoding"
  local ok, failedStage = run_encode_variants(variants, ctx.startTime, ctx.endTime, label)
  if ok and not file_is_nonempty(stagedPath) then
    msg.error("Child mpv exited successfully but did not create a non-empty output file")
    ok = false
  end
  if ok then
    local published, publishError = publish_encode_result(stagedPath, job.outputPath)
    if not published then
      retain_encode_file(stagedPath)
      retain_encode_file(job.audioOutputPath)
      msg.error("Couldn't publish output: " .. tostring(publishError))
      msg.error("Completed output retained at " .. stagedPath)
      if job.audioOutputPath then
        msg.error("Completed audio retained at " .. job.audioOutputPath)
      end
      cleanup_temporary_source(job)
      message("Couldn't publish output; completed file retained at " .. stagedPath)
      return false
    end
    message("Encode finished")
    cleanup_temporary_source(job)
    return true
  end

  cleanup_failed_encode(job, false, { stagedPath })
  if failedStage == "pass1" then
    message("Encode failed (pass 1)")
  else
    message("Encode failed")
  end
  return false
end
local encode_target_size_job
encode_target_size_job = function(ctx, job, targetMB, labelPrefix, basketVideoOnly)
  local bitrate, bitrateError, budget = calculate_target_video_bitrate(
    ctx.format, ctx.endTime - ctx.startTime, targetMB, basketVideoOnly)
  if not bitrate then
    local detail = "Target-size mode is unsupported: " .. tostring(bitrateError)
    msg.error(detail)
    message(detail)
    cleanup_failed_encode(job, false)
    return false
  end
  ctx.targetBitrate = bitrate
  ctx.targetBudget = budget
  if not validate_encode_capabilities(ctx) then
    cleanup_failed_encode(job, false)
    return false
  end
  local stagedPath = staged_output_path(job.outputPath)
  -- Menu sizes follow Windows Explorer's binary "MB" display. Upload hosts
  -- that enforce decimal MB can reject a file below this binary limit.
  local targetBytes = targetMB * 1024 * 1024
  local measuredBytes
  local maxAttempts = 4
  for attempt = 1, maxAttempts do
    ctx.targetBitrate = bitrate
    local variants = build_encode_variants(ctx, stagedPath)
    local label = labelPrefix .. " target " .. string.format("%.0f kbps", bitrate / 1000)
    msg.info("Native target-bitrate encode attempt " .. attempt .. "/" .. maxAttempts .. ": " .. bitrate .. " bit/s")
    local ok, failedStage = run_encode_variants(variants, ctx.startTime, ctx.endTime, label)
    if ok and not file_is_nonempty(stagedPath) then
      msg.error("Child mpv exited successfully but did not create a non-empty output file")
      ok = false
    end
    if not ok then
      cleanup_failed_encode(job, false, { stagedPath })
      message(failedStage == "pass1" and "Encode failed (pass 1)" or "Encode failed")
      return false
    end
    local info = utils.file_info(stagedPath)
    measuredBytes = info and info.size
    if not measuredBytes or measuredBytes <= 0 then
      msg.error("Could not measure target-size output")
      cleanup_failed_encode(job, false, { stagedPath })
      message("Encode failed: output size unavailable")
      return false
    end
    if measuredBytes < targetBytes then break end
    msg.warn(string.format("Target-size attempt %d produced %.6f MB (Windows units; limit %.0f MB)",
      attempt, measuredBytes / (1024 * 1024), targetMB))
    if attempt == maxAttempts then break end
    local nextBitrate = calculate_retry_video_bitrate(
      bitrate, measuredBytes, targetBytes, ctx.format:getCodecProfile())
    if not nextBitrate then break end
    if not os.remove(stagedPath) and file_exists(stagedPath) then
      msg.error("Cannot remove oversized staged output before retry")
      cleanup_failed_encode(job, false, { stagedPath })
      message("Encode failed: oversized staged output could not be removed")
      return false
    end
    bitrate = nextBitrate
  end
  if measuredBytes >= targetBytes then
    msg.error("Target size could not be met after native bitrate retries; existing output was not replaced")
    cleanup_failed_encode(job, false, { stagedPath })
    message("Encode failed: target size could not be met")
    return false
  end
  local published, publishError = publish_encode_result(stagedPath, job.outputPath)
  if not published then
    retain_encode_file(stagedPath)
    retain_encode_file(job.audioOutputPath)
    msg.error("Couldn't publish target-size output: " .. tostring(publishError))
    msg.error("Completed output retained at " .. stagedPath)
    cleanup_temporary_source(job)
    message("Couldn't publish output; completed file retained at " .. stagedPath)
    return false
  end
  local sizeMessage = string.format("%.6f", measuredBytes / (1024 * 1024)) ..
    " MB (Windows units), under " .. tostring(targetMB) .. " MB"
  message("Encode finished (" .. sizeMessage .. ")")
  cleanup_temporary_source(job)
  return true
end
local encode
encode = function(region, startTime, endTime)
  local format = formats[options.output_format]
  if not format then
    msg.error("Unknown output format: " .. tostring(options.output_format))
    message("Unknown output format: " .. tostring(options.output_format))
    return
  end
  local originalStartTime = startTime
  local originalEndTime = endTime
  local path, is_stream, is_temporary
  path, is_stream, is_temporary, startTime, endTime = find_path(startTime, endTime)
  if not path then
    message("No file is being played")
    return 
  end
  local dir
  if is_stream then
    dir = parse_directory("~")
  else
    local _
    dir, _ = utils.split_path(path)
  end
  if options.output_directory ~= "" then
    dir = parse_directory(options.output_directory)
  end
  local formatted_filename = format_filename(originalStartTime, originalEndTime, format)
  local out_path = utils.join_path(dir, formatted_filename)
  active_encode.directory = dir
  if is_temporary then track_encode_file(path) end
  local encodeContext = {
    format = format,
    path = path,
    startTime = startTime,
    endTime = endTime,
    originalStartTime = originalStartTime,
    region = region
  }
  local isBasket = options.output_format == "Basket"
  -- Snapshot playback-dependent maps/filters before the first async wait.
  encodeContext.baseCommand = build_encode_command(encodeContext)
  local audio_out_path = nil
  if isBasket then
    audio_out_path = (out_path:gsub("%.[^./\\]+$", ".ogg"))
  end
  local encodeJob = {
    sourcePath = path,
    isTemporarySource = is_temporary,
    outputPath = out_path,
    audioOutputPath = audio_out_path and staged_output_path(audio_out_path)
  }
  if isBasket then
    -- Encode audio first into staging. Publish the sidecar only after video
    -- succeeds, so a failed video attempt cannot replace existing audio.
    if not ensure_encoder_available(get_native_audio_codec("libopus"), "audio") then
      cleanup_temporary_source(encodeJob)
      return false
    end
    if not encode_basket_audio(encodeContext, encodeJob.audioOutputPath) then
      cleanup_temporary_source(encodeJob)
      return
    end
  end
  local ok
  if isBasket and options.target_size_basket_mb > 0 then
    ok = encode_target_size_job(encodeContext, encodeJob, options.target_size_basket_mb, "Basket", true)
  elseif options.output_format == "mp4" and options.target_size_mp4_mb > 0 and format:getTargetSizeProfile() then
    ok = encode_target_size_job(encodeContext, encodeJob, options.target_size_mp4_mb, "MP4", false)
  elseif options.output_format == "WebM" and format:getVideoCodec() == "libsvtav1" and options.target_size_av1_mb > 0 then
    ok = encode_target_size_job(encodeContext, encodeJob, options.target_size_av1_mb, "AV1", false)
  elseif options.output_format == "NVENC" and options.target_size_nvenc_mb > 0 then
    ok = encode_target_size_job(encodeContext, encodeJob, options.target_size_nvenc_mb, "NVENC", false)
  else
    ok = encode_standard_job(encodeContext, encodeJob)
  end
  if ok and audio_out_path then
    local published, err = publish_encode_result(encodeJob.audioOutputPath, audio_out_path)
    if not published then
      retain_encode_file(encodeJob.audioOutputPath)
      msg.error("Audio publication failed: " .. tostring(err))
      message("Completed audio retained at " .. encodeJob.audioOutputPath)
      return false
    end
  end
  return ok
end
local crop_aspect_presets = {
  { label = "Free", ratio = nil },
  { label = "Source", source = true },
  { label = "16:9", ratio = 16 / 9 },
  { label = "9:16", ratio = 9 / 16 },
  { label = "4:3", ratio = 4 / 3 },
  { label = "3:4", ratio = 3 / 4 },
  { label = "1:1", ratio = 1 },
  { label = "21:9", ratio = 21 / 9 },
  { label = "9:21", ratio = 9 / 21 }
}
local function get_crop_source_dimensions()
  local params = mp.get_property_native("video-out-params") or { }
  local w = tonumber(params.w) or 1
  local h = tonumber(params.h) or 1
  local dw = tonumber(params.dw) or w
  local dh = tonumber(params.dh) or h
  if dw <= 0 then dw = w end
  if dh <= 0 then dh = h end
  if mp.get_property_number("video-rotate") % 180 == 90 then
    w, h, dw, dh = h, w, dh, dw
  end
  return w, h, dw, dh
end
local CropPage
do
  local _class_0
  local _parent_0 = Page
  local _base_0 = {
    reset = function(self)
      local dimensions = get_video_dimensions()
      local xa, ya
      do
        local _obj_0 = dimensions.top_left
        xa, ya = _obj_0.x, _obj_0.y
      end
      self.pointA:set_from_screen(xa, ya)
      local xb, yb
      do
        local _obj_0 = dimensions.bottom_right
        xb, yb = _obj_0.x, _obj_0.y
      end
      self.pointB:set_from_screen(xb, yb)
      if self.aspect_index and self.aspect_index > 1 then
        self:fit_aspect()
      end
      if self.visible then
        return self:draw()
      end
    end,
    is_aspect_locked = function(self)
      return self.aspect_index and self.aspect_index > 1
    end,
    get_aspect_preset = function(self)
      return crop_aspect_presets[self.aspect_index or 1]
    end,
    get_pixel_aspect_ratio = function(self)
      local w, h, dw, dh = get_crop_source_dimensions()
      local preset = self:get_aspect_preset()
      if preset.source then
        return w / h
      end
      if not preset.ratio then
        return nil
      end
      -- Crop coordinates are pixels, while presets describe display shape.
      -- Account for non-square source pixels when converting the ratio.
      return preset.ratio * w * dh / (h * dw)
    end,
    normalize_points = function(self)
      if self.pointA.x > self.pointB.x then
        self.pointA.x, self.pointB.x = self.pointB.x, self.pointA.x
      end
      if self.pointA.y > self.pointB.y then
        self.pointA.y, self.pointB.y = self.pointB.y, self.pointA.y
      end
    end,
    fit_aspect = function(self)
      local ratio = self:get_pixel_aspect_ratio()
      if not ratio then
        return
      end
      local sourceW, sourceH = get_crop_source_dimensions()
      self:normalize_points()
      local x = self.pointA.x
      local y = self.pointA.y
      local w = self.pointB.x - self.pointA.x
      local h = self.pointB.y - self.pointA.y
      if w < 2 or h < 2 then
        x, y, w, h = 0, 0, sourceW, sourceH
      end
      local centerX = x + w / 2
      local centerY = y + h / 2
      if w / h > ratio then
        w = math.min(sourceW, h * ratio)
      else
        h = math.min(sourceH, w / ratio)
      end
      w = math.max(2, math.floor(w / 2) * 2)
      h = math.max(2, math.floor(h / 2) * 2)
      x = math.floor(centerX - w / 2 + 0.5)
      y = math.floor(centerY - h / 2 + 0.5)
      x = clamp(0, x, sourceW - w)
      y = clamp(0, y, sourceH - h)
      self.pointA.x, self.pointA.y = x, y
      self.pointB.x, self.pointB.y = x + w, y + h
    end,
    cycle_aspect = function(self)
      self.aspect_index = self.aspect_index % #crop_aspect_presets + 1
      if self:is_aspect_locked() then
        self:fit_aspect()
      end
      return self:draw()
    end,
    cycle_nudge_target = function(self)
      if self:is_aspect_locked() then
        self.nudge_target = "box"
      elseif self.nudge_target == "a" then
        self.nudge_target = "b"
      elseif self.nudge_target == "b" then
        self.nudge_target = "box"
      else
        self.nudge_target = "a"
      end
      return self:draw()
    end,
    nudge = function(self, dx, dy, step)
      local sourceW, sourceH = get_crop_source_dimensions()
      dx, dy = dx * step, dy * step
      self:normalize_points()
      if self:is_aspect_locked() or self.nudge_target == "box" then
        local w = self.pointB.x - self.pointA.x
        local h = self.pointB.y - self.pointA.y
        local x = clamp(0, self.pointA.x + dx, sourceW - w)
        local y = clamp(0, self.pointA.y + dy, sourceH - h)
        self.pointA.x, self.pointA.y = x, y
        self.pointB.x, self.pointB.y = x + w, y + h
      else
        local point = self.nudge_target == "a" and self.pointA or self.pointB
        local other = self.nudge_target == "a" and self.pointB or self.pointA
        if self.nudge_target == "a" then
          point.x = clamp(0, point.x + dx, other.x - 2)
          point.y = clamp(0, point.y + dy, other.y - 2)
        else
          point.x = clamp(other.x + 2, point.x + dx, sourceW)
          point.y = clamp(other.y + 2, point.y + dy, sourceH)
        end
      end
      return self:draw()
    end,
    setPointA = function(self)
      if self:is_aspect_locked() then
        return message("Aspect locked; use arrow keys to move the crop")
      end
      local posX, posY = mp.get_mouse_pos()
      self.pointA:set_from_screen(posX, posY)
      self.nudge_target = "a"
      if self.visible then
        return self:draw()
      end
    end,
    setPointB = function(self)
      if self:is_aspect_locked() then
        return message("Aspect locked; use arrow keys to move the crop")
      end
      local posX, posY = mp.get_mouse_pos()
      self.pointB:set_from_screen(posX, posY)
      self.nudge_target = "b"
      if self.visible then
        return self:draw()
      end
    end,
    snap = function(self)
      if self:is_aspect_locked() then
        local sourceW, sourceH = get_crop_source_dimensions()
        self:normalize_points()
        local w = self.pointB.x - self.pointA.x
        local h = self.pointB.y - self.pointA.y
        local candidates = {
          { math.abs(self.pointA.x), 0, self.pointA.y },
          { math.abs(sourceW - self.pointB.x), sourceW - w, self.pointA.y },
          { math.abs(self.pointA.y), self.pointA.x, 0 },
          { math.abs(sourceH - self.pointB.y), self.pointA.x, sourceH - h }
        }
        table.sort(candidates, function(a, b) return a[1] < b[1] end)
        self.pointA.x, self.pointA.y = candidates[1][2], candidates[1][3]
        self.pointB.x, self.pointB.y = self.pointA.x + w, self.pointA.y + h
        return self:draw()
      end
      local dimensions = get_video_dimensions()
      local xa, ya
      do
        local _obj_0 = dimensions.top_left
        xa, ya = _obj_0.x, _obj_0.y
      end
      local sa = self.pointA:to_screen()
      if math.abs(sa.x - xa) < 50 then
        sa.x = xa
      end
      if math.abs(sa.y - ya) < 50 then
        sa.y = ya
      end
      self.pointA:set_from_screen(sa.x, sa.y)
      local xb, yb
      do
        local _obj_0 = dimensions.bottom_right
        xb, yb = _obj_0.x, _obj_0.y
      end
      local sb = self.pointB:to_screen()
      if math.abs(sb.x - xb) < 50 then
        sb.x = xb
      end
      if math.abs(sb.y - yb) < 50 then
        sb.y = yb
      end
      self.pointB:set_from_screen(sb.x, sb.y)
      if self.visible then
        return self:draw()
      end
    end,
    cancel = function(self)
      self:hide()
      return self.callback(false, nil)
    end,
    finish = function(self)
      self:normalize_points()
      local region = Region()
      region:set_from_points(self.pointA, self.pointB)
      self:hide()
      return self.callback(true, region)
    end,
    draw_box = function(self, ass)
      local region = Region()
      region:set_from_points(self.pointA:to_screen(), self.pointB:to_screen())
      local d = get_video_dimensions()
      ass:new_event()
      ass:append("{\\an7}")
      ass:pos(0, 0)
      ass:append('{\\bord0}')
      ass:append('{\\shad0}')
      ass:append('{\\c&H000000&}')
      ass:append('{\\alpha&H77}')
      ass:draw_start()
      ass:rect_cw(d.top_left.x, d.top_left.y, region.x, region.y + region.h)
      ass:rect_cw(region.x, d.top_left.y, d.bottom_right.x, region.y)
      ass:rect_cw(d.top_left.x, region.y + region.h, region.x + region.w, d.bottom_right.y)
      ass:rect_cw(region.x + region.w, region.y, d.bottom_right.x, d.bottom_right.y)
      return ass:draw_stop()
    end,
    draw = function(self)
      local window = { }
      window.w, window.h = mp.get_osd_size()
      local ass = assdraw.ass_new()
      self:draw_box(ass)
      ass:new_event()
      self:setup_text(ass)
      ass:append(tostring(bold('Crop:')) .. "\\N")
      local preset = self:get_aspect_preset()
      local target = self.nudge_target == "a" and "point A" or (self.nudge_target == "b" and "point B" or "whole box")
      ass:append(tostring(bold('Aspect:')) .. " " .. tostring(preset.label) .. " (a: next)\\N")
      ass:append(tostring(bold('1:')) .. " change point A (" .. tostring(self.pointA.x) .. ", " .. tostring(self.pointA.y) .. ")\\N")
      ass:append(tostring(bold('2:')) .. " change point B (" .. tostring(self.pointB.x) .. ", " .. tostring(self.pointB.y) .. ")\\N")
      ass:append(tostring(bold('m:')) .. " nudge target: " .. target .. "\\N")
      ass:append(tostring(bold('arrows:')) .. " nudge 1 px; SHIFT+arrow: 8 px\\N")
      ass:append(tostring(bold('s:')) .. " snap to edges\\N")
      ass:append(tostring(bold('r:')) .. " reset to whole screen\\N")
      ass:append(tostring(bold('ESC:')) .. " cancel crop\\N")
      local width, height = math.abs(self.pointA.x - self.pointB.x), math.abs(self.pointA.y - self.pointB.y)
      ass:append(tostring(bold('ENTER:')) .. " confirm crop (" .. tostring(width) .. "x" .. tostring(height) .. ")\\N")
      return mp.set_osd_ass(window.w, window.h, ass.text)
    end
  }
  _base_0.__index = _base_0
  _class_0 = make_class({
    __init = function(self, callback, region)
      self.pointA = VideoPoint()
      self.pointB = VideoPoint()
      self.aspect_index = 1
      self.nudge_target = "box"
      self.keybinds = {
        ["1"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.setPointA
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["2"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.setPointB
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["a"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.cycle_aspect
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["m"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.cycle_nudge_target
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["LEFT"] = function() return self:nudge(-1, 0, 1) end,
        ["RIGHT"] = function() return self:nudge(1, 0, 1) end,
        ["UP"] = function() return self:nudge(0, -1, 1) end,
        ["DOWN"] = function() return self:nudge(0, 1, 1) end,
        ["SHIFT+LEFT"] = function() return self:nudge(-1, 0, 8) end,
        ["SHIFT+RIGHT"] = function() return self:nudge(1, 0, 8) end,
        ["SHIFT+UP"] = function() return self:nudge(0, -1, 8) end,
        ["SHIFT+DOWN"] = function() return self:nudge(0, 1, 8) end,
        ["s"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.snap
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["r"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.reset
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["ESC"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.cancel
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["ENTER"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.finish
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)()
      }
      self:reset()
      self.callback = callback
      if region and region:is_valid() then
        self.pointA.x = region.x
        self.pointA.y = region.y
        self.pointB.x = region.x + region.w
        self.pointB.y = region.y + region.h
      end
    end,
    __base = _base_0,
    __name = "CropPage",
    __parent = _parent_0
  })
  CropPage = _class_0
end
local Option
do
  local _class_0
  local _base_0 = {
    hasPrevious = function(self)
      local _exp_0 = self.optType
      if "bool" == _exp_0 then
        return true
      elseif "int" == _exp_0 then
        if self.opts.min then
          return self.value > self.opts.min
        else
          return true
        end
      elseif "list" == _exp_0 then
        return self.value > 1
      end
    end,
    hasNext = function(self)
      local _exp_0 = self.optType
      if "bool" == _exp_0 then
        return true
      elseif "int" == _exp_0 then
        if self.opts.max then
          return self.value < self.opts.max
        else
          return true
        end
      elseif "list" == _exp_0 then
        return self.value < #self.opts.possibleValues
      end
    end,
    leftKey = function(self)
      local _exp_0 = self.optType
      if "bool" == _exp_0 then
        self.value = not self.value
      elseif "int" == _exp_0 then
        self.value = self.value - self.opts.step
        if self.opts.min and self.opts.min > self.value then
          self.value = self.opts.min
        end
      elseif "list" == _exp_0 then
        if self.value > 1 then
          self.value = self.value - 1
        end
      end
    end,
    rightKey = function(self)
      local _exp_0 = self.optType
      if "bool" == _exp_0 then
        self.value = not self.value
      elseif "int" == _exp_0 then
        self.value = self.value + self.opts.step
        if self.opts.max and self.opts.max < self.value then
          self.value = self.opts.max
        end
      elseif "list" == _exp_0 then
        if self.value < #self.opts.possibleValues then
          self.value = self.value + 1
        end
      end
    end,
    getValue = function(self)
      local _exp_0 = self.optType
      if "bool" == _exp_0 then
        return self.value
      elseif "int" == _exp_0 then
        return self.value
      elseif "list" == _exp_0 then
        local value, _
        do
          local _obj_0 = self.opts.possibleValues[self.value]
          value, _ = _obj_0[1], _obj_0[2]
        end
        return value
      end
    end,
    setValue = function(self, value)
      local _exp_0 = self.optType
      if "bool" == _exp_0 then
        self.value = value
      elseif "int" == _exp_0 then
        self.value = value
      elseif "list" == _exp_0 then
        local set = false
        for i, possiblePair in ipairs(self.opts.possibleValues) do
          local possibleValue, _
          possibleValue, _ = possiblePair[1], possiblePair[2]
          if possibleValue == value then
            set = true
            self.value = i
            break
          end
        end
        if not set then
          return msg.warn("Tried to set invalid value " .. tostring(value) .. " to " .. tostring(self.displayText) .. " option.")
        end
      end
    end,
    getDisplayValue = function(self)
      local _exp_0 = self.optType
      if "bool" == _exp_0 then
        return self.value and "yes" or "no"
      elseif "int" == _exp_0 then
        if self.opts.altDisplayNames and self.opts.altDisplayNames[self.value] then
          return self.opts.altDisplayNames[self.value]
        else
          return tostring(self.value)
        end
      elseif "list" == _exp_0 then
        local value, displayValue
        do
          local _obj_0 = self.opts.possibleValues[self.value]
          value, displayValue = _obj_0[1], _obj_0[2]
        end
        return displayValue or value
      end
    end,
    draw = function(self, ass, selected)
      if selected then
        ass:append(tostring(bold(self.displayText)) .. ": ")
      else
        ass:append(tostring(self.displayText) .. ": ")
      end
      if self:hasPrevious() then
        ass:append("◀ ")
      end
      ass:append(self:getDisplayValue())
      if self:hasNext() then
        ass:append(" ▶")
      end
      return ass:append("\\N")
    end,
    optVisible = function(self)
      if self.visibleCheckFn == nil then
        return true
      else
        return self.visibleCheckFn()
      end
    end
  }
  _base_0.__index = _base_0
  _class_0 = setmetatable({
    __init = function(self, optType, displayText, value, opts, visibleCheckFn)
      self.optType = optType
      self.displayText = displayText
      self.opts = opts
      self.value = 1
      self.visibleCheckFn = visibleCheckFn
      return self:setValue(value)
    end,
    __base = _base_0,
    __name = "Option"
  }, {
    __index = _base_0,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  Option = _class_0
end
-- Shared menu choices; constructing a page only creates its editable values.
local menu_choices = {
  scaleHeightOpts = {
        possibleValues = {
          { -1, "Source" },
          { 240, "240p" },
          { 360, "360p" },
          { 480, "480p" },
          { 720, "720p" },
          { 1080, "1080p" },
          { 1440, "1440p" },
          { 2160, "2160p" }
        }
  },
  crfWebmOpts = {
        step = 1,
        min = 1,
		max = 63,
        altDisplayNames = {
		  [23] = "23",
        }
  },
  crfMp4Opts = {
        step = 0.25,
        min = 0,
		max = 51,
        altDisplayNames = {
		  [23] = "23",
        }
  },
  cqNvencOpts = {
        step = 1,
        min = 1,
		max = 51,
        altDisplayNames = {
          [20] = "20",
        }
  },
  cqNvencAv1Opts = {
        step = 1,
        min = 1,
		max = 51,
        altDisplayNames = {
		  [20] = "20",

        }
  },
  audioOpts = {
        possibleValues = {
          { 64000, "64k" },
          { 80000, "80k" },
          { 96000, "96k" },
          { 128000, "128k" },
          { 192000, "192k" },
          { 320000, "320k" }
        }
  },
  fpsOpts = {
        possibleValues = {
          { -1, "Source" },
          { 12 },
          { 20 },
          { 24 },
          { 30 },
          { 40 },
          { 48 },
          { 50 },
          { 60 }
        }
  },
  tuneAvcOpts = {
        possibleValues = {
          { "", "None" },
          { "film", "Film" },
          { "animation", "Animation" },
          { "grain", "Grain" }
        }
  },
  tuneHevcOpts = {
        possibleValues = {
          { "", "None" },
          { "animation", "Animation" },
          { "grain", "Grain" }
        }
  },
  videoCodecNvencOpts = {
        possibleValues = {
          { "h264_nvenc", "H264" },
          { "hevc_nvenc", "H265" },
          { "av1_nvenc", "AV1" }
        }
  },
  videoCodecMp4Opts = {
        possibleValues = {
          { "libx264", "x264" },
          { "libx265", "x265" }
        }
  },
  videoCodecWebmOpts = {
        possibleValues = {
          { "libsvtav1", "AV1" },
          { "libvpx-vp9", "VP9" }
        }
  },
  videoCodecBasketOpts = {
        possibleValues = {
          { "libx264", "x264 (mp4, 8bit)" },
          { "libvpx-vp9", "VP9 (webm, 10bit)" }
        }
  },
  targetSizeBasketOpts = {
        possibleValues = {
          { 0, "Off" },
          { 3, "3 MB" },
          { 4, "4 MB" },
          { 8, "8 MB" },
          { 10, "10 MB" }
        }
  },
  targetSizeOpts = {
    possibleValues = {
      { 0, "Off" }, { 20, "20 MB" }, { 200, "200 MB" }
    }
  },
  audioCodecMuxedOpts = {
        possibleValues = {
          { "aac", "AAC (Compatibility)" },
          { "libopus", "OPUS (Quality)" }
        }
  },
  colorFilter8BitOpts = {
        possibleValues = {
          { "format=yuv420p", "Off" },
          { "libplacebo=tonemapping=auto:brightness=0.05:gamma=1.10:contrast=0.95:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv,format=yuv420p", "On" }
        }
  },
  colorFilter10BitOpts = {
        possibleValues = {
          { "format=yuv420p10le", "Off" },
          { "libplacebo=tonemapping=auto:brightness=0.05:gamma=1.10:contrast=0.95:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv,format=yuv420p10le", "On" }
        }
  },
  presetAvcOpts = {
        possibleValues = {
          { "medium", "Medium" },
          { "slow", "Slow" },
          { "slower", "Slower" },        
		  { "veryslow", "Very Slow" }
        }
  },
  presetHevcOpts = {
        possibleValues = {
          { "fast", "Fast" },
          { "medium", "Medium" },        
		  { "slow", "Slow" },
          { "slower", "Slower" }
        }
  },
  presetAv1Opts = {
        possibleValues = {
          { "8", "8" },
          { "6", "6" },
          { "4", "4" }
        }
  },
  audioCodecAudioOpts = {
        possibleValues = {
          { "libmp3lame", "MP3" },
          { "aac", "AAC" },
          { "libopus", "Opus" }
        }
  },
  compressionLevelWebpOpts = {
        possibleValues = {
          { 2, "Fast" },
          { 4, "Balanced" },
          { 6, "Maximum (Very Slow)" }
        }
  },
}
menu_choices.formatOpts = { possibleValues = {} }
for _, id in ipairs({ "mp4", "WebM", "NVENC", "Audio", "Animated", "Basket" }) do
  table.insert(menu_choices.formatOpts.possibleValues, { id, formats[id].displayName })
end
local EncodeOptionsPage
do
  local _class_0
  local _parent_0 = Page
  local _base_0 = {
    getOptionValue = function(self, name)
      local opt = self.optionsByName and self.optionsByName[name]
      if opt then
        return opt:getValue()
      end
      return options[name]
    end,
    getCurrentOption = function(self)
      return self.options[self.currentOption][2]
    end,
    leftKey = function(self)
      (self:getCurrentOption()):leftKey()
      return self:draw()
    end,
    rightKey = function(self)
      (self:getCurrentOption()):rightKey()
      return self:draw()
    end,
    prevOpt = function(self)
      for i = self.currentOption - 1, 1, -1 do
        if self.options[i][2]:optVisible() then
          self.currentOption = i
          break
        end
      end
      return self:draw()
    end,
    nextOpt = function(self)
      for i = self.currentOption + 1, #self.options do
        if self.options[i][2]:optVisible() then
          self.currentOption = i
          break
        end
      end
      return self:draw()
    end,
    confirmOpts = function(self)
      for _, optPair in ipairs(self.options) do
        local optName, opt
        optName, opt = optPair[1], optPair[2]
        options[optName] = opt:getValue()
      end
      self:hide()
      return self.callback(true)
    end,
    cancelOpts = function(self)
      self:hide()
      return self.callback(false)
    end,
    draw = function(self)
      local window_w, window_h = mp.get_osd_size()
      local ass = assdraw.ass_new()
      ass:new_event()
      self:setup_text(ass)
      ass:append(tostring(bold('Options:')) .. "\\N\\N")
      for i, optPair in ipairs(self.options) do
        local opt = optPair[2]
        if opt:optVisible() then
          opt:draw(ass, self.currentOption == i)
        end
      end
      ass:append("\\N▲ / ▼: navigate\\N")
      ass:append(tostring(bold('ENTER:')) .. " confirm options\\N")
      ass:append(tostring(bold('ESC:')) .. " cancel\\N")
      return mp.set_osd_ass(window_w, window_h, ass.text)
    end
  }
  _base_0.__index = _base_0
  _class_0 = make_class({
    __init = function(self, callback)
      self.callback = callback
      self.currentOption = 1
      self.options = {
        {
          "output_format",
          Option("list", "Output Format", options.output_format, menu_choices.formatOpts)
        },
        {
          "crf_webm",
          Option("int", "V-Quality", options.crf_webm, menu_choices.crfWebmOpts, function()
			local fmt = self:getOptionValue("output_format")
			return (fmt == "WebM" and (self:getOptionValue("video_codec_webm") ~= "libsvtav1" or self:getOptionValue("target_size_av1_mb") == 0)) or (fmt == "Basket" and self:getOptionValue("video_codec_basket") == "libvpx-vp9" and self:getOptionValue("target_size_basket_mb") == 0)
          end)
        },
        {
          "crf_mp4",
          Option("int", "V-Quality", options.crf_mp4, menu_choices.crfMp4Opts, function()
			local fmt = self:getOptionValue("output_format")
			return (fmt == "mp4" and self:getOptionValue("target_size_mp4_mb") == 0) or (fmt == "Basket" and self:getOptionValue("video_codec_basket") == "libx264" and self:getOptionValue("target_size_basket_mb") == 0)
          end)
        },
        {
          "cq_nvenc",
          Option("int", "V-Quality", options.cq_nvenc, menu_choices.cqNvencOpts, function()
			return self:getOptionValue("output_format") == "NVENC" and self:getOptionValue("target_size_nvenc_mb") == 0 and self:getOptionValue("video_codec_nvenc") ~= "av1_nvenc"
          end)
        },
        {
          "cq_nvenc_av1",
          Option("int", "V-Quality", options.cq_nvenc_av1, menu_choices.cqNvencAv1Opts, function()
			return self:getOptionValue("output_format") == "NVENC" and self:getOptionValue("target_size_nvenc_mb") == 0 and self:getOptionValue("video_codec_nvenc") == "av1_nvenc"
          end)
        },
        {
          "aac_bitrate",
          Option("list", "A-Quality", options.aac_bitrate, menu_choices.audioOpts, function()
			local fmt = self:getOptionValue("output_format")
			if (fmt == "mp4" or fmt == "NVENC") and self:getOptionValue("audio_codec_muxed") == "aac" then
			  return true
			end
			return fmt == "Audio" and self:getOptionValue("audio_codec_audio") == "aac"
          end)
        },
        {
          "opus_bitrate",
          Option("list", "A-Quality", options.opus_bitrate, menu_choices.audioOpts, function()
			local fmt = self:getOptionValue("output_format")
			if fmt == "WebM" then
			  return true
			end
			if (fmt == "mp4" or fmt == "NVENC") and self:getOptionValue("audio_codec_muxed") == "libopus" then
			  return true
			end
			if fmt == "Audio" and self:getOptionValue("audio_codec_audio") == "libopus" then
			  return true
			end
			return false
          end)
        },
        {
          "mp3_bitrate",
          Option("list", "A-Quality", options.mp3_bitrate, menu_choices.audioOpts, function()
			return self:getOptionValue("output_format") == "Audio" and self:getOptionValue("audio_codec_audio") == "libmp3lame"
          end)
        },
		{
          "scale_height",
          Option("list", "Scale Height", options.scale_height, menu_choices.scaleHeightOpts, function()
			local fmt = self:getOptionValue("output_format")
			return fmt == "mp4" or fmt == "WebM" or fmt == "NVENC" or fmt == "Animated" or fmt == "Basket"
          end)
        },
        {
          "fps",
          Option("list", "Framerate", options.fps, menu_choices.fpsOpts, function()
			local fmt = self:getOptionValue("output_format")
			return fmt == "mp4" or fmt == "WebM" or fmt == "NVENC" or fmt == "Animated" or fmt == "Basket"
		  end)
        },
       {
         "video_codec_nvenc",
         Option("list", "V-Codec", options.video_codec_nvenc, menu_choices.videoCodecNvencOpts, function()
			return self:getOptionValue("output_format") == "NVENC"
          end)
        },
       {
         "video_codec_mp4",
         Option("list", "V-Codec", options.video_codec_mp4, menu_choices.videoCodecMp4Opts, function()
			return self:getOptionValue("output_format") == "mp4"
          end)
        },
        {
          "video_codec_webm",
          Option("list", "V-Codec", options.video_codec_webm, menu_choices.videoCodecWebmOpts, function()
			return self:getOptionValue("output_format") == "WebM"
          end)
        },
        {
          "audio_codec_muxed",
          Option("list", "A-Codec", options.audio_codec_muxed, menu_choices.audioCodecMuxedOpts, function()
			local fmt = self:getOptionValue("output_format")
			return fmt == "mp4" or fmt == "NVENC"
          end)
        },
        {
          "audio_codec_audio",
          Option("list", "A-Codec", options.audio_codec_audio, menu_choices.audioCodecAudioOpts, function()
			return self:getOptionValue("output_format") == "Audio"
          end)
        },
        {
          "preset_avc",
          Option("list", "Preset", options.preset_avc, menu_choices.presetAvcOpts, function()
			return self:getOptionValue("output_format") == "mp4" and self:getOptionValue("video_codec_mp4") == "libx264"
          end)
        },
        {
          "preset_hevc",
          Option("list", "Preset", options.preset_hevc, menu_choices.presetHevcOpts, function()
			return self:getOptionValue("output_format") == "mp4" and self:getOptionValue("video_codec_mp4") == "libx265"
          end)
        },
        {
          "preset_av1",
          Option("list", "Preset", options.preset_av1, menu_choices.presetAv1Opts, function()
			return self:getOptionValue("output_format") == "WebM" and self:getOptionValue("video_codec_webm") == "libsvtav1"
          end)
        },
        {
          "tune_avc",
          Option("list", "Tune", options.tune_avc, menu_choices.tuneAvcOpts, function()
			return self:getOptionValue("output_format") == "mp4" and self:getOptionValue("video_codec_mp4") == "libx264"
          end)
        },
        {
          "tune_hevc",
          Option("list", "Tune", options.tune_hevc, menu_choices.tuneHevcOpts, function()
			return self:getOptionValue("output_format") == "mp4" and self:getOptionValue("video_codec_mp4") == "libx265"
          end)
        },
        {
          "color_filter_10bit",
          Option("list", "Tone mapping", options.color_filter_10bit, menu_choices.colorFilter10BitOpts, function()
			local fmt = self:getOptionValue("output_format")
			return fmt == "WebM" or (fmt == "Basket" and self:getOptionValue("video_codec_basket") == "libvpx-vp9")
          end)
        }, 
		{
          "color_filter_8bit",
          Option("list", "Tone mapping", options.color_filter_8bit, menu_choices.colorFilter8BitOpts, function()
			local fmt = self:getOptionValue("output_format")
			return fmt == "mp4" or fmt == "NVENC" or (fmt == "Basket" and self:getOptionValue("video_codec_basket") == "libx264")
          end)
        },
        {
          "compression_level_webp",
          Option("list", "Compression", options.compression_level_webp, menu_choices.compressionLevelWebpOpts, function()
			return self:getOptionValue("output_format") == "Animated"
          end)
        },
        {
          "video_codec_basket",
          Option("list", "V-Codec", options.video_codec_basket, menu_choices.videoCodecBasketOpts, function()
			return self:getOptionValue("output_format") == "Basket"
          end)
        },
        {
          "target_size_basket_mb",
          Option("list", "Target Size", options.target_size_basket_mb, menu_choices.targetSizeBasketOpts, function()
			return self:getOptionValue("output_format") == "Basket"
          end)
        },
        {
          "target_size_av1_mb",
          Option("list", "Target Size", options.target_size_av1_mb, menu_choices.targetSizeOpts, function()
            return self:getOptionValue("output_format") == "WebM" and self:getOptionValue("video_codec_webm") == "libsvtav1"
          end)
        },
        {
          "target_size_nvenc_mb",
          Option("list", "Target Size", options.target_size_nvenc_mb, menu_choices.targetSizeOpts, function()
            return self:getOptionValue("output_format") == "NVENC"
          end)
        },
        {
          "target_size_mp4_mb",
          Option("list", "Target Size", options.target_size_mp4_mb, menu_choices.targetSizeOpts, function()
            local fmt = self:getOptionValue("output_format")
            local codec = self:getOptionValue("video_codec_mp4")
            return fmt == "mp4" and (codec == "libx264" or codec == "libx265")
          end)
        }
      }
      self.optionsByName = { }
      for _, optPair in ipairs(self.options) do
        self.optionsByName[optPair[1]] = optPair[2]
      end
      self.keybinds = {
        ["LEFT"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.leftKey
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["RIGHT"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.rightKey
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["UP"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.prevOpt
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["DOWN"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.nextOpt
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["ENTER"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.confirmOpts
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["ESC"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.cancelOpts
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)()
      }
    end,
    __base = _base_0,
    __name = "EncodeOptionsPage",
    __parent = _parent_0
  })
  EncodeOptionsPage = _class_0
end
local PreviewPage
do
  local _class_0
  local _parent_0 = Page
  local _base_0 = {
    __init = function(self, callback, region, startTime, endTime)
      self.callback = callback
      self.originalProperties = {
        ["vf"] = mp.get_property_native("vf"),
        ["time-pos"] = mp.get_property_native("time-pos"),
        ["pause"] = mp.get_property_native("pause")
      }
      self.keybinds = {
        ["ESC"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.cancel
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)()
      }
      self.region = region
      self.startTime = startTime
      self.endTime = endTime
    end,
    prepare = function(self)
      local vf = self.originalProperties["vf"]
      if type(vf) == "table" then
        vf = copy_list(vf)
      else
        vf = { }
      end
      -- Keep subtitles in the filter chain, then apply the selected crop.
      vf[#vf + 1] = {
        name = "sub"
      }
      if self.region and self.region.is_valid and self.region:is_valid() then
        vf[#vf + 1] = {
          name = "crop",
          params = {
            w = tostring(self.region.w),
            h = tostring(self.region.h),
            x = tostring(self.region.x),
            y = tostring(self.region.y)
          }
        }
      end
      mp.set_property_native("vf", vf)
      mp.set_property_native("ab-loop-a", self.startTime)
      mp.set_property_native("ab-loop-b", self.endTime)
      mp.set_property_native("time-pos", self.startTime)
      return mp.set_property_native("pause", false)
    end,
    dispose = function(self)
      mp.set_property("ab-loop-a", "no")
      mp.set_property("ab-loop-b", "no")
      for prop, value in pairs(self.originalProperties) do
        mp.set_property_native(prop, value)
      end
    end,
    draw = function(self)
      local window_w, window_h = mp.get_osd_size()
      local ass = assdraw.ass_new()
      ass:new_event()
      self:setup_text(ass)
      ass:append("Press " .. tostring(bold("ESC")) .. " to exit preview.\\N")
      return mp.set_osd_ass(window_w, window_h, ass.text)
    end,
    cancel = function(self)
      self:hide()
      return self.callback()
    end
  }
  _base_0.__index = _base_0
  _class_0 = make_class({
    __init = _base_0.__init,
    __base = _base_0,
    __name = "PreviewPage",
    __parent = _parent_0
  })
  PreviewPage = _class_0
end
local MainPage
do
  local _class_0
  local _parent_0 = Page
  local _base_0 = {
    setStartTime = function(self)
      self.startTime = mp.get_property_number("time-pos")
      if self.visible then
        self:clear()
        return self:draw()
      end
    end,
    setEndTime = function(self)
      self.endTime = mp.get_property_number("time-pos")
      if self.visible then
        self:clear()
        return self:draw()
      end
    end,
    setupStartAndEndTimes = function(self)
      if mp.get_property_native("duration") then
        self.startTime = 0
        self.endTime = mp.get_property_native("duration")
      else
        self.startTime = -1
        self.endTime = -1
      end
      if self.visible then
        self:clear()
        return self:draw()
      end
    end,
    draw = function(self)
      local window_w, window_h = mp.get_osd_size()
      local ass = assdraw.ass_new()
      ass:new_event()
      self:setup_text(ass)
      ass:append(tostring(bold('Encoding Tool')) .. "\\N\\N")
      ass:append(tostring(bold('1:')) .. " Start time (" .. tostring(seconds_to_time_string(self.startTime)) .. ")\\N")
      ass:append(tostring(bold('2:')) .. " End time (" .. tostring(seconds_to_time_string(self.endTime)) .. ")\\N")
	  ass:append(tostring(bold('c:')) .. " Crop\\N")
      ass:append(tostring(bold('q:')) .. " Options\\N")
      ass:append(tostring(bold('p:')) .. " Preview\\N")
      ass:append(tostring(bold('e:')) .. " Encode\\N\\N")
      ass:append(tostring(bold('ESC:')) .. " Close\\N")
      return mp.set_osd_ass(window_w, window_h, ass.text)
    end,
    onUpdateCropRegion = function(self, updated, newRegion)
      if updated then
        self.region = newRegion
      end
      return self:show()
    end,
    crop = function(self)
      self:hide()
      local cropPage = CropPage((function()
        local _base_1 = self
        local _fn_0 = _base_1.onUpdateCropRegion
        return function(...)
          return _fn_0(_base_1, ...)
        end
      end)(), self.region)
      return cropPage:show()
    end,
    onOptionsChanged = function(self, updated)
      return self:show()
    end,
    changeOptions = function(self)
      self:hide()
      local encodeOptsPage = EncodeOptionsPage((function()
        local _base_1 = self
        local _fn_0 = _base_1.onOptionsChanged
        return function(...)
          return _fn_0(_base_1, ...)
        end
      end)())
      return encodeOptsPage:show()
    end,
    onPreviewEnded = function(self)
      return self:show()
    end,
    preview = function(self)
      if self.startTime < 0 then
        message("No start time")
        return 
      end
      if self.endTime < 0 then
        message("No end time")
        return 
      end
      if self.startTime >= self.endTime then
        message("Start time is ahead of end time")
        return 
      end
      self:hide()
      local previewPage = PreviewPage((function()
        local _base_1 = self
        local _fn_0 = _base_1.onPreviewEnded
        return function(...)
          return _fn_0(_base_1, ...)
        end
      end)(), self.region, self.startTime, self.endTime)
      return previewPage:show()
    end,
    encode = function(self)
      self:hide()
      if self.startTime < 0 then
        message("No start time")
        return 
      end
      if self.endTime < 0 then
        message("No end time")
        return 
      end
      if self.startTime >= self.endTime then
        message("Start time is ahead of end time")
        return 
      end
      if active_encode then return end
      active_encode = { files = {}, sequence = 0 }
      active_encode.thread = coroutine.create(function()
        return encode(self.region, self.startTime, self.endTime)
      end)
      return resume_encode()
    end
  }
  _base_0.__index = _base_0
  _class_0 = make_class({
    __init = function(self)
      self.keybinds = {
        ["c"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.crop
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["1"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.setStartTime
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["2"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.setEndTime
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["q"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.changeOptions
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["p"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.preview
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["e"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.encode
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)(),
        ["ESC"] = (function()
          local _base_1 = self
          local _fn_0 = _base_1.hide
          return function(...)
            return _fn_0(_base_1, ...)
          end
        end)()
      }
      self.startTime = -1
      self.endTime = -1
      self.region = Region()
    end,
    __base = _base_0,
    __name = "MainPage",
    __parent = _parent_0
  })
  MainPage = _class_0
end
monitor_dimensions()
local mainPage = MainPage()
mp.add_key_binding(options.keybind, "display-encoder", (function()
  local _base_0 = mainPage
  local _fn_0 = _base_0.show
  return function(...)
    if active_encode then return end
    return _fn_0(_base_0, ...)
  end
end)(), {
  repeatable = false
})
return mp.register_event("file-loaded", (function()
  local _base_0 = mainPage
  local _fn_0 = _base_0.setupStartAndEndTimes
  return function(...)
    return _fn_0(_base_0, ...)
  end
end)())
