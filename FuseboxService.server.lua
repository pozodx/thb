-- FuseboxService.server.lua
-- Door: real ProximityPrompt, rotates open on its HingeAttachment.
-- Interior: custom E-press system (FuseboxInteract remote), inserts fuses.
--
-- SPAWN MODE: FUSEBOX_SPAWN_COUNT fuseboxes are cloned onto random points of the
-- active map's "FuseboxSpawns" folder at the start of every round
-- (SpawnFuseboxes BindableFunction, called by LobbyService).
-- Template lookup order: ReplicatedStorage.Templates, ServerStorage, a hand-placed
-- fusebox in Workspace.FuseBoxes, then a placed model in FuseboxSpawns.
-- Placed models in FuseboxSpawns are only position markers and are removed at runtime.
--
-- BILLBOARDS: every BillboardGui inside a fusebox is enabled only while the
-- Fuseboxes stage is active and the fusebox isn't fully powered yet.
-- When the door is opened, the billboard WITHOUT fuse icons (the "open me" one) is removed.
--
-- FUSE ICONS: the BillboardGui "FusesManagement" holds one "FuseIcon" ImageLabel per
-- fuse slot plus a "NoFuseIcon" ImageLabel used as the look of an EMPTY slot.

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local FuseService = require(script.Parent.FuseService)
local StageManager = require(script.Parent.StageManager)

local fuseBoxesFolder = Workspace:WaitForChild("FuseBoxes")

local REQUIRED_FUSES = 3 -- fuses needed per fusebox (must match the number of FuseIcon labels)
local FUSEBOX_SPAWN_COUNT = 5 -- how many fuseboxes exist on the map each round
local REQUIRED_FUSEBOX_COUNT = 3 -- how many must be fully powered to finish the Fuseboxes stage
local MAX_INTERACT_DISTANCE = 8
local DOOR_OPEN_ANGLE = 100
local DOOR_OPEN_TIME = 0.6

local TEMPLATE_NAME = "FuseboxTemplate" -- name of your fusebox template model
local SPAWNS_FOLDER_NAME = "FuseboxSpawns" -- searched for inside the active map (any depth)
local SPAWN_OFFSET = CFrame.new(0, 0, 0) -- nudge if fuseboxes float/sink relative to the spawn points

local ICON_BILLBOARD_NAME = "FusesManagement"
local FUSE_ICON_NAME = "FuseIcon"
local NO_FUSE_ICON_NAME = "NoFuseIcon"

local interactRemote = ReplicatedStorage:FindFirstChild("FuseboxInteract")
if not interactRemote then
	interactRemote = Instance.new("RemoteEvent")
	interactRemote.Name = "FuseboxInteract"
	interactRemote.Parent = ReplicatedStorage
end

-- fuseboxData[fuseboxModel] = { insertedCount = 0, opened = false }
local fuseboxData = {}
local slotCache = {} -- [fuseboxModel] = { { icon, empty, filledTransparency }, ... } (built lazily)
local spawnPointCache = {} -- [spawnsFolder] = { CFrame, ... } (filled the first time a map is used)
local fuseboxStageActive = false -- true while StageManager's current stage is "Fuseboxes"

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
	local templatesFolder = ReplicatedStorage:FindFirstChild("Templates")
	if templatesFolder then
		local exact = templatesFolder:FindFirstChild(TEMPLATE_NAME)
		if exact and exact:IsA("Model") then
			return exact
		end

		for _, child in ipairs(templatesFolder:GetChildren()) do
			local lower = child.Name:lower()
			if child:IsA("Model") and lower:find("fusebox") and not lower:find("chest") then
				return child
			end
		end
	end

	local inServerStorage = ServerStorage:FindFirstChild(TEMPLATE_NAME)
	if inServerStorage and inServerStorage:IsA("Model") then
		return inServerStorage
	end

	return nil
end

local fuseboxTemplate = findExplicitTemplate()
local templateIsExplicit = fuseboxTemplate ~= nil -- true when it comes from Templates/ServerStorage (never replaced by a marker)

if fuseboxTemplate then
	print("FuseboxService: using template " .. fuseboxTemplate:GetFullName() .. " (" .. countBillboards(fuseboxTemplate) .. " BillboardGui(s)).")
else
	-- Not found: copy a hand-placed fusebox if there is one (old behavior).
	for _, child in ipairs(fuseBoxesFolder:GetChildren()) do
		if child:IsA("Model") then
			fuseboxTemplate = child:Clone()
			fuseboxTemplate.Name = "FuseboxTemplate"
			fuseboxTemplate.Parent = ServerStorage
			break
		end
	end

	local names = {}
	local templatesFolder = ReplicatedStorage:FindFirstChild("Templates")
	if templatesFolder then
		for _, child in ipairs(templatesFolder:GetChildren()) do
			table.insert(names, child.Name)
		end
	end
	warn("FuseboxService: no template named '" .. TEMPLATE_NAME .. "' (or similar) in ReplicatedStorage.Templates. It contains: " .. table.concat(names, ", ") .. ". Set TEMPLATE_NAME at the top of this script to the right name.")
end

-- === End template lookup ===

local function findPrompt(instance)
	if instance:IsA("BasePart") then
		local direct = instance:FindFirstChildOfClass("ProximityPrompt")
		if direct then
			return direct
		end
	end
	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") then
			return descendant
		end
	end
	return nil
end

-- === Billboards ===

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
		warn("FuseboxService: " .. model.Name .. " has no BillboardGui, nothing to show.")
	end
end

-- Visible only while the Fuseboxes stage is active and this fusebox still needs fuses.
local function refreshBillboards(fuseboxModel)
	local data = fuseboxData[fuseboxModel]
	local show = fuseboxStageActive and data ~= nil and data.insertedCount < REQUIRED_FUSES
	setBillboardsEnabled(fuseboxModel, show)
end

-- When the door is opened, the "open me" billboard (every BillboardGui that has NO FuseIcon
-- inside it) is removed. Only the FusesManagement billboard stays.
local function removeDoorBillboard(fuseboxModel)
	for _, descendant in ipairs(fuseboxModel:GetDescendants()) do
		if descendant:IsA("BillboardGui")
			and descendant.Name ~= ICON_BILLBOARD_NAME
			and not descendant:FindFirstChild(FUSE_ICON_NAME, true) then
			descendant:Destroy()
		end
	end
end

StageManager.StageChanged.Event:Connect(function(nextStage)
	fuseboxStageActive = (nextStage == "Fuseboxes")
	for fuseboxModel in pairs(fuseboxData) do
		refreshBillboards(fuseboxModel)
	end
end)

-- === End billboards ===

-- === Fuse icons ===
-- For every slot, a copy of NoFuseIcon is placed exactly on top of the slot's FuseIcon.
-- A slot shows either its FuseIcon (fuse inserted) or its empty copy (fuse missing).
-- The original NoFuseIcon is only used as the template for those copies and stays hidden.

-- Finds the FuseIcon labels (sorted by LayoutOrder, then Position.X, then Explorer order),
-- creates one empty-slot copy per label, and returns the list of slots.
local function buildSlots(fuseboxModel)
	local gui = fuseboxModel:FindFirstChild(ICON_BILLBOARD_NAME, true)
	if not gui then
		return nil
	end

	local entries = {}
	local noFuseIcon = nil
	for index, descendant in ipairs(gui:GetDescendants()) do
		if descendant:IsA("ImageLabel") then
			if descendant.Name == NO_FUSE_ICON_NAME then
				noFuseIcon = descendant
			elseif descendant.Name == FUSE_ICON_NAME then
				table.insert(entries, { icon = descendant, index = index })
			end
		end
	end

	if #entries == 0 then
		warn("FuseboxService: " .. fuseboxModel.Name .. " has a '" .. ICON_BILLBOARD_NAME .. "' but no '" .. FUSE_ICON_NAME .. "' ImageLabel inside it.")
		return nil
	end

	table.sort(entries, function(a, b)
		if a.icon.LayoutOrder ~= b.icon.LayoutOrder then
			return a.icon.LayoutOrder < b.icon.LayoutOrder
		end
		local ax, bx = a.icon.Position.X, b.icon.Position.X
		if ax.Scale ~= bx.Scale then
			return ax.Scale < bx.Scale
		end
		if ax.Offset ~= bx.Offset then
			return ax.Offset < bx.Offset
		end
		return a.index < b.index
	end)

	if noFuseIcon then
		noFuseIcon.Visible = false
	else
		warn("FuseboxService: " .. fuseboxModel.Name .. " has no '" .. NO_FUSE_ICON_NAME .. "' ImageLabel, empty slots will just be dimmed.")
	end

	local slots = {}
	for slotNumber, entry in ipairs(entries) do
		local icon = entry.icon
		local empty = nil

		if noFuseIcon then
			empty = noFuseIcon:Clone()
			empty.Name = "EmptyFuseSlot" .. slotNumber
			empty.AnchorPoint = icon.AnchorPoint
			empty.Position = icon.Position
			empty.Size = icon.Size
			empty.Rotation = icon.Rotation
			empty.ZIndex = icon.ZIndex
			empty.LayoutOrder = icon.LayoutOrder
			empty.Visible = false
			empty.Parent = icon.Parent
		end

		table.insert(slots, { icon = icon, empty = empty, filledTransparency = icon.ImageTransparency })
	end

	return slots
end

local function updateFuseIcons(fuseboxModel)
	local data = fuseboxData[fuseboxModel]
	if not data then
		return
	end

	local slots = slotCache[fuseboxModel]
	if not slots then
		slots = buildSlots(fuseboxModel)
		if not slots then
			return -- this fusebox has no FusesManagement billboard
		end
		slotCache[fuseboxModel] = slots

		if #slots ~= REQUIRED_FUSES then
			warn("FuseboxService: " .. fuseboxModel.Name .. " has " .. #slots .. " '" .. FUSE_ICON_NAME .. "' icon(s) but REQUIRED_FUSES is " .. REQUIRED_FUSES .. ".")
		end
	end

	for slotNumber, slot in ipairs(slots) do
		local filled = slotNumber <= data.insertedCount

		if slot.empty then
			slot.icon.Visible = filled
			slot.empty.Visible = not filled
		else
			slot.icon.Visible = true
			slot.icon.ImageTransparency = filled and slot.filledTransparency or 0.7
		end
	end

	print("[FuseIcons] " .. fuseboxModel.Name .. ": " .. data.insertedCount .. "/" .. REQUIRED_FUSES .. " filled (" .. #slots .. " slot(s), empty overlays: " .. tostring(slots[1].empty ~= nil) .. ")")
end

-- === End fuse icons ===

-- Rotates a door part open around its HingeAttachment
local function openDoor(doorPart)
	local hinge = doorPart:FindFirstChild("HingeAttachment")
	if not hinge then
		warn(doorPart.Name .. " has no HingeAttachment, skipping door animation.")
		return
	end

	local hingeCFrame0 = hinge.WorldCFrame
	local offset = hingeCFrame0:ToObjectSpace(doorPart.CFrame)

	local startTime = tick()
	local connection
	connection = RunService.Heartbeat:Connect(function()
		local elapsed = tick() - startTime
		local alpha = math.min(elapsed / DOOR_OPEN_TIME, 1)
		local currentAngle = DOOR_OPEN_ANGLE * alpha

		doorPart.CFrame = hingeCFrame0 * CFrame.Angles(0, math.rad(currentAngle), 0) * offset

		if alpha >= 1 then
			connection:Disconnect()
		end
	end)
end

local function setupFusebox(fuseboxModel)
	fuseboxData[fuseboxModel] = { insertedCount = 0, opened = false }
	fuseboxModel:SetAttribute("Opened", false)
	updateFuseIcons(fuseboxModel)
	refreshBillboards(fuseboxModel)

	local doorPart = fuseboxModel:FindFirstChild("FuseboxDoor")
	if not doorPart then
		warn(fuseboxModel.Name .. " has no FuseboxDoor")
		return
	end

	local doorPrompt = findPrompt(doorPart)
	if not doorPrompt then
		warn(fuseboxModel.Name .. "'s FuseboxDoor has no ProximityPrompt")
		return
	end

	doorPrompt.Triggered:Connect(function(player)
		local data = fuseboxData[fuseboxModel]
		if not data or data.opened then
			return
		end

		if player:GetAttribute("IsKiller") then
			return
		end

		if not StageManager.IsStageActive("Fuseboxes") then
			return
		end

		data.opened = true
		fuseboxModel:SetAttribute("Opened", true)
		doorPrompt.Enabled = false
		removeDoorBillboard(fuseboxModel)
		openDoor(doorPart)
		print(fuseboxModel.Name .. " opened")
	end)
end

-- === Spawning ===

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

-- Removes last round's fuseboxes and their tracking data.
local function clearFuseboxes()
	for fuseboxModel in pairs(fuseboxData) do
		fuseboxData[fuseboxModel] = nil
		slotCache[fuseboxModel] = nil
	end

	for _, child in ipairs(fuseBoxesFolder:GetChildren()) do
		if child:IsA("Model") then
			child:Destroy()
		end
	end
end

-- Reads the spawn points of a FuseboxSpawns folder (cached after the first call).
-- Placed fusebox models are position markers and are removed at runtime so they
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
		local templateBillboards = fuseboxTemplate and countBillboards(fuseboxTemplate) or 0
		if countBillboards(bestMarker) > 0 or templateBillboards == 0 then
			if fuseboxTemplate then
				fuseboxTemplate:Destroy()
			end
			fuseboxTemplate = bestMarker:Clone()
			fuseboxTemplate.Name = "FuseboxTemplate"
			fuseboxTemplate.Parent = ServerStorage
		end
	end

	for _, marker in ipairs(markerModels) do
		marker:Destroy()
	end

	spawnPointCache[spawnsFolder] = points
	return points
end

-- Clones FUSEBOX_SPAWN_COUNT fuseboxes onto random points of the given map's
-- FuseboxSpawns folder. Returns how many were spawned.
local function spawnFuseboxes(mapFolder)
	fuseboxStageActive = false -- new round: StageManager.ResetRound() will announce the first stage right after this
	clearFuseboxes()

	local spawnsFolder = mapFolder and mapFolder:FindFirstChild(SPAWNS_FOLDER_NAME, true)
	if not spawnsFolder then
		warn("FuseboxService: no '" .. SPAWNS_FOLDER_NAME .. "' found inside " .. tostring(mapFolder and mapFolder:GetFullName()))
		return 0
	end

	local points = getSpawnPoints(spawnsFolder)

	if not fuseboxTemplate then
		warn("FuseboxService: no fusebox template found anywhere (ReplicatedStorage.Templates, ServerStorage, Workspace.FuseBoxes or " .. spawnsFolder:GetFullName() .. ").")
		return 0
	end

	if #points < REQUIRED_FUSEBOX_COUNT then
		warn("FuseboxService: only " .. #points .. " spawn point(s) in " .. spawnsFolder:GetFullName() .. ", but " .. REQUIRED_FUSEBOX_COUNT .. " fuseboxes are required -- the Fuseboxes stage can NEVER be completed this round.")
	elseif #points < FUSEBOX_SPAWN_COUNT then
		warn("FuseboxService: only " .. #points .. " spawn point(s) in " .. spawnsFolder:GetFullName() .. ", spawning " .. #points .. " fuseboxes instead of " .. FUSEBOX_SPAWN_COUNT .. ".")
	end

	local shuffled = table.clone(points)
	shuffle(shuffled)
	local count = math.min(FUSEBOX_SPAWN_COUNT, #shuffled)

	for i = 1, count do
		local fuseboxModel = fuseboxTemplate:Clone()
		fuseboxModel.Name = "Fusebox" .. i
		fuseboxModel:PivotTo(shuffled[i] * SPAWN_OFFSET)
		fuseboxModel.Parent = fuseBoxesFolder
		setupFusebox(fuseboxModel)
	end

	print("FuseboxService: spawned " .. count .. " fusebox(es) on " .. mapFolder.Name .. " (" .. #points .. " spawn points available, " .. REQUIRED_FUSEBOX_COUNT .. " needed to finish the stage).")
	return count
end

local spawnFuseboxesFunction = Instance.new("BindableFunction")
spawnFuseboxesFunction.Name = "SpawnFuseboxes"
spawnFuseboxesFunction.Parent = script
spawnFuseboxesFunction.OnInvoke = function(mapFolder)
	return spawnFuseboxes(mapFolder)
end

-- === End spawning ===

interactRemote.OnServerEvent:Connect(function(player, fuseboxModel)
	print("[Fusebox] Interior interact received for:", fuseboxModel, "from", player.Name)

	if not fuseboxModel or not fuseboxModel:IsDescendantOf(fuseBoxesFolder) then
		print("  Rejected: invalid fusebox")
		return
	end

	if player:GetAttribute("IsKiller") then
		return
	end

	local data = fuseboxData[fuseboxModel]
	if not data or not data.opened then
		print("  Rejected: not opened yet. data.opened =", data and data.opened)
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local interior = fuseboxModel:FindFirstChild("Interior")
	if not root or not interior then
		print("  Rejected: missing root or interior")
		return
	end

	local distance = (root.Position - interior.Position).Magnitude
	print("  Distance to interior:", distance)
	if distance > MAX_INTERACT_DISTANCE then
		print("  Rejected: too far")
		return
	end

	print("  IsHoldingFuse:", FuseService.IsHoldingFuse(player), "insertedCount:", data.insertedCount)

	if data.insertedCount >= REQUIRED_FUSES then
		print("  Rejected: already full")
		return
	end

	if not FuseService.IsHoldingFuse(player) then
		print("  Rejected: not holding a fuse")
		return
	end

	local fuseInstance = FuseService.GetHeldFuseModel(player)
	FuseService.ClearHeldFuse(player)
	if fuseInstance then
		fuseInstance:Destroy()
	end

	data.insertedCount += 1
	print(fuseboxModel.Name .. ": " .. data.insertedCount .. "/" .. REQUIRED_FUSES .. " fuses inserted")
	updateFuseIcons(fuseboxModel)

	local compartmentsFolder = interior:FindFirstChild("Compartments") or fuseboxModel:FindFirstChild("Compartments")
	if compartmentsFolder then
		local slot = compartmentsFolder:FindFirstChild("Fuse" .. data.insertedCount)
		if slot and slot:IsA("BasePart") then
			slot.Material = Enum.Material.Neon
			slot.Transparency = 0
		end
	end

	if data.insertedCount >= REQUIRED_FUSES then
		print(fuseboxModel.Name .. " fully powered!")
		refreshBillboards(fuseboxModel)
		StageManager.NotifyObjectiveCompleted("Fuseboxes")
	end
end)

-- === Bot support ===
-- Real players open the door via a ProximityPrompt, which is a client-
-- driven interaction bots can't trigger (no client at all). This bridge
-- runs the exact same opening logic directly.

local botOpenDoor = Instance.new("BindableFunction")
botOpenDoor.Name = "BotOpenDoor"
botOpenDoor.Parent = script

botOpenDoor.OnInvoke = function(fuseboxModel)
	local data = fuseboxData[fuseboxModel]
	if not data or data.opened then
		return false
	end

	if not StageManager.IsStageActive("Fuseboxes") then
		return false
	end

	local doorPart = fuseboxModel:FindFirstChild("FuseboxDoor")
	if not doorPart then
		return false
	end

	local doorPrompt = findPrompt(doorPart)

	data.opened = true
	fuseboxModel:SetAttribute("Opened", true)
	if doorPrompt then
		doorPrompt.Enabled = false
	end
	removeDoorBillboard(fuseboxModel)
	openDoor(doorPart)
	print(fuseboxModel.Name .. " opened (by bot)")
	return true
end

-- Mirrors the interior interact handler above, but takes the fuse
-- instance directly as a parameter instead of reading it from
-- FuseService's player-keyed state (bots aren't tracked there).

local botInsertFuse = Instance.new("BindableFunction")
botInsertFuse.Name = "BotInsertFuse"
botInsertFuse.Parent = script

botInsertFuse.OnInvoke = function(fuseboxModel, botCharacter, fuseInstance)
	local data = fuseboxData[fuseboxModel]
	if not data or not data.opened then
		return false
	end

	if data.insertedCount >= REQUIRED_FUSES then
		return false
	end

	local root = botCharacter and botCharacter:FindFirstChild("HumanoidRootPart")
	local interior = fuseboxModel:FindFirstChild("Interior")
	if not root or not interior then
		return false
	end

	if (root.Position - interior.Position).Magnitude > MAX_INTERACT_DISTANCE then
		return false
	end

	if fuseInstance then
		fuseInstance:Destroy()
	end

	data.insertedCount += 1
	print(fuseboxModel.Name .. ": " .. data.insertedCount .. "/" .. REQUIRED_FUSES .. " fuses inserted (by bot)")
	updateFuseIcons(fuseboxModel)

	local compartmentsFolder = interior:FindFirstChild("Compartments") or fuseboxModel:FindFirstChild("Compartments")
	if compartmentsFolder then
		local slot = compartmentsFolder:FindFirstChild("Fuse" .. data.insertedCount)
		if slot and slot:IsA("BasePart") then
			slot.Material = Enum.Material.Neon
			slot.Transparency = 0
		end
	end

	if data.insertedCount >= REQUIRED_FUSES then
		print(fuseboxModel.Name .. " fully powered! (by bot)")
		refreshBillboards(fuseboxModel)
		StageManager.NotifyObjectiveCompleted("Fuseboxes")
	end

	return true
end

local isFuseboxFull = Instance.new("BindableFunction")
isFuseboxFull.Name = "IsFuseboxFull"
isFuseboxFull.Parent = script

isFuseboxFull.OnInvoke = function(fuseboxModel)
	local data = fuseboxData[fuseboxModel]
	if not data then
		return true -- unknown fusebox, treat as unavailable rather than erroring
	end
	return data.insertedCount >= REQUIRED_FUSES
end

-- === End bot support ===

if fuseboxTemplate then
	-- Spawn mode: hand-placed fuseboxes in Workspace.FuseBoxes are removed at
	-- runtime (your Studio file is untouched); fresh ones are spawned each round.
	for _, child in ipairs(fuseBoxesFolder:GetChildren()) do
		if child:IsA("Model") then
			child:Destroy()
		end
	end
	print("FuseboxService loaded (spawn mode). " .. FUSEBOX_SPAWN_COUNT .. " spawned per round, " .. REQUIRED_FUSEBOX_COUNT .. " required, " .. REQUIRED_FUSES .. " fuses each.")
else
	-- No template yet. Either fuseboxes are placed in Workspace.FuseBoxes (old
	-- behavior), or the template will be taken from FuseboxSpawns at round start.
	local totalFuseboxes = 0
	for _, fuseboxModel in ipairs(fuseBoxesFolder:GetChildren()) do
		if fuseboxModel:IsA("Model") then
			setupFusebox(fuseboxModel)
			totalFuseboxes += 1
		end
	end

	if totalFuseboxes == 0 then
		print("FuseboxService loaded. No fuseboxes placed; waiting for LobbyService to spawn them from " .. SPAWNS_FOLDER_NAME .. " at round start.")
	else
		if totalFuseboxes < REQUIRED_FUSEBOX_COUNT then
			warn("FuseboxService: only " .. totalFuseboxes .. " fusebox(es) placed in Workspace.FuseBoxes, but " .. REQUIRED_FUSEBOX_COUNT .. " are required -- add " .. (REQUIRED_FUSEBOX_COUNT - totalFuseboxes) .. " more or the Fuseboxes stage can NEVER be completed this round.")
		end
		print("FuseboxService loaded (static mode). Tracking " .. totalFuseboxes .. " fusebox(es), " .. REQUIRED_FUSEBOX_COUNT .. " required.")
	end
end

StageManager.SetRequiredCount("Fuseboxes", REQUIRED_FUSEBOX_COUNT)