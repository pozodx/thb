-- KillerAttackService.server.lua
-- No lunge: clicking starts ONE long swing (SWING_DURATION seconds). The killer keeps
-- walking at normal speed during the swing, so a miss has no slowdown at all.
-- If a target is in range/angle during the hit window, the hit is registered, the swing
-- is cut short and the killer plays SuccessfulHit while slowed down (only on a hit).
--
-- Animation chain (per selected killer, e.g. "Scarecrow" / "TheMarkMaker"):
--   <Killer>Swing          -- plays once when the attack starts (the long swing)
--   <Killer>SuccessfulHit  -- plays once if the swing connected (with the slowdown)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimationIds = require(ReplicatedStorage.Shared.AnimationIds)
local PlayerStateService = require(ReplicatedStorage.Shared.PlayerStateService)
local ActionAnimationService = require(ReplicatedStorage.Shared.ActionAnimationService)

local SWING_DURATION = 1.7 -- how long the swing lasts when it misses
local HIT_WINDOW_START = 0 -- seconds into the swing when hits start to count
local HIT_WINDOW_END = SWING_DURATION -- seconds into the swing when hits stop counting
local ATTACK_RANGE = 8
local ATTACK_ANGLE_DEGREES = 45
local ATTACK_COOLDOWN = 1.5 -- time before the killer can attack again (starts when the swing ends or hits)

local dummyAnimTrack = nil

local remoteEvent = ReplicatedStorage:FindFirstChild("KillerAttackRequest")
if not remoteEvent then
	remoteEvent = Instance.new("RemoteEvent")
	remoteEvent.Name = "KillerAttackRequest"
	remoteEvent.Parent = ReplicatedStorage
end

print("KillerAttackService: script starting, remote is:", remoteEvent)

local activeAttacks = {} -- [killerPlayer] = { startTime = tick() }
local cooldowns = {} -- [killerPlayer] = tick() they can attack again

local KillerAppearanceService = require(script.Parent.KillerAppearanceService)
local KillerOverlayAnimationService = require(ReplicatedStorage.Shared.KillerOverlayAnimationService)

-- Builds an animation name like "ScarecrowSwing" based on the killer's
-- SelectedKiller attribute (e.g. "ScarecrowModel" -> "Scarecrow" + suffix)
local function getKillerAnimName(player, suffix)
	local selected = player:GetAttribute("SelectedKiller") or "ScarecrowModel"
	local baseName = selected:gsub("Model$", "")
	return baseName .. suffix
end

local function isInRangeAndAngle(killerPosition, killerLookVector, targetPosition)
	local offset = targetPosition - killerPosition
	local distance = offset.Magnitude

	if distance <= ATTACK_RANGE then
		local direction = offset.Unit
		local cosThreshold = math.cos(math.rad(ATTACK_ANGLE_DEGREES))
		local dot = killerLookVector:Dot(direction)
		return dot >= cosThreshold
	end

	return false
end

local function findTarget(killerPlayer)
	local killerCharacter = killerPlayer.Character
	if not killerCharacter then
		return nil
	end

	local killerRoot = killerCharacter:FindFirstChild("HumanoidRootPart")
	if not killerRoot then
		return nil
	end

	local killerPosition = killerRoot.Position
	local killerLookVector = killerRoot.CFrame.LookVector

	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= killerPlayer and not otherPlayer:GetAttribute("IsKiller") then
			local state = PlayerStateService.GetState(otherPlayer)
			if state == PlayerStateService.States.Healthy or state == PlayerStateService.States.Injured then
				local otherCharacter = otherPlayer.Character
				if otherCharacter then
					local otherRoot = otherCharacter:FindFirstChild("HumanoidRootPart")
					if otherRoot and isInRangeAndAngle(killerPosition, killerLookVector, otherRoot.Position) then
						return { isPlayer = true, player = otherPlayer }
					end
				end
			end
		end
	end

	local dummy = Workspace:FindFirstChild("TestDummy")
	if dummy then
		local dummyRoot = dummy:FindFirstChild("HumanoidRootPart")
		if dummyRoot and isInRangeAndAngle(killerPosition, killerLookVector, dummyRoot.Position) then
			return { isPlayer = false, dummy = dummy }
		end
	end

	return nil
end

local function playDummyAnimation(dummy, animName)
	local humanoid = dummy:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local animId = AnimationIds[animName]
	if not animId or animId == "" or animId:find("PUT_ID_HERE") then
		return
	end

	if dummyAnimTrack then
		dummyAnimTrack:Stop(0.1)
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = animId

	local success, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)

	if success then
		track.Looped = true
		track:Play(0.1)
		dummyAnimTrack = track
	else
		warn("Failed to load dummy animation: " .. animName)
	end
end

local testDummy = Workspace:FindFirstChild("TestDummy")
if testDummy then
	testDummy:GetAttributeChangedSignal("HealthState"):Connect(function()
		local state = testDummy:GetAttribute("HealthState")
		if state == "Injured" then
			playDummyAnimation(testDummy, "LimpIdle")
		elseif state == "Downed" then
			playDummyAnimation(testDummy, "CrawlIdle")
		elseif state == "Healthy" then
			playDummyAnimation(testDummy, "IdleAnim")
		end
	end)
end

local function registerHit(killerPlayer, target)
	if target.isPlayer then
		local targetPlayer = target.player
		local state = PlayerStateService.GetState(targetPlayer)

		if state == PlayerStateService.States.Healthy then
			PlayerStateService.SetState(targetPlayer, PlayerStateService.States.Injured)
		elseif state == PlayerStateService.States.Injured then
			PlayerStateService.SetState(targetPlayer, PlayerStateService.States.Downed)
		end

		print(killerPlayer.Name .. " hit " .. targetPlayer.Name .. "!")
	else
		local dummy = target.dummy
		local currentState = dummy:GetAttribute("HealthState") or "Healthy"

		if currentState == "Healthy" then
			currentState = "Injured"
			playDummyAnimation(dummy, "LimpIdle")
		elseif currentState == "Injured" then
			currentState = "Downed"
			playDummyAnimation(dummy, "CrawlIdle")
		end

		dummy:SetAttribute("HealthState", currentState)
		print(killerPlayer.Name .. " hit the TestDummy! Dummy is now: " .. currentState)

		for _, part in ipairs(dummy:GetDescendants()) do
			if part:IsA("BasePart") then
				local flashColor = Color3.fromRGB(255, 0, 0)
				if currentState == "Downed" then
					flashColor = Color3.fromRGB(80, 0, 0)
				end

				local originalColor = part.Color
				part.Color = flashColor

				task.delay(0.3, function()
					part.Color = originalColor
				end)
			end
		end
	end
end

-- The swing connected: stop the swing, play SuccessfulHit, and slow the killer down
-- (IsRecoveringFromAttack is what MovementStateService uses for the slowdown) until it ends.
local function onHit(killerPlayer, target)
	registerHit(killerPlayer, target)

	activeAttacks[killerPlayer] = nil
	killerPlayer:SetAttribute("IsSwinging", false)
	cooldowns[killerPlayer] = tick() + ATTACK_COOLDOWN

	local overlay = KillerAppearanceService.GetOverlay(killerPlayer)
	local hitAnim = getKillerAnimName(killerPlayer, "SuccessfulHit")

	killerPlayer:SetAttribute("IsRecoveringFromAttack", true)
	KillerOverlayAnimationService.Stop(overlay) -- cut the swing short
	KillerOverlayAnimationService.PlayOnce(overlay, hitAnim, function()
		killerPlayer:SetAttribute("IsRecoveringFromAttack", false)
	end)
end

-- The swing finished without hitting anything: no slowdown, just the cooldown.
local function onMiss(killerPlayer)
	activeAttacks[killerPlayer] = nil
	killerPlayer:SetAttribute("IsSwinging", false)
	cooldowns[killerPlayer] = tick() + ATTACK_COOLDOWN

	KillerOverlayAnimationService.Stop(KillerAppearanceService.GetOverlay(killerPlayer))
	print(killerPlayer.Name .. " swung and missed")
end

-- The swing was interrupted (stunned, picked someone up...): stop it, no cooldown, no slowdown.
local function cancelAttack(killerPlayer)
	activeAttacks[killerPlayer] = nil
	killerPlayer:SetAttribute("IsSwinging", false)
	KillerOverlayAnimationService.Stop(KillerAppearanceService.GetOverlay(killerPlayer))
end

remoteEvent.OnServerEvent:Connect(function(player, action, holdDuration)
	print("KillerAttackService received:", action, "from", player.Name, "IsKiller:", player:GetAttribute("IsKiller"), "IsCarrying:", player:GetAttribute("IsCarrying"), "IsStunned:", player:GetAttribute("IsStunned"))

	if not player:GetAttribute("IsKiller") then
		return
	end

	if player:GetAttribute("IsCarrying") then
		return
	end

	if player:GetAttribute("IsStunned") then
		return
	end

	-- Only "start" does anything now. Releasing the mouse ("end") doesn't affect the swing.
	if action ~= "start" then
		return
	end

	local cooldownEnd = cooldowns[player]
	if cooldownEnd and tick() < cooldownEnd then
		return
	end

	if activeAttacks[player] then
		return
	end

	activeAttacks[player] = { startTime = tick() }
	player:SetAttribute("IsSwinging", true)

	local overlay = KillerAppearanceService.GetOverlay(player)
	KillerOverlayAnimationService.PlayOnce(overlay, getKillerAnimName(player, "Swing"), nil)
end)

RunService.Heartbeat:Connect(function()
	for killerPlayer, attackData in pairs(activeAttacks) do
		if killerPlayer:GetAttribute("IsStunned") or killerPlayer:GetAttribute("IsCarrying") then
			cancelAttack(killerPlayer)
			continue
		end

		local elapsed = tick() - attackData.startTime

		if elapsed >= HIT_WINDOW_START and elapsed <= HIT_WINDOW_END then
			local target = findTarget(killerPlayer)
			if target then
				onHit(killerPlayer, target)
				continue
			end
		end

		if elapsed >= SWING_DURATION then
			onMiss(killerPlayer)
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	activeAttacks[player] = nil
	cooldowns[player] = nil
end)

print("KillerAttackService loaded successfully.")