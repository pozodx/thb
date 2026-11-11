-- GeneratorObjectiveAnnounceService.server.lua
-- Watches StageManager for the Generators stage becoming active (this
-- fires exactly once when it starts — either as the round's first stage,
-- or after the previous stage is cleared — so no debounce/reset needed).
-- Shows the "NEW OBJECTIVE" banner to every survivor. Killer is exempt.
--
-- The banner is sent only once the round is really running (match timer started)
-- and after a short delay. The round's FIRST stage fires during round setup, before
-- RoundStarted reaches the clients, so announcing instantly could get it lost.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local StageManager = require(ServerScriptService.Server.StageManager)
local ObjectiveAnnouncementService = require(ReplicatedStorage.Shared.ObjectiveAnnouncementService)

local STAGE_NAME = "Generators"
local ANNOUNCE_DELAY = 1.5 -- seconds to wait after the round is running before showing the banner
local MAX_WAIT_FOR_ROUND = 5 -- how long to wait for the match timer to start

local matchTimerScript = ServerScriptService.Server:WaitForChild("MatchTimerService")
local getRemainingFunction = matchTimerScript:WaitForChild("MatchTimer_GetRemaining")

local function isRoundRunning()
	return getRemainingFunction:Invoke() > 0
end

local function waitUntilRoundIsRunning()
	local waited = 0
	while not isRoundRunning() and waited < MAX_WAIT_FOR_ROUND do
		task.wait(0.1)
		waited += 0.1
	end
end

StageManager.StageChanged.Event:Connect(function(nextStage)
	print("GeneratorObjectiveAnnounceService: StageChanged fired with nextStage =", nextStage)

	if nextStage ~= STAGE_NAME then
		print("  -> not the " .. STAGE_NAME .. " stage, skipping")
		return
	end

	task.spawn(function()
		waitUntilRoundIsRunning()
		if not isRoundRunning() then
			print("  -> round isn't running, no banner (server start or aborted round)")
			return
		end

		task.wait(ANNOUNCE_DELAY)

		if not StageManager.IsStageActive(STAGE_NAME) or not isRoundRunning() then
			print("  -> " .. STAGE_NAME .. " stage is already over, no banner")
			return
		end

		for _, player in ipairs(Players:GetPlayers()) do
			if not player:GetAttribute("IsKiller") then
				print("  -> announcing to", player.Name)
				ObjectiveAnnouncementService.AnnouncePlayer(
					player,
					"NEW OBJECTIVE",
					"LOCATE GENERATORS AND POWER THEM UP"
				)
			else
				print("  -> skipping killer", player.Name)
			end
		end
	end)
end)

print("GeneratorObjectiveAnnounceService loaded.")

return true