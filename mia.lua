if not getactors or not run_on_actor then error("your executor does not support blackwine.") end

local actors = getactors()
local playerActor = actors and actors[1]

if not playerActor then
	error("blackwine failed to start: no actor available")
end

run_on_actor(playerActor, [[
-- ═══════════════════════════════════════════════════════════════════
-- blackwine v2
-- ═══════════════════════════════════════════════════════════════════

local debugState = { enabled = false }

local logger = {
	info  = function(...) print("[blackwine] [info]", ...) end,
	warn  = function(...) warn("[blackwine] [warn]", ...) end,
	debug = function(...)
		if not debugState.enabled then return end
		print("[blackwine] [debug]", ...)
	end,
	error = function(...)
		local f = {}
		for i = 1, select("#", ...) do f[i] = tostring(select(i, ...)) end
		warn("[blackwine] [error]", table.concat(f, " "))
	end,
}

if type(hookfunction) ~= "function" or type(newcclosure) ~= "function" then
	logger.error("actor environment missing required hook primitives:", "hookfunction=", type(hookfunction), "newcclosure=", type(newcclosure))
	return
end

-- ═══════ Services ═══════
local services = setmetatable({}, {
	__index = function(self, key)
		local ok, svc = pcall(game.GetService, game, key)
		if ok and svc then rawset(self, key, svc); return svc end
		logger.warn("service '" .. key .. "' invalid or not found")
	end,
})

local playersService     = services.Players
local replicatedStorage  = services.ReplicatedStorage
local localPlayer        = playersService.LocalPlayer
local HttpService        = game:GetService("HttpService")

local controllersDir = replicatedStorage:WaitForChild("Controllers")
local packagesDir    = replicatedStorage:WaitForChild("Packages")
local modulesDir     = replicatedStorage:WaitForChild("Modules")

local is5v5             = controllersDir:FindFirstChild("FanController") ~= nil
local collectionService = services.CollectionService

local sharedUtil  = require(modulesDir:WaitForChild("SharedUtil"))
local basketball  = require(modulesDir:WaitForChild("Basketball"))
local items       = require(modulesDir:WaitForChild("Items"))

local knit = require(packagesDir:WaitForChild("Knit"))

local knitServices = {}
for _, name in ipairs({"PlayerService", "ControlService"}) do
	local ok, svc = pcall(knit.GetService, name)
	if ok and svc then knitServices[name] = svc
	else logger.warn("failed to get knit service '" .. name .. "': " .. tostring(svc)) end
end

-- ═══════ Configuration ═══════
local CONFIG_FILE       = "blackwine_v2_config.json"
local CONFIG_SAVE_DELAY = 1.5
local CONFIG_VERSION    = 3
local pendingConfigSave
local EMPTY_CONFIG = {}
if table.freeze then table.freeze(EMPTY_CONFIG) end

local function canUseFileApi()
	return typeof(isfile) == "function" and typeof(readfile) == "function" and typeof(writefile) == "function"
end

local function mergeConfig(target, patch)
	if type(target) ~= "table" or type(patch) ~= "table" then return end
	for k, v in pairs(patch) do
		if type(target[k]) == "table" and type(v) == "table" then mergeConfig(target[k], v)
		else target[k] = v end
	end
end

local function saveConfig(cfg)
	if not canUseFileApi() then return false end
	cfg.version = CONFIG_VERSION
	local okE, encoded = pcall(HttpService.JSONEncode, HttpService, cfg)
	if not okE then logger.warn("config encode failed: " .. tostring(encoded)); return false end
	local okW, err = pcall(writefile, CONFIG_FILE, encoded)
	if not okW then logger.warn("config save failed: " .. tostring(err)); return false end
	logger.info("config saved")
	return true
end

local function scheduleConfigSave() end -- forward‑declared

local function readConfigFile(fileName)
	local okE, exists = pcall(isfile, fileName)
	if not okE or not exists then return nil end
	local okR, raw = pcall(readfile, fileName)
	if not okR or type(raw) ~= "string" then return nil end
	local okD, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if not okD or type(decoded) ~= "table" then return nil end
	return decoded
end

local getConfigSection, getConfigTable, getConfigValue

local config = {
	movement = {
		speedOverride     = false,
		speed             = 17,
		noJumpCooldown    = false,
		hideCoreGui       = true,
		bodyGyroTorque    = 1000000,
		bodyVelocityForce = 1000000,
		turnUnlockDelay   = 0.1,
	},
	moves = {
		jumpshot = {
			boost          = 1,
			autoGreen      = false,
			perfectRelease = false,
			greenChance    = 50,
			shotSpeed      = 1.25,
			autoRelease    = false,
			releaseDelay   = 0.35,
		},
		fade     = { boost = 1 },
		layup    = { boost = 1, animSpeed = 1 },
		euro     = { boost = 1, unlockRange = false },
		post     = {
			boost            = 1,
			unlockRange      = false,
			autoDropstep     = false,
			dropstepRange    = 7,
			autoHook         = false,
			hookRange        = 8.5,
			handScale        = 1,
			faceDefender     = false,
			assistCooldown   = 1.2,
			hookCooldown     = 2,
			hookTriggerDelay = 0.32,
		},
		dribble  = { boost = 1, noDribbleCooldown = false, animSpeed = 1 },
		pumpFake = {
			boost              = 1,
			forceShot          = false,
			jumpshotFake       = false,
			noPumpFakeCooldown = false,
			infinitePumpFake   = false,
		},
		stepback = { boost = 1 },
		dunk = {
			boost          = 1,
			unlockRange    = false,
			dunkChanger    = false,
			dunkType       = "Tomahawk",
			dunkHeight     = -0.4,
			noDunkCooldown = false,
		},
		block  = { boost = 1 },
		steal  = {
			boost            = 1,
			perfectSteal     = false,
			noStealCooldown  = false,
			phantomSteal     = false,
			passiveSteal     = false,
			passiveInterval  = 0.3,
			reachEnabled     = false,
			reachMultiplier  = 1.5,
		},
		pass     = { boost = 1 },
		rebound  = { boost = 1 },
		screen   = { boost = 1 },
		selfLob  = { unlockRange = false },
	},
	defense = {
		antiBump                  = false,
		autoAnkleBreaker          = false,
		autoGuard                 = false,
		autoBlock                 = false,
		autoBlockExtreme          = false,
		autoLock                  = false,
		blockboxSize              = 3,
		autoBlockRange            = 25,
		autoBlockCooldown         = 0.9,
		autoBlockTriggerDelay     = 0.32,
		autoBlockReleaseDelay     = 0.12,
		extremeAutoBlockInterval  = 0.08,
		guardRefreshInterval      = 0.05,
		guardTargetSwitchCooldown = 0.3,
		autoLockRefreshInterval   = 0.05,
		autoLockLeadDistance      = 3,
		autoLockPreferOffBall     = false,
		autoGuardSpeedFactor      = 25,
		autoGuardMinSpeed         = 6,
		autoGuardMaxSpeed         = 32,
		ankleBreakerRange         = 18,
		ankleBreakerDelay         = 0.06,
		guardRange                = 25,
	},
	abilities = {
		unlockAllMoves             = false,
		ignoreTeamPossessionChecks = false,
	},
	ballMagnet = {
		enabled             = false,
		scale               = 50,
		range               = 20,
		resizeEnabled       = true,
		directTouchEnabled  = true,
		touchCooldown       = 0.15,
	},
	debug = { enabled = false },
	version = CONFIG_VERSION,
}

getConfigSection = function(...)
	local node = config
	for i = 1, select("#", ...) do
		if type(node) ~= "table" then return nil end
		node = node[select(i, ...)]
		if node == nil then return nil end
	end
	return node
end

getConfigTable = function(default, ...)
	local v = getConfigSection(...)
	return type(v) == "table" and v or (default or EMPTY_CONFIG)
end

getConfigValue = function(default, ...)
	local v = getConfigSection(...)
	return v ~= nil and v or default
end

local function syncDebugState()
	debugState.enabled = getConfigValue(false, "debug", "enabled") == true
end

local function loadConfigFromDisk()
	if not canUseFileApi() then return false end
	local decoded = readConfigFile(CONFIG_FILE)
	if not decoded then return false end
	mergeConfig(config, decoded)
	syncDebugState()
	logger.info("config loaded from disk")
	return true
end

syncDebugState()
loadConfigFromDisk()

scheduleConfigSave = function()
	if not canUseFileApi() then return end
	if pendingConfigSave then pcall(task.cancel, pendingConfigSave) end
	pendingConfigSave = task.delay(CONFIG_SAVE_DELAY, function()
		pendingConfigSave = nil
		saveConfig(config)
	end)
end

-- ═══════ clampedConfig helper ═══════
local function clampedConfig(default, min, max, ...)
	return math.clamp(getConfigValue(default, ...), min, max)
end

-- ═══════ Constants ═══════
local DUNK_TYPES = {
	["360"] = "360", Reverse = "Reverse", Eastbay = "Testing2",
	["Double Clutch"] = "Testing3", ["Under the Legs"] = "Testing",
	Tomahawk = "Tomahawk", Windmill = "Windmill",
}

local fireTouch = (typeof(firetouchinterest) == "function") and firetouchinterest or nil

-- ═══════ State ═══════
local ballMagnetState = {
	tracked = {}, originals = {}, partConnections = {}, watchers = {}, touchCooldowns = {},
	enabled = false, heartbeat = nil,
}

local passiveStealEnabled = false
local passiveStealThread  = nil
local passiveStealRunId   = 0

local lastPostAssistTick        = 0
local lastAutoHookTick          = 0
local lastAutoBlockTick         = 0
local lastAutoAnkleBreakerTick  = 0
local autoAnkleBreakerRunId     = 0
local lastExtremeAutoBlockTick  = 0
local lastGuardTargetRefreshTick = 0
local lastGuardTargetSwitchTick  = 0

local cachedGuardBall      = nil
local cachedGuardTargetRoot = nil
local autoGuardDriving     = false
local autoLockActive       = false
local autoLockTargetRoot   = nil
local autoLockPreferOffBall = false
local lastAutoLockRefreshTick = 0
local autoLockTargetHistory = {}

local guardInputState = {
	holdKey       = Enum.KeyCode.F,
	toggleKey     = Enum.KeyCode.B,
	holdActive    = false,
	toggleActive  = false,
	lastToggleTick   = 0,
	lastGuardSyncTick = 0,
}

local autoBlockConnections     = {}
local blockReactiveAnimations  = {}
local stealReactiveAnimations  = {}

local cachedPlayers = {}

local function populateCachedPlayers()
	for i = #cachedPlayers, 1, -1 do cachedPlayers[i] = nil end
	for _, p in ipairs(playersService:GetPlayers()) do cachedPlayers[#cachedPlayers + 1] = p end
end

local function addCachedPlayer(p) cachedPlayers[#cachedPlayers + 1] = p end

local function removeCachedPlayer(p)
	for i = #cachedPlayers, 1, -1 do
		if cachedPlayers[i] == p then table.remove(cachedPlayers, i); break end
	end
end

-- steal reach state
local stealReachState = { originals = {} }

local GUARD_INPUT_TOGGLE_DEBOUNCE = 0.25
local AUTO_ANKLE_BREAKER_COOLDOWN = 1.5
local autoLockInputService = pcall(function() return game:GetService("UserInputService") end) and game:GetService("UserInputService") or nil

-- ═══════ Data Tables ═══════
local rigType = sharedUtil.GSettings.RigType
local runService  = services.RunService
local starterGui  = services.StarterGui
local currentCamera = workspace.CurrentCamera

local lastJumpTick      = tick()
local movementStartTick = tick()
local movementActive    = false
local loadedAnimations  = {}

local DRIBBLE_END_ANIMATIONS = {
	Ball_SpinL2R = true, Ball_SpinR2L = true,
	Ball_CrossL = true,  Ball_CrossR = true,
	Ball_HesiL = true,   Ball_HesiR = true,
	Ball_BTBL2R = true,  Ball_BTBR2L = true,
	Ball_StepbackL = true, Ball_StepbackR = true,
}

local SHOT_MARKER_ANIMATIONS = {
	Jumpshot = true, Ball_FadeBack = true,
	JumpshotRight = true, JumpshotLeft = true,
	Ball_FloaterL = true,  Ball_FloaterR = true,
	Ball_PostHookL = true, Ball_PostHookR = true,
	Ball_ReverseLayupL = true, Ball_ReverseLayupR = true,
	Ball_ShortLayupL = true,   Ball_ShortLayupR = true,
}

local RIG_PARTS = {
	R6 = {
		Torso = "Torso", ["Right Arm"] = "Right Arm", ["Left Arm"] = "Left Arm",
		["Right Leg"] = "Right Leg", ["Left Leg"] = "Left Leg",
	},
	R15 = {
		Torso = "UpperTorso", RightHand = "RightHand", LeftHand = "LeftHand",
		RLL = "RightLowerArm", LLL = "LeftLowerArm",
	},
}

local rigPartMap = RIG_PARTS[rigType]
local CHILD_TO_ARG = {}
if rigPartMap then
	for argKey, childName in pairs(rigPartMap) do CHILD_TO_ARG[childName] = argKey end
end

local DIRECTION_VELOCITY = {
	Forward         = function(cf) return cf.LookVector end,
	ForwardOpposite = function(cf) return -cf.LookVector end,
	Right           = function(cf) return cf.RightVector end,
	Left            = function(cf) return -cf.RightVector end,
	Back            = function(cf) return -cf.LookVector end,
	RightForward    = function(cf) return (cf.LookVector + cf.RightVector) / 2 end,
	LeftForward     = function(cf) return (cf.LookVector - cf.RightVector) / 2 end,
}

-- ═══════ Hook Bridge System ═══════
local function createHookBridge(targetController, controllerName)
	local originalFunctions = {}
	return setmetatable({}, {
		__index = function(_, key) return originalFunctions[key] end,
		__newindex = function(self, key, new)
			local target = targetController[key]
			if type(target) ~= "function" then
				logger.warn("hook: invalid function '" .. key .. "' on '" .. controllerName .. "'"); return
			end
			if type(new) ~= "function" then
				logger.warn("hook: non-function for '" .. key .. "' on '" .. controllerName .. "'"); return
			end
			if not originalFunctions[key] then originalFunctions[key] = target end
			local ok, err = pcall(function() hookfunction(originalFunctions[key], newcclosure(new)) end)
			if not ok then
				logger.error("hook failed '" .. key .. "' on '" .. controllerName .. "': " .. tostring(err)); return
			end
			rawset(self, key, originalFunctions[key])
			logger.info("hooked '" .. key .. "' on '" .. controllerName .. "'")
		end,
	})
end

local controllerNames = {}
for _, c in ipairs(controllersDir:GetChildren()) do
	if c:IsA("ModuleScript") then controllerNames[#controllerNames + 1] = c.Name end
end

local controllers     = {}
local knitControllers = {}
for _, name in ipairs(controllerNames) do
	local ok, ctrl = pcall(require, controllersDir:WaitForChild(name))
	if ok and ctrl then
		controllers[name] = ctrl
		local kOk, kCtrl = pcall(knit.GetController, name)
		if kOk and kCtrl then knitControllers[name] = kCtrl
		else logger.warn("knit controller '" .. name .. "' failed: " .. tostring(kCtrl)) end
	else logger.warn("require '" .. name .. "' failed: " .. tostring(ctrl)) end
end

local hookBridges = {}
for _, name in ipairs(controllerNames) do
	if controllers[name] then hookBridges[name] = createHookBridge(controllers[name], name)
	else logger.warn("no bridge for '" .. name .. "'") end
end

local function applyOverrides(controllerName, overrides)
	local bridge = hookBridges[controllerName]
	if not bridge then logger.error("no hook bridge for '" .. controllerName .. "'"); return end
	for fnName, fn in pairs(overrides) do bridge[fnName] = fn end
end

-- startup summary
local bridgedCount, knitSvcCount, knitCtrlCount = 0, 0, 0
for _ in pairs(hookBridges) do bridgedCount = bridgedCount + 1 end
for _ in pairs(knitServices) do knitSvcCount = knitSvcCount + 1 end
for _ in pairs(knitControllers) do knitCtrlCount = knitCtrlCount + 1 end
logger.info(string.format("ready — %d/%d bridged, %d knit ctrl, %d knit svc | %s",
	bridgedCount, #controllerNames, knitCtrlCount, knitSvcCount, is5v5 and "5v5" or "mypark"))

-- ═══════ Controller Aliases ═══════
local pc = knitControllers["PlayerController"]
local ic = knitControllers["InputController"]
local gc = knitControllers["GameController"]
local dc = knitControllers["DataController"]
local uc = knitControllers["UIController"]
local vc = knitControllers["VisualController"]

local controlService = knitServices["ControlService"]
local playerService  = knitServices["PlayerService"]

-- ═══════ Helpers ═══════
local function safeSetCore(fn, ...)
	local result = {}
	for _ = 1, 15 do
		result = { pcall(starterGui[fn], starterGui, ...) }
		if result[1] then break end
		runService.Stepped:Wait()
	end
	return unpack(result)
end

local function getBaseSpeed()
	return getConfigValue(false, "movement", "speedOverride") and getConfigValue(17, "movement", "speed") or 17
end

local function restoreSpeed(humanoid, gv)
	if gv and gv.Locked then return end
	humanoid.WalkSpeed = getBaseSpeed()
end

local function hasBall(character)
	return character and character:FindFirstChild("Basketball") ~= nil
end

local function getGameValues()
	return gc and gc.GameValues or nil
end

local function getTeam(player)
	return is5v5 and player.Team or player:GetAttribute("Team")
end

local function ignoreTeamPossessionChecks()
	return getConfigValue(false, "abilities", "ignoreTeamPossessionChecks") == true
end

local function playersShareTeam(a, b)
	if not a or not b then return false end
	if is5v5 then return a.Team == b.Team end
	local at = a:GetAttribute("Team")
	return at ~= nil and b:GetAttribute("Team") == at
end

local function localTeamHasPossession(gv)
	return gv and gv.Possession ~= nil and getTeam(localPlayer) == gv.Possession
end

local function stopDribbleAnims(fade)
	pc:StopAnimation("Ball_DribbleR", fade)
	pc:StopAnimation("Ball_DribbleL", fade)
end

local function playDribbleAnim(hand, speed, fade)
	if hand == "Right" then pc:PlayAnimation("Ball_DribbleR", speed, fade)
	elseif hand == "Left" then pc:PlayAnimation("Ball_DribbleL", speed, fade) end
end

local function getAutoAnkleBreakerMove()
	local _, bv = basketball:GetValues()
	if not bv then return nil end
	if bv.Hand == "Right" then return "Left" end
	if bv.Hand == "Left" then return "Right" end
	return nil
end

local function distanceSquared(a, b)
	local d = a - b; return d:Dot(d)
end

local function getClosestPlayer(withBall)
	local myChar = localPlayer.Character
	local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
	if not myRoot then return nil end
	local ignore = ignoreTeamPossessionChecks()
	local myPos = myRoot.Position
	local bestEnemy, bestEnemyDSq = nil, math.huge
	local bestAny, bestAnyDSq = nil, math.huge

	for i = 1, #cachedPlayers do
		local other = cachedPlayers[i]
		if other ~= localPlayer then
			local oChar = other.Character
			local oRoot = oChar and oChar:FindFirstChild("HumanoidRootPart")
			if oRoot then
				local dSq = distanceSquared(myPos, oRoot.Position)
				local oBall = oChar:FindFirstChild("Basketball") ~= nil
				local diffTeam = ignore or not playersShareTeam(other, localPlayer)
				if not withBall then
					if diffTeam and dSq < bestEnemyDSq then bestEnemyDSq = dSq; bestEnemy = other end
					if dSq < bestAnyDSq then bestAnyDSq = dSq; bestAny = other end
				else
					if diffTeam and oBall and dSq < bestEnemyDSq then bestEnemyDSq = dSq; bestEnemy = other end
					if oBall and dSq < bestAnyDSq then bestAnyDSq = dSq; bestAny = other end
				end
			end
		end
	end
	return bestEnemy or bestAny
end

local function onCourtWith(other)
	if not other then return false end
	local mc = localPlayer:GetAttribute("Court")
	local oc = other:GetAttribute("Court")
	if mc == nil or oc == nil then return true end
	return mc == oc
end

local function playersAreOpponents(other)
	if not other or other == localPlayer then return false end
	if ignoreTeamPossessionChecks() then return true end
	return not playersShareTeam(other, localPlayer)
end

local function resolveBallAttach(character)
	if not character then return nil end
	local tool = character:FindFirstChild("Basketball")
	if not tool then return nil end
	local attach = tool:FindFirstChild("Attach")
	if attach and attach:IsA("BasePart") then return attach end
	local handle = tool:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then return handle end
	return tool:FindFirstChildWhichIsA("BasePart")
end

local function getMoveBoost(tag)
	if not tag then return 1 end
	local sec = getConfigTable(nil, "moves", tag)
	local b = sec and sec.boost
	return (type(b) == "number" and b > 0) and b or 1
end

local function getPhysicalBlockboxSize()
	local s = math.clamp(getConfigValue(3, "defense", "blockboxSize"), 0, 200)
	return Vector3.new(s, s, s)
end

local function refreshPhysicalBlockbox()
	if pc and pc.Args and pc.Args.Blockbox then pc.Args.Blockbox.Size = getPhysicalBlockboxSize() end
end

local function isAutoGuardRequested()
	return config.defense.autoGuard == true and (guardInputState.holdActive or guardInputState.toggleActive)
end

local function syncDesiredGuardState(shouldGuard, force)
	if not ic or not pc or not pc.Args then return end
	local char = pc.Args.Character
	if not char or not char.Parent then return end
	if shouldGuard and hasBall(char) then return end
	if (char:GetAttribute("Guarding") == true) == shouldGuard then return end
	local now = tick()
	if not force and now - guardInputState.lastGuardSyncTick < 0.12 then return end
	guardInputState.lastGuardSyncTick = now
	pcall(function() ic:Guard(shouldGuard) end)
end

-- body mover helpers (no trace conditionals)
local function clearBodyGyro(args)
	if not args or not args.BodyGyro then return end
	args.BodyGyro.MaxTorque = Vector3.new(0, 0, 0)
	args.BodyGyro.CFrame = CFrame.new(0, 0, 0)
end

local function setBodyGyroLook(args, lookCF)
	if not args or not args.BodyGyro or not lookCF then return end
	local torque = clampedConfig(1000000, 0, 2000000, "movement", "bodyGyroTorque")
	args.BodyGyro.MaxTorque = Vector3.new(0, torque, 0)
	args.BodyGyro.CFrame = lookCF
end

local function clearBodyVelocity(args)
	if not args or not args.BodyVelocity then return end
	args.BodyVelocity.MaxForce = Vector3.new(0, 0, 0)
	args.BodyVelocity.Velocity = Vector3.new(0, 0, 0)
end

local function setBodyVelocity(args, velocity, planarOnly)
	if not args or not args.BodyVelocity then return end
	local force = clampedConfig(1000000, 0, 2000000, "movement", "bodyVelocityForce")
	args.BodyVelocity.Velocity = velocity or Vector3.new(0, 0, 0)
	if planarOnly then args.BodyVelocity.MaxForce = Vector3.new(force, 0, force)
	else args.BodyVelocity.MaxForce = Vector3.new(force, force, force) end
end

-- guard target resolution
local function resolveGuardTarget(forceRefresh)
	local now = tick()
	if not forceRefresh and now - lastGuardTargetRefreshTick < clampedConfig(0.05, 0.01, 0.5, "defense", "guardRefreshInterval") then
		if cachedGuardBall and cachedGuardBall.Parent and cachedGuardTargetRoot and cachedGuardTargetRoot.Parent then
			return cachedGuardBall, cachedGuardTargetRoot
		end
	end
	lastGuardTargetRefreshTick = now

	local candidateBall, candidateRoot
	local ballOwner = getClosestPlayer(true)
	local ballOwnerChar = ballOwner and ballOwner.Character
	if ballOwnerChar then
		candidateBall = resolveBallAttach(ballOwnerChar)
		candidateRoot = ballOwnerChar:FindFirstChild("HumanoidRootPart")
	end

	if not (candidateBall and candidateRoot) and is5v5 then
		for _, tagged in pairs(collectionService:GetTagged("Ball")) do
			if tagged.Name == "Attach" and tagged.Parent and tagged.Parent:IsA("Tool") then
				local owner = tagged.Parent.Parent
				local root = owner and owner:FindFirstChild("HumanoidRootPart")
				if root then candidateBall = tagged; candidateRoot = root; break end
			end
		end
	elseif not (candidateBall and candidateRoot) then
		local cb = sharedUtil.Ball:GetClosestBall(localPlayer)
		if cb and cb.Name == "Attach" and cb.Parent and cb.Parent:IsA("Tool") then
			candidateBall = cb
			candidateRoot = cb.Parent.Parent and cb.Parent.Parent:FindFirstChild("HumanoidRootPart") or nil
		end
	end

	if not (candidateBall and candidateRoot) then
		cachedGuardBall = nil; cachedGuardTargetRoot = nil; return nil, nil
	end

	if cachedGuardTargetRoot and cachedGuardTargetRoot.Parent and cachedGuardBall and cachedGuardBall.Parent then
		local switching = cachedGuardTargetRoot ~= candidateRoot or cachedGuardBall ~= candidateBall
		if switching and now - lastGuardTargetSwitchTick < clampedConfig(0.3, 0.05, 1, "defense", "guardTargetSwitchCooldown") then
			return cachedGuardBall, cachedGuardTargetRoot
		end
		if switching then lastGuardTargetSwitchTick = now end
	else lastGuardTargetSwitchTick = now end

	cachedGuardBall = candidateBall; cachedGuardTargetRoot = candidateRoot
	return cachedGuardBall, cachedGuardTargetRoot
end

-- auto lock
local function findAutoLockTarget(preferOffBall)
	local myRoot = localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart")
	if not myRoot then return nil end
	local bestPref, bestPrefDSq = nil, math.huge
	local bestFall, bestFallDSq = nil, math.huge
	for i = 1, #cachedPlayers do
		local other = cachedPlayers[i]
		if other ~= localPlayer and playersAreOpponents(other) and onCourtWith(other) then
			local oRoot = other.Character and other.Character:FindFirstChild("HumanoidRootPart")
			if oRoot then
				local oBall = hasBall(other.Character)
				local dSq = distanceSquared(myRoot.Position, oRoot.Position)
				local pref = (preferOffBall and not oBall) or (not preferOffBall and oBall)
				if pref then
					if dSq < bestPrefDSq then bestPrefDSq = dSq; bestPref = other end
				elseif dSq < bestFallDSq then bestFallDSq = dSq; bestFall = other end
			end
		end
	end
	local tp = bestPref or bestFall
	return tp and tp.Character and tp.Character:FindFirstChild("HumanoidRootPart") or nil
end

local function getAutoLockLookPosition(targetRoot)
	if not targetRoot then return nil end
	local now = tick()
	local fwd = Vector3.new(targetRoot.CFrame.LookVector.X, 0, targetRoot.CFrame.LookVector.Z)
	local last = autoLockTargetHistory[targetRoot]
	if last then
		local dt = math.max(now - last.tick, 1 / 240)
		local vel = (targetRoot.Position - last.position) / dt
		local pv = Vector3.new(vel.X, 0, vel.Z)
		if pv.Magnitude > 0.05 then
			local bf = fwd.Magnitude > 0 and fwd.Unit or Vector3.new(0, 0, -1)
			local blended = pv.Unit * 0.7 + bf * 0.3
			if blended.Magnitude > 0 then fwd = blended.Unit end
		elseif fwd.Magnitude > 0 then fwd = fwd.Unit end
	elseif fwd.Magnitude > 0 then fwd = fwd.Unit end
	autoLockTargetHistory[targetRoot] = { position = targetRoot.Position, tick = now }
	local lead = clampedConfig(3, 0, 15, "defense", "autoLockLeadDistance")
	return Vector3.new(targetRoot.Position.X + fwd.X * lead, targetRoot.Position.Y, targetRoot.Position.Z + fwd.Z * lead)
end

local function abilityUnlocked(name)
	if config.abilities.unlockAllMoves then return true end
	return dc and dc.Data and dc.Data.Abilities and dc.Data.Abilities[name]
end

local function isBenched()
	return is5v5 and localPlayer:GetAttribute("Benched") ~= nil
end

local function vector3Close(a, b, eps)
	return (a - b).Magnitude <= (eps or 0.001)
end

local function clearTable(tbl)
	if not tbl then return end
	if table.clear then table.clear(tbl) else for k in pairs(tbl) do tbl[k] = nil end end
end

local function getOppositeHand(hand)
	return hand == "Right" and "Left" or "Right"
end

local function waitForArgsFlag(flag, timeout)
	if not ic or not ic.Args then return false end
	timeout = timeout or 2
	local start = tick()
	while not ic.Args[flag] do
		if not ic or not ic.Args then return false end
		task.wait()
		if tick() - start > timeout then return false end
	end
	return true
end

local function setWalkSpeedSafely(humanoid, speed)
	humanoid.WalkSpeed = config.movement.speedOverride and config.movement.speed or speed
end

-- ═══════ Post Hand Scale ═══════
local setPostHandScale, resetPostHandScale, resetAllPostHandScale, updateActivePostHandScale

local function getPostHandPart(args, hand)
	if not args then return nil end
	if rigType == "R6" then
		return hand == "Right" and args["Right Arm"] or args["Left Arm"]
	else
		return hand == "Right" and args.RightHand or args.LeftHand
	end
end

setPostHandScale = function(args, hand, scale)
	if not args or type(scale) ~= "number" then return end
	local part = getPostHandPart(args, hand)
	if not (part and part:IsA("BasePart")) then return end
	args._postHandOriginals = args._postHandOriginals or {}
	local orig = args._postHandOriginals[part]
	if not orig then orig = part.Size; args._postHandOriginals[part] = orig end
	local cs = math.clamp(scale, 0.5, 3)
	if cs <= 1.01 then
		if not vector3Close(part.Size, orig) then part.Size = orig end; return
	end
	local ns = Vector3.new(orig.X * cs, orig.Y, orig.Z * cs)
	if not vector3Close(part.Size, ns) then part.Size = ns end
end

resetPostHandScale = function(args, hand)
	if not args then return end
	local part = getPostHandPart(args, hand)
	local orig = args._postHandOriginals
	if part and orig and orig[part] and not vector3Close(part.Size, orig[part]) then
		part.Size = orig[part]
	end
end

resetAllPostHandScale = function(args)
	if not args then return end
	resetPostHandScale(args, "Right"); resetPostHandScale(args, "Left")
end

updateActivePostHandScale = function()
	local pa = pc and pc.Args; if not pa then return end
	local ps = config.moves.post
	if ic and ic.Args and ic.Args.Posting then
		setPostHandScale(pa, getOppositeHand(ic.Args.PostDirection or "Right"), ps.handScale or 1)
	else resetAllPostHandScale(pa) end
end

-- forward declare lockAction / unlockAction
local lockAction, unlockAction, applyCooldown

local function enterPostState(ballHand)
	setPostHandScale(pc.Args, getOppositeHand(ballHand), config.moves.post.handScale or 1)
	setBodyGyroLook(pc.Args, pc.Args.BodyGyro.CFrame)
	stopDribbleAnims(0.2)
	pc:PlayAnimation(ballHand == "Right" and "Ball_PostDribbleR" or "Ball_PostDribbleL", 1, 0.2)
	lockAction({ walkSpeed = 14, autoRotate = false })
end

local function exitPostState(ballHand)
	resetAllPostHandScale(pc.Args)
	clearBodyGyro(pc.Args)
	pc:StopAnimation("Ball_PostDribbleR"); pc:StopAnimation("Ball_PostDribbleL")
	playDribbleAnim(ballHand)
end

lockAction = function(opts)
	local ia = ic and ic.Args
	local pa = pc and pc.Args
	if ia then
		if opts.canShoot ~= nil then ia.CanShoot = opts.canShoot end
		if opts.canDribble ~= nil then ia.CanDribble = opts.canDribble end
		if opts.inAction ~= nil then ia.InAction = opts.inAction end
	end
	if pa and pa.Humanoid then
		if opts.walkSpeed ~= nil then pa.Humanoid.WalkSpeed = opts.walkSpeed end
		if opts.autoRotate ~= nil then pa.Humanoid.AutoRotate = opts.autoRotate end
	end
end

unlockAction = function(gv)
	if pc then pc:StopMovement() end
	local pa = pc and pc.Args
	if pa and pa.Humanoid then
		pa.Humanoid.AutoRotate = true
		restoreSpeed(pa.Humanoid, gv)
	end
end

applyCooldown = function(key, dur)
	if not ic or not ic.Args then return end
	ic.Args[key] = true
	if dur and dur > 0 then
		task.delay(dur, function() if ic and ic.Args then ic.Args[key] = false end end)
	else ic.Args[key] = false end
end

-- ═══════ Ball Magnet System ═══════
local function resolveBasketballPart(inst)
	if not inst then return nil end
	if inst:IsA("BasePart") and inst.Name == "Basketball" then return inst end
	if inst:IsA("Tool") and inst.Name == "Basketball" then
		return inst:FindFirstChild("Handle") or inst:FindFirstChildWhichIsA("BasePart")
	end
	return nil
end

local function isInsideAnyCharacter(inst)
	for i = 1, #cachedPlayers do
		local char = cachedPlayers[i] and cachedPlayers[i].Character
		if char and inst:IsDescendantOf(char) then return true end
	end
	return false
end

local function cleanupBallMagnetForPart(part, restore)
	if not part then return end
	local bucket = ballMagnetState.partConnections[part]
	if bucket then
		for _, conn in ipairs(bucket) do conn:Disconnect() end
		ballMagnetState.partConnections[part] = nil
	end
	if restore then
		local orig = ballMagnetState.originals[part]
		if orig and part.Parent then part.Size = orig.size; part.Anchored = orig.anchored end
	end
	ballMagnetState.originals[part] = nil
	ballMagnetState.tracked[part] = nil
	ballMagnetState.touchCooldowns[part] = nil
end

local function applyBallMagnet(part)
	if not ballMagnetState.enabled then return end
	if not part or not part:IsA("BasePart") then return end
	if isInsideAnyCharacter(part) then return end
	if not ballMagnetState.tracked[part] and ballMagnetState.originals[part] then
		ballMagnetState.originals[part] = nil
	end
	if not ballMagnetState.originals[part] then
		ballMagnetState.originals[part] = { size = part.Size, anchored = part.Anchored }
	end
	local orig = ballMagnetState.originals[part]
	local targetSize = orig.size
	if config.ballMagnet.resizeEnabled ~= false then
		local sf = math.clamp((config.ballMagnet.scale or 50) / 50, 0.6, 2.5)
		targetSize = orig.size * sf
	end
	if not vector3Close(part.Size, targetSize, 0.01) then part.Size = targetSize end
	ballMagnetState.tracked[part] = true
	if not ballMagnetState.partConnections[part] then
		ballMagnetState.partConnections[part] = {
			part.AncestryChanged:Connect(function(_, parent)
				if not parent then cleanupBallMagnetForPart(part, false)
				elseif isInsideAnyCharacter(part) then cleanupBallMagnetForPart(part, true) end
			end),
		}
	end
end

local function enableBallMagnetWatchers()
	if ballMagnetState.watchers.child then return end
	local function handle(inst)
		if not ballMagnetState.enabled then return end
		local bp = resolveBasketballPart(inst)
		if bp then applyBallMagnet(bp) end
	end
	ballMagnetState.watchers.child = workspace.ChildAdded:Connect(handle)
	ballMagnetState.watchers.desc  = workspace.DescendantAdded:Connect(handle)
end

local function disableBallMagnetWatchers()
	for key, conn in pairs(ballMagnetState.watchers) do
		conn:Disconnect(); ballMagnetState.watchers[key] = nil
	end
end

local function resolveTouchTarget(part)
	local ti = part:FindFirstChildWhichIsA("TouchTransmitter") or part:FindFirstChild("TouchInterest")
	if ti then return part end
	local pTool = part.Parent
	if pTool and pTool:IsA("Tool") then
		local handle = pTool:FindFirstChild("Handle")
		if handle and handle:FindFirstChildWhichIsA("TouchTransmitter") then return handle end
	end
	return part
end

local function startBallMagnetHeartbeat()
	if ballMagnetState.heartbeat then return end
	ballMagnetState.heartbeat = runService.Heartbeat:Connect(function()
		if not ballMagnetState.enabled then return end
		local pa = pc and pc.Args
		local root = pa and pa.HumanoidRootPart
		local rh = pa and (pa.RightHand or pa["Right Arm"])
		if not root then return end
		local rangeSq = (config.ballMagnet.range or 20) ^ 2
		local nowTick = tick()
		for part in pairs(ballMagnetState.tracked) do
			if part and part.Parent then
				if isInsideAnyCharacter(part) then cleanupBallMagnetForPart(part, true)
				else
					if distanceSquared(part.Position, root.Position) <= rangeSq then
						local last = ballMagnetState.touchCooldowns[part] or 0
						if nowTick - last >= clampedConfig(0.15, 0.01, 1, "ballMagnet", "touchCooldown") then
							ballMagnetState.touchCooldowns[part] = nowTick
							if fireTouch and config.ballMagnet.directTouchEnabled ~= false then
								local tp = resolveTouchTarget(part)
								pcall(fireTouch, root, tp, 0); pcall(fireTouch, root, tp, 1)
								if rh and rh.Parent then pcall(fireTouch, rh, tp, 0); pcall(fireTouch, rh, tp, 1) end
							end
						end
					end
				end
			end
		end
	end)
end

local function stopBallMagnetHeartbeat()
	if ballMagnetState.heartbeat then ballMagnetState.heartbeat:Disconnect(); ballMagnetState.heartbeat = nil end
end

local function refreshBallMagnet()
	if not ballMagnetState.enabled then return end
	for part in pairs(ballMagnetState.tracked) do if part and part.Parent then applyBallMagnet(part) end end
	for _, inst in ipairs(workspace:GetDescendants()) do
		local bp = resolveBasketballPart(inst); if bp then applyBallMagnet(bp) end
	end
end

local function setBallMagnet(enabled, skipSave)
	config.ballMagnet.enabled = enabled == true
	if skipSave ~= true then scheduleConfigSave() end
	if config.ballMagnet.enabled then
		if ballMagnetState.enabled then refreshBallMagnet(); return end
		ballMagnetState.enabled = true
		if not fireTouch and config.ballMagnet.directTouchEnabled ~= false then
			logger.warn("ball magnet direct touch unavailable: firetouchinterest missing")
		end
		enableBallMagnetWatchers()
		for _, child in ipairs(workspace:GetDescendants()) do
			local bp = resolveBasketballPart(child); if bp then applyBallMagnet(bp) end
		end
		startBallMagnetHeartbeat()
	else
		if not ballMagnetState.enabled then return end
		ballMagnetState.enabled = false
		stopBallMagnetHeartbeat(); disableBallMagnetWatchers()
		local list = {}; for part in pairs(ballMagnetState.tracked) do list[#list + 1] = part end
		for _, part in ipairs(list) do cleanupBallMagnetForPart(part, true) end
		clearTable(ballMagnetState.tracked); clearTable(ballMagnetState.originals)
		clearTable(ballMagnetState.partConnections); clearTable(ballMagnetState.touchCooldowns)
	end
end

-- ═══════ Passive Steal ═══════
local function startPassiveStealLoop(runId)
	passiveStealThread = task.spawn(function()
		while passiveStealEnabled and passiveStealRunId == runId do
			if ic and ic.Args then pcall(function() ic:Steal() end) end
			task.wait(clampedConfig(0.3, 0.05, 2, "moves", "steal", "passiveInterval"))
		end
		if passiveStealRunId == runId then passiveStealThread = nil end
	end)
end

local function setPassiveSteal(enabled, skipSave)
	config.moves.steal.passiveSteal = enabled == true
	if skipSave ~= true then scheduleConfigSave() end
	if config.moves.steal.passiveSteal then
		if passiveStealEnabled and passiveStealThread then return end
		passiveStealEnabled = true
		passiveStealRunId = passiveStealRunId + 1
		startPassiveStealLoop(passiveStealRunId)
	else
		passiveStealEnabled = false
		passiveStealRunId = passiveStealRunId + 1
		passiveStealThread = nil
	end
end

-- ═══════ Steal Reach ═══════
local function applyStealReach()
	local char = localPlayer.Character; if not char then return end
	local mult = math.clamp(config.moves.steal.reachMultiplier or 1.5, 1, 5)
	local arms = rigType == "R6"
		and { char:FindFirstChild("Right Arm"), char:FindFirstChild("Left Arm") }
		or  { char:FindFirstChild("RightHand"), char:FindFirstChild("LeftHand"),
		      char:FindFirstChild("RightLowerArm"), char:FindFirstChild("LeftLowerArm") }
	for _, arm in ipairs(arms) do
		if arm and arm:IsA("BasePart") then
			if not stealReachState.originals[arm] then
				stealReachState.originals[arm] = { size = arm.Size, transparency = arm.Transparency, massless = arm.Massless }
			end
			arm.Size = stealReachState.originals[arm].size * mult
			arm.Transparency = 1; arm.CanCollide = false; arm.Massless = true
		end
	end
end

local function clearStealReach()
	for arm, orig in pairs(stealReachState.originals) do
		if arm and arm.Parent then
			arm.Size = orig.size; arm.Transparency = orig.transparency
			arm.CanCollide = false; arm.Massless = orig.massless
		end
	end
	clearTable(stealReachState.originals)
end

-- ═══════ Teleporter ═══════
local function rejoinServer()
	local ts = services.TeleportService
	if ts then pcall(ts.TeleportToPlaceInstance, ts, game.PlaceId, game.JobId, localPlayer) end
end

local function serverHop()
	local ts = services.TeleportService; if not ts then return end
	local servers = {}
	local cursor = ""
	repeat
		local ok, result = pcall(function()
			return game:HttpGet("https://games.roblox.com/v1/games/" .. tostring(game.PlaceId) .. "/servers/Public?sortOrder=Asc&limit=100&cursor=" .. cursor)
		end)
		if ok and result then
			local dOk, decoded = pcall(HttpService.JSONDecode, HttpService, result)
			if dOk and decoded then
				cursor = decoded.nextPageCursor or ""
				for _, srv in pairs(decoded.data or {}) do
					if srv.playing < srv.maxPlayers and srv.id ~= game.JobId then
						servers[#servers + 1] = srv
					end
				end
			else break end
		else break end
	until cursor == ""
	if #servers > 0 then
		table.sort(servers, function(a, b) return a.playing < b.playing end)
		pcall(ts.TeleportToPlaceInstance, ts, game.PlaceId, servers[1].id, localPlayer)
	else logger.warn("server hop: no available servers") end
end

local function teleportToRanked()
	local uiCtrlFolder = controllersDir:FindFirstChild("UIController")
	if uiCtrlFolder then
		local ok, parkModule = pcall(function()
			local ps = uiCtrlFolder:FindFirstChild("Park") or uiCtrlFolder:WaitForChild("Park", 5)
			if ps then return require(ps) end
		end)
		if ok and type(parkModule) == "table" and type(parkModule.Teleport) == "function" then
			pcall(parkModule.Teleport, parkModule, "Ranked")
			return
		end
	end
	logger.warn("ranked teleport unavailable")
end

-- init cached players
populateCachedPlayers()
playersService.PlayerAdded:Connect(addCachedPlayer)
playersService.PlayerRemoving:Connect(removeCachedPlayer)

-- ═══════ PlayerController Overrides ═══════
local pcOverrides = {}

pcOverrides.CharacterAdded = function(self, character)
	currentCamera = workspace.CurrentCamera
	self.Args.Setup = false
	self.Args.toolEquipped = false
	self.Args.Moved = false
	if not is5v5 then self.Args.SpawnTick = tick() end
	self.Args.EmoteSpeed = 8
	movementActive = false

	for _, conn in pairs(self.Connections) do conn:Disconnect() end
	self.Connections = {}
	loadedAnimations = {}

	self.Args.Character = character
	self.Args.Humanoid = character:WaitForChild("Humanoid")
	self.Args.HumanoidRootPart = character:WaitForChild("HumanoidRootPart")

	if rigPartMap then
		for argKey, childName in pairs(rigPartMap) do
			self.Args[argKey] = character:WaitForChild(childName)
		end
	end

	-- body movers
	self.Args.BodyGyro = Instance.new("BodyGyro")
	self.Args.BodyGyro.CFrame = CFrame.new(0, 0, 0)
	self.Args.BodyGyro.D = 500
	self.Args.BodyGyro.MaxTorque = Vector3.new(0, 0, 0)
	self.Args.BodyGyro.P = 6500
	self.Args.BodyGyro.Parent = self.Args.HumanoidRootPart

	self.Args.BodyVelocity = Instance.new("BodyVelocity")
	self.Args.BodyVelocity.MaxForce = Vector3.new(0, 0, 0)
	self.Args.BodyVelocity.P = 1250
	self.Args.BodyVelocity.Velocity = Vector3.new(0, 0, 0)
	self.Args.BodyVelocity.Parent = self.Args.HumanoidRootPart

	-- blockbox
	self.Args.Folder = Instance.new("Folder")
	self.Args.Folder.Parent = self.Args.Character

	self.Args.Blockbox = Instance.new("Part")
	self.Args.Blockbox.Transparency = 1
	self.Args.Blockbox.Size = getPhysicalBlockboxSize()
	self.Args.Blockbox.CanCollide = false
	self.Args.Blockbox.Massless = true
	self.Args.Blockbox.CFrame = self.Args.HumanoidRootPart.CFrame
	self.Args.Blockbox.Parent = self.Args.Folder

	self.Args.BoxWeld = Instance.new("WeldConstraint")
	self.Args.BoxWeld.Part0 = self.Args.Blockbox
	self.Args.BoxWeld.Part1 = self.Args.HumanoidRootPart
	self.Args.BoxWeld.Parent = self.Args.BoxWeld.Part0

	-- connections
	self.Connections.Death = self.Args.Humanoid.Died:Connect(function()
		if not is5v5 then self:CancelEmote() end
	end)

	self.Connections.Child = self.Args.Character.ChildAdded:Connect(function(child)
		if child:IsA("BasePart") then
			if child.Name == "Head" then self.Args.Head = child end
			local argKey = CHILD_TO_ARG[child.Name]
			if argKey then self.Args[argKey] = child end
			return
		end
		if child:IsA("Tool") then self.Args.toolEquipped = true end
	end)

	self.Connections.MovingChange = self.Args.Humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(function()
		if not is5v5 then
			if dc.Data and dc.Data.AFKBenchmark ~= false then
				playerService.AFKToggle:Fire(false)
			end
		end
		if self.Args.Moved == false then self.Args.Moved = true end
		if not is5v5 then
			if self.Args.Emoting == true and self.Args.Humanoid.MoveDirection.Magnitude > 0 and self.Args.Humanoid.WalkSpeed > 0 then
				controlService.StopEmote:Fire()
			end
		end
	end)

	self.Connections.ToolUnequip = self.Args.Character.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") then self.Args.toolEquipped = false end
	end)

	-- main per-frame loop (guard positioning, post assist, movement timeout)
	self.Connections.HeartbeatLoop = runService.RenderStepped:Connect(function()
		local guardRequested = isAutoGuardRequested()
		local charGuarding = self.Args.Character:GetAttribute("Guarding") == true

		if charGuarding or guardRequested then
			local closestBall, guardTargetRoot = resolveGuardTarget(false)
			if closestBall and guardTargetRoot then
				local rootPos = self.Args.HumanoidRootPart.Position
				setBodyGyroLook(self.Args, CFrame.lookAt(rootPos, Vector3.new(guardTargetRoot.Position.X, rootPos.Y, guardTargetRoot.Position.Z)))

				if config.defense.autoGuard then
					local goalPart = sharedUtil.Ball:GetGoal(localPlayer)
					local guardPoint
					if goalPart then
						local toGoal = Vector3.new(goalPart.Position.X - closestBall.Position.X, 0, goalPart.Position.Z - closestBall.Position.Z)
						local goalDist = toGoal.Magnitude
						if goalDist > 0.1 then
							guardPoint = closestBall.Position + toGoal.Unit * math.clamp(goalDist - 1, 1, 4)
						end
					end
					if not guardPoint then
						local ownerLook = guardTargetRoot.CFrame.LookVector
						guardPoint = closestBall.Position + Vector3.new(ownerLook.X, 0, ownerLook.Z) * 3
					end
					guardPoint = Vector3.new(guardPoint.X, rootPos.Y, guardPoint.Z)
					local toTarget = Vector3.new(guardPoint.X - rootPos.X, 0, guardPoint.Z - rootPos.Z)
					autoGuardDriving = true
					if toTarget.Magnitude > 0.05 then
						local minSpd = clampedConfig(6, 0, 40, "defense", "autoGuardMinSpeed")
						local maxSpd = math.max(minSpd, clampedConfig(32, 0, 60, "defense", "autoGuardMaxSpeed"))
						local dScale = math.clamp(toTarget.Magnitude / 3, 0.35, 1)
						local gSpd = math.clamp(minSpd + (toTarget.Magnitude * clampedConfig(25, 1, 60, "defense", "autoGuardSpeedFactor") * dScale), minSpd, maxSpd)
						setBodyVelocity(self.Args, toTarget.Unit * gSpd, true)
					else clearBodyVelocity(self.Args) end
				elseif autoGuardDriving then
					autoGuardDriving = false; clearBodyVelocity(self.Args)
				end
			elseif autoGuardDriving then
				autoGuardDriving = false; clearBodyVelocity(self.Args)
			end
		else
			if autoGuardDriving then autoGuardDriving = false; clearBodyVelocity(self.Args) end
			ic:HandleDribbleCheck()

			local postGoal = ic.Args.Posting == true and sharedUtil.Ball:GetGoal(localPlayer)
			if postGoal then
				local rotOff = ic.Args.PostDirection == "Right" and CFrame.Angles(0, -math.pi / 2, 0) or CFrame.Angles(0, math.pi / 2, 0)
				local rootPos = self.Args.HumanoidRootPart.Position
				local postCfg = config.moves.post
				local oppPlayer = getClosestPlayer(false)
				local oppRoot = oppPlayer and oppPlayer.Character and oppPlayer.Character:FindFirstChild("HumanoidRootPart")
				local postLookTarget = postGoal
				if postCfg.faceDefender and oppRoot and (rootPos - oppRoot.Position).Magnitude <= math.max(postCfg.dropstepRange or 7, 14) then
					postLookTarget = oppRoot
				end
				setBodyGyroLook(self.Args, CFrame.lookAt(rootPos, Vector3.new(postLookTarget.Position.X, rootPos.Y, postLookTarget.Position.Z)) * rotOff)

				if sharedUtil.Math:XYMagnitude(self.Args.HumanoidRootPart.Position, postGoal.Position) > 38 and not postCfg.unlockRange then
					ic:Post(false)
				end

				setPostHandScale(self.Args, getOppositeHand(ic.Args.PostDirection or "Right"), postCfg.handScale or 1)

				-- auto dropstep
				local root = self.Args.HumanoidRootPart
				local now = tick()
				local rangeUnlocked = postCfg.unlockRange == true

				if postCfg.autoDropstep and oppRoot and ic.Args.CanDribble ~= false and ic.Args.InAction ~= true then
					local pv = Vector3.new(oppRoot.Position.X - root.Position.X, 0, oppRoot.Position.Z - root.Position.Z)
					local pd = pv.Magnitude
					local dr = postCfg.dropstepRange or 7
					if (rangeUnlocked or pd <= dr) and pd > 0.1 then
						local fDot = root.CFrame.LookVector:Dot(pv.Unit)
						if fDot > -0.7 and now - lastPostAssistTick >= clampedConfig(1.2, 0, 5, "moves", "post", "assistCooldown") then
							lastPostAssistTick = now
							local rel = root.CFrame:PointToObjectSpace(oppRoot.Position)
							local spin = (rel.X >= 0) and "SpinLeft" or "SpinRight"
							task.spawn(function() if ic then ic:Dribble(spin) end end)
						end
					end
				end

				-- auto hook
				if postCfg.autoHook and postGoal and ic.Args.CanShoot ~= false and ic.Args.Holding ~= true and ic.Args.InAction ~= true then
					local hookHolder = self.Args.Character and self.Args.Character:FindFirstChild("Basketball")
					if hookHolder and now - lastAutoHookTick >= clampedConfig(2, 0, 5, "moves", "post", "hookCooldown") then
						local goalDist = sharedUtil.Math:XYMagnitude(root.Position, postGoal.Position)
						local hookRange = postCfg.hookRange or 8.5
						if rangeUnlocked or goalDist <= hookRange then
							lastAutoHookTick = now
							local shotSpeedCfg = config.moves.jumpshot.shotSpeed or 1.25
							local relDelay = math.clamp(0.35 / math.max(shotSpeedCfg, 0.1), 0.05, 0.45)
							task.delay(clampedConfig(0.32, 0, 1, "moves", "post", "hookTriggerDelay"), function()
								if not (self.Args and self.Args.Character and self.Args.Character:FindFirstChild("Basketball")) then return end
								if not ic then return end
								if ic.Args then ic.Args.CanShoot = true; ic.Args.Holding = false end
								ic:Shoot(true)
								task.delay(relDelay, function() if ic then ic:Shoot(false) end end)
							end)
						end
					end
				end
			else
				resetAllPostHandScale(self.Args)
			end
		end

		-- movement timeout
		local movTimeout = is5v5 and 3.5 or 3
		if tick() - movementStartTick > movTimeout and movementActive then
			self:StopMovement()
			if not is5v5 and self.Args.Humanoid.WalkSpeed == 0 then
				self.Args.Humanoid.WalkSpeed = getBaseSpeed()
			end
		end
	end)

	-- block detection
	local blockDebounce = false
	self.Connections.BlockDetection = self.Args.Blockbox.Touched:Connect(function(hit)
		if config.defense.antiBump then return end
		if self.Args.BeingBlocked ~= nil then return end
		if not hit.Parent:FindFirstChild("Humanoid") then return end
		if not hit.Parent:GetAttribute("Screening") and (not hit.Parent:GetAttribute("Posting") or blockDebounce) then return end

		local postingSide = hit.Parent:GetAttribute("Posting")
		local isPost = postingSide == "Right" or postingSide == "Left"
		local head = hit.Parent:FindFirstChild("Head")
		if not head then return end

		local srcPlayer = playersService:GetPlayerFromCharacter(hit.Parent)
		local isEnemy = srcPlayer and (ignoreTeamPossessionChecks() or not playersShareTeam(srcPlayer, localPlayer)) or false

		if isPost then
			local sideDot = (head.CFrame.RightVector * (postingSide == "Right" and -1 or 1)):Dot((self.Args.HumanoidRootPart.Position - head.Position).Unit)
			if math.deg(math.acos(sideDot)) > 75 then isEnemy = false end
		else
			local frontDot = self.Args.HumanoidRootPart.CFrame.LookVector:Dot((head.Position - self.Args.HumanoidRootPart.Position).Unit)
			if math.deg(math.acos(frontDot)) > 90 then isEnemy = false end
		end
		if not isEnemy then return end

		blockDebounce = true
		if isPost then controlService.PostBlocked:Fire() end
		self.Args.BeingBlocked = true
		self:PlayAnimation("Push", isPost and 1.75 or 1.5)
		self:StartMovement("Back", isPost and (is5v5 and 6 or 5) or 4, hit)
		self.Args.Humanoid.WalkSpeed = 0

		task.wait(isPost and (is5v5 and 0.4 or 0.35) or 0.8)
		self:StopMovement()
		self.Args.Humanoid.WalkSpeed = getBaseSpeed()
		self.Args.BeingBlocked = nil
		if self.Args.Character:GetAttribute("Guarding") == true then
			setBodyGyroLook(self.Args, self.Args.BodyGyro.CFrame)
		end
		task.wait(0.9)
		blockDebounce = false
	end)

	self.Connections.JumpCooldown = self.Args.Humanoid:GetPropertyChangedSignal("Jump"):Connect(function()
		if not self.Args.Humanoid.Jump then return end
		if not config.movement.noJumpCooldown and lastJumpTick + 2.5 > tick() then
			self.Args.Humanoid.Jump = false; return
		end
		lastJumpTick = tick()
	end)

	if is5v5 then
		self.Connections.BenchAnim = localPlayer:GetAttributeChangedSignal("Benched"):Connect(function()
			if localPlayer:GetAttribute("Benched") == nil then
				self:StopAnimation("Bench"); self.Args.HumanoidRootPart.Anchored = false
			else self:PlayAnimation("Bench") end
		end)
	end

	self.Connections.GuardAnim = self.Args.Character:GetAttributeChangedSignal("Guarding"):Connect(function()
		if self.Args.Character:GetAttribute("Guarding") == true then
			self:PlayAnimation("Guard"); setBodyGyroLook(self.Args, self.Args.BodyGyro.CFrame)
		else self:StopAnimation("Guard"); clearBodyGyro(self.Args) end
	end)

	self.Connections.ScreenAnim = self.Args.Character:GetAttributeChangedSignal("Screening"):Connect(function()
		if self.Args.Character:GetAttribute("Screening") == true then
			self:PlayAnimation("Screen"); self.Args.Humanoid.WalkSpeed = 0
		else self:StopAnimation("Screen"); self.Args.Humanoid.WalkSpeed = getBaseSpeed() end
	end)

	self.Connections.Ankle = self.Args.Character:GetAttributeChangedSignal("Broken"):Connect(function()
		if self.Args.Character:GetAttribute("Broken") == true then
			self:PlayAnimation("Anklebreaker" .. math.random(1, 4), 1.5)
			self.Args.Humanoid.WalkSpeed = 0
		end
	end)

	if not is5v5 then
		self.Connections.QueuePause = localPlayer:GetAttributeChangedSignal("Queue"):Connect(function()
			if localPlayer:GetAttribute("Queue") == nil then
				self.Args.Humanoid.WalkSpeed = localPlayer:GetAttribute("Emoting") and self.Args.EmoteSpeed or getBaseSpeed()
			else self.Args.Humanoid.WalkSpeed = 0 end
		end)
	end

	-- animation loading + marker connections
	local animFolder = replicatedStorage.Assets["Animations_" .. rigType]
	for idx, animObj in pairs(animFolder:GetChildren()) do
		loadedAnimations[animObj.Name] = self.Args.Humanoid:LoadAnimation(animObj)

		if SHOT_MARKER_ANIMATIONS[animObj.Name] then
			self.Connections["JumpMarker" .. idx] = loadedAnimations[animObj.Name]:GetMarkerReachedSignal("Jump"):Connect(function()
				ic.Args.Jumped = true
			end)
			self.Connections["ReleaseMarker" .. idx] = loadedAnimations[animObj.Name]:GetMarkerReachedSignal("Release"):Connect(function()
				ic.Args.Released = true; ic:Shoot(false)
			end)
			self.Connections["LandMarker" .. idx] = loadedAnimations[animObj.Name]:GetMarkerReachedSignal("Land"):Connect(function()
				ic.Args.Landed = true
			end)
		elseif animObj.Name == "Ball_LayupL" or animObj.Name == "Ball_LayupR" then
			self.Connections["ReleaseMarker" .. idx] = loadedAnimations[animObj.Name]:GetMarkerReachedSignal("Released"):Connect(function()
				ic.Args.Released = true; ic:Shoot(false)
			end)
		elseif DRIBBLE_END_ANIMATIONS[animObj.Name] then
			self.Connections["EndMarker" .. idx] = loadedAnimations[animObj.Name].Stopped:Connect(function()
				ic.Args.Ended = true
			end)
		end

		if string.sub(animObj.Name, 1, 6) == "Dance_" then
			self.Connections[animObj.Name .. "Stop"] = loadedAnimations[animObj.Name].Stopped:Connect(function()
				local danceExtra = "DanceExtra_" .. string.sub(animObj.Name, 7)
				if animFolder:FindFirstChild(danceExtra) then self:StopAnimation(danceExtra) end
				if workspace.CurrentCamera.CameraSubject == self.Args.Head then self:FixCamera() end
				if self.Args.Humanoid.WalkSpeed == self.Args.EmoteSpeed then
					if is5v5 then self.Args.Humanoid.WalkSpeed = getBaseSpeed()
					else
						if gc.GameValues and gc.GameValues.Locked then self.Args.Humanoid.WalkSpeed = 0
						else self.Args.Humanoid.WalkSpeed = localPlayer:GetAttribute("Queue") and 0 or getBaseSpeed() end
					end
				end
				if not is5v5 then controlService.StopEmote:Fire(); ic.Args.StopEmoteTick = tick() end
			end)
		end
	end

	-- final setup
	if gc.GameValues and gc.GameValues.Phase == "Tipoff" then
		self.Args.Humanoid.WalkSpeed = 0; self:PlayAnimation("Tip_Stand")
	end
	self.Args.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, false)
	self.Args.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)

	if not is5v5 then
		if uc.FullyLoaded == true and uc.UIs.Courts ~= nil then uc.UIs.Courts:CourtMode(false) end
		if localPlayer:GetAttribute("Queue") ~= nil then self.Args.Humanoid.WalkSpeed = 0 end
	end

	self.Args.Setup = true

	if config.movement.hideCoreGui ~= false then
		safeSetCore("SetCoreGuiEnabled", Enum.CoreGuiType.Backpack, false)
		safeSetCore("SetCoreGuiEnabled", Enum.CoreGuiType.PlayerList, false)
	end

	logger.info("character initialized")
end

pcOverrides.Fix = function(self, reasonCode)
	logger.warn("Fix(" .. tostring(reasonCode) .. ") intercepted")
end

pcOverrides.PlayAnimation = function(self, animName, speed, fadeTime, weight, forceReplay)
	local track = loadedAnimations[animName]
	if not track then
		local obj = replicatedStorage.Assets["Animations_" .. rigType]:FindFirstChild(animName)
		if obj then track = self.Args.Humanoid:LoadAnimation(obj); loadedAnimations[animName] = track end
	end
	if track then
		if not forceReplay and track.IsPlaying then return end
		track:Play(fadeTime or 0.1, weight or 1, speed or 1)
		if track.Looped == false and animName == self.Args.LastEmote then
			if self.Connections.EmoteCancelLink then self.Connections.EmoteCancelLink:Disconnect() end
			self.Connections.EmoteCancelLink = track.Ended:Connect(function()
				if self.Connections.EmoteCancelLink then self.Connections.EmoteCancelLink:Disconnect(); self.Connections.EmoteCancelLink = nil end
				controlService.StopEmote:Fire()
			end)
		end
	end
end

pcOverrides.StopAnimation = function(self, animName, fadeTime)
	if loadedAnimations[animName] and loadedAnimations[animName].IsPlaying then
		loadedAnimations[animName]:Stop(fadeTime or 0.1)
	end
end

pcOverrides.IsAnimationLooped = function(self, animName)
	return loadedAnimations[animName] and loadedAnimations[animName].Looped or false
end

pcOverrides.IsAnimationPlaying = function(self, animName)
	return loadedAnimations[animName] and loadedAnimations[animName].IsPlaying or false
end

pcOverrides.CreateM6D = function(self, part)
	self.Args.HumanoidRootPart.Ball.Part0 = self.Args.HumanoidRootPart
	self.Args.HumanoidRootPart.Ball.Part1 = part
end

pcOverrides.StartMovement = function(self, direction, force, target, temporaryTurnUnlock, moveTag)
	local movTarget = target or sharedUtil.Ball:GetGoal(localPlayer)
	if not movTarget then return end
	local boost = getMoveBoost(moveTag)
	local rootPos = self.Args.HumanoidRootPart.Position
	local lookTarget = typeof(movTarget) == "Vector3"
		and Vector3.new(movTarget.X, rootPos.Y, movTarget.Z)
		or Vector3.new(movTarget.Position.X, rootPos.Y, movTarget.Position.Z)
	local lookCF = CFrame.lookAt(rootPos, lookTarget)
	setBodyGyroLook(self.Args, lookCF)
	setBodyVelocity(self.Args, Vector3.new(0, 0, 0), false)
	local dirFn = DIRECTION_VELOCITY[direction]
	if dirFn then self.Args.BodyVelocity.Velocity = dirFn(lookCF) * (force * boost) end
	if direction == "ForwardOpposite" then setBodyGyroLook(self.Args, lookCF * CFrame.Angles(0, math.pi, 0)) end
	if temporaryTurnUnlock then
		task.delay(clampedConfig(0.1, 0, 1, "movement", "turnUnlockDelay"), function() clearBodyGyro(self.Args) end)
	end
	movementStartTick = tick(); movementActive = true
end

pcOverrides.StartTurn = function(self, targetPosition)
	local goal = sharedUtil.Ball:GetGoal(localPlayer); if not goal then return end
	local rootPos = self.Args.HumanoidRootPart.Position
	local lookPos = Vector3.new(
		targetPosition and targetPosition.X or goal.Position.X, rootPos.Y,
		targetPosition and targetPosition.Z or goal.Position.Z)
	setBodyGyroLook(self.Args, CFrame.lookAt(rootPos, lookPos))
	movementStartTick = tick(); movementActive = true
end

pcOverrides.StopMovement = function(self)
	movementActive = false; clearBodyVelocity(self.Args); clearBodyGyro(self.Args)
end

pcOverrides.FixCamera = function(self)
	local cam = workspace.CurrentCamera
	cam.CameraSubject = self.Args.Humanoid; cam.CameraType = Enum.CameraType.Custom; cam.FieldOfView = 70
	if self.Args.Head then cam.CFrame = self.Args.Head.CFrame end
	if is5v5 then self:UpdateBallcam() end
end

pcOverrides.UpdateBallcam = function(self)
	if not is5v5 then return end
	local vip = replicatedStorage:FindFirstChild("VIP")
	if vip and vip.Value == true then
		local ballcam = gc.Ballcam
		local ball = gc.GameValues and gc.GameValues.Ball or nil
		if ballcam == true then
			if ball and currentCamera.CameraSubject ~= ball then currentCamera.CameraSubject = ball end
		elseif ballcam == false and currentCamera.CameraSubject ~= self.Args.Humanoid then
			currentCamera.CameraSubject = self.Args.Humanoid
		end
	end
end

pcOverrides.CancelEmote = function(self)
	if not self.Args.LastEmote or not localPlayer:GetAttribute("Emoting") then return end
	controlService.StopEmote:Fire(true)
	self:StopAnimation(self.Args.LastEmote)
	ic.Args.StopEmoteTick = tick()
	for _, child in pairs(self.Args.Character:GetChildren()) do
		if child.Name == "EMOTE_PROP_MODEL" and child:GetAttribute("DestroyPropCancel") then child:Destroy() end
	end
end

pcOverrides.IsFirstPerson = function(self)
	if self.Args.Head and self.Args.Head.LocalTransparencyModifier then
		return self.Args.Head.LocalTransparencyModifier == 1
	end
	return false
end

applyOverrides("PlayerController", pcOverrides)

-- ═══════ Helper Config Getters ═══════
local function getAutoBlockRange() return clampedConfig(25, 5, 60, "defense", "autoBlockRange") end
local function getAutoBlockCooldown() return clampedConfig(0.9, 0, 3, "defense", "autoBlockCooldown") end
local function getAutoBlockTriggerDelay() return clampedConfig(0.32, 0, 1, "defense", "autoBlockTriggerDelay") end
local function getAutoBlockReleaseDelay() return clampedConfig(0.12, 0, 1, "defense", "autoBlockReleaseDelay") end
local function getExtremeAutoBlockInterval() return clampedConfig(0.08, 0.01, 0.5, "defense", "extremeAutoBlockInterval") end
local function getAutoLockRefreshInterval() return clampedConfig(0.05, 0.01, 0.5, "defense", "autoLockRefreshInterval") end
local function normalizeBlockboxSize(v) return math.clamp(v, 0, 200) end

-- ═══════ Shot / Dribble Helpers (from original IC) ═══════
local function getBallHandSuffix(hand)
	return hand == "Left" and "L" or "R"
end

local function resolveShotProfile(self, ballValues, distanceToGoal, root, humanoid)
	local shotType = (distanceToGoal < (is5v5 and 17.5 or 15) and root.Velocity.Magnitude > 4) and "Layup" or "Jumpshot"
	local animationName = "Jumpshot"
	local animationSpeed = 1.25
	local handSuffix = getBallHandSuffix(ballValues.Hand)

	if shotType == "Layup" then
		animationName = "Ball_Layup" .. handSuffix
		animationSpeed = 1.75 * (config.moves.layup.animSpeed or 1)
		if distanceToGoal < (is5v5 and 12.5 or 10) then
			animationName = "Ball_ShortLayup" .. handSuffix
		end
	elseif shotType == "Jumpshot" then
		local shotGoal = sharedUtil.Ball:GetGoal(localPlayer)
		local moveDirection = currentCamera.CFrame:VectorToObjectSpace(humanoid.MoveDirection).Unit

		if shotGoal then
			moveDirection = shotGoal.CFrame:VectorToObjectSpace(humanoid.MoveDirection).Unit
			if shotGoal.CFrame:toObjectSpace(root.CFrame).Z < (is5v5 and 3 or 2)
			and math.abs(moveDirection.X) > 0.9 then
				moveDirection = Vector3.new(moveDirection.Z, 0, 1)
			end
		end

		if moveDirection.X < -0.6 then
			shotType = "FadeLeft"
			animationName = "JumpshotLeft"
			animationSpeed = 1.4
		end

		if moveDirection.X > 0.6 then
			shotType = "FadeRight"
			animationName = "JumpshotRight"
			animationSpeed = 1.4
		end

		if moveDirection.Z > 0.6 then
			shotType = "FadeBack"
			animationName = "Ball_FadeBack"
			animationSpeed = 1.4
		end
	end

	if self.Args.Posting then
		self.Args.Posting = false
		pc:StopAnimation("Ball_PostDribbleR")
		pc:StopAnimation("Ball_PostDribbleL")
		playDribbleAnim(ballValues.Hand)

		if shotType == "Jumpshot" or shotType == "FadeBack" then
			shotType = "FadeBack"
			animationName = "Ball_FadeBack"
			animationSpeed = 1.4
		else
			shotType = "PostHook"
			animationName = "Ball_PostHook" .. handSuffix
			animationSpeed = 1.3
		end
	end

	return shotType, animationName, animationSpeed
end

local function executeShotMovement(self, ballValues)
	if self.Args.ShotType == "Layup" then
		pc:StartMovement("Forward", 7, nil, nil, "layup")
		return
	end

	if self.Args.ShotType == "Jumpshot" then
		pc:StartTurn()
		waitForArgsFlag("Jumped", 2)
		pc:StopMovement()
		if self.Args.CanShoot == false then
			pc:StartMovement("Forward", 3, nil, nil, "jumpshot")
		end
		return
	end

	if self.Args.ShotType == "FadeBack" then
		pc:StartMovement("Back", 7, nil, nil, "fade")
		return
	end

	if self.Args.ShotType == "FadeLeft" then
		pc:StartMovement("Left", 9, nil, nil, "fade")
		return
	end

	if self.Args.ShotType == "FadeRight" then
		pc:StartMovement("Right", 9, nil, nil, "fade")
		return
	end

	if self.Args.ShotType == "PostHook" then
		pc:StartMovement(self.Args.PostDirection, 9, nil, nil, "post")
		return
	end
end

local function getResolvedShotPoint()
	local shotPoint = uc.UIs.Shooting:GetCurrentPoint()
	local shootCfg = config.moves.jumpshot
	if shootCfg.autoGreen then
		local perfect = shootCfg.perfectRelease == true
		if not perfect then
			local chance = shootCfg.greenChance or 50
			perfect = math.random() < (chance / 100)
		end
		shotPoint = perfect and 1 or 0.97
	end
	return shotPoint, shootCfg
end

local EMPTY_DRIBBLE_CONFIG = {}

local function beginDribbleAction(self, startDribbleArg, options)
	options = options or EMPTY_DRIBBLE_CONFIG
	controlService.StartDribble:Fire(startDribbleArg)
	lockAction({
		canShoot = options.canShoot ~= nil and options.canShoot or false,
		canDribble = options.canDribble ~= nil and options.canDribble or false,
		walkSpeed = options.walkSpeed ~= nil and options.walkSpeed or 0,
		autoRotate = options.autoRotate,
	})
	self.Args.Ended = false
end

local function finishDribbleAction(self, targetHand)
	unlockAction(getGameValues())
	if hasBall(pc.Args.Character) then
		playDribbleAnim(targetHand)
	end
	self.Args.CanShoot = true
	task.wait(0.1)
	self.Args.CanDribble = true
end

local function resolveDribbleMoveProfile(move, currentHand, dribAnimSpeed)
	local isBehindTheBack = string.sub(move, 1, 3) == "BTB"
	local isSpin = string.sub(move, 1, 4) == "Spin"
	local targetHand = move

	if isBehindTheBack then
		if move == "BTBLeft" and currentHand == "Right" then return nil end
		if move == "BTBRight" and currentHand == "Left" then return nil end
		targetHand = move == "BTBRight" and "Left" or (move == "BTBLeft" and "Right" or move)
	end

	if isSpin then
		if move == "SpinLeft" and currentHand == "Right" then return nil end
		if move == "SpinRight" and currentHand == "Left" then return nil end
		targetHand = move == "SpinRight" and "Left" or (move == "SpinLeft" and "Right" or targetHand)
	end

	local dribbleType = currentHand == move and "Hesi" or "Cross"
	local animationName = nil
	local animationSpeed = nil

	if move == "Right" then
		animationName = "Ball_" .. dribbleType .. "R"
		animationSpeed = 1.75 * dribAnimSpeed
	elseif move == "Left" then
		animationName = "Ball_" .. dribbleType .. "L"
		animationSpeed = 1.75 * dribAnimSpeed
	elseif move == "BTBRight" then
		animationName = "Ball_BTBR2L"
		animationSpeed = 1.85 * dribAnimSpeed
	elseif move == "BTBLeft" then
		animationName = "Ball_BTBL2R"
		animationSpeed = 1.85 * dribAnimSpeed
	elseif move == "SpinRight" then
		animationName = "Ball_SpinR2L"
		animationSpeed = 2.75 * dribAnimSpeed
	elseif move == "SpinLeft" then
		animationName = "Ball_SpinL2R"
		animationSpeed = 2.75 * dribAnimSpeed
	end

	if not animationName then return nil end

	return {
		targetHand = targetHand,
		movementDirection = targetHand,
		animationName = animationName,
		animationSpeed = animationSpeed,
	}
end

-- ═══════ InputController Overrides ═══════
local icOverrides = {}

icOverrides.GetBallValues = function(self)
	local _, ballValues = basketball:GetValues()
	return ballValues
end

icOverrides.Shoot = function(self, isHolding)
	if isBenched() then return end
	if not hasBall(pc.Args.Character) then return end

	local gameValues = getGameValues()
	if not gameValues or gameValues.Inbounding then return end

	if isHolding == true then
		if self.Args.CanShoot ~= true or self.Args.Holding then return end

		local ballValues = self:GetBallValues()
		if not ballValues then return end

		local goal = sharedUtil.Ball:GetGoal(localPlayer)
		if not goal then return end

		local root = pc.Args.HumanoidRootPart
		local humanoid = pc.Args.Humanoid
		local distanceToGoal = sharedUtil.Math:XYMagnitude(root.Position, goal.Position)

		if pc.Args.SpawnTick and tick() - pc.Args.SpawnTick < 5 then return end
		if distanceToGoal < 2.5 then return end

		self.Args.ShotType = (distanceToGoal < (is5v5 and 17.5 or 15) and root.Velocity.Magnitude > 4) and "Layup" or "Jumpshot"

		lockAction({ canShoot = false, walkSpeed = 0, autoRotate = false })
		self.Args.Holding = true
		self.Args.Jumped = false
		self.Args.Released = false
		self.Args.Landed = false

		local animationName, animationSpeed
		self.Args.ShotType, animationName, animationSpeed = resolveShotProfile(self, ballValues, distanceToGoal, root, humanoid)

		task.spawn(function()
			uc.UIs.Shooting:Handle()
		end)

		if self.Args.InEuro then
			local euroStartTick = tick()
			repeat task.wait() until tick() - euroStartTick > 0.5 or not self.Args.InEuro
			animationSpeed = animationSpeed * (is5v5 and 1.25 or 1.2)
			if not pc.Args.toolEquipped then return end
		end

		controlService.StartShoot:Fire()
		local finalAnimSpeed = animationSpeed
		if config.moves.jumpshot.shotSpeed and config.moves.jumpshot.shotSpeed ~= 1 then
			finalAnimSpeed = config.moves.jumpshot.shotSpeed
		end
		pc:PlayAnimation(animationName, finalAnimSpeed)
		executeShotMovement(self, ballValues)
		return
	end

	if isHolding == false and self.Args.CanShoot == false and self.Args.Holding == true and self.Args.ShotEndFlag ~= true then
		self.Args.ShotEndFlag = true
		task.wait(0.1)

		local shotPoint, shootCfg = getResolvedShotPoint()

		if shootCfg.autoRelease then
			local releaseDelay = shootCfg.releaseDelay or 0.35
			task.wait(releaseDelay)
		else
			waitForArgsFlag("Released", 2)
		end

		controlService.Shoot:Fire(shotPoint)

		if self.Args.ShotType == "Layup" then
			task.wait(0.2)
		elseif self.Args.ShotType == "Jumpshot"
		or self.Args.ShotType == "FadeBack"
		or self.Args.ShotType == "FadeLeft"
		or self.Args.ShotType == "FadeRight"
		or self.Args.ShotType == "PostHook" then
			waitForArgsFlag("Landed", 2)
		end

		unlockAction(getGameValues())
		self.Args.CanShoot = true
		self.Args.Holding = false
		self.Args.ShotEndFlag = false
	end
end

icOverrides.Pass = function(self, slot)
	if isBenched() then return end
	if not hasBall(pc.Args.Character) then return end
	if self.Args.CanShoot == false then return end
	if not (self.Args.InEuro or self.Args.CanDribble ~= false) then return end

	local ignoreChecks = ignoreTeamPossessionChecks()
	local targetCharacter = nil

	if is5v5 and slot == "Closest" then
		local closestDist, closestPlayer = nil, nil
		for i = 1, #cachedPlayers do
			local player = cachedPlayers[i]
			if player ~= localPlayer and (ignoreChecks or playersShareTeam(player, localPlayer))
			and player:GetAttribute("Benched") == nil
			and player.Character
			and player.Character:GetAttribute("Screening") ~= true then
				local dist = player:DistanceFromCharacter(pc.Args.HumanoidRootPart.Position)
				if dist and (not closestDist or closestDist > dist) then
					closestPlayer = player
					closestDist = dist
				end
			end
		end
		if closestPlayer then targetCharacter = closestPlayer.Character end
	elseif not is5v5 then
		local closest = getClosestPlayer(false)
		if closest and closest.Character then targetCharacter = closest.Character end
	else
		local passTags = vc:PassTagTable()
		if slot and passTags[slot] then
			for i = 1, #cachedPlayers do
				local player = cachedPlayers[i]
				if player.UserId == passTags[slot]
				and player.Character
				and player.Character:GetAttribute("Screening") ~= true then
					targetCharacter = player.Character
				end
			end
		end
	end

	if targetCharacter and is5v5 then
		local targetPlayer = playersService:GetPlayerFromCharacter(targetCharacter)
		if targetPlayer and targetPlayer:GetAttribute("Benched") ~= nil then return end
	end

	if not targetCharacter then return end
	local targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return end

	lockAction({ canShoot = false, canDribble = false })
	pc:PlayAnimation("Ball_Pass")
	pc:StartTurn(targetRoot.Position)
	if not is5v5 then
		local passBoost = getMoveBoost("pass")
		pc.Args.Humanoid.WalkSpeed = 8 * passBoost
	end
	task.wait(0.25)
	controlService.Pass:Fire(targetCharacter)
	pc:StopMovement()
end

icOverrides.Dribble = function(self, move)
	if isBenched() then return end
	if not hasBall(pc.Args.Character) then return end

	local gameValues = getGameValues()
	if not gameValues or gameValues.Inbounding then return end

	local ballObject, ballValues = basketball:GetValues()
	if not ballValues then return end

	local dribCfg = config.moves.dribble
	if not dribCfg.noDribbleCooldown then
		if self.Args.CanShoot == false or self.Args.CanDribble == false or self.Args.Posting or self.Args.DoubleDribble then
			return
		end
	else
		if self.Args.Posting then return end
	end

	local dribAnimSpeed = dribCfg.animSpeed or 1
	local profile = resolveDribbleMoveProfile(move, ballValues.Hand, dribAnimSpeed)
	if not profile then return end

	beginDribbleAction(self)
	basketball:SetValue(ballObject, "Hand", profile.targetHand)
	pc:StartMovement(profile.movementDirection, 14, nil, nil, "dribble")
	stopDribbleAnims()
	pc:PlayAnimation(profile.animationName, profile.animationSpeed)

	waitForArgsFlag("Ended", 1.5)
	finishDribbleAction(self, profile.targetHand)
end

icOverrides.PumpFake = function(self)
	if isBenched() then return end
	if not hasBall(pc.Args.Character) then return end
	if not abilityUnlocked("PumpFake") then return end

	local gameValues = getGameValues()
	if not gameValues or gameValues.Inbounding then return end

	local _, ballValues = basketball:GetValues()
	if not ballValues then return end

	local pfCfg = config.moves.pumpFake

	if not pfCfg.forceShot and self.Args.CanShoot == false then return end
	if self.Args.CanDribble == false or self.Args.EuroCD or self.Args.Posting then return end
	if not pfCfg.noPumpFakeCooldown and self.Args.PumpFakeCD then return end
	if not pfCfg.infinitePumpFake and self.Args.DoubleDribble then return end

	local moved = pc.Args.Moved

	self.Args.PumpFakeCD = true
	self.Args.DoubleDribble = pfCfg.infinitePumpFake and false or moved
	lockAction({ canShoot = false, canDribble = false, walkSpeed = 0, autoRotate = false })

	local pumpAnimName = pfCfg.jumpshotFake and "Jumpshot" or "Ball_PumpFake"
	pc:PlayAnimation(pumpAnimName, pfCfg.jumpshotFake and (config.moves.jumpshot.shotSpeed or 1.25) or 1.35)
	pc:StartMovement("Forward", 3, nil, nil, "pumpFake")
	stopDribbleAnims()
	pc:PlayAnimation("Ball_NormalHold")

	task.wait(0.75)

	lockAction({ autoRotate = true })
	pc:StopMovement()

	self.Args.CanShoot = true
	self.Args.CanDribble = true

	if pfCfg.infinitePumpFake or not moved then
		pc:StopAnimation("Ball_NormalHold")
		restoreSpeed(pc.Args.Humanoid, getGameValues())
		if hasBall(pc.Args.Character) then
			playDribbleAnim(ballValues.Hand)
		end
	end

	if pfCfg.noPumpFakeCooldown then
		self.Args.PumpFakeCD = false
	else
		applyCooldown("PumpFakeCD", 4)
	end
end

icOverrides.Eurostep = function(self, isComboTriggered)
	if isBenched() then return end
	if not hasBall(pc.Args.Character) then return end
	if not abilityUnlocked("Eurostep") then return end

	local gameValues = getGameValues()
	if not gameValues or gameValues.Inbounding then return end

	local ballObject, ballValues = basketball:GetValues()
	if not ballValues then return end

	if self.Args.CanShoot == false
	or self.Args.CanDribble == false
	or self.Args.EuroCD
	or self.Args.Posting
	or self.Args.DoubleDribble then
		return
	end

	if pc.Args.HumanoidRootPart.Velocity.Magnitude <= 4 then return end

	local goal = sharedUtil.Ball:GetGoal(localPlayer)
	local root = pc.Args.HumanoidRootPart

	if not config.moves.euro.unlockRange and sharedUtil.Math:XYMagnitude(root.Position, goal.Position) > 38 then return end

	beginDribbleAction(self, true, { canShoot = self.Args.CanShoot, canDribble = false })
	self.Args.EuroCD = true
	self.Args.InEuro = true

	local initialHand = ballValues.Hand
	local targetHand = ballValues.Hand == "Left" and "Right" or (ballValues.Hand == "Right" and "Left" or "Right")

	pc:PlayAnimation("Eurostep_" .. ballValues.Hand, is5v5 and 1 or 1.4)
	basketball:SetValue(ballObject, "Hand", targetHand)
	stopDribbleAnims()

	if isComboTriggered then
		pc:StartMovement(initialHand .. "Forward", 28, nil, true, "euro")
		task.wait(0.15)
		pc:StartMovement(targetHand .. "Forward", 35, nil, true, "euro")
		task.wait(0.25)
	else
		pc:StartMovement(targetHand .. "Forward", 35, nil, true, "euro")
		task.wait(0.4)
	end

	self.Args.InEuro = false

	if self.Args.CanShoot == true then
		pc:StopMovement()
	end

	task.wait(0.1)

	if self.Args.CanShoot == true and self.Args.Holding == false then
		self:Shoot(true)
		self:Shoot(false)
	end

	task.wait(3)
	self.Args.EuroCD = false
end

icOverrides.Stepback = function(self)
	if isBenched() then return end
	if not hasBall(pc.Args.Character) then return end

	local gameValues = getGameValues()
	if not gameValues or gameValues.Inbounding then return end

	local _, ballValues = basketball:GetValues()
	if not ballValues then return end

	if self.Args.CanShoot == false
	or self.Args.CanDribble == false
	or self.Args.KeyX1
	or self.Args.KeyX2
	or self.Args.Posting
	or self.Args.DoubleDribble then
		return
	end

	beginDribbleAction(self)

	pc:StartMovement("Back", 14, nil, nil, "stepback")
	stopDribbleAnims()

	if ballValues.Hand == "Right" then
		pc:PlayAnimation("Ball_StepbackR", 1.75)
	elseif ballValues.Hand == "Left" then
		pc:PlayAnimation("Ball_StepbackL", 1.75)
	end

	waitForArgsFlag("Ended", 1.5)
	finishDribbleAction(self, ballValues.Hand)
end

icOverrides.Guard = function(self, shouldGuard)
	if isBenched() then return end
	if hasBall(pc.Args.Character) then return end

	local character = pc.Args.Character

	if shouldGuard == nil then
		shouldGuard = not character:GetAttribute("Guarding")
	end

	if shouldGuard then
		local gameValues = getGameValues()
		local ignoreChecks = ignoreTeamPossessionChecks()

		if self.Args.GuardCD or self.Args.InAction or not gameValues or gameValues.Inbounding then
			return
		end

		if is5v5 then
			if gameValues.Possession == nil or (not ignoreChecks and localTeamHasPossession(gameValues)) then return end
			if workspace:FindFirstChild("Basketball") then return end

			local guardTarget = nil
			for _, tagged in pairs(collectionService:GetTagged("Ball")) do
				if tagged.Name == "Attach" and tagged.Parent:IsA("Tool") then
					local tRoot = tagged.Parent.Parent:FindFirstChild("HumanoidRootPart")
					if tRoot then guardTarget = tRoot; break end
				end
			end
			if not guardTarget then return end
			if (pc.Args.HumanoidRootPart.Position - guardTarget.Position).Magnitude > (config.defense.guardRange or 25) then return end
		else
			if gameValues.Practice or gameValues.ScoringContest then return end
			if gameValues.Possession == nil or (not ignoreChecks and localTeamHasPossession(gameValues)) then return end

			local closestBall = sharedUtil.Ball:GetClosestBall(localPlayer)
			if not closestBall or closestBall.Parent == workspace then return end
			if (pc.Args.HumanoidRootPart.Position - closestBall.Position).Magnitude > (config.defense.guardRange or 25) then return end
			pc.Args.TargetGuard = closestBall
		end
	end

	controlService.Guard:Fire(shouldGuard)
	self.Args.InAction = shouldGuard
end

icOverrides.Screen = function(self, shouldScreen)
	if isBenched() then return end
	if hasBall(pc.Args.Character) then return end

	if shouldScreen then
		if self.Args.ScreenCD or self.Args.InAction then return end

		local gameValues = getGameValues()
		local ignoreChecks = ignoreTeamPossessionChecks()
		if gameValues then
			if gameValues.Inbounding or gameValues.Possession == nil then return end
			if not ignoreChecks and not localTeamHasPossession(gameValues) then return end
			if is5v5 then
				if workspace:FindFirstChild("Basketball") then return end
			else
				if gameValues.Practice or gameValues.ScoringContest then return end
			end
		end

		if not is5v5 then
			local closestBall = sharedUtil.Ball:GetClosestBall(localPlayer)
			if not closestBall or closestBall.Parent == workspace then return end
		end
	end

	controlService.Screen:Fire(shouldScreen)
	self.Args.InAction = shouldScreen

	if shouldScreen == false then
		applyCooldown("ScreenCD", 0.25)
	end
end

icOverrides.Jump = function(self, isContactDunk)
	if isBenched() then return end
	if hasBall(pc.Args.Character) then
		if self.Args.CanShoot == false then return end
		if self.Args.CanDribble == false and self.Args[false] then return end
		if self.Args.Posting or self.Args.DoubleDribble then return end

		local goal = sharedUtil.Ball:GetGoal(localPlayer)
		if not goal then return end

		local root = pc.Args.HumanoidRootPart
		local distanceToGoal = sharedUtil.Math:XYMagnitude(root.Position, goal.Position)
		local speed = root.Velocity.Magnitude

		local dunkCfg = config.moves.dunk
		local shouldContactDunk = false
		if dunkCfg.unlockRange or (distanceToGoal < 12.5 and distanceToGoal > 5) then
			local canTrigger = self.Args.InEuro or speed > 3
			shouldContactDunk = isContactDunk == true and true or canTrigger
		end

		local shouldDunk = shouldContactDunk == false and (dunkCfg.unlockRange or (distanceToGoal <= 5 and distanceToGoal > 2)) and true or shouldContactDunk
		local equippedDunk = dc.Data.Dunks and dc.Data.Dunks.Equipped or nil

		if dunkCfg.dunkChanger and DUNK_TYPES[dunkCfg.dunkType] then
			equippedDunk = DUNK_TYPES[dunkCfg.dunkType]
		end

		if not dunkCfg.noDunkCooldown and self.Args.DunkCD == true then shouldDunk = false end
		if goal.CFrame:toObjectSpace(root.CFrame).Z < -2 then shouldDunk = false end
		if pc.Args.SpawnTick and tick() - pc.Args.SpawnTick < 5 then shouldDunk = false end

		if shouldDunk and equippedDunk then
			lockAction({ canShoot = false, canDribble = false })
			self.Args.DunkCD = true

			if self.Args.InEuro then
				local euroStart = tick()
				repeat task.wait() until tick() - euroStart > 0.5 or not self.Args.InEuro
			end

			controlService.StartDunk:Fire()
			pc.Args.Humanoid.WalkSpeed = 0

			local dunkSpeed = items.Dunks[equippedDunk][6] or 1.5
			if isContactDunk then dunkSpeed = dunkSpeed * 1.25 end

			pc:PlayAnimation("Dunk_" .. equippedDunk, dunkSpeed)
			pc:StopAnimation("Rebound")
			pc:StartTurn()

			local bodyPosition = Instance.new("BodyPosition")
			bodyPosition.D = 1100
			bodyPosition.P = 8000
			bodyPosition.MaxForce = Vector3.new(1, 1, 1) * math.huge
			local dHeight = dunkCfg.dunkHeight or -0.4
			bodyPosition.Position = (CFrame.new(goal.Position, Vector3.new(root.Position.X, goal.Position.Y, root.Position.Z)) * CFrame.new(0, dHeight, -1.3)).Position
			bodyPosition.Parent = root

			if items.Dunks[equippedDunk][7] then
				bodyPosition.D = 100
				bodyPosition.P = 300
				bodyPosition.Position = goal.Position - Vector3.new(0, 1.75, 0)
			end

			task.wait(isContactDunk and 0.6 or 0.75)
			controlService.Dunk:Fire()

			if items.Dunks[equippedDunk][7] then
				task.wait(items.Dunks[equippedDunk][7])
			end

			unlockAction(getGameValues())
			bodyPosition:Destroy()

			task.wait(1)
			self.Args.CanShoot = true
			self.Args.CanDribble = true

			if dunkCfg.noDunkCooldown then
				self.Args.DunkCD = false
			else
				task.wait(3)
				self.Args.DunkCD = false
			end
			return
		end

		return
	end

	-- defense: block / rebound / jump
	local closestBall
	if is5v5 then
		closestBall = collectionService:GetTagged("Ball")[1]
	else
		closestBall = sharedUtil.Ball:GetClosestBall(localPlayer)
	end
	local action = "Jump"
	local reboundThreshold = is5v5 and 8 or 3

	if closestBall and (pc.Args.HumanoidRootPart.Position - closestBall.Position).Magnitude < 20 then
		action = closestBall.Parent ~= workspace and "Block" or (closestBall.Position.Y > reboundThreshold and "Rebound" or action)
	end

	if action == "Block" then
		local gameValues = getGameValues()
		local ignoreChecks = ignoreTeamPossessionChecks()

		if self.Args.InAction
		or self.Args.BlockCD
		or not gameValues
		or gameValues.Inbounding
		or gameValues.Possession == nil
		or (not ignoreChecks and localTeamHasPossession(gameValues))
		or pc.Args.Character:GetAttribute("Stealing")
		or pc.Args.Character:GetAttribute("Broken")
		or pc.Args.Character:GetAttribute("PostBlockedCD") then
			return
		end

		if not is5v5 and (gameValues.Practice or gameValues.ScoringContest) then return end

		self.Args.BlockCD = true
		lockAction({ inAction = true, walkSpeed = 0 })

		controlService.Block:Fire()
		pc:StartMovement("Forward", 18, closestBall, nil, "block")
		pc:PlayAnimation("Block")

		task.wait(0.6)

		if pc.Args.Character:GetAttribute("Contact") == nil then
			pc:StopMovement()
		end

		task.wait(0.4)

		if pc.Args.Character:GetAttribute("Contact") == nil then
			restoreSpeed(pc.Args.Humanoid, getGameValues())
		end

		self.Args.InAction = false

		task.wait(2)
		self.Args.BlockCD = false
		return
	end

	if action == "Rebound" then
		local gameValues = getGameValues()

		if self.Args.InAction
		or self.Args.BlockCD
		or not gameValues
		or gameValues.Inbounding
		or pc.Args.Character:GetAttribute("Stealing")
		or pc.Args.Character:GetAttribute("Broken")
		or pc.Args.Character:GetAttribute("PostBlockedCD") then
			return
		end

		self.Args.BlockCD = true
		lockAction({ inAction = true, walkSpeed = 7 })

		pc:PlayAnimation("Rebound", 2.4)
		self.Args.LastRebound = tick()

		local humanoid = pc.Args.Humanoid
		local reboundBoost = getMoveBoost("rebound")
		humanoid.JumpPower = 50 * reboundBoost
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		task.wait(0.5)
		humanoid.JumpPower = 0

		local gv = getGameValues()
		if is5v5 then
			if not self.Args.DoubleDribble then
				restoreSpeed(pc.Args.Humanoid, gv)
			end
		else
			if gv and not (gv.Locked or self.Args.DoubleDribble) then
				restoreSpeed(pc.Args.Humanoid, gv)
			end
		end

		pc:StopMovement()
		self.Args.InAction = false

		task.wait(2)
		self.Args.BlockCD = false
		return
	end
end

icOverrides.Steal = function(self)
	if isBenched() then return end
	if hasBall(pc.Args.Character) then return end

	local closestBall
	if is5v5 then
		closestBall = collectionService:GetTagged("Ball")[1]
	else
		closestBall = sharedUtil.Ball:GetClosestBall(localPlayer)
	end
	if not closestBall then return end

	local gameValues = getGameValues()
	local stealCfg = config.moves.steal
	local ignoreChecks = ignoreTeamPossessionChecks()

	if self.Args.InAction
	or (not stealCfg.noStealCooldown and self.Args.StealCD)
	or pc.Args.Character:GetAttribute("Blocking")
	or pc.Args.Character:GetAttribute("PostBlockedCD")
	or not gameValues
	or gameValues.Inbounding
	or gameValues.Possession == nil
	or (not ignoreChecks and localTeamHasPossession(gameValues)) then
		return
	end

	if not is5v5 and (gameValues.Practice or gameValues.ScoringContest) then return end

	local isPassive = stealCfg.phantomSteal or stealCfg.passiveSteal

	self.Args.StealCD = true
	lockAction({ inAction = not isPassive, walkSpeed = not stealCfg.phantomSteal and 0 or nil })

	controlService.Steal:Fire()

	if stealCfg.perfectSteal and fireTouch then
		local rightHand = pc.Args.Character:FindFirstChild("RightHand") or pc.Args.Character:FindFirstChild("Right Arm")
		local ballPart = resolveBallAttach(closestBall.Parent and closestBall.Parent:IsA("Tool") and closestBall.Parent.Parent or nil)
		if rightHand and ballPart then
			pcall(fireTouch, ballPart, rightHand, 0)
			task.delay(0.2, pcall, fireTouch, ballPart, rightHand, 1)
		end
	end

	if not stealCfg.phantomSteal then
		pc:StartMovement("Forward", 7, closestBall, nil, "steal")
		pc:PlayAnimation("Steal", 1.5)

		task.wait(0.6)
		pc:StopMovement()

		if pc.Args.Character:GetAttribute("Broken") then
			task.wait(0.75)
		end

		restoreSpeed(pc.Args.Humanoid, getGameValues())
	else
		task.wait(0.3)
	end

	self.Args.InAction = false

	if stealCfg.noStealCooldown then
		self.Args.StealCD = false
	else
		applyCooldown("StealCD", 4)
	end
end

icOverrides.Combo = function(self, direction)
	if isBenched() then return end
	if not hasBall(pc.Args.Character) then return end

	local firstWindow = self.CurrentInputLayout == "Touch" and 0.2 or 0.13
	local secondWindow = self.CurrentInputLayout == "Touch" and 0.25 or 0.15

	if direction == "Left" then
		if self.Args.KeyZ1 == false then
			self.Args.KeyZ1 = true
			task.wait(firstWindow)
			self.Args.KeyZ1 = false
		else
			self.Args.KeyZ2 = true
			task.wait(firstWindow)
			self.Args.KeyZ2 = false
		end
		return
	end

	if direction == "Right" then
		if self.Args.KeyC1 == false then
			self.Args.KeyC1 = true
			task.wait(firstWindow)
			self.Args.KeyC1 = false
		else
			self.Args.KeyC2 = true
			task.wait(firstWindow)
			self.Args.KeyC2 = false
		end
		return
	end

	if direction == "Back" then
		if self.Args.KeyZ1 == true then
			self.Args.KeyX1 = true
			task.wait(firstWindow)
			self.Args.KeyX1 = false
			return
		end
		if self.Args.KeyC1 == true then
			self.Args.KeyX2 = true
			task.wait(firstWindow)
			self.Args.KeyX2 = false
			return
		end
		return
	end

	if direction == "Euro" then
		if self.Args.KeyF1 == false then
			self.Args.KeyF1 = true
			task.wait(secondWindow)
			self.Args.KeyF1 = false
			return
		end
		self.Args.KeyF2 = true
		task.wait(secondWindow)
		self.Args.KeyF2 = false
	end
end

icOverrides.HandleDribbleCheck = function(self)
	if self.Args.KeyZ1 == false and self.Args.KeyC1 == false and self.Args.KeyF1 == false then
		return
	end
	if self.Args.CanDribble == false then return end
	if not hasBall(pc.Args.Character) then return end

	local _, ballValues = basketball:GetValues()
	if not ballValues then return end

	if self.Args.KeyZ1 == true and ballValues.Hand == "Left" then
		if self.Args.KeyX1 == true then
			self.Args.KeyZ1 = false
			self.Args.KeyX1 = false
			self:Dribble("BTBLeft")
			return
		end
		if self.Args.KeyZ2 == true then
			self.Args.KeyZ1 = false
			self.Args.KeyZ2 = false
			self:Dribble("SpinLeft")
			return
		end
	elseif self.Args.KeyC1 == true and ballValues.Hand == "Right" then
		if self.Args.KeyX2 == true then
			self.Args.KeyC1 = false
			self.Args.KeyX2 = false
			self:Dribble("BTBRight")
			return
		end
		if self.Args.KeyC2 == true then
			self.Args.KeyC1 = false
			self.Args.KeyC2 = false
			self:Dribble("SpinRight")
			return
		end
	elseif self.Args.KeyF2 == true then
		self:Eurostep(true)
	end
end

icOverrides.Post = function(self, shouldPost)
	if isBenched() then return end
	if not hasBall(pc.Args.Character) then return end
	if not abilityUnlocked("Post") then return end

	local gameValues = getGameValues()
	if not gameValues or gameValues.Inbounding or self.Args.CanShoot == false or self.Args.DoubleDribble then
		return
	end

	local _, ballValues = basketball:GetValues()
	if not ballValues then return end

	local goal = sharedUtil.Ball:GetGoal(localPlayer)
	local root = pc.Args.HumanoidRootPart
	local distanceToGoal = sharedUtil.Math:XYMagnitude(root.Position, goal.Position)

	if shouldPost == true and not config.moves.post.unlockRange and distanceToGoal > 38 then return end

	self.Args.Posting = shouldPost
	self.Args.PostDirection = ballValues.Hand
	pc.Args.PostTick = tick()
	controlService.Posting:Fire(shouldPost, ballValues.Hand)

	if self.Args.Posting == true then
		enterPostState(ballValues.Hand)
		return
	end

	exitPostState(ballValues.Hand)

	local didSpinOut = false

	if distanceToGoal <= 38 then
		local moveDirection = currentCamera.CFrame:VectorToObjectSpace(pc.Args.Humanoid.MoveDirection).Unit

		if moveDirection.X <= -0.75 and ballValues.Hand == "Right" then
			self:Dribble("SpinRight")
			didSpinOut = true
		elseif moveDirection.X >= 0.75 and ballValues.Hand == "Left" then
			self:Dribble("SpinLeft")
			didSpinOut = true
		end
	end

	if not didSpinOut then
		restoreSpeed(pc.Args.Humanoid, getGameValues())
	end

	pc.Args.Humanoid.AutoRotate = true
end

icOverrides.SelfLob = function(self)
	if isBenched() then return end
	if not hasBall(pc.Args.Character) then return end
	if not abilityUnlocked("Lob") then return end

	local gameValues = getGameValues()
	if not gameValues
	or gameValues.Inbounding
	or self.Args.Posting
	or self.Args.CanShoot == false
	or not (self.Args.InEuro or self.Args.CanDribble ~= false) then
		return
	end

	local goal = sharedUtil.Ball:GetGoal(localPlayer)
	local root = pc.Args.HumanoidRootPart
	local distanceToGoal = sharedUtil.Math:XYMagnitude(root.Position, goal.Position)

	if config.moves.selfLob.unlockRange or (distanceToGoal <= 38 and distanceToGoal >= 12.5) then
		lockAction({ canShoot = false, canDribble = false })
		pc:PlayAnimation("Ball_Pass")
		pc.Args.LobTick = tick()
		task.wait(0.25)
		controlService.Pass:Fire("SelfLob")
	end
end

icOverrides.Emote = function(self)
	if is5v5 then return end
	if localPlayer:GetAttribute("Emoting") then
		if tick() - (self.Args.LastEmoteTick or 0) >= 1 then
			pc:CancelEmote()
		end
		return
	end

	if self.Args.EmoteCD or localPlayer:GetAttribute("Court") then return end
	if tick() - (self.Args.StopEmoteTick or 0) < 2.5 then return end
	if pc:IsAnimationPlaying(pc.Args.LastEmote) then return end
	if localPlayer:GetAttribute("InTrade") then return end

	self.Args.EmoteCD = true
	self.Args.LastEmoteTick = tick()
	controlService.Emote:Fire()
	task.wait(2)
	self.Args.EmoteCD = false
end

icOverrides.Signal = function(self)
	if not is5v5 then return end
	if isBenched() then return end
	if hasBall(pc.Args.Character) then return end
	if self.Args.SignalCD then return end
	if self.Args.InAction then return end

	local gameValues = getGameValues()
	if gameValues then
		if gameValues.Inbounding then return end
		if gameValues.Possession == nil then return end
		if not ignoreTeamPossessionChecks() and not localTeamHasPossession(gameValues) then return end
		if workspace:FindFirstChild("Basketball") then return end
	end

	self.Args.SignalCD = true
	pc:PlayAnimation("Signal")
	controlService.CallPass:Fire()
	task.delay(7.5, function()
		if ic and ic.Args then ic.Args.SignalCD = false end
	end)
end

applyOverrides("InputController", icOverrides)

-- ═══════ Heartbeat + Guard Input ═══════

local function updateSpeedOverride()
	if not config.movement.speedOverride then return end
	local humanoid = pc and pc.Args and pc.Args.Humanoid
	if not humanoid then return end
	local targetSpeed = config.movement.speed or 17
	if humanoid.WalkSpeed ~= targetSpeed then humanoid.WalkSpeed = targetSpeed end
end

local function updateAutoGuardMode()
	if not config.defense.autoGuard then return end
	if not localPlayer or not localPlayer.Character then return end
	if hasBall(localPlayer.Character) or isBenched() then
		if not guardInputState.holdActive and guardInputState.toggleActive then
			guardInputState.toggleActive = false
		end
		syncDesiredGuardState(false)
		return
	end
	if guardInputState.holdActive or guardInputState.toggleActive then
		syncDesiredGuardState(true)
	elseif localPlayer.Character:GetAttribute("Guarding") == true then
		syncDesiredGuardState(false)
	end
end

local function updateAutoLock()
	local pcArgs = pc and pc.Args
	if not config.defense.autoLock then
		if autoLockActive then
			autoLockActive = false; autoLockTargetRoot = nil
			if pcArgs and pcArgs.BodyGyro then clearBodyGyro(pcArgs) end
		end
		return
	end
	if not localPlayer or not localPlayer.Character then return end

	local wasActive = autoLockActive
	autoLockActive = not hasBall(localPlayer.Character)

	if wasActive and not autoLockActive then
		autoLockTargetRoot = nil
		if pcArgs and pcArgs.BodyGyro then clearBodyGyro(pcArgs) end
		return
	end
	if autoLockActive and (autoGuardDriving or (ic and ic.Args and ic.Args.Posting)) then return end

	local preferOffBall = config.defense.autoLockPreferOffBall == true
	local now = tick()
	if autoLockPreferOffBall ~= preferOffBall then
		autoLockPreferOffBall = preferOffBall
		autoLockTargetRoot = nil; lastAutoLockRefreshTick = 0
	end

	if autoLockActive and pcArgs and pcArgs.HumanoidRootPart then
		if not autoLockTargetRoot or not autoLockTargetRoot.Parent
		or now - lastAutoLockRefreshTick >= getAutoLockRefreshInterval() then
			autoLockTargetRoot = findAutoLockTarget(preferOffBall)
			lastAutoLockRefreshTick = now
		end
		if autoLockTargetRoot then
			local myRoot = pcArgs.HumanoidRootPart
			local lookPos = getAutoLockLookPosition(autoLockTargetRoot)
			if lookPos then
				setBodyGyroLook(pcArgs, CFrame.lookAt(myRoot.Position, Vector3.new(lookPos.X, myRoot.Position.Y, lookPos.Z)))
			end
		elseif pcArgs.BodyGyro then clearBodyGyro(pcArgs) end
	end
end

local function updateAutoBlockExtreme()
	if not config.defense.autoBlock or not config.defense.autoBlockExtreme then return end
	if not fireTouch then return end
	local pcArgs = pc and pc.Args
	if not pcArgs or not pcArgs.Character then return end

	local gv = getGameValues()
	if not gv or gv.Inbounding or gv.Possession == nil then return end
	if not ignoreTeamPossessionChecks() and localTeamHasPossession(gv) then return end

	local now = tick()
	if now - lastExtremeAutoBlockTick < getExtremeAutoBlockInterval() then return end
	lastExtremeAutoBlockTick = now

	local rightHand = pcArgs.RightHand or pcArgs["Right Arm"]
	if not rightHand or not rightHand:IsDescendantOf(workspace) then return end
	local myRoot = pcArgs.HumanoidRootPart
	if not myRoot then return end

	local blockRange = getAutoBlockRange()
	for i = 1, #cachedPlayers do
		local player = cachedPlayers[i]
		if playersAreOpponents(player) and onCourtWith(player) and player.Character then
			local tRoot = player.Character:FindFirstChild("HumanoidRootPart")
			local attach = resolveBallAttach(player.Character)
			if tRoot and attach and attach:IsDescendantOf(workspace)
			and distanceSquared(myRoot.Position, tRoot.Position) <= (blockRange * blockRange) then
				controlService.Block:Fire()
				pcall(fireTouch, attach, rightHand, 0)
				task.delay(0.05, function()
					if attach and attach.Parent and rightHand and rightHand.Parent then
						pcall(fireTouch, attach, rightHand, 1)
					end
				end)
			end
		end
	end
end

-- Guard F/B key handlers
if autoLockInputService then
	autoLockInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		if input.KeyCode == guardInputState.holdKey then
			if not config.defense.autoGuard then return end
			guardInputState.holdActive = true
			syncDesiredGuardState(true, true)
		elseif input.KeyCode == guardInputState.toggleKey then
			if not config.defense.autoGuard then return end
			local now = tick()
			if now - guardInputState.lastToggleTick < GUARD_INPUT_TOGGLE_DEBOUNCE then return end
			guardInputState.lastToggleTick = now
			guardInputState.toggleActive = not guardInputState.toggleActive
			syncDesiredGuardState(guardInputState.toggleActive or guardInputState.holdActive, true)
		end
	end)

	autoLockInputService.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		if input.KeyCode == guardInputState.holdKey then
			if not config.defense.autoGuard then return end
			guardInputState.holdActive = false
			syncDesiredGuardState(guardInputState.toggleActive, true)
		end
	end)
end

runService.Heartbeat:Connect(function()
	updateSpeedOverride()
	updateAutoGuardMode()
	updateAutoLock()
	updateAutoBlockExtreme()
end)

-- ═══════ Auto Block System (Animation-Reactive) ═══════

local function cleanupAutoBlock(player)
	local conns = autoBlockConnections[player]
	if conns then
		for _, conn in ipairs(conns) do
			if typeof(conn) == "RBXScriptConnection" then conn:Disconnect() end
		end
		autoBlockConnections[player] = nil
	end
end

local function handleAutoBlockAnimation(player, character, animTrack)
	if not config.defense.autoBlock or config.defense.autoBlockExtreme then return end
	if hasBall(pc.Args.Character) then return end
	if not playersAreOpponents(player) or not onCourtWith(player) then return end

	local animId = animTrack and animTrack.Animation and animTrack.Animation.AnimationId
	if not animId or not blockReactiveAnimations[animId] then return end

	local gv = getGameValues()
	if not gv or gv.Inbounding or gv.Possession == nil then return end
	if not ignoreTeamPossessionChecks() and localTeamHasPossession(gv) then return end
	if not is5v5 and (gv.Practice or gv.ScoringContest) then return end
	if ic.Args.InAction or ic.Args.BlockCD then return end
	if pc.Args.Character:GetAttribute("Stealing")
	or pc.Args.Character:GetAttribute("Broken")
	or pc.Args.Character:GetAttribute("PostBlockedCD") then return end

	local myRoot = pc.Args.HumanoidRootPart
	local tRoot = character and character:FindFirstChild("HumanoidRootPart")
	if not myRoot or not tRoot then return end
	if (myRoot.Position - tRoot.Position).Magnitude > getAutoBlockRange() then return end

	local now = tick()
	if now - lastAutoBlockTick < getAutoBlockCooldown() then return end
	lastAutoBlockTick = now

	local rightHand = pc.Args.RightHand or pc.Args["Right Arm"]
	if not rightHand then return end

	task.delay(getAutoBlockTriggerDelay(), function()
		if not config.defense.autoBlock then return end
		if not character or not character.Parent then return end
		local attach = resolveBallAttach(character)
		if not attach then return end
		controlService.Block:Fire()
		if fireTouch then
			pcall(fireTouch, attach, rightHand, 0)
			task.delay(getAutoBlockReleaseDelay(), function()
				pcall(fireTouch, attach, rightHand, 1)
			end)
		end
	end)
end

local function handleAutoAnkleBreakerAnimation(player, character, animTrack)
	if not config.defense.autoAnkleBreaker then return end
	if not pc or not pc.Args or not ic or not ic.Args then return end
	if isBenched() then return end
	if not hasBall(pc.Args.Character) then return end
	if not playersAreOpponents(player) or not onCourtWith(player) then return end

	local animId = animTrack and animTrack.Animation and animTrack.Animation.AnimationId
	if not animId or not stealReactiveAnimations[animId] then return end

	local gv = getGameValues()
	if not gv or gv.Inbounding or gv.Possession == nil then return end
	if not ignoreTeamPossessionChecks() and not localTeamHasPossession(gv) then return end
	if not is5v5 and (gv.Practice or gv.ScoringContest) then return end
	if ic.Args.Posting or ic.Args.DoubleDribble or pc.Args.Character:GetAttribute("Broken") then return end

	local myRoot = pc.Args.HumanoidRootPart
	local tRoot = character and character:FindFirstChild("HumanoidRootPart")
	if not myRoot or not tRoot then return end
	if (myRoot.Position - tRoot.Position).Magnitude > (config.defense.ankleBreakerRange or 18) then return end

	local reactiveMove = getAutoAnkleBreakerMove()
	if not reactiveMove then return end

	local now = tick()
	if now - lastAutoAnkleBreakerTick < AUTO_ANKLE_BREAKER_COOLDOWN then return end
	lastAutoAnkleBreakerTick = now
	autoAnkleBreakerRunId = autoAnkleBreakerRunId + 1
	local runId = autoAnkleBreakerRunId

	ic.Args.CanShoot = true; ic.Args.CanDribble = true

	task.delay(config.defense.ankleBreakerDelay or 0.06, function()
		if runId ~= autoAnkleBreakerRunId then return end
		if not config.defense.autoAnkleBreaker then return end
		if not player or player.Parent == nil then return end
		if not character or not character.Parent then return end
		if not pc or not pc.Args or not ic or not ic.Args then return end
		if not hasBall(pc.Args.Character) then return end

		local dgv = getGameValues()
		if not dgv or dgv.Inbounding or dgv.Possession == nil then return end
		if not ignoreTeamPossessionChecks() and not localTeamHasPossession(dgv) then return end

		local curRoot = pc.Args.HumanoidRootPart
		local dRoot = character:FindFirstChild("HumanoidRootPart")
		if not curRoot or not dRoot then return end
		if (curRoot.Position - dRoot.Position).Magnitude > (config.defense.ankleBreakerRange or 18) then return end

		ic:Dribble(reactiveMove)
	end)
end

local function bindAutoBlockToCharacter(player, character)
	if player == localPlayer then return end
	cleanupAutoBlock(player)

	local conns = {}
	autoBlockConnections[player] = conns

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	local boundAnimators = {}

	local function bindAnimator(animator)
		if not animator or boundAnimators[animator] then return end
		boundAnimators[animator] = true
		conns[#conns + 1] = animator.AnimationPlayed:Connect(function(animTrack)
			handleAutoBlockAnimation(player, character, animTrack)
			handleAutoAnkleBreakerAnimation(player, character, animTrack)
		end)
	end

	local animator = humanoid:FindFirstChildOfClass("Animator") or humanoid:WaitForChild("Animator", 3)
	bindAnimator(animator)
	conns[#conns + 1] = humanoid.ChildAdded:Connect(function(child)
		if child:IsA("Animator") then bindAnimator(child) end
	end)
end

local function attachAutoBlockPlayer(player)
	if player == localPlayer then return end
	if player.Character then bindAutoBlockToCharacter(player, player.Character) end
	local conn = player.CharacterAdded:Connect(function(character)
		task.wait(0.5)
		if character and character.Parent then bindAutoBlockToCharacter(player, character) end
	end)
	local existing = autoBlockConnections[player]
	if existing then existing[#existing + 1] = conn
	else autoBlockConnections[player] = { conn } end
end

for _, player in ipairs(playersService:GetPlayers()) do
	task.spawn(attachAutoBlockPlayer, player)
end
playersService.PlayerAdded:Connect(attachAutoBlockPlayer)
playersService.PlayerRemoving:Connect(cleanupAutoBlock)

-- ═══════ UI ═══════

task.spawn(function()
local BlackwineLib = loadstring(game:HttpGet("https://raw.githubusercontent.com/gfn8879-hub/blackwine/refs/heads/main/ui.lua"))()
local Window = BlackwineLib:CreateWindow({
	Title = "blackwine",
	Size = UDim2.fromOffset(640, 440),
	ToggleKey = Enum.KeyCode.RightShift,
})

-- helper: DRY bind for toggle / slider / dropdown
local function bindToggle(section, name, tbl, key, extra)
	section:AddToggle({
		Name = name,
		Default = tbl[key],
		Callback = function(v) tbl[key] = v; if extra then extra(v) end; scheduleConfigSave() end,
	})
end

local function bindSlider(section, name, tbl, key, min, max, inc, suffix, extra)
	section:AddSlider({
		Name = name,
		Min = min, Max = max, Increment = inc, Default = tbl[key],
		Suffix = suffix or "",
		Callback = function(v) tbl[key] = v; if extra then extra(v) end; scheduleConfigSave() end,
	})
end

-- ═══════ Home Tab ═══════
local HomeTab = Window:CreateTab({ Name = "Home" })
local HomeSec = HomeTab:AddSection({ Name = "welcome to blackwine." })
HomeSec:AddButton({ Name = "Rejoin Server", Callback = rejoinServer })
HomeSec:AddButton({ Name = "Join Ranked", Callback = teleportToRanked })

-- ═══════ Offense Tab ═══════
local OffenseTab = Window:CreateTab({ Name = "Offense" })

-- Shooting (left)
local ShootSec = OffenseTab:AddSection({ Name = "Shooting", Side = "left" })
bindToggle(ShootSec, "Auto Green", config.moves.jumpshot, "autoGreen")
bindToggle(ShootSec, "Perfect Release", config.moves.jumpshot, "perfectRelease")
bindSlider(ShootSec, "Green Chance", config.moves.jumpshot, "greenChance", 0, 100, 1, "%")
bindSlider(ShootSec, "Shot Speed", config.moves.jumpshot, "shotSpeed", 0.5, 3, 0.05)
bindToggle(ShootSec, "Auto Release", config.moves.jumpshot, "autoRelease")
bindSlider(ShootSec, "Release Delay", config.moves.jumpshot, "releaseDelay", 0.05, 0.75, 0.05)
bindSlider(ShootSec, "Jumpshot Boost", config.moves.jumpshot, "boost", 0.5, 3, 0.1)

-- Dribble & Pump Fake (right)
local DribbleSec = OffenseTab:AddSection({ Name = "Dribble & Pump Fake", Side = "right" })
bindToggle(DribbleSec, "No Dribble Cooldown", config.moves.dribble, "noDribbleCooldown")
bindSlider(DribbleSec, "Dribble Anim Speed", config.moves.dribble, "animSpeed", 0.5, 5, 0.1)
bindSlider(DribbleSec, "Dribble Boost", config.moves.dribble, "boost", 0.5, 3, 0.1)
bindToggle(DribbleSec, "Force Shot (Pump Fake)", config.moves.pumpFake, "forceShot")
bindToggle(DribbleSec, "Jumpshot Fake", config.moves.pumpFake, "jumpshotFake")
bindToggle(DribbleSec, "No Pump Fake Cooldown", config.moves.pumpFake, "noPumpFakeCooldown")
bindToggle(DribbleSec, "Infinite Pump Fake", config.moves.pumpFake, "infinitePumpFake")

-- Dunking (left)
local DunkSec = OffenseTab:AddSection({ Name = "Dunking", Side = "left" })
bindToggle(DunkSec, "Dunk Changer", config.moves.dunk, "dunkChanger")
DunkSec:AddDropdown({
	Name = "Dunk Type",
	Items = { "Tomahawk", "360", "Reverse", "Eastbay", "Double Clutch", "Under the Legs", "Windmill" },
	Default = config.moves.dunk.dunkType,
	Callback = function(v) config.moves.dunk.dunkType = v; scheduleConfigSave() end,
})
bindSlider(DunkSec, "Dunk Height", config.moves.dunk, "dunkHeight", -3, 3, 0.1)
bindToggle(DunkSec, "No Dunk Cooldown", config.moves.dunk, "noDunkCooldown")
bindToggle(DunkSec, "Unlock Dunk Range", config.moves.dunk, "unlockRange")
bindSlider(DunkSec, "Dunk Boost", config.moves.dunk, "boost", 0.5, 3, 0.1)

-- Movement & Ranges (right)
local MovesSec = OffenseTab:AddSection({ Name = "Movement & Ranges", Side = "right" })
bindToggle(MovesSec, "Unlock Euro Range", config.moves.euro, "unlockRange")
bindToggle(MovesSec, "Unlock Post Range", config.moves.post, "unlockRange")
bindToggle(MovesSec, "Unlock Self Lob Range", config.moves.selfLob, "unlockRange")
bindSlider(MovesSec, "Euro Boost", config.moves.euro, "boost", 0.5, 3, 0.1)
bindSlider(MovesSec, "Fade Boost", config.moves.fade, "boost", 0.5, 3, 0.1)
bindSlider(MovesSec, "Layup Boost", config.moves.layup, "boost", 0.5, 3, 0.1)
bindSlider(MovesSec, "Stepback Boost", config.moves.stepback, "boost", 0.5, 3, 0.1)
bindSlider(MovesSec, "Layup Anim Speed", config.moves.layup, "animSpeed", 0.5, 2, 0.1)
bindSlider(MovesSec, "Pass Boost", config.moves.pass, "boost", 0.5, 3, 0.1)

-- Post (left)
local PostSec = OffenseTab:AddSection({ Name = "Post", Side = "left" })
bindToggle(PostSec, "Auto Dropstep", config.moves.post, "autoDropstep")
bindSlider(PostSec, "Dropstep Radius", config.moves.post, "dropstepRange", 3, 12, 0.5)
bindToggle(PostSec, "Auto Hook", config.moves.post, "autoHook")
bindSlider(PostSec, "Hook Range", config.moves.post, "hookRange", 5, 15, 0.5)
bindSlider(PostSec, "Hand Scale", config.moves.post, "handScale", 1, 2.5, 0.05, nil, function() updateActivePostHandScale() end)
bindToggle(PostSec, "Face Defender", config.moves.post, "faceDefender")
bindSlider(PostSec, "Post Boost", config.moves.post, "boost", 0.5, 3, 0.1)
bindSlider(PostSec, "Assist Cooldown", config.moves.post, "assistCooldown", 0, 5, 0.05)
bindSlider(PostSec, "Hook Cooldown", config.moves.post, "hookCooldown", 0, 5, 0.05)
bindSlider(PostSec, "Hook Windup", config.moves.post, "hookTriggerDelay", 0, 1, 0.01)

-- ═══════ Defense Tab ═══════
local DefenseTab = Window:CreateTab({ Name = "Defense" })

-- Blocking (left)
local BlockSec = DefenseTab:AddSection({ Name = "Blocking", Side = "left" })
bindToggle(BlockSec, "Auto Block", config.defense, "autoBlock")
bindToggle(BlockSec, "Extreme Auto Block", config.defense, "autoBlockExtreme")
bindSlider(BlockSec, "Blockbox Size", config.defense, "blockboxSize", 0, 200, 1, nil, function(v)
	config.defense.blockboxSize = normalizeBlockboxSize(v)
	refreshPhysicalBlockbox()
end)
bindSlider(BlockSec, "Block Boost", config.moves.block, "boost", 0.5, 3, 0.1)
bindSlider(BlockSec, "Auto Block Range", config.defense, "autoBlockRange", 5, 60, 1)
bindSlider(BlockSec, "Block Cooldown", config.defense, "autoBlockCooldown", 0, 3, 0.05)
bindSlider(BlockSec, "Block Windup", config.defense, "autoBlockTriggerDelay", 0, 1, 0.01)
bindSlider(BlockSec, "Release Window", config.defense, "autoBlockReleaseDelay", 0, 1, 0.01)
bindSlider(BlockSec, "Extreme Interval", config.defense, "extremeAutoBlockInterval", 0.01, 0.5, 0.01)

-- Guarding (right)
local GuardSec = DefenseTab:AddSection({ Name = "Guarding", Side = "right" })
GuardSec:AddToggle({
	Name = "Auto Guard",
	Default = config.defense.autoGuard,
	Callback = function(v)
		config.defense.autoGuard = v
		if not v then
			guardInputState.holdActive = false; guardInputState.toggleActive = false
			syncDesiredGuardState(false, true)
		end
		scheduleConfigSave()
	end,
})
bindToggle(GuardSec, "Auto Lock", config.defense, "autoLock")
bindToggle(GuardSec, "Prefer Off-Ball Lock", config.defense, "autoLockPreferOffBall")
GuardSec:AddLabel({ Text = "Hold F for guard assist. Press B to toggle sticky guard." })
bindSlider(GuardSec, "Guard Range", config.defense, "guardRange", 5, 100, 1)
bindSlider(GuardSec, "Guard Refresh", config.defense, "guardRefreshInterval", 0.01, 0.5, 0.01)
bindSlider(GuardSec, "Target Switch Cooldown", config.defense, "guardTargetSwitchCooldown", 0.05, 1, 0.05)
bindSlider(GuardSec, "Lock Lead Distance", config.defense, "autoLockLeadDistance", 0, 15, 0.25)
bindSlider(GuardSec, "Lock Refresh", config.defense, "autoLockRefreshInterval", 0.01, 0.5, 0.01)
bindSlider(GuardSec, "Guard Speed Factor", config.defense, "autoGuardSpeedFactor", 1, 60, 1)
bindSlider(GuardSec, "Guard Min Speed", config.defense, "autoGuardMinSpeed", 0, 40, 1)
bindSlider(GuardSec, "Guard Max Speed", config.defense, "autoGuardMaxSpeed", 0, 60, 1)
bindToggle(GuardSec, "Anti Bump", config.defense, "antiBump")

-- Stealing (left)
local StealSec = DefenseTab:AddSection({ Name = "Stealing", Side = "left" })
bindToggle(StealSec, "Perfect Steal", config.moves.steal, "perfectSteal")
bindToggle(StealSec, "No Steal Cooldown", config.moves.steal, "noStealCooldown")
bindToggle(StealSec, "Phantom Steal", config.moves.steal, "phantomSteal")
bindSlider(StealSec, "Steal Boost", config.moves.steal, "boost", 0.5, 3, 0.1)
bindToggle(StealSec, "Passive Steal", config.moves.steal, "passiveSteal", function(v) setPassiveSteal(v) end)
bindSlider(StealSec, "Passive Interval", config.moves.steal, "passiveInterval", 0.05, 2, 0.05)
bindToggle(StealSec, "Auto Ankle Breaker", config.defense, "autoAnkleBreaker")
bindSlider(StealSec, "Ankle Breaker Range", config.defense, "ankleBreakerRange", 5, 35, 1)
bindSlider(StealSec, "Ankle Breaker Delay", config.defense, "ankleBreakerDelay", 0, 0.3, 0.01)
bindSlider(StealSec, "Rebound Boost", config.moves.rebound, "boost", 0.5, 3, 0.1)

-- Ball Magnet (right)
local BallMagnetSec = DefenseTab:AddSection({ Name = "Ball Magnet", Side = "right" })
BallMagnetSec:AddToggle({
	Name = "Ball Magnet",
	Default = config.ballMagnet.enabled,
	Callback = function(v) setBallMagnet(v) end,
})
bindSlider(BallMagnetSec, "Scale", config.ballMagnet, "scale", 10, 100, 5, nil, function() refreshBallMagnet() end)
bindToggle(BallMagnetSec, "Resize Ball", config.ballMagnet, "resizeEnabled", function() refreshBallMagnet() end)
bindToggle(BallMagnetSec, "Direct Touch Fire", config.ballMagnet, "directTouchEnabled")
bindSlider(BallMagnetSec, "Grab Radius", config.ballMagnet, "range", 5, 40, 1, nil, function() refreshBallMagnet() end)
bindSlider(BallMagnetSec, "Touch Cooldown", config.ballMagnet, "touchCooldown", 0.01, 1, 0.01)
bindSlider(BallMagnetSec, "Screen Boost", config.moves.screen, "boost", 0.5, 3, 0.1)

-- ═══════ Movement Tab ═══════
local MovementTab = Window:CreateTab({ Name = "Movement" })

local SpeedSec = MovementTab:AddSection({ Name = "Speed", Side = "left" })
bindToggle(SpeedSec, "Speed Override", config.movement, "speedOverride")
bindSlider(SpeedSec, "Walk Speed", config.movement, "speed", 1, 50, 1)
bindToggle(SpeedSec, "No Jump Cooldown", config.movement, "noJumpCooldown")
bindSlider(SpeedSec, "Gyro Torque", config.movement, "bodyGyroTorque", 0, 2000000, 50000)
bindSlider(SpeedSec, "Velocity Force", config.movement, "bodyVelocityForce", 0, 2000000, 50000)
bindSlider(SpeedSec, "Turn Unlock Delay", config.movement, "turnUnlockDelay", 0, 1, 0.01)

local AbilitySec = MovementTab:AddSection({ Name = "Abilities", Side = "right" })
bindToggle(AbilitySec, "Unlock All Moves", config.abilities, "unlockAllMoves")
bindToggle(AbilitySec, "Ignore Team/Possession Checks", config.abilities, "ignoreTeamPossessionChecks")
bindToggle(SpeedSec, "Hide CoreGui", config.movement, "hideCoreGui")

-- ═══════ Misc Tab (NEW) ═══════
local MiscTab = Window:CreateTab({ Name = "Misc" })

-- Teleporter (left)
local TeleportSec = MiscTab:AddSection({ Name = "Teleporter", Side = "left" })
TeleportSec:AddButton({ Name = "Rejoin Server", Callback = rejoinServer })
TeleportSec:AddButton({ Name = "Server Hop", Callback = serverHop })
TeleportSec:AddButton({ Name = "Teleport to Ranked", Callback = teleportToRanked })

-- Steal Reach (right)
local ReachSec = MiscTab:AddSection({ Name = "Steal Reach", Side = "right" })
bindToggle(ReachSec, "Enable Steal Reach", config.moves.steal, "reachEnabled")
bindSlider(ReachSec, "Reach Multiplier", config.moves.steal, "reachMultiplier", 1, 3, 0.1)

-- ═══════ Settings Tab ═══════
local SettingsTab = Window:CreateTab({ Name = "Settings" })

local ConfigSec = SettingsTab:AddSection({ Name = "Configuration", Side = "left" })
ConfigSec:AddButton({ Name = "Save Config", Callback = function() saveConfig(config) end })
ConfigSec:AddButton({
	Name = "Load Config",
	Callback = function()
		loadConfigFromDisk(config)
		syncDebugState(); refreshPhysicalBlockbox(); refreshBallMagnet()
		logger.info("config loaded — some changes may require rejoin")
	end,
})
ConfigSec:AddButton({
	Name = "Reset Config",
	Callback = function()
		if not canUseFileApi() then return end
		local ok = pcall(function()
			if typeof(delfile) == "function" then delfile(CONFIG_FILE)
			elseif typeof(writefile) == "function" then writefile(CONFIG_FILE, "{}") end
		end)
		if ok then logger.info("config reset — rejoin to apply defaults") end
	end,
})

local DebugSec = SettingsTab:AddSection({ Name = "Diagnostics", Side = "right" })
bindToggle(DebugSec, "Debug Logging", config.debug, "enabled", function() syncDebugState() end)

local InfoSec = SettingsTab:AddSection({ Name = "Info", Side = "right" })
InfoSec:AddLabel({ Text = "Config auto-saves after changes." })
InfoSec:AddLabel({ Text = "File: " .. CONFIG_FILE })
InfoSec:AddLabel({ Text = "Mode: " .. (is5v5 and "5v5" or "MyPark") })

end)

-- ═══════ Initialization ═══════

-- re-fire CharacterAdded for current character
if localPlayer.Character then
	pc:CharacterAdded(localPlayer.Character)
	localPlayer.Character:BreakJoints()
end

-- start passive steal / ball magnet from saved config
if config.moves.steal.passiveSteal then setPassiveSteal(true, true) end
if config.ballMagnet.enabled then setBallMagnet(true, true) end

logger.info("blackwine fully initialized")

]])
