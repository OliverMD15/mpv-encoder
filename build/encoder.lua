local mp = require("mp")
local assdraw = require("mp.assdraw")
local msg = require("mp.msg")
local utils = require("mp.utils")
local mpopts = require("mp.options")

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
	vfr = false, -- preserve timestamps while removing duplicate frames; mutually exclusive with fps
	filter_policy = "safe-only", -- inherit, safe-only, or ignore
	downmix_audio = true,

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
	-- Target-size mode searches quickly, then re-encodes once with these
	-- higher-quality settings. Audio remains a separate .ogg file.
	basket_search_preset = "medium",
	basket_final_preset = "veryslow",
	basket_first_pass_speed = 4,
	basket_search_second_pass_speed = 2,
	basket_final_second_pass_speed = 0,
	basket_final_attempts = 2,
	basket_target_tolerance = 0.95
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
if options.filter_policy ~= "inherit" and options.filter_policy ~= "safe-only" and options.filter_policy ~= "ignore" then
  msg.warn("Unknown filter_policy '" .. tostring(options.filter_policy) .. "'; using safe-only")
  options.filter_policy = "safe-only"
end
if options.vfr and options.fps ~= -1 then
  msg.warn("vfr=true overrides fps=" .. tostring(options.fps) .. "; using Source framerate")
  options.fps = -1
end
if options.target_size_mp4_mb ~= 0 and options.target_size_mp4_mb ~= 20 and options.target_size_mp4_mb ~= 200 then
  msg.warn("target_size_mp4_mb must be 0, 20, or 200; using Off")
  options.target_size_mp4_mb = 0
end
if options.target_size_av1_mb ~= 0 and options.target_size_av1_mb ~= 20 and options.target_size_av1_mb ~= 200 then
  msg.warn("target_size_av1_mb must be 0, 20, or 200; using Off")
  options.target_size_av1_mb = 0
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
local get_null_path
get_null_path = function()
  if file_exists("/dev/null") then
    return "/dev/null"
  end
  return "NUL"
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
  return tostring(encode_out_path) .. "-video-pass1-" .. instance_id .. ".log"
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
    displayName = "VP9",
    extension = "webm",
    deferPlainColorFilter = true,
    clampFilter = "limiter=min=0:max=1023",
    twoPass = true,
    pass1Muxer = "webm",
    targetSize = {
      crfMin = 31,
      crfMax = 60,
      initialCrf = 45,
      fineStep = 1,
      maxAttempts = 8,
      integerQuality = true,
      getFinalOffset = function()
        -- Lower VP9 speed is slower and usually more efficient.
        local delta = (options.basket_search_second_pass_speed or 2) - (options.basket_final_second_pass_speed or 0)
        if delta > 0 then
          return -math.ceil(delta / 2)
        end
        return 0
      end
    }
  },
  ["libx264"] = {
    displayName = "AVC",
    extension = "mp4",
    twoPass = false,
    -- MP4 target-size mode uses a fast search pass and the configured
    -- preset for final candidates. Keep this separate from Basket's
    -- video-only target-size profile.
    mp4TargetSize = {
      crfMin = 23,
      crfMax = 40,
      initialCrf = 30,
      fineStep = 0.25,
      maxAttempts = 30,
      integerQuality = false,
      finalAttempts = 2,
      tolerance = 0.95
    },
    targetSize = {
      crfMin = 23,
      crfMax = 40,
      initialCrf = 30,
      fineStep = 0.25,
      maxAttempts = 30,
      integerQuality = false,
      getFinalOffset = function()
        local rank = { ultrafast = 0, superfast = 1, veryfast = 2, faster = 3, fast = 4, medium = 5, slow = 6, slower = 7, veryslow = 8 }
        local searchRank = rank[options.basket_search_preset] or rank.medium
        local finalRank = rank[options.basket_final_preset] or rank.veryslow
        if finalRank > searchRank then
          return -math.ceil((finalRank - searchRank) / 2)
        elseif finalRank < searchRank then
          return math.ceil((searchRank - finalRank) / 2)
        end
        return 0
      end
    }
  },
  ["libx265"] = {
    displayName = "HEVC",
    extension = "mp4",
    twoPass = false,
    mp4TargetSize = {
      crfMin = 23,
      crfMax = 45,
      initialCrf = 30,
      fineStep = 0.25,
      maxAttempts = 30,
      integerQuality = false,
      finalAttempts = 2,
      tolerance = 0.95
    }
  },
  ["libsvtav1"] = {
    displayName = "AV1",
    extension = "mp4",
    twoPass = false,
    targetSize = {
      crfMin = 25, crfMax = 60, initialCrf = 40,
      fineStep = 1, maxAttempts = 8, integerQuality = true,
      finalAttempts = 2, tolerance = 0.95
    }
  },
  ["h264_nvenc"] = {
    displayName = "NVENC AVC",
    extension = "mp4",
    twoPass = false
  },
  ["hevc_nvenc"] = {
    displayName = "NVENC HEVC",
    extension = "mp4",
    twoPass = false
  },
  ["av1_nvenc"] = {
    displayName = "NVENC AV1",
    extension = "mp4",
    twoPass = false
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
local get_audio_encode_flags
get_audio_encode_flags = function(codec)
  return {
    "-c:a", tostring(codec),
    "-b:a", tostring(get_audio_bitrate(codec))
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
      "-colorspace", "bt709",
      "-color_primaries", "bt709",
      "-color_trc", "bt709",
      "-color_range", "tv"
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
get_vp9_video_flags = function(pass, speed, crf)
  -- Shared between the "WebM" format's VP9 option and "Basket"'s -- video-
  -- side flags only, no audio (WebM muxes it, Basket never does; each
  -- caller appends its own audio handling, or none).
  -- Constant-quality, two-pass, tuned for heavily bitrate-starved output
  -- rather than raw archival quality -- CRF still governs quality/size,
  -- left alone here.
  local fps = options.fps > -1 and options.fps or (mp.get_property_native("container-fps") or 30)
  local flags = {
    "-c:v", "libvpx-vp9",
    "-crf", tostring(crf or options.crf_webm),
    "-b:v", "0",
    "-deadline", "good",
    -- WebM defaults to fast analysis / slow final encoding. Basket passes
    -- its own search/final speeds explicitly.
    "-speed", tostring(speed or (pass == 1 and 4 or 0)),
    "-profile:v", "2",
    "-row-mt", "1",
    "-tile-columns", "0",
    "-aq-mode", "1",
    "-g", tostring(math.floor(fps * 10 + 0.5)),
    "-frame-parallel", "0"
  }
  -- These tools improve the actual encoded stream. Pass 1 only generates
  -- rate-control statistics, so avoid spending time on them there.
  if pass ~= 1 then
    append(flags, {
      "-lag-in-frames", "25",
      "-auto-alt-ref", "6",
      "-arnr-maxframes", "7",
      "-arnr-strength", "4",
      "-arnr-type", "3",
      "-enable-tpl", "1"
    })
  end
  if pass then
    append(flags, {
      "-pass", tostring(pass)
    })
  end
  append(flags, get_color_tag_flags(options.color_filter_10bit))
  return flags
end
local get_mp4_video_flags
get_mp4_video_flags = function(codec, qualityProfile, crf)
  local preset = codec == "libx265" and options.preset_hevc or options.preset_avc
  if qualityProfile == "search" then
    preset = "fast"
  end
  local tune = codec == "libx265" and options.tune_hevc or options.tune_avc
  local flags = {
    "-c:v", codec,
    "-preset", tostring(preset),
    "-crf", tostring(crf or options.crf_mp4),
    "-movflags", "+faststart"
  }
  if tune ~= "" then
    append(flags, {
      "-tune", tostring(tune)
    })
  end
  if codec == "libx265" then
    append(flags, {
      "-tag:v", "hvc1"
    })
  end
  append(flags, get_color_tag_flags(options.color_filter_8bit))
  return flags
end
local get_svt_av1_video_flags
get_svt_av1_video_flags = function(pass, qualityProfile, presetStage, crf)
  local preset = tonumber(options.preset_av1) or 6
  if presetStage == "search" then
    preset = 8
  elseif presetStage == "near" then
    preset = 6
  elseif presetStage == "final" then
    preset = 4
  elseif type(presetStage) == "number" then
    crf = presetStage
  else
    crf = presetStage or crf
  end
  local flags = {
    "-c:v", "libsvtav1",
    "-preset", tostring(preset),
    "-crf", tostring(crf or options.crf_webm),
    "-svtav1-params", "tune=1:enable-variance-boost=1:enable-qm=1:ac-bias=1:tf-strength=1:qp-scale-compress-strength=1:sharpness=1:keyint=10s"
  }
  append(flags, get_color_tag_flags(options.color_filter_10bit))
  return flags
end
local get_basket_x264_video_flags
get_basket_x264_video_flags = function(qualityProfile, crf)
  local flags = {
    "-c:v", "libx264",
    "-preset", qualityProfile == "search" and options.basket_search_preset or options.basket_final_preset,
    "-crf", tostring(crf or options.crf_mp4),
    "-movflags", "+faststart",
    "-tune", "animation"
  }
  append(flags, get_color_tag_flags(options.color_filter_8bit))
  return flags
end
video_codec_profiles["libx264"].mp4Flags = function(qualityProfile, crf, presetStage)
  return get_mp4_video_flags("libx264", qualityProfile, crf, presetStage)
end
video_codec_profiles["libx264"].basketFlags = get_basket_x264_video_flags
video_codec_profiles["libx265"].mp4Flags = function(qualityProfile, crf, presetStage)
  return get_mp4_video_flags("libx265", qualityProfile, crf, presetStage)
end
video_codec_profiles["libsvtav1"].flags = get_svt_av1_video_flags
video_codec_profiles["libvpx-vp9"].flags = get_vp9_video_flags
local get_nvenc_video_flags
get_nvenc_video_flags = function(codec)
  -- Static "best possible quality, speed doesn't matter" settings.
  -- h264_nvenc has no UHQ tune, so only HEVC/AV1 use it.
  local tune = codec == "h264_nvenc" and "hq" or "uhq"
  local cq = codec == "av1_nvenc" and options.cq_nvenc_av1 or options.cq_nvenc
  local flags = {
    "-c:v", codec,
    "-preset", "p7",
    "-tune", tune,
    "-rc", "vbr",
    "-cq", tostring(cq),
    "-multipass", "fullres",
    "-spatial-aq", "1",
    "-temporal-aq", "1",
    "-rc-lookahead", "32",
    "-b_ref_mode", "each",
    "-movflags", "+faststart"
  }
  if codec == "av1_nvenc" then
    append(flags, {
      "-pix_fmt", "p010le",
      "-lookahead_level", "3"
    })
  elseif codec == "hevc_nvenc" then
    append(flags, {
      "-tag:v", "hvc1"
    })
  end
  append(flags, get_color_tag_flags(options.color_filter_8bit))
  return flags
end
video_codec_profiles["h264_nvenc"].flags = function()
  return get_nvenc_video_flags("h264_nvenc")
end
video_codec_profiles["hevc_nvenc"].flags = function()
  return get_nvenc_video_flags("hevc_nvenc")
end
video_codec_profiles["av1_nvenc"].flags = function()
  return get_nvenc_video_flags("av1_nvenc")
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
    supportsTwoPass = function(self)
      return self:getCodecProfile().twoPass == true
    end,
    getCodecFlags = function(self)
      local codecs = { }
      if self:getVideoCodec() == "" then
        codecs[#codecs + 1] = "-vn"
      end
      if self:getAudioCodec() == "" then
        codecs[#codecs + 1] = "-an"
      end
      return codecs
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
    getTargetSizeProfile = function(self)
      return self:getCodecProfile().mp4TargetSize
    end,
    getFlags = function(self, pass, qualityProfile, crf, presetStage)
      local flags = self:getCodecProfile().mp4Flags(qualityProfile, crf, presetStage)
      append(flags, get_audio_encode_flags(options.audio_codec_muxed))
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
    getFlags = function(self, pass, qualityProfile, crf, presetStage)
      local flags
      if self:getVideoCodec() == "libsvtav1" then
        flags = self:getCodecProfile().flags(pass, qualityProfile, presetStage, crf)
      else
        flags = self:getCodecProfile().flags(pass)
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
      self.outputExtension = "mp4"
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
    getFlags = function(self)
      return {
        "-c:a", tostring(options.audio_codec_audio),
        "-b:a", tostring(get_audio_bitrate(options.audio_codec_audio))
      }
    end
  }
  _base_0.__index = _base_0
  _class_0 = make_class({
    __init = function(self)
      self.displayName = "Audio"
      self.videoCodec = ""
      self.audioCodec = "libopus"
      self.outputExtension = "ogg"
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
        "-c:v", "libwebp_anim",
        "-loop", "0",
        "-lossless", "0",
        "-compression_level", tostring(options.compression_level_webp),
        "-q:v", tostring(options.quality_webp)
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
    getFlags = function(self)
      local flags = self:getCodecProfile().flags()
      append(flags, get_audio_encode_flags(options.audio_codec_muxed))
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
    getFlags = function(self, pass, quality_profile, crf)
      local profile = self:getCodecProfile()
      if profile.twoPass then
        local speed = options.basket_search_second_pass_speed
        if pass == 1 then
          speed = options.basket_first_pass_speed
        elseif quality_profile == "final" then
          speed = options.basket_final_second_pass_speed
        end
        return profile.flags(pass, speed, crf)
      end
      return profile.basketFlags(quality_profile, crf)
    end
  }
  _base_0.__index = _base_0
  _class_0 = make_class({
    __init = function(self)
      self.displayName = "Basket"
      self.videoCodec = "video"
      self.audioCodec = ""
      self.outputExtension = "mp4"
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
-- One coroutine owns a complete job, including Basket attempts and both
-- VP9 passes. Only subprocess waits yield; the existing cleanup paths still
-- run on failure/cancellation. No shell is involved in launching FFmpeg.
local active_encode
local function track_encode_file(path)
  if active_encode and path then active_encode.files[path] = true end
  return path
end
local function cancel_encode()
  if not active_encode then return end
  active_encode.cancelled = true
  if active_encode.request then mp.abort_async_command(active_encode.request) end
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
      if job.request then mp.abort_async_command(job.request) end
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
-- Defer unloading long enough to reap FFmpeg and clean its files. This also
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
      if self.fps then
        ass:append(" at " .. string.format("%.1f fps", self.fps))
      end
      if self.speed then
        if self.fps then
          ass:append(" (" .. tostring(self.speed) .. ")")
        else
          ass:append(" at " .. tostring(self.speed))
        end
      end
      ass:append("\\NESC: Cancel")
      return mp.set_osd_ass(window_w, window_h, ass.text)
    end,
    parseLine = function(self, line)
      local outTimeUs = string.match(line, "^out_time_us=(%d+)")
      if outTimeUs then
        self.elapsed = math.max(self.elapsed, tonumber(outTimeUs) / 1000000)
      end
      local h, m, s = string.match(line, "^out_time=(%d+):(%d+):([%d%.]+)")
      if h ~= nil and not outTimeUs then
        local elapsed = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
        self.elapsed = math.max(self.elapsed, elapsed)
      end
      local speed = string.match(line, "^speed=(.+)")
      if speed and speed ~= "N/A" then
        self.speed = speed
      end
      local fps = tonumber(string.match(line, "^fps=([%d%.]+)"))
      if fps and fps > 0 then
        self.fps = fps
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
      -- A separate file lets mpv remain responsive while FFmpeg runs.
      job.sequence = job.sequence + 1
      local outputDir = utils.split_path(command_line[#command_line])
      -- Pass 1 writes NUL, so keep progress next to the real job output.
      local progressPath = track_encode_file(utils.join_path(job.directory or outputDir,
        ".encoder-progress-" .. instance_id .. "-" .. job.sequence .. ".txt"))
      local output = table.remove(copy_command_line)
      append(copy_command_line, {
        "-nostdin", "-loglevel", "error",
        "-stats_period", "0.25",
        "-progress", progressPath,
        "-nostats"
      })
      table.insert(copy_command_line, output)
      self:show()
      job.page = self
      local offset, pending = 0, ""
      local function poll()
        local fd = io.open(progressPath, "rb")
        if not fd then return end
        fd:seek("set", offset)
        local chunk = fd:read("*a") or ""
        offset = offset + #chunk
        fd:close()
        pending = pending .. chunk
        local last = 1
        for line, nextPos in pending:gmatch("([^\n]*)\n()") do
          self:parseLine((line:gsub("\r$", "")))
          last = nextPos
        end
        pending = pending:sub(last)
        self:draw()
      end
      job.timer = mp.add_periodic_timer(0.25, poll)
      job.request = mp.command_native_async({
        name = "subprocess", args = copy_command_line, playback_only = false,
        capture_stdout = false, capture_stderr = true,
      }, function(success, result, err)
        job.request = nil
        job.timer:kill()
        job.timer = nil
        poll()
        self:hide()
        job.page = nil
        os.remove(progressPath)
        local passed = success and result and result.status == 0 and not job.cancelled
        if not passed and not job.cancelled then
          local detail = result and result.stderr
          if not detail or detail == "" then detail = result and result.error_string or err end
          msg.error("FFmpeg failed: " .. tostring(detail))
        end
        resume_encode(passed)
      end)
      return coroutine.yield()
    end
  }
  _base_0.__index = _base_0
  _class_0 = make_class({
    __init = function(self, startTime, endTime, label)
      self.duration = endTime - startTime
      self.elapsed = 0
      self.label = label or "Encoding"
      self.fps = nil
      self.speed = nil
      self.keybinds = { ESC = cancel_encode }
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
local get_stream_maps
get_stream_maps = function(format, skip_video)
  -- Maps whatever mpv currently has active (vid/aid) onto the ffmpeg
  -- stream indices ffmpeg needs for -map, via track-list's ff-index.
  -- PoC scope: single active track only, internal (non-external-file)
  -- tracks only, no multi-track audio mixing.
  -- skip_video: when the video output comes from a -filter_complex label
  -- instead (image-based subtitle burn-in), the caller maps it itself.
  local maps = { }
  local videoCodec = format.getVideoCodec and format:getVideoCodec() or format.videoCodec
  local audioCodec = format.getAudioCodec and format:getAudioCodec() or format.audioCodec
  local want_video = videoCodec ~= "" and not skip_video
  local want_audio = audioCodec ~= "" and not mp.get_property_bool("mute")
  for _, track in ipairs(mp.get_property_native("track-list")) do
    if track["selected"] and not track["external"] and track["ff-index"] then
      if track["type"] == "video" and want_video then
        append(maps, {
          "-map", "0:" .. tostring(track["ff-index"])
        })
        want_video = false
      elseif track["type"] == "audio" and want_audio then
        append(maps, {
          "-map", "0:" .. tostring(track["ff-index"])
        })
        want_audio = false
      end
    end
  end
  if audioCodec ~= "" and want_audio then
    -- No selected internal audio track was mapped: suppress auto-selection.
    append(maps, { "-an" })
  elseif mp.get_property_bool("mute") then
    append(maps, { "-an" })
  end
  return maps
end
local get_scale_filters
get_scale_filters = function()
  local filters = { }
  local scaleFlags = ":flags=lanczos+accurate_rnd+full_chroma_inp"
  if options.scale_height > 0 then
    append(filters, {
      "scale=-2:" .. tostring(options.scale_height) .. scaleFlags
    })
  end
  return filters
end
local get_fps_filters
get_fps_filters = function()
  -- Unlike mpv's encode mode (which writes VFR timestamps on a generic
  -- 24000fps timebase unless told otherwise), ffmpeg demuxing+encoding
  -- directly preserves the source's real frame timing on its own, so
  -- "Source" (-1) genuinely means "don't touch it" here.
	-- Explicit FPS conversion always removes near-duplicate frames first. The
	-- one-frame drop cap catches the common A,A / B,B pattern without letting a
	-- long low-motion scene collapse into a handful of frames.
	if options.vfr then
		return {
			"mpdecimate=max=1"
		}
	elseif options.fps > -1 then
		return {
			"mpdecimate=max=1",
			"fps=" .. tostring(options.fps)
		}
	end
	return { }
end
local get_fps_output_args
get_fps_output_args = function()
	if options.vfr then
		return {
			"-fps_mode:v", "vfr"
		}
	elseif options.fps > -1 then
		return {
			"-fps_mode:v", "cfr"
		}
	end
	return { }
end
local append_current_filters
local safe_filter_parameters = {
  crop = { w = true, h = true, out_w = true, out_h = true, x = true, y = true, keep_aspect = true, exact = true },
  scale = { w = true, h = true, width = true, height = true, flags = true, force_original_aspect_ratio = true, force_divisible_by = true },
  fps = { fps = true, start_time = true, round = true, eof_action = true },
  format = { pix_fmts = true, color_spaces = true, color_ranges = true },
  setsar = { sar = true, ratio = true, r = true, max = true },
  setdar = { dar = true, ratio = true, r = true, max = true },
  transpose = { dir = true, passthrough = true },
  hflip = {},
  vflip = {}
}
local function safe_filter_params(name, params)
  local allowed = safe_filter_parameters[name]
  if not allowed then
    return false
  end
  for key, value in pairs(params) do
    if not allowed[key] or (type(value) ~= "string" and type(value) ~= "number") then
      return false
    end
    -- Conservative subset: no graph separators, quoting, or escaping.
    -- Complex expressions remain available through the inherit policy.
    if tostring(value):find("[^%w_%.%+%-%*/%(%)| ]") then
      return false
    end
  end
  return true
end
append_current_filters = function(filters, policy)
  local vf = mp.get_property_native("vf")
  if not vf then
    return 
  end
  for _index_0 = 1, #vf do
    local filter = vf[_index_0]
    if filter["enabled"] ~= false then
      -- mpv prefixes some filter names with "lavfi-" to select the
      -- libavfilter version over its own native one (e.g. "lavfi-crop").
      -- ffmpeg only knows the plain libavfilter name.
      local name = string.gsub(filter["name"], "^lavfi%-", "")
      local params = filter["params"] or { }
      if policy == "safe-only" and not safe_filter_params(name, params) then
        msg.warn("Skipping unsupported filter or parameters in safe-only mode: " .. tostring(filter["name"]))
      else
        local parts = { }
        for k, v in pairs(params) do
          parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        end
        table.sort(parts)
        local str = name
        if #parts > 0 then
          str = str .. "=" .. table.concat(parts, ":")
        end
        append(filters, {
          str
        })
      end
    end
  end
end
local escape_subtitle_path
escape_subtitle_path = function(path)
  -- Escaping for the ffmpeg "subtitles" filter's filename= value: a
  -- literal backslash becomes "\\", a literal colon becomes "\:" (colon
  -- is the filter's key/value separator), and the whole thing is wrapped
  -- in single quotes below, with any literal quote backslash-escaped too.
  path = path:gsub("\\", "\\\\")
  path = path:gsub(":", "\\:")
  path = path:gsub("'", "\\'")
  return path
end
local image_subtitle_codecs = {
  hdmv_pgs_subtitle = true,
  dvd_subtitle = true,
  dvb_subtitle = true,
  xsub = true
}
local get_subtitle_info
get_subtitle_info = function(path)
  -- Automatically burns in whatever subtitle track mpv currently has
  -- selected and visible -- no separate on/off option. `selected` means
  -- the track is loaded/active (mpv's sid); `sub-visibility` is the
  -- separate toggle `cycle sub-visibility` (default key `v`) flips, which
  -- hides rendering without deselecting the track, so both are checked.
  -- mode == "text": bitmap-free subs (ass/srt/webvtt/mov_text/etc),
  --   rendered via the libass-based "subtitles" ffmpeg filter.
  -- mode == "image": bitmap subs (hdmv_pgs_subtitle/dvd_subtitle/
  --   dvb_subtitle/xsub), composited via -filter_complex overlay onto
  --   the raw decoded video, since libass can't render these. Only
  --   supported for tracks embedded in the file currently playing.
  if not mp.get_property_bool("sub-visibility", true) then
    return nil
  end
  local track_list = mp.get_property_native("track-list")
  local target = nil
  for _, track in ipairs(track_list) do
    if track["type"] == "sub" and track["selected"] then
      target = track
      break
    end
  end
  if not target then
    return nil
  end
  if image_subtitle_codecs[target["codec"]] then
    if target["external"] then
      message("Burn subtitles: external image-based subtitles aren't supported")
      return nil
    end
    if not target["ff-index"] then
      message("Burn subtitles: couldn't resolve subtitle stream")
      return nil
    end
    return {
      mode = "image",
      ffIndex = target["ff-index"]
    }
  end
  local subPath
  local streamIndex = nil
  if target["external"] then
    subPath = target["external-filename"]
  else
    subPath = path
    local idx = 0
    for _, track in ipairs(track_list) do
      if track["type"] == "sub" and not track["external"] then
        if track["id"] == target["id"] then
          streamIndex = idx
          break
        end
        idx = idx + 1
      end
    end
    if streamIndex == nil then
      streamIndex = 0
    end
  end
  if not subPath then
    message("Burn subtitles: couldn't resolve subtitle file")
    return nil
  end
  local filterStr = "subtitles=filename='" .. escape_subtitle_path(subPath) .. "'"
  if streamIndex then
    filterStr = filterStr .. ":si=" .. tostring(streamIndex)
  end
  return {
    mode = "text",
    filterStr = filterStr,
    isExternal = target["external"] == true
  }
end
local get_video_filters
get_video_filters = function(format, region, subtitleFilter, subtitleOffset)
  local filters = { }
  if subtitleFilter then
    -- ffmpeg normalizes output timestamps to start at 0 when "-ss" is
    -- given before "-i" (input seeking), but the subtitles filter still
    -- matches events against the *original* absolute timeline. Shift
    -- timestamps forward before the subtitles filter and back after, so
    -- subtitle timing lines up without desyncing the actual output.
    append(filters, {
      "setpts=PTS+" .. tostring(subtitleOffset) .. "/TB"
    })
  end
  append(filters, format:getPreFilters())
  if options.filter_policy ~= "ignore" then
    -- Picks up anything a live playback-side script (e.g. autocrop.lua)
    -- has already inserted into mpv's active filter chain, so it carries
    -- over into the encode instead of being silently dropped.
    append_current_filters(filters, options.filter_policy)
  end
  if region and region:is_valid() then
    append(filters, {
      "crop=" .. tostring(region.w) .. ":" .. tostring(region.h) .. ":" .. tostring(region.x) .. ":" .. tostring(region.y)
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
  if subtitleFilter then
    append(filters, {
      subtitleFilter
    })
    append(filters, {
      "setpts=PTS-" .. tostring(subtitleOffset) .. "/TB"
    })
  end
  return filters
end
local build_video_filter_args
build_video_filter_args = function(ctx)
  local format = ctx.format
  local subtitleFilter = ctx.subInfo and ctx.subInfo.filterStr or nil
  local subtitleOffset = (ctx.subInfo and ctx.subInfo.isExternal) and ctx.originalStartTime or ctx.startTime
  local filters = get_video_filters(format, ctx.region, subtitleFilter, subtitleOffset)

  if not ctx.useImageOverlay then
    if #filters == 0 then
      return { }
    end
    return {
      "-vf", table.concat(filters, ",")
    }
  end

  local graph = ""
  local videoLabel = "[0:v]"
  for _, track in ipairs(mp.get_property_native("track-list")) do
    if track.type == "video" and track.selected and not track.external and track["ff-index"] then
      videoLabel = "[0:" .. tostring(track["ff-index"]) .. "]"
      break
    end
  end
  local sourceLabel = videoLabel
  if ctx.useImageOverlay then
    graph = videoLabel .. "[0:" .. tostring(ctx.subInfo.ffIndex) .. "]overlay[cbi_base]"
    sourceLabel = "[cbi_base]"
  end
  if #filters > 0 then
    if graph ~= "" then
      graph = graph .. ";"
    end
    graph = graph .. sourceLabel .. table.concat(filters, ",") .. "[cbi_filtered]"
    sourceLabel = "[cbi_filtered]"
  end

  local outputLabel = "[cbi_out]"
  if sourceLabel ~= outputLabel then
    if graph == "" then
      graph = sourceLabel .. "null[cbi_out]"
    else
      graph = graph .. ";" .. sourceLabel .. "null[cbi_out]"
    end
  end
  return {
    "-filter_complex", graph,
    "-map", outputLabel
  }
end
local build_encode_command
build_encode_command = function(ctx)
  local command = {
    "ffmpeg",
    "-y",
    "-ss", seconds_to_time_string(ctx.startTime, false, true),
    "-i", ctx.path,
    "-t", tostring(ctx.endTime - ctx.startTime)
  }
  append(command, get_stream_maps(ctx.format, ctx.useImageOverlay))
  append(command, ctx.format:getCodecFlags())
  if ctx.format:getAudioCodec() ~= "" and options.downmix_audio then
    append(command, {
      "-ac", "2"
    })
  end
  if ctx.format:getVideoCodec() == "" then
    return command
  end
  append(command, build_video_filter_args(ctx))
  append(command, get_fps_output_args())
  return command
end
local build_encode_variants
build_encode_variants = function(ctx, targetPath, qualityProfile, crf, presetStage)
  local format = ctx.format
  local baseCommand = copy_list(ctx.baseCommand or build_encode_command(ctx))
  local variants = {
    passlog = nil,
    pass1 = nil,
    final = nil
  }
  if format:supportsTwoPass() then
    local codecProfile = format:getCodecProfile()
    variants.passlog = get_pass_logfile_path(targetPath)
    track_encode_file(variants.passlog .. "-0.log")
    track_encode_file(variants.passlog .. "-0.log.mbtree")
    variants.pass1 = copy_list(baseCommand)
    append(variants.pass1, format:getFlags(1, qualityProfile, crf, presetStage))
    append(variants.pass1, {
      "-an",
      "-passlogfile", variants.passlog,
      "-f", codecProfile.pass1Muxer or "null",
      get_null_path()
    })
    variants.final = copy_list(baseCommand)
    append(variants.final, format:getFlags(2, qualityProfile, crf, presetStage))
    append(variants.final, {
      "-passlogfile", variants.passlog,
      targetPath
    })
  else
    variants.final = baseCommand
    append(variants.final, format:getFlags(nil, qualityProfile, crf, presetStage))
    table.insert(variants.final, targetPath)
  end
  return variants
end
local remove_pass_logs
remove_pass_logs = function(passlog)
  if not passlog then
    return
  end
  os.remove(passlog .. "-0.log")
  os.remove(passlog .. "-0.log.mbtree")
end
local run_encode_variants
run_encode_variants = function(variants, startTime, endTime, label)
  if variants.pass1 then
    msg.info("Encoding pass 1/2 (analysis)")
    if not run_encode_command(variants.pass1, startTime, endTime, label .. " pass 1/2") then
      remove_pass_logs(variants.passlog)
      return false, "pass1"
    end
  end

  local finalLabel = variants.pass1 and label .. " pass 2/2" or label
  local ok = run_encode_command(variants.final, startTime, endTime, finalLabel)
  remove_pass_logs(variants.passlog)
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
local clamp_basket_crf
clamp_basket_crf = function(searchProfile, value)
  value = math.max(searchProfile.crfMin, math.min(searchProfile.crfMax, value))
  if searchProfile.integerQuality then
    return math.floor(value + 0.5)
  end
  return math.floor(value * 4 + 0.5) / 4
end
local basket_has_crf
basket_has_crf = function(candidates, value)
  for _, candidate in ipairs(candidates) do
    if math.abs(candidate.crf - value) < 0.0001 then
      return true
    end
  end
  return false
end
local basket_candidate_or_nil
basket_candidate_or_nil = function(searchProfile, attempts, value, current)
  value = clamp_basket_crf(searchProfile, value)
  if math.abs(value - current) < 0.0001 or basket_has_crf(attempts, value) then
    return nil
  end
  return value
end
local get_next_basket_crf
get_next_basket_crf = function(searchProfile, attempts, current, targetMB)
  local over, under = { }, { }
  for _, attempt in ipairs(attempts) do
    if attempt.sizeMB > targetMB then
      over[#over + 1] = attempt
    else
      under[#under + 1] = attempt
    end
  end

  table.sort(over, function(a, b) return a.crf < b.crf end)
  table.sort(under, function(a, b) return a.crf < b.crf end)
  if #over > 0 and #under > 0 then
    local lowCrf = over[#over]
    local highCrf = under[1]
    if lowCrf.crf < highCrf.crf and lowCrf.sizeMB > 0 and highCrf.sizeMB > 0 then
      local denominator = math.log(highCrf.sizeMB) - math.log(lowCrf.sizeMB)
      if math.abs(denominator) > 1e-12 then
        local ratio = (math.log(targetMB) - math.log(lowCrf.sizeMB)) / denominator
        local candidate = clamp_basket_crf(searchProfile, lowCrf.crf + (highCrf.crf - lowCrf.crf) * ratio)
        candidate = math.max(lowCrf.crf + searchProfile.fineStep, math.min(highCrf.crf - searchProfile.fineStep, candidate))
        candidate = basket_candidate_or_nil(searchProfile, attempts, candidate, current)
        if candidate then
          return candidate
        end
      end
    end
    return nil
  end

  if #attempts == 1 and attempts[1].sizeMB > 0 then
    local only = attempts[1]
    local candidate = only.crf + 6 * (math.log(only.sizeMB / targetMB) / math.log(2))
    candidate = basket_candidate_or_nil(searchProfile, attempts, candidate, current)
    if candidate then
      return candidate
    end
  end

  if #attempts >= 2 then
    local sorted = copy_list(attempts)
    table.sort(sorted, function(a, b) return a.crf < b.crf end)
    local a = sorted[#sorted - 1]
    local b = sorted[#sorted]
    if a.crf ~= b.crf and a.sizeMB > 0 and b.sizeMB > 0 then
      local slope = (math.log(b.sizeMB) - math.log(a.sizeMB)) / (b.crf - a.crf)
      if slope < -0.005 then
        local candidate = b.crf + (math.log(targetMB) - math.log(b.sizeMB)) / slope
        candidate = basket_candidate_or_nil(searchProfile, attempts, candidate, current)
        if candidate then
          return candidate
        end
      end
    end
  end

  local last = attempts[#attempts]
  local candidate = last.sizeMB > targetMB and current + searchProfile.fineStep or current - searchProfile.fineStep
  return basket_candidate_or_nil(searchProfile, attempts, candidate, current)
end
local get_initial_basket_final_crf
get_initial_basket_final_crf = function(searchProfile, searchCrf, searchSizeMB, targetMB)
  local offset = searchProfile.getFinalOffset and searchProfile.getFinalOffset() or 0
  local ratio = searchSizeMB / targetMB
  if ratio < 0.75 then
    offset = offset - 2 * searchProfile.fineStep
  elseif ratio < 0.88 then
    offset = offset - searchProfile.fineStep
  end
  return clamp_basket_crf(searchProfile, searchCrf + offset)
end
local is_better_basket_candidate
is_better_basket_candidate = function(candidate, best, targetMB)
  if not best then
    return true
  end
  local bestIsUnder = best.sizeMB <= targetMB
  local thisIsUnder = candidate.sizeMB <= targetMB
  if thisIsUnder and not bestIsUnder then
    return true
  end
  if thisIsUnder and bestIsUnder then
    return candidate.sizeMB > best.sizeMB
  end
  if not thisIsUnder and not bestIsUnder then
    return candidate.sizeMB < best.sizeMB
  end
  return false
end
local get_basket_final_correction
get_basket_final_correction = function(searchProfile, finalCandidates, currentCrf, sizeMB, targetMB)
  -- Same exponential model used during search, now based on an encode at
  -- the actual final-quality settings. Round away from the target so an
  -- overage gets smaller and an undershoot gets larger.
  local estimate = currentCrf + 6 * (math.log(sizeMB / targetMB) / math.log(2))
  local corrected
  if searchProfile.integerQuality then
    corrected = sizeMB > targetMB and math.ceil(estimate) or math.floor(estimate)
  else
    corrected = sizeMB > targetMB and math.ceil(estimate * 4) / 4 or math.floor(estimate * 4) / 4
  end
  corrected = clamp_basket_crf(searchProfile, corrected)
  if math.abs(corrected - currentCrf) < 0.0001 or basket_has_crf(finalCandidates, corrected) then
    return nil
  end
  return corrected
end
local build_basket_audio_command
build_basket_audio_command = function(ctx, outputPath)
  local command = {
    "ffmpeg",
    "-y",
    "-ss", seconds_to_time_string(ctx.startTime, false, true),
    "-i", ctx.path,
    "-t", tostring(ctx.endTime - ctx.startTime)
  }
  append(command, get_stream_maps({
    videoCodec = "",
    audioCodec = "libopus"
  }, false))
  append(command, {
    "-vn"
  })
  if options.downmix_audio then
    append(command, {
      "-ac", "2"
    })
  end
  append(command, {
    "-c:a", "libopus",
    "-b:a", "96k",
    outputPath
  })
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
  local stagedPath = staged_output_path(job.outputPath)
  local variants = build_encode_variants(ctx, stagedPath, nil)
  local passLabel = format:getCodecProfile().displayName or format:getVideoCodec()
  msg.info("Encoding to", job.outputPath)
  local label = variants.pass1 and passLabel or "Encoding"
  local ok, failedStage = run_encode_variants(variants, ctx.startTime, ctx.endTime, label)
  if ok and not file_is_nonempty(stagedPath) then
    msg.error("FFmpeg exited successfully but did not create a non-empty output file")
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
encode_target_size_job = function(ctx, job, outputDirectory, targetMB, labelPrefix)
  -- Search with deliberately faster settings, then validate the best CRF
  -- at the final-quality settings. Measure the actual complete candidate:
  -- Basket is video-only, whereas MP4 and WebM AV1 include muxed audio.
  local format = ctx.format
  local searchProfile = format:getTargetSizeProfile()
  if not searchProfile then
    message("Target-size encoding is not supported by " .. tostring(format:getVideoCodec()))
    cleanup_failed_encode(job, false)
    return false
  end

  local crf = searchProfile.initialCrf
  local tolerance = searchProfile.tolerance or options.basket_target_tolerance
  local maxAttempts = searchProfile.maxAttempts
  local attemptExt = format:getExtension()
  local attempts = { }
  local bestSearch = nil
  local bestPath = nil

  local function attempt_path(stage, n)
    return track_encode_file(utils.join_path(outputDirectory, ".encoder-target-" .. stage .. "-" .. instance_id .. "-" .. tostring(n) .. "." .. attemptExt))
  end

  local function build_and_run(targetPath, qualityProfile, progressLabel, attemptCrf, presetStage)
    local variants = build_encode_variants(ctx, targetPath, qualityProfile, attemptCrf, presetStage)
    if not run_encode_variants(variants, ctx.startTime, ctx.endTime, progressLabel) then
      return false
    end
    local info = utils.file_info(targetPath)
    if not info or not info.size or info.size <= 0 then
      return false
    end
    return true, info.size / (1024 * 1024)
  end

  local searchFailed = false
  for i = 1, maxAttempts do
    local thisPath = attempt_path("search", i)
    local label = labelPrefix .. " search " .. tostring(i) .. "/" .. tostring(maxAttempts) .. ", CRF " .. tostring(crf)
    local ok, sizeMB = build_and_run(thisPath, "search", label, crf)
    if not ok then
      message("Encode failed (size-search attempt, CRF " .. tostring(crf) .. ")")
      os.remove(thisPath)
      searchFailed = true
      break
    end
    message("Attempt " .. tostring(i) .. ": CRF " .. tostring(crf) .. " -> " .. string.format("%.1f", sizeMB) .. " MB (target " .. tostring(targetMB) .. " MB)")
    local attempt = { crf = crf, sizeMB = sizeMB, path = thisPath }
    attempts[#attempts + 1] = attempt
    if is_better_basket_candidate(attempt, bestSearch, targetMB) then
      if bestPath then
        os.remove(bestPath)
      end
      bestPath = thisPath
      bestSearch = attempt
    else
      os.remove(thisPath)
    end
    if sizeMB <= targetMB and sizeMB >= targetMB * tolerance then
      break
    end
    local newCrf = get_next_basket_crf(searchProfile, attempts, crf, targetMB)
    if not newCrf then
      message("No useful untried CRF remains in the current search range")
      break
    end
    crf = newCrf
  end

  if searchFailed then
    local failedPaths = { }
    for _, attempt in ipairs(attempts) do
      failedPaths[#failedPaths + 1] = attempt.path
    end
    cleanup_failed_encode(job, false, failedPaths)
    return false
  end

  if not bestSearch or not bestPath then
    message("Encode failed")
    cleanup_failed_encode(job, false)
    return false
  end

  message("Best search result: CRF " .. tostring(bestSearch.crf) .. " -> " .. string.format("%.1f", bestSearch.sizeMB) .. " MB")
  local finalCrf = get_initial_basket_final_crf(searchProfile, bestSearch.crf, bestSearch.sizeMB, targetMB)
  local finalCandidates = { }
  local finalAttempts = math.max(1, math.floor(tonumber(searchProfile.finalAttempts or options.basket_final_attempts) or 2))
  local finalFailed = false
  for i = 1, finalAttempts do
    local finalPath = attempt_path("final", i)
    local presetStage
    if labelPrefix == "AV1" then
      presetStage = i == finalAttempts and "final" or "near"
    end
    local presetLabel = presetStage == "near" and " (preset 6)" or (presetStage == "final" and " (preset 4)" or "")
    local label = labelPrefix .. " final " .. tostring(i) .. "/" .. tostring(finalAttempts) .. presetLabel .. ", CRF " .. tostring(finalCrf)
    local ok, sizeMB = build_and_run(finalPath, "final", label, finalCrf, presetStage)
    if not ok then
      message("Final encode failed (CRF " .. tostring(finalCrf) .. ")")
      os.remove(finalPath)
      finalFailed = true
      break
    end
    local candidate = { crf = finalCrf, sizeMB = sizeMB, path = finalPath }
    finalCandidates[#finalCandidates + 1] = candidate
    message("Final " .. tostring(i) .. "/" .. tostring(finalAttempts) .. ": CRF " .. tostring(finalCrf) .. " -> " .. string.format("%.1f", sizeMB) .. " MB")
    local withinTarget = sizeMB <= targetMB and sizeMB >= targetMB * tolerance
    -- AV1 always gets its slower preset-4 encode, even when the preset-6
    -- validation already falls inside the target window.
    if withinTarget and (labelPrefix ~= "AV1" or i == finalAttempts) then
      break
    end
    if i < finalAttempts then
      if not (labelPrefix == "AV1" and withinTarget) then
        local corrected = get_basket_final_correction(searchProfile, finalCandidates, finalCrf, sizeMB, targetMB)
        if not corrected then
          break
        end
        finalCrf = corrected
      end
    end
  end

  if finalFailed then
    local failedPaths = { bestPath }
    for _, candidate in ipairs(finalCandidates) do
      failedPaths[#failedPaths + 1] = candidate.path
    end
    cleanup_failed_encode(job, false, failedPaths)
    return false
  end

  local selected = nil
  for _, candidate in ipairs(finalCandidates) do
    if candidate.sizeMB <= targetMB and (not selected or candidate.sizeMB > selected.sizeMB) then
      selected = candidate
    end
  end
  -- A faster search encode that already fits is safer than a final-quality
  -- candidate which still overshoots the user's hard video-size limit.
  if not selected and bestSearch.sizeMB <= targetMB then
    selected = bestSearch
  end
  if not selected then
    for _, candidate in ipairs(finalCandidates) do
      if not selected or candidate.sizeMB < selected.sizeMB then
        selected = candidate
      end
    end
  end
  selected = selected or bestSearch

  for _, candidate in ipairs(finalCandidates) do
    if candidate.path ~= selected.path then
      os.remove(candidate.path)
    end
  end
  if bestPath ~= selected.path then
    os.remove(bestPath)
  end
  local renamed, renameError = publish_encode_result(selected.path, job.outputPath)
  if not renamed then
    retain_encode_file(selected.path)
    retain_encode_file(job.audioOutputPath)
    msg.error("Couldn't move target-size result into place: " .. tostring(renameError))
    msg.error("Completed video retained at " .. selected.path)
    if job.audioOutputPath then
      msg.error("Completed audio retained at " .. job.audioOutputPath)
    end
    cleanup_temporary_source(job)
    message("Couldn't publish output; completed video retained at " .. selected.path)
    return false
  end
  local sizeMessage = string.format("%.2f", selected.sizeMB) .. " MB, target " .. tostring(targetMB) .. " MB"
  if selected.sizeMB > targetMB then
    msg.warn("Target could not be met within the quality/search limits: " .. sizeMessage)
    message("Encode finished OVER TARGET (" .. sizeMessage .. ")")
  else
    message("Encode finished (" .. sizeMessage .. ")")
  end
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
  local subInfo = get_subtitle_info(path)
  local useImageOverlay = subInfo and subInfo.mode == "image" and format:getVideoCodec() ~= ""
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
    region = region,
    subInfo = subInfo,
    useImageOverlay = useImageOverlay
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
    if not encode_basket_audio(encodeContext, encodeJob.audioOutputPath) then
      cleanup_temporary_source(encodeJob)
      return
    end
  end
  local ok
  if isBasket and options.target_size_basket_mb > 0 then
    ok = encode_target_size_job(encodeContext, encodeJob, dir, options.target_size_basket_mb, "Basket")
  elseif options.output_format == "mp4" and options.target_size_mp4_mb > 0 and format:getTargetSizeProfile() then
    ok = encode_target_size_job(encodeContext, encodeJob, dir, options.target_size_mp4_mb, "MP4")
  elseif options.output_format == "WebM" and format:getVideoCodec() == "libsvtav1" and options.target_size_av1_mb > 0 then
    ok = encode_target_size_job(encodeContext, encodeJob, dir, options.target_size_av1_mb, "AV1")
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
			return fmt == "mp4" or (fmt == "Basket" and self:getOptionValue("video_codec_basket") == "libx264" and self:getOptionValue("target_size_basket_mb") == 0)
          end)
        },
        {
          "cq_nvenc",
          Option("int", "V-Quality", options.cq_nvenc, menu_choices.cqNvencOpts, function()
			return self:getOptionValue("output_format") == "NVENC" and self:getOptionValue("video_codec_nvenc") ~= "av1_nvenc"
          end)
        },
        {
          "cq_nvenc_av1",
          Option("int", "V-Quality", options.cq_nvenc_av1, menu_choices.cqNvencAv1Opts, function()
			return self:getOptionValue("output_format") == "NVENC" and self:getOptionValue("video_codec_nvenc") == "av1_nvenc"
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
			return not self:getOptionValue("vfr") and (fmt == "mp4" or fmt == "WebM" or fmt == "NVENC" or fmt == "Animated" or fmt == "Basket")
		  end)
        },
        {
          "vfr",
          Option("bool", "Variable Frame Rate", options.vfr, nil, function()
			local fmt = self:getOptionValue("output_format")
			return self:getOptionValue("fps") == -1 and (fmt == "mp4" or fmt == "WebM" or fmt == "NVENC" or fmt == "Animated" or fmt == "Basket")
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

