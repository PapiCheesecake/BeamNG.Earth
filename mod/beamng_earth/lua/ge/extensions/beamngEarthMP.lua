-- EarthSync: BeamNG.Earth on BeamMP, one shared world origin for players near each other.
--
-- Every BeamNG.Earth PC builds its own world around its own origin (a lat/lon), so the same in-game
-- coordinates mean different real places on different PCs, and BeamMP only sends raw coordinates.
-- This extension makes players who are close together (real GPS distance) use the SAME origin:
--   * every SEND_S each PC tells the server plugin (Resources/Server/EarthSync) its GPS position and
--     its current origin; the plugin relays that to everyone with the sender's BeamMP id;
--   * players within JOIN_M of each other form a group (left again beyond LEAVE_M);
--   * the group's leader is the lowest BeamMP id in it (whoever joined first); everyone else is a
--     follower and re-registers its world under the leader's origin (core.adoptOrigin, a 'resync'
--     to another origin: the world and every vehicle move with the exact transform);
--   * a follower never starts its own distance rebase (it would pick its own origin): when the
--     leader rebases, the followers adopt the new origin a moment later.
-- Players further apart keep their own origins, and are GHOSTS to each other: their cars are switched off on
-- this PC (veh:setActive(0), as BeamMP does with unstable cars: hidden, no physics, BeamMP's position updates skip
-- them) until they are back in the group and share our origin; then switched on again (BeamMP's next update puts
-- them in place). Only the cars this extension switched off are ever switched on again.

local M = {}

M.VERSION = '0.2.1'
M.SEND_S = 1.0            -- how often this PC reports its position and origin
M.JOIN_M = 5000           -- players closer than this share one origin (and are solid)
M.LEAVE_M = 5500          -- ... until they are further apart than this (then: ghosts)
M.PEER_TIMEOUT_S = 6      -- a player not heard from for this long is forgotten
M.ADOPT_RETRY_S = 3       -- wait between two attempts to adopt the leader's origin
M.EPS_DEG = 1e-7          -- origins closer than this (~1 cm) are the same origin

local rebase = require('beamngEarth/rebase')

local peers = {}          -- BeamMP id -> { lat, lon, alat, alon, t }
local inGroup = {}        -- BeamMP id -> true while in this PC's group (hysteresis)
local myId = nil          -- this PC's BeamMP id (learnt from the plugin echoing our token)
local token = nil
local clock, sendTimer, adoptAt = 0, 0, 0
local handlersAdded = false
local following = false
local leaderId = nil
local adoptTarget = nil   -- { lat, lon } of an origin switch asked for and not committed yet
local camResetIn = nil    -- frames until the orbit camera is reset (after a switch committed)
local ghosted = {}        -- game vehicle id -> owner's BeamMP id, for the cars WE switched off

local function logI(text) log('I', 'beamngEarthMP', text) end

-- After an origin switch the orbit camera keeps aiming at the old spot (seen 2026-10-19): reset it
-- onto the car. Only the orbit camera: the others are attached to the car and keep their view.
local function resetOrbitCamera()
  local cam = rawget(_G, 'core_camera')
  if not cam or type(cam.resetCamera) ~= 'function' then return end
  local name = nil
  if type(cam.getActiveCamName) == 'function' then
    local ok, n = pcall(cam.getActiveCamName, 0)
    if ok then name = n end
  end
  if name == nil or name == 'orbit' then
    pcall(cam.resetCamera, 0)
    logI('orbit camera reset after the origin switch')
  end
end

local function toast(text)
  logI(text)
  pcall(function()
    guihooks.trigger('Message', { ttl = 6, msg = 'EarthSync: ' .. text, category = 'beamngEarthMP', icon = 'group' })
  end)
end

local function core() return rawget(_G, 'beamngEarth_core') end

local function inMP()
  if type(rawget(_G, 'TriggerServerEvent')) ~= 'function' then return false end
  local n = rawget(_G, 'MPCoreNetwork')
  if n and type(n.isMPSession) == 'function' then
    local ok, r = pcall(n.isMPSession)
    return ok and r == true
  end
  return true
end

-- great-circle distance in metres
local function distM(lat1, lon1, lat2, lon2)
  local r = math.rad
  local dlat, dlon = r(lat2 - lat1), r(lon2 - lon1)
  local a = math.sin(dlat / 2) ^ 2 + math.cos(r(lat1)) * math.cos(r(lat2)) * math.sin(dlon / 2) ^ 2
  return 6371008.8 * 2 * math.atan2(math.sqrt(a), math.sqrt(math.max(0, 1 - a)))
end

local function sameOrigin(alat, alon, blat, blon)
  return math.abs(alat - blat) < M.EPS_DEG and math.abs(alon - blon) < M.EPS_DEG
end

local function split(s)
  local t = {}
  for field in (s .. '|'):gmatch('([^|]*)|') do t[#t + 1] = field end
  return t
end

-- "id|token|lat|lon|alat|alon" from the plugin (alat / alon empty before the first origin)
local function onPeer(data)
  local f = split(tostring(data or ''))
  local id = tonumber(f[1])
  if not id then return end
  if f[2] == token then
    if myId ~= id then
      myId = id
      logI('this PC is BeamMP player ' .. id)
    end
    return
  end
  local p = peers[id] or {}
  p.lat, p.lon = tonumber(f[3]), tonumber(f[4])
  p.alat, p.alon = tonumber(f[5]), tonumber(f[6])
  p.t = clock
  peers[id] = p
end

local function onLeave(data)
  local id = tonumber(data)
  if id then peers[id], inGroup[id] = nil, nil end
end

local function addHandlers()
  if handlersAdded then return end
  local add = rawget(_G, 'AddEventHandler')
  if type(add) ~= 'function' then return end
  add('EarthSyncPeer', onPeer)
  add('EarthSyncLeave', onLeave)
  handlersAdded = true
  logI('EarthSync ' .. M.VERSION .. ' listening')
end

-- The group leader as this PC sees it: the lowest id among this PC and the players in its group.
local function pickLeader(pl)
  if not myId or not pl or not pl.lat then return nil end
  local best = myId
  for id, p in pairs(peers) do
    if p.lat and p.lon then
      local d = distM(pl.lat, pl.lon, p.lat, p.lon)
      if inGroup[id] then
        if d > M.LEAVE_M then inGroup[id] = nil end
      elseif d < M.JOIN_M then
        inGroup[id] = true
      end
      if inGroup[id] and p.alat and p.alon and id < best then best = id end
    end
  end
  return best
end

-- A follower never starts its own distance rebase: it keeps the leader's origin (the leader's
-- rebases reach it through adoptOrigin). Wrapped once, whatever reloads this extension.
if not rebase._earthSyncDecide then rebase._earthSyncDecide = rebase.decide end
rebase.decide = function(dist, pending, ...)
  if following then
    if pending and pending.purpose == 'rebase' then return 'discard' end
    if not pending then return nil end
  end
  return rebase._earthSyncDecide(dist, pending, ...)
end

-- Ghosts ---------------------------------------------------------------------------------------------------------

M.GHOST_CHECK_S = 0.25
M.WATCH_S = 2.0           -- frozen-car check: how often
M.WATCH_PEER_M = 8        -- the owner's GPS moved more than this since the last check ...
M.WATCH_CAR_M = 1         -- ... but his car here moved less than this: reset its sync
local ghostTimer = 0
local remoteCars = {}     -- game vehicle id -> owner, other players' cars (refreshed with the ghosts)
local watchTimer = 0
local watchLast = {}      -- game vehicle id -> { x, y, lat, lon } at the last check
local lastOrigin = nil    -- { lat, lon } of our origin last frame (a change: every other car's sync is reset)
local originResetIn = nil
local playerGhost = {}    -- BeamMP id -> 'far' | 'switching' while that player's cars are ghosts here (messages)

-- Should player id's cars be ghosts on this PC? Only players we have a report from: not in our group, or in it but
-- not on our origin yet (a switch in progress: their positions still mean another place).
local function wantGhost(id, myAnchor)
  local p = peers[id]
  if not p or not p.alat or not p.alon then return false end
  if not inGroup[id] or not myAnchor then return true end
  return not sameOrigin(myAnchor.lat, myAnchor.lon, p.alat, p.alon)
end

local function findObj(gid)
  local f = rawget(_G, 'getObjectByID')
  if type(f) ~= 'function' then return nil end
  local ok, o = pcall(f, gid)
  return ok and o or nil
end

-- BeamMP applies a position packet only if it is newer than the last one it applied (positionVE remoteData.timer);
-- after a car was switched off or the world moved under it, that check could drop every packet: the car was seen and
-- heard (inputs come separately) but never moved until its owner reset it (F7) (2026-10-19). Its own reset clears it.
local function resyncCar(gid)
  local obj = findObj(gid)
  if obj then
    pcall(function() obj:queueLuaCommand('if positionVE and positionVE.onReset then positionVE.onReset() end') end)
  end
end

local function setGhost(gid, owner, on)
  local obj = findObj(gid)
  if not obj then ghosted[gid] = nil; return end
  if on then
    if ghosted[gid] then return end
    local ok, active = pcall(obj.getActive, obj)
    if ok and active then
      obj:setActive(0)
      ghosted[gid] = owner
      logI(string.format('player %d: car %d is a ghost (out of range)', owner, gid))
    end
  elseif ghosted[gid] then
    obj:setActive(1)
    resyncCar(gid)
    ghosted[gid] = nil
    logI(string.format('player %d: car %d solid again', owner, gid))
  end
end

local function updateGhosts(myAnchor)
  local mp = rawget(_G, 'MPVehicleGE')
  if not mp or type(mp.getVehicles) ~= 'function' then return end
  local ok, vehs = pcall(mp.getVehicles)
  if not ok or type(vehs) ~= 'table' then return end
  local seen, ghostNow = {}, {}
  remoteCars = {}
  for _, v in pairs(vehs) do
    local gid, owner = tonumber(v.gameVehicleID), tonumber(v.ownerID)
    if gid and gid >= 0 and owner and v.isLocal ~= true and owner ~= myId then
      seen[gid] = true
      remoteCars[gid] = owner
      local g = wantGhost(owner, myAnchor)
      setGhost(gid, owner, g)
      if g then ghostNow[owner] = inGroup[owner] and 'switching' or 'far' end
    end
  end
  for gid in pairs(ghosted) do
    if not seen[gid] then ghosted[gid] = nil end -- the car was deleted
  end
  for owner, why in pairs(ghostNow) do
    if why == 'far' and playerGhost[owner] ~= 'far' then toast('player ' .. owner .. ' is far away: hidden (ghost)') end
  end
  for owner, why in pairs(playerGhost) do
    if why == 'far' and not ghostNow[owner] and peers[owner] then toast('player ' .. owner .. ' is back in range') end
  end
  playerGhost = ghostNow
end

-- Every WATCH_S: another player's car that stands still here while his GPS says he is driving gets its sync reset.
local function watchCars(myAnchor)
  local now = {}
  for gid, owner in pairs(remoteCars) do
    local p, obj = peers[owner], findObj(gid)
    if p and p.lat and obj and not ghosted[gid] and inGroup[owner] and myAnchor and p.alat
        and sameOrigin(myAnchor.lat, myAnchor.lon, p.alat, p.alon) then
      local ok, pos = pcall(obj.getPosition, obj)
      if ok and pos then
        local w = watchLast[gid]
        if w then
          local peerMoved = distM(w.lat, w.lon, p.lat, p.lon)
          local carMoved = math.sqrt((pos.x - w.x) ^ 2 + (pos.y - w.y) ^ 2)
          if peerMoved > M.WATCH_PEER_M and carMoved < M.WATCH_CAR_M then
            resyncCar(gid)
            logI(string.format('player %d: car %d stood still while he drove %.0f m: sync reset', owner, gid, peerMoved))
          end
        end
        now[gid] = { x = pos.x, y = pos.y, lat = p.lat, lon = p.lon }
      end
    end
  end
  watchLast = now
end

local function unghostAll()
  for gid, owner in pairs(ghosted) do setGhost(gid, owner, false) end
  ghosted, playerGhost = {}, {}
end

local function reset()
  unghostAll()
  remoteCars, watchLast, lastOrigin, originResetIn = {}, {}, nil, nil
  peers, inGroup = {}, {}
  myId, leaderId, following = nil, nil, false
  adoptTarget, camResetIn = nil, nil
  handlersAdded = false
  sendTimer, adoptAt = 0, 0
end

local function update(dt)
  clock = clock + dt
  if not inMP() then
    if following or myId then reset() end
    return
  end
  addHandlers()
  local c = core()
  if not c or type(c._state) ~= 'function' then return end
  local st = c._state()
  local pl = st and st.player
  local a = st and st.anchor

  sendTimer = sendTimer + dt
  if sendTimer >= M.SEND_S and pl and pl.lat and pl.lon then
    sendTimer = 0
    local msg = string.format('%s|%.9f|%.9f|%s|%s', token, pl.lat, pl.lon,
      a and string.format('%.9f', a.lat) or '', a and string.format('%.9f', a.lon) or '')
    TriggerServerEvent('EarthSyncState', msg)
  end

  for id, p in pairs(peers) do
    if clock - (p.t or 0) > M.PEER_TIMEOUT_S then peers[id], inGroup[id] = nil, nil end
  end

  local leader = pickLeader(pl)
  local nowFollowing = leader ~= nil and leader ~= myId
  if nowFollowing ~= following or (nowFollowing and leader ~= leaderId) then
    if nowFollowing then
      toast('sharing the world origin of player ' .. leader .. ' (nearby)')
    elseif following then
      toast('using your own world origin again (no one nearby)')
    end
  end
  following, leaderId = nowFollowing, leader

  if following and a and clock >= adoptAt and type(c.adoptOrigin) == 'function' then
    local p = peers[leader]
    if p and p.alat and p.alon and not sameOrigin(a.lat, a.lon, p.alat, p.alon) then
      adoptAt = clock + M.ADOPT_RETRY_S
      if c.adoptOrigin(p.alat, p.alon) then
        adoptTarget = { p.alat, p.alon }
        logI(string.format('adopting the origin of player %d: %.6f, %.6f', leader, p.alat, p.alon))
      end
    end
  end

  ghostTimer = ghostTimer + dt
  if ghostTimer >= M.GHOST_CHECK_S then
    ghostTimer = 0
    updateGhosts(a)
  end
  watchTimer = watchTimer + dt
  if watchTimer >= M.WATCH_S then
    watchTimer = 0
    watchCars(a)
  end
  -- our origin changed (a teleport, an adoption, a rebase): every other car's sync is reset a moment later
  if a and not st.rebasing then
    if lastOrigin and not sameOrigin(a.lat, a.lon, lastOrigin[1], lastOrigin[2]) then originResetIn = 0.5 end
    lastOrigin = { a.lat, a.lon }
  end
  if originResetIn then
    originResetIn = originResetIn - dt
    if originResetIn <= 0 then
      originResetIn = nil
      for gid in pairs(remoteCars) do if not ghosted[gid] then resyncCar(gid) end end
      watchLast = {}
      logI('origin changed: other players\' car sync reset')
    end
  end

  -- the switch committed (both phases done): reset the orbit camera a few frames later
  if adoptTarget and a and not st.rebasing and sameOrigin(a.lat, a.lon, adoptTarget[1], adoptTarget[2]) then
    adoptTarget, camResetIn = nil, 3
  end
  if camResetIn then
    camResetIn = camResetIn - 1
    if camResetIn <= 0 then
      camResetIn = nil
      resetOrbitCamera()
    end
  end
end

function M.onUpdate(dtReal)
  local ok, err = pcall(update, tonumber(dtReal) or 0)
  if not ok then
    log('E', 'beamngEarthMP', 'update failed: ' .. tostring(err))
  end
end

function M.onClientStartMission() reset() end
function M.onClientEndMission() reset() end

function M.onExtensionLoaded()
  math.randomseed(os.time() + math.floor((os.clock() or 0) * 1e6))
  token = string.format('%08x%08x', math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
  logI('EarthSync ' .. M.VERSION .. ' loaded')
end

-- console: dump(beamngEarthMP.state())
function M.state()
  local c = core()
  local st = c and c._state and c._state() or nil
  return { myId = myId, following = following, leader = leaderId, peers = peers, inGroup = inGroup,
    origin = st and st.anchor and { st.anchor.lat, st.anchor.lon } or nil, handlers = handlersAdded, ghosted = ghosted,
    inMP = inMP() }
end

return M
