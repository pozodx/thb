-- ChestService.server.lua
-- Custom E-hold system (no ProximityPrompt, no floating label).
-- Fuse chests: hold E -> ChestStruggle loops the whole time -> at 100%,
-- chest fades out and player is instantly holding a fuse (no separate
-- open animation, no fuse spawned on the ground).
-- Item chests: same loop, but spawns a Flashlight/Toolbox on the ground.
--
-- SPAWN MODE (fuse chests only): FUSE_CHEST_COUNT fuse chests are cloned onto
-- random points of the active map's "FuseChestSpawns" folder at the start of
-- every round (SpawnFuseChests BindableFunction, called by LobbyService).
-- Every time a fuse chest is opened, a new one respawns on a random FREE spawn
-- point after RESPAWN_DELAY seconds, so the number of chests stays constant.
-- Two chests never get closer than MIN_CHEST_SPACING studs to each other.
-- Template lookup order: ReplicatedStorage.Templates, ServerStorage, a hand-placed
-- fuse chest in Workspace.Chests, then a placed model in FuseChestSpawns.
-- Placed models in FuseChestSpawns are only position markers and are removed at runtime.
--
-- BILLBOARDS: every BillboardGui inside a fuse chest is enabled only while the
-- Fuseboxes stage is active (and hidden as soon as the chest is opened).

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local ProgressBarService = require(ReplicatedStorage.Shared.ProgressBarService)
local ActionAnimationService = require(ReplicatedStorage.Shared.ActionAnimationService)
local FuseService = require(script.Parent.FuseService)
local StageManager = require(script.Parent.StageManager)

local SEARCH_RATE_PER_SECOND = 8
local MAX_INTERACT_DISTANCE = 8
local FADE_OUT_TIME = 0.6

local FUSE_CHEST_COUNT = 8 -- fuse chests on the map at any time
local MIN_CHEST_SPACING = 5 -- studs: no two fuse chests may spawn closer than this
local RESPAWN_DELAY_MIN = 10 -- seconds after a chest is opened before its replacement appears
local RESPAWN_DELAY_MAX = 10 -- set MIN lower (e.g. 1) for "sometime within 10 seconds"
local RESPAWN_RETRY_INTERVAL = 2 -- if no free spot exists, try again every X seconds
local TEMPLATE_NAME = "FuseChestTemplate" -- name of your fuse chest template model
local SPAWNS_FOLDER_NAME = "FuseChestSpawns" -- searched for inside the active map (any depth)
local SPAWN_OFFSET = CFrame.new(0, 0, 0) -- nudge if chests float/sink relative to the spawn points

local chestsFolder = Workspace:WaitForChild("Chests")
local templatesFolder = ReplicatedStorage:WaitForChild("Templates")

local chestData = {} -- [chestModel] = { progress = 0, completed = false, searcher = nil }
local activeSearch = {} -- [player] = { chestModel, phase = "searching" }
local spawnPointCache = {} -- [spawnsFolder] = { CFrame, ... } (filled the first time a map is used)

local activeSpawnPoints = {} -- fuse chest spawn points of the map being played
local roundActive = false -- respawns only happen while a round is running
local roundToken = 0 -- bumped whenever a round starts/ends, cancels pending respawns
local chestCounter = 0
local fuseStageActive = false -- true while StageManager's current stage is "Fuseboxes"

local function countBillboards(model)
	local count = 0
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BillboardGui") then
			count += 1
		end
	end
	return count
end

-- === Template lookup ===

-- Your own template: ReplicatedStorage.Templates (exact name, else a fuzzy match), then ServerStorage.
local function findExplicitTemplate()
	local exact = templatesFolder:FindFirstChild(TEMPLATE_NAME)
	if exact and exact:IsA("Model") then
		return exact
	end

	for _, child in ipairs(templatesFolder:GetChildren()) do
		local lower = child.Name:lower()
		if child:IsA("Model") and lower:find("chest") and lower:find("fuse") then
			return child
		end
	end

	local inServerStorage = ServerStorage:FindFirstChild(TEMPLATE_NAME)
	if inServerStorage and inServerStorage:IsA("Model") then
		return inServerStorage
	end

	return nil
end

local fuseChestTemplate = findExplicitTemplate()
local templateIsExplicit = fuseChestTemplate ~= nil -- true when it comes from Templates/ServerStorage (never replaced by a marker)

if fuseChestTemplate then
	print("ChestService: using template " .. fuseChestTemplate:GetFullName() .. " (" .. countBillboards(fuseChestTemplate) .. " BillboardGui(s)).")
else
	-- Not found: copy a hand-placed fuse chest if there is one (old behavior).
	for _, child in ipairs(chestsFolder:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("ChestType") == "Fuse" then
			fuseChestTemplate = child:Clone()
			fuseChestTemplate.Name = "FuseChestTemplate"
			fuseChestTemplate.Parent = ServerStorage
			break
		end
	end

	local names = {}
	for _, child in ipairs(templatesFolder:GetChildren()) do
		table.insert(names, child.Name)
	end
	warn("ChestService: no template named '" .. TEMPLATE_NAME .. "' (or similar) in ReplicatedStorage.Templates. It contains: " .. table.concat(names, ", ") .. ". Set TEMPLATE_NAME at the top of this script to the right name.")
end

-- === End template lookup ===

local interactRemote = ReplicatedStorage:FindFirstChild("ChestInteract")
if not interactRemote then
	interactRemote = Instance.new("RemoteEvent")
	interactRemote.Name = "ChestInteract"
	interactRemote.Parent = ReplicatedStorage
end

local cancelRemote = ReplicatedStorage:FindFirstChild("CancelTimedAction")
if not cancelRemote then
	cancelRemote = Instance.new("RemoteEvent")
	cancelRemote.Name = "CancelTimedAction"
	cancelRemote.Parent = ReplicatedStorage
end

local function findMainPart(chestModel)
	for _, descendant in ipairs(chestModel:GetDescendants()) do
		if descendant:IsA("BasePart") then
			return descendant
		end
	end
	return nil
end

local function setBillboardsEnabled(model, enabled)
	local found = 0
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BillboardGui") then
			found += 1

			-- A BillboardGui only renders if it sits inside a part or has an Adornee.
			if descendant.Adornee == nil and not descendant.Parent:IsA("BasePart") then
				descendant.Adornee = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
			end

			descendant.Enabled = enabled
		end
	end

	if enabled and found == 0 then
		warn("ChestService: " .. model.Name .. " has no BillboardGui, nothing to show.")
	end
end

local function stopSearch(player)
	local search = activeSearch[player]
	if not search then
		return
	end

	local data = chestData[search.chestModel]
	if data and data.searcher == player then
		data.searcher = nil
	end

	ActionAnimationService.Stop(player)
	ProgressBarService.Hide(player)
	activeSearch[player] = nil
end

local function setupChest(chestModel)
	chestData[chestModel] = { progress = 0, completed = false, searcher = nil }
	chestModel:SetAttribute("Completed", false)
end

-- === Fuse chest placement helpers ===

local function getSpawnCFrame(spawnInstance)
	if spawnInstance:IsA("BasePart") then
		return spawnInstance.CFrame
	elseif spawnInstance:IsA("Attachment") then
		return spawnInstance.WorldCFrame
	elseif spawnInstance:IsA("Model") then
		return spawnInstance:GetPivot()
	end
	return nil
end

local function shuffle(list)
	for i = #list, 2, -1 do
		local j = math.random(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

-- Positions of every fuse chest currently in the world (including ones that are
-- still fading out after being opened, so a new chest can't land on top of them).
local function getFuseChestPositions()
	local positions = {}
	for _, child in ipairs(chestsFolder:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("ChestType") == "Fuse" then
			table.insert(positions, child:GetPivot().Position)
		end
	end
	return positions
end

local function isFarEnough(position, takenPositions)
	for _, taken in ipairs(takenPositions) do
		if (taken - position).Magnitude < MIN_CHEST_SPACING then
			return false
		end
	end
	return true
end

local function placeFuseChest(spawnCFrame)
	chestCounter += 1
	local chestModel = fuseChestTemplate:Clone()
	chestModel.Name = "FuseChest" .. chestCounter
	chestModel:SetAttribute("ChestType", "Fuse")
	chestModel:PivotTo(spawnCFrame * SPAWN_OFFSET)
	chestModel.Parent = chestsFolder
	setupChest(chestModel)
	setBillboardsEnabled(chestModel, fuseStageActive)
	return chestModel
end

-- Spawns ONE fuse chest on a random spawn point that is free (not within
-- MIN_CHEST_SPACING of any existing fuse chest). Returns true if it spawned.
local function spawnOneFuseChest()
	if not fuseChestTemplate or #activeSpawnPoints == 0 then
		return false
	end

	local taken = getFuseChestPositions()
	local candidates = {}
	for _, cf in ipairs(activeSpawnPoints) do
		if isFarEnough((cf * SPAWN_OFFSET).Position, taken) then
			table.insert(candidates, cf)
		end
	end

	if #candidates == 0 then
		return false
	end

	placeFuseChest(candidates[math.random(1, #candidates)])
	return true
end

-- Called every time a fuse chest is opened: a replacement appears later.
local function scheduleFuseChestRespawn()
	if not roundActive then
		return
	end

	local token = roundToken
	local delaySeconds = RESPAWN_DELAY_MIN + math.random() * (RESPAWN_DELAY_MAX - RESPAWN_DELAY_MIN)

	task.delay(delaySeconds, function()
		while roundActive and token == roundToken do
			if spawnOneFuseChest() then
				print("ChestService: a fuse chest respawned.")
				return
			end
			task.wait(RESPAWN_RETRY_INTERVAL)
		end
	end)
end

-- === End placement helpers ===

local function fadeOutChest(chestModel)
	for _, part in ipairs(chestModel:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CanCollide = false
			local tween = TweenService:Create(
				part,
				TweenInfo.new(FADE_OUT_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Transparency = 1 }
			)
			tween:Play()
		end
	end

	task.delay(FADE_OUT_TIME, function()
		if chestModel and chestModel.Parent then
			chestModel:Destroy()
		end
	end)
end

local function giveFuseDirectly(player)
	if FuseService.IsHoldingFuse(player) then
		return -- already holding one
	end

	local template = templatesFolder:FindFirstChild("FuseTemplate")
	if not template then
		warn("No FuseTemplate found in ReplicatedStorage.Templates")
		return
	end

	local newFuse = template:Clone()
	newFuse.Parent = Workspace.Fuses
	FuseService.PickUp(player, newFuse)
	print(player.Name .. " received a fuse directly from a chest")
end

local function spawnItemReward(chestModel, spawnPosition)
	local itemName = (math.random(2) == 1) and "FlashlightTemplate" or "ToolboxTemplate"
	local template = templatesFolder:FindFirstChild(itemName)
	if not template then
		warn("No " .. itemName .. " found in ReplicatedStorage.Templates")
		return
	end

	local newItem = template:Clone()
	newItem.Parent = Workspace

	local templateCFrame = template:GetPivot()
	local rotationOnly = templateCFrame - templateCFrame.Position
	local finalCFrame = CFrame.new(spawnPosition) * rotationOnly

	if newItem:IsA("Model") then
		newItem:PivotTo(finalCFrame)
	elseif newItem:IsA("BasePart") then
		newItem.CFrame = finalCFrame
	end

	print(chestModel.Name .. " spawned a " .. itemName)
end

local function beginOpenPhase(player, chestModel)
	local search = activeSearch[player]
	if not search or search.chestModel ~= chestModel then
		return
	end

	local data = chestData[chestModel]
	if not data or data.completed then
		return
	end

	data.completed = true
	chestModel:SetAttribute("Completed", true)

	local chestType = chestModel:GetAttribute("ChestType")
	local mainPart = findMainPart(chestModel)
	local spawnPosition = mainPart and mainPart.Position or chestModel:GetPivot().Position

	ProgressBarService.Hide(player)
	ActionAnimationService.Stop(player)

	if chestType == "Fuse" then
		setBillboardsEnabled(chestModel, false) -- opened: nothing left to do here
	end

	fadeOutChest(chestModel)

	if chestType == "Fuse" then
		giveFuseDirectly(player)
		scheduleFuseChestRespawn()
	elseif chestType == "Item" then
		spawnItemReward(chestModel, spawnPosition)
	else
		warn("Unknown or missing ChestType on " .. chestModel.Name .. ": " .. tostring(chestType))
	end

	activeSearch[player] = nil
end

-- === Spawning (fuse chests only) ===

-- Removes last round's fuse chests (item chests are left alone) and their data.
local function clearFuseChests()
	roundToken += 1 -- cancels any respawn still waiting from the previous round

	-- cancel anyone still searching a fuse chest
	for player, search in pairs(activeSearch) do
		if search.chestModel:GetAttribute("ChestType") == "Fuse" then
			stopSearch(player)
		end
	end

	for _, child in ipairs(chestsFolder:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("ChestType") == "Fuse" then
			chestData[child] = nil
			child:Destroy()
		end
	end
end

-- Reads the spawn points of a FuseChestSpawns folder (cached after the first call).
-- Placed chest models are position markers and are removed at runtime so they
-- don't act as decoys. Only when no template exists yet does the best marker (the
-- first one that has BillboardGuis, else the first one) become the template.
local function getSpawnPoints(spawnsFolder)
	local cached = spawnPointCache[spawnsFolder]
	if cached then
		return cached
	end

	local points = {}
	local markerModels = {}
	local bestMarker = nil

	for _, child in ipairs(spawnsFolder:GetChildren()) do
		local cf = getSpawnCFrame(child)
		if cf then
			table.insert(points, cf)

			if child:IsA("Model") then
				table.insert(markerModels, child)
				if not bestMarker or (countBillboards(bestMarker) == 0 and countBillboards(child) > 0) then
					bestMarker = child
				end
			end
		end
	end

	if bestMarker and not templateIsExplicit then
		local templateBillboards = fuseChestTemplate and countBillboards(fuseChestTemplate) or 0
		if countBillboards(bestMarker) > 0 or templateBillboards == 0 then
			if fuseChestTemplate then
				fuseChestTemplate:Destroy()
			end
			fuseChestTemplate = bestMarker:Clone()
			fuseChestTemplate.Name = "FuseChestTemplate"
			fuseChestTemplate.Parent = ServerStorage
		end
	end

	for _, marker in ipairs(markerModels) do
		marker:Destroy()
	end

	spawnPointCache[spawnsFolder] = points
	return points
end

-- Spawns FUSE_CHEST_COUNT fuse chests on random, non-overlapping points of the
-- given map's FuseChestSpawns folder and enables respawning for this round.
-- Returns how many were spawned.
local function spawnFuseChests(mapFolder)
	fuseStageActive = false -- new round: StageManager.ResetRound() will announce the first stage right after this
	clearFuseChests()
	roundActive = false
	activeSpawnPoints = {}

	local spawnsFolder = mapFolder and mapFolder:FindFirstChild(SPAWNS_FOLDER_NAME, true)
	if not spawnsFolder then
		warn("ChestService: no '" .. SPAWNS_FOLDER_NAME .. "' found inside " .. tostring(mapFolder and mapFolder:GetFullName()))
		return 0
	end

	local points = getSpawnPoints(spawnsFolder)

	if not fuseChestTemplate then
		warn("ChestService: no fuse chest template found anywhere (ReplicatedStorage.Templates, ServerStorage, Workspace.Chests or " .. spawnsFolder:GetFullName() .. ").")
		return 0
	end

	if #points < FUSE_CHEST_COUNT then
		warn("ChestService: only " .. #points .. " fuse chest spawn point(s) in " .. spawnsFolder:GetFullName() .. ", wanted " .. FUSE_CHEST_COUNT .. ".")
	end

	activeSpawnPoints = points

	-- pick random points one by one, skipping any that would overlap an already chosen chest
	local shuffled = table.clone(points)
	shuffle(shuffled)

	local takenPositions = {}
	local count = 0
	for _, cf in ipairs(shuffled) do
		if count >= FUSE_CHEST_COUNT then
			break
		end

		local position = (cf * SPAWN_OFFSET).Position
		if isFarEnough(position, takenPositions) then
			placeFuseChest(cf)
			table.insert(takenPositions, position)
			count += 1
		end
	end

	if count < FUSE_CHEST_COUNT then
		warn("ChestService: could only place " .. count .. " of " .. FUSE_CHEST_COUNT .. " fuse chests (spawn points too few or too close together for MIN_CHEST_SPACING = " .. MIN_CHEST_SPACING .. ").")
	end

	roundActive = true
	print("ChestService: spawned " .. count .. " fuse chest(s) on " .. mapFolder.Name .. " (" .. #points .. " spawn points available).")
	return count
end

local spawnFuseChestsFunction = Instance.new("BindableFunction")
spawnFuseChestsFunction.Name = "SpawnFuseChests"
spawnFuseChestsFunction.Parent = script
spawnFuseChestsFunction.OnInvoke = function(mapFolder)
	return spawnFuseChests(mapFolder)
end

-- Stop respawning chests as soon as the round ends.
task.spawn(function()
	local matchTimerScript = script.Parent:WaitForChild("MatchTimerService")
	local roundEndedEvent = matchTimerScript:WaitForChild("MatchTimer_RoundEnded")
	roundEndedEvent.Event:Connect(function()
		roundActive = false
		roundToken += 1
	end)
end)

-- Billboards follow the current stage: on while "Fuseboxes" is active, off otherwise.
StageManager.StageChanged.Event:Connect(function(nextStage)
	fuseStageActive = (nextStage == "Fuseboxes")
	for _, child in ipairs(chestsFolder:GetChildren()) do
		if child:IsA("Model") and child:GetAttribute("ChestType") == "Fuse" and not child:GetAttribute("Completed") then
			setBillboardsEnabled(child, fuseStageActive)
		end
	end
end)

-- === End spawning ===

interactRemote.OnServerEvent:Connect(function(player, chestModel, action)
	if not chestModel or not chestModel:IsDescendantOf(chestsFolder) then
		return
	end

	if player:GetAttribute("IsKiller") then
		return
	end

	local data = chestData[chestModel]
	if not data or data.completed then
		return
	end

	if action == "start" then
		if activeSearch[player] then
			return
		end

		if data.searcher and data.searcher ~= player then
			return
		end

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local mainPart = findMainPart(chestModel)
		if not root or not mainPart then
			return
		end

		if (root.Position - mainPart.Position).Magnitude > MAX_INTERACT_DISTANCE then
			return
		end

		local snapFolder = chestModel:FindFirstChild("SnapPoints")
		local snap = snapFolder and snapFolder:FindFirstChild("Front")
		if snap and character then
			character:PivotTo(snap.WorldCFrame)
		end

		data.searcher = player
		activeSearch[player] = { chestModel = chestModel, phase = "searching" }

		ActionAnimationService.Play(player, "ChestStruggle")
	elseif action == "stop" then
		stopSearch(player)
	end
end)

cancelRemote.OnServerEvent:Connect(function(player)
	if activeSearch[player] then
		stopSearch(player)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	if activeSearch[player] then
		stopSearch(player)
	end
end)

RunService.Heartbeat:Connect(function(deltaTime)
	for player, search in pairs(activeSearch) do
		if search.phase == "searching" then
			local chestModel = search.chestModel
			local data = chestData[chestModel]

			data.progress = math.min(100, data.progress + SEARCH_RATE_PER_SECOND * deltaTime)
			ProgressBarService.Update(player, "Searching", data.progress)

			if data.progress >= 100 then
				beginOpenPhase(player, chestModel)
			end
		end
	end
end)

local totalChests = 0
for _, chestModel in ipairs(chestsFolder:GetChildren()) do
	if chestModel:IsA("Model") then
		if fuseChestTemplate and chestModel:GetAttribute("ChestType") == "Fuse" then
			-- Spawn mode: hand-placed fuse chests are removed at runtime (your Studio
			-- file is untouched); fresh ones are spawned each round.
			chestModel:Destroy()
		else
			setupChest(chestModel)
			totalChests += 1
		end
	end
end

if fuseChestTemplate then
	print("ChestService loaded (spawn mode for fuse chests). Tracking " .. totalChests .. " other chest(s).")
else
	print("ChestService loaded. Tracking " .. totalChests .. " chest(s); fuse chests will spawn from " .. SPAWNS_FOLDER_NAME .. " at round start.")
end