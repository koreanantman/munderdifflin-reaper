-- @description Shredder
-- @author Byungkyu Lee
-- @version 2.0
-- @changelog Size and lettering follow the Munder Difflin card
-- @about Grinds selected audio items into randomized, automated fragments.
--   Drag a value up/down to change it (Shift = fine), mouse wheel works too,
--   double-click any value to type it. Enter = shred, Shift+Enter / Shift+click = re-roll.

local r = reaper
local SEC = "BK_Shredder"
local W, H = 300, 508
local FONT_UP = 1     -- +1 pt on every text size
local UI_SCALE = tonumber(reaper.GetExtState("BK_Office", "ui_scale")) or 1.265  -- set on the Munder Difflin card

---------------------------------------------------------------- settings
local P = { count = 24, min = 60, max = 450, gap = 120, rev = 25, strength = 4.0,
            pitch = true, speed = true, gain = true, pan = false }
local LIM = { count = {1, 512}, min = {5, 10000}, max = {5, 20000},
              gap = {0, 5000}, rev = {0, 100}, strength = {1, 10} }

local status, statusT = "", 0
local lastTrack = nil

local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end
local function rnd() return math.random() * 2 - 1 end
local function say(s) status, statusT = s, r.time_precise() end
local function fmtS(v) local s = string.format("%.3f", v); return (s:gsub("0$", "")) end

local function setP(k, v, fine)
  v = clamp(v, LIM[k][1], LIM[k][2])
  if k == "strength" then
    local q = fine and 1000 or 100
    v = math.floor(v * q + 0.5) / q
  else
    v = math.floor(v + 0.5)
  end
  P[k] = v
  if k == "min" and P.max < v then P.max = v end
  if k == "max" and P.min > v then P.min = v end
end

local function load()
  for k, v in pairs(P) do
    local s = r.GetExtState(SEC, k)
    if s ~= "" then
      if type(v) == "boolean" then P[k] = (s == "1") else P[k] = tonumber(s) or v end
    end
  end
end

local function save()
  for k, v in pairs(P) do
    if type(v) == "boolean" then v = v and "1" or "0" end
    r.SetExtState(SEC, k, tostring(v), true)
  end
end

---------------------------------------------------------------- engine
local function collect()
  local list, total = {}, 0
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    local tk = r.GetActiveTake(it)
    if tk and not r.TakeIsMIDI(tk) then
      local src = r.GetMediaItemTake_Source(tk)
      local parent = r.GetMediaSourceParent(src)
      if parent then src = parent end
      local fn = r.GetMediaSourceFileName(src)
      if fn and fn ~= "" then
        local len = r.GetMediaItemInfo_Value(it, "D_LENGTH")
        list[#list + 1] = {
          item = it, take = tk, file = fn, len = len,
          offs = r.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS"),
          rate = r.GetMediaItemTakeInfo_Value(tk, "D_PLAYRATE"),
          srclen = (r.GetMediaSourceLength(src)),
          name = (fn:match("([^/\\]+)$") or "src"):gsub("%.%w+$", ""),
        }
        total = total + len
      end
    end
  end
  return list, total
end

local function pick(srcs, total)
  local x = math.random() * total
  for _, s in ipairs(srcs) do x = x - s.len; if x <= 0 then return s end end
  return srcs[#srcs]
end

-- peak of a take region (item time), read at low rate: only used to dodge silence
local function peak(acc, t, len)
  local sr = math.min(4000, 16000 / math.max(len, 0.001))
  local n = math.max(16, math.floor(len * sr))
  local buf = r.new_array(n)
  r.GetAudioAccessorSamples(acc, sr, 1, r.GetAudioAccessorStartTime(acc) + t, n, buf)
  local pk = 0
  for i = 1, n do local v = math.abs(buf[i]); if v > pk then pk = v end end
  return pk
end

-- full-rate peak of a finished fragment (before gain automation)
local CEIL_DB = -0.3
local function fragPeak(tk, len)
  local acc = r.CreateTakeAudioAccessor(tk)
  local src = r.GetMediaItemTake_Source(tk)
  local sr = r.GetMediaSourceSampleRate(src); if not sr or sr <= 0 then sr = 48000 end
  local ch = clamp(r.GetMediaSourceNumChannels(src) or 1, 1, 8)
  local block = 4096
  local buf = r.new_array(block * ch)
  local total, pos, pk = math.floor(len * sr), 0, 0
  while pos < total do
    local n = math.min(block, total - pos)
    buf.clear()
    r.GetAudioAccessorSamples(acc, sr, ch, r.GetAudioAccessorStartTime(acc) + pos / sr, n, buf)
    for i = 1, n * ch do local v = math.abs(buf[i]); if v > pk then pk = v end end
    pos = pos + n
  end
  r.DestroyAudioAccessor(acc)
  return pk
end

-- dB of gain this fragment can take before crossing the ceiling
local function headroom(pk)
  if pk <= 1e-6 then return 0 end
  return CEIL_DB - 20 * math.log(pk, 10)
end

-- varispeed via stretch markers: random rate per segment + random slopes
local function speedPlan(L, depth)
  local m = clamp(math.floor(L / 0.12) + 1, 2, 6)
  local base = rnd() * depth
  local w, wsum = {}, 0
  for j = 1, m do w[j] = 0.6 + math.random() * 0.8; wsum = wsum + w[j] end
  local segs, total = {}, 0
  for j = 1, m do
    local sl = L * w[j] / wsum
    local rate = 2 ^ (base + rnd() * 0.9 * depth)
    segs[j] = { src = sl, dur = sl / rate }
    total = total + sl / rate
  end
  return segs, total
end

local function applyMarkers(tk, segs, depth)
  local i0 = r.SetTakeStretchMarker(tk, -1, 0)
  if i0 < 0 then return end
  local _, _, sp = r.GetTakeStretchMarker(tk, i0)
  local p = 0
  for _, sg in ipairs(segs) do
    p, sp = p + sg.dur, sp + sg.src
    r.SetTakeStretchMarker(tk, -1, p, sp)
  end
  for j = 0, r.GetTakeNumStretchMarkers(tk) - 2 do
    r.SetTakeStretchMarkerSlope(tk, j, rnd() * 0.5 * depth)
  end
end

local function automate(env, len, kind, depth, ceil)
  if not env then return end
  r.DeleteEnvelopePointRange(env, -1, len + 1)
  local n = clamp(math.floor(len / 0.15) + 2, 2, 8)
  local mode = r.GetEnvelopeScalingMode(env)
  local center = rnd()
  for i = 0, n - 1 do
    local t = len * i / (n - 1)
    if i > 0 and i < n - 1 then t = t + rnd() * 0.35 * len / (n - 1) end
    local x = clamp(center * 0.5 + rnd() * 0.5, -1, 1)
    local v
    if kind == "Volume" then
      v = r.ScaleToEnvelopeMode(mode, 10 ^ (math.min(x * 12 * depth, ceil) / 20))
    elseif kind == "Pan" then
      v = x * depth
    else -- Pitch, semitones
      v = x * 3 * depth
    end
    r.InsertEnvelopePoint(env, t, v, 2, 0, false, true)
  end
  r.Envelope_SortPoints(env)
end

local function shred(replace)
  local srcs, total = collect()
  if #srcs == 0 then return say("select audio item(s) first") end
  local lo, hi = P.min / 1000, P.max / 1000
  local depth = (P.strength / 10) ^ 1.3

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  if replace and lastTrack and r.ValidatePtr2(0, lastTrack, "MediaTrack*") then
    local safe = true
    for _, s in ipairs(srcs) do
      if r.GetMediaItem_Track(s.item) == lastTrack then safe = false end
    end
    if safe then r.DeleteTrack(lastTrack) end
  end

  local tr0 = r.GetMediaItem_Track(srcs[1].item)
  local tidx = math.floor(r.GetMediaTrackInfo_Value(tr0, "IP_TRACKNUMBER"))
  local _, base = r.GetSetMediaTrackInfo_String(tr0, "P_NAME", "", false)
  if base == "" then base = "Track " .. tidx end
  local pat = "^" .. base:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0") .. "_SHRED (%d+)$"
  local num = 0
  for i = 0, r.CountTracks(0) - 1 do
    local _, nm = r.GetSetMediaTrackInfo_String(r.GetTrack(0, i), "P_NAME", "", false)
    local d = tonumber(nm:match(pat))
    if d and d > num then num = d end
  end
  r.InsertTrackAtIndex(tidx, true)
  local tr = r.GetTrack(0, tidx)
  r.GetSetMediaTrackInfo_String(tr, "P_NAME", ("%s_SHRED %02d"):format(base, num + 1), true)
  lastTrack = tr

  local pos = math.huge
  for _, s in ipairs(srcs) do pos = math.min(pos, r.GetMediaItemInfo_Value(s.item, "D_POSITION")) end

  r.SelectAllMediaItems(0, false)
  local accs, made = {}, {}

  for n = 1, P.count do
    local s = pick(srcs, total)
    local L = lo + math.random() * (hi - lo)                -- source seconds
    L = math.min(L, s.len * s.rate)
    local span = L / s.rate                                 -- item seconds

    accs[s] = accs[s] or r.CreateTakeAudioAccessor(s.take)
    local best, bestpk = 0, -1
    for _ = 1, 12 do
      local p = math.random() * math.max(0, s.len - span)
      local pk = peak(accs[s], p, span)
      if pk > bestpk then best, bestpk = p, pk end
      if pk > 0.004 then break end                          -- ~ -48 dBFS
    end
    local srcStart = s.offs + best * s.rate
    if s.srclen and s.srclen > 0 then srcStart = srcStart % s.srclen end

    local it = r.AddMediaItemToTrack(tr)
    local tk = r.AddTakeToMediaItem(it)
    r.SetMediaItemTake_Source(tk, r.PCM_Source_CreateFromFile(s.file))
    r.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", srcStart)
    r.SetMediaItemTakeInfo_Value(tk, "B_PPITCH", 0)
    r.GetSetMediaItemTakeInfo_String(tk, "P_NAME", ("%s_shr%02d"):format(s.name, n), true)
    r.SetMediaItemInfo_Value(it, "D_POSITION", pos)

    r.SetMediaItemInfo_Value(it, "D_LENGTH", L)
    local rev = math.random() * 100 < P.rev
    if rev then
      r.SelectAllMediaItems(0, false)
      r.SetMediaItemSelected(it, true)
      r.Main_OnCommand(41051, 0) -- Item properties: Toggle take reverse
      r.GetSetMediaItemTakeInfo_String(tk, "P_NAME", ("%s_shr%02d_rev"):format(s.name, n), true)
    end

    local len = L
    if P.speed then
      local segs, tot = speedPlan(L, depth)
      len = tot
      r.SetMediaItemInfo_Value(it, "D_LENGTH", len)
      applyMarkers(tk, segs, depth)
    else
      r.SetMediaItemInfo_Value(it, "D_LENGTH", len)
    end

    if P.pitch then
      r.SetMediaItemTakeInfo_Value(tk, "D_PITCH", math.floor(rnd() * 12 * depth * 100 + 0.5) / 100)
    end

    local f = math.min(0.006, len * 0.25)
    r.SetMediaItemInfo_Value(it, "D_FADEINLEN", f)
    r.SetMediaItemInfo_Value(it, "D_FADEOUTLEN", f)
    local hr = headroom(fragPeak(tk, len))
    r.SetMediaItemTakeInfo_Value(tk, "D_VOL", 1)
    if not P.gain and hr < 0 then
      r.SetMediaItemTakeInfo_Value(tk, "D_VOL", 10 ^ (hr / 20))  -- static trim only if it would clip
    end

    made[#made + 1] = { it = it, tk = tk, len = len, ceil = hr }
    pos = pos + len + P.gap / 1000
  end

  for _, a in pairs(accs) do r.DestroyAudioAccessor(a) end
  r.SelectAllMediaItems(0, false)
  for _, m in ipairs(made) do r.SetMediaItemSelected(m.it, true) end

  -- take envelopes are created by toggling them on the (selected) new items
  if P.gain  then r.Main_OnCommand(40693, 0) end -- Take: Toggle take volume envelope
  if P.pan   then r.Main_OnCommand(40694, 0) end -- Take: Toggle take pan envelope
  if P.pitch then r.Main_OnCommand(41612, 0) end -- Take: Toggle take pitch envelope
  for _, m in ipairs(made) do
    if P.gain  then automate(r.GetTakeEnvelopeByName(m.tk, "Volume"), m.len, "Volume", depth, m.ceil) end
    if P.pan   then automate(r.GetTakeEnvelopeByName(m.tk, "Pan"),    m.len, "Pan",    depth) end
    if P.pitch then automate(r.GetTakeEnvelopeByName(m.tk, "Pitch"),  m.len, "Pitch",  depth) end
  end

  r.Main_OnCommand(40047, 0) -- build missing peaks
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("Shredder: " .. #made .. " fragments", -1)
  say(("%d fragments  /  str %s%s"):format(#made, fmtS(P.strength), replace and "  /  re-rolled" or ""))
end

---------------------------------------------------------------- ui (memo)
local OS = r.GetOS()
local FONT = (reaper.GetExtState("BK_Office", "lettering") == "clean")
  and (OS:match("Win") and "Consolas" or ((OS:match("OSX") or OS:match("mac")) and "Menlo" or "DejaVu Sans Mono"))
  or ((OS:match("Win") or OS:match("OSX") or OS:match("mac")) and "Courier New" or "Liberation Mono")
local S = 1
local PAPER = {0.965, 0.953, 0.918}
local INK   = {0.13, 0.13, 0.15}
local NAVY  = {0.13, 0.22, 0.46}   -- ballpoint
local RED   = {0.76, 0.14, 0.12}   -- rubber stamp
local DIM   = {0.50, 0.49, 0.46}
local LINE  = {0.78, 0.77, 0.72}
-- After Hours (dark) theme: shared by every tool through ExtState BK_Office/after_hours
local THEMEX = {
  knob = { INK[1], INK[2], INK[3] }, kdot = { PAPER[1], PAPER[2], PAPER[3] },
  noteInk = {0.13, 0.13, 0.15}, noteRed = {0.76, 0.14, 0.12},
  night = {
    PAPER = {0.105, 0.115, 0.150}, INK = {0.90, 0.88, 0.82}, NAVY = {0.58, 0.70, 0.98},
    RED = {0.96, 0.42, 0.36}, DIM = {0.56, 0.58, 0.64}, LINE = {0.27, 0.29, 0.35},
    KNOB = {0.21, 0.22, 0.28}, KDOT = {0.90, 0.88, 0.82},
  },
  day = {}, dark = nil, t = 0,
}
THEMEX.live = { PAPER = PAPER, INK = INK, NAVY = NAVY, RED = RED, DIM = DIM, LINE = LINE,
                KNOB = THEMEX.knob, KDOT = THEMEX.kdot }
for k, t in pairs(THEMEX.live) do THEMEX.day[k] = { t[1], t[2], t[3] } end
local function applyTheme(force)
  local now = reaper.time_precise()
  if not force and now - THEMEX.t < 0.5 then return end
  THEMEX.t = now
  local d = false   -- After Hours retired
  if d == THEMEX.dark then return end
  THEMEX.dark = d
  local src = d and THEMEX.night or THEMEX.day
  for k, t in pairs(THEMEX.live) do local v = src[k]; t[1], t[2], t[3] = v[1], v[2], v[3] end
  if TOOL_THEME then TOOL_THEME(d) end
end

local function sc(v) return math.floor(v * S + 0.5) end
local function col(c, a) gfx.set(c[1], c[2], c[3], a or 1) end
local function font(sz, bold) gfx.setfont(1, FONT, sc(sz + FONT_UP), bold and string.byte("b") or 0) end
local function frameBorder(ink, line)
  local t = math.max(2, math.floor(2 * S + 0.5))
  col(ink)
  gfx.rect(0, 0, gfx.w, t, 1); gfx.rect(0, gfx.h - t, gfx.w, t, 1)
  gfx.rect(0, 0, t, gfx.h, 1); gfx.rect(gfx.w - t, 0, t, gfx.h, 1)
  local i = math.floor(6 * S + 0.5)
  col(line); gfx.rect(i, i, gfx.w - 2 * i, gfx.h - 2 * i, 0)
end

local function hline(x, y, w, t, c) col(c); gfx.rect(sc(x), sc(y), sc(w), math.max(1, sc(t or 1)), 1) end

local function text(s, x, y, sz, c, align, track, bold)
  font(sz, bold); col(c)
  track = sc(track or 0)
  local w = 0
  if track == 0 then w = gfx.measurestr(s)
  else for ch in s:gmatch(".") do w = w + gfx.measurestr(ch) + track end; w = w - track end
  local px = sc(x)
  if align == "r" then px = px - w elseif align == "c" then px = px - w / 2 end
  gfx.y = sc(y)
  if track == 0 then gfx.x = px; gfx.drawstr(s)
  else for ch in s:gmatch(".") do gfx.x = px; gfx.drawstr(ch); px = px + gfx.measurestr(ch) + track end end
  return w / S
end

local M = { x = 0, y = 0, down = false, prev = false }
local active, dragY0, dragV0
local lastKey, lastT = nil, 0
local editReq, doShred = nil, nil
local info, infoT = "", 0

local helpOpen = false

local STAFF = {
  "Michael Scott", "Dwight Schrute", "Jim Halpert", "Pam Beesly", "Ryan Howard",
  "Andy Bernard", "Angela Martin", "Kevin Malone", "Oscar Martinez", "Stanley Hudson",
  "Phyllis Vance", "Meredith Palmer", "Creed Bratton", "Kelly Kapoor", "Toby Flenderson",
  "Darryl Philbin", "Erin Hannon",
}
local sender = ""
local function newSender()
  local prev = sender
  repeat sender = STAFF[math.random(#STAFF)] until sender ~= prev
end

local function interact(key, x, y, w, h)
  if helpOpen and key ~= "help" then return false, false end
  local hov = M.x >= sc(x) and M.x < sc(x + w) and M.y >= sc(y) and M.y < sc(y + h)
  if hov and M.pressed then
    local now = r.time_precise()
    if lastKey == key and now - lastT < 0.32 then editReq, lastKey = key, nil
    else lastKey, lastT = key, now end
    active, dragY0, dragV0 = key, M.y, P[key]
  end
  return hov, active == key
end

-- form row:  LABEL: ............ value unit
local function row(key, label, unit, y, step, wstep)
  local x, w = 24, W - 48
  local hov, act = interact(key, x, y, w, 24)
  if act and M.down and M.y ~= dragY0 then
    setP(key, dragV0 + (dragY0 - M.y) / S * step * (M.shift and 0.2 or 1))
  end
  if hov and M.wheel ~= 0 then setP(key, P[key] + (M.wheel > 0 and 1 or -1) * wstep) end
  local lw = text(label .. ":", x, y + 5, 12, INK, nil, 1, true)
  local vs = tostring(math.floor(P[key])) .. (unit and (" " .. unit) or "")
  local vw = text(vs, x + w, y + 4, 14, (hov or act) and RED or NAVY, "r")
  col(LINE)
  for dx = x + lw + 8, x + w - vw - 8, 5 do gfx.rect(sc(dx), sc(y + 15), math.max(1, sc(1)), math.max(1, sc(1)), 1) end
  hline(x, y + 23, w, 1, LINE)
end

local function knob(cx, cy, R)
  local hov, act = interact("strength", cx - R - 14, cy - R - 14, (R + 14) * 2, (R + 14) * 2)
  if act and M.down and M.y ~= dragY0 then
    setP("strength", dragV0 + (dragY0 - M.y) / S * (M.shift and 0.005 or 0.04), M.shift)
  end
  if hov and M.wheel ~= 0 then
    setP("strength", P.strength + (M.wheel > 0 and 1 or -1) * (M.shift and 0.01 or 0.1))
  end
  local t = (P.strength - 1) / 9
  local a0, a1 = math.rad(-135), math.rad(135)
  local a = a0 + t * (a1 - a0)
  local X, Y, RR = sc(cx), sc(cy), sc(R)
  for i = 0, 9 do
    local ta = a0 + i / 9 * (a1 - a0)
    local r1, r2 = RR + sc(7), RR + sc((i == 0 or i == 9) and 14 or 11)
    col(i / 9 <= t + 1e-6 and NAVY or LINE)
    gfx.line(X + math.sin(ta) * r1, Y - math.cos(ta) * r1, X + math.sin(ta) * r2, Y - math.cos(ta) * r2, 1)
  end
  col(LINE); gfx.arc(X, Y, RR + sc(3), a0, a1, 1)
  col(NAVY); for k = 0, sc(2), 0.5 do gfx.arc(X, Y, RR + sc(2) + k, a0, a, 1) end
  col(THEMEX.knob, (hov or act) and 0.85 or 1); gfx.circle(X, Y, RR - sc(3), 1, 1)
  local dr = (RR - sc(3)) * 0.7
  col(THEMEX.kdot); gfx.circle(X + math.sin(a) * dr, Y - math.cos(a) * dr, sc(3), 1, 1)
  text("1", cx - R - 12, cy + R + 6, 10, DIM, "c")
  text("10", cx + R + 12, cy + R + 6, 10, DIM, "c")
  text(fmtS(P.strength), cx, cy + R + 2, 16, act and RED or NAVY, "c", 0, true)
end

-- [x] LABEL
local function check(key, label, x, y)
  local hov = interact(key, x, y - 2, 64, 18)
  if hov and M.pressed then P[key] = not P[key] end
  text("[ ]", x, y, 12, INK)
  if P[key] then text("x", x + 7.5, y, 12, NAVY, nil, 0, true) end
  text(label, x + 24, y, 11, P[key] and INK or DIM, nil, 1)
end

-- rubber stamp button
local function stamp(x, y, w, h)
  local hov, act = interact("shred", x, y, w, h)
  local pressed = act and M.down
  if pressed then col(RED); gfx.rect(sc(x), sc(y), sc(w), sc(h), 1) end
  local c = pressed and PAPER or RED
  local a = hov and 1 or 0.88
  col(c, a)
  for k = 0, 1 do gfx.rect(sc(x) + k, sc(y) + k, sc(w) - 2 * k, sc(h) - 2 * k, 0) end
  gfx.rect(sc(x + 4), sc(y + 4), sc(w - 8), sc(h - 8), 0)
  font(16, true); col(c, a)
  local label = "SHRED"
  local tw = 0; for ch in label:gmatch(".") do tw = tw + gfx.measurestr(ch) + sc(7) end; tw = tw - sc(7)
  local px = sc(x + w / 2) - tw / 2
  gfx.y = sc(y + h / 2 - 9)
  for ch in label:gmatch(".") do gfx.x = px; gfx.drawstr(ch); px = px + gfx.measurestr(ch) + sc(7) end
  if act and M.released and hov then doShred = M.shift and "replace" or "new" end
end

-- attachment: folded / unfolded sticky note
local NOTE = {0.99, 0.93, 0.58}
local HELP = {
  { "ATTACHMENT 1 OF 1", true },
  { "Re: How to use the Shredder" },
  { "" },
  { "Select audio item(s)." },
  { "Press SHRED. Fragments appear" },
  { "on a new track. That's the job." },
  { "" },
  { "DRAG value ......... up/down" },
  { "SHIFT+DRAG ......... fine" },
  { "WHEEL .............. nudge" },
  { "DOUBLE-CLICK ....... type it" },
  { "ENTER .............. shred" },
  { "SHIFT+SHRED ........ redo" },
  { "ESC ................ go home" },
  { "" },
  { "STRENGTH = how much chaos." },
  { "1 is a memo. 10 is a party" },
  { "planning committee meeting." },
  { "" },
  { "Nothing leaves above 0 dB." },
  { "Legal was very clear." },
}

local function attachment()
  local label = helpOpen and "ATTACHMENT (1) v" or "ATTACHMENT (1) >"
  font(10)
  local lw = gfx.measurestr(label) / S
  local hov = interact("help", W - 24 - lw, 86, lw, 16)
  if hov and M.pressed then helpOpen = not helpOpen; active = nil end
  text(label, W - 24, 89, 10, (hov or helpOpen) and RED or DIM, "r")
end

local function note()
  if not helpOpen then return end
  local LH = 14 + FONT_UP
  local x, y, w, h = 30, 118, W - 60, #HELP * LH + 30
  col(INK, 0.12); gfx.rect(sc(x + 3), sc(y + 4), sc(w), sc(h), 1)   -- shadow
  col(NOTE); gfx.rect(sc(x), sc(y), sc(w), sc(h), 1)
  col(INK, 0.08); gfx.rect(sc(x), sc(y), sc(w), sc(18), 1)           -- tape strip
  local ly = y + 28
  for _, ln in ipairs(HELP) do
    if ln[1] ~= "" then text(ln[1], x + 14, ly, 11, ln[2] and THEMEX.noteRed or THEMEX.noteInk, nil, 0, ln[2]) end
    ly = ly + LH
  end
  -- click anywhere on the note to fold it back
  local hov = M.x >= sc(x) and M.x < sc(x + w) and M.y >= sc(y) and M.y < sc(y + h)
  if hov and M.pressed and active ~= "help" then helpOpen = false end
end

local NAMES = { count = "Count", min = "Min length (ms)", max = "Max length (ms)",
                gap = "Gap (ms)", rev = "Reverse chance (%)", strength = "Strength (1-10)" }

local function edit(k)
  local cur = k == "strength" and fmtS(P[k]) or tostring(math.floor(P[k]))
  local ok, s = r.GetUserInputs("Shredder", 1, NAMES[k] .. ",extrawidth=60", cur)
  if ok then local v = tonumber(s); if v then setP(k, v, true) end end
  M.prev, active = false, nil
end

local function frame()
  col(PAPER); gfx.rect(0, 0, gfx.w, gfx.h, 1)
  frameBorder(INK, LINE)

  text("INTEROFFICE MEMO", 24, 20, 13, INK, nil, 3, true)
  text(os.date("%m/%d/%y"), W - 24, 21, 11, DIM, "r")
  hline(24, 42, W - 48, 2, INK)

  text("FROM:", 24, 52, 11, DIM, nil, 1)
  if sender == "" then newSender() end
  text(sender, 78, 51, 12, INK)
  text("RE:", 24, 70, 11, DIM, nil, 1)
  text(info, 78, 69, 12, INK)
  text("SUBJ:", 24, 88, 11, DIM, nil, 1)
  text("Shredder", 78, 87, 12, INK)
  attachment()
  hline(24, 108, W - 48, 1, INK); hline(24, 111, W - 48, 1, INK)

  row("count", "COUNT",   nil,  120, 0.25, 1)
  row("min",   "MIN",     "ms", 146, 2,    5)
  row("max",   "MAX",     "ms", 172, 4,    10)
  row("gap",   "GAP",     "ms", 198, 2,    10)
  row("rev",   "REVERSE", "%",  224, 0.5,  5)

  text("STRENGTH:", 24, 260, 12, INK, nil, 1, true)
  knob(W / 2, 318, 38)

  check("pitch", "PITCH", 24,  384)
  check("speed", "SPEED", 92,  384)
  check("gain",  "GAIN",  160, 384)
  check("pan",   "PAN",   222, 384)

  stamp(24, 410, W - 48, 42)

  local cc = (status ~= "" and r.time_precise() - statusT < 6) and status or "-"
  local cw = text("cc:", 24, 464, 11, DIM)
  text(cc, 24 + math.max(26, cw + 6), 464, 11, NAVY)

  hline(24, 484, W - 48, 1, LINE)
  text("Regional Manager: Michael Scott", W - 24, 490, 9, DIM, "r")

  note()
end

local function loop()
  local ch = gfx.getchar()
  if ch < 0 then return end
  if ch == 27 then
    if helpOpen then helpOpen = false else gfx.quit(); return end
  end
  if ch == 63 or ch == 26161 then helpOpen = not helpOpen end
  if ch == 13 then doShred = (gfx.mouse_cap & 8 == 8) and "replace" or "new" end

  S = ((gfx.ext_retina and gfx.ext_retina > 0) and gfx.ext_retina or 1) * UI_SCALE
  M.x, M.y = gfx.mouse_x, gfx.mouse_y
  M.down = gfx.mouse_cap & 1 == 1
  M.pressed = M.down and not M.prev
  M.released = (not M.down) and M.prev
  M.shift = gfx.mouse_cap & 8 == 8
  M.wheel = gfx.mouse_wheel; gfx.mouse_wheel = 0

  local now = r.time_precise()
  if now - infoT > 0.25 then
    infoT = now
    local list, total = collect()
    info = #list == 0 and "(no item selected)" or ("%d item%s, %.1f sec"):format(#list, #list > 1 and "s" or "", total)
  end

  applyTheme()
  frame()

  if M.released then active = nil end
  M.prev = M.down
  gfx.update()

  if editReq then
    local k = editReq; editReq = nil
    if NAMES[k] then edit(k) end
  end
  if doShred then
    local mode = doShred; doShred = nil
    shred(mode == "replace"); save(); newSender()
  end
  r.defer(loop)
end

---------------------------------------------------------------- run
math.randomseed(math.floor(os.time() + (r.time_precise() % 1) * 1e6))
load()
applyTheme(true)
local function fitScale(w, h)
  if not r.my_getViewport then return end
  local mx, my = r.GetMousePosition()
  local l, t, rr, b = r.my_getViewport(0, 0, 0, 0, mx, my, mx, my, true)
  local sw, sh = (rr or 0) - (l or 0), math.abs((b or 0) - (t or 0))
  if sw > 200 and sh > 200 then
    UI_SCALE = math.min(UI_SCALE, (sh * 0.92) / h, (sw * 0.95) / w)
  end
end
fitScale(W, H)
local dock = tonumber(r.GetExtState(SEC, "dock")) or 0
local wx = tonumber(r.GetExtState(SEC, "wx"))
local wy = tonumber(r.GetExtState(SEC, "wy"))
gfx.ext_retina = 1
gfx.init("Shredder", math.floor(W * UI_SCALE + 0.5), math.floor(H * UI_SCALE + 0.5), dock, wx, wy)

r.atexit(function()
  local d, x, y = gfx.dock(-1, 0, 0, 0, 0)
  r.SetExtState(SEC, "dock", tostring(d), true)
  if x then r.SetExtState(SEC, "wx", tostring(x), true); r.SetExtState(SEC, "wy", tostring(y), true) end
  save()
end)

loop()
