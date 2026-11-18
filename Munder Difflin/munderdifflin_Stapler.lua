-- @description Stapler
-- @author Byungkyu Lee
-- @version 1.5
-- @changelog Size and lettering follow the Munder Difflin card
-- @about Lines up the first hit of every selected item (layers) and staggers them by an offset.
--   Drag a value up/down (Shift = fine), wheel nudges, double-click to type. Enter = stamp.

local r = reaper
local SEC, TOOL = "BK_Stapler", "Stapler"
local W, H = 300, 420
local P   = { offset = 0 }
local LIM = { offset = {0, 100} }
local Q   = { offset = 0 }      -- drag/wheel resolution (decimals)
local QF  = { offset = 2 }      -- shift-drag / typed resolution
local NAMES = { offset = "Offset (ms)" }
local HELP = {
  "ATTACHMENT 1 OF 1",
  "Re: How to use the Stapler",
  "",
  "Select 2+ items. Your layers.",
  "Press STAMP!. Every layer's",
  "first hit lines up with the",
  "top layer. OFFSET then pushes",
  "each next layer a bit later.",
  "0 ms = one solid stack.",
  "",
  "DRAG knob ......... up/down",
  "SHIFT+DRAG ........ fine",
  "WHEEL ............. nudge",
  "DOUBLE-CLICK ...... type it",
  "ENTER ............. stamp",
  "ESC ............... go home",
  "",
  "The top layer never moves.",
  "It has seniority.",
}
local FONT_UP = 1     -- +1 pt on every text size
local UI_SCALE = tonumber(reaper.GetExtState("BK_Office", "ui_scale")) or 1.265  -- set on the Munder Difflin card
local TOOL_FRAME, TOOL_INFO, TOOL_ACTION
---------------------------------------------------------------- base
local status, statusT = "", 0
local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end
local function say(s) status, statusT = s, r.time_precise() end
local function fmtN(v)
  local s = string.format("%.3f", v):gsub("0+$", ""):gsub("%.$", "")
  return s
end

local function setP(k, v, fine)
  v = clamp(v, LIM[k][1], LIM[k][2])
  local q = 10 ^ ((fine and QF[k]) or Q[k] or 0)
  P[k] = math.floor(v * q + 0.5) / q
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

-- new track right below tr0, named "<tr0 name>_<SUFFIX> NN"
local function newTrackBelow(tr0, suffix)
  local tidx = math.floor(r.GetMediaTrackInfo_Value(tr0, "IP_TRACKNUMBER"))
  local _, base = r.GetSetMediaTrackInfo_String(tr0, "P_NAME", "", false)
  if base == "" then base = "Track " .. tidx end
  local pat = "^" .. base:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0") .. "_" .. suffix .. " (%d+)$"
  local num = 0
  for i = 0, r.CountTracks(0) - 1 do
    local _, nm = r.GetSetMediaTrackInfo_String(r.GetTrack(0, i), "P_NAME", "", false)
    local d = tonumber(nm:match(pat))
    if d and d > num then num = d end
  end
  r.InsertTrackAtIndex(tidx, true)
  local tr = r.GetTrack(0, tidx)
  r.GetSetMediaTrackInfo_String(tr, "P_NAME", ("%s_%s %02d"):format(base, suffix, num + 1), true)
  return tr
end

---------------------------------------------------------------- engine
-- first transient of an item, seconds from item start
local function onset(item)
  local tk = r.GetActiveTake(item)
  if not tk or r.TakeIsMIDI(tk) then return 0 end
  local len = math.min(r.GetMediaItemInfo_Value(item, "D_LENGTH"), 10)
  local src = r.GetMediaItemTake_Source(tk)
  local sr = r.GetMediaSourceSampleRate(src); if not sr or sr <= 0 then sr = 48000 end
  local ch = clamp(r.GetMediaSourceNumChannels(src) or 1, 1, 8)
  local acc = r.CreateTakeAudioAccessor(tk)
  local block = 4096
  local buf = r.new_array(block * ch)
  local total = math.floor(len * sr)

  local function scan(fn)
    local pos = 0
    while pos < total do
      local n = math.min(block, total - pos)
      buf.clear()
      r.GetAudioAccessorSamples(acc, sr, ch, r.GetAudioAccessorStartTime(acc) + pos / sr, n, buf)
      for i = 0, n - 1 do
        local v = 0
        for c = 1, ch do local a = math.abs(buf[i * ch + c]); if a > v then v = a end end
        if fn(pos + i, v) then return end
      end
      pos = pos + n
    end
  end

  local pk = 0
  scan(function(_, v) if v > pk then pk = v end end)
  local hit = 0
  if pk > 1e-5 then
    local thr = pk * 0.3                      -- ~ -10 dB under the item's own peak
    scan(function(i, v) if v >= thr then hit = i; return true end end)
  end
  r.DestroyAudioAccessor(acc)
  return hit / sr
end

local function selectedItems()
  local items = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    items[#items + 1] = {
      it = it,
      tr = r.GetMediaTrackInfo_Value(r.GetMediaItem_Track(it), "IP_TRACKNUMBER"),
      pos = r.GetMediaItemInfo_Value(it, "D_POSITION"),
    }
  end
  table.sort(items, function(a, b) if a.tr ~= b.tr then return a.tr < b.tr end return a.pos < b.pos end)
  return items
end

local function staple()
  local items = selectedItems()
  if #items < 2 then return say("select 2+ items first") end
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local anchor = items[1].pos + onset(items[1].it)
  for i = 2, #items do
    local p = anchor + (i - 1) * P.offset / 1000 - onset(items[i].it)
    r.SetMediaItemInfo_Value(items[i].it, "D_POSITION", math.max(0, p))
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("Stapler: " .. #items .. " layers", -1)
  say(("%d layers stapled  /  %s ms"):format(#items, fmtN(P.offset)))
end

---------------------------------------------------------------- ui (memo)
local OS = r.GetOS()
local FONT = (reaper.GetExtState("BK_Office", "lettering") == "clean")
  and (OS:match("Win") and "Consolas" or ((OS:match("OSX") or OS:match("mac")) and "Menlo" or "DejaVu Sans Mono"))
  or ((OS:match("Win") or OS:match("OSX") or OS:match("mac")) and "Courier New" or "Liberation Mono")
local S = 1
local PAPER = {0.965, 0.953, 0.918}
local INK   = {0.13, 0.13, 0.15}
local NAVY  = {0.13, 0.22, 0.46}
local RED   = {0.76, 0.14, 0.12}
local DIM   = {0.50, 0.49, 0.46}
local LINE  = {0.78, 0.77, 0.72}
local NOTE  = {0.99, 0.93, 0.58}
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
local function font(sz, bold) gfx.setfont(1, FONT, sc(sz + (FONT_UP or 0)), bold and string.byte("b") or 0) end
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
local editReq, doAction = nil, nil
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

-- LABEL: ............ value unit
local function row(key, label, unit, y, step, wstep, fmt)
  local x, w = 24, W - 48
  local hov, act = interact(key, x, y, w, 24)
  if act and M.down and M.y ~= dragY0 then
    setP(key, dragV0 + (dragY0 - M.y) / S * step * (M.shift and 0.2 or 1))
  end
  if hov and M.wheel ~= 0 then setP(key, P[key] + (M.wheel > 0 and 1 or -1) * wstep) end
  local lw = text(label .. ":", x, y + 5, 12, INK, nil, 1, true)
  local vs = (fmt and fmt(P[key]) or fmtN(P[key])) .. (unit and (" " .. unit) or "")
  local vw = text(vs, x + w, y + 4, 14, (hov or act) and RED or NAVY, "r")
  col(LINE)
  for dx = x + lw + 8, x + w - vw - 8, 5 do gfx.rect(sc(dx), sc(y + 15), math.max(1, sc(1)), math.max(1, sc(1)), 1) end
  hline(x, y + 23, w, 1, LINE)
end

-- o = { drag, fine, wheel, wheelFine, loL, hiL, fmt }
local function knob(key, cx, cy, R, o)
  local hov, act = interact(key, cx - R - 14, cy - R - 14, (R + 14) * 2, (R + 14) * 2)
  if act and M.down and M.y ~= dragY0 then
    setP(key, dragV0 + (dragY0 - M.y) / S * (M.shift and o.fine or o.drag), M.shift)
  end
  if hov and M.wheel ~= 0 then
    setP(key, P[key] + (M.wheel > 0 and 1 or -1) * (M.shift and o.wheelFine or o.wheel))
  end
  local lo, hi = LIM[key][1], LIM[key][2]
  local t = (P[key] - lo) / (hi - lo)
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
  text(o.loL, cx - R - 12, cy + R + 6, 10, DIM, "c")
  text(o.hiL, cx + R + 12, cy + R + 6, 10, DIM, "c")
  text(o.fmt(P[key]), cx, cy + R + 2, 16, act and RED or NAVY, "c", 0, true)
end

local function check(key, label, x, y, w)
  local hov = interact(key, x, y - 2, w or 64, 18)
  if hov and M.pressed then P[key] = not P[key] end
  text("[ ]", x, y, 12, INK)
  if P[key] then text("x", x + 7.5, y, 12, NAVY, nil, 0, true) end
  text(label, x + 24, y, 11, P[key] and INK or DIM, nil, 1)
end

local function stamp(label, x, y, w, h)
  local hov, act = interact("action", x, y, w, h)
  local pressed = act and M.down
  if pressed then col(RED); gfx.rect(sc(x), sc(y), sc(w), sc(h), 1) end
  local c = pressed and PAPER or RED
  local a = hov and 1 or 0.88
  col(c, a)
  for k = 0, 1 do gfx.rect(sc(x) + k, sc(y) + k, sc(w) - 2 * k, sc(h) - 2 * k, 0) end
  gfx.rect(sc(x + 4), sc(y + 4), sc(w - 8), sc(h - 8), 0)
  text(label, x + w / 2, y + h / 2 - 9, 16, c, "c", 7, true)
  if act and M.released and hov then doAction = M.shift and "shift" or "normal" end
end

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
  local x, y, w = 30, 118, W - 60
  local LH = 13 + (FONT_UP or 0)
  local h = #HELP * LH + 38
  col(INK, 0.12); gfx.rect(sc(x + 3), sc(y + 4), sc(w), sc(h), 1)
  col(NOTE); gfx.rect(sc(x), sc(y), sc(w), sc(h), 1)
  col(INK, 0.08); gfx.rect(sc(x), sc(y), sc(w), sc(18), 1)
  local ly = y + 28
  for i, ln in ipairs(HELP) do
    if ln ~= "" then text(ln, x + 14, ly, 11, i == 1 and THEMEX.noteRed or THEMEX.noteInk, nil, 0, i == 1) end
    ly = ly + LH
  end
  local hov = M.x >= sc(x) and M.x < sc(x + w) and M.y >= sc(y) and M.y < sc(y + h)
  if hov and M.pressed and active ~= "help" then helpOpen = false end
end

local function header()
  col(PAPER); gfx.rect(0, 0, gfx.w, gfx.h, 1)
  frameBorder(INK, LINE)
  text("INTEROFFICE MEMO", 24, 20, 13, INK, nil, 3, true)
  text(os.date("%m/%d/%y"), W - 24, 21, 11, DIM, "r")
  hline(24, 42, W - 48, 2, INK)
  if sender == "" then newSender() end
  text("FROM:", 24, 52, 11, DIM, nil, 1); text(sender, 78, 51, 12, INK)
  text("RE:", 24, 70, 11, DIM, nil, 1);   text(info, 78, 69, 12, INK)
  text("SUBJ:", 24, 88, 11, DIM, nil, 1); text(TOOL, 78, 87, 12, INK)
  attachment()
  hline(24, 108, W - 48, 1, INK); hline(24, 111, W - 48, 1, INK)
end

local function footer(y)
  local cc = (status ~= "" and r.time_precise() - statusT < 6) and status or "-"
  local cw = text("cc:", 24, y, 11, DIM)
  text(cc, 24 + math.max(26, cw + 6), y, 11, NAVY)
  hline(24, y + 20, W - 48, 1, LINE)
  text("Regional Manager: Michael Scott", W - 24, y + 26, 9, DIM, "r")
end

local function edit(k)
  local ok, s = r.GetUserInputs(TOOL, 1, NAMES[k] .. ",extrawidth=60", fmtN(P[k]))
  if ok then local v = tonumber(s); if v then setP(k, v, true) end end
  M.prev, active = false, nil
end

local function loop()
  local ch = gfx.getchar()
  if ch < 0 then return end
  if TOOL_KEY and TOOL_KEY(ch) then ch = 0 end
  if ch == 27 then
    if helpOpen then helpOpen = false else gfx.quit(); return end
  end
  if ch == 63 or ch == 26161 then helpOpen = not helpOpen end
  if ch == 13 then doAction = (gfx.mouse_cap & 8 == 8) and "shift" or "normal" end

  S = ((gfx.ext_retina and gfx.ext_retina > 0) and gfx.ext_retina or 1) * (UI_SCALE or 1)
  M.x, M.y = gfx.mouse_x, gfx.mouse_y
  M.down = gfx.mouse_cap & 1 == 1
  M.pressed = M.down and not M.prev
  M.released = (not M.down) and M.prev
  M.rdown = gfx.mouse_cap & 2 == 2
  M.rpressed = M.rdown and not M.rprev
  M.shift = gfx.mouse_cap & 8 == 8
  M.wheel = gfx.mouse_wheel; gfx.mouse_wheel = 0

  local now = r.time_precise()
  if now - infoT > 0.25 then infoT = now; info = TOOL_INFO() end

  applyTheme()
  header()
  TOOL_FRAME()
  note()

  if M.released then active = nil end
  M.prev, M.rprev = M.down, M.rdown
  gfx.update()

  if editReq then
    local k = editReq; editReq = nil
    if NAMES[k] then edit(k) end
  end
  if doAction then
    local mode = doAction; doAction = nil
    TOOL_ACTION(mode); save(); newSender()
  end
  if TOOL_POST then TOOL_POST() end
  r.defer(loop)
end

---------------------------------------------------------------- frame
TOOL_INFO = function()
  local n = r.CountSelectedMediaItems(0)
  if n == 0 then return "(no item selected)" end
  return ("%d layer%s"):format(n, n > 1 and "s" or "")
end

TOOL_FRAME = function()
  text("OFFSET:", 24, 124, 12, INK, nil, 1, true)
  knob("offset", W / 2, 216, 50, {
    drag = 0.4, fine = 0.02, wheel = 1, wheelFine = 0.1,
    loL = "0", hiL = "100", fmt = function(v) return fmtN(v) .. " ms" end,
  })
  stamp("STAMP!", 24, 318, W - 48, 42)
  footer(372)
end

TOOL_ACTION = function() staple() end

---------------------------------------------------------------- run
local function fitScale(w, h)
  if not r.my_getViewport then return end
  local mx, my = r.GetMousePosition()
  local l, t, rr, b = r.my_getViewport(0, 0, 0, 0, mx, my, mx, my, true)
  local sw, sh = (rr or 0) - (l or 0), math.abs((b or 0) - (t or 0))
  if sw > 200 and sh > 200 then
    UI_SCALE = math.min(UI_SCALE, (sh * 0.92) / h, (sw * 0.95) / w)
  end
end
math.randomseed(math.floor(os.time() + (r.time_precise() % 1) * 1e6))
load()
fitScale(W, H)
do
  local dock = tonumber(r.GetExtState(SEC, "dock")) or 0
  local wx = tonumber(r.GetExtState(SEC, "wx"))
  local wy = tonumber(r.GetExtState(SEC, "wy"))
  gfx.ext_retina = 1
  local k = UI_SCALE or 1
  gfx.init(TOOL, math.floor(W * k + 0.5), math.floor(H * k + 0.5), dock, wx, wy)
end
r.atexit(function()
  local d, x, y = gfx.dock(-1, 0, 0, 0, 0)
  r.SetExtState(SEC, "dock", tostring(d), true)
  if x then r.SetExtState(SEC, "wx", tostring(x), true); r.SetExtState(SEC, "wy", tostring(y), true) end
  save()
end)
applyTheme(true)
loop()
