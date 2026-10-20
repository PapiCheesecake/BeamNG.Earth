-- luajit mod/tests/test_rhd_signs.lua  (RHD sign fix: signs and signal heads face their drivers with left-hand traffic)
local T = dofile((arg[0]:match('^(.*)[/\\]') or '.') .. '/testlib.lua')
local nav = require('beamngEarth/navgraph')
local trees = require('beamngEarth/trees')

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end
local function angle(a, b) return math.abs(((a - b) + 180) % 360 - 180) end

-- the stock server's head row for northbound traffic (inc = +y) into a junction at (100, 100), left-hand traffic:
-- the post on the left (west) kerb at x = 94, turned by that kerb (local +x west: yaw 180), its back to the drivers
local a = { 'n1', 98, 90, 0, 0, 1, 0, 94, 92, 0.15, 180 }
local x, y, yaw = nav.headPose(a, 100, 100, true)
T.check(near(x, 106) and near(y, 92), 'left-hand: the post goes to the right kerb, mirrored across the road')
T.check(angle(yaw, 0) < 1e-6, 'left-hand: local +x to the right of travel (east): it faces the drivers')

-- right-hand traffic: the server's row as it is
x, y, yaw = nav.headPose({ 'n1', 102, 90, 0, 0, 1, 0, 106, 92, 0.15, 0 }, 100, 100, false)
T.check(near(x, 106) and near(y, 92) and yaw == 0, 'right-hand: unchanged')

-- a diagonal approach: the same facing as the right-hand head of the same approach
local d = math.sqrt(0.5)
x, y, yaw = nav.headPose({ 'n2', 0, 0, 0, d, d, 0, 100 - 6 * d - 8 * d, 100 + 6 * d - 8 * d, 0.15, 135 }, 100, 100, true)
T.check(angle(yaw, 315) < 1e-6, 'diagonal: faces the drivers (yaw of the right of travel)')
T.check(near((x - 100) * d - (y - 100) * d, 6, 1e-6), 'diagonal: 6 m right of travel now (was 6 m left)')
-- no junction node known: left as it is
x, y, yaw = nav.headPose(a, nil, nil, true)
T.check(x == 94 and y == 92 and yaw == 180, 'no junction: unchanged')

-- road signs: turned only with left-hand traffic, only the sign groups
T.check(not trees.rhdTurned('stop'), 'right-hand: not turned')
trees.setLeftHand(true)
for _, g in ipairs({ 'stop', 'giveway', 'signal', 'speed30', 'speed70', 'speedk100' }) do
  T.check(trees.rhdTurned(g), 'left-hand: ' .. g .. ' turned')
end
for _, g in ipairs({ 'deciduous', 'bench', 'door', 'hydrant', 'polelamp' }) do
  T.check(not trees.rhdTurned(g), 'left-hand: ' .. g .. ' as it is')
end
trees.setLeftHand(false)
T.check(not trees.rhdTurned('stop'), 'back to right-hand')

T.done()
