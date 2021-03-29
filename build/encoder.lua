local mp = require("mp")
local assdraw = require("mp.assdraw")
local msg = require("mp.msg")
local utils = require("mp.utils")
local mpopts = require("mp.options")
local options = {
	keybind = "e",
	-- If empty, saves on the same directory of the playing video.
	-- A starting "~" will be replaced by the home dir.
	-- This field is delimited by double-square-brackets - [[ and ]] - instead of
	-- quotes, because Windows users might run into a issue when using
	-- backslashes as a path separator. Examples of valid inputs for this field
	-- would be: [[]] (the default, empty value), [[C:\Users\John]] (on Windows),
	-- and [[/home/john]] (on Unix-like systems eg. Linux).
	output_directory = [[]],
	run_detached = false,
	-- Template string for the output file
	-- %f/%F - Filename, with or without extension
	-- %T - Media title, if it exists, or filename, with extension (useful for some streams, such as YouTube).
	-- %s/%S %e/%E - Start and end time, with or without milliseconds
	-- %M - "-audio", if audio is enabled, empty otherwise
	-- %R - "-(height)p", where height is the video's height, or scale_height, if it's enabled.
	-- More specifiers are supported, see https://mpv.io/manual/master/#options-screenshot-template
	-- Property expansion is supported (with %{} at top level, ${} when nested), see https://mpv.io/manual/master/#property-expansion
	output_template = "%T-[%S-%E]%M",
	-- Scale video to a certain height, keeping the aspect ratio. -1 disables it.
	scale_height = -1,
	-- Change the FPS of the output video, dropping or duplicating frames as needed. -1 means the FPS will be unchanged from the source.
	fps = -1,
	-- Sets the output format, from a few predefined ones. Currently we have webm-vp8 (libvpx/libvorbis), webm-vp9 (libvpx-vp9/libopus), mp4 (x264/libmp3lame), copy (h264_nvenc/libmp3lame), ogg (libopus)
	output_format = "mp4",
	apply_current_filters = true,
	write_filename_on_metadata = true,
	libvpx_threads = 4,
	crf = 23,
	audio_bitrate = 128000,
	-- Displays the encode progress, requires run_detached to be disabled. "auto" will display progress on non-Windows platforms.
	-- On Windows it shows a cmd popup, but it needs mpv to be listed as PATH to function properly.
	display_progress = "auto",
	font_size = 22,
	margin = 10,
	message_duration = 3
}

mpopts.read_options(options)
local base64_chars='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

-- encoding
function base64_encode(data)
    return ((data:gsub('.', function(x) 
        local r,b='',x:byte()
        for i=8,1,-1 do r=r..(b%2^i-b%2^(i-1)>0 and '1' or '0') end
        return r;
    end)..'0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if (#x < 6) then return '' end
        local c=0
        for i=1,6 do c=c+(x:sub(i,i)=='1' and 2^(6-i) or 0) end
        return base64_chars:sub(c+1,c+1)
    end)..({ '', '==', '=' })[#data%3+1])
end

-- decoding
function base64_decode(data)
    data = string.gsub(data, '[^'..base64_chars..'=]', '')
    return (data:gsub('.', function(x)
        if (x == '=') then return '' end
        local r,f='',(base64_chars:find(x)-1)
        for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
        return r;
    end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
        if (#x ~= 8) then return '' end
        local c=0
        for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
        return string.char(c)
    end))
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
  for _, val in ipairs(b) do
    a[#a + 1] = val
  end
  return a
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
  local info, err = utils.file_info(name)
  if info ~= nil then
    return true
  end
  return false
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
  local hasAudioCodec = videoFormat.audioCodec ~= ""
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
  return tostring(filename) .. "." .. tostring(videoFormat.outputExtension)
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
local is_windows = type(package) == "table" and type(package.config) == "string" and package.config:sub(1, 1) == "\\"
local trim
trim = function(s)
  return s:match("^%s*(.-)%s*$")
end
local get_null_path
get_null_path = function()
  if file_exists("/dev/null") then
    return "/dev/null"
  end
  return "NUL"
end
local run_subprocess
run_subprocess = function(params)
  local res = utils.subprocess(params)
  msg.verbose("Command stdout: ")
  msg.verbose(res.stdout)
  if res.status ~= 0 then
    msg.verbose("Command failed! Reason: ", res.error, " Killed by us? ", res.killed_by_us and "Yes" or "No")
    return false
  end
  return true
end
local shell_escape
shell_escape = function(args)
  local ret = { }
  for i, a in ipairs(args) do
    local s = tostring(a)
    if string.match(s, "[^A-Za-z0-9_/:=-]") then
      if is_windows then
        s = '"' .. string.gsub(s, '"', '"\\""') .. '"'
      else
        s = "'" .. string.gsub(s, "'", "'\\''") .. "'"
      end
    end
    table.insert(ret, s)
  end
  local concat = table.concat(ret, " ")
  if is_windows then
    concat = '"' .. concat .. '"'
  end
  return concat
end
local run_subprocess_popen
run_subprocess_popen = function(command_line)
  local command_line_string = shell_escape(command_line)
  command_line_string = command_line_string .. " 2>&1"
  msg.verbose("run_subprocess_popen: running " .. tostring(command_line_string))
  return io.popen(command_line_string)
end
local calculate_scale_factor
calculate_scale_factor = function()
  local baseResY = 720
  local osd_w, osd_h = mp.get_osd_size()
  return osd_h / baseResY
end
local should_display_progress
should_display_progress = function()
  if options.display_progress == "auto" then
    return not is_windows
  end
  return options.display_progress
end
local reverse
reverse = function(list)
  local _accum_0 = { }
  local _len_0 = 1
  local _max_0 = 1
  for _index_0 = #list, _max_0 < 0 and #list + _max_0 or _max_0, -1 do
    local element = list[_index_0]
    _accum_0[_len_0] = element
    _len_0 = _len_0 + 1
  end
  return _accum_0
end
local get_pass_logfile_path
get_pass_logfile_path = function(encode_out_path)
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
  if keep_aspect then
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
local make_fullscreen_region
make_fullscreen_region = function()
  local r = Region()
  local d = get_video_dimensions()
  local a = VideoPoint()
  local b = VideoPoint()
  local xa, ya
  do
    local _obj_0 = d.top_left
    xa, ya = _obj_0.x, _obj_0.y
  end
  a:set_from_screen(xa, ya)
  local xb, yb
  do
    local _obj_0 = d.bottom_right
    xb, yb = _obj_0.x, _obj_0.y
  end
  b:set_from_screen(xb, yb)
  r:set_from_points(a, b)
  return r
end
local read_double
read_double = function(bytes)
  local sign = 1
  local mantissa = bytes[2] % 2 ^ 4
  for i = 3, 8 do
    mantissa = mantissa * 256 + bytes[i]
  end
  if bytes[1] > 127 then
    sign = -1
  end
  local exponent = (bytes[1] % 128) * 2 ^ 4 + math.floor(bytes[2] / 2 ^ 4)
  if exponent == 0 then
    return 0
  end
  mantissa = (math.ldexp(mantissa, -52) + 1) * sign
  return math.ldexp(mantissa, exponent - 1023)
end
local write_double
write_double = function(num)
  local bytes = {
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0
  }
  if num == 0 then
    return bytes
  end
  local anum = math.abs(num)
  local mantissa, exponent = math.frexp(anum)
  exponent = exponent - 1
  mantissa = mantissa * 2 - 1
  local sign = num ~= anum and 128 or 0
  exponent = exponent + 1023
  bytes[1] = sign + math.floor(exponent / 2 ^ 4)
  mantissa = mantissa * 2 ^ 4
  local currentmantissa = math.floor(mantissa)
  mantissa = mantissa - currentmantissa
  bytes[2] = (exponent % 2 ^ 4) * 2 ^ 4 + currentmantissa
  for i = 3, 8 do
    mantissa = mantissa * 2 ^ 8
    currentmantissa = math.floor(mantissa)
    mantissa = mantissa - currentmantissa
    bytes[i] = currentmantissa
  end
  return bytes
end
local formats = { }
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
    getCodecFlags = function(self)
      local codecs = { }
      if self.videoCodec ~= "" then
        codecs[#codecs + 1] = "--ovc=" .. tostring(self.videoCodec)
      end
      if self.audioCodec ~= "" then
        codecs[#codecs + 1] = "--oac=" .. tostring(self.audioCodec)
      end
      return codecs
    end
  }
  _base_0.__index = _base_0
  _class_0 = setmetatable({
    __init = function(self)
      self.displayName = "Basic"
      self.supportsTwopass = true
      self.videoCodec = ""
      self.audioCodec = ""
      self.outputExtension = ""
      self.acceptsBitrate = true
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
local WebmVP8
do
  local _class_0
  local _parent_0 = Format
  local _base_0 = {
    getPreFilters = function(self)
      local colormatrixFilter = {
        ["bt.709"] = "bt709",
        ["bt.2020"] = "bt2020",
        ["smpte-240m"] = "smpte240m"
      }
      local ret = { }
      local colormatrix = mp.get_property_native("video-params/colormatrix")
      if colormatrixFilter[colormatrix] then
        append(ret, {
          "lavfi-colormatrix=" .. tostring(colormatrixFilter[colormatrix]) .. ":bt601"
        })
      end
      return ret
    end,
    getFlags = function(self)
      return {
        "--ovcopts-add=threads=" .. tostring(options.libvpx_threads)
      }
    end
  }
  _base_0.__index = _base_0
  setmetatable(_base_0, _parent_0.__base)
  _class_0 = setmetatable({
    __init = function(self)
      self.displayName = "VP8"
      self.supportsTwopass = false
      self.videoCodec = "libvpx"
      self.audioCodec = "libvorbis"
      self.outputExtension = "webm"
      self.acceptsBitrate = true
    end,
    __base = _base_0,
    __name = "WebmVP8",
    __parent = _parent_0
  }, {
    __index = function(cls, name)
      local val = rawget(_base_0, name)
      if val == nil then
        local parent = rawget(cls, "__parent")
        if parent then
          return parent[name]
        end
      else
        return val
      end
    end,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  if _parent_0.__inherited then
    _parent_0.__inherited(_parent_0, _class_0)
  end
  WebmVP8 = _class_0
end
formats["webm-vp8"] = WebmVP8()
local WebmVP9
do
  local _class_0
  local _parent_0 = Format
  local _base_0 = {
    getFlags = function(self)
      return {
        "--ovcopts-add=threads=" .. tostring(options.libvpx_threads)
      }
    end
  }
  _base_0.__index = _base_0
  setmetatable(_base_0, _parent_0.__base)
  _class_0 = setmetatable({
    __init = function(self)
      self.displayName = "VP9"
      self.supportsTwopass = true
      self.videoCodec = "libvpx-vp9"
      self.audioCodec = "libopus"
      self.outputExtension = "webm"
      self.acceptsBitrate = true
    end,
    __base = _base_0,
    __name = "WebmVP9",
    __parent = _parent_0
  }, {
    __index = function(cls, name)
      local val = rawget(_base_0, name)
      if val == nil then
        local parent = rawget(cls, "__parent")
        if parent then
          return parent[name]
        end
      else
        return val
      end
    end,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  if _parent_0.__inherited then
    _parent_0.__inherited(_parent_0, _class_0)
  end
  WebmVP9 = _class_0
end
formats["webm-vp9"] = WebmVP9()
local MP4
do
  local _class_0
  local _parent_0 = Format
  local _base_0 = { }
  _base_0.__index = _base_0
  setmetatable(_base_0, _parent_0.__base)
  _class_0 = setmetatable({
    __init = function(self)
      self.displayName = "MP4"
      self.supportsTwopass = false
      self.videoCodec = "libx264"
      self.audioCodec = "aac"
      self.outputExtension = "mp4"
      self.acceptsBitrate = true
    end,
    __base = _base_0,
    __name = "MP4",
    __parent = _parent_0
  }, {
    __index = function(cls, name)
      local val = rawget(_base_0, name)
      if val == nil then
        local parent = rawget(cls, "__parent")
        if parent then
          return parent[name]
        end
      else
        return val
      end
    end,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  if _parent_0.__inherited then
    _parent_0.__inherited(_parent_0, _class_0)
  end
  MP4 = _class_0
end
formats["mp4"] = MP4()
local MP4NVENC
do
  local _class_0
  local _parent_0 = Format
  local _base_0 = { }
  _base_0.__index = _base_0
  setmetatable(_base_0, _parent_0.__base)
  _class_0 = setmetatable({
    __init = function(self)
      self.displayName = "HQ Copy (NVENC)"
      self.supportsTwopass = false
      self.videoCodec = "h264_nvenc"
      self.audioCodec = "aac"
      self.outputExtension = "mp4"
      self.acceptsBitrate = false
    end,
    __base = _base_0,
    __name = "MP4NVENC",
    __parent = _parent_0
  }, {
    __index = function(cls, name)
      local val = rawget(_base_0, name)
      if val == nil then
        local parent = rawget(cls, "__parent")
        if parent then
          return parent[name]
        end
      else
        return val
      end
    end,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  if _parent_0.__inherited then
    _parent_0.__inherited(_parent_0, _class_0)
  end
  MP4NVENC = _class_0
end
formats["mp4-nvenc"] = MP4NVENC()
local ogg
do
  local _class_0
  local _parent_0 = Format
  local _base_0 = { }
  _base_0.__index = _base_0
  setmetatable(_base_0, _parent_0.__base)
  _class_0 = setmetatable({
    __init = function(self)
      self.displayName = "Ogg"
      self.supportsTwopass = false
      self.videoCodec = ""
      self.audioCodec = "libopus"
      self.outputExtension = "ogg"
      self.acceptsBitrate = true
    end,
    __base = _base_0,
    __name = "ogg",
    __parent = _parent_0
  }, {
    __index = function(cls, name)
      local val = rawget(_base_0, name)
      if val == nil then
        local parent = rawget(cls, "__parent")
        if parent then
          return parent[name]
        end
      else
        return val
      end
    end,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  if _parent_0.__inherited then
    _parent_0.__inherited(_parent_0, _class_0)
  end
  ogg = _class_0
end
formats["ogg"] = ogg()
local GIF
do
  local _class_0
  local _parent_0 = Format
  local _base_0 = { }
  _base_0.__index = _base_0
  setmetatable(_base_0, _parent_0.__base)
  _class_0 = setmetatable({
    __init = function(self)
      self.displayName = "GIF"
      self.supportsTwopass = false
      self.videoCodec = "gif"
      self.audioCodec = ""
      self.outputExtension = "gif"
      self.acceptsBitrate = false
    end,
    __base = _base_0,
    __name = "GIF",
    __parent = _parent_0
  }, {
    __index = function(cls, name)
      local val = rawget(_base_0, name)
      if val == nil then
        local parent = rawget(cls, "__parent")
        if parent then
          return parent[name]
        end
      else
        return val
      end
    end,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  if _parent_0.__inherited then
    _parent_0.__inherited(_parent_0, _class_0)
  end
  GIF = _class_0
end
formats["gif"] = GIF()
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
local EncodeWithProgress
do
  local _class_0
  local _parent_0 = Page
  local _base_0 = {
    draw = function(self)
      local progress = 100 * ((self.currentTime - self.startTime) / self.duration)
      local progressText = string.format("%d%%", progress)
      local window_w, window_h = mp.get_osd_size()
      local ass = assdraw.ass_new()
      ass:new_event()
      self:setup_text(ass)
      ass:append("Encoding (" .. tostring(bold(progressText)) .. ")\\N")
      return mp.set_osd_ass(window_w, window_h, ass.text)
    end,
    parseLine = function(self, line)
      local matchTime = string.match(line, "Encode time[-]pos: ([0-9.]+)")
      local matchExit = string.match(line, "Exiting... [(]([%a ]+)[)]")
      if matchTime == nil and matchExit == nil then
        return 
      end
      if matchTime ~= nil and tonumber(matchTime) > self.currentTime then
        self.currentTime = tonumber(matchTime)
      end
      if matchExit ~= nil then
        self.finished = true
        self.finishedReason = matchExit
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
      append(copy_command_line, {
        '--term-status-msg=Encode time-pos: ${=time-pos}\\n'
      })
      self:show()
      local processFd = run_subprocess_popen(copy_command_line)
      for line in processFd:lines() do
        msg.verbose(string.format('%q', line))
        self:parseLine(line)
        self:draw()
      end
      processFd:close()
      self:hide()
      if self.finishedReason == "End of file" then
        return true
      end
      return false
    end
  }
  _base_0.__index = _base_0
  setmetatable(_base_0, _parent_0.__base)
  _class_0 = setmetatable({
    __init = function(self, startTime, endTime)
      self.startTime = startTime
      self.endTime = endTime
      self.duration = endTime - startTime
      self.currentTime = startTime
    end,
    __base = _base_0,
    __name = "EncodeWithProgress",
    __parent = _parent_0
  }, {
    __index = function(cls, name)
      local val = rawget(_base_0, name)
      if val == nil then
        local parent = rawget(cls, "__parent")
        if parent then
          return parent[name]
        end
      else
        return val
      end
    end,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  if _parent_0.__inherited then
    _parent_0.__inherited(_parent_0, _class_0)
  end
  EncodeWithProgress = _class_0
end
local get_active_tracks
get_active_tracks = function()
  local accepted = {
    video = true,
    audio = not mp.get_property_bool("mute"),
    sub = mp.get_property_bool("sub-visibility")
  }
  local active = {
    video = { },
    audio = { },
    sub = { }
  }
  for _, track in ipairs(mp.get_property_native("track-list")) do
    if track["selected"] and accepted[track["type"]] then
      local count = #active[track["type"]]
      active[track["type"]][count + 1] = track
    end
  end
  return active
end
local filter_tracks_supported_by_format
filter_tracks_supported_by_format = function(active_tracks, format)
  local has_video_codec = format.videoCodec ~= ""
  local has_audio_codec = format.audioCodec ~= ""
  local supported = {
    video = has_video_codec and active_tracks["video"] or { },
    audio = has_audio_codec and active_tracks["audio"] or { },
    sub = has_video_codec and active_tracks["sub"] or { }
  }
  return supported
end
local append_track
append_track = function(out, track)
  local external_flag = {
    ["audio"] = "audio-file",
    ["sub"] = "sub-file"
  }
  local internal_flag = {
    ["video"] = "vid",
    ["audio"] = "aid",
    ["sub"] = "sid"
  }
  if track['external'] and string.len(track['external-filename']) <= 2048 then
    return append(out, {
      "--" .. tostring(external_flag[track['type']]) .. "=" .. tostring(track['external-filename'])
    })
  else
    return append(out, {
      "--" .. tostring(internal_flag[track['type']]) .. "=" .. tostring(track['id'])
    })
  end
end
local append_audio_tracks
append_audio_tracks = function(out, tracks)
  local internal_tracks = { }
  for _index_0 = 1, #tracks do
    local track = tracks[_index_0]
    if track['external'] then
      append_track(out, track)
    else
      append(internal_tracks, {
        track
      })
    end
  end
  if #internal_tracks > 1 then
    local filter_string = ""
    for _index_0 = 1, #internal_tracks do
      local track = internal_tracks[_index_0]
      filter_string = filter_string .. "[aid" .. tostring(track['id']) .. "]"
    end
    filter_string = filter_string .. "amix[ao]"
    return append(out, {
      "--lavfi-complex=" .. tostring(filter_string)
    })
  else
    if #internal_tracks == 1 then
      return append_track(out, internal_tracks[1])
    end
  end
end
local get_scale_filters
get_scale_filters = function()
  if options.scale_height > 0 then
    return {
      "lavfi-scale=-2:" .. tostring(options.scale_height)
    }
  end
  return { }
end
local get_fps_filters
get_fps_filters = function()
  if options.fps > 0 then
    return {
      "fps=" .. tostring(options.fps)
    }
  end
  return { }
end
local append_property
append_property = function(out, property_name, option_name)
  option_name = option_name or property_name
  local prop = mp.get_property(property_name)
  if prop and prop ~= "" then
    return append(out, {
      "--" .. tostring(option_name) .. "=" .. tostring(prop)
    })
  end
end
local append_list_options
append_list_options = function(out, property_name, option_prefix)
  option_prefix = option_prefix or property_name
  local prop = mp.get_property_native(property_name)
  if prop then
    for _index_0 = 1, #prop do
      local value = prop[_index_0]
      append(out, {
        "--" .. tostring(option_prefix) .. "-append=" .. tostring(value)
      })
    end
  end
end
local get_playback_options
get_playback_options = function()
  local ret = { }
  append_property(ret, "sub-ass-override")
  append_property(ret, "sub-ass-force-style")
  append_property(ret, "sub-ass-vsfilter-aspect-compat")
  append_property(ret, "sub-auto")
  append_property(ret, "sub-delay")
  append_property(ret, "video-rotate")
  append_property(ret, "ytdl-format")
  return ret
end
local get_speed_flags
get_speed_flags = function()
  local ret = { }
  local speed = mp.get_property_native("speed")
  if speed ~= 1 then
    append(ret, {
      "--vf-add=setpts=PTS/" .. tostring(speed),
      "--af-add=atempo=" .. tostring(speed),
      "--sub-speed=1/" .. tostring(speed)
    })
  end
  return ret
end
local get_metadata_flags
get_metadata_flags = function()
  local title = mp.get_property("filename/no-ext")
  return {
    "--oset-metadata=title=%" .. tostring(string.len(title)) .. "%" .. tostring(title)
  }
end
local apply_current_filters
apply_current_filters = function(filters)
  local vf = mp.get_property_native("vf")
  msg.verbose("apply_current_filters: got " .. tostring(#vf) .. " currently applied.")
  for _index_0 = 1, #vf do
    local _continue_0 = false
    repeat
      local filter = vf[_index_0]
      msg.verbose("apply_current_filters: filter name: " .. tostring(filter['name']))
      if filter["enabled"] == false then
        _continue_0 = true
        break
      end
      local str = filter["name"]
      local params = filter["params"] or { }
      for k, v in pairs(params) do
        str = str .. ":" .. tostring(k) .. "=%" .. tostring(string.len(v)) .. "%" .. tostring(v)
      end
      append(filters, {
        str
      })
      _continue_0 = true
    until true
    if not _continue_0 then
      break
    end
  end
end
local get_video_filters
get_video_filters = function(format, region)
  local filters = { }
  append(filters, format:getPreFilters())
  if options.apply_current_filters then
    apply_current_filters(filters)
  end
  if region and region:is_valid() then
    append(filters, {
      "lavfi-crop=" .. tostring(region.w) .. ":" .. tostring(region.h) .. ":" .. tostring(region.x) .. ":" .. tostring(region.y)
    })
  end
  append(filters, get_scale_filters())
  append(filters, get_fps_filters())
  append(filters, format:getPostFilters())
  return filters
end
local get_video_encode_flags
get_video_encode_flags = function(format, region)
  local flags = { }
  append(flags, get_playback_options())
  local filters = get_video_filters(format, region)
  for _index_0 = 1, #filters do
    local f = filters[_index_0]
    append(flags, {
      "--vf-add=" .. tostring(f)
    })
  end
  append(flags, get_speed_flags())
  return flags
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
      path = utils.join_path(parse_directory('~'), 'cache_dump.ts')
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
local encode
encode = function(region, startTime, endTime)
  local format = formats[options.output_format]
  local originalStartTime = startTime
  local originalEndTime = endTime
  local path, is_temporary, is_stream
  path, is_temporary, is_stream, startTime, endTime = find_path(startTime, endTime)
  if not path then
    message("No file is being played")
    return 
  end
  local command = {
    "mpv",
    path,
    "--start=" .. seconds_to_time_string(startTime, false, true),
    "--end=" .. seconds_to_time_string(endTime, false, true),
    "--loop-file=no",
    "--no-pause"
  }
  append(command, format:getCodecFlags())
  local active_tracks = get_active_tracks()
  local supported_active_tracks = filter_tracks_supported_by_format(active_tracks, format)
  for track_type, tracks in pairs(supported_active_tracks) do
    if track_type == "audio" then
      append_audio_tracks(command, tracks)
    else
      for _index_0 = 1, #tracks do
        local track = tracks[_index_0]
        append_track(command, track)
      end
    end
  end
  for track_type, tracks in pairs(supported_active_tracks) do
    local _continue_0 = false
    repeat
      if #tracks > 0 then
        _continue_0 = true
        break
      end
      local _exp_0 = track_type
      if "video" == _exp_0 then
        append(command, {
          "--vid=no"
        })
      elseif "audio" == _exp_0 then
        append(command, {
          "--aid=no"
        })
      elseif "sub" == _exp_0 then
        append(command, {
          "--sid=no"
        })
      end
      _continue_0 = true
    until true
    if not _continue_0 then
      break
    end
  end
  if format.videoCodec ~= "" then
    append(command, get_video_encode_flags(format, region))
  end
  if format.videoCodec == "libx264" then
  	append(command, {"--vf-add=format=fmt=yuv420p"})
    	append(command, {"--ovcopts-add=preset=medium"})
    	append(command, {"--ovcopts-add=level=4.2"})
	append(command, {"--ofopts-add=movflags=+faststart"})
	append(command, {"--oacopts=b=" .. tostring(options.audio_bitrate)})
  end
  if format.videoCodec == "h264_nvenc" then
   	append(command, {"--vf-add=format=fmt=nv12"})
    	append(command, {"--ovcopts-add=preset=hp"})
	append(command, {"--ovcopts-add=profile=high"})
	append(command, {"--ovcopts-add=g=60"})
	append(command, {"--ovcopts-add=qp=17"})
	append(command, {"--ovcopts-add=qmax=23"})
	append(command, {"--oacopts=b=320000"})
  end
  if format.videoCodec == "libvpx" then
	append(command, {"--ovcopts-add=deadline=good"})
	append(command, {"--ovcopts-add=cpu=used=1"})
	append(command, {"--ovcopts=b=100000000"})
	append(command, {"--oacopts=b=" .. tostring(options.audio_bitrate)})
	
  end
  if format.videoCodec == "libvpx-vp9" then
    	append(command, {"--ovcopts-add=deadline=good"})
	append(command, {"--ovcopts-add=speed=1"})
	append(command, {"--ovcopts-add=row=mt=1"})
	append(command, {"--ovcopts=b=0"})
  end
  if format.audioCodec == "libopus" then
	append(command, {"--oacopts=add=compression=level=10"})
	append(command, {"--oacopts=add=frame=duration=60"})
	append(command, {"--oacopts=add=application=audio"})
	append(command, {"--oacopts=b=" .. tostring(options.audio_bitrate)})

  end
  append(command, format:getFlags())
  if options.write_filename_on_metadata then
    append(command, get_metadata_flags())
  end
    if options.crf >= 0 then
      append(command, {
        "--ovcopts-add=crf=" .. tostring(options.crf)
      })
  end
  local dir = ""
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
  append(command, {
    "--o=" .. tostring(out_path)
  })
  msg.info("Encoding to", out_path)
  msg.verbose("Command line:", table.concat(command, " "))
  if options.run_detached then
    message("Encode started, detached process")
    return utils.subprocess_detached({
      args = command
    })
  else
    local res = false
    if not should_display_progress() then
      message("Encode started")
      res = run_subprocess({
        args = command,
        cancellable = false
      })
    else
--	mp.command('no-osd set ontop yes')
      local ewp = EncodeWithProgress(startTime, endTime)
      res = ewp:startEncode(command)
--	mp.command('no-osd set ontop no')
    end
    if res then
      message("Encode finished")
    else
      message("Encode failed")
    end
    os.remove(get_pass_logfile_path(out_path))
    if is_temporary then
      return os.remove(path)
    end
  end
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
      if self.visible then
        return self:draw()
      end
    end,
    setPointA = function(self)
      local posX, posY = mp.get_mouse_pos()
      self.pointA:set_from_screen(posX, posY)
      if self.visible then
        return self:draw()
      end
    end,
    setPointB = function(self)
      local posX, posY = mp.get_mouse_pos()
      self.pointB:set_from_screen(posX, posY)
      if self.visible then
        return self:draw()
      end
    end,
    cancel = function(self)
      self:hide()
      return self.callback(false, nil)
    end,
    finish = function(self)
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
      ass:append(tostring(bold('Crop:')) .. "\\N\\N")
      ass:append(tostring(bold('1:')) .. " Point A (" .. tostring(self.pointA.x) .. ", " .. tostring(self.pointA.y) .. ")\\N")
      ass:append(tostring(bold('2:')) .. " Point B (" .. tostring(self.pointB.x) .. ", " .. tostring(self.pointB.y) .. ")\\N")
      ass:append(tostring(bold('r:')) .. " Reset\\N\\N")
      local width, height = math.abs(self.pointA.x - self.pointB.x), math.abs(self.pointA.y - self.pointB.y)
      ass:append(tostring(bold('ENTER:')) .. " Confirm (" .. tostring(width) .. "x" .. tostring(height) .. ")\\N")
	  ass:append(tostring(bold('ESC:')) .. " Cancel\\N")
	  return mp.set_osd_ass(window.w, window.h, ass.text)
    end
  }
  _base_0.__index = _base_0
  setmetatable(_base_0, _parent_0.__base)
  _class_0 = setmetatable({
    __init = function(self, callback, region)
      self.pointA = VideoPoint()
      self.pointB = VideoPoint()
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
  }, {
    __index = function(cls, name)
      local val = rawget(_base_0, name)
      if val == nil then
        local parent = rawget(cls, "__parent")
        if parent then
          return parent[name]
        end
      else
        return val
      end
    end,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  if _parent_0.__inherited then
    _parent_0.__inherited(_parent_0, _class_0)
  end
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
        return self.value and "Yes" or "No"
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
    end
  }
  _base_0.__index = _base_0
  _class_0 = setmetatable({
    __init = function(self, optType, displayText, value, opts)
      self.optType = optType
      self.displayText = displayText
      self.opts = opts
      self.value = 1
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
local EncodeOptionsPage
do
  local _class_0
  local _parent_0 = Page
  local _base_0 = {
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
      self.currentOption = math.max(1, self.currentOption - 1)
      return self:draw()
    end,
    nextOpt = function(self)
      self.currentOption = math.min(#self.options, self.currentOption + 1)
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
        opt:draw(ass, self.currentOption == i)
      end
      ass:append("\\N▲ / ▼: Navigate\\N")
      ass:append(tostring(bold('ENTER:')) .. " Confirm\\N")
      ass:append(tostring(bold('ESC:')) .. " Cancel\\N")
      return mp.set_osd_ass(window_w, window_h, ass.text)
    end
  }
  _base_0.__index = _base_0
  setmetatable(_base_0, _parent_0.__base)
  _class_0 = setmetatable({
    __init = function(self, callback)
      self.callback = callback
      self.currentOption = 1
      local scaleHeightOpts = {
        possibleValues = {
          {
            -1,
            "Source"
          },
          {
            240,
			"240p"
          },
          {
            360,
			"360p"
          },
          {
            480,
			"480p"
          },
		  {
            540,
			"540p"
          },
          {
            720,
			"720p"
          },
          {
            900,
			"900p"
          },
          {
            1080,
			"1080p"
          },
          {
            1440,
			"1440p"
          },
          {
            1800,
			"1800p"
          },
          {
            2160,
			"2160p"
          }
        }
      }
      local crfOpts = {
        step = 1,
        min = 10,
		max = 51,
        altDisplayNames = {
		[10] = "10 (Nightmare!)",
		[17] = "17 (Ultra High)",
		[23] = "23 (Very High)",
		[26] = "26 (High)",
		[30] = "30 (Medium)",
		[37] = "37 (Low)",
		[45] = "45 (Very Low)",
		[51] = "51 (Ultra Low)"
        }
      }
	  local audioOpts = {
        possibleValues = {
          {
			32000,
			"32k (!WARNING!)"
          },
          {
			64000,
			"64k (Ultra Low)"
          },
          {
			96000,
			"96k (Very Low("
          },
          {
			128000,
			"128k (Low)"
          },
          {
			160000,
			"160k (Medium)"
          },
          {
			192000, 
			"192k (High)",
          },
          {
			256000, 
			"256k (Very High)"
          },
          {
			320000,
			"320k (Ultra High)"
          }
        }
      }
      local fpsOpts = {
        possibleValues = {
          {
            -1,
            "Source"
          },
          {
            15
          },
	  {
            20
          },
          {
            30
          },
          {
            48
          },
          {
            60
          }
        }
      }
      local formatIds = {
        "mp4",
        "webm-vp8",
--	"webm-vp9",
        "ogg",
	"mp4-nvenc"
      }
      local formatOpts = {
        possibleValues = (function()
          local _accum_0 = { }
          local _len_0 = 1
          for _index_0 = 1, #formatIds do
            local fId = formatIds[_index_0]
            _accum_0[_len_0] = {
              fId,
              formats[fId].displayName
            }
            _len_0 = _len_0 + 1
          end
          return _accum_0
        end)()
      }
      self.options = {
        {
          "output_format",
          Option("list", "Output Format", options.output_format, formatOpts)
        },
        {
          "apply_current_filters",
         Option("bool", "Apply Filters", options.apply_current_filters)
        },
	{
          "write_filename_on_metadata",
          Option("bool", "Write Metadata", options.write_filename_on_metadata)
        },
        {
          "crf",
          Option("int", "V-Quality", options.crf, crfOpts)
        },
	{
          "audio_bitrate",
	  Option("list", "A-Quality", options.audio_bitrate, audioOpts)
	},
	{
          "scale_height",
          Option("list", "Scale Height", options.scale_height, scaleHeightOpts)
        },
        {
          "fps",
          Option("list", "Framerate", options.fps, fpsOpts)
        }
      }
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
  }, {
    __index = function(cls, name)
      local val = rawget(_base_0, name)
      if val == nil then
        local parent = rawget(cls, "__parent")
        if parent then
          return parent[name]
        end
      else
        return val
      end
    end,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  if _parent_0.__inherited then
    _parent_0.__inherited(_parent_0, _class_0)
  end
  EncodeOptionsPage = _class_0
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
--      ass:append(tostring(bold('p:')) .. " Preview\\N")
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
      return encode(self.region, self.startTime, self.endTime)
    end
  }
  _base_0.__index = _base_0
  setmetatable(_base_0, _parent_0.__base)
  _class_0 = setmetatable({
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
--        ["p"] = (function()
--          local _base_1 = self
--          local _fn_0 = _base_1.preview
--          return function(...)
--            return _fn_0(_base_1, ...)
--          end
--        end)(),
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
  }, {
    __index = function(cls, name)
      local val = rawget(_base_0, name)
      if val == nil then
        local parent = rawget(cls, "__parent")
        if parent then
          return parent[name]
        end
      else
        return val
      end
    end,
    __call = function(cls, ...)
      local _self_0 = setmetatable({}, _base_0)
      cls.__init(_self_0, ...)
      return _self_0
    end
  })
  _base_0.__class = _class_0
  if _parent_0.__inherited then
    _parent_0.__inherited(_parent_0, _class_0)
  end
  MainPage = _class_0
end
monitor_dimensions()
local mainPage = MainPage()
mp.add_key_binding(options.keybind, "display-encoder", (function()
  local _base_0 = mainPage
  local _fn_0 = _base_0.show
  return function(...)
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
