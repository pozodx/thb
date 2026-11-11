-- GateService.lua (ModuleScript)
-- Slides the tunnel gates open (GATE_OPEN_DISTANCE studs, apart from each other)
-- over ~5 seconds when the round starts, and closes them again when the match
-- timer reaches CLOSE_AT_SECONDS_REMAINING (9:00 left).
-- Also opens permanently (no auto-close) once all objectives are done,
-- via GateService.OpenGatesForEscape().
--
-- Gate pairs are LeftGate1 + RightGate1 and LeftGate2 + RightGate2. Each pair
-- opens along the line between its two gates (the left gate moves away from the
-- right gate and vice versa), so it works whatever way the tunnel is rotated.

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local GATE_OPEN_DISTANCE = 10
local GATE_MOVE_TIME = 5
local CLOSE_AT_SECONDS_REMAINING = 9 * 60 -- gates close when the match timer reads 9:00
local TIMER_POLL_INTERVAL = 0.25
local TIMER_START_GRACE = 2 -- seconds to wait for the match timer to start before giving up

local lobbyFolder = Workspace:WaitForChild("Lobby")

local leftGates = { lobbyFolder:WaitForChild("LeftGate1"), lobbyFolder:WaitForChild("LeftGate2") }
local rightGates = { lobbyFolder:WaitForChild("RightGate1"), lobbyFolder:WaitForChild("RightGate2") }

-- Store each gate's true closed position ONCE at load time. All movement
-- below always targets (home + offset), never "current position + offset" --
-- this makes Open/Close/OpenForEscape safe to call in any order or
-- combination without the gates drifting or double-offsetting.
local gateHomes = {}
local gateOpenOffsets = {} -- [gate] = Vector3 offset (world space) that opens it

for _, gate in ipairs(leftGates) do
	gateHomes[gate] = gate:GetPivot()
end
for _, gate in ipairs(rightGates) do
	gateHomes[gate] = gate:GetPivot()
end

local function getCenter(gate)
	local boundingBoxCFrame = gate:GetBoundingBox()
	return boundingBoxCFrame.Position
end

local function flatten(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

-- Work out each pair's opening direction from where the two gates actually are.
for index = 1, math.min(#leftGates, #rightGates) do
	local leftGate = leftGates[index]
	local rightGate = rightGates[index]

	local across = flatten(getCenter(rightGate) - getCenter(leftGate))
	if across.Magnitude < 0.5 then
		-- The two gates sit on the same spot, so the pair can't tell us which way "apart" is.
		warn("GateService: " .. leftGate.Name .. " and " .. rightGate.Name .. " have the same center, using the left gate's own right direction instead.")
		across = flatten(leftGate:GetPivot().RightVector)
	end

	local direction = across.Unit
	gateOpenOffsets[leftGate] = -direction * GATE_OPEN_DISTANCE -- left gate moves away from the right gate
	gateOpenOffsets[rightGate] = direction * GATE_OPEN_DISTANCE -- right gate moves away from the left gate

	print(string.format("GateService: %s / %s open apart along (%.2f, %.2f)", leftGate.Name, rightGate.Name, direction.X, direction.Z))
end

local GateService = {}

local escapeModeActive = false
local roundToken = 0 -- bumped on every new round, so an old round's timer watcher stops by itself

local function moveGateModel(gateModel, offset, duration)
	local homeCFrame = gateHomes[gateModel]
	local targetCFrame = homeCFrame + offset
	local startCFrame = gateModel:GetPivot()
	local startTime = tick()

	local connection
	connection = RunService.Heartbeat:Connect(function()
		local elapsed = tick() - startTime
		local alpha = math.min(elapsed / duration, 1)
		gateModel:PivotTo(startCFrame:Lerp(targetCFrame, alpha))

		if alpha >= 1 then
			connection:Disconnect()
		end
	end)
end

local function openAllGates()
	for _, gate in ipairs(leftGates) do
		moveGateModel(gate, gateOpenOffsets[gate] or Vector3.zero, GATE_MOVE_TIME)
	end
	for _, gate in ipairs(rightGates) do
		moveGateModel(gate, gateOpenOffsets[gate] or Vector3.zero, GATE_MOVE_TIME)
	end
end

-- Watches the match timer and closes the gates once it reaches CLOSE_AT_SECONDS_REMAINING.
-- Stops by itself if a new round starts, if the escape gates open, or if the round ends.
local function closeWhenTimerHits(token)
	task.spawn(function()
		local matchTimerScript = script.Parent:WaitForChild("MatchTimerService")
		local getRemaining = matchTimerScript:WaitForChild("MatchTimer_GetRemaining")
		local graceUntil = tick() + TIMER_START_GRACE

		while token == roundToken do
			task.wait(TIMER_POLL_INTERVAL)

			if token ~= roundToken or escapeModeActive then
				return -- new round started, or the gates are held open for the escape
			end

			local remaining = getRemaining:Invoke()
			if remaining > 0 then
				if remaining <= CLOSE_AT_SECONDS_REMAINING then
					GateService.CloseGates()
					return
				end
			elseif tick() > graceUntil then
				return -- the round isn't running (anymore)
			end
		end
	end)
end

function GateService.OpenGates()
	roundToken += 1
	local token = roundToken

	openAllGates()
	print("Gates opening")

	closeWhenTimerHits(token)
end

-- Called when StageManager reports every objective is complete. Opens the
-- gates (safe even if they're already open from GateService.OpenGates())
-- and does NOT schedule an auto-close -- they stay open for the rest of
-- the round.
function GateService.OpenGatesForEscape()
	if escapeModeActive then
		return
	end

	escapeModeActive = true
	openAllGates()
	print("Escape gates opening -- all objectives complete!")
end

function GateService.CloseGates()
	escapeModeActive = false

	for _, gate in ipairs(leftGates) do
		moveGateModel(gate, Vector3.zero, GATE_MOVE_TIME)
	end
	for _, gate in ipairs(rightGates) do
		moveGateModel(gate, Vector3.zero, GATE_MOVE_TIME)
	end

	print("Gates closing")
end

-- Instantly snaps gates back to their closed home position with no tween,
-- and clears escape mode. Call at the very start of a new round so a
-- round that ended with the escape gates left open (nobody made it out
-- before the match timer expired) doesn't leak into the next round.
function GateService.ResetForNewRound()
	roundToken += 1
	escapeModeActive = false

	for gateModel, homeCFrame in pairs(gateHomes) do
		gateModel:PivotTo(homeCFrame)
	end
end

return GateService