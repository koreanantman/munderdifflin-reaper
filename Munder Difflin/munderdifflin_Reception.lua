-- @description Munder Difflin office tools (Reception, Shredder, Stapler, Copier, Binder)
-- @author Byungkyu Lee
-- @version 1.0.0
-- @changelog First release
-- @link https://github.com/koreanantman/munderdifflin-reaper
-- @license MIT
-- @provides
--   [main] munderdifflin_Shredder.lua
--   [main] munderdifflin_Stapler.lua
--   [main] munderdifflin_Copier.lua
--   [main] munderdifflin_Binder.lua
--   [main] munderdifflin_MunderDifflin.lua
-- @about
--   # Munder Difflin
--   Small, office-themed tools for sound design in REAPER.
--
--   - Reception: the front desk. Dial 1-4 to open a tool, 5-9 for custom dials, 0 for the operator.
--   - Shredder: grinds selected audio into randomized, automated fragments.
--   - Stapler: lines up the first transient of every layer, with an offset.
--   - Copier: turns audio into MIDI (ALL, CHORDS, MELODY, BASS, HITS).
--   - Binder: files track templates, FX chains and audio; drag them onto tracks.
--   - Munder Difflin: the business card. Credits, orientation and shared settings.
--
--   Tip: bind Reception to a key. When REAPER asks about the already running instance,
--   choose "Terminate instances" + "Remember" and the same key opens/closes it.

local r = reaper
local SEC = "BK_Office"
local W, H = 320, 400
local UI_SCALE = tonumber(r.GetExtState("BK_Office", "ui_scale")) or 1.265

local DIR = (debug.getinfo(1, "S").source:match("^@?(.*[/\\])")) or ""
local PREFIX = "munderdifflin_"

local DEPTS = {
  [1] = { word = "SHRED",  name = "SHREDDER", file = "Shredder.lua", what = { "grind audio", "into scraps" } },
  [2] = { word = "STAPLE", name = "STAPLER",  file = "Stapler.lua",  what = { "line up", "your layers" } },
  [3] = { word = "COPY",   name = "COPIER",   file = "Copier.lua",   what = { "turn audio", "into MIDI" } },
  [4] = { word = "BIND",   name = "BINDER",   file = "Binder.lua",   what = { "file presets", "and audio" } },
}

---------------------------------------------------------------- colours (business hours only)
local C = {
  BG = {0.965, 0.953, 0.918}, INK = {0.13, 0.13, 0.15}, DIM = {0.50, 0.49, 0.46}, LINE = {0.78, 0.77, 0.72},
  RED = {0.76, 0.14, 0.12}, NAVY = {0.13, 0.22, 0.46},
  RING = {0.78, 0.77, 0.73}, RING2 = {0.62, 0.61, 0.57}, FACE = {0.97, 0.95, 0.89}, WHEEL = {0.14, 0.14, 0.16},
  HOLE = {0.97, 0.95, 0.89}, HOV = {0.99, 0.90, 0.50}, CARD = {0.995, 0.985, 0.95},
  SPEED = {0.88, 0.92, 0.97}, OPER = {0.97, 0.86, 0.84},
}

---------------------------------------------------------------- drawing helpers
local S = 1
local OS = r.GetOS()
local CLEAN = r.GetExtState("BK_Office", "lettering") == "clean"
local FONT = CLEAN and (OS:match("Win") and "Consolas" or ((OS:match("OSX") or OS:match("mac")) and "Menlo" or "DejaVu Sans Mono"))
             or ((OS:match("Win") or OS:match("OSX") or OS:match("mac")) and "Courier New" or "Liberation Mono")
local function sc(v) return math.floor(v * S + 0.5) end
local function col(c, a) gfx.set(c[1], c[2], c[3], a or 1) end
local SANS = OS:match("Win") and "Arial" or ((OS:match("OSX") or OS:match("mac")) and "Helvetica" or "Liberation Sans")
local useSans = false
local function font(sz, bold)
  if useSans then gfx.setfont(2, SANS, sc(sz + 1), bold and string.byte("b") or 0)
  else gfx.setfont(1, FONT, sc(sz + 1), bold and string.byte("b") or 0) end
end
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
local function hline(x, y, w, t, c) col(c); gfx.rect(sc(x), sc(y), sc(w), math.max(1, sc(t or 1)), 1) end
local function frameBorder(ink, line)
  local t = math.max(2, math.floor(2 * S + 0.5))
  col(ink)
  gfx.rect(0, 0, gfx.w, t, 1); gfx.rect(0, gfx.h - t, gfx.w, t, 1)
  gfx.rect(0, 0, t, gfx.h, 1); gfx.rect(gfx.w - t, 0, t, gfx.h, 1)
  local i = math.floor(6 * S + 0.5)
  col(line); gfx.rect(i, i, gfx.w - 2 * i, gfx.h - 2 * i, 0)
end
local function disc(x, y, rad, c, a) col(c, a); gfx.circle(x * S, y * S, rad * S, 1, 1) end

---------------------------------------------------------------- speed dial (5-9)
local function isSpeed(n) return type(n) == "number" and n >= 5 and n <= 9 end
local function speed(n)
  local id = r.GetExtState(SEC, "speed" .. n .. "_cmd")
  if id == "" then return nil end
  return { id = id, label = r.GetExtState(SEC, "speed" .. n .. "_label") }
end

local function cmdOf(id)
  local n = tonumber(id)
  if n then return n end
  if id:sub(1, 1) ~= "_" then id = "_" .. id end
  local c = r.NamedCommandLookup(id)
  return (c and c ~= 0) and c or nil
end

local function actionName(c)
  if not r.kbd_getTextFromCmd then return nil end
  local t = r.kbd_getTextFromCmd(c, 0)
  return (t and t ~= "") and t or nil
end

local function shortLabel(s)
  s = (s or ""):gsub("^Script:%s*", ""):gsub("%.lua$", ""):gsub("^%w+:%s*", "")
  s = s:upper():gsub("[^%w ]", ""):gsub("%s+", " ")
  local w = s:match("^(%S+)") or s
  return w:sub(1, 6)
end

local function assignSpeed(n)
  local cur = speed(n)
  -- prefill with a command ID sitting on the clipboard (SWS), e.g. after
  -- Actions list > right-click > "Copy selected action command ID"
  local id0 = cur and cur.id or ""
  if r.CF_GetClipboard then
    local clip = (r.CF_GetClipboard("") or ""):match("^%s*(.-)%s*$")
    if clip ~= "" and #clip < 80 and clip:match("^_?[%w_]+$") and cmdOf(clip) then id0 = clip end
  end
  local ok, csv = r.GetUserInputs("Custom dial " .. n .. "  -  Actions list: right-click > Copy selected action command ID", 2,
    "Action ID:,Label (optional):,extrawidth=200",
    id0 .. "," .. (cur and cur.label or ""))
  if not ok then return nil end
  local id, label = csv:match("^([^,]*),?(.*)$")
  id = (id or ""):match("^%s*(.-)%s*$")
  if id == "" then
    r.DeleteExtState(SEC, "speed" .. n .. "_cmd", true)
    r.DeleteExtState(SEC, "speed" .. n .. "_label", true)
    return "custom dial " .. n .. " cleared"
  end
  local c = cmdOf(id)
  if not c then return "no action with that ID" end
  label = (label or ""):match("^%s*(.-)%s*$")
  if label == "" then label = shortLabel(actionName(c) or id) end
  label = label:upper():sub(1, 6)
  r.SetExtState(SEC, "speed" .. n .. "_cmd", id, true)
  r.SetExtState(SEC, "speed" .. n .. "_label", label, true)
  return ("%d = %s"):format(n, actionName(c) or id)
end

---------------------------------------------------------------- state
local M = { x = 0, y = 0, down = false, prev = false, rprev = false }
local status, statusT = "", 0
local function say(s) status, statusT = s, r.time_precise() end
local anim = nil
local wasInside, outT, openT = false, nil, r.time_precise()
local quitting = false

local CX, CY, R_RING, R_FACE, R_WHEEL, R_HOLES, R_HOLE, R_CARD = W / 2, 194, 136, 130, 124, 94, 23, 60
local STOP = 112
local function holeAngle(n) return 60 - ((n == 0 and 10 or n) - 1) * 30 end

local function inside(x, y, w, h) return M.x >= sc(x) and M.x < sc(x + w) and M.y >= sc(y) and M.y < sc(y + h) end
local function near(x, y, rad) local dx, dy = M.x / S - x, M.y / S - y; return dx * dx + dy * dy <= rad * rad end

---------------------------------------------------------------- what each number does
local function launchTool(d)
  local path = DIR .. PREFIX .. d.file
  if not r.file_exists(path) then path = DIR .. d.file end
  if not r.file_exists(path) then return false, "can't find " .. PREFIX .. d.file end
  local cmd = r.AddRemoveReaScript(true, 0, path, true)
  if not cmd or cmd == 0 then return false, "couldn't register " .. d.file end
  r.Main_OnCommand(cmd, 0)
  return true
end

-- returns true if Reception should close afterwards
local function connect(n)
  if DEPTS[n] or n == 0 then
    local ok, err = launchTool(DEPTS[n] or { file = "MunderDifflin.lua" })
    if not ok then say(err) end
    return ok
  else
    local sp = speed(n)
    if not sp then return false end
    local c = cmdOf(sp.id)
    if not c then say("custom dial " .. n .. ": action not found"); return false end
    r.Main_OnCommand(c, 0)
    return true
  end
end

local function dial(n)
  if anim then return end
  if isSpeed(n) and not speed(n) then
    local msg = assignSpeed(n)
    M.prev, M.rprev = false, false
    if msg then say(msg) end
    return
  end
  anim = { n = n, t0 = r.time_precise(), travel = (STOP - holeAngle(n)) % 360 }
end

local function easeInOut(x) return x < 0.5 and 4 * x * x * x or 1 - (-2 * x + 2) ^ 3 / 2 end
local function wheelRot()
  if not anim then return 0 end
  local t = r.time_precise() - anim.t0
  local go, hold, back = 0.20 + anim.travel / 650, 0.07, 0.22 + anim.travel / 750
  if t < go then return anim.travel * easeInOut(t / go) end
  if t < go + hold then
    local w = (t - go) / hold                       -- tiny bump against the finger stop
    return anim.travel + math.sin(w * math.pi) * 1.2
  end
  if not anim.fired then
    anim.fired = true
    if connect(anim.n) then quitting = true end
  end
  local u = (t - go - hold) / back
  if u < 1 then
    -- mostly constant speed (like the governor in a real dial), easing into rest at the end
    local e = u < 0.75 and (u / 0.75) * 0.85 or 0.85 + (1 - (1 - (u - 0.75) / 0.25) ^ 2) * 0.15
    return anim.travel * (1 - e)
  end
  anim = nil
  return 0
end

---------------------------------------------------------------- frame
local function holeInfo(n)
  if DEPTS[n] then return "tool", DEPTS[n].word end
  if n == 0 then return "oper", "OPER" end
  local sp = speed(n)
  return "speed", sp and sp.label or nil
end

local drawCardText
local function drawCard(n)
  disc(CX, CY, R_CARD + 3, C.RING2)
  disc(CX, CY, R_CARD, C.CARD)
  useSans = true
  drawCardText(n)
  useSans = false
end

drawCardText = function(n)
  if n == 0 then
    text("OPERATOR", CX, CY - 28, 13, C.RED, "c", 1, true)
    hline(CX - 36, CY - 9, 72, 1, C.INK)
    text("settings and", CX, CY - 2, 10, C.INK, "c")
    text("credits", CX, CY + 12, 10, C.INK, "c")
    return
  end
  if n and DEPTS[n] then
    local d = DEPTS[n]
    text(d.name, CX, CY - 28, 13, C.INK, "c", 1, true)
    hline(CX - 36, CY - 9, 72, 1, C.INK)
    text(d.what[1], CX, CY - 2, 10, C.INK, "c")
    text(d.what[2], CX, CY + 12, 10, C.INK, "c")
  elseif n then
    local sp = speed(n)
    text("CUSTOM DIAL " .. n, CX, CY - 30, 11, C.INK, "c", 0, true)
    hline(CX - 36, CY - 12, 72, 1, C.INK)
    if sp then
      local c = cmdOf(sp.id)
      local nm = (c and actionName(c)) or sp.id
      nm = nm:gsub("^Script:%s*", "")
      local a, b = nm:sub(1, 14), nm:sub(15, 26)
      text(a, CX, CY - 5, 9, C.INK, "c")
      if b ~= "" then text(b, CX, CY + 7, 9, C.INK, "c") end
      text("right-click: change", CX, CY + 22, 8, C.DIM, "c")
    else
      text("empty line", CX, CY - 3, 10, C.INK, "c")
      text("click to assign", CX, CY + 12, 9, C.DIM, "c")
    end
  else
    text("RECEPTION", CX, CY - 27, 12, C.INK, "c", 1, true)
    hline(CX - 38, CY - 9, 76, 1, C.INK)
    text("dial a number", CX, CY - 2, 10, C.INK, "c")
    text("0 = operator", CX, CY + 13, 8, C.DIM, "c")
  end
end

local function drawDial(rot, hovered)
  disc(CX, CY + 3, R_RING, {0, 0, 0}, 0.12)
  disc(CX, CY, R_RING, C.RING)
  col(C.RING2); gfx.circle(sc(CX), sc(CY), R_RING * S, 0, 1)
  disc(CX, CY, R_FACE, C.FACE)
  disc(CX, CY, R_WHEEL, C.WHEEL)
  for i = 1, 10 do
    local n = i % 10
    local a = math.rad(holeAngle(n) + rot)
    local hx, hy = CX + math.sin(a) * R_HOLES, CY - math.cos(a) * R_HOLES
    local kind, word = holeInfo(n)
    local base = (kind == "speed" and word) and C.SPEED or (kind == "oper" and C.OPER) or C.HOLE
    disc(hx, hy, R_HOLE, hovered == n and C.HOV or base)
    useSans = true
    if word then
      text(tostring(n), hx, hy - 18, 17, kind == "oper" and C.RED or C.INK, "c", 0, true)
      text(word, hx, hy + 3, 9, kind == "oper" and C.RED or C.INK, "c", 0, true)
    else
      text(tostring(n), hx, hy - 18, 17, C.DIM, "c", 0, true)
      text("- - -", hx, hy + 4, 8, C.LINE, "c", 0, true)
    end
    useSans = false
  end
  local s = math.rad(STOP)
  col(C.RING2)
  for k = -1.5, 1.5, 0.5 do
    local px, py = math.cos(s) * k, math.sin(s) * k
    gfx.line(sc(CX + math.sin(s) * (R_HOLES + 6) + px), sc(CY - math.cos(s) * (R_HOLES + 6) + py),
             sc(CX + math.sin(s) * (R_RING + 4) + px), sc(CY - math.cos(s) * (R_RING + 4) + py), 1)
  end
  disc(CX + math.sin(s) * (R_RING + 4), CY - math.cos(s) * (R_RING + 4), 4, C.RING2)
  drawCard((anim and anim.n) or hovered)
end

local function frame()
  col(C.BG); gfx.rect(0, 0, gfx.w, gfx.h, 1)
  frameBorder(C.INK, C.LINE)
  text("RECEPTION", 24, 18, 13, C.INK, nil, 4, true)
  text(os.date("%H:%M"), W - 24, 20, 11, C.DIM, "r")
  hline(24, 42, W - 48, 2, C.INK)

  local hovered
  if not anim then
    for i = 1, 10 do
      local n = i % 10
      local a = math.rad(holeAngle(n))
      if near(CX + math.sin(a) * R_HOLES, CY - math.cos(a) * R_HOLES, R_HOLE + 2) then hovered = n end
    end
  end
  drawDial(wheelRot(), hovered)

  local cc = (status ~= "" and r.time_precise() - statusT < 6) and status or "-"
  local cw = text("cc:", 24, 350, 11, C.DIM)
  text(#cc > 32 and (cc:sub(1, 31) .. "...") or cc, 24 + math.max(26, cw + 6), 350, 11, C.NAVY)
  hline(24, 370, W - 48, 1, C.LINE)
  text("Regional Manager: Michael Scott", W - 24, 376, 9, C.DIM, "r")
  return hovered
end

---------------------------------------------------------------- loop
local function loop()
  local ch = gfx.getchar()
  if ch < 0 or (quitting and not anim) then gfx.quit(); return end
  if ch == 27 then gfx.quit(); return end
  if ch >= 48 and ch <= 57 then dial(ch - 48) end                    -- keys 0-9

  S = math.min(gfx.w / W, gfx.h / H)          -- real pixels per layout unit
  M.x, M.y = gfx.mouse_x, gfx.mouse_y
  M.down = gfx.mouse_cap & 1 == 1
  M.pressed = M.down and not M.prev
  M.rdown = gfx.mouse_cap & 2 == 2
  M.rpressed = M.rdown and not M.rprev

  local hovered = frame()

  if M.pressed and hovered and not anim then dial(hovered) end
  if M.rpressed and hovered and isSpeed(hovered) then
    local msg = assignSpeed(hovered)
    M.down, M.prev, M.rprev = false, false, false
    if msg then say(msg) end
  end

  local inWin = M.x >= 0 and M.y >= 0 and M.x < gfx.w and M.y < gfx.h
  local now = r.time_precise()
  if inWin then wasInside, outT = true, nil
  elseif wasInside and not anim and not M.down then
    outT = outT or now
    if now - outT > 0.45 and now - openT > 0.8 then gfx.quit(); return end
  end

  M.prev, M.rprev = M.down, M.rdown
  gfx.update()
  r.defer(loop)
end

---------------------------------------------------------------- open at the mouse
do
  local mx, my = r.GetMousePosition()
  if r.my_getViewport then
    local l, t, rr, b = r.my_getViewport(0, 0, 0, 0, mx, my, mx, my, true)
    local sw, sh = (rr or 0) - (l or 0), math.abs((b or 0) - (t or 0))
    if sw > 200 and sh > 200 then UI_SCALE = math.min(UI_SCALE, sh * 0.92 / H, sw * 0.95 / W) end
  end
  local ww, hh = math.floor(W * UI_SCALE + 0.5), math.floor(H * UI_SCALE + 0.5)
  gfx.ext_retina = 1
  gfx.init("Reception", ww, hh, 0, math.floor(mx - ww / 2), math.floor(my - CY * UI_SCALE))
  -- Windows HiDPI: REAPER reports the monitor scale in ext_retina but may keep the window
  -- at unscaled pixels; grow the window to real pixels so text is drawn sharp, not upscaled.
  local ret = gfx.ext_retina or 1
  if r.GetOS():match("Win") and ret > 1.01 and gfx.w > 0 and gfx.w < ww * ret * 0.9 then
    gfx.init("", math.floor(ww * ret + 0.5), math.floor(hh * ret + 0.5))
  end
  if r.JS_Window_Find then
    local hwnd = r.JS_Window_Find("Reception", true)
    if hwnd then r.JS_Window_SetStyle(hwnd, "POPUP") end
  end
end
loop()
