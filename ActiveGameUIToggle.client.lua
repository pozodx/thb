-- ActiveGameUIToggle.client.lua

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local roundStartedRemote = ReplicatedStorage:WaitForChild("RoundStarted")
local roundEndedRemote = ReplicatedStorage:WaitForChild("RoundEndedForClients")
local matchTimerRemote = ReplicatedStorage:WaitForChild("MatchTimerUpdate")
local matchExpiredRemote = ReplicatedStorage:WaitForChild("MatchTimerExpired")

local screenGui = playerGui:WaitForChild("LobbyUI")
local otherFolder = screenGui:WaitForChild("Other")

local sideButtons = otherFolder:WaitForChild("Sidebuttons")
local lobbyFrame = otherFolder:WaitForChild("Frame")
local killerChance = otherFolder:WaitForChild("KillerChance")
local objective1 = otherFolder:WaitForChild("Objective1")
local objective2 = otherFolder:WaitForChild("Objective2")

-- Whatever Visible was set to in Studio is what Frame returns to when it's allowed to show
local frameDefaultVisible = lobbyFrame.Visible

-- Objective billboards (generators, fuseboxes, fuse chests):
--   * nobody sees them until the match timer reaches REVEAL_AT_SECONDS_REMAINING (11:00 left),
--   * after that the killer sees them right away,
--   * survivors only see them once they have passed through Workspace.Lobby.TunnelExitModel.
local FADE_IN_TIME = 1.5
local REVEAL_AT_SECONDS_REMAINING = 11 * 60 -- the match lasts 12:00, so the first minute stays hidden
local BILLBOARD_FOLDER_NAMES = { "Generators", "FuseBoxes", "Chests" }

local isRoundActive = false
local isInTunnelExit = false
local isKiller = player:GetAttribute("IsKiller") == true
local passedTunnel = false -- true once this round's tunnel has been entered
local objectivesRevealed = false -- true once the timer has reached 11:00
local matchOver = false -- true between the end of a round and the start of the next one

local function updateVisibility()
	-- Sidebuttons: lobby only, not in the tunnel exit, not the killer
	sideButtons.Visible = not isRoundActive and not isInTunnelExit and not isKiller

	-- Frame: hidden in the tunnel exit and for the killer
	lobbyFrame.Visible = frameDefaultVisible and not isInTunnelExit and not isKiller
end

-- === Objective billboard fade ===
-- fadeValue goes 0 (everything transparent) -> 1 (everything at its original look).
-- Every Frame / TextLabel / ImageLabel / UIStroke inside a BillboardGui in the watched folders
-- remembers its original transparency and is scaled by fadeValue.

local fadeValue = Instance.new("NumberValue")
fadeValue.Name = "ObjectiveBillboardFade"
fadeValue.Value = 0
fadeValue.Parent = script

local fadeTween = nil
local fadeRegistry = setmetatable({}, { __mode = "k" }) -- [instance] = { PropertyName = originalValue }

local function getTransparencyProperties(instance)
	local properties = {}
	if instance:IsA("GuiObject") then
		table.insert(properties, "BackgroundTransparency")
	end
	if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
		table.insert(properties, "TextTransparency")
		table.insert(properties, "TextStrokeTransparency")
	end
	if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
		table.insert(properties, "ImageTransparency")
	end
	if instance:IsA("UIStroke") then
		table.insert(properties, "Transparency")
	end
	return properties
end

local function applyFade(instance, amount)
	local originals = fadeRegistry[instance]
	if not originals then
		return
	end
	for property, original in pairs(originals) do
		instance[property] = 1 - (1 - original) * amount
	end
end

local function registerForFade(instance)
	if fadeRegistry[instance] then
		return
	end
	if not instance:FindFirstAncestorOfClass("BillboardGui") then
		return
	end

	local properties = getTransparencyProperties(instance)
	if #properties == 0 then
		return
	end

	local originals = {}
	for _, property in ipairs(properties) do
		originals[property] = instance[property]
	end
	fadeRegistry[instance] = originals
	applyFade(instance, fadeValue.Value)
end

fadeValue.Changed:Connect(function(amount)
	for instance in pairs(fadeRegistry) do
		if instance.Parent then
			applyFade(instance, amount)
		end
	end
end)

local function setFade(target, animated)
	if fadeTween then
		fadeTween:Cancel()
		fadeTween = nil
	end

	if animated and fadeValue.Value ~= target then
		fadeTween = TweenService:Create(
			fadeValue,
			TweenInfo.new(FADE_IN_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
			{ Value = target }
		)
		fadeTween:Play()
	else
		fadeValue.Value = target
	end
end

-- Visible only when the timer has reached 11:00 AND (you're the killer OR you passed the tunnel).
local function applyBillboardVisibility(animated)
	local target = (objectivesRevealed and (isKiller or passedTunnel)) and 1 or 0
	setFade(target, animated)
end

local function watchFolder(folder)
	for _, descendant in ipairs(folder:GetDescendants()) do
		registerForFade(descendant)
	end
	folder.DescendantAdded:Connect(registerForFade)
end

for _, folderName in ipairs(BILLBOARD_FOLDER_NAMES) do
	task.spawn(function()
		local folder = Workspace:WaitForChild(folderName, 30)
		if folder then
			watchFolder(folder)
		else
			warn("ActiveGameUIToggle: Workspace." .. folderName .. " not found, its billboards won't fade.")
		end
	end)
end

-- === End objective billboard fade ===

local function setActiveGameState(isActive)
	isRoundActive = isActive
	killerChance.Visible = not isActive
	objective1.Visible = isActive
	objective2.Visible = isActive
	updateVisibility()

	-- new round (or round over): hidden again until the timer reaches 11:00 and the tunnel is passed
	passedTunnel = false
	objectivesRevealed = false
	applyBillboardVisibility(false)
end

roundStartedRemote.OnClientEvent:Connect(function()
	matchOver = false
	setActiveGameState(true)
end)

roundEndedRemote.OnClientEvent:Connect(function()
	matchOver = true
	setActiveGameState(false)
end)

matchExpiredRemote.OnClientEvent:Connect(function()
	matchOver = true
end)

-- The server sends the remaining time as "MM:SS" every frame during a round.
-- Once it reads 11:00 or less, the objective billboards are allowed to show.
matchTimerRemote.OnClientEvent:Connect(function(timeText)
	if matchOver then
		return
	end

	local minutes, seconds = string.match(tostring(timeText), "^(%d+):(%d+)$")
	if not minutes then
		return
	end

	local remaining = tonumber(minutes) * 60 + tonumber(seconds)
	local reveal = remaining <= REVEAL_AT_SECONDS_REMAINING
	if reveal ~= objectivesRevealed then
		objectivesRevealed = reveal
		applyBillboardVisibility(true)
	end
end)

player:GetAttributeChangedSignal("IsKiller"):Connect(function()
	isKiller = player:GetAttribute("IsKiller") == true
	updateVisibility()
	applyBillboardVisibility(false)
end)

setActiveGameState(false)

-- Track whether the local player is inside Workspace.Lobby.TunnelExitModel
task.spawn(function()
	local lobbyFolder = Workspace:WaitForChild("Lobby")
	local tunnelExitModel = lobbyFolder:WaitForChild("TunnelExitModel")

	-- The tunnel is static, so compute its bounding box once instead of every frame
	local boxCFrame, boxSize = tunnelExitModel:GetBoundingBox()
	local halfSize = boxSize / 2

	local function isInsideTunnel(position)
		local relative = boxCFrame:PointToObjectSpace(position)
		return math.abs(relative.X) <= halfSize.X
			and math.abs(relative.Y) <= halfSize.Y
			and math.abs(relative.Z) <= halfSize.Z
	end

	RunService.Heartbeat:Connect(function()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local inside = root ~= nil and isInsideTunnel(root.Position)

		if inside ~= isInTunnelExit then
			isInTunnelExit = inside
			updateVisibility()
		end

		-- survivor goes through the tunnel during a round: objective billboards fade in
		-- (as soon as the timer allows it, which may be right now or at 11:00)
		if isRoundActive and inside and not passedTunnel and not isKiller then
			passedTunnel = true
			applyBillboardVisibility(true)
		end
	end)
end)