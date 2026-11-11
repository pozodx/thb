-- AnimationIds.lua
-- Fill in your actual rbxassetid numbers below (as strings, e.g. "1234567890")

return {
	IdleAnim = "rbxassetid://113442130937144",
	WalkAnim = "rbxassetid://81498715683483",
	RunAnim = "rbxassetid://94700524956023",
	CrouchIdle = "rbxassetid://91872901543527",
	CrouchWalk = "rbxassetid://124980595705418",
	LimpIdle = "rbxassetid://122965395126377",
	LimpWalk = "rbxassetid://139570897121690",
	LimpRun = "rbxassetid://121770771501677",
	CrawlIdle = "rbxassetid://117213093812791",
	CrawlWalk = "rbxassetid://85581533639228",
	MainGenerator = "rbxassetid://127842372902025",
	SideGenerator = "rbxassetid://100958524743978",
	Healer = "rbxassetid://134616646190490",
	SelfHealing = "rbxassetid://101615067958465",
	BeingHealed = "rbxassetid://131359168109462",
	ChestOpen = "rbxassetid://103790589240984",
	ChestStruggle = "rbxassetid://80804047221136",
	ChestCrouch = "rbxassetid://134079921101611",
	SlowVault = "rbxassetid://109835349349702",
	FastVault = "rbxassetid://80477662630850",
	PalletDrop = "rbxassetid://101300827422263",

	-- Scarecrow
	ScarecrowLunge = "rbxassetid://117775522475988", -- unused since the lunge was removed
	ScarecrowSwing = "rbxassetid://127389596789475",
	ScarecrowSuccessfulHit = "rbxassetid://88679961509663",
	ScarecrowMiss = "rbxassetid://95340740998593", -- unused since the lunge was removed
	ScarecrowAbility = "rbxassetid://109121677260056",

	-- These KEY NAMES must match what getKillerAnimName() builds
	-- internally (SelectedKiller "TheMarkMakerModel" minus trailing
	-- "Model" = "TheMarkMaker" + suffix) -- this is unrelated to
	-- whatever you named the animation asset in your Roblox library.
	TheMarkMakerLunge = "rbxassetid://139127971019546", -- unused since the lunge was removed
	TheMarkMakerSwing = "rbxassetid://77595835557790", -- new long swing (old: rbxassetid://111479718712348)
	TheMarkMakerSuccessfulHit = "rbxassetid://87586594846623",
	TheMarkMakerMiss = "rbxassetid://133250657126212", -- unused since the lunge was removed
	TheMarkMakerWalk = "rbxassetid://137994099273272", -- looped on the overlay while the killer moves
	TheMarkMakerStunned = "rbxassetid://111198361441978", -- not used yet: pallet stun (later)

	-- MarkMakerPowerService looks this exact key up (MARK_ANIM_NAME), it does not follow the naming above.
	MarkMakerAbility = "rbxassetid://133236630930729",
}