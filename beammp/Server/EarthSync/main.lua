-- EarthSync: BeamMP server plugin for BeamNG.Earth.
-- Relays each player's GPS position and world origin to every player (with the sender's id), so
-- players near each other can share one world origin. It keeps no state of its own.
-- Install: put this folder in the server's Resources/Server/ (Resources/Server/EarthSync/main.lua).

local MAX_LEN = 200

function EarthSync_onState(pid, data)
  if type(data) ~= "string" or #data > MAX_LEN then return end
  MP.TriggerClientEvent(-1, "EarthSyncPeer", tostring(pid) .. "|" .. data)
end

function EarthSync_onLeave(pid)
  MP.TriggerClientEvent(-1, "EarthSyncLeave", tostring(pid))
end

MP.RegisterEvent("EarthSyncState", "EarthSync_onState")
MP.RegisterEvent("onPlayerDisconnect", "EarthSync_onLeave")
print("[EarthSync] loaded")
