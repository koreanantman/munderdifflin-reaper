-- @description Munder Difflin
-- @author Byungkyu Lee
-- @version 1.4
-- @changelog Orientation in English only
-- @about The company business card.
--   Front: who made this. Back (turn it over): settings shared by every office tool.
--   Reception's 0 (operator) puts you through here.

local r = reaper
local SEC = "BK_Office"
local W, H = 560, 344                       -- window (layout units)
local CXo, CYo, CW, CH = 12, 12, 536, 316   -- the card on the desk
local BASE = 0.8                            -- layout units -> pixels at 100% size

local OS = r.GetOS()
local IS_WIN = OS:match("Win") ~= nil
local IS_MAC = OS:match("OSX") ~= nil or OS:match("mac") ~= nil
local SANS = IS_WIN and "Arial" or (IS_MAC and "Helvetica" or "Liberation Sans")
local FACE = SANS

local DESK  = {0.80, 0.78, 0.74}
local CARD  = {0.988, 0.984, 0.972}
local EDGE  = {0.80, 0.79, 0.75}
local INK   = {0.13, 0.13, 0.15}
local DIM   = {0.48, 0.47, 0.44}
local RED   = {0.76, 0.14, 0.12}
local NAVY  = {0.13, 0.22, 0.46}
local CHIP  = {0.93, 0.92, 0.88}

local S = 1
local function sc(v) return math.floor(v * S + 0.5) end
local function col(c, a) gfx.set(c[1], c[2], c[3], a or 1) end
local function font(sz, flags)
  local f = 0
  for ch in (flags or ""):gmatch(".") do f = f * 256 + string.byte(ch) end
  gfx.setfont(1, FACE, sc(sz), f)
end
local function text(s, x, y, sz, c, align, flags)
  font(sz, flags); col(c)
  local w = gfx.measurestr(s)
  local px = sc(x)
  if align == "r" then px = px - w elseif align == "c" then px = px - w / 2 end
  gfx.x, gfx.y = px, sc(y)
  gfx.drawstr(s)
  return w / S
end
local function rect(x, y, w, h, c, fill, a) col(c, a); gfx.rect(sc(x), sc(y), sc(w), sc(h), fill and 1 or 0) end

---------------------------------------------------------------- settings
local TOOL_SECS = { "BK_Shredder", "BK_Stapler", "BK_Copier", "BK_Binder" }
local SPEED_HOLES = { 5, 6, 7, 8, 9 }

local function getScale() return tonumber(r.GetExtState(SEC, "ui_scale")) or 1.265 end
local function setScale(v)
  v = math.max(0.9, math.min(1.6, math.floor(v * 20 + 0.5) / 20))
  r.SetExtState(SEC, "ui_scale", tostring(v), true)
  return v
end
local function lettering() return r.GetExtState(SEC, "lettering") == "clean" and "clean" or "typewriter" end

local function windowSize(k)
  local px = BASE * k * ((IS_WIN and (gfx.ext_retina or 1) > 1.01) and gfx.ext_retina or 1)
  return math.floor(W * px + 0.5), math.floor(H * px + 0.5)
end

---------------------------------------------------------------- state
local M = { x = 0, y = 0, down = false, prev = false }
local face = "front"
local flip = nil
local status, statusT = "", 0
local function say(s) status, statusT = s, r.time_precise() end

-- mouse in card coordinates (faces are drawn at 0,0 inside an off-screen buffer)
local function over(x, y, w, h)
  local a, b = M.x / S - CXo, M.y / S - CYo
  return a >= x and a < x + w and b >= y and b < y + h
end

local function button(label, x, y, active)
  font(17, active and "b" or "")
  local w = gfx.measurestr(label) / S + 26
  local hov = not flip and over(x, y, w, 32)
  rect(x, y, w, 32, active and NAVY or CHIP, true)
  if hov and not active then rect(x, y, w, 32, EDGE, false) end
  text(label, x + w / 2, y + 7, 17, active and CARD or (hov and RED or INK), "c", active and "b" or "")
  return hov and M.pressed, w
end

local function turnLink()
  local hov = not flip and over(CW - 150, CH - 40, 140, 28)
  text("turn over  >", CW - 22, CH - 36, 15, hov and RED or DIM, "r", hov and "b" or "")
  return hov and M.pressed
end

---------------------------------------------------------------- orientation (welcome packet)
local INTRO = {
  en = {
    title = "Welcome to Munder Difflin",
    sub = "New employee orientation. Please read. There is no quiz.",
    items = {
      { "Reception", "The front desk. Dial 1-4 for a department, 5-9 for your custom dials, 0 for the operator." },
      { "Shredder",  "Feed it audio, get random scraps back. Good for happy accidents." },
      { "Stapler",   "Lines up the first hit of every layer. Add offset if you like it loose." },
      { "Copier",    "Copies audio into MIDI. Five modes, from chords to drum hits." },
      { "Binder",    "Files track templates, FX chains and audio. Drag them in and out to fit the job." },
    },
    sign = "Complaints go to HR. HR is one guy. He sits in the annex.",
  },
}

-- word wrap by measured width (works for English and Korean, both use spaces)
local function wrap(str, maxw, sz, flags)
  font(sz, flags)
  local lines, cur = {}, ""
  for word in str:gmatch("%S+") do
    local try = cur == "" and word or (cur .. " " .. word)
    if gfx.measurestr(try) / S > maxw and cur ~= "" then lines[#lines + 1] = cur; cur = word
    else cur = try end
  end
  if cur ~= "" then lines[#lines + 1] = cur end
  return lines
end


local function drawIntro()
  local T = INTRO.en
  text(T.title, 34, 24, 21, INK, nil, "b")
  text(T.sub, 34, 52, 14, DIM, nil, "i")
  rect(34, 76, CW - 68, 1, EDGE, true)

  local y = 88
  for _, it in ipairs(T.items) do
    text(it[1], 34, y + 1, 15, RED, nil, "b")
    for _, ln in ipairs(wrap(it[2], CW - 68 - 104, 14)) do
      text(ln, 138, y, 14, INK)
      y = y + 19
    end
    y = y + 6
  end
  text(T.sign, 34, CH - 34, 13, DIM, nil, "i")

  local hBack = not flip and over(CW - 110, CH - 40, 100, 28)
  text("back  >", CW - 22, CH - 36, 15, hBack and RED or DIM, "r", hBack and "b" or "")
  return hBack and M.pressed
end

---------------------------------------------------------------- faces
local function drawFront()
  local hO = not flip and (over(CW - 150, 26, 130, 26) or over(34, 28, 170, 22))
  text("Orientation  >", CW - 22, 30, 14, hO and RED or DIM, "r", hO and "b" or "")
  if hO and M.pressed then return "intro" end
  text("MUNDER DIFFLIN", 34, 30, 18, INK, nil, "b")
  text("office tools for REAPER", 34, 54, 14, DIM)
  rect(34, 82, 46, 3, RED, true)

  text("Byungkyu Lee", 34, 116, 38, INK, nil, "b")
  text("Assistant to the Regional Manager", 34, 164, 18, INK, nil, "i")

  text("Shredder  .  Stapler  .  Copier  .  Binder  .  Reception", 34, 206, 13, DIM)

  text("Built with Claude.", 34, CH - 66, 15, INK)
  text('I mostly said "make it bigger."', 34, CH - 44, 15, DIM, nil, "i")
  return turnLink() and "back" or nil
end

local function drawBack()
  text("Settings", 34, 26, 22, INK, nil, "b")
  text("shared by every tool", 34, 54, 14, DIM)
  rect(34, 80, CW - 68, 1, EDGE, true)

  local actions = {}
  local LX, BX = 34, 210
  local y = 98
  text("Size", LX, y + 6, 18, INK, nil, "b")
  local k = getScale()
  local m, mw = button("-", BX, y)
  text(("%d%%"):format(math.floor(k * 100 + 0.5)), BX + mw + 38, y + 6, 18, NAVY, "c", "b")
  local p = button("+", BX + mw + 76, y)
  if m then actions.size = -0.05 elseif p then actions.size = 0.05 end

  y = y + 48
  text("Lettering", LX, y + 6, 18, INK, nil, "b")
  local lt = lettering()
  local a1, w1 = button("Typewriter", BX, y, lt == "typewriter")
  local a2 = button("Clean", BX + w1 + 8, y, lt == "clean")
  if a1 then actions.letter = "typewriter" elseif a2 then actions.letter = "clean" end

  y = y + 48
  text("Custom dials", LX, y + 6, 18, INK, nil, "b")
  if button("Clear 5-9", BX, y) then actions.clearSpeed = true end

  y = y + 48
  text("Windows", LX, y + 6, 18, INK, nil, "b")
  if button("Reset positions", BX, y) then actions.resetWin = true end

  if status ~= "" and r.time_precise() - statusT < 4 then text(status, 34, CH - 36, 14, NAVY) end
  return turnLink(), actions
end

---------------------------------------------------------------- frame
local CARDBUF = 7

local function frame()
  S = math.min(gfx.w / W, gfx.h / H)
  col(DESK); gfx.rect(0, 0, gfx.w, gfx.h, 1)

  local cw, ch = sc(CW), sc(CH)
  gfx.setimgdim(CARDBUF, cw, ch)
  gfx.dest = CARDBUF
  col(CARD); gfx.rect(0, 0, cw, ch, 1)
  col(EDGE); gfx.rect(0, 0, cw, ch, 0)
  local ox, oy = CXo, CYo
  local saveX, saveY = M.x, M.y
  M.x, M.y = M.x - sc(ox), M.y - sc(oy)
  CXo, CYo = 0, 0
  local turn, actions
  if face == "front" then turn = drawFront()
  elseif face == "intro" then
    if drawIntro() then turn = "front" end
  else
    local t
    t, actions = drawBack()
    if t then turn = "front" end
  end
  CXo, CYo = ox, oy
  M.x, M.y = saveX, saveY
  gfx.dest = -1

  local kx = 1
  if flip then
    local t = (r.time_precise() - flip.t0) / 0.34
    if t >= 1 then flip = nil
    else
      if t >= 0.5 and face ~= flip.to then face = flip.to end
      kx = math.max(0.02, math.abs(math.cos(t * math.pi)))
    end
  end
  local w = cw * kx
  local x = sc(CXo) + (cw - w) / 2
  col({0, 0, 0}, 0.18); gfx.rect(math.floor(x + sc(4)), sc(CYo) + sc(5), math.floor(w), ch, 1)
  gfx.a = 1
  gfx.blit(CARDBUF, 1, 0, 0, 0, cw, ch, x, sc(CYo), w, ch)
  return turn, actions
end

local function loop()
  local chr = gfx.getchar()
  if chr < 0 or chr == 27 then gfx.quit(); return end
  M.x, M.y = gfx.mouse_x, gfx.mouse_y
  M.down = gfx.mouse_cap & 1 == 1
  M.pressed = M.down and not M.prev

  local turn, actions = frame()

  if turn and not flip then flip = { t0 = r.time_precise(), to = turn } end
  if actions then
    if actions.size then
      local k = setScale(getScale() + actions.size)
      local ww, hh = windowSize(k)
      gfx.init("", ww, hh)                  -- the card grows / shrinks right away
      say(("size %d%%: tools follow next time they open"):format(math.floor(k * 100 + 0.5)))
    elseif actions.letter then
      r.SetExtState(SEC, "lettering", actions.letter, true)
      say(actions.letter == "clean" and "clean lettering: sharper small text" or "typewriter lettering")
    elseif actions.clearSpeed then
      if r.ShowMessageBox("Clear every custom dial (5-9) on Reception?", "Munder Difflin", 4) == 6 then
        for _, n in ipairs(SPEED_HOLES) do
          r.DeleteExtState(SEC, "speed" .. n .. "_cmd", true)
          r.DeleteExtState(SEC, "speed" .. n .. "_label", true)
        end
        say("custom dials cleared")
      end
      M.prev = false
    elseif actions.resetWin then
      for _, sec in ipairs(TOOL_SECS) do
        r.DeleteExtState(sec, "wx", true); r.DeleteExtState(sec, "wy", true); r.DeleteExtState(sec, "dock", true)
      end
      say("windows will open in the default spot")
    end
  end

  M.prev = M.down
  gfx.update()
  r.defer(loop)
end

---------------------------------------------------------------- open
do
  local mx_, my_ = r.GetMousePosition()
  local k = getScale()
  local ww, hh = math.floor(W * BASE * k + 0.5), math.floor(H * BASE * k + 0.5)
  gfx.ext_retina = 1
  gfx.init("Munder Difflin", ww, hh, 0, math.floor(mx_ - ww / 2), math.floor(my_ - hh / 2))
  local ww2, hh2 = windowSize(k)
  if ww2 ~= ww and gfx.w > 0 and gfx.w < ww2 * 0.9 then gfx.init("", ww2, hh2) end
end
loop()
