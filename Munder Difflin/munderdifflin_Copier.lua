-- @description Copier
-- @author Byungkyu Lee
-- @version 2.1
-- @changelog Size and lettering follow the Munder Difflin card
-- @about Turns audio into MIDI notes on a new track.
--   Modes: ALL (every spectral peak), CHORDS (harmonic grouping), MELODY (YIN),
--   BASS (lowest fundamental), HITS (spectral-flux onsets -> note 36 triggers).
--   Drag a value up/down (Shift = fine), wheel nudges, double-click to type. Enter = copy.

local r = reaper
local SEC, TOOL = "BK_Copier", "Copier"
local W, H = 300, 428
local P   = { sens = 5, minnote = 60, mode = 1 }
local LIM = { sens = {1, 10}, minnote = {10, 2000} }
local Q   = { sens = 2, minnote = 0 }
local QF  = { sens = 3, minnote = 0 }
local NAMES = { sens = "Sensitivity (1-10)", minnote = "Min note (ms)" }
local MODES = {
  { key = "ALL",    info = "every peak it hears, overtones too" },
  { key = "CHORDS", info = "fundamentals only, several at once" },
  { key = "MELODY", info = "one clean note at a time" },
  { key = "BASS",   info = "the lowest fundamental only" },
  { key = "HITS",   info = "note 36 (kick) on every hit" },
}
local HELP = {
  "ATTACHMENT 1 OF 1",
  "Re: How to use the Copier",
  "",
  "Select audio item(s). Press COPY.",
  "MIDI lands on a new track below.",
  "",
  "MODE (click to choose):",
  "  ALL ..... everything, overtones too",
  "  CHORDS .. root notes, chords OK",
  "  MELODY .. one note at a time",
  "  BASS .... lowest note only",
  "  HITS .... note 36 on every hit",
  "",
  "SENSITIVITY  how much it hears",
  "MIN NOTE ... shorter = ignored",
  "             (HITS: min gap)",
  "",
  "ENTER copies. ESC goes home.",
  "Please do not unplug anything.",
}
local FONT_UP = 1     -- +1 pt on every text size
local UI_SCALE = tonumber(reaper.GetExtState("BK_Office", "ui_scale")) or 1.265  -- set on the Munder Difflin card
local TOOL_FRAME, TOOL_INFO, TOOL_ACTION, TOOL_POST
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
local MAXLEN = 180                              -- seconds analysed per item

-- mono read at `sr`, with `pad` zeros in front (so frame centres line up with time 0)
local function readMono(take, len, sr, pad)
  local acc = r.CreateTakeAudioAccessor(take)
  local t0 = r.GetAudioAccessorStartTime(acc)
  local src = r.GetMediaItemTake_Source(take)
  local ch = clamp(r.GetMediaSourceNumChannels(src) or 1, 1, 8)
  local total = math.floor(len * sr)
  local x, block = {}, 4096
  for i = 1, pad do x[i] = 0 end
  local buf = r.new_array(block * ch)
  local pos = 0
  while pos < total do
    local n = math.min(block, total - pos)
    buf.clear()
    r.GetAudioAccessorSamples(acc, sr, ch, t0 + pos / sr, n, buf)
    for i = 0, n - 1 do
      local s = 0
      for c = 1, ch do s = s + buf[i * ch + c] end
      x[pad + pos + i + 1] = s / ch
    end
    pos = pos + n
  end
  r.DestroyAudioAccessor(acc)
  for i = pad + total + 1, pad + total + 8192 do x[i] = 0 end
  return x, total
end

---------------------------------------------------------------- spectral analysis (shared by ALL / CHORDS / BASS / HITS)
local SR2, WINS, NFFT, HOP2 = 11025, 2048, 4096, 256    -- tonal modes: 186 ms window, 23 ms hop
local HWIN, HNFFT, HHOP = 1024, 1024, 128                -- HITS: 93 ms window, 12 ms hop

local function makeFFT(n)
  local bits = math.floor(math.log(n, 2) + 0.5)
  local rev = {}
  for i = 0, n - 1 do
    local rv, v = 0, i
    for _ = 1, bits do rv = rv * 2 + v % 2; v = v // 2 end
    rev[i] = rv
  end
  local cs, sn = {}, {}
  for i = 0, n // 2 - 1 do cs[i] = math.cos(-2 * math.pi * i / n); sn[i] = math.sin(-2 * math.pi * i / n) end
  return function(re, im)
    for i = 0, n - 1 do
      local j = rev[i]
      if j > i then re[i], re[j] = re[j], re[i]; im[i], im[j] = im[j], im[i] end
    end
    local size = 2
    while size <= n do
      local half, step = size // 2, n // size
      for i = 0, n - 1, size do
        local k = 0
        for j = i, i + half - 1 do
          local l = j + half
          local c, s = cs[k], sn[k]
          local tr = re[l] * c - im[l] * s
          local ti = re[l] * s + im[l] * c
          re[l], im[l] = re[j] - tr, im[j] - ti
          re[j], im[j] = re[j] + tr, im[j] + ti
          k = k + step
        end
      end
      size = size * 2
    end
  end
end

-- frames = { t, peaks = { {m, db}... sorted loud->soft }, fmax, flux }
local function spectralFrames(x, total, win, nfft, hop, range)
  local fft = makeFFT(nfft)
  local hann = {}
  for i = 0, win - 1 do hann[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (win - 1)) end
  local kmin = math.max(2, math.floor(30 * nfft / SR2))
  local kmax = math.min(nfft // 2 - 2, math.floor(5000 * nfft / SR2))
  local re, im, db, mag, prev = {}, {}, {}, {}, {}
  local frames, gmax = {}, -300
  local nfr = math.floor(total / hop) + 1
  for f = 0, nfr - 1 do
    local st = f * hop
    for i = 0, win - 1 do re[i] = (x[st + i + 1] or 0) * hann[i]; im[i] = 0 end
    for i = win, nfft - 1 do re[i] = 0; im[i] = 0 end
    fft(re, im)
    local fmax, flux = -300, 0
    for b = kmin - 1, kmax + 1 do
      local p = re[b] * re[b] + im[b] * im[b]
      local v = 10 * math.log(p + 1e-20, 10)
      db[b] = v
      if v > fmax then fmax = v end
      local m = math.sqrt(p)
      local d = m - (prev[b] or 0)
      if d > 0 then flux = flux + d end
      mag[b] = m
    end
    prev, mag = mag, prev
    local peaks = {}
    for b = kmin, kmax do
      local v = db[b]
      if v > db[b - 1] and v >= db[b + 1] and v > fmax - range then
        local a, c = db[b - 1], db[b + 1]
        local den = a - 2 * v + c
        local off = den ~= 0 and 0.5 * (a - c) / den or 0
        local freq = (b + off) * SR2 / nfft
        peaks[#peaks + 1] = { m = 69 + 12 * math.log(freq / 440, 2), db = v - 0.25 * (a - c) * off }
      end
    end
    table.sort(peaks, function(p, q) return p.db > q.db end)
    for i = #peaks, 25, -1 do peaks[i] = nil end
    frames[f + 1] = { t = st / SR2, peaks = peaks, fmax = fmax, flux = flux }
    if fmax > gmax then gmax = fmax end
  end
  return frames, gmax
end

-- harmonic grouping: pick fundamentals that explain the most partials
local LOG2 = {}
for h = 1, 8 do LOG2[h] = 12 * math.log(h, 2) end
local function fundamentals(peaks, maxV, gate)
  local P_ = {}
  for _, p in ipairs(peaks) do if p.db > gate then P_[#P_ + 1] = { m = p.m, db = p.db, a = 10 ^ (p.db / 20) } end end
  local used, picks = {}, {}
  for _ = 1, maxV do
    local best, bestS
    for i, p in ipairs(P_) do
      if not used[i] then
        local s = 0
        for h = 1, 6 do
          local target, amax = p.m + LOG2[h], 0
          for j, q in ipairs(P_) do
            if not used[j] and math.abs(q.m - target) < 0.45 and q.a > amax then amax = q.a end
          end
          s = s + amax / math.sqrt(h)
        end
        if not bestS or s > bestS then best, bestS = i, s end
      end
    end
    if not best or (picks[1] and bestS < picks[1].s * 0.22) then break end
    local p = P_[best]
    picks[#picks + 1] = { m = p.m, db = p.db, s = bestS }
    for h = 1, 8 do
      local target = p.m + LOG2[h]
      for j, q in ipairs(P_) do if math.abs(q.m - target) < 0.45 then used[j] = true end end
    end
  end
  return picks
end

-- turn per-frame pitch sets into notes (a pitch survives short gaps)
local function trackSets(frames, setOf, gate, gmax, dt)
  local HOLD = 2
  local active, notes = {}, {}
  local function close(p, a)
    local t1 = a.t1 + dt
    if t1 - a.t0 >= P.minnote / 1000 then
      local v = clamp((a.db - gate) / math.max(1, gmax - gate), 0, 1) ^ 0.7
      notes[#notes + 1] = { t0 = math.max(0, a.t0 - dt / 2), t1 = t1, pitch = p,
                            vel = clamp(math.floor(1 + 126 * v + 0.5), 1, 127) }
    end
  end
  for _, fr in ipairs(frames) do
    local seen = {}
    for _, pk in ipairs(setOf(fr)) do
      if pk.db > gate then
        local p = math.floor(pk.m + 0.5)
        if p >= 0 and p <= 127 and (not seen[p] or seen[p] < pk.db) then seen[p] = pk.db end
      end
    end
    for p, v in pairs(seen) do
      local a = active[p]
      if a then a.t1, a.miss = fr.t, 0; if v > a.db then a.db = v end
      else active[p] = { t0 = fr.t, t1 = fr.t, db = v, miss = 0 } end
    end
    for p, a in pairs(active) do
      if not seen[p] then
        a.miss = a.miss + 1
        if a.miss > HOLD then close(p, a); active[p] = nil end
      end
    end
  end
  for p, a in pairs(active) do close(p, a) end
  return notes
end

local function tonalNotes(x, total, mode)
  local k = (P.sens - 1) / 9
  local range = 15 + 30 * k
  local gateR = 30 + 30 * k
  local maxV  = 3 + math.floor(9 * k + 0.5)
  local frames, gmax = spectralFrames(x, total, WINS, NFFT, HOP2, mode == "ALL" and range or 60)
  local gate = gmax - gateR
  local dt = HOP2 / SR2
  local setOf
  if mode == "ALL" then
    setOf = function(fr)
      local out = {}
      for i = 1, math.min(maxV, #fr.peaks) do out[i] = fr.peaks[i] end
      return out
    end
  elseif mode == "CHORDS" then
    local voices = 1 + math.floor(5 * k + 0.5)
    setOf = function(fr) return fundamentals(fr.peaks, voices, gate) end
  else -- BASS
    setOf = function(fr)
      local f = fundamentals(fr.peaks, 4, gate)
      local low
      for _, p in ipairs(f) do if not low or p.m < low.m then low = p end end
      return low and { low } or {}
    end
  end
  return trackSets(frames, setOf, gate, gmax, dt)
end

-- HITS: spectral-flux onsets -> one trigger note each (note 36 = GM kick)
local HIT_NOTE = 36
local function hitNotes(x, total)
  local k = (P.sens - 1) / 9
  local frames, gmax = spectralFrames(x, total, HWIN, HNFFT, HHOP, 1)
  local gate = gmax - (24 + 36 * k)
  local n = #frames
  local fmaxFlux = 0
  for _, f in ipairs(frames) do if f.flux > fmaxFlux then fmaxFlux = f.flux end end
  if fmaxFlux <= 0 then return {} end
  local mult = 2.2 - 1.1 * k                      -- how far above the local average a hit must be
  local floor_ = fmaxFlux * (0.10 - 0.08 * k)
  local dt = HHOP / SR2
  local gap = math.max(0.03, P.minnote / 1000)
  local hits, last = {}, -1
  for i = 2, n - 1 do
    local f = frames[i]
    if f.flux > frames[i - 1].flux and f.flux >= frames[i + 1].flux and f.fmax > gate then
      local sum, c = 0, 0
      for j = math.max(1, i - 10), math.min(n, i + 10) do sum = sum + frames[j].flux; c = c + 1 end
      if f.flux > floor_ and f.flux > (sum / c) * mult and f.t - last >= gap then
        hits[#hits + 1] = { t = f.t, v = f.flux / fmaxFlux }
        last = f.t
      end
    end
  end
  local notes = {}
  for i, h in ipairs(hits) do
    local nxt = hits[i + 1] and hits[i + 1].t or (h.t + 0.2)
    notes[#notes + 1] = { t0 = h.t + dt * 1.5, t1 = h.t + dt * 1.5 + math.min(0.12, math.max(0.03, nxt - h.t - 0.005)),
                          pitch = HIT_NOTE, vel = clamp(math.floor(20 + 107 * h.v ^ 0.6 + 0.5), 1, 127) }
  end
  return notes
end

---------------------------------------------------------------- melody only (YIN)
local SR, HOP, WIN = 16000, 160, 512
local FMIN, FMAX = 40, 2000
local TMIN, TMAX = math.floor(SR / FMAX), math.ceil(SR / FMIN)

local d = {}
local function yin(x, st, thr)
  for tau = 1, TMAX do
    local s = 0
    for j = st, st + WIN - 1 do local df = x[j] - x[j + tau]; s = s + df * df end
    d[tau] = s
  end
  local run = 0
  for tau = 1, TMAX do
    run = run + d[tau]
    d[tau] = run > 0 and d[tau] * tau / run or 1
  end
  local tau = TMIN
  while tau < TMAX do
    if d[tau] < thr then
      while tau + 1 < TMAX and d[tau + 1] < d[tau] do tau = tau + 1 end
      local a, b, c = d[tau - 1] or d[tau], d[tau], d[tau + 1]
      local den = a - 2 * b + c
      return tau + (den ~= 0 and 0.5 * (a - c) / den or 0)
    end
    tau = tau + 1
  end
end

local function melodyNotes(x, total)
  local k = (P.sens - 1) / 9
  local thr = 0.10 + 0.25 * k
  local frames, maxdb = {}, -200
  local st = 1
  while st <= total do
    local e = 0
    for j = st, st + WIN - 1 do e = e + x[j] * x[j] end
    local db = 10 * math.log(e / WIN + 1e-12, 10)
    frames[#frames + 1] = { st = st, db = db, t = (st - 1 + WIN / 2) / SR }
    if db > maxdb then maxdb = db end
    st = st + HOP
  end
  local gate = maxdb - (24 + 36 * k)
  for _, f in ipairs(frames) do
    if f.db > gate then
      local tau = yin(x, f.st, thr)
      if tau then f.midi = 69 + 12 * math.log(SR / tau / 440, 2) end
    end
  end
  local sm = {}
  for i, f in ipairs(frames) do
    if f.midi then
      local w = {}
      for j = i - 2, i + 2 do if frames[j] and frames[j].midi then w[#w + 1] = frames[j].midi end end
      table.sort(w)
      sm[i] = w[math.floor((#w + 1) / 2)]
    end
  end
  local notes, cur, gap, pend, pendN = {}, nil, 0, nil, 0
  local hop = HOP / SR
  local function close()
    if not cur then return end
    if cur.t1 + hop - cur.t0 >= P.minnote / 1000 then
      local v = clamp((cur.db - gate) / math.max(1, maxdb - gate), 0, 1) ^ 0.7
      notes[#notes + 1] = { t0 = cur.t0, t1 = cur.t1 + hop,
                            pitch = clamp(math.floor(cur.sum / cur.n + 0.5), 0, 127),
                            vel = clamp(math.floor(1 + 126 * v + 0.5), 1, 127) }
    end
    cur = nil
  end
  for i, f in ipairs(frames) do
    local m = sm[i]
    if not m then
      gap = gap + 1
      if gap > 3 then close() end
    else
      gap = 0
      if not cur then
        cur = { p = math.floor(m + 0.5), t0 = f.t, t1 = f.t, sum = m, n = 1, db = f.db }
        pendN = 0
      elseif math.abs(m - cur.p) > 0.6 then
        local p = math.floor(m + 0.5)
        pendN = (pend == p) and pendN + 1 or 1; pend = p
        if pendN >= 3 then
          local t0 = frames[i - 2].t
          cur.t1 = t0 - hop; close()
          cur = { p = p, t0 = t0, t1 = f.t, sum = m * 3, n = 3, db = f.db }
          pendN = 0
        end
      else
        pendN = 0
        cur.t1, cur.sum, cur.n = f.t, cur.sum + m, cur.n + 1
        if f.db > cur.db then cur.db = f.db end
      end
    end
  end
  close()
  return notes
end

---------------------------------------------------------------- action
local function audioItems()
  local list = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    local tk = r.GetActiveTake(it)
    if tk and not r.TakeIsMIDI(tk) then list[#list + 1] = { it = it, tk = tk } end
  end
  return list
end

local function copy()
  local list = audioItems()
  if #list == 0 then return say("select audio item(s) first") end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local outTrack, made, total = {}, 0, 0
  for _, s in ipairs(list) do
    local tr0 = r.GetMediaItem_Track(s.it)
    outTrack[tr0] = outTrack[tr0] or newTrackBelow(tr0, "COPY")
    local pos = r.GetMediaItemInfo_Value(s.it, "D_POSITION")
    local len = math.min(r.GetMediaItemInfo_Value(s.it, "D_LENGTH"), MAXLEN)

    local notes
    local mode = MODES[P.mode] and MODES[P.mode].key or "ALL"
    if mode == "MELODY" then
      local x, n = readMono(s.tk, len, SR, 0)
      notes = melodyNotes(x, n)
    elseif mode == "HITS" then
      local x, n = readMono(s.tk, len, SR2, HWIN // 2)
      notes = hitNotes(x, n)
    else
      local x, n = readMono(s.tk, len, SR2, WINS // 2)
      notes = tonalNotes(x, n, mode)
    end

    local mi = r.CreateNewMIDIItemInProj(outTrack[tr0], pos, pos + len, false)
    local mt = r.GetActiveTake(mi)
    local _, nm = r.GetSetMediaItemTakeInfo_String(s.tk, "P_NAME", "", false)
    r.GetSetMediaItemTakeInfo_String(mt, "P_NAME", (nm ~= "" and nm or "audio") .. "_copy_" .. mode:lower(), true)
    for _, nt in ipairs(notes) do
      local a = r.MIDI_GetPPQPosFromProjTime(mt, pos + nt.t0)
      local b = r.MIDI_GetPPQPosFromProjTime(mt, pos + math.min(nt.t1, len))
      if b > a then r.MIDI_InsertNote(mt, false, false, a, b, 0, nt.pitch, nt.vel, true) end
    end
    r.MIDI_Sort(mt)
    made, total = made + 1, total + #notes
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("Copier: " .. total .. " notes", -1)
  local mname = MODES[P.mode] and MODES[P.mode].key or "ALL"
  say(total == 0 and "nothing heard. try more SENSITIVITY"
      or ("%d notes from %d item%s  /  %s"):format(total, made, made > 1 and "s" or "", mname))
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
local modeMenu = false
TOOL_INFO = function()
  local n, len = 0, 0
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    local it = r.GetSelectedMediaItem(0, i)
    local tk = r.GetActiveTake(it)
    if tk and not r.TakeIsMIDI(tk) then n = n + 1; len = len + r.GetMediaItemInfo_Value(it, "D_LENGTH") end
  end
  if n == 0 then return "(no item selected)" end
  return ("%d item%s, %.1f sec"):format(n, n > 1 and "s" or "", len)
end

TOOL_FRAME = function()
  row("minnote", "MIN NOTE", "ms", 120, 2, 10)
  -- MODE: click = list, wheel = next/previous
  local x, w, y = 24, W - 48, 146
  local hov = interact("mode", x, y, w, 24)
  if hov and M.pressed then modeMenu = true end
  if hov and M.wheel ~= 0 then P.mode = (P.mode - 1 + (M.wheel > 0 and -1 or 1)) % #MODES + 1 end
  local lw = text("MODE:", x, y + 5, 12, INK, nil, 1, true)
  local m = MODES[P.mode] or MODES[1]
  local vw = text(m.key .. " v", x + w, y + 4, 14, hov and RED or NAVY, "r")
  col(LINE)
  for dx = x + lw + 8, x + w - vw - 8, 5 do gfx.rect(sc(dx), sc(y + 15), math.max(1, sc(1)), math.max(1, sc(1)), 1) end
  hline(x, y + 23, w, 1, LINE)
  text(m.info, x + w, y + 27, 9, DIM, "r")
  text("SENSITIVITY:", 24, 190, 12, INK, nil, 1, true)
  knob("sens", W / 2, 254, 40, {
    drag = 0.04, fine = 0.005, wheel = 0.1, wheelFine = 0.01,
    loL = "1", hiL = "10", fmt = fmtN,
  })
  stamp("COPY", 24, 326, W - 48, 42)
  footer(380)
end

TOOL_ACTION = function() copy() end

TOOL_POST = function()
  if not modeMenu then return end
  modeMenu = false
  local items = {}
  for i, m in ipairs(MODES) do items[i] = (i == P.mode and "!" or "") .. m.key .. "  -  " .. m.info end
  gfx.x, gfx.y = M.x, M.y
  local c = gfx.showmenu(table.concat(items, "|"))
  M.prev, active = false, nil
  if c and c > 0 then P.mode = c; save() end
end

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
