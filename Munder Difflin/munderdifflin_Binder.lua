-- @description Binder
-- @author Byungkyu Lee
-- @version 2.5
-- @changelog Binder folder can be moved (FOLDER in the header)
-- @about Your filing system for track templates, FX chains and audio snippets.
--   Shows everything in REAPER's TrackTemplates / FXChains folders as LOOSE PAPERS,
--   lets you file them into your own binders and tabs (references only, nothing moves),
--   and drag them straight onto tracks. Selected items are filed as audio copies.
--   The filing (index) is saved in <resource>/Binder and can be exported / imported.

local r = reaper
local SEC, TOOL = "BK_Binder", "Binder"
local W, H = 440, 650
local P = { sort = 1, showhidden = false, loosepage = 1 }
local LIM, Q, QF, NAMES = {}, {}, {}, {}
local HELP = {
  "ATTACHMENT 1 OF 1",
  "Re: How to use the Binder",
  "",
  "BINDER > TAB > SECTION > paper.",
  "ALL shows REAPER's own folders as-is.",
  "Your binders only hold references.",
  "",
  "DRAG paper -> binder / tab / section .. file",
  "DRAG paper -> paper ........... reorder",
  "DRAG paper -> REAPER track .... use it",
  "DOUBLE-CLICK ........ use on selection",
  "SHIFT / CTRL-CLICK ... select many",
  "RIGHT-CLICK .......... do things to them",
  "FILE IT .. items -> audio, tracks -> TT/FX",
  "DROP files from anywhere .... saved here",
  "CTRL+Z undo   CTRL+F search   CTRL+A all",
  "FOLDER ......... where Binder keeps its files",
  "DEL .................. shred selection",
  "SPACE / click wave .... listen (audio)",
  "",
  "Shredded files wait in Binder/_Shredded.",
  "Undo works. Like a real office. It does not.",
}
local FONT_UP = 1     -- +1 pt on every text size
local UI_SCALE = tonumber(reaper.GetExtState("BK_Office", "ui_scale")) or 1.265  -- set on the Munder Difflin card
local TOOL_FRAME, TOOL_INFO, TOOL_ACTION, TOOL_POST, TOOL_KEY, TOOL_THEME
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

---------------------------------------------------------------- paths
local IS_WIN = r.GetOS():match("Win") ~= nil
local SEP = IS_WIN and "\\" or "/"
local RES = r.GetResourcePath()
local function J(...) return table.concat({ ... }, SEP) end
local BINDIR = J(RES, "Binder")
local INDEX  = J(BINDIR, "binder_index.txt")
local ROOT = { tt = J(RES, "TrackTemplates"), fx = J(RES, "FXChains"), au = J(BINDIR, "Audio") }
local EXT = {
  tt = { rtracktemplate = true },
  fx = { rfxchain = true },
  au = { wav = true, flac = true, mp3 = true, ogg = true, aif = true, aiff = true, opus = true },
}

local function trim(s) return s:match("^%s*(.-)%s*$") end
local function clean(s) return (trim(s):gsub("|", "/")) end
local function sanitize(s) return (trim(s):gsub('[\\/:%*%?"<>|]', "_")) end
local function fullPath(e) return ROOT[e.type] .. SEP .. e.path:gsub("/", SEP) end
local function exists(p) return r.file_exists(p) end

local function splitLines(s)
  local t = {}
  s = s:gsub("\r", "")
  for l in (s .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end
  return t
end

local function uniqueName(dir, base, ext)
  local name, n = base .. ext, 2
  while exists(dir .. SEP .. name) do name = ("%s %d%s"):format(base, n, ext); n = n + 1 end
  return name
end

local function readFile(p) local f = io.open(p, "rb"); if not f then return nil end; local s = f:read("a"); f:close(); return s end
local function writeFile(p, s) local f = io.open(p, "wb"); if not f then return false end; f:write(s); f:close(); return true end

---------------------------------------------------------------- loose papers (scan)
local loose = { tt = {}, fx = {}, au = {} }

local function scan(t)
  local out = {}
  local function walk(dir, rel)
    r.EnumerateFiles(dir, -1)
    r.EnumerateSubdirectories(dir, -1)
    local i = 0
    while true do
      local f = r.EnumerateFiles(dir, i); if not f then break end
      local ext = (f:match("%.([^%.]+)$") or ""):lower()
      if EXT[t][ext] then out[#out + 1] = { type = t, path = rel == "" and f or (rel .. "/" .. f) } end
      i = i + 1
    end
    i = 0
    while true do
      local d = r.EnumerateSubdirectories(dir, i); if not d then break end
      walk(dir .. SEP .. d, rel == "" and d or (rel .. "/" .. d))
      i = i + 1
    end
  end
  walk(ROOT[t], "")
  table.sort(out, function(a, b) return a.path:lower() < b.path:lower() end)
  return out
end

local function refreshLoose()
  loose = { tt = scan("tt"), fx = scan("fx"), au = scan("au") }
end

---------------------------------------------------------------- index (your filing)
-- binders = { { name, color, tabs = { { name, sections = { {name, open} }, entries = { {type, path, label, sec} } } } } }
local binders = {}
local hidden = {}     -- ["tt:path"] = true   (hidden from LOOSE only)

local function hkey(e) return e.type .. ":" .. e.path end
local function newTab(name) return { name = name, sections = {}, entries = {} } end

local function deepCopy(v)
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = deepCopy(x) end
  return o
end

local function serialize(list, hid)
  local o = { "BINDER INDEX 2" }
  local hk = {}
  for k in pairs(hid) do hk[#hk + 1] = k end
  table.sort(hk)
  for _, k in ipairs(hk) do
    local t, p = k:match("^(%w+):(.*)$")
    if t then o[#o + 1] = ("H|%s|%s"):format(t, p) end
  end
  for _, b in ipairs(list) do
    o[#o + 1] = ("B|%s|%d"):format(b.name, b.color)
    for _, t in ipairs(b.tabs) do
      o[#o + 1] = ("T|%s|%d|%d"):format(t.name, t.color or 0, t.page or 0)
      for _, s in ipairs(t.sections) do o[#o + 1] = ("S|%s|%d"):format(s.name, s.open and 1 or 0) end
      for _, e in ipairs(t.entries) do
        o[#o + 1] = ("E|%s|%s|%s|%s"):format(e.type, e.path, e.label or "", e.sec or "")
      end
    end
  end
  return table.concat(o, "\n") .. "\n"
end

local function parse(text)
  if not text or not text:match("^BINDER INDEX") then return nil end
  local out, hid, b, t = {}, {}, nil, nil
  for _, line in ipairs(splitLines(text)) do
    local f = {}
    for p in (line .. "|"):gmatch("([^|]*)|") do f[#f + 1] = p end
    if f[1] == "H" and ROOT[f[2] or ""] and f[3] and f[3] ~= "" then
      hid[f[2] .. ":" .. f[3]] = true
    elseif f[1] == "B" and f[2] then
      b = { name = f[2], color = tonumber(f[3]) or 1, tabs = {} }; out[#out + 1] = b; t = nil
    elseif f[1] == "T" and b then
      t = newTab(f[2] or "TAB"); b.tabs[#b.tabs + 1] = t
      local c, pg = tonumber(f[3] or ""), tonumber(f[4] or "")
      if c and c > 0 then t.color = c end
      if pg and pg > 0 then t.page = pg end
    elseif f[1] == "S" and t and f[2] and f[2] ~= "" then
      t.sections[#t.sections + 1] = { name = f[2], open = f[3] ~= "0" }
    elseif f[1] == "E" and t and ROOT[f[2] or ""] and f[3] and f[3] ~= "" then
      t.entries[#t.entries + 1] = { type = f[2], path = f[3],
        label = (f[4] and f[4] ~= "") and f[4] or nil, sec = (f[5] and f[5] ~= "") and f[5] or nil }
    end
  end
  -- entries pointing at a section that does not exist become unsectioned
  for _, bb in ipairs(out) do for _, tt in ipairs(bb.tabs) do
    local have = {}
    for _, s in ipairs(tt.sections) do have[s.name] = true end
    for _, e in ipairs(tt.entries) do if e.sec and not have[e.sec] then e.sec = nil end end
  end end
  return out, hid
end

-- undo: every saveIndex() pushes the previous state + the file operations done since
local undoStack, pendingFiles, lastState = {}, {}, nil
local function logFile(op, a, b) pendingFiles[#pendingFiles + 1] = { op = op, a = a, b = b } end

local function saveIndex(path)
  r.RecursiveCreateDirectory(BINDIR, 0)
  local now = serialize(binders, hidden)
  if path then return writeFile(path, now) end
  if lastState and (now ~= lastState or #pendingFiles > 0) then
    undoStack[#undoStack + 1] = { index = lastState, files = pendingFiles }
    if #undoStack > 60 then table.remove(undoStack, 1) end
  end
  pendingFiles, lastState = {}, now
  return writeFile(INDEX, now)
end

-- view-only changes (folding) should not become undo steps
local function saveQuiet()
  lastState = serialize(binders, hidden)
  writeFile(INDEX, lastState)
end

local function undo()
  local u = table.remove(undoStack)
  if not u then return false end
  for i = #u.files, 1, -1 do
    local f = u.files[i]
    if f.op == "mv" then
      local d = f.a:match("^(.*)[/\\]")
      if d then r.RecursiveCreateDirectory(d, 0) end
      os.rename(f.b, f.a)
    elseif f.op == "new" then
      os.remove(f.a)
    end
  end
  local l, h = parse(u.index)
  binders, hidden = l or {}, h or {}
  lastState, pendingFiles = u.index, {}
  writeFile(INDEX, u.index)
  return true
end

local function loadIndex()
  local list, hid = parse(readFile(INDEX))
  binders, hidden = list or {}, hid or {}
  lastState = serialize(binders, hidden)
end

local function byName(list, name) for _, v in ipairs(list) do if v.name == name then return v end end end

local function addEntry(bi, ti, e, sec)
  local b = binders[bi]
  if #b.tabs == 0 then b.tabs[1] = newTab("GENERAL") end
  local t = b.tabs[ti] or b.tabs[1]
  for _, x in ipairs(t.entries) do if x.type == e.type and x.path == e.path then return false, t.name end end
  t.entries[#t.entries + 1] = { type = e.type, path = e.path, label = e.label, sec = sec }
  return true, t.name
end

local function merge(list, hid)
  for k in pairs(hid or {}) do hidden[k] = true end
  for _, ib in ipairs(list) do
    local b = byName(binders, ib.name)
    if not b then b = { name = ib.name, color = ib.color, tabs = {} }; binders[#binders + 1] = b end
    for _, it in ipairs(ib.tabs) do
      local t = byName(b.tabs, it.name)
      if not t then t = newTab(it.name); t.color, t.page = it.color, it.page; b.tabs[#b.tabs + 1] = t end
      for _, s in ipairs(it.sections) do
        if not byName(t.sections, s.name) then t.sections[#t.sections + 1] = { name = s.name, open = s.open } end
      end
      for _, e in ipairs(it.entries) do
        local dup = false
        for _, x in ipairs(t.entries) do if x.type == e.type and x.path == e.path then dup = true end end
        if not dup then t.entries[#t.entries + 1] = e end
      end
    end
  end
end

---------------------------------------------------------------- file operations
local function relSplit(path)
  local dir, file = path:match("^(.*)/([^/]+)$")
  if not dir then return "", path end
  return dir, file
end

local function cleanDir(s)
  local parts = {}
  for seg in (s:gsub("\\", "/")):gmatch("[^/]+") do
    seg = sanitize(seg)
    if seg ~= "" and seg ~= "." and seg ~= ".." then parts[#parts + 1] = seg end
  end
  return table.concat(parts, "/")
end

local function absDir(t, rel)
  if rel == "" then return ROOT[t] end
  return ROOT[t] .. SEP .. (rel:gsub("/", SEP))
end

local function forEachRef(fn)
  for _, b in ipairs(binders) do
    for _, t in ipairs(b.tabs) do
      for i = #t.entries, 1, -1 do fn(t.entries, i, t.entries[i]) end
    end
  end
end

local function repath(t, old, new)
  forEachRef(function(_, _, x) if x.type == t and x.path == old then x.path = new end end)
  if hidden[t .. ":" .. old] then hidden[t .. ":" .. old] = nil; hidden[t .. ":" .. new] = true end
end

-- rename and/or move a file; newDir/newBase nil = keep
local function moveFile(e, newDir, newBase)
  local dir, file = relSplit(e.path)
  local ext = file:match("(%.[^%.]+)$") or ""
  local base = newBase or file:sub(1, #file - #ext)
  newDir = newDir or dir
  if newDir == dir and base .. ext == file then return true end
  local adir = absDir(e.type, newDir)
  r.RecursiveCreateDirectory(adir, 0)
  local target = base .. ext
  if exists(adir .. SEP .. target) then target = uniqueName(adir, base, ext) end
  local from, to = fullPath(e), adir .. SEP .. target
  if not os.rename(from, to) then return false end
  logFile("mv", from, to)
  local newRel = newDir == "" and target or (newDir .. "/" .. target)
  local old = e.path
  repath(e.type, old, newRel)
  e.path = newRel
  return true
end

local function duplicateFile(e)
  local dir, file = relSplit(e.path)
  local ext = file:match("(%.[^%.]+)$") or ""
  local adir = absDir(e.type, dir)
  local target = uniqueName(adir, file:sub(1, #file - #ext) .. " copy", ext)
  local data = readFile(fullPath(e))
  if not data or not writeFile(adir .. SEP .. target, data) then return nil end
  logFile("new", adir .. SEP .. target)
  return { type = e.type, path = dir == "" and target or (dir .. "/" .. target) }
end

-- "delete" = into the shredder bin, so Ctrl+Z can bring it back
local TRASH = J(BINDIR, "_Shredded")
local function deleteFile(e)
  local src = fullPath(e)
  local _, file = relSplit(e.path)
  local dir = J(TRASH, e.type)
  r.RecursiveCreateDirectory(dir, 0)
  local dst, n = dir .. SEP .. os.date("%Y%m%d-%H%M%S_") .. file, 2
  while exists(dst) do dst = dir .. SEP .. os.date("%Y%m%d-%H%M%S_") .. n .. "_" .. file; n = n + 1 end
  if not os.rename(src, dst) then return false end
  logFile("mv", src, dst)
  local t, p = e.type, e.path
  forEachRef(function(list, i, x) if x.type == t and x.path == p then table.remove(list, i) end end)
  hidden[t .. ":" .. p] = nil
  return true
end

---------------------------------------------------------------- chunks
-- top-level <FXCHAIN ... > of a track chunk (line indices)
local function fxBlock(L)
  local depth, s = 0, nil
  for i, l in ipairs(L) do
    local tl = trim(l)
    if tl:sub(1, 1) == "<" then
      depth = depth + 1
      if depth == 2 and tl == "<FXCHAIN" then s = i end
    elseif tl == ">" then
      if s and depth == 2 then return s, i end
      depth = depth - 1
    end
  end
end

local function stripItems(chunk)
  local out, skip = {}, 0
  for _, l in ipairs(splitLines(chunk)) do
    local tl = trim(l)
    if skip > 0 then
      if tl:sub(1, 1) == "<" then skip = skip + 1 elseif tl == ">" then skip = skip - 1 end
    elseif tl:match("^<ITEM") then skip = 1
    elseif tl ~= "" then out[#out + 1] = l end
  end
  return table.concat(out, "\n")
end

local HEADER_KEYS = { WNDRECT = true, SHOW = true, LASTSEL = true, DOCKED = true }

local function extractChain(tr)
  local _, ch = r.GetTrackStateChunk(tr, "", false)
  local L = splitLines(ch)
  local s, e = fxBlock(L)
  if not s then return nil end
  local out, depth = {}, 0
  for i = s + 1, e - 1 do
    local tl = trim(L[i])
    local top = depth == 0
    if tl:sub(1, 1) == "<" then depth = depth + 1 elseif tl == ">" then depth = depth - 1 end
    local key = tl:match("^(%S+)")
    if tl ~= "" and not (top and HEADER_KEYS[key]) and key ~= "FXID" then out[#out + 1] = L[i] end
  end
  if #out == 0 then return nil end
  return table.concat(out, "\n")
end

-- split chain text into one block per plugin (each starts with a top-level BYPASS line)
local function chainSegments(text)
  local segs, cur, depth = {}, nil, 0
  for _, l in ipairs(splitLines(text)) do
    local tl = trim(l)
    if depth == 0 and tl:match("^BYPASS") then cur = {}; segs[#segs + 1] = cur end
    if cur and tl ~= "" then cur[#cur + 1] = l end
    if tl:sub(1, 1) == "<" then depth = depth + 1 elseif tl == ">" then depth = depth - 1 end
  end
  return segs
end

local function addChain(tr, text)
  local cl = {}
  for _, l in ipairs(splitLines(text)) do
    local tl = trim(l)
    if tl ~= "" and not tl:match("^FXID ") then cl[#cl + 1] = l end
  end
  if #cl == 0 then return false end
  local _, ch = r.GetTrackStateChunk(tr, "", false)
  local L = splitLines(ch)
  while #L > 0 and trim(L[#L]) == "" do table.remove(L) end
  local s, e = fxBlock(L)
  local out = {}
  if s then
    for i = 1, e - 1 do out[#out + 1] = L[i] end
    for _, l in ipairs(cl) do out[#out + 1] = l end
    for i = e, #L do out[#out + 1] = L[i] end
  else
    -- new FXCHAIN goes before the first item (or before the track's closing ">")
    local at, depth = #L, 0
    for i, l in ipairs(L) do
      local tl = trim(l)
      if tl:sub(1, 1) == "<" then
        depth = depth + 1
        if depth == 2 and tl:match("^<ITEM") then at = i; break end
      elseif tl == ">" then depth = depth - 1 end
    end
    for i = 1, at - 1 do out[#out + 1] = L[i] end
    for _, l in ipairs({ "<FXCHAIN", "SHOW 0", "LASTSEL 0", "DOCKED 0" }) do out[#out + 1] = l end
    for _, l in ipairs(cl) do out[#out + 1] = l end
    out[#out + 1] = ">"
    for i = at, #L do out[#out + 1] = L[i] end
  end
  return r.SetTrackStateChunk(tr, table.concat(out, "\n"), false)
end

-- selected tracks + every child of selected folders, in project order
local function selectedTrackSet()
  local idx, n = {}, r.CountTracks(0)
  for i = 0, r.CountSelectedTracks(0) - 1 do
    local tr = r.GetSelectedTrack(0, i)
    local k = math.floor(r.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")) - 1
    idx[k] = true
    if r.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1 then
      local depth, j = 1, k + 1
      while depth > 0 and j < n do
        idx[j] = true
        depth = depth + r.GetMediaTrackInfo_Value(r.GetTrack(0, j), "I_FOLDERDEPTH")
        j = j + 1
      end
    end
  end
  local list = {}
  for k in pairs(idx) do list[#list + 1] = k end
  table.sort(list)
  return list
end

---------------------------------------------------------------- audio copy (24-bit wav of the item as heard at take level)
local function writeWav(path, take, len)
  local src = r.GetMediaItemTake_Source(take)
  local sr = math.floor(r.GetMediaSourceSampleRate(src) or 0)
  if sr <= 0 then sr = 48000 end
  local ch = clamp(r.GetMediaSourceNumChannels(src) or 2, 1, 8)
  local frames = math.floor(len * sr + 0.5)
  local data = frames * ch * 3
  local pad = data % 2
  local f = io.open(path, "wb"); if not f then return false end
  f:write(string.pack("<c4I4c4c4I4I2I2I4I4I2I2c4I4",
    "RIFF", 36 + data + pad, "WAVE", "fmt ", 16, 1, ch, sr, sr * ch * 3, ch * 3, 24, "data", data))
  local acc = r.CreateTakeAudioAccessor(take)
  local t0 = r.GetAudioAccessorStartTime(acc)
  local block = 4096
  local buf = r.new_array(block * ch)
  local pack, pos = string.pack, 0
  while pos < frames do
    local n = math.min(block, frames - pos)
    buf.clear()
    r.GetAudioAccessorSamples(acc, sr, ch, t0 + pos / sr, n, buf)
    local parts = {}
    for i = 1, n * ch do
      local v = buf[i]
      if v > 1 then v = 1 elseif v < -1 then v = -1 end
      local q = math.floor(v * 8388607 + 0.5)
      if q < 0 then q = q + 16777216 end
      parts[i] = pack("<I3", q)
    end
    f:write(table.concat(parts))
    pos = pos + n
  end
  if pad == 1 then f:write("\0") end
  r.DestroyAudioAccessor(acc)
  f:close()
  return true
end

---------------------------------------------------------------- use a paper
local function entryName(e, full)
  if e.label and e.label ~= "" then return e.label end
  local p = full and e.path or (e.path:match("([^/]+)$") or e.path)
  return (p:gsub("%.[^%.]+$", ""))
end

-- tracks: list of target tracks (may be empty); pos: timeline position for audio (nil = edit cursor)
local function useEntry(e, tracks, pos)
  local fp = fullPath(e)
  if not exists(fp) then return say("that file is missing") end
  local name = entryName(e)
  r.Undo_BeginBlock()
  if e.type == "fx" then
    if #tracks == 0 then r.Undo_EndBlock("Binder", -1); return say("drop FX chains on a track") end
    local txt = readFile(fp) or ""
    local n = 0
    for _, tr in ipairs(tracks) do if addChain(tr, txt) then n = n + 1 end end
    say(("FX chain '%s' -> %d track%s"):format(name, n, n == 1 and "" or "s"))
  elseif e.type == "tt" then
    local anchor = tracks[1]
    local cnt = r.CountTracks(0)
    if not anchor and cnt > 0 then anchor = r.GetTrack(0, cnt - 1) end
    if anchor then r.SetOnlyTrackSelected(anchor) end
    r.Main_openProject(fp)
    say(("template '%s' inserted"):format(name))
  else
    local tr = tracks[1]
    if not tr then
      r.InsertTrackAtIndex(r.CountTracks(0), true)
      tr = r.GetTrack(0, r.CountTracks(0) - 1)
    end
    r.SetOnlyTrackSelected(tr)
    local cur = r.GetCursorPosition()
    if pos then r.SetEditCurPos(pos, false, false) end
    r.InsertMedia(fp, 0)
    r.SetEditCurPos(cur, false, false)
    say(("audio '%s' placed"):format(name))
  end
  r.Undo_EndBlock("Binder: use " .. name, -1)
  r.UpdateArrange()
end

local function selectedTracks()
  local t = {}
  for i = 0, r.CountSelectedTracks(0) - 1 do t[#t + 1] = r.GetSelectedTrack(0, i) end
  return t
end

-- drop at a screen point (outside the Binder window)
local function dropAt(e, sx, sy)
  local tr = r.GetTrackFromPoint(sx, sy)
  if tr == r.GetMasterTrack(0) and e.type ~= "fx" then tr = nil end
  local pos
  if e.type == "au" and r.BR_GetMouseCursorContext then
    r.BR_GetMouseCursorContext()
    local p = r.BR_GetMouseCursorContext_Position()
    if p and p >= 0 then pos = p end
  end
  useEntry(e, tr and { tr } or {}, pos)
end

local IS_MAC = r.GetOS():match("OSX") ~= nil or r.GetOS():match("mac") ~= nil
local LOCATE = IS_MAC and "Show in Finder" or (IS_WIN and "Show in Explorer" or "Show in folder")
local function locate(e)
  local fp = fullPath(e)
  if r.CF_LocateInExplorer then r.CF_LocateInExplorer(fp)
  elseif IS_MAC then os.execute('open -R "' .. fp .. '"')
  elseif IS_WIN then os.execute('explorer /select,"' .. fp .. '"')
  else r.ShowMessageBox(fp, "Binder", 0) end
end

local function emptyShredder()
  local n = 0
  local function walk(dir)
    r.EnumerateFiles(dir, -1); r.EnumerateSubdirectories(dir, -1)
    local files, i = {}, 0
    while true do local f = r.EnumerateFiles(dir, i); if not f then break end; files[#files + 1] = f; i = i + 1 end
    for _, f in ipairs(files) do if os.remove(dir .. SEP .. f) then n = n + 1 end end
    i = 0
    while true do local d = r.EnumerateSubdirectories(dir, i); if not d then break end; walk(dir .. SEP .. d); i = i + 1 end
  end
  walk(TRASH)
  undoStack = {}
  return n
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

local function BINDER_MAIN()
---------------------------------------------------------------- frame
local SPINE = {
  {0.80, 0.16, 0.14}, {0.13, 0.30, 0.70}, {0.12, 0.12, 0.13}, {0.10, 0.45, 0.30},
  {0.93, 0.93, 0.91}, {0.92, 0.55, 0.66}, {0.96, 0.80, 0.20}, {0.93, 0.47, 0.13},
}
local MANILA = {0.86, 0.76, 0.55}
local SHEET  = {0.99, 0.985, 0.97}
local SECBG  = {0.93, 0.92, 0.88}
local SPINE_NAMES = { "Red", "Blue", "Black", "Green", "White", "Pink", "Yellow", "Orange" }
local TINTS  = { {0.98, 0.85, 0.55}, {0.70, 0.85, 0.95}, {0.80, 0.92, 0.72}, {0.97, 0.75, 0.75},
                 {0.85, 0.80, 0.95}, {0.99, 0.72, 0.50}, {0.99, 0.99, 0.98}, {0.82, 0.82, 0.80} }
local TINT_NAMES = { "Yellow", "Blue", "Green", "Pink", "Lavender", "Orange", "White", "Grey" }
-- c = paper, rule = ruled lines
local PAGES = {
  { name = "White",        c = {0.99, 0.985, 0.97}, rule = {0.92, 0.91, 0.88} },
  { name = "Legal yellow", c = {0.99, 0.95, 0.66}, rule = {0.62, 0.74, 0.88} },
  { name = "Ivory",        c = {0.97, 0.94, 0.86}, rule = {0.86, 0.83, 0.76} },
  { name = "Legal white",  c = {0.99, 0.99, 0.98}, rule = {0.66, 0.78, 0.92} },
  { name = "Pastel blue",  c = {0.86, 0.92, 0.98}, rule = {0.62, 0.74, 0.88} },
  { name = "Pastel pink",  c = {0.99, 0.88, 0.90}, rule = {0.62, 0.74, 0.88} },
  { name = "Pastel green", c = {0.88, 0.96, 0.86}, rule = {0.62, 0.74, 0.88} },
  { name = "Orchid",       c = {0.93, 0.87, 0.97}, rule = {0.62, 0.74, 0.88} },
}
local THEME_B = { tints = deepCopy(TINTS), pages = deepCopy(PAGES), manila = { MANILA[1], MANILA[2], MANILA[3] } }
TOOL_THEME = function(dark)
  for i, t in ipairs(TINTS) do
    local s = THEME_B.tints[i]
    for c = 1, 3 do t[c] = dark and (0.08 + s[c] * 0.32) or s[c] end
  end
  for i, p in ipairs(PAGES) do
    local s = THEME_B.pages[i]
    for c = 1, 3 do
      p.c[c] = dark and (0.10 + s.c[c] * 0.12) or s.c[c]
      p.rule[c] = dark and (s.rule[c] * 0.42) or s.rule[c]
    end
  end
  for c = 1, 3 do MANILA[c] = dark and THEME_B.manila[c] * 0.62 or THEME_B.manila[c] end
end
local function tabTint(t, i) return TINTS[(t and t.color) or ((i - 1) % 5 + 1)] or TINTS[1] end
local LOOSE_TABS = { { "TEMPLATES", "tt" }, { "FX CHAINS", "fx" }, { "AUDIO", "au" } }
local MARK = { tt = "TT", fx = "FX", au = "~" }
local TORD = { tt = 1, fx = 2, au = 3 }
local SORTS = { "MANUAL", "A-Z", "Z-A", "TYPE" }

local SX, SY, SW, SH, SG = 24, 124, 26, 128, 4   -- shelf
local TY, TH = 262, 22                            -- tabs
local PY, PH = 284, 252                           -- page
local BARY = PY + 6                               -- search / sort bar
local LISTY = PY + 30                             -- first row
local ROWH = 19

local cur = { b = 0, t = 1 }
local shelfScroll, pageScroll = 0, 0
local drag, pending = nil, nil
local lastRow, lastRowT = nil, 0
local search, searchFocus = "", false
local jumpTo = nil
local looseOpen = {}            -- ["tt:dir"] = false when folded

local function pageStyle()
  if cur and cur.b > 0 then
    local b = binders[cur.b]
    local t = b and b.tabs[cur.t]
    return PAGES[(t and t.page) or 1] or PAGES[1]
  end
  return PAGES[P.loosepage or 1] or PAGES[1]
end

local function inside(x, y, w, h) return M.x >= sc(x) and M.x < sc(x + w) and M.y >= sc(y) and M.y < sc(y + h) end
local function lum(c) return 0.3 * c[1] + 0.59 * c[2] + 0.11 * c[3] end
local function outsideWindow() return M.x < 0 or M.y < 0 or M.x >= gfx.w or M.y >= gfx.h end

local function fit(s, maxw, sz, bold)
  font(sz, bold)
  if gfx.measurestr(s) / S <= maxw then return s end
  local n = utf8.len(s) or #s
  while n > 1 do
    n = n - 1
    local cut = s:sub(1, (utf8.offset(s, n + 1) or (#s + 1)) - 1) .. "..."
    if gfx.measurestr(cut) / S <= maxw then return cut end
  end
  return "..."
end

local function openBinder(id) cur.b, cur.t, pageScroll = id, 1, 0 end

local function curTab()
  if cur.b == 0 then return nil end
  local b = binders[cur.b]
  if not b then cur.b = 0; return nil end
  if #b.tabs == 0 then b.tabs[1] = newTab("GENERAL"); cur.t = 1 end
  if not b.tabs[cur.t] then cur.t = 1 end
  return b.tabs[cur.t]
end

local function sorted(list, getE)
  local m = SORTS[P.sort] or "MANUAL"
  if m == "MANUAL" then return list end
  local c = {}
  for i, v in ipairs(list) do c[i] = v end
  table.sort(c, function(x, y)
    local a, b = getE(x), getE(y)
    local na, nb = entryName(a):lower(), entryName(b):lower()
    if m == "A-Z" then return na < nb end
    if m == "Z-A" then return na > nb end
    if a.type ~= b.type then return TORD[a.type] < TORD[b.type] end
    return na < nb
  end)
  return c
end

-- rows = { kind = "paper", e, sec, hint } | { kind = "sec", name, open, count }
local function buildRows()
  local rows = {}
  local q = search ~= "" and search:lower() or nil
  local function paper(e, sec, hint) rows[#rows + 1] = { kind = "paper", e = e, sec = sec, hint = hint } end

  if q then
    -- 1) sections (binder) / folders (LOOSE) whose name matches: header + its papers
    local shown = {}
    if cur.b == 0 then
      for li, lt in ipairs(LOOSE_TABS) do
        local groups, order = {}, {}
        for _, e in ipairs(loose[lt[2]]) do
          if P.showhidden or not hidden[hkey(e)] then
            local d = relSplit(e.path)
            if d ~= "" and d:lower():find(q, 1, true) then
              if not groups[d] then groups[d] = {}; order[#order + 1] = d end
              table.insert(groups[d], e)
            end
          end
        end
        table.sort(order, function(a, b) return a:lower() < b:lower() end)
        for _, d in ipairs(order) do
          rows[#rows + 1] = { kind = "sec", name = d, open = true, count = #groups[d], hint = lt[1], jump = { t = li, name = d } }
          for _, e in ipairs(sorted(groups[d], function(v) return v end)) do shown[e] = true; paper(e, d) end
        end
      end
    else
      for ti, t in ipairs(binders[cur.b].tabs) do
        for _, sc_ in ipairs(t.sections) do
          if sc_.name:lower():find(q, 1, true) then
            local list = {}
            for _, e in ipairs(t.entries) do if e.sec == sc_.name then list[#list + 1] = e end end
            rows[#rows + 1] = { kind = "sec", name = sc_.name, open = true, count = #list, hint = t.name, jump = { t = ti, name = sc_.name, ref = sc_ } }
            for _, e in ipairs(sorted(list, function(v) return v end)) do shown[e] = true; paper(e, sc_.name) end
          end
        end
      end
    end
    -- 2) papers whose name matches (not already listed under a section above)
    local pool = {}
    if cur.b == 0 then
      for _, lt in ipairs(LOOSE_TABS) do
        for _, e in ipairs(loose[lt[2]]) do
          if P.showhidden or not hidden[hkey(e)] then pool[#pool + 1] = { e = e, hint = lt[1] } end
        end
      end
    else
      for _, t in ipairs(binders[cur.b].tabs) do
        for _, e in ipairs(t.entries) do pool[#pool + 1] = { e = e, hint = t.name .. (e.sec and (" / " .. e.sec) or "") } end
      end
    end
    local hits = {}
    for _, x in ipairs(pool) do
      if not shown[x.e] and (entryName(x.e, true):lower():find(q, 1, true) or (x.e.label and x.e.label:lower():find(q, 1, true))) then
        hits[#hits + 1] = x
      end
    end
    for _, x in ipairs(sorted(hits, function(v) return v.e end)) do paper(x.e, nil, x.hint) end
    return rows
  end

  if cur.b == 0 then
    local ty = LOOSE_TABS[cur.t][2]
    local root, dirs, order = {}, {}, {}
    for _, e in ipairs(loose[ty]) do
      if P.showhidden or not hidden[hkey(e)] then
        local dir = relSplit(e.path)
        if dir == "" then root[#root + 1] = e
        else
          if not dirs[dir] then dirs[dir] = {}; order[#order + 1] = dir end
          table.insert(dirs[dir], e)
        end
      end
    end
    table.sort(order, function(a, b) return a:lower() < b:lower() end)
    for _, e in ipairs(sorted(root, function(v) return v end)) do paper(e, nil) end
    for _, d in ipairs(order) do
      local open = looseOpen[ty .. ":" .. d] ~= false
      rows[#rows + 1] = { kind = "sec", name = d, open = open, count = #dirs[d] }
      if open then for _, e in ipairs(sorted(dirs[d], function(v) return v end)) do paper(e, d) end end
    end
    return rows
  end

  local t = curTab()
  if not t then return rows end
  local root, by = {}, {}
  for _, s in ipairs(t.sections) do by[s.name] = {} end
  for _, e in ipairs(t.entries) do
    if e.sec and by[e.sec] then table.insert(by[e.sec], e) else root[#root + 1] = e end
  end
  for _, e in ipairs(sorted(root, function(v) return v end)) do paper(e, nil) end
  for _, s in ipairs(t.sections) do
    rows[#rows + 1] = { kind = "sec", name = s.name, open = s.open, count = #by[s.name], ref = s }
    if s.open then for _, e in ipairs(sorted(by[s.name], function(v) return v end)) do paper(e, s.name) end end
  end
  return rows
end

---------------------------------------------------------------- shelf
local function spines()
  local list, n = {}, #binders + 2
  local vis = math.floor((W - 48 + SG) / (SW + SG))
  shelfScroll = clamp(shelfScroll, 0, math.max(0, n - vis))
  for i = 1 + shelfScroll, math.min(n, shelfScroll + vis) do
    local id = (i == 1) and 0 or ((i == n) and "+" or i - 1)
    list[#list + 1] = { id = id, x = SX + (i - 1 - shelfScroll) * (SW + SG) }
  end
  return list
end

local function drawSpine(sp)
  local x, w, h = sp.x, SW, SH
  if sp.id == "+" then
    col(LINE)
    for yy = SY, SY + h - 3, 6 do gfx.rect(sc(x), sc(yy), math.max(1, sc(1)), sc(3), 1); gfx.rect(sc(x + w) - 1, sc(yy), math.max(1, sc(1)), sc(3), 1) end
    for xx = x, x + w - 3, 6 do gfx.rect(sc(xx), sc(SY), sc(3), math.max(1, sc(1)), 1); gfx.rect(sc(xx), sc(SY + h) - 1, sc(3), math.max(1, sc(1)), 1) end
    text("+", x + w / 2, SY + h / 2 - 9, 16, (not helpOpen and inside(x, SY, w, h)) and RED or DIM, "c")
    return
  end
  local c = sp.id == 0 and MANILA or SPINE[binders[sp.id].color] or SPINE[1]
  local name = sp.id == 0 and "ALL" or binders[sp.id].name
  local y = (sp.id == cur.b) and SY - 7 or SY
  col(INK, 0.15); gfx.rect(sc(x + 2), sc(y + 3), sc(w), sc(h), 1)
  col(c); gfx.rect(sc(x), sc(y), sc(w), sc(h), 1)
  if lum(c) > 0.8 then col(LINE); gfx.rect(sc(x), sc(y), sc(w), sc(h), 0) end
  col(PAPER); gfx.rect(sc(x + 4), sc(y + 8), sc(w - 8), sc(h - 34), 1)
  local step = 11 + (FONT_UP or 0)
  local ly, maxc, k = y + 12, math.floor((h - 44) / step), 0
  for _, cp in utf8.codes(name:upper()) do
    k = k + 1
    if k > maxc then break end
    text(utf8.char(cp), x + w / 2, ly, 10, INK, "c", 0, true)
    ly = ly + step
  end
  col(INK, 0.35); gfx.circle(sc(x + w / 2), sc(y + h - 13), sc(5), 1, 1)
  if drag and drag.active and sp.id ~= 0 and inside(x, y, w, h) then
    col(RED); gfx.rect(sc(x) - 2, sc(y) - 2, sc(w) + 4, sc(h) + 4, 0)
  end
end

---------------------------------------------------------------- tabs
local function tabs()
  local labels = {}
  if cur.b == 0 then
    for i, t in ipairs(LOOSE_TABS) do labels[i] = t[1] end
  else
    curTab()
    for i, t in ipairs(binders[cur.b].tabs) do labels[i] = t.name end
    labels[#labels + 1] = "+"
  end
  local out, x = {}, 24
  for i, l in ipairs(labels) do
    local lab = fit(l, 120, 10, true)
    font(10, true)
    local w = math.floor(gfx.measurestr(lab) / S) + 18
    if x + w > W - 24 then break end
    out[#out + 1] = { i = i, label = lab, x = x, w = w, plus = (cur.b > 0 and i == #labels) }
    x = x + w + 2
  end
  return out
end

local function drawTab(tb)
  local sel = (not tb.plus) and tb.i == cur.t
  local c = tb.plus and PAPER or tabTint(cur.b > 0 and binders[cur.b].tabs[tb.i] or nil, tb.i)
  local y = sel and TY or TY + 4
  col(c); gfx.rect(sc(tb.x), sc(y), sc(tb.w), sc(TY + TH - y + (sel and 1 or 0)), 1)
  col(LINE); gfx.rect(sc(tb.x), sc(y), sc(tb.w), sc(TY + TH - y), 0)
  if drag and drag.active and cur.b > 0 and not tb.plus and inside(tb.x, y, tb.w, TH) then
    col(RED); gfx.rect(sc(tb.x) - 1, sc(y) - 1, sc(tb.w) + 2, sc(TY + TH - y) + 2, 0)
  end
  text(tb.label, tb.x + tb.w / 2, y + 5, 10, sel and INK or DIM, "c", 0, true)
end

---------------------------------------------------------------- selection
local sel, anchor, viewKey = {}, nil, ""
local lastRows = {}
local SELC = {0.13, 0.22, 0.46}

local function clearSel() sel, anchor = {}, nil end
local function selList(rows)
  local out = {}
  for _, row in ipairs(rows or lastRows) do if row.kind == "paper" and sel[row.e] then out[#out + 1] = row.e end end
  return out
end

---------------------------------------------------------------- waveform strip
local WH = 50
local function waveTarget(rows)
  local list = selList(rows)
  if #list == 1 and list[1].type == "au" then return list[1] end
end
local waveCache, waveOrder = {}, {}

local function loadWave(fp)
  if waveCache[fp] then return waveCache[fp] end
  local w = { ok = false }
  local src = exists(fp) and r.PCM_Source_CreateFromFile(fp)
  if src then
    local len = r.GetMediaSourceLength(src)
    local ch = clamp(math.floor(r.GetMediaSourceNumChannels(src) or 1), 1, 8)
    local sr = r.GetMediaSourceSampleRate(src)
    if r.PCM_Source_BuildPeaks(src, 0) ~= 0 then
      local guard = 0
      while r.PCM_Source_BuildPeaks(src, 1) ~= 0 and guard < 200000 do guard = guard + 1 end
      r.PCM_Source_BuildPeaks(src, 2)
    end
    local n = 360
    local buf = r.new_array(n * ch * 2)
    local rv = r.PCM_Source_GetPeaks(src, n / math.max(len, 0.001), 0, ch, n, 0, buf)
    local cnt = math.floor(rv or 0) & 0xFFFFF
    if cnt > 1 then
      local hi, lo, pk = {}, {}, 0
      for i = 0, cnt - 1 do
        local a, b = -1, 1
        for c = 1, ch do
          local mx, mn = buf[i * ch + c], buf[n * ch + i * ch + c]
          if mx > a then a = mx end
          if mn < b then b = mn end
        end
        hi[i + 1], lo[i + 1] = a, b
        pk = math.max(pk, math.abs(a), math.abs(b))
      end
      w = { ok = true, hi = hi, lo = lo, n = cnt, len = len, ch = ch, sr = sr, peak = pk }
    end
    r.PCM_Source_Destroy(src)
  end
  waveCache[fp] = w
  waveOrder[#waveOrder + 1] = fp
  if #waveOrder > 24 then waveCache[table.remove(waveOrder, 1)] = nil end
  return w
end

---------------------------------------------------------------- preview playback
local HAS_CF = r.CF_CreatePreview ~= nil
local prev = {}            -- { h, src, path, len }
local waveUI = {}          -- hit areas of the strip, refreshed every frame

local function stopPreview()
  if prev.h then r.CF_Preview_Stop(prev.h) end
  if prev.src then r.PCM_Source_Destroy(prev.src) end
  prev = {}
end

local function previewPos()
  if not prev.h then return nil end
  local ok, pos = r.CF_Preview_GetValue(prev.h, "D_POSITION")
  if not ok or (prev.len and pos >= prev.len - 0.005) then stopPreview(); return nil end
  return pos
end

local function playPreview(fp, pos)
  if not HAS_CF then
    if r.OpenMediaExplorer then r.OpenMediaExplorer(fp, true) end
    return
  end
  if prev.h and prev.path == fp and pos then
    r.CF_Preview_SetValue(prev.h, "D_POSITION", pos); return
  end
  stopPreview()
  local src = r.PCM_Source_CreateFromFile(fp)
  if not src then return say("can't play this one") end
  local h = r.CF_CreatePreview(src)
  if not h then r.PCM_Source_Destroy(src); return end
  if pos then r.CF_Preview_SetValue(h, "D_POSITION", pos) end
  r.CF_Preview_Play(h)
  prev = { h = h, src = src, path = fp, len = r.GetMediaSourceLength(src) }
end

local function togglePreview(e)
  local fp = fullPath(e)
  if prev.h and prev.path == fp then stopPreview() else playPreview(fp, nil) end
end

r.atexit(function() if prev.h then stopPreview() end end)

local function drawWave(e)
  local ps = pageStyle()
  local WY = PY + PH - WH - 3
  col({ ps.c[1] * 0.95, ps.c[2] * 0.95, ps.c[3] * 0.95 }); gfx.rect(sc(56), sc(WY), sc(W - 84), sc(WH), 1)
  hline(56, WY, W - 84, 1, LINE)
  local fp = fullPath(e)
  local w = loadWave(fp)
  local playing = prev.h and prev.path == fp
  local pos = playing and previewPos() or nil
  if playing and not pos then playing = false end
  -- play / stop button
  local bx, by = 62, WY + 22
  local bh = not helpOpen and inside(bx - 4, by - 10, 22, 22)
  col(bh and RED or INK)
  if playing then gfx.rect(sc(bx), sc(by - 6), sc(12), sc(12), 1)
  else gfx.triangle(sc(bx), sc(by - 7), sc(bx), sc(by + 7), sc(bx + 12), sc(by)) end
  waveUI = { e = e, fp = fp, len = w.len, btn = { x = bx - 4, y = by - 10, w = 22, h = 22 } }
  text(fit(entryName(e), 150, 8), 84, WY + 3, 8, INK)
  if not w.ok then text("can't read this one", W / 2 + 14, WY + WH / 2 - 4, 9, RED, "c"); return end
  local info = ("%.2f s  %d kHz  %d ch  peak %.1f dB"):format(w.len, math.floor((w.sr or 0) / 1000 + 0.5), w.ch,
               w.peak > 0 and 20 * math.log(w.peak, 10) or -150)
  text(info, W - 34, WY + 3, 8, DIM, "r")
  local x0, x1 = 84, W - 34
  waveUI.area = { x = x0, y = WY + 12, w = x1 - x0, h = WH - 14 }
  local cy, amp = WY + 12 + (WH - 14) / 2, (WH - 16) / 2
  hline(x0, cy, x1 - x0, 1, LINE)
  col(NAVY)
  for i = 1, w.n do
    local x = sc(x0 + (i - 1) / (w.n - 1) * (x1 - x0))
    gfx.line(x, sc(cy - w.hi[i] * amp), x, sc(cy - w.lo[i] * amp), 0)
  end
  if pos and w.len and w.len > 0 then
    local px = x0 + clamp(pos / w.len, 0, 1) * (x1 - x0)
    hline(px, WY + 12, 1, WH - 14, RED)
  end
  if not HAS_CF then text("plays in Media Explorer (SWS: plays here)", W - 34, WY + WH - 11, 7, DIM, "r") end
end

---------------------------------------------------------------- page
local bar = {}

local function drawBar()
  local can = not helpOpen
  local sl = "SORT " .. (SORTS[P.sort] or "MANUAL")
  font(9); local sw = gfx.measurestr(sl) / S
  local secw = 0
  if cur.b > 0 and search == "" then font(9); secw = gfx.measurestr("+ SECTION") / S + 12 end
  local bx, bw = 60, W - 32 - 60 - sw - 12 - secw
  bar.search = { x = bx, y = BARY, w = bw, h = 18 }
  bar.sort = { x = bx + bw + 10, y = BARY, w = sw, h = 18 }
  bar.sec = secw > 0 and { x = bx + bw + 10 + sw + 12, y = BARY, w = secw - 12, h = 18 } or nil

  col(PAPER); gfx.rect(sc(bx), sc(BARY), sc(bw), sc(18), 1)
  col(searchFocus and NAVY or LINE); gfx.rect(sc(bx), sc(BARY), sc(bw), sc(18), 0)
  if search == "" and not searchFocus then
    text(cur.b == 0 and "search everything" or "search this binder", bx + 6, BARY + 4, 9, DIM)
  else
    local shown = search
    font(10)
    while gfx.measurestr(shown) / S > bw - 16 and #shown > 0 do shown = shown:sub((utf8.offset(shown, 2) or 2)) end
    local tw = text(shown, bx + 6, BARY + 3, 10, NAVY)
    if searchFocus and (r.time_precise() % 1) < 0.55 then hline(bx + 7 + tw, BARY + 3, 1, 12, NAVY) end
  end
  if search ~= "" then text("x", bx + bw - 8, BARY + 3, 10, (can and inside(bx + bw - 14, BARY, 14, 18)) and RED or DIM, "c") end
  text(sl, bar.sort.x, BARY + 4, 9, (can and inside(bar.sort.x, BARY, sw, 18)) and RED or DIM)
  if bar.sec then text("+ SECTION", bar.sec.x, BARY + 4, 9, (can and inside(bar.sec.x, BARY, bar.sec.w, 18)) and RED or DIM) end
end

local function drawPage(rows)
  local ps = pageStyle()
  col(ps.c); gfx.rect(sc(24), sc(PY), sc(W - 48), sc(PH), 1)
  col(LINE); gfx.rect(sc(24), sc(PY), sc(W - 48), sc(PH), 0)
  col(RED, 0.45); gfx.rect(sc(52), sc(PY), math.max(1, sc(1)), sc(PH), 1)
  for _, hy in ipairs({ PY + 34, PY + PH / 2, PY + PH - 34 }) do
    col(PAPER); gfx.circle(sc(38), sc(hy), sc(5), 1, 1)
    col(LINE); gfx.circle(sc(38), sc(hy), sc(5), 0, 1)
  end
  drawBar()

  local waveE = waveTarget(rows)
  local bottom = waveE and (PY + PH - WH - 6) or (PY + PH - 6)
  local vis = math.floor((bottom - LISTY) / ROWH)
  pageScroll = clamp(pageScroll, 0, math.max(0, #rows - vis))
  if #rows == 0 then
    local msg
    if search ~= "" then msg = "Nothing found. Not even in the annex."
    elseif cur.b == 0 then
      msg = LOOSE_TABS[cur.t][2] == "au" and "No audio filed yet. Select items, FILE IT." or "Nothing in this REAPER folder yet."
    else msg = "Empty tab. Drag papers here, or FILE IT." end
    text(msg, 64, LISTY + 4, 10, DIM)
  end

  local hovered
  local dragging = drag and drag.active
  for k = 1, vis do
    local i = k + pageScroll
    local row = rows[i]
    if not row then break end
    local y = LISTY + (k - 1) * ROWH
    local hov = not helpOpen and inside(56, y, W - 84, ROWH)
    if hov then hovered = i end
    if row.kind == "sec" then
      col({ ps.c[1] * 0.93, ps.c[2] * 0.93, ps.c[3] * 0.93 }); gfx.rect(sc(56), sc(y + 1), sc(W - 84), sc(ROWH - 2), 1)
      if hov and dragging then col(RED); gfx.rect(sc(56), sc(y + 1), sc(W - 84), sc(ROWH - 2), 0) end
      text(row.open and "v" or ">", 62, y + 3, 10, DIM, nil, 0, true)
      local nm = fit(row.name:upper(), W - 84 - 70 - (row.hint and 110 or 0), 10, true)
      local nw = text(nm, 76, y + 4, 10, hov and RED or INK, nil, 0, true)
      text(("(%d)"):format(row.count), 82 + nw, y + 4, 9, DIM)
      if row.hint then text(fit(row.hint, 110, 9), W - 32, y + 4, 9, DIM, "r") end
    else
      local e = row.e
      local ind = row.sec and 12 or 0
      local isSel = sel[e]
      if isSel then col(NAVY, dragging and 0.10 or (THEMEX.dark and 0.22 or 0.16)); gfx.rect(sc(56), sc(y), sc(W - 84), sc(ROWH), 1)
      elseif hov and not dragging then col(NOTE, THEMEX.dark and 0.14 or 0.55); gfx.rect(sc(56), sc(y), sc(W - 84), sc(ROWH), 1) end
      if hov and dragging and not sel[e] then hline(56, y, W - 84, 2, RED) end
      if isSel then hline(56, y, 2, ROWH, NAVY) end
      local missing = not exists(fullPath(e))
      local isHidden = hidden[hkey(e)]
      local tag = missing and "(missing)" or (isHidden and cur.b == 0 and "(hidden)") or row.hint
      local tagw = 0
      if tag then font(9); tagw = math.min(110, gfx.measurestr(tag) / S) + 8 end
      text(MARK[e.type], 62 + ind, y + 4, 9, DIM, nil, 1)
      local nm = fit(entryName(e, search ~= "" and cur.b == 0), W - 84 - 34 - ind - tagw, 11)
      text(nm, 88 + ind, y + 3, 11, (missing or isHidden) and DIM or (isSel and NAVY or INK))
      if tag then text(fit(tag, 110, 9), W - 32, y + 4, 9, missing and RED or DIM, "r") end
      hline(56, y + ROWH - 1, W - 84, 1, ps.rule)
    end
  end
  local n = 0; for _ in pairs(sel) do n = n + 1 end
  local foot = n > 1 and (n .. " selected") or nil
  if #rows > vis then
    local range = ("%d-%d / %d"):format(pageScroll + 1, math.min(#rows, pageScroll + vis), #rows)
    foot = foot and (foot .. "   " .. range) or range
  end
  if foot and not waveE then text(foot, W - 30, PY + PH - 12, 8, n > 1 and NAVY or DIM, "r") end
  if waveE then drawWave(waveE) end
  return hovered
end

---------------------------------------------------------------- helpers for actions
local function ask(caption, default)
  local ok, v = r.GetUserInputs(TOOL, 1, caption .. ",extrawidth=160", default or "")
  M.prev, active = false, nil
  if ok then v = clean(v); if v ~= "" then return v end end
end

local function menu(str)
  gfx.x, gfx.y = M.x, M.y
  local i = gfx.showmenu(str)
  M.prev, M.rprev, active = false, false, nil
  return i
end

local function menuSafe(s) return (s:gsub("[|]", "/"):gsub("^[!#<>]+", "")) end

local function pickFrom(list, label, current)
  local items = {}
  for i, v in ipairs(list) do items[i] = (i == current and "!" or "") .. label(v) end
  local c = menu(table.concat(items, "|"))
  if c and c > 0 then return c end
end

local function placeInTab(bi, ti, e, sec, before)
  local b = binders[bi]
  if #b.tabs == 0 then b.tabs[1] = newTab("GENERAL") end
  local t = b.tabs[ti] or b.tabs[1]
  local obj
  for i, x in ipairs(t.entries) do
    if x.type == e.type and x.path == e.path then obj = table.remove(t.entries, i); break end
  end
  obj = obj or { type = e.type, path = e.path, label = e.label }
  obj.sec = sec
  local at = #t.entries + 1
  if before then for i, x in ipairs(t.entries) do if x == before then at = i; break end end end
  table.insert(t.entries, at, obj)
  return t.name
end

local function removeFrom(bi, ti, e)
  local t = binders[bi] and binders[bi].tabs[ti]
  if not t then return end
  for i, x in ipairs(t.entries) do if x == e then table.remove(t.entries, i); return end end
end

local function changed() refreshLoose(); saveIndex() end

local function fileAudio()
  local dir, rel = ROOT.au, ""
  local t = curTab()
  if t then
    local b = binders[cur.b]
    rel = sanitize(b.name) .. "/" .. sanitize(t.name)
    dir = J(ROOT.au, sanitize(b.name), sanitize(t.name))
  end
  r.RecursiveCreateDirectory(dir, 0)
  local n = 0
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    local tk = r.GetActiveTake(it)
    if tk and not r.TakeIsMIDI(tk) then
      local _, nm = r.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)
      nm = sanitize((nm ~= "" and nm or "item"):gsub("%.%w+$", ""))
      if nm == "" then nm = "item" end
      local file = uniqueName(dir, nm, ".wav")
      if writeWav(dir .. SEP .. file, tk, r.GetMediaItemInfo_Value(it, "D_LENGTH")) then
        logFile("new", dir .. SEP .. file)
        n = n + 1
        if t then addEntry(cur.b, cur.t, { type = "au", path = (rel ~= "" and (rel .. "/") or "") .. file }) end
      end
    end
  end
  changed()
  if n == 0 then return say("no audio items selected") end
  say(("%d audio file%s filed%s"):format(n, n == 1 and "" or "s", t and (" in " .. t.name) or ""))
end

local function plural(n, w) return n .. " " .. w .. (n == 1 and "" or "s") end

---------------------------------------------------------------- files dropped onto the window (Finder, Explorer, samplers...)
local function takeDrops()
  local files, i = {}, 0
  while true do
    local ok, fn = gfx.getdropfile(i)
    if not ok or ok == 0 or not fn or fn == "" then break end
    files[#files + 1] = fn
    i = i + 1
  end
  if #files > 0 then gfx.getdropfile(-1) end
  return files
end

-- temp-looking names (tmp1234, GUIDs, hex) become "Capture yymmdd-hhmmss"
local function dropName(fn)
  local b = (fn:match("([^/\\]+)$") or ""):gsub("%.[^%.]+$", "")
  local low = b:lower()
  if b == "" or low:match("^te?mp") or low:match("^~") or (#b >= 8 and b:match("^[%x%-_{}]+$")) then
    return "Capture " .. os.date("%y%m%d-%H%M%S")
  end
  return sanitize(b)
end

local function fileDropped(files, bi, ti, sec)
  local t = bi > 0 and binders[bi] and (binders[bi].tabs[ti] or binders[bi].tabs[1]) or nil
  if bi > 0 and not t then binders[bi].tabs[1] = newTab("GENERAL"); t = binders[bi].tabs[1]; ti = 1 end
  local nA, nO, skipped = 0, 0, 0
  for _, fn in ipairs(files) do
    local ext = (fn:match("%.([^%.\\/]+)$") or ""):lower()
    local kind = EXT.au[ext] and "au" or (EXT.tt[ext] and "tt") or (EXT.fx[ext] and "fx") or nil
    local data = kind and readFile(fn)
    if not data then
      skipped = skipped + 1
    else
      local dir, rel = ROOT[kind], ""
      if kind == "au" and t then
        rel = sanitize(binders[bi].name) .. "/" .. sanitize(t.name)
        dir = J(ROOT.au, sanitize(binders[bi].name), sanitize(t.name))
      end
      r.RecursiveCreateDirectory(dir, 0)
      local file = uniqueName(dir, dropName(fn), "." .. (fn:match("%.([^%.\\/]+)$") or ext))
      if writeFile(dir .. SEP .. file, data) then
        logFile("new", dir .. SEP .. file)
        if kind == "au" then nA = nA + 1 else nO = nO + 1 end
        if t then placeInTab(bi, ti, { type = kind, path = (rel ~= "" and (rel .. "/") or "") .. file }, sec) end
      else
        skipped = skipped + 1
      end
    end
  end
  changed()
  local parts = {}
  if nA > 0 then parts[#parts + 1] = plural(nA, "audio file") end
  if nO > 0 then parts[#parts + 1] = plural(nO, "preset") end
  local where = t and (" in " .. t.name .. (sec and (" / " .. sec) or "")) or ""
  say(#parts > 0 and ("saved " .. table.concat(parts, " + ") .. where .. (skipped > 0 and ("  (" .. skipped .. " skipped)") or ""))
      or "nothing usable in that drop")
end

local function pickFX(tr)
  local n = r.TrackFX_GetCount(tr)
  local names, chk = {}, {}
  for i = 0, n - 1 do
    local _, nm = r.TrackFX_GetFXName(tr, i, "")
    names[i + 1] = menuSafe(nm ~= "" and nm or ("FX " .. (i + 1)))
    chk[i + 1] = true
  end
  if n <= 1 then return n == 1 and { 0 } or nil end
  while true do
    local items, k = {}, 0
    for i = 1, n do items[i] = (chk[i] and "!" or "") .. names[i]; if chk[i] then k = k + 1 end end
    items[n + 1] = ">> FILE " .. k .. " FX"
    items[n + 2] = "Cancel"
    local c = menu(table.concat(items, "|"))
    if c == 0 or c == n + 2 then return nil end
    if c == n + 1 then
      local out = {}
      for i = 1, n do if chk[i] then out[#out + 1] = i - 1 end end
      return #out > 0 and out or nil
    end
    chk[c] = not chk[c]
  end
end

local function fileTracks(kind)
  local trk = r.GetSelectedTrack(0, 0)
  local _, tname = r.GetSetMediaTrackInfo_String(trk, "P_NAME", "", false)
  local content, ext
  if kind == "tt" then
    local parts = {}
    for _, k in ipairs(selectedTrackSet()) do
      local _, ch = r.GetTrackStateChunk(r.GetTrack(0, k), "", false)
      parts[#parts + 1] = stripItems(ch)
    end
    content, ext = table.concat(parts, "\n") .. "\n", ".RTrackTemplate"
  else
    local chain = extractChain(trk)
    if not chain then return say("that track has no FX") end
    local pick = pickFX(trk)
    if not pick then return end
    local segs = chainSegments(chain)
    if #segs == r.TrackFX_GetCount(trk) then
      local keep = {}
      for _, i in ipairs(pick) do for _, l in ipairs(segs[i + 1]) do keep[#keep + 1] = l end end
      chain = table.concat(keep, "\n")
    end
    content, ext = chain .. "\n", ".RfxChain"
  end
  local name = ask(kind == "tt" and "Template name" or "FX chain name", tname ~= "" and tname or "Untitled")
  if not name then return end
  name = sanitize(name)
  r.RecursiveCreateDirectory(ROOT[kind], 0)
  local file = uniqueName(ROOT[kind], name, ext)
  if not writeFile(ROOT[kind] .. SEP .. file, content) then return say("could not write file") end
  logFile("new", ROOT[kind] .. SEP .. file)
  local t = curTab()
  if t then addEntry(cur.b, cur.t, { type = kind, path = file }) end
  changed()
  say(("%s '%s' filed%s"):format(kind == "tt" and "template" or "FX chain", name, t and (" in " .. t.name) or ""))
end

local exportIndex
exportIndex = function()
  local dir = J(BINDIR, "exports")
  r.RecursiveCreateDirectory(dir, 0)
  local file = "binder_index_" .. os.date("%Y%m%d-%H%M%S") .. ".txt"
  local full = dir .. SEP .. file
  if not saveIndex(full) then return say("export failed") end
  if r.CF_LocateInExplorer then r.CF_LocateInExplorer(full)
  elseif IS_MAC then os.execute('open -R "' .. full .. '"')
  elseif IS_WIN then os.execute('explorer /select,"' .. full .. '"')
  else r.ShowMessageBox("Exported to:\n" .. full, TOOL, 0) end
  say("exported: " .. file)
end

local function importIndex()
  local ok, fn = r.GetUserFileNameForRead(BINDIR, "Import Binder index", ".txt")
  M.prev, active = false, nil
  if not ok then return end
  local list, hid = parse(readFile(fn))
  if not list then return say("that is not a Binder index") end
  local a = r.ShowMessageBox("Merge with your current binders?\n\nYes = merge     No = replace", TOOL, 3)
  if a == 6 then merge(list, hid) elseif a == 7 then binders, hidden = list, hid or {} else return end
  openBinder(0); clearSel()
  saveIndex()
  say(("imported %d binder%s"):format(#list, #list == 1 and "" or "s"))
end

---------------------------------------------------------------- batch operations (list = entries)

local function opUse(list)
  local tr = selectedTracks()
  for _, e in ipairs(list) do useEntry(e, tr, nil) end
end

local function opDuplicate(list)
  local n, t = 0, cur.b > 0 and curTab() or nil
  for _, e in ipairs(list) do
    local d = duplicateFile(e)
    if d then
      n = n + 1
      if t then
        local at
        for j, x in ipairs(t.entries) do if x == e then at = j end end
        table.insert(t.entries, (at or #t.entries) + 1, { type = d.type, path = d.path, sec = e.sec })
      end
    end
  end
  changed(); clearSel()
  say("duplicated " .. plural(n, "file"))
end

local function opRename(list)
  if #list == 1 then
    local e = list[1]
    local _, file = relSplit(e.path)
    local nm = ask("New file name", (file:gsub("%.[^%.]+$", "")))
    if not nm then return end
    if moveFile(e, nil, sanitize(nm)) then changed(); say("renamed") else say("rename failed") end
    return
  end
  local base = ask(("Base name for %d files (-> name 01, 02...)"):format(#list), "")
  if not base then return end
  base = sanitize(base)
  local n = 0
  for i, e in ipairs(list) do if moveFile(e, nil, ("%s %02d"):format(base, i)) then n = n + 1 end end
  changed(); say("renamed " .. plural(n, "file"))
end

local function opMove(list)
  local dir = relSplit(list[1].path)
  local hasAudio = false
  for _, e in ipairs(list) do if e.type == "au" then hasAudio = true end end
  local ok, v = r.GetUserInputs(TOOL, 1, "Move to folder (a/b, empty = top; inside each file's own root),extrawidth=180", dir)
  M.prev, active = false, nil
  if not ok then return end
  if hasAudio and r.ShowMessageBox("Items in open projects that use these audio files will go offline.\nMove anyway?", TOOL, 4) ~= 6 then return end
  local target, n = cleanDir(v), 0
  for _, e in ipairs(list) do if moveFile(e, target) then n = n + 1 end end
  changed(); say(("moved %s to /%s"):format(plural(n, "file"), target))
end

-- physical move into an existing (or new) folder, no typing unless "+ New folder"
local function opFolder(list, target)
  local hasAudio = false
  for _, e in ipairs(list) do if e.type == "au" then hasAudio = true end end
  if hasAudio and r.ShowMessageBox("Items in open projects that use these audio files will go offline.\nMove anyway?", TOOL, 4) ~= 6 then return end
  local n = 0
  for _, e in ipairs(list) do if moveFile(e, target) then n = n + 1 end end
  changed(); say(("moved %s to /%s"):format(plural(n, "file"), target))
end

-- move (binder paper) or file (loose paper) into binder / tab / section
local function opMoveTo(list, bi, ti, sec)
  local fromB, fromT = cur.b, cur.t
  local tname
  for _, e in ipairs(list) do
    if fromB > 0 and not (fromB == bi and fromT == ti) then removeFrom(fromB, fromT, e) end
    tname = placeInTab(bi, ti, e, sec)
  end
  saveIndex(); clearSel()
  say(("%s %s -> %s / %s%s"):format(fromB > 0 and "moved" or "filed", plural(#list, "paper"),
      binders[bi].name, tname, sec and (" / " .. sec) or ""))
end

local function opHide(list)
  local any = false
  for _, e in ipairs(list) do if not hidden[hkey(e)] then any = true end end
  for _, e in ipairs(list) do hidden[hkey(e)] = any or nil end
  saveIndex(); clearSel()
  say(any and ("hid " .. plural(#list, "paper")) or ("unhid " .. plural(#list, "paper")))
end

local function opDelete(list)
  local msg = #list == 1 and ("Shred this file?\n\n" .. fullPath(list[1]))
              or ("Shred " .. #list .. " files?")
  msg = msg .. "\n\nThey go to Binder/_Shredded. Ctrl+Z brings them back."
  if r.ShowMessageBox(msg, TOOL, 4) ~= 6 then return end
  local n = 0
  for _, e in ipairs(list) do if deleteFile(e) then n = n + 1 end end
  changed(); clearSel()
  say(n == #list and ("shredded " .. plural(n, "file")) or ("shredded " .. n .. " of " .. #list .. " (some in use?)"))
end

local function opUnfile(list)
  local set = {}
  for _, e in ipairs(list) do set[e] = true end
  for _, t in ipairs(binders[cur.b].tabs) do
    for j = #t.entries, 1, -1 do if set[t.entries[j]] then table.remove(t.entries, j) end end
  end
  saveIndex(); clearSel()
  say("unfiled " .. plural(#list, "paper") .. " (files untouched)")
end

local function opUnsection(list)
  for _, e in ipairs(list) do e.sec = nil end
  saveIndex()
end

local function doUndo()
  if undo() then
    clearSel(); refreshLoose()
    if cur.b > #binders then openBinder(0) end
    say("undone")
  else say("nothing to undo") end
end

---------------------------------------------------------------- Binder folder (index, audio copies, exports, shredder)
local DEFAULT_DIR = J(RES, "Binder")

local function applyBinderDir(dir)
  BINDIR = dir
  INDEX = J(dir, "binder_index.txt")
  ROOT.au = J(dir, "Audio")
  TRASH = J(dir, "_Shredded")
end

local function copyTree(src, dst)
  local n = 0
  local function walk(a, b)
    r.RecursiveCreateDirectory(b, 0)
    r.EnumerateFiles(a, -1); r.EnumerateSubdirectories(a, -1)
    local i = 0
    while true do
      local f = r.EnumerateFiles(a, i); if not f then break end
      local data = readFile(a .. SEP .. f)
      if data and not exists(b .. SEP .. f) and writeFile(b .. SEP .. f, data) then n = n + 1 end
      i = i + 1
    end
    i = 0
    while true do
      local d = r.EnumerateSubdirectories(a, i); if not d then break end
      walk(a .. SEP .. d, b .. SEP .. d)
      i = i + 1
    end
  end
  walk(src, dst)
  return n
end

local function pickFolder(cur)
  if r.JS_Dialog_BrowseForFolder then
    local rv, path = r.JS_Dialog_BrowseForFolder("Choose a folder for Binder", cur)
    M.prev, active = false, nil
    if rv == 1 and path and path ~= "" then return path end
    return nil
  end
  local ok, v = r.GetUserInputs("Binder folder", 1, "Folder path,extrawidth=360", cur)
  M.prev, active = false, nil
  if ok then v = trim(v); if v ~= "" then return v end end
end

local function switchFolder(newDir)
  newDir = newDir:gsub("[/\\]+$", "")
  if newDir == BINDIR then return say("that's already the Binder folder") end
  r.RecursiveCreateDirectory(newDir, 0)
  if not writeFile(J(newDir, ".binder_test"), "ok") then return say("can't write to that folder") end
  os.remove(J(newDir, ".binder_test"))
  local old = BINDIR
  if exists(J(newDir, "binder_index.txt")) then
    local a = r.ShowMessageBox("That folder already has a Binder.\n\nYes = use the binders already there\nNo = bring yours along (both get merged)", TOOL, 3)
    M.prev, active = false, nil
    if a == 2 then return end
    if a == 7 then
      local mine = serialize(binders, hidden)
      applyBinderDir(newDir)
      loadIndex()
      local l, h = parse(mine)
      merge(l or {}, h)
      copyTree(J(old, "Audio"), ROOT.au)
    else
      applyBinderDir(newDir)
      loadIndex()
    end
  else
    local a = r.ShowMessageBox("Bring your binders and filed audio along?\n\nYes = copy them to the new folder\nNo = start with an empty Binder there\n\n(Nothing is deleted from the old folder.)", TOOL, 3)
    M.prev, active = false, nil
    if a == 2 then return end
    if a == 6 then
      local n = copyTree(J(old, "Audio"), J(newDir, "Audio"))
      applyBinderDir(newDir)
      lastState = nil
      saveIndex()
      say(("moved in. %d audio file%s copied"):format(n, n == 1 and "" or "s"))
    else
      applyBinderDir(newDir)
      binders, hidden = {}, {}
      lastState = nil
      saveIndex()
    end
  end
  undoStack, pendingFiles = {}, {}
  lastState = serialize(binders, hidden)
  saveIndex()
  if newDir == DEFAULT_DIR then r.DeleteExtState(SEC, "dir", true) else r.SetExtState(SEC, "dir", newDir, true) end
  openBinder(0); clearSel(); refreshLoose()
  if not status:match("^moved in") then say("Binder folder: " .. newDir) end
end

local function folderMenu()
  local shown = BINDIR
  if #shown > 60 then shown = "..." .. shown:sub(-57) end
  local i = menu("#" .. menuSafe(shown) .. "|Change folder...|" .. (r.CF_LocateInExplorer and "Open folder" or "Show path")
                 .. "|" .. (BINDIR == DEFAULT_DIR and "#" or "") .. "Back to default folder")
  if i == 2 then
    local d = pickFolder(BINDIR)
    if d then switchFolder(d) end
  elseif i == 3 then
    if r.CF_LocateInExplorer then r.CF_LocateInExplorer(INDEX)
    elseif IS_MAC then os.execute('open "' .. BINDIR .. '"')
    elseif IS_WIN then os.execute('explorer "' .. BINDIR .. '"')
    else r.ShowMessageBox(BINDIR, TOOL, 0) end
  elseif i == 4 then
    switchFolder(DEFAULT_DIR)
  end
end

---------------------------------------------------------------- frame / input
TOOL_INFO = function()
  local papers = #loose.tt + #loose.fx + #loose.au
  return ("%d binder%s, %d papers"):format(#binders, #binders == 1 and "" or "s", papers)
end

TOOL_KEY = function(ch)
  if ch == 6 then searchFocus = true; return true end                  -- Ctrl+F
  if searchFocus and ch ~= 0 then
    if ch == 13 then searchFocus = false
    elseif ch == 27 then if search ~= "" then search = "" else searchFocus = false end
    elseif ch == 8 then
      local n = utf8.len(search)
      if n and n > 0 then search = search:sub(1, utf8.offset(search, n) - 1) end
    elseif ch >= 32 and ch < 127 then search = search .. string.char(ch)
    elseif ch >= 0x75000000 and ch < 0x76000000 then search = search .. utf8.char(ch - 0x75000000)
    elseif ch >= 160 and ch < 256 then search = search .. utf8.char(ch)
    end
    pageScroll = 0
    return true
  end
  if ch == 26 then pending = { kind = "undo" }; return true end           -- Ctrl+Z
  if ch == 32 then                                                      -- Space = preview
    local e = waveTarget(lastRows)
    if e then togglePreview(e); return true end
  end
  if ch == 1 then                                                       -- Ctrl+A
    sel = {}
    for _, row in ipairs(lastRows) do if row.kind == "paper" then sel[row.e] = true end end
    return true
  end
  if ch == 6579564 and next(sel) then pending = { kind = "delete" }; return true end   -- Delete key
  if ch == 27 and next(sel) then clearSel(); return true end
  return false
end

TOOL_FRAME = function()
  local can = not helpOpen

  font(10); local ew = gfx.measurestr("EXPORT") / S; local iw = gfx.measurestr("IMPORT") / S
  local fw = gfx.measurestr("FOLDER") / S
  local ex, ix = W - 24 - ew, W - 24 - ew - 14 - iw
  local fx = ix - 14 - fw
  local hE, hI = can and inside(ex, 66, ew, 16), can and inside(ix, 66, iw, 16)
  local hF = can and inside(fx, 66, fw, 16)
  text("FOLDER", fx, 71, 10, hF and RED or DIM)
  text("IMPORT", ix, 71, 10, hI and RED or DIM)
  text("EXPORT", ex, 71, 10, hE and RED or DIM)

  local sps = spines()
  for _, sp in ipairs(sps) do drawSpine(sp) end
  hline(20, SY + SH + 2, W - 40, 3, {0.55, 0.45, 0.33})

  local vk = cur.b .. ":" .. cur.t .. ":" .. search
  if vk ~= viewKey then viewKey = vk; clearSel() end

  local tbs = tabs()
  local rows = buildRows()
  lastRows = rows
  if jumpTo then
    for i, row in ipairs(rows) do if row.kind == "sec" and row.name == jumpTo then pageScroll = i - 1; break end end
    jumpTo = nil
  end
  waveUI = {}
  local hovered = drawPage(rows)
  if prev.h and (not waveUI.fp or waveUI.fp ~= prev.path) then stopPreview() end
  for _, tb in ipairs(tbs) do drawTab(tb) end

  stamp("FILE IT", 24, 548, W - 48, 42)
  footer(600)

  if drag and drag.active and not outsideWindow() then
    local label = #drag.list > 1 and (#drag.list .. " papers") or fit(entryName(drag.list[1]), 200, 10)
    font(10); local lw = gfx.measurestr(label) / S
    local x, y = M.x / S + 10, M.y / S + 8
    if #drag.list > 1 then col(INK, 0.10); gfx.rect(sc(x + 5), sc(y + 5), sc(lw + 14), sc(18), 1); col(NOTE); gfx.rect(sc(x + 3), sc(y + 3), sc(lw + 14), sc(18), 1) end
    col(INK, 0.15); gfx.rect(sc(x + 2), sc(y + 2), sc(lw + 14), sc(18), 1)
    col(NOTE); gfx.rect(sc(x), sc(y), sc(lw + 14), sc(18), 1)
    text(label, x + 7, y + 3, 10, THEMEX.noteInk)
  end

  if not can then return end

  if M.wheel ~= 0 then
    local d = M.wheel > 0 and -1 or 1
    if inside(SX, SY - 8, W - 48, SH + 10) then shelfScroll = shelfScroll + d
    elseif inside(24, PY, W - 48, PH) then pageScroll = pageScroll + d * 2 end
  end

  local overSpine, overTab
  for _, sp in ipairs(sps) do
    local y = (sp.id == cur.b) and SY - 7 or SY
    if inside(sp.x, y, SW, SH + 7) then overSpine = sp.id end
  end
  for _, tb in ipairs(tbs) do if inside(tb.x, TY, tb.w, TH) then overTab = tb end end
  local overRow = hovered and rows[hovered]
  local overPage = inside(56, LISTY, W - 84, PY + PH - LISTY)
  -- OS file drop: target = spine / tab / section under the mouse, else the open tab
  local drops = takeDrops()
  if #drops > 0 then
    local bi, ti, sec = cur.b, cur.t, nil
    if type(overSpine) == "number" then bi, ti = overSpine, 1
    elseif overTab and cur.b > 0 and not overTab.plus then ti = overTab.i
    elseif cur.b > 0 and overRow then sec = (overRow.kind == "sec") and overRow.name or overRow.sec end
    pending = { kind = "dropin", files = drops, bi = bi, ti = ti, sec = sec }
  end

  local cap = gfx.mouse_cap
  local mShift, mCtrl = cap & 8 == 8, (cap & 4 == 4) or (cap & 32 == 32)

  ---------------- left press
  if M.pressed then
    local sb = bar.search
    if sb and inside(sb.x, sb.y, sb.w, sb.h) then
      if search ~= "" and inside(sb.x + sb.w - 14, sb.y, 14, sb.h) then search = "" end
      searchFocus = true
    else
      searchFocus = false
    end
    if hF then pending = { kind = "folder" }
    elseif hE then pending = { kind = "export" }
    elseif hI then pending = { kind = "import" }
    elseif bar.sort and inside(bar.sort.x, bar.sort.y, bar.sort.w, bar.sort.h) then
      P.sort = P.sort % #SORTS + 1; save()
    elseif bar.sec and inside(bar.sec.x, bar.sec.y, bar.sec.w, bar.sec.h) then
      pending = { kind = "newsec" }
    elseif overSpine ~= nil then
      if overSpine == "+" then pending = { kind = "newbinder" }
      else openBinder(overSpine); search = ""; if overSpine == 0 then refreshLoose() end end
    elseif overTab then
      if overTab.plus then pending = { kind = "newtab" } else cur.t, pageScroll = overTab.i, 0 end
    elseif overRow and overRow.kind == "sec" and overRow.jump then
      local j = overRow.jump
      cur.t, search, searchFocus = j.t, "", false
      if cur.b == 0 then looseOpen[LOOSE_TABS[j.t][2] .. ":" .. j.name] = nil
      elseif j.ref then j.ref.open = true; saveQuiet() end
      jumpTo = j.name
    elseif overRow and overRow.kind == "sec" then
      if cur.b == 0 then
        local k = LOOSE_TABS[cur.t][2] .. ":" .. overRow.name
        looseOpen[k] = not overRow.open
      else
        overRow.ref.open = not overRow.ref.open; saveQuiet()
      end
    elseif overRow then
      local e = overRow.e
      if mShift and anchor and rows[anchor] then
        sel = {}
        local a, b = math.min(anchor, hovered), math.max(anchor, hovered)
        for j = a, b do if rows[j].kind == "paper" then sel[rows[j].e] = true end end
      elseif mCtrl then
        sel[e] = (not sel[e]) or nil
        anchor = hovered
      else
        local now = r.time_precise()
        if lastRow == e and now - lastRowT < 0.32 then
          pending = { kind = "use", list = { e } }; lastRow = nil
        else
          lastRow, lastRowT = e, now
          local wasSel = sel[e]
          if not wasSel then sel = { [e] = true } end
          anchor = hovered
          local list = wasSel and selList(rows) or { e }
          drag = { list = list, e = e, b = cur.b, t = cur.t, x0 = M.x, y0 = M.y, collapse = wasSel }
        end
      end
    elseif waveUI.btn and inside(waveUI.btn.x, waveUI.btn.y, waveUI.btn.w, waveUI.btn.h) then
      togglePreview(waveUI.e)
    elseif waveUI.area and inside(waveUI.area.x, waveUI.area.y, waveUI.area.w, waveUI.area.h) then
      local a = waveUI.area
      local t = clamp((M.x / S - a.x) / a.w, 0, 1) * (waveUI.len or 0)
      playPreview(waveUI.fp, t)
    elseif overPage then
      clearSel()
    end
  end

  ---------------- drag
  if drag and M.down and not drag.active then
    if math.abs(M.x - drag.x0) + math.abs(M.y - drag.y0) > 5 * S then drag.active = true end
  end
  if drag and M.released then
    local list = drag.list
    if not drag.active then
      if drag.collapse then sel = { [drag.e] = true } end          -- click on a selected row = select just it
    elseif outsideWindow() then
      pending = { kind = "drop", list = list }
    elseif type(overSpine) == "number" and overSpine > 0 then
      local bi = overSpine
      local ti = (bi == drag.b) and drag.t or 1
      if not (drag.b == bi and drag.t == ti) then
        local n, tname = 0
        for _, e in ipairs(list) do
          local added, tn = addEntry(bi, ti, e); tname = tn
          if added then n = n + 1; if drag.b > 0 then removeFrom(drag.b, drag.t, e) end end
        end
        saveIndex(); clearSel()
        say(n > 0 and ("filed %s in %s / %s"):format(plural(n, "paper"), binders[bi].name, tname) or "already in there")
      end
    elseif overTab and cur.b > 0 and not overTab.plus and overTab.i ~= drag.t then
      local n, tname = 0
      for _, e in ipairs(list) do
        local added, tn = addEntry(cur.b, overTab.i, e); tname = tn
        if added then n = n + 1; if drag.b > 0 then removeFrom(drag.b, drag.t, e) end end
      end
      saveIndex(); clearSel()
      say(n > 0 and ("filed %s in %s"):format(plural(n, "paper"), tname) or "already in there")
    elseif overPage and search == "" then
      if cur.b == 0 and drag.b == 0 and overRow and overRow.kind == "sec" then
        local hasAudio = false
        for _, e in ipairs(list) do if e.type == "au" then hasAudio = true end end
        if hasAudio and r.ShowMessageBox("Items in open projects that use these audio files will go offline.\nMove anyway?", TOOL, 4) ~= 6 then
          M.prev, active = false, nil
        else
          local n = 0
          for _, e in ipairs(list) do if moveFile(e, overRow.name) then n = n + 1 end end
          changed(); clearSel(); say(("moved %s to /%s"):format(plural(n, "file"), overRow.name))
        end
      elseif cur.b > 0 then
        local sec, before
        if overRow and overRow.kind == "sec" then sec = overRow.name
        elseif overRow then
          sec = overRow.sec
          if SORTS[P.sort] == "MANUAL" and not sel[overRow.e] then before = overRow.e end
        end
        if not (overRow and overRow.kind == "paper" and sel[overRow.e]) then
          local tname
          for _, e in ipairs(list) do
            if drag.b > 0 and not (drag.b == cur.b and drag.t == cur.t) then removeFrom(drag.b, drag.t, e) end
            tname = placeInTab(cur.b, cur.t, e, sec, before)
          end
          saveIndex()
          say(sec and ("filed under " .. sec) or ("filed in " .. tname))
        end
      end
    end
    drag = nil
  end

  ---------------- right click
  if M.rpressed then
    if type(overSpine) == "number" then pending = { kind = "spinemenu", id = overSpine }
    elseif overTab and cur.b > 0 and not overTab.plus then pending = { kind = "tabmenu", i = overTab.i }
    elseif overRow and overRow.kind == "sec" and not overRow.jump then pending = { kind = "secmenu", row = overRow }
    elseif overRow then
      if not sel[overRow.e] then sel = { [overRow.e] = true }; anchor = hovered end
      pending = { kind = "rowmenu" }
    elseif overPage then pending = { kind = "pagemenu" } end
  end
end

TOOL_POST = function()
  local p = pending; pending = nil
  if not p then return end
  local k = p.kind
  if k == "undo" then doUndo()
  elseif k == "dropin" then fileDropped(p.files, p.bi, p.ti, p.sec)
  elseif k == "export" then exportIndex()
  elseif k == "import" then importIndex()
  elseif k == "folder" then folderMenu()
  elseif k == "drop" then
    local sx, sy = gfx.clienttoscreen(M.x, M.y)
    for _, e in ipairs(p.list) do dropAt(e, sx, sy) end
  elseif k == "use" then opUse(p.list)
  elseif k == "delete" then local l = selList(); if #l > 0 then opDelete(l) end
  elseif k == "newbinder" then
    local name = ask("Binder name")
    if name then
      binders[#binders + 1] = { name = name, color = (#binders % #SPINE) + 1, tabs = { newTab("GENERAL") } }
      openBinder(#binders); shelfScroll = #binders; saveIndex()
    end
  elseif k == "newtab" then
    local name = ask("Tab name")
    if name then
      local tb = binders[cur.b].tabs
      tb[#tb + 1] = newTab(name)
      cur.t = #tb; saveIndex()
    end
  elseif k == "newsec" or k == "pagemenu" then
    if k == "pagemenu" then
      local i = cur.b > 0 and menu("New section|Page color") or (menu("Page color") + 1)
      if i == 2 then
        local curp = (cur.b > 0 and curTab().page) or (cur.b == 0 and P.loosepage) or 1
        local cp = pickFrom(PAGES, function(x) return x.name end, curp)
        if cp then
          if cur.b > 0 then curTab().page = cp; saveIndex() else P.loosepage = cp; save() end
        end
        return
      elseif i ~= 1 then return end
    end
    local t = curTab()
    local name = t and ask("Section name")
    if name then
      if byName(t.sections, name) then return say("that section already exists") end
      t.sections[#t.sections + 1] = { name = name, open = true }
      saveIndex()
    end
  elseif k == "spinemenu" then
    if p.id == 0 then
      local i = menu("Refresh|" .. (P.showhidden and "!" or "") .. "Show hidden|Empty shredder")
      if i == 1 then refreshLoose(); say("refreshed")
      elseif i == 2 then P.showhidden = not P.showhidden; save()
      elseif i == 3 then
        if r.ShowMessageBox("Empty Binder/_Shredded for good?\nThis cannot be undone, and clears Ctrl+Z history.", TOOL, 4) == 6 then
          say("shredder emptied: " .. plural(emptyShredder(), "file"))
        end
      end
      return
    end
    local b = binders[p.id]
    local i = menu("Rename|Color|Duplicate|Move left|Move right|Delete")
    if i == 1 then local n = ask("Binder name", b.name); if n then b.name = n end
    elseif i == 2 then
      local c = pickFrom(SPINE_NAMES, function(x) return x end, b.color)
      if c then b.color = c end
    elseif i == 3 then
      local d = deepCopy(b)
      d.name = b.name .. " copy"
      table.insert(binders, p.id + 1, d)
      openBinder(p.id + 1); say("binder duplicated (references only)")
    elseif i == 4 and p.id > 1 then binders[p.id], binders[p.id - 1] = binders[p.id - 1], b; if cur.b == p.id then cur.b = p.id - 1 end
    elseif i == 5 and p.id < #binders then binders[p.id], binders[p.id + 1] = binders[p.id + 1], b; if cur.b == p.id then cur.b = p.id + 1 end
    elseif i == 6 then
      if r.ShowMessageBox(("Delete the binder '%s'?\nFiles stay where they are. Ctrl+Z undoes."):format(b.name), TOOL, 4) == 6 then
        table.remove(binders, p.id); openBinder(0)
      end
    end
    saveIndex()
  elseif k == "tabmenu" then
    local tb = binders[cur.b].tabs
    local t = tb[p.i]
    local i = menu("Rename|Color|Page color|Duplicate|Move left|Move right|Delete")
    if i == 1 then local n = ask("Tab name", t.name); if n then t.name = n end
    elseif i == 2 then
      local c = pickFrom(TINT_NAMES, function(x) return x end, t.color or ((p.i - 1) % 5 + 1))
      if c then t.color = c end
    elseif i == 3 then
      local c = pickFrom(PAGES, function(x) return x.name end, t.page or 1)
      if c then t.page = c end
    elseif i == 4 then
      local d = deepCopy(t)
      d.name = t.name .. " copy"
      table.insert(tb, p.i + 1, d)
      cur.t = p.i + 1; say("tab duplicated (references only)")
    elseif i == 5 and p.i > 1 then tb[p.i], tb[p.i - 1] = tb[p.i - 1], t; cur.t = p.i - 1
    elseif i == 6 and p.i < #tb then tb[p.i], tb[p.i + 1] = tb[p.i + 1], t; cur.t = p.i + 1
    elseif i == 7 then
      if #t.entries == 0 or r.ShowMessageBox(("Delete tab '%s' (%d papers)?\nFiles stay where they are. Ctrl+Z undoes."):format(t.name, #t.entries), TOOL, 4) == 6 then
        table.remove(tb, p.i); cur.t = math.max(1, math.min(cur.t, #tb))
      end
    end
    saveIndex()
  elseif k == "secmenu" then
    if cur.b == 0 then
      local ty = LOOSE_TABS[cur.t][2]
      local i = menu("Open all|Close all")
      for _, e in ipairs(loose[ty]) do
        local d = relSplit(e.path)
        if d ~= "" then looseOpen[ty .. ":" .. d] = (i == 1) end
      end
      return
    end
    local t = curTab()
    local s = p.row.ref
    local idx
    for j, x in ipairs(t.sections) do if x == s then idx = j end end
    local i = menu("Rename|Move up|Move down|Delete")
    if i == 1 then
      local n = ask("Section name", s.name)
      if n and not byName(t.sections, n) then
        for _, e in ipairs(t.entries) do if e.sec == s.name then e.sec = n end end
        s.name = n
      end
    elseif i == 2 and idx > 1 then t.sections[idx], t.sections[idx - 1] = t.sections[idx - 1], s
    elseif i == 3 and idx < #t.sections then t.sections[idx], t.sections[idx + 1] = t.sections[idx + 1], s
    elseif i == 4 then
      for _, e in ipairs(t.entries) do if e.sec == s.name then e.sec = nil end end
      table.remove(t.sections, idx)
    end
    saveIndex()
  elseif k == "rowmenu" then
    local list = selList()
    if #list == 0 then return end
    local n = #list
    local cnt = n > 1 and (" (" .. n .. ")") or ""
    local anyHidden, inSec = false, false
    for _, e in ipairs(list) do
      if hidden[hkey(e)] then anyHidden = true end
      if e.sec then inSec = true end
    end
    local items, acts = {}, {}
    local function item(label, fn) items[#items + 1] = label; acts[#acts + 1] = fn or false end
    local function sub(label) items[#items + 1] = ">" .. label end

    item("Use" .. cnt, function() opUse(list) end)
    item("Rename" .. cnt, function() opRename(list) end)
    if cur.b > 0 then
      item((n == 1 and "" or "#") .. "Label", function()
        local l = ask("Label (empty = file name)", entryName(list[1])); list[1].label = l; saveIndex()
      end)
    end
    item("Duplicate" .. cnt, function() opDuplicate(list) end)

    -- Move > binder > tab > section
    sub("Move" .. cnt)
    for bi, b in ipairs(binders) do
      sub(menuSafe(b.name))
      for ti, t in ipairs(b.tabs) do
        local here = (cur.b == bi and cur.t == ti)
        if #t.sections > 0 then
          sub(menuSafe(t.name))
          item((here and "!" or "") .. "(no section)", function() opMoveTo(list, bi, ti, nil) end)
          for _, sc_ in ipairs(t.sections) do
            item(menuSafe(sc_.name), function() opMoveTo(list, bi, ti, sc_.name) end)
          end
          item("<+ New section...", function()
            local nm = ask("Section name")
            if not nm then return end
            if not byName(t.sections, nm) then t.sections[#t.sections + 1] = { name = nm, open = true } end
            opMoveTo(list, bi, ti, nm)
          end)
        else
          item((here and "!" or "") .. menuSafe(t.name), function() opMoveTo(list, bi, ti, nil) end)
        end
      end
      item("<+ New tab...", function()
        local nm = ask("Tab name")
        if not nm then return end
        b.tabs[#b.tabs + 1] = newTab(nm)
        opMoveTo(list, bi, #b.tabs, nil)
      end)
    end
    item("<+ New binder...", function()
      local nm = ask("Binder name")
      if not nm then return end
      binders[#binders + 1] = { name = nm, color = (#binders % #SPINE) + 1, tabs = { newTab("GENERAL") } }
      opMoveTo(list, #binders, 1, nil)
    end)

    -- Folder > existing folders of that file type (real move on disk)
    sub("Folder" .. cnt)
    local ty = list[1].type
    local curDir = relSplit(list[1].path)
    local dirs, seen = {}, {}
    for _, e in ipairs(loose[ty]) do
      local d = relSplit(e.path)
      if d ~= "" and not seen[d] then seen[d] = true; dirs[#dirs + 1] = d end
    end
    table.sort(dirs, function(a, b) return a:lower() < b:lower() end)
    item((curDir == "" and "!" or "") .. "(top)", function() opFolder(list, "") end)
    for _, d in ipairs(dirs) do item((d == curDir and "!" or "") .. menuSafe(d), function() opFolder(list, d) end) end
    item("<+ New folder...", function()
      local nm = ask("New folder (a/b)", curDir)
      if nm then opFolder(list, cleanDir(nm)) end
    end)

    if cur.b > 0 then
      item((inSec and "" or "#") .. "Unsection" .. cnt, function() opUnsection(list) end)
      item("Unfile" .. cnt, function() opUnfile(list) end)
    end
    item((anyHidden and "Unhide" or "Hide") .. cnt, function() opHide(list) end)
    item("Delete" .. cnt, function() opDelete(list) end)
    item((n == 1 and "" or "#") .. LOCATE, function() locate(list[1]) end)

    local c = menu(table.concat(items, "|"))
    if c > 0 and acts[c] then acts[c]() end
  end
end

TOOL_ACTION = function()
  if r.CountSelectedMediaItems(0) > 0 then return fileAudio() end
  if r.CountSelectedTracks(0) > 0 then
    local i = menu("Track template (with children)|FX chain (pick FX)")
    if i == 1 then fileTracks("tt") elseif i == 2 then fileTracks("fx") end
    return
  end
  say("select items or tracks first")
end

do
  local saved = r.GetExtState(SEC, "dir")
  if saved ~= "" then applyBinderDir(saved) end
end
loadIndex()
refreshLoose()

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
end
BINDER_MAIN()
