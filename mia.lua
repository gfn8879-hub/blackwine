if not getactors or not run_on_actor then error("your executor does not support blackwine.") end

local actors = getactors()
local playerActor = actors and actors[1]

if not playerActor then
	error("blackwine failed to start: no actor available")
end

run_on_actor(playerActor, [[
-- utilities
-- TODO: aggregate all logs in an autoupdating file over a 5-10s interval for better debugging when logger is enabled
local debugState = {
enabled = false,
traceBodyMovers = false,
}

local logger = {
info = function(...)
print("[blackwine] [info]", ...)
end,
warn = function(...)
warn("[blackwine] [warn]", ...)
end,
debug = function(...)
if not debugState.enabled then return end
print("[blackwine] [debug]", ...)
end,
error = function(...)
local formatted = {}
for i = 1, select("#", ...) do
	formatted[i] = tostring(select(i, ...))
end
warn("[blackwine] [error]", table.concat(formatted, " "))
end,
}

if type(hookfunction) ~= "function" or type(newcclosure) ~= "function" then
	logger.error("actor environment missing required hook primitives:", "hookfunction=", type(hookfunction), "newcclosure=", type(newcclosure))
	return
end

if not task or type(task.spawn) ~= "function" then
	logger.warn("task library unavailable, some features may not work")
end

local services = setmetatable({}, {
__index = function(self, key)
local ok, service = pcall(game.GetService, game, key)
if ok and service then
	rawset(self, key, service)
	return service
end
logger.warn("service '" .. key .. "' invalid or not found")
end,
})



-- services
local playersService = services.Players
local replicatedStorage = services.ReplicatedStorage
local localPlayer = playersService.LocalPlayer

-- variables for game core
local controllersDir = replicatedStorage:WaitForChild("Controllers")
local packagesDir = replicatedStorage:WaitForChild("Packages")
local modulesDir = replicatedStorage:WaitForChild("Modules")

-- gamemode detection: FanController only exists in 5v5
local is5v5 = controllersDir:FindFirstChild("FanController") ~= nil
local collectionService = services.CollectionService

local sharedUtil = require(modulesDir:WaitForChild("SharedUtil"))
local basketball = require(modulesDir:WaitForChild("Basketball"))
local items = require(modulesDir:WaitForChild("Items"))

-- park module (for ranked teleport)
local parkModule
do
	local uiControllerFolder = controllersDir:FindFirstChild("UIController")
	if uiControllerFolder then
		local ok, moduleResult = pcall(function()
		local parkScript = uiControllerFolder:FindFirstChild("Park") or uiControllerFolder:WaitForChild("Park", 5)
		if parkScript then return require(parkScript) end
	end)
	if ok and type(moduleResult) == "table" and type(moduleResult.Teleport) == "function" then
		parkModule = moduleResult
	end
end
end

local function teleportToRanked()
	if parkModule then
		local ok, err = pcall(parkModule.Teleport, parkModule, "Ranked")
		if not ok then logger.warn("ranked teleport failed: " .. tostring(err)) end
	else
		logger.warn("park module unavailable for ranked teleport")
	end
end

local function rejoinServer()
	local ts = services.TeleportService
	if ts then
		pcall(ts.Teleport, ts, game.PlaceId, localPlayer)
	end
end

local knit = require(packagesDir:WaitForChild("Knit"))

-- knit services (used for server communication / remotes inside overrides)
local knitServices = {}
for _, serviceName in ipairs({"PlayerService", "ControlService"}) do
	local ok, svc = pcall(knit.GetService, serviceName)
	if ok and svc then
		knitServices[serviceName] = svc
	else
		logger.warn("failed to get knit service '" .. serviceName .. "': " .. tostring(svc))
	end
end

-- ═══════ Configuration Persistence ═══════
local HttpService = game:GetService("HttpService")
local CONFIG_FILE = "blackwine_config.json"
local LEGACY_CONFIG_FILE = "redwine_1_1_0_config.json"
local CONFIG_SAVE_DELAY = 1.5
local CONFIG_VERSION = 2
local pendingConfigSave
local configApplying = false

local EMPTY_CONFIG = {}
if table.freeze then
	table.freeze(EMPTY_CONFIG)
end

local function canUseFileApi()
	return typeof(isfile) == "function" and typeof(readfile) == "function" and typeof(writefile) == "function"
end

local function mergeConfig(target, patch)
	if type(target) ~= "table" or type(patch) ~= "table" then return end
	for key, value in pairs(patch) do
		local current = target[key]
		if type(current) == "table" and type(value) == "table" then
			mergeConfig(current, value)
		else
			target[key] = value
		end
	end
end

local function saveConfig(cfg)
	if not canUseFileApi() then return false end
	cfg.version = CONFIG_VERSION
	local okEncode, encoded = pcall(HttpService.JSONEncode, HttpService, cfg)
	if not okEncode then
		logger.warn("failed to encode config: " .. tostring(encoded))
		return false
	end
	local okWrite, err = pcall(writefile, CONFIG_FILE, encoded)
	if not okWrite then
		logger.warn("failed to save config: " .. tostring(err))
		return false
	end
	logger.info("config saved")
	return true
end

local function scheduleConfigSave() end -- forward declaration, replaced after config exists

local function normalizeBlockboxSize(rawValue)
	if type(rawValue) ~= "number" then
		return 3
	end
	return math.clamp(rawValue, 0, 200)
end

local function migrateConfigShape(cfg)
	if type(cfg) ~= "table" then
		return false
	end

	local changed = false
	local movement = cfg.movement
	if type(movement) == "table" then
		if movement.speedOverride == nil and movement.movementOverride ~= nil then
			movement.speedOverride = movement.movementOverride
			changed = true
		end
		if movement.speed == nil and type(movement.movementSpeed) == "number" then
			movement.speed = movement.movementSpeed
			changed = true
		end
		if movement.movementOverride ~= nil then
			movement.movementOverride = nil
			changed = true
		end
		if movement.movementSpeed ~= nil then
			movement.movementSpeed = nil
			changed = true
		end
	end

	local defense = cfg.defense
	if type(defense) ~= "table" then
		defense = {}
		cfg.defense = defense
		changed = true
	end

	if type(defense.blockboxSize) ~= "number" then
		if defense.minimizeBlockBox == true then
			defense.blockboxSize = 0
		else
			defense.blockboxSize = 3
		end
		changed = true
	else
		local normalized = normalizeBlockboxSize(defense.blockboxSize)
		if normalized ~= defense.blockboxSize then
			defense.blockboxSize = normalized
			changed = true
		end
	end

	if defense.minimizeBlockBox ~= nil then
		defense.minimizeBlockBox = nil
		changed = true
	end

	if type(cfg.debug) ~= "table" then
		cfg.debug = {
		enabled = false,
		traceBodyMovers = false,
		}
		changed = true
	else
		if cfg.debug.enabled == nil then
			cfg.debug.enabled = false
			changed = true
		end
		if cfg.debug.traceBodyMovers == nil then
			cfg.debug.traceBodyMovers = false
			changed = true
		end
	end

	if cfg.version ~= CONFIG_VERSION then
		cfg.version = CONFIG_VERSION
		changed = true
	end

	return changed
end

local function readConfigFile(fileName)
	local okExists, exists = pcall(isfile, fileName)
	if not okExists or not exists then return nil end
	local okRead, raw = pcall(readfile, fileName)
	if not okRead or type(raw) ~= "string" then
		logger.warn("failed to read config file '" .. fileName .. "'")
		return nil
	end
	local okDecode, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if not okDecode or type(decoded) ~= "table" then
		logger.warn("failed to decode config file '" .. fileName .. "'")
		return nil
	end
	return decoded
end

local getConfigSection
local getConfigTable
local getConfigValue
local syncDebugState

	local function loadConfigFromDisk(cfg)
		if not canUseFileApi() then return false end
		local sourceFile = nil
		local decoded = readConfigFile(CONFIG_FILE)
		if decoded then
			sourceFile = CONFIG_FILE
		else
			decoded = readConfigFile(LEGACY_CONFIG_FILE)
			if decoded then
				sourceFile = LEGACY_CONFIG_FILE
			end
		end
		if not decoded then return false end
		mergeConfig(cfg, decoded)
		local migrated = migrateConfigShape(cfg)
		if type(syncDebugState) == "function" then
			syncDebugState()
		end
		logger.info("config loaded from disk", sourceFile)
		if migrated and sourceFile ~= CONFIG_FILE then
			logger.info("legacy config migrated to current schema")
			saveConfig(cfg)
		end
		return true
	end

	-- config
	local config = {
	movement = {
	speedOverride = false,
	speed = 17,
	noJumpCooldown = false,
	hideCoreGui = true,
	bodyGyroTorque = 1000000,
	bodyVelocityForce = 1000000,
	turnUnlockDelay = 0.1,
	},
	moves = {
	jumpshot = {
	boost = 1,
	autoGreen = false,
	perfectRelease = false,
	greenChance = 50,
	shotSpeed = 1.25,
	autoRelease = false,
	releaseDelay = 0.35,
	},
	fade = { boost = 1 },
	layup = { boost = 1, animSpeed = 1 },
	euro = { boost = 1, unlockRange = false },
	post = {
	boost = 1,
	unlockRange = false,
	autoDropstep = false,
	dropstepRange = 7,
	autoHook = false,
	hookRange = 8.5,
	handScale = 1,
	faceDefender = false,
	assistCooldown = 1.2,
	hookCooldown = 2,
	hookTriggerDelay = 0.32,
	},
	dribble = { boost = 1, noDribbleCooldown = false, animSpeed = 1 },
	pumpFake = {
	boost = 1,
	forceShot = false,
	jumpshotFake = false,
	noPumpFakeCooldown = false,
	infinitePumpFake = false,
	},
	stepback = { boost = 1 },
	dunk = {
	boost = 1,
	unlockRange = false,
	dunkChanger = false,
	dunkType = "Tomahawk",
	dunkHeight = -0.4,
	noDunkCooldown = false,
	},
	block = { boost = 1 },
	steal = {
	boost = 1,
	perfectSteal = false,
	noStealCooldown = false,
	phantomSteal = false,
	passiveSteal = false,
	passiveInterval = 0.3,
	},
	pass = { boost = 1 },
	rebound = { boost = 1 },
	screen = { boost = 1 },
	selfLob = { unlockRange = false },
	},
	defense = {
	antiBump = false,
	autoAnkleBreaker = false,
	autoGuard = false,
	autoBlock = false,
	autoBlockExtreme = false,
	autoLock = false,
	blockboxSize = 3,
	autoBlockRange = 25,
	autoBlockCooldown = 0.9,
	autoBlockTriggerDelay = 0.32,
	autoBlockReleaseDelay = 0.12,
	extremeAutoBlockInterval = 0.08,
	guardRefreshInterval = 0.05,
	guardTargetSwitchCooldown = 0.3,
	autoLockRefreshInterval = 0.05,
	autoLockLeadDistance = 3,
	autoLockPreferOffBall = false,
	autoGuardSpeedFactor = 25,
	autoGuardMinSpeed = 6,
	autoGuardMaxSpeed = 32,
	ankleBreakerRange = 18,
	ankleBreakerDelay = 0.06,
	guardRange = 25,
	},
	abilities = {
	unlockAllMoves = false,
	ignoreTeamPossessionChecks = false,
	},
	ballMagnet = {
	enabled = false,
	scale = 50,
	range = 20,
	resizeEnabled = true,
	directTouchEnabled = true,
	touchCooldown = 0.15,
	},
	debug = {
	enabled = false,
	traceBodyMovers = false,
	},
	version = CONFIG_VERSION,
	}

	getConfigSection = function(...)
		local node = config
		local count = select("#", ...)
		if count == 0 then
			return node
		end
		for i = 1, count do
			if type(node) ~= "table" then
				return nil
			end
			local key = select(i, ...)
			node = node[key]
			if node == nil then
				return nil
			end
		end
		return node
	end

	getConfigTable = function(default, ...)
		local value = getConfigSection(...)
		if type(value) == "table" then
			return value
		end
		return default or EMPTY_CONFIG
	end

	getConfigValue = function(default, ...)
		local value = getConfigSection(...)
		if value == nil then
			return default
		end
		return value
	end

	syncDebugState = function()
		local debugConfig = getConfigTable(EMPTY_CONFIG, "debug")
		debugState.enabled = debugConfig.enabled == true
		debugState.traceBodyMovers = debugConfig.traceBodyMovers == true
	end

	migrateConfigShape(config)
	syncDebugState()

	-- load saved config from disk (merges over defaults)
	loadConfigFromDisk(config)

	-- now wire up the real scheduleConfigSave
	scheduleConfigSave = function()
	if configApplying then return end
	if not canUseFileApi() then return end
	if pendingConfigSave then
		pcall(task.cancel, pendingConfigSave)
	end
	pendingConfigSave = task.delay(CONFIG_SAVE_DELAY, function()
	pendingConfigSave = nil
	saveConfig(config)
end)
end

-- dunk type lookup
local DUNK_TYPES = {
["360"] = "360",
["Reverse"] = "Reverse",
["Eastbay"] = "Testing2",
["Double Clutch"] = "Testing3",
["Under the Legs"] = "Testing",
["Tomahawk"] = "Tomahawk",
["Windmill"] = "Windmill",
}

-- firetouchinterest reference (for perfect steal / auto block contact)
local fireTouch = (typeof(firetouchinterest) == "function") and firetouchinterest or nil


-- ball magnet state
local ballMagnetState = {
tracked = {},
originals = {},
partConnections = {},
watchers = {},
touchCooldowns = {},
enabled = false,
heartbeat = nil,
}
local BALL_MAGNET_TOUCH_COOLDOWN = 0.15
local GUARD_TARGET_SWITCH_COOLDOWN = 0.3
local GUARD_INPUT_TOGGLE_DEBOUNCE = 0.2

-- passive steal state
local passiveStealEnabled = false
local passiveStealThread = nil
local passiveStealRunId = 0

-- post assist state
local lastPostAssistTick = 0
local lastAutoHookTick = 0
local POST_ASSIST_COOLDOWN = 1.2
local POST_HOOK_COOLDOWN = 2

-- cached player list (avoids :GetPlayers() every frame)
local cachedPlayers = {}

local function populateCachedPlayers()
	for i = #cachedPlayers, 1, -1 do cachedPlayers[i] = nil end
	for _, player in ipairs(playersService:GetPlayers()) do
		cachedPlayers[#cachedPlayers + 1] = player
	end
end

local function addCachedPlayer(player)
	cachedPlayers[#cachedPlayers + 1] = player
end

local function removeCachedPlayer(player)
	for i = #cachedPlayers, 1, -1 do
		if cachedPlayers[i] == player then
			table.remove(cachedPlayers, i)
			break
		end
	end
end

-- auto block state
local autoBlockConnections = {}
local lastAutoBlockTick = 0
local AUTO_BLOCK_COOLDOWN = 0.9
local lastAutoAnkleBreakerTick = 0
local autoAnkleBreakerRunId = 0
local AUTO_ANKLE_BREAKER_COOLDOWN = 0.75
local PHYSICAL_BLOCKBOX_SIZE = 3
local EXTREME_AUTO_BLOCK_INTERVAL = 0.08
local lastExtremeAutoBlockTick = 0
local GUARD_TARGET_REFRESH_INTERVAL = 0.05
local AUTO_LOCK_REFRESH_INTERVAL = 0.05
local AUTO_LOCK_LEAD_DISTANCE = 3

local blockReactiveAnimations = {}
local stealReactiveAnimations = {}

local function shouldTrackBlockAnimationByName(name)
	if not name then return false end
	return name:match("^Dunk") or name:match("^Jumpshot") or name:find("PostHook") or name:find("Layup") or name:find("Floater") or name:find("Reverse")
end

local function shouldTrackStealAnimationByName(name)
	return name ~= nil and name:find("Steal") ~= nil
end

local function registerTrackedAnimations()
	for k in pairs(blockReactiveAnimations) do blockReactiveAnimations[k] = nil end
	for k in pairs(stealReactiveAnimations) do stealReactiveAnimations[k] = nil end
	local function scanFolder(folder)
		if not folder then return end
		for _, anim in ipairs(folder:GetChildren()) do
			if anim:IsA("Animation") then
				if shouldTrackBlockAnimationByName(anim.Name) then
					blockReactiveAnimations[anim.AnimationId] = anim.Name
				end
				if shouldTrackStealAnimationByName(anim.Name) then
					stealReactiveAnimations[anim.AnimationId] = anim.Name
				end
			end
		end
	end
	local assets = replicatedStorage:FindFirstChild("Assets")
	if assets then
		scanFolder(assets:FindFirstChild("Animations_R6"))
		scanFolder(assets:FindFirstChild("Animations_R15"))
	end
end

registerTrackedAnimations()

-- auto guard driving state
local autoGuardDriving = false
local lastGuardTargetRefreshTick = 0
local lastGuardTargetSwitchTick = 0
local cachedGuardBall = nil
local cachedGuardTargetRoot = nil
local guardInputState = {
holdKey = Enum.KeyCode.F,
toggleKey = Enum.KeyCode.B,
holdActive = false,
toggleActive = false,
lastToggleTick = 0,
lastGuardSyncTick = 0,
}

-- auto lock state
local autoLockActive = false
local autoLockInputService = pcall(function() return game:GetService("UserInputService") end) and game:GetService("UserInputService") or nil
local autoLockTargetRoot = nil
local autoLockPreferOffBall = false
local lastAutoLockRefreshTick = 0
local autoLockTargetHistory = {}

-- hook bridges
-- extremely reliable override method, prevents c stack overflow and is virtually indistinguishable from the original function (except for upvalues, but those are not used in the controllers we want to hook)
local function createHookBridge(targetController, controllerName)
	local originalFunctions = {}

	return setmetatable({}, {
	__index = function(_, key)
	return originalFunctions[key]
end,
__newindex = function(self, key, new)
-- determine if key is a valid function of the target controller
local targetFunction = targetController[key]
if type(targetFunction) ~= "function" then
	logger.warn("attempt to hook invalid function '" .. key .. "' on controller '" .. (controllerName) .. "'")
	return
end

if type(new) ~= "function" then
	logger.warn("attempt to set non-function hook for '" .. key .. "' on controller '" .. (controllerName) .. "'")
	return
end

if not originalFunctions[key] then
	originalFunctions[key] = targetFunction
end

local originalFunction = originalFunctions[key]

-- hook the function
local ok, err = pcall(function()
local newFunction = newcclosure(new)
hookfunction(originalFunction, newFunction)
end)

if not ok then
	logger.error("failed to hook function '" .. key .. "' on controller '" .. (controllerName) .. "': " .. tostring(err))
	return
end

rawset(self, key, originalFunction)
logger.info("successfully hooked function '" .. key .. "' on controller '" .. (controllerName) .. "'")
end,
})
end

-- get controller names as table
local controllerNames = {}
for _, controller in ipairs(controllersDir:GetChildren()) do
	if controller:IsA("ModuleScript") then
		table.insert(controllerNames, controller.Name)
	end
end

-- controllers via require() are used for hook bridges (the actual function references to hook)
-- controllers via Knit.GetController() are used internally within overrides (game architecture requires this)
local controllers = {}
local knitControllers = {}
for _, controllerName in ipairs(controllerNames) do
	local ok, controller = pcall(require, controllersDir:WaitForChild(controllerName))
	if ok and controller then
		controllers[controllerName] = controller
		local knitOk, knitController = pcall(knit.GetController, controllerName)
		if knitOk and knitController then
			knitControllers[controllerName] = knitController
		else
			logger.warn("failed to get knit controller '" .. controllerName .. "': " .. tostring(knitController))
		end
	else
		logger.warn("failed to require controller '" .. controllerName .. "': " .. tostring(controller))
	end
end

-- now create hook bridges for each controller and store them in a table for easy access
local hookBridges = {}
for _, controllerName in ipairs(controllerNames) do
	local controller = controllers[controllerName]
	if controller then
		hookBridges[controllerName] = createHookBridge(controller, controllerName)
	else
		logger.warn("cannot create hook bridge for controller '" .. controllerName .. "' because it failed to require")
	end
end

-- bulk override registration helper
local function applyOverrides(controllerName, overrides)
	local bridge = hookBridges[controllerName]
	if not bridge then
		logger.error("no hook bridge for '" .. controllerName .. "'")
		return
	end
	for fnName, fn in pairs(overrides) do
		bridge[fnName] = fn
	end
end

-- startup health summary
local bridgedCount = 0
for _ in pairs(hookBridges) do bridgedCount = bridgedCount + 1 end
local knitServiceCount = 0
for _ in pairs(knitServices) do knitServiceCount = knitServiceCount + 1 end
local knitControllerCount = 0
for _ in pairs(knitControllers) do knitControllerCount = knitControllerCount + 1 end
logger.info(string.format("ready — %d/%d controllers bridged, %d knit controllers, %d knit services | mode: %s",
bridgedCount, #controllerNames, knitControllerCount, knitServiceCount, is5v5 and "5v5" or "mypark"))

---------------------------------------
-- shared state (replaces module-level locals from original controllers)
---------------------------------------
local rigType = sharedUtil.GSettings.RigType
local runService = services.RunService
local starterGui = services.StarterGui
local currentCamera = workspace.CurrentCamera

local lastJumpTick = tick()
local movementStartTick = tick()
local movementActive = false
local loadedAnimations = {}

---------------------------------------
-- data tables
---------------------------------------
local DRIBBLE_END_ANIMATIONS = {
Ball_SpinL2R = true, Ball_SpinR2L = true,
Ball_CrossL = true, Ball_CrossR = true,
Ball_HesiL = true, Ball_HesiR = true,
Ball_BTBL2R = true, Ball_BTBR2L = true,
Ball_StepbackL = true, Ball_StepbackR = true,
}

local SHOT_MARKER_ANIMATIONS = {
Jumpshot = true, Ball_FadeBack = true,
JumpshotRight = true, JumpshotLeft = true,
Ball_FloaterL = true, Ball_FloaterR = true,
Ball_PostHookL = true, Ball_PostHookR = true,
Ball_ReverseLayupL = true, Ball_ReverseLayupR = true,
Ball_ShortLayupL = true, Ball_ShortLayupR = true,
}

local RIG_PARTS = {
R6 = {
Torso = "Torso",
["Right Arm"] = "Right Arm",
["Left Arm"] = "Left Arm",
["Right Leg"] = "Right Leg",
["Left Leg"] = "Left Leg",
},
R15 = {
Torso = "UpperTorso",
RightHand = "RightHand",
LeftHand = "LeftHand",
RLL = "RightLowerArm",
LLL = "LeftLowerArm",
},
}

-- reverse lookup: child instance name -> self.Args key
local rigPartMap = RIG_PARTS[rigType]
local CHILD_TO_ARG = {}
if rigPartMap then
	for argKey, childName in pairs(rigPartMap) do
		CHILD_TO_ARG[childName] = argKey
	end
end

-- direction -> velocity unit vector from a lookAt CFrame
local DIRECTION_VELOCITY = {
Forward         = function(cf) return cf.LookVector end,
ForwardOpposite = function(cf) return -cf.LookVector end,
Right           = function(cf) return cf.RightVector end,
Left            = function(cf) return -cf.RightVector end,
Back            = function(cf) return -cf.LookVector end,
RightForward    = function(cf) return (cf.LookVector + cf.RightVector) / 2 end,
LeftForward     = function(cf) return (cf.LookVector - cf.RightVector) / 2 end,
}

---------------------------------------
-- knit controller / service aliases (used inside overrides)
-- require()'d controllers are for hook bridges only;
-- knit controllers are used for internal calls within overrides
---------------------------------------
local pc = knitControllers["PlayerController"]
local ic = knitControllers["InputController"]
local gc = knitControllers["GameController"]
local dc = knitControllers["DataController"]
local uc = knitControllers["UIController"]
local vc = knitControllers["VisualController"]

local controlService = knitServices["ControlService"]
local playerService = knitServices["PlayerService"]

---------------------------------------
-- helpers
---------------------------------------
local function safeSetCore(coreFunctionName, ...)
	local result = {}
	for _ = 1, 15 do
		result = { pcall(starterGui[coreFunctionName], starterGui, ...) }
		if result[1] then break end
		runService.Stepped:Wait()
	end
	return unpack(result)
end

local function getBaseSpeed()
	return getConfigValue(false, "movement", "speedOverride") and getConfigValue(17, "movement", "speed") or 17
end

local function restoreSpeed(humanoid, gameValues)
	if gameValues and gameValues.Locked then return end
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

local function playersShareTeam(firstPlayer, secondPlayer)
	if not firstPlayer or not secondPlayer then return false end
	if is5v5 then
		return firstPlayer.Team == secondPlayer.Team
	end
	local firstAttr = firstPlayer:GetAttribute("Team")
	local secondAttr = secondPlayer:GetAttribute("Team")
	return firstAttr ~= nil and secondAttr == firstAttr
end

local function localTeamHasPossession(gameValues)
	return gameValues and gameValues.Possession ~= nil and getTeam(localPlayer) == gameValues.Possession
end

local function stopDribbleAnims(fadeTime)
	pc:StopAnimation("Ball_DribbleR", fadeTime)
	pc:StopAnimation("Ball_DribbleL", fadeTime)
end

local function playDribbleAnim(hand, speed, fadeTime)
	if hand == "Right" then
		pc:PlayAnimation("Ball_DribbleR", speed, fadeTime)
	elseif hand == "Left" then
		pc:PlayAnimation("Ball_DribbleL", speed, fadeTime)
	end
end

local function getAutoAnkleBreakerMove()
	local _, ballValues = basketball:GetValues()
	if not ballValues then return nil end
	if ballValues.Hand == "Right" then return "Left" end
	if ballValues.Hand == "Left" then return "Right" end
	return nil
end

local function distanceSquared(a, b)
	local delta = a - b
	return delta:Dot(delta)
end

local function getClosestPlayer(withBall)
	local myCharacter = localPlayer.Character
	local myRoot = myCharacter and myCharacter:FindFirstChild("HumanoidRootPart")
	if not myCharacter or not myRoot then return nil end
	local ignoreChecks = ignoreTeamPossessionChecks()
	local myPos = myRoot.Position

	local bestEnemy, bestEnemyDistSq = nil, math.huge
	local bestAny, bestAnyDistSq = nil, math.huge

	for i = 1, #cachedPlayers do
		local otherPlayer = cachedPlayers[i]
		if otherPlayer ~= localPlayer then
			local otherCharacter = otherPlayer.Character
			local otherRoot = otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart")
			if otherRoot then
				local dSq = distanceSquared(myPos, otherRoot.Position)
				local otherHasBall = otherCharacter:FindFirstChild("Basketball") ~= nil

				local teamsDiffer = ignoreChecks or not playersShareTeam(otherPlayer, localPlayer)

				if not withBall then
					if teamsDiffer and dSq < bestEnemyDistSq then bestEnemyDistSq = dSq; bestEnemy = otherPlayer end
					if dSq < bestAnyDistSq then bestAnyDistSq = dSq; bestAny = otherPlayer end
				else
					if teamsDiffer and otherHasBall and dSq < bestEnemyDistSq then bestEnemyDistSq = dSq; bestEnemy = otherPlayer end
					if otherHasBall and dSq < bestAnyDistSq then bestAnyDistSq = dSq; bestAny = otherPlayer end
				end
			end
		end
	end

	return bestEnemy or bestAny
end

local function onCourtWith(otherPlayer)
	if not otherPlayer then return false end
	local myCourt = localPlayer:GetAttribute("Court")
	local otherCourt = otherPlayer:GetAttribute("Court")
	if myCourt == nil or otherCourt == nil then return true end
	return myCourt == otherCourt
end

local function playersAreOpponents(otherPlayer)
	if not otherPlayer or otherPlayer == localPlayer then return false end
	if ignoreTeamPossessionChecks() then return true end
	return not playersShareTeam(otherPlayer, localPlayer)
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
	local section = getConfigTable(nil, "moves", tag)
	local boost = section and section.boost
	if type(boost) == "number" and boost > 0 then return boost end
	return 1
end

local function getPhysicalBlockboxSize()
	local size = normalizeBlockboxSize(getConfigValue(PHYSICAL_BLOCKBOX_SIZE, "defense", "blockboxSize"))
	return Vector3.new(size, size, size)
end

local function refreshPhysicalBlockbox()
	if pc and pc.Args and pc.Args.Blockbox then
		pc.Args.Blockbox.Size = getPhysicalBlockboxSize()
	end
end

local function getBallMagnetTouchRadius()
	local scale = getConfigValue(50, "ballMagnet", "scale")
	if type(scale) ~= "number" then return 25 end
	return math.max(scale * 0.5, 2)
end

local function getBallMagnetTouchCooldown()
	return math.clamp(getConfigValue(BALL_MAGNET_TOUCH_COOLDOWN, "ballMagnet", "touchCooldown"), 0.01, 1)
end

local function getPassiveStealInterval()
	return math.clamp(getConfigValue(0.3, "moves", "steal", "passiveInterval"), 0.05, 2)
end

local function getPostAssistCooldown()
	return math.clamp(getConfigValue(POST_ASSIST_COOLDOWN, "moves", "post", "assistCooldown"), 0, 5)
end

local function getPostHookCooldown()
	return math.clamp(getConfigValue(POST_HOOK_COOLDOWN, "moves", "post", "hookCooldown"), 0, 5)
end

local function getPostHookTriggerDelay()
	return math.clamp(getConfigValue(0.32, "moves", "post", "hookTriggerDelay"), 0, 1)
end

local function getGuardTargetRefreshInterval()
	return math.clamp(getConfigValue(GUARD_TARGET_REFRESH_INTERVAL, "defense", "guardRefreshInterval"), 0.01, 0.5)
end

local function getGuardTargetSwitchCooldown()
	return math.clamp(getConfigValue(GUARD_TARGET_SWITCH_COOLDOWN, "defense", "guardTargetSwitchCooldown"), 0.05, 1)
end

local function getAutoLockRefreshInterval()
	return math.clamp(getConfigValue(AUTO_LOCK_REFRESH_INTERVAL, "defense", "autoLockRefreshInterval"), 0.01, 0.5)
end

local function getAutoLockLeadDistance()
	return math.clamp(getConfigValue(AUTO_LOCK_LEAD_DISTANCE, "defense", "autoLockLeadDistance"), 0, 15)
end

local function getAutoBlockRange()
	return math.clamp(getConfigValue(25, "defense", "autoBlockRange"), 5, 60)
end

local function getAutoBlockCooldown()
	return math.clamp(getConfigValue(AUTO_BLOCK_COOLDOWN, "defense", "autoBlockCooldown"), 0, 3)
end

local function getAutoBlockTriggerDelay()
	return math.clamp(getConfigValue(0.32, "defense", "autoBlockTriggerDelay"), 0, 1)
end

local function getAutoBlockReleaseDelay()
	return math.clamp(getConfigValue(0.12, "defense", "autoBlockReleaseDelay"), 0, 1)
end

local function getExtremeAutoBlockInterval()
	return math.clamp(getConfigValue(EXTREME_AUTO_BLOCK_INTERVAL, "defense", "extremeAutoBlockInterval"), 0.01, 0.5)
end

local function getBodyGyroTorque()
	return math.clamp(getConfigValue(1000000, "movement", "bodyGyroTorque"), 0, 2000000)
end

local function getBodyVelocityForce()
	return math.clamp(getConfigValue(1000000, "movement", "bodyVelocityForce"), 0, 2000000)
end

local function getTurnUnlockDelay()
	return math.clamp(getConfigValue(0.1, "movement", "turnUnlockDelay"), 0, 1)
end

local function getAutoGuardSpeedFactor()
	return math.clamp(getConfigValue(25, "defense", "autoGuardSpeedFactor"), 1, 60)
end

local function getAutoGuardMinSpeed()
	return math.clamp(getConfigValue(6, "defense", "autoGuardMinSpeed"), 0, 40)
end

local function getAutoGuardMaxSpeed()
	return math.clamp(getConfigValue(32, "defense", "autoGuardMaxSpeed"), 0, 60)
end

local function isAutoGuardRequested()
	return config.defense.autoGuard == true and (guardInputState.holdActive or guardInputState.toggleActive)
end

local function syncDesiredGuardState(shouldGuard, force)
	if not ic or not pc or not pc.Args then return end
	local character = pc.Args.Character
	if not character or not character.Parent then return end
	if shouldGuard and hasBall(character) then return end

	local current = character:GetAttribute("Guarding") == true
	if current == shouldGuard then return end

	local now = tick()
	if not force and now - guardInputState.lastGuardSyncTick < 0.12 then return end
	guardInputState.lastGuardSyncTick = now

	local ok, err = pcall(function()
		ic:Guard(shouldGuard)
	end)
	if not ok then
		logger.debug("guard sync failed", tostring(err))
	end
end

local function clearBodyGyro(args)
	if not args or not args.BodyGyro then return end
	args.BodyGyro.MaxTorque = Vector3.new(0, 0, 0)
	args.BodyGyro.CFrame = CFrame.new(0, 0, 0)
	if debugState.traceBodyMovers then
		logger.debug("clear body gyro")
	end
end

local function setBodyGyroLook(args, lookCFrame)
	if not args or not args.BodyGyro or not lookCFrame then return end
	local torque = getBodyGyroTorque()
	args.BodyGyro.MaxTorque = Vector3.new(0, torque, 0)
	args.BodyGyro.CFrame = lookCFrame
	if debugState.traceBodyMovers then
		logger.debug("set body gyro", tostring(lookCFrame.Position), "torque=", torque)
	end
end

local function clearBodyVelocity(args)
	if not args or not args.BodyVelocity then return end
	args.BodyVelocity.MaxForce = Vector3.new(0, 0, 0)
	args.BodyVelocity.Velocity = Vector3.new(0, 0, 0)
	if debugState.traceBodyMovers then
		logger.debug("clear body velocity")
	end
end

local function setBodyVelocity(args, velocity, planarOnly)
	if not args or not args.BodyVelocity then return end
	local force = getBodyVelocityForce()
	args.BodyVelocity.Velocity = velocity or Vector3.new(0, 0, 0)
	if planarOnly then
		args.BodyVelocity.MaxForce = Vector3.new(force, 0, force)
	else
		args.BodyVelocity.MaxForce = Vector3.new(force, force, force)
	end
	if debugState.traceBodyMovers then
		logger.debug("set body velocity", tostring(args.BodyVelocity.Velocity), "force=", force, "planar=", planarOnly == true)
	end
end

local function resolveGuardTarget(forceRefresh)
	local now = tick()
	if not forceRefresh and now - lastGuardTargetRefreshTick < getGuardTargetRefreshInterval() then
		if cachedGuardBall and cachedGuardBall.Parent and cachedGuardTargetRoot and cachedGuardTargetRoot.Parent then
			return cachedGuardBall, cachedGuardTargetRoot
		end
	end

	lastGuardTargetRefreshTick = now

	local candidateBall = nil
	local candidateRoot = nil
	local ballOwner = getClosestPlayer(true)
	local ballOwnerCharacter = ballOwner and ballOwner.Character
	if ballOwnerCharacter then
		candidateBall = resolveBallAttach(ballOwnerCharacter)
		candidateRoot = ballOwnerCharacter:FindFirstChild("HumanoidRootPart")
	end

	if not (candidateBall and candidateRoot) and is5v5 then
		for _, tagged in pairs(collectionService:GetTagged("Ball")) do
			if tagged.Name == "Attach" and tagged.Parent and tagged.Parent:IsA("Tool") then
				local owner = tagged.Parent.Parent
				local root = owner and owner:FindFirstChild("HumanoidRootPart")
				if root then
					candidateBall = tagged
					candidateRoot = root
					break
				end
			end
		end
	elseif not (candidateBall and candidateRoot) then
		local closestBall = sharedUtil.Ball:GetClosestBall(localPlayer)
		if closestBall and closestBall.Name == "Attach" and closestBall.Parent and closestBall.Parent:IsA("Tool") then
			candidateBall = closestBall
			candidateRoot = closestBall.Parent.Parent and closestBall.Parent.Parent:FindFirstChild("HumanoidRootPart") or nil
		end
	end

	if not (candidateBall and candidateRoot) then
		cachedGuardBall = nil
		cachedGuardTargetRoot = nil
		return nil, nil
	end

	if cachedGuardTargetRoot and cachedGuardTargetRoot.Parent and cachedGuardBall and cachedGuardBall.Parent then
		local switchingTargets = cachedGuardTargetRoot ~= candidateRoot or cachedGuardBall ~= candidateBall
		if switchingTargets and now - lastGuardTargetSwitchTick < getGuardTargetSwitchCooldown() then
			return cachedGuardBall, cachedGuardTargetRoot
		end
		if switchingTargets then
			lastGuardTargetSwitchTick = now
		end
	else
		lastGuardTargetSwitchTick = now
	end

	cachedGuardBall = candidateBall
	cachedGuardTargetRoot = candidateRoot
	return cachedGuardBall, cachedGuardTargetRoot
end

local function findAutoLockTarget(preferOffBall)
	local myCharacter = localPlayer.Character
	local myRoot = myCharacter and myCharacter:FindFirstChild("HumanoidRootPart")
	if not myRoot then return nil end

	local bestPreferredPlayer, bestPreferredDistSq = nil, math.huge
	local bestFallbackPlayer, bestFallbackDistSq = nil, math.huge
	for i = 1, #cachedPlayers do
		local otherPlayer = cachedPlayers[i]
		if otherPlayer ~= localPlayer and playersAreOpponents(otherPlayer) and onCourtWith(otherPlayer) then
			local otherCharacter = otherPlayer.Character
			local otherRoot = otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart")
			if otherRoot then
				local otherHasBall = hasBall(otherCharacter)
				local distSq = distanceSquared(myRoot.Position, otherRoot.Position)
				local prefersThisTarget = (preferOffBall and not otherHasBall) or (not preferOffBall and otherHasBall)
				if prefersThisTarget then
					if distSq < bestPreferredDistSq then
						bestPreferredDistSq = distSq
						bestPreferredPlayer = otherPlayer
					end
				elseif distSq < bestFallbackDistSq then
					bestFallbackDistSq = distSq
					bestFallbackPlayer = otherPlayer
				end
			end
		end
	end

	local targetPlayer = bestPreferredPlayer or bestFallbackPlayer
	return targetPlayer and targetPlayer.Character and targetPlayer.Character:FindFirstChild("HumanoidRootPart") or nil
end

local function getAutoLockLookPosition(targetRoot)
	if not targetRoot then return nil end
	local now = tick()
	local forward = Vector3.new(targetRoot.CFrame.LookVector.X, 0, targetRoot.CFrame.LookVector.Z)
	local lastSample = autoLockTargetHistory[targetRoot]
	if lastSample then
		local dt = math.max(now - lastSample.tick, 1 / 240)
		local velocity = (targetRoot.Position - lastSample.position) / dt
		local planarVelocity = Vector3.new(velocity.X, 0, velocity.Z)
		if planarVelocity.Magnitude > 0.05 then
			local baseForward = forward.Magnitude > 0 and forward.Unit or Vector3.new(0, 0, -1)
			local blended = planarVelocity.Unit * 0.7 + baseForward * 0.3
			if blended.Magnitude > 0 then
				forward = blended.Unit
			end
		elseif forward.Magnitude > 0 then
			forward = forward.Unit
		end
	elseif forward.Magnitude > 0 then
		forward = forward.Unit
	end
	autoLockTargetHistory[targetRoot] = {
		position = targetRoot.Position,
		tick = now,
	}
	local leadDistance = getAutoLockLeadDistance()
	return Vector3.new(
	targetRoot.Position.X + forward.X * leadDistance,
	targetRoot.Position.Y,
	targetRoot.Position.Z + forward.Z * leadDistance
	)
end

local function abilityUnlocked(abilityName)
	if config.abilities.unlockAllMoves then return true end
	return dc and dc.Data and dc.Data.Abilities and dc.Data.Abilities[abilityName]
end

local function isBenched()
	return is5v5 and localPlayer:GetAttribute("Benched") ~= nil
end

-- utility: compare Vector3 approximately
local function vector3Close(a, b, epsilon)
	local delta = a - b
	return delta.Magnitude <= (epsilon or 0.001)
end

-- utility: clear table (supports table.clear or fallback)
local function clearTable(tbl)
	if not tbl then return end
	if table.clear then
		table.clear(tbl)
	else
		for key in pairs(tbl) do tbl[key] = nil end
	end
end

-- utility: opposite hand
local function getOppositeHand(hand)
	if hand == "Right" then return "Left"
elseif hand == "Left" then return "Right"
end
return "Right"
end

-- timeout-guarded wait for ic.Args flag (prevents infinite stalls)
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

-- walk speed setter that respects speedOverride
local function setWalkSpeedSafely(humanoid, speed)
	if config.movement.speedOverride then
		humanoid.WalkSpeed = config.movement.speed
	else
		humanoid.WalkSpeed = speed
	end
end

---------------------------------------
-- post hand scale system
---------------------------------------
local setPostHandScale, resetPostHandScale, resetAllPostHandScale, updateActivePostHandScale

local function getPostHandPart(args, hand)
	if not args then return nil end
	if rigType == "R6" then
		if hand == "Right" then return args["Right Arm"]
	elseif hand == "Left" then return args["Left Arm"]
	end
else
	if hand == "Right" then return args.RightHand
elseif hand == "Left" then return args.LeftHand
end
end
return nil
end

setPostHandScale = function(args, hand, scale)
if not args or type(scale) ~= "number" then return end
local part = getPostHandPart(args, hand)
if not (part and part:IsA("BasePart")) then return end

args._postHandOriginals = args._postHandOriginals or {}
local originals = args._postHandOriginals
local originalSize = originals[part]
if not originalSize then
	originalSize = part.Size
	originals[part] = originalSize
end

local clampScale = math.clamp(scale, 0.5, 3)
if clampScale <= 1.01 then
	if not vector3Close(part.Size, originalSize, 0.001) then
		part.Size = originalSize
	end
	return
end

local base = originalSize
local newSize = Vector3.new(base.X * clampScale, base.Y, base.Z * clampScale)
if not vector3Close(part.Size, newSize, 0.001) then
	part.Size = newSize
end
end

resetPostHandScale = function(args, hand)
if not args then return end
local part = getPostHandPart(args, hand)
local originals = args._postHandOriginals
if part and originals and originals[part] then
	local base = originals[part]
	if not vector3Close(part.Size, base, 0.001) then
		part.Size = base
	end
end
end

resetAllPostHandScale = function(args)
if not args then return end
resetPostHandScale(args, "Right")
resetPostHandScale(args, "Left")
end

updateActivePostHandScale = function()
local pcArgs = pc and pc.Args
if not pcArgs then return end
local postConfig = config.moves.post
local scale = postConfig and postConfig.handScale or 1
if ic and ic.Args and ic.Args.Posting then
	local targetHand = getOppositeHand(ic.Args.PostDirection or "Right")
	setPostHandScale(pcArgs, targetHand, scale)
else
	resetAllPostHandScale(pcArgs)
end
end

local function enterPostState(ballHand)
	local handScale = config.moves.post.handScale or 1
	local targetHand = getOppositeHand(ballHand)
	setPostHandScale(pc.Args, targetHand, handScale)
	setBodyGyroLook(pc.Args, pc.Args.BodyGyro.CFrame)
	stopDribbleAnims(0.2)

	if ballHand == "Right" then
		pc:PlayAnimation("Ball_PostDribbleR", 1, 0.2)
	elseif ballHand == "Left" then
		pc:PlayAnimation("Ball_PostDribbleL", 1, 0.2)
	end

	lockAction({ walkSpeed = 14, autoRotate = false })
end

local function exitPostState(ballHand)
	resetAllPostHandScale(pc.Args)
	clearBodyGyro(pc.Args)
	pc:StopAnimation("Ball_PostDribbleR")
	pc:StopAnimation("Ball_PostDribbleL")
	playDribbleAnim(ballHand)
end

---------------------------------------
-- ball magnet system
---------------------------------------

-- Resolves a basketball instance to its trackable BasePart.
-- Handles both direct BaseParts named "Basketball" and Tool containers.
-- Returns (basePart) or (nil).
local function resolveBasketballPart(inst)
	if not inst then return nil end
	if inst:IsA("BasePart") and inst.Name == "Basketball" then
		return inst
	end
	if inst:IsA("Tool") and inst.Name == "Basketball" then
		return inst:FindFirstChild("Handle") or inst:FindFirstChildWhichIsA("BasePart")
	end
	return nil
end

-- Check if an instance is inside any player's character (not just local player)
local function isInsideAnyCharacter(inst)
	for i = 1, #cachedPlayers do
		local char = cachedPlayers[i] and cachedPlayers[i].Character
		if char and inst:IsDescendantOf(char) then return true end
	end
	return false
end

local function cleanupBallMagnetForPart(part, restoreOriginal)
	if not part then return end
	local connectionBucket = ballMagnetState.partConnections[part]
	if connectionBucket then
		for _, conn in ipairs(connectionBucket) do conn:Disconnect() end
		ballMagnetState.partConnections[part] = nil
	end
	if restoreOriginal then
		local original = ballMagnetState.originals[part]
		if original and part.Parent then
			part.Size = original.size
			part.Anchored = original.anchored
		end
	end
	ballMagnetState.originals[part] = nil
	ballMagnetState.tracked[part] = nil
	ballMagnetState.touchCooldowns[part] = nil
end

local function applyBallMagnet(part)
	if not ballMagnetState.enabled then return end
	if not part or not part:IsA("BasePart") then return end
	if isInsideAnyCharacter(part) then return end

	-- If this part was previously tracked and cleaned up, refresh its original snapshot
	if not ballMagnetState.tracked[part] and ballMagnetState.originals[part] then
		ballMagnetState.originals[part] = nil
	end

	if not ballMagnetState.originals[part] then
		ballMagnetState.originals[part] = {
		size = part.Size,
		anchored = part.Anchored,
		}
	end

	local original = ballMagnetState.originals[part]
	local targetSize = original.size
	if config.ballMagnet.resizeEnabled ~= false then
		local scaleCfg = config.ballMagnet.scale or 50
		local scaleFactor = math.clamp(scaleCfg / 50, 0.6, 2.5)
		targetSize = original.size * scaleFactor
	end
	if not vector3Close(part.Size, targetSize, 0.01) then
		part.Size = targetSize
	end

	ballMagnetState.tracked[part] = true

	if not ballMagnetState.partConnections[part] then
		ballMagnetState.partConnections[part] = {
		part.AncestryChanged:Connect(function(_, parent)
		if not parent then
			cleanupBallMagnetForPart(part, false)
		elseif isInsideAnyCharacter(part) then
			cleanupBallMagnetForPart(part, true)
		end
	end),
	}
end
end

local function enableBallMagnetWatchers()
	if ballMagnetState.watchers.child then return end
	local function handleInstance(inst)
		if not ballMagnetState.enabled then return end
		local bpart = resolveBasketballPart(inst)
		if bpart then applyBallMagnet(bpart) end
	end
	ballMagnetState.watchers.child = workspace.ChildAdded:Connect(handleInstance)
	ballMagnetState.watchers.desc = workspace.DescendantAdded:Connect(handleInstance)
end

local function disableBallMagnetWatchers()
	for key, conn in pairs(ballMagnetState.watchers) do
		conn:Disconnect()
		ballMagnetState.watchers[key] = nil
	end
end

-- Find the best part to fire touch against (prefer TouchInterest child)
local function resolveTouchTarget(part)
	local ti = part:FindFirstChildWhichIsA("TouchTransmitter") or part:FindFirstChild("TouchInterest")
	if ti then
		return part -- firetouchinterest uses the part that owns the TouchInterest
	end
	-- Check parent Tool for Handle with TouchInterest
	local parentTool = part.Parent
	if parentTool and parentTool:IsA("Tool") then
		local handle = parentTool:FindFirstChild("Handle")
		if handle and handle:FindFirstChildWhichIsA("TouchTransmitter") then
			return handle
		end
	end
	return part -- fallback to the part itself
end

local function startBallMagnetHeartbeat()
	if ballMagnetState.heartbeat then return end
	ballMagnetState.heartbeat = runService.Heartbeat:Connect(function()
	if not ballMagnetState.enabled then return end
	local pcArgs = pc and pc.Args
	local root = pcArgs and pcArgs.HumanoidRootPart
	local rightHand = pcArgs and (pcArgs.RightHand or pcArgs["Right Arm"])
	if not root then return end

	local range = config.ballMagnet.range or 20
	local rangeSq = range * range
	local nowTick = tick()

	for part in pairs(ballMagnetState.tracked) do
		if part and part.Parent then
			if isInsideAnyCharacter(part) then
				cleanupBallMagnetForPart(part, true)
			else
				local distSq = distanceSquared(part.Position, root.Position)
				if distSq <= rangeSq then
					local lastTouch = ballMagnetState.touchCooldowns[part] or 0
					if nowTick - lastTouch >= getBallMagnetTouchCooldown() then
						ballMagnetState.touchCooldowns[part] = nowTick
						if fireTouch and config.ballMagnet.directTouchEnabled ~= false then
							local touchPart = resolveTouchTarget(part)
							pcall(fireTouch, root, touchPart, 0)
							pcall(fireTouch, root, touchPart, 1)
							if rightHand and rightHand.Parent then
								pcall(fireTouch, rightHand, touchPart, 0)
								pcall(fireTouch, rightHand, touchPart, 1)
							end
						end
					end
				end
			end
		end
	end
end
end)
end

local function stopBallMagnetHeartbeat()
	if ballMagnetState.heartbeat then
		ballMagnetState.heartbeat:Disconnect()
		ballMagnetState.heartbeat = nil
	end
end

local function refreshBallMagnet()
	if not ballMagnetState.enabled then return end
	for part in pairs(ballMagnetState.tracked) do
		if part and part.Parent then applyBallMagnet(part) end
	end
	for _, inst in ipairs(workspace:GetDescendants()) do
		local bpart = resolveBasketballPart(inst)
		if bpart then applyBallMagnet(bpart) end
	end
end

local function setBallMagnet(enabled, skipSave)
	local shouldEnable = enabled == true
	config.ballMagnet.enabled = shouldEnable
	if skipSave ~= true then scheduleConfigSave() end

	if shouldEnable then
		if ballMagnetState.enabled then
			refreshBallMagnet()
			return
		end
		ballMagnetState.enabled = true
		if not fireTouch and config.ballMagnet.directTouchEnabled ~= false then
			logger.warn("ball magnet direct touch unavailable: firetouchinterest missing")
		end
		enableBallMagnetWatchers()
		for _, child in ipairs(workspace:GetDescendants()) do
			local bpart = resolveBasketballPart(child)
			if bpart then applyBallMagnet(bpart) end
		end
		startBallMagnetHeartbeat()
	else
		if not ballMagnetState.enabled then return end
		ballMagnetState.enabled = false
		stopBallMagnetHeartbeat()
		disableBallMagnetWatchers()

		local restoreList = {}
		for part in pairs(ballMagnetState.tracked) do
			restoreList[#restoreList + 1] = part
		end
		for _, part in ipairs(restoreList) do
			cleanupBallMagnetForPart(part, true)
		end

		clearTable(ballMagnetState.tracked)
		clearTable(ballMagnetState.originals)
		clearTable(ballMagnetState.partConnections)
		clearTable(ballMagnetState.touchCooldowns)
	end
end

---------------------------------------
-- passive steal system
---------------------------------------
local function startPassiveStealLoop(runId)
	passiveStealThread = task.spawn(function()
	while passiveStealEnabled and passiveStealRunId == runId do
		if ic and ic.Args then
			local ok, err = pcall(function() ic:Steal() end)
			if not ok then logger.warn("passive steal failed: " .. tostring(err)) end
		end
		task.wait(getPassiveStealInterval())
	end
	if passiveStealRunId == runId then
		passiveStealThread = nil
	end
end)
end

local function setPassiveSteal(enabled, skipSave)
	local shouldEnable = enabled == true
	config.moves.steal.passiveSteal = shouldEnable
	if skipSave ~= true then scheduleConfigSave() end

	if shouldEnable then
		if passiveStealEnabled and passiveStealThread then return end
		passiveStealEnabled = true
		passiveStealRunId = passiveStealRunId + 1
		startPassiveStealLoop(passiveStealRunId)
		return
	end

	passiveStealEnabled = false
	passiveStealRunId = passiveStealRunId + 1
	passiveStealThread = nil
end

-- initialize cached players
populateCachedPlayers()
playersService.PlayerAdded:Connect(addCachedPlayer)
playersService.PlayerRemoving:Connect(removeCachedPlayer)

---------------------------------------
-- action primitives
---------------------------------------
local function lockAction(opts)
	local icArgs = ic and ic.Args
	local pcArgs = pc and pc.Args
	if icArgs then
		if opts.canShoot ~= nil then icArgs.CanShoot = opts.canShoot end
		if opts.canDribble ~= nil then icArgs.CanDribble = opts.canDribble end
		if opts.inAction ~= nil then icArgs.InAction = opts.inAction end
	end
	if pcArgs and pcArgs.Humanoid then
		if opts.walkSpeed ~= nil then pcArgs.Humanoid.WalkSpeed = opts.walkSpeed end
		if opts.autoRotate ~= nil then pcArgs.Humanoid.AutoRotate = opts.autoRotate end
	end
end

local function unlockAction(gameValues)
	if pc then pc:StopMovement() end
	local pcArgs = pc and pc.Args
	if pcArgs and pcArgs.Humanoid then
		pcArgs.Humanoid.AutoRotate = true
		restoreSpeed(pcArgs.Humanoid, gameValues)
	end
end

local function applyCooldown(key, duration)
	if not ic or not ic.Args then return end
	ic.Args[key] = true
	if duration and duration > 0 then
		task.delay(duration, function()
		if ic and ic.Args then ic.Args[key] = false end
	end)
else
	ic.Args[key] = false
end
end

local function checkRange(rootPos, goalPos, min, max, unlockFlag)
	local dist = sharedUtil.Math:XYMagnitude(rootPos, goalPos)
	if unlockFlag then return true, dist end
	return dist >= (min or 0) and dist <= (max or math.huge), dist
end



---------------------------------------
-- playerController overrides
---------------------------------------
local pcOverrides = {}

pcOverrides.CharacterAdded = function(self, character)
currentCamera = workspace.CurrentCamera
self.Args.Setup = false
self.Args.toolEquipped = false
self.Args.Moved = false
if not is5v5 then self.Args.SpawnTick = tick() end
self.Args.EmoteSpeed = 8
movementActive = false

for _, connection in pairs(self.Connections) do
	connection:Disconnect()
end
self.Connections = {}
loadedAnimations = {}

-- character references
self.Args.Character = character
self.Args.Humanoid = character:WaitForChild("Humanoid")
self.Args.HumanoidRootPart = character:WaitForChild("HumanoidRootPart")

-- rig-specific body part references (data-driven)
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

---------------------------------------
-- connections
---------------------------------------
self.Connections.Death = self.Args.Humanoid.Died:Connect(function()
if not is5v5 then self:CancelEmote() end
end)

self.Connections.Child = self.Args.Character.ChildAdded:Connect(function(child)
if child:IsA("BasePart") then
	if child.Name == "Head" then
		self.Args.Head = child
	end
	local argKey = CHILD_TO_ARG[child.Name]
	if argKey then
		self.Args[argKey] = child
	end
	return
end
if child:IsA("Tool") then
	self.Args.toolEquipped = true
	return
end
-- note: original BodyGyro/HopperBin anti-cheat checks removed (Fix hook covers legacy connections)
end)

self.Connections.MovingChange = self.Args.Humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(function()
if not is5v5 then
	if dc.Data and dc.Data.AFKBenchmark ~= false then
		playerService.AFKToggle:Fire(false)
	end
end
if self.Args.Moved == false then
	self.Args.Moved = true
end
if not is5v5 then
	if self.Args.Emoting == true and self.Args.Humanoid.MoveDirection.Magnitude > 0 and self.Args.Humanoid.WalkSpeed > 0 then
		controlService.StopEmote:Fire()
	end
end
end)

-- note: original WalkSpeed/JumpPower monitors that called Fix() are removed (Fix hook covers legacy connections)

self.Connections.ToolUnequip = self.Args.Character.ChildRemoved:Connect(function(child)
if child:IsA("Tool") then
	self.Args.toolEquipped = false
end
end)

self.Connections.HeartbeatLoop = runService.RenderStepped:Connect(function()
local guardRequested = isAutoGuardRequested()
local characterGuarding = self.Args.Character:GetAttribute("Guarding") == true
if characterGuarding or guardRequested then
	local closestBall, guardTargetRoot = resolveGuardTarget(false)

	if closestBall and guardTargetRoot then
		local rootPosition = self.Args.HumanoidRootPart.Position
		setBodyGyroLook(self.Args, CFrame.lookAt(rootPosition, Vector3.new(guardTargetRoot.Position.X, rootPosition.Y, guardTargetRoot.Position.Z)))

		-- auto guard positioning: drive between ball carrier and goal
		if config.defense.autoGuard then
			local goalPart = sharedUtil.Ball:GetGoal(localPlayer)
			local guardPoint = nil

			if goalPart then
				local toGoal = Vector3.new(goalPart.Position.X - closestBall.Position.X, 0, goalPart.Position.Z - closestBall.Position.Z)
				local goalDist = toGoal.Magnitude
				if goalDist > 0.1 then
					local offset = math.clamp(goalDist - 1, 1, 4)
					guardPoint = closestBall.Position + toGoal.Unit * offset
				end
			end

			if not guardPoint then
				local ownerLook = guardTargetRoot.CFrame.LookVector
				guardPoint = closestBall.Position + Vector3.new(ownerLook.X, 0, ownerLook.Z) * 3
			end

			guardPoint = Vector3.new(guardPoint.X, rootPosition.Y, guardPoint.Z)
			local toTarget = Vector3.new(guardPoint.X - rootPosition.X, 0, guardPoint.Z - rootPosition.Z)
			local planarMag = toTarget.Magnitude
			autoGuardDriving = true

			if planarMag > 0.05 then
				local minSpeed = getAutoGuardMinSpeed()
				local maxSpeed = math.max(minSpeed, getAutoGuardMaxSpeed())
				local distanceScale = math.clamp(planarMag / 3, 0.35, 1)
				local guardSpeed = math.clamp(minSpeed + (planarMag * getAutoGuardSpeedFactor() * distanceScale), minSpeed, maxSpeed)
				setBodyVelocity(self.Args, toTarget.Unit * guardSpeed, true)
			else
				clearBodyVelocity(self.Args)
			end
		elseif autoGuardDriving then
			autoGuardDriving = false
			clearBodyVelocity(self.Args)
		end
	elseif autoGuardDriving then
		autoGuardDriving = false
		clearBodyVelocity(self.Args)
	end
else
	if autoGuardDriving then
		autoGuardDriving = false
		clearBodyVelocity(self.Args)
	end
	ic:HandleDribbleCheck()

	local postGoal = ic.Args.Posting == true and sharedUtil.Ball:GetGoal(localPlayer)
	if postGoal then
		local rotationOffset = ic.Args.PostDirection == "Right" and CFrame.Angles(0, -math.pi / 2, 0) or CFrame.Angles(0, math.pi / 2, 0)
		local rootPosition = self.Args.HumanoidRootPart.Position
		local postCfg = config.moves.post
		local opponentPlayer = getClosestPlayer(false)
		local opponentRoot = opponentPlayer and opponentPlayer.Character and opponentPlayer.Character:FindFirstChild("HumanoidRootPart")
		local postLookTarget = postGoal
		if postCfg.faceDefender and opponentRoot and (rootPosition - opponentRoot.Position).Magnitude <= math.max(postCfg.dropstepRange or 7, 14) then
			postLookTarget = opponentRoot
		end
		setBodyGyroLook(self.Args, CFrame.lookAt(rootPosition, Vector3.new(postLookTarget.Position.X, rootPosition.Y, postLookTarget.Position.Z)) * rotationOffset)

		if sharedUtil.Math:XYMagnitude(self.Args.HumanoidRootPart.Position, postGoal.Position) > 38 and not config.moves.post.unlockRange then
			ic:Post(false)
		end

		-- post hand scale
		local handScale = postCfg.handScale or 1
		local targetHand = getOppositeHand(ic.Args.PostDirection or "Right")
		setPostHandScale(self.Args, targetHand, handScale)

		-- auto dropstep
		local root = self.Args.HumanoidRootPart
		local now = tick()
		local rangeUnlocked = postCfg.unlockRange == true

		if postCfg.autoDropstep and opponentRoot and ic.Args.CanDribble ~= false and ic.Args.InAction ~= true then
			local planarVector = Vector3.new(opponentRoot.Position.X - root.Position.X, 0, opponentRoot.Position.Z - root.Position.Z)
			local planarDistance = planarVector.Magnitude
			local dropRange = postCfg.dropstepRange or 7
			if (rangeUnlocked or planarDistance <= dropRange) and planarDistance > 0.1 then
				local forwardDot = root.CFrame.LookVector:Dot(planarVector.Unit)
				if forwardDot > -0.7 and now - lastPostAssistTick >= getPostAssistCooldown() then
					lastPostAssistTick = now
					local relative = root.CFrame:PointToObjectSpace(opponentRoot.Position)
					local spin = (relative.X >= 0) and "SpinLeft" or "SpinRight"
					task.spawn(function()
					if ic then ic:Dribble(spin) end
				end)
			end
		end
	end

	-- auto hook (standalone — fires independently of dropstep)
	if postCfg.autoHook and postGoal and ic.Args.CanShoot ~= false and ic.Args.Holding ~= true and ic.Args.InAction ~= true then
		local hookHolder = self.Args.Character and self.Args.Character:FindFirstChild("Basketball")
		if hookHolder and now - lastAutoHookTick >= getPostHookCooldown() then
			local goalDistance = sharedUtil.Math:XYMagnitude(root.Position, postGoal.Position)
			local hookRange = postCfg.hookRange or 8.5
			if rangeUnlocked or goalDistance <= hookRange then
				lastAutoHookTick = now
				local shotSpeedConfig = config.moves.jumpshot.shotSpeed or 1.25
				local releaseDelay = math.clamp(0.35 / math.max(shotSpeedConfig, 0.1), 0.05, 0.45)
				task.delay(getPostHookTriggerDelay(), function()
				if not (self.Args and self.Args.Character and self.Args.Character:FindFirstChild("Basketball")) then return end
				if not ic then return end
				if ic.Args then
					ic.Args.CanShoot = true
					ic.Args.Holding = false
				end
				ic:Shoot(true)
				task.delay(releaseDelay, function()
				if ic then ic:Shoot(false) end
			end)
		end)
	end
end
end
else
	-- not posting, reset hand scale
	resetAllPostHandScale(self.Args)
end
end

-- movement timeout safety
local movementTimeout = is5v5 and 3.5 or 3
if tick() - movementStartTick > movementTimeout and movementActive then
	self:StopMovement()
	if not is5v5 and self.Args.Humanoid.WalkSpeed == 0 then
		self.Args.Humanoid.WalkSpeed = getBaseSpeed()
	end
end
end)

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

local sourcePlayer = playersService:GetPlayerFromCharacter(hit.Parent)
local isEnemy = sourcePlayer and (ignoreTeamPossessionChecks() or not playersShareTeam(sourcePlayer, localPlayer)) or false

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
	self.Args.Humanoid.Jump = false
	return
end
lastJumpTick = tick()
end)

if is5v5 then
	self.Connections.BenchAnim = localPlayer:GetAttributeChangedSignal("Benched"):Connect(function()
	if localPlayer:GetAttribute("Benched") == nil then
		self:StopAnimation("Bench")
		self.Args.HumanoidRootPart.Anchored = false
	else
		self:PlayAnimation("Bench")
	end
end)
end

self.Connections.GuardAnim = self.Args.Character:GetAttributeChangedSignal("Guarding"):Connect(function()
if self.Args.Character:GetAttribute("Guarding") == true then
	self:PlayAnimation("Guard")
	setBodyGyroLook(self.Args, self.Args.BodyGyro.CFrame)
else
	self:StopAnimation("Guard")
	clearBodyGyro(self.Args)
end
end)

self.Connections.ScreenAnim = self.Args.Character:GetAttributeChangedSignal("Screening"):Connect(function()
if self.Args.Character:GetAttribute("Screening") == true then
	self:PlayAnimation("Screen")
	self.Args.Humanoid.WalkSpeed = 0
else
	self:StopAnimation("Screen")
	self.Args.Humanoid.WalkSpeed = getBaseSpeed()
end
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
	else
		self.Args.Humanoid.WalkSpeed = 0
	end
end)
end

---------------------------------------
-- animation loading + marker connections
---------------------------------------
local animationFolder = replicatedStorage.Assets["Animations_" .. rigType]

for index, animationObject in pairs(animationFolder:GetChildren()) do
	loadedAnimations[animationObject.Name] = self.Args.Humanoid:LoadAnimation(animationObject)

	if SHOT_MARKER_ANIMATIONS[animationObject.Name] then
		self.Connections["JumpMarker" .. index] = loadedAnimations[animationObject.Name]:GetMarkerReachedSignal("Jump"):Connect(function()
		ic.Args.Jumped = true
	end)
	self.Connections["ReleaseMarker" .. index] = loadedAnimations[animationObject.Name]:GetMarkerReachedSignal("Release"):Connect(function()
	ic.Args.Released = true
	ic:Shoot(false)
end)
self.Connections["LandMarker" .. index] = loadedAnimations[animationObject.Name]:GetMarkerReachedSignal("Land"):Connect(function()
ic.Args.Landed = true
end)
elseif animationObject.Name == "Ball_LayupL" or animationObject.Name == "Ball_LayupR" then
	self.Connections["ReleaseMarker" .. index] = loadedAnimations[animationObject.Name]:GetMarkerReachedSignal("Released"):Connect(function()
	ic.Args.Released = true
	ic:Shoot(false)
end)
elseif DRIBBLE_END_ANIMATIONS[animationObject.Name] then
	self.Connections["EndMarker" .. index] = loadedAnimations[animationObject.Name].Stopped:Connect(function()
	ic.Args.Ended = true
end)
end

if string.sub(animationObject.Name, 1, 6) == "Dance_" then
	self.Connections[animationObject.Name .. "Stop"] = loadedAnimations[animationObject.Name].Stopped:Connect(function()
	local danceExtraName = "DanceExtra_" .. string.sub(animationObject.Name, 7)
	if animationFolder:FindFirstChild(danceExtraName) then
		self:StopAnimation(danceExtraName)
	end
	if workspace.CurrentCamera.CameraSubject == self.Args.Head then
		self:FixCamera()
	end
	if self.Args.Humanoid.WalkSpeed == self.Args.EmoteSpeed then
		if is5v5 then
			self.Args.Humanoid.WalkSpeed = getBaseSpeed()
		else
			if gc.GameValues and gc.GameValues.Locked then
				self.Args.Humanoid.WalkSpeed = 0
			else
				self.Args.Humanoid.WalkSpeed = localPlayer:GetAttribute("Queue") and 0 or getBaseSpeed()
			end
		end
	end
	if not is5v5 then
		controlService.StopEmote:Fire()
		ic.Args.StopEmoteTick = tick()
	end
end)
end
end

---------------------------------------
-- final setup
---------------------------------------
if gc.GameValues and gc.GameValues.Phase == "Tipoff" then
	self.Args.Humanoid.WalkSpeed = 0
	self:PlayAnimation("Tip_Stand")
end

self.Args.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, false)
self.Args.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)

if not is5v5 then
	if uc.FullyLoaded == true and uc.UIs.Courts ~= nil then
		uc.UIs.Courts:CourtMode(false)
	end

	if localPlayer:GetAttribute("Queue") ~= nil then
		self.Args.Humanoid.WalkSpeed = 0
	end
end

self.Args.Setup = true

if config.movement.hideCoreGui ~= false then
	local okBackpack, backpackErr = safeSetCore("SetCoreGuiEnabled", Enum.CoreGuiType.Backpack, false)
	if not okBackpack then
		logger.warn("failed to set Backpack CoreGui state: " .. tostring(backpackErr))
	end

	local okPlayerList, playerListErr = safeSetCore("SetCoreGuiEnabled", Enum.CoreGuiType.PlayerList, false)
	if not okPlayerList then
		logger.warn("failed to set PlayerList CoreGui state: " .. tostring(playerListErr))
	end
end

logger.info("character initialized")
end

pcOverrides.Fix = function(self, reasonCode)
logger.warn("Fix(" .. tostring(reasonCode) .. ") intercepted and neutralized")
end

pcOverrides.PlayAnimation = function(self, animationName, speed, fadeTime, weight, forceReplay)
local animationTrack = loadedAnimations[animationName]

if not animationTrack then
	local animationObject = replicatedStorage.Assets["Animations_" .. rigType]:FindFirstChild(animationName)
	if animationObject then
		animationTrack = self.Args.Humanoid:LoadAnimation(animationObject)
		loadedAnimations[animationName] = animationTrack
	end
end

if animationTrack then
	if not forceReplay and animationTrack.IsPlaying then return end
	animationTrack:Play(fadeTime or 0.1, weight or 1, speed or 1)

	-- EmoteCancelLink: auto-fire StopEmote when non-looped emote ends
	if animationTrack.Looped == false and animationName == self.Args.LastEmote then
		if self.Connections.EmoteCancelLink then
			self.Connections.EmoteCancelLink:Disconnect()
		end
		self.Connections.EmoteCancelLink = animationTrack.Ended:Connect(function()
		if self.Connections.EmoteCancelLink then
			self.Connections.EmoteCancelLink:Disconnect()
			self.Connections.EmoteCancelLink = nil
		end
		controlService.StopEmote:Fire()
	end)
end
end
end

pcOverrides.StopAnimation = function(self, animationName, fadeTime)
if loadedAnimations[animationName] and loadedAnimations[animationName].IsPlaying then
	loadedAnimations[animationName]:Stop(fadeTime or 0.1)
end
end

pcOverrides.IsAnimationLooped = function(self, animationName)
return loadedAnimations[animationName] and loadedAnimations[animationName].Looped or false
end

pcOverrides.IsAnimationPlaying = function(self, animationName)
return loadedAnimations[animationName] and loadedAnimations[animationName].IsPlaying or false
end

pcOverrides.CreateM6D = function(self, part)
self.Args.HumanoidRootPart.Ball.Part0 = self.Args.HumanoidRootPart
self.Args.HumanoidRootPart.Ball.Part1 = part
end

pcOverrides.StartMovement = function(self, direction, force, target, temporaryTurnUnlock, moveTag)
local movementTarget = target or sharedUtil.Ball:GetGoal(localPlayer)
if not movementTarget then return end

local boost = getMoveBoost(moveTag)
local boostedForce = force * boost

local rootPosition = self.Args.HumanoidRootPart.Position
local lookTarget = typeof(movementTarget) == "Vector3"
and Vector3.new(movementTarget.X, rootPosition.Y, movementTarget.Z)
or Vector3.new(movementTarget.Position.X, rootPosition.Y, movementTarget.Position.Z)

local lookCFrame = CFrame.lookAt(rootPosition, lookTarget)

setBodyGyroLook(self.Args, lookCFrame)
setBodyVelocity(self.Args, Vector3.new(0, 0, 0), false)

if debugState.traceBodyMovers then
	logger.debug("start movement", tostring(direction), "force=", boostedForce, "tag=", tostring(moveTag))
end

local dirFn = DIRECTION_VELOCITY[direction]
if dirFn then
	self.Args.BodyVelocity.Velocity = dirFn(lookCFrame) * boostedForce
end

if direction == "ForwardOpposite" then
	setBodyGyroLook(self.Args, lookCFrame * CFrame.Angles(0, math.pi, 0))
end

if temporaryTurnUnlock then
	task.delay(getTurnUnlockDelay(), function()
	clearBodyGyro(self.Args)
end)
end

movementStartTick = tick()
movementActive = true
end

pcOverrides.StartTurn = function(self, targetPosition)
local goal = sharedUtil.Ball:GetGoal(localPlayer)
if not goal then return end

local rootPosition = self.Args.HumanoidRootPart.Position
local lookPosition = Vector3.new(
targetPosition and targetPosition.X or goal.Position.X,
rootPosition.Y,
targetPosition and targetPosition.Z or goal.Position.Z
)

setBodyGyroLook(self.Args, CFrame.lookAt(rootPosition, lookPosition))

if debugState.traceBodyMovers then
	logger.debug("start turn", tostring(lookPosition))
end

movementStartTick = tick()
movementActive = true
end

pcOverrides.StopMovement = function(self)
movementActive = false
clearBodyVelocity(self.Args)
clearBodyGyro(self.Args)

if debugState.traceBodyMovers then
	logger.debug("stop movement")
end
end

pcOverrides.FixCamera = function(self)
local camera = workspace.CurrentCamera
camera.CameraSubject = self.Args.Humanoid
camera.CameraType = Enum.CameraType.Custom
camera.FieldOfView = 70
if self.Args.Head then
	camera.CFrame = self.Args.Head.CFrame
end
if is5v5 then self:UpdateBallcam() end
end

pcOverrides.UpdateBallcam = function(self)
if not is5v5 then return end
local vipValue = replicatedStorage:FindFirstChild("VIP")
if vipValue and vipValue.Value == true then
	local ballcam = gc.Ballcam
	local ball = gc.GameValues and gc.GameValues.Ball or nil
	if ballcam == true then
		if ball and currentCamera.CameraSubject ~= ball then
			currentCamera.CameraSubject = ball
		end
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
	if child.Name == "EMOTE_PROP_MODEL" and child:GetAttribute("DestroyPropCancel") then
		child:Destroy()
	end
end
end

pcOverrides.IsFirstPerson = function(self)
if self.Args.Head and self.Args.Head.LocalTransparencyModifier then
	return self.Args.Head.LocalTransparencyModifier == 1
end
return false
end

applyOverrides("PlayerController", pcOverrides)

---------------------------------------
-- inputController overrides
-- NOTE: KnitStart is intentionally NOT hooked (crashes game)
---------------------------------------
local icOverrides = {}

icOverrides.GetBallValues = function(self)
local _, values = basketball:GetValues()
return values
end

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
	elseif shotType == "Floater" then
		animationName = "Ball_Floater" .. handSuffix
		animationSpeed = 1.5
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

	if self.Args.ShotType == "Floater" then
		pc:StopMovement()
		pc:StartMovement(ballValues.Hand, 5, nil, nil, "layup")
		return
	end

	if self.Args.ShotType == "ReverseLayup" then
		pc:StartMovement("ForwardOpposite", 5, nil, nil, "layup")
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

local function beginDribbleAction(self, startDribbleArg, options)
	options = options or EMPTY_CONFIG
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

icOverrides.Shoot = function(self, isHolding)
if isBenched() then return end
if not hasBall(pc.Args.Character) then return end

local gameValues = getGameValues()
if not gameValues or gameValues.Inbounding then return end

if isHolding == true then
	if self.Args.CanShoot ~= true or self.Args.Holding then return end

	local _, ballValues = basketball:GetValues()
	if not ballValues then return end

	local goal = sharedUtil.Ball:GetGoal(localPlayer)
	if not goal then return end

	local root = pc.Args.HumanoidRootPart
	local humanoid = pc.Args.Humanoid
	local distanceToGoal = sharedUtil.Math:XYMagnitude(root.Position, goal.Position)

	if pc.Args.SpawnTick and tick() - pc.Args.SpawnTick < 5 then return end

	-- 5v5 distance warnings
	if is5v5 and distanceToGoal > 80 then
		if distanceToGoal > 100 then
			uc.UIs.Warning:Message("Get closer to the right basket!")
		else
			uc.UIs.Warning:Message("You can't shoot from that far!")
		end
	end

	self.Args.ShotType = (distanceToGoal < (is5v5 and 17.5 or 15) and root.Velocity.Magnitude > 4) and "Layup" or "Jumpshot"

	if distanceToGoal < 2.5 then return end

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

	-- auto release with configurable delay or wait for marker
	if shootCfg.autoRelease then
		local releaseDelay = shootCfg.releaseDelay or 0.35
		task.wait(releaseDelay)
	else
		waitForArgsFlag("Released", 2)
	end

	controlService.Shoot:Fire(shotPoint)

	if self.Args.ShotType == "Layup" then
		task.wait(0.2)
	elseif self.Args.ShotType == "ReverseLayup"
	or self.Args.ShotType == "Jumpshot"
	or self.Args.ShotType == "Floater"
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
if not slot then return end
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
	if closestPlayer then
		targetCharacter = closestPlayer.Character
	end
else
	local passTags = vc:PassTagTable()

	if passTags[slot] then
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
				local root = tagged.Parent.Parent:FindFirstChild("HumanoidRootPart")
				if root then guardTarget = root; break end
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
	if self.Args.CanDribble == false and self.Args[false] then return end -- NOTE: self.Args[false] is a game bug (key is boolean false, always nil); preserved for parity
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

	-- dunk changer
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

	-- action == "Jump": vanilla jump, no override needed
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

-- perfect steal: touch the ball part directly
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

-- re-initialize for current character (hooks are now active, replaces original CharacterAdded state)
-- placed after BOTH controller overrides so CharacterAdded fires with all hooks active
if localPlayer.Character then
	pc:CharacterAdded(localPlayer.Character)
	for i = 1, 10 do
		if localPlayer.Character then
			localPlayer.Character:BreakJoints()
		else
			break
		end
	end
end

-- ═══════ Consolidated Heartbeat ═══════
-- Speed override, auto lock, and extreme auto block combined into a single connection

local function updateSpeedOverride()
	if not config.movement.speedOverride then return end
	if not localPlayer or not localPlayer.Character then return end
	local humanoid = localPlayer.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local targetSpeed = config.movement.speed or 17
		if humanoid.WalkSpeed ~= targetSpeed then
			humanoid.WalkSpeed = targetSpeed
		end
	end
end

local function updateAutoGuardMode()
	if not config.defense.autoGuard then
		return
	end
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
			autoLockActive = false
			autoLockTargetRoot = nil
			if pcArgs and pcArgs.BodyGyro then
				clearBodyGyro(pcArgs)
			end
		end
		return
	end
	if not localPlayer or not localPlayer.Character then return end

	local wasActive = autoLockActive
	autoLockActive = not hasBall(localPlayer.Character)

	if wasActive and not autoLockActive then
		autoLockTargetRoot = nil
		if pcArgs and pcArgs.BodyGyro then
			clearBodyGyro(pcArgs)
		end
		return
	end

	if autoLockActive and (autoGuardDriving or (ic and ic.Args and ic.Args.Posting)) then
		return
	end

	local preferOffBall = config.defense.autoLockPreferOffBall == true
	local now = tick()
	if autoLockPreferOffBall ~= preferOffBall then
		autoLockPreferOffBall = preferOffBall
		autoLockTargetRoot = nil
		lastAutoLockRefreshTick = 0
	end

	if autoLockActive and pcArgs and pcArgs.HumanoidRootPart then
		if not autoLockTargetRoot
		or not autoLockTargetRoot.Parent
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
		elseif pcArgs.BodyGyro then
			clearBodyGyro(pcArgs)
		end
	end
end

local function updateAutoBlockExtreme()
	if not config.defense.autoBlock then return end
	if not config.defense.autoBlockExtreme then return end
	if not fireTouch then return end
	local pcArgs = pc and pc.Args
	if not pcArgs or not pcArgs.Character then return end

	local gameValues = getGameValues()
	if not gameValues or gameValues.Inbounding or gameValues.Possession == nil then return end
	if not ignoreTeamPossessionChecks() and localTeamHasPossession(gameValues) then return end

	local now = tick()
	if now - lastExtremeAutoBlockTick < getExtremeAutoBlockInterval() then return end
	lastExtremeAutoBlockTick = now

	local rightHand = pcArgs.RightHand or pcArgs["Right Arm"]
	if not rightHand then return end
	if not rightHand:IsDescendantOf(workspace) then return end
	local myRoot = pcArgs.HumanoidRootPart
	if not myRoot then return end

	for i = 1, #cachedPlayers do
		local player = cachedPlayers[i]
		if playersAreOpponents(player) and onCourtWith(player) and player.Character then
			local targetRoot = player.Character:FindFirstChild("HumanoidRootPart")
			local currentAttach = resolveBallAttach(player.Character)
			local autoBlockRange = getAutoBlockRange()
			if targetRoot and currentAttach and currentAttach:IsDescendantOf(workspace)
			and distanceSquared(myRoot.Position, targetRoot.Position) <= (autoBlockRange * autoBlockRange) then
				controlService.Block:Fire()
				pcall(fireTouch, currentAttach, rightHand, 0)
				task.delay(0.05, function()
				if currentAttach and currentAttach.Parent and rightHand and rightHand.Parent then
					pcall(fireTouch, currentAttach, rightHand, 1)
				end
			end)
		end
	end
end
end

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

-- initialize passive steal if config says so
if config.moves.steal.passiveSteal then
	setPassiveSteal(true, true)
end

-- initialize ball magnet if config says so
if config.ballMagnet.enabled then
	setBallMagnet(true, true)
end

-- ═══════ Auto Block System ═══════
-- Animation-based detection on opponents

local function cleanupAutoBlock(player)
	local connections = autoBlockConnections[player]
	if connections then
		for _, conn in ipairs(connections) do
			if typeof(conn) == "RBXScriptConnection" then
				conn:Disconnect()
			end
		end
		autoBlockConnections[player] = nil
	end
end

local function handleAutoBlockAnimation(player, character, animTrack)
	if not config.defense.autoBlock then return end
	if config.defense.autoBlockExtreme then return end
	if hasBall(pc.Args.Character) then return end
	if not playersAreOpponents(player) then return end
	if not onCourtWith(player) then return end

	local animId = animTrack and animTrack.Animation and animTrack.Animation.AnimationId
	if not animId or not blockReactiveAnimations[animId] then return end

	local gameValues = getGameValues()
	if not gameValues
	or gameValues.Inbounding
	or gameValues.Possession == nil
	or (not ignoreTeamPossessionChecks() and localTeamHasPossession(gameValues)) then
		return
	end

	if not is5v5 and (gameValues.Practice or gameValues.ScoringContest) then return end

	if ic.Args.InAction or ic.Args.BlockCD then return end
	if pc.Args.Character:GetAttribute("Stealing")
	or pc.Args.Character:GetAttribute("Broken")
	or pc.Args.Character:GetAttribute("PostBlockedCD") then
		return
	end

	local myRoot = pc.Args.HumanoidRootPart
	local targetRoot = character and character:FindFirstChild("HumanoidRootPart")
	if not myRoot or not targetRoot then return end
	if (myRoot.Position - targetRoot.Position).Magnitude > getAutoBlockRange() then return end

	local now = tick()
	if now - lastAutoBlockTick < getAutoBlockCooldown() then return end
	lastAutoBlockTick = now

	local rightHand = pc.Args.RightHand or pc.Args["Right Arm"]
	if not rightHand then return end

	task.delay(getAutoBlockTriggerDelay(), function()
	if not config.defense.autoBlock then return end
	if not character or not character.Parent then return end

	local currentAttach = resolveBallAttach(character)
	if not currentAttach then return end

	controlService.Block:Fire()

	if fireTouch then
		pcall(fireTouch, currentAttach, rightHand, 0)
		task.delay(getAutoBlockReleaseDelay(), function()
		pcall(fireTouch, currentAttach, rightHand, 1)
	end)
end
end)
end

local function handleAutoAnkleBreakerAnimation(player, character, animTrack)
	if not config.defense.autoAnkleBreaker then return end
	if not pc or not pc.Args or not ic or not ic.Args then return end
	if isBenched() then return end
	if not hasBall(pc.Args.Character) then return end
	if not playersAreOpponents(player) then return end
	if not onCourtWith(player) then return end

	local animId = animTrack and animTrack.Animation and animTrack.Animation.AnimationId
	if not animId or not stealReactiveAnimations[animId] then return end

	local gameValues = getGameValues()
	if not gameValues
	or gameValues.Inbounding
	or gameValues.Possession == nil
	or (not ignoreTeamPossessionChecks() and not localTeamHasPossession(gameValues)) then
		return
	end

	if not is5v5 and (gameValues.Practice or gameValues.ScoringContest) then return end
	if ic.Args.Posting or ic.Args.DoubleDribble or pc.Args.Character:GetAttribute("Broken") then return end

	local myRoot = pc.Args.HumanoidRootPart
	local targetRoot = character and character:FindFirstChild("HumanoidRootPart")
	if not myRoot or not targetRoot then return end
	if (myRoot.Position - targetRoot.Position).Magnitude > (config.defense.ankleBreakerRange or 18) then return end

	local reactiveMove = getAutoAnkleBreakerMove()
	if not reactiveMove then return end

	local now = tick()
	if now - lastAutoAnkleBreakerTick < AUTO_ANKLE_BREAKER_COOLDOWN then return end
	lastAutoAnkleBreakerTick = now
	autoAnkleBreakerRunId = autoAnkleBreakerRunId + 1
	local runId = autoAnkleBreakerRunId

	ic.Args.CanShoot = true
	ic.Args.CanDribble = true

	task.delay(config.defense.ankleBreakerDelay or 0.06, function()
	if runId ~= autoAnkleBreakerRunId then return end
	if not config.defense.autoAnkleBreaker then return end
	if not player or player.Parent == nil then return end
	if not character or not character.Parent then return end
	if not pc or not pc.Args or not ic or not ic.Args then return end
	if not hasBall(pc.Args.Character) then return end

	local delayedGameValues = getGameValues()
	if not delayedGameValues
	or delayedGameValues.Inbounding
	or delayedGameValues.Possession == nil
	or (not ignoreTeamPossessionChecks() and not localTeamHasPossession(delayedGameValues)) then
		return
	end

	local currentRoot = pc.Args.HumanoidRootPart
	local delayedTargetRoot = character:FindFirstChild("HumanoidRootPart")
	if not currentRoot or not delayedTargetRoot then return end
	if (currentRoot.Position - delayedTargetRoot.Position).Magnitude > (config.defense.ankleBreakerRange or 18) then return end

	ic:Dribble(reactiveMove)
end)
end

local function bindAutoBlockToCharacter(player, character)
	if player == localPlayer then return end
	cleanupAutoBlock(player)

	local connections = {}
	autoBlockConnections[player] = connections

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	local boundAnimators = {}

	local function bindAnimator(animator)
		if not animator or boundAnimators[animator] then return end
		boundAnimators[animator] = true
		connections[#connections + 1] = animator.AnimationPlayed:Connect(function(animTrack)
			handleAutoBlockAnimation(player, character, animTrack)
			handleAutoAnkleBreakerAnimation(player, character, animTrack)
		end)
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		-- wait briefly for Animator to replicate
		animator = humanoid:WaitForChild("Animator", 3)
	end

	bindAnimator(animator)
	connections[#connections + 1] = humanoid.ChildAdded:Connect(function(child)
		if child:IsA("Animator") then
			bindAnimator(child)
		end
	end)
end

local function attachAutoBlockPlayer(player)
	if player == localPlayer then return end
	if player.Character then
		bindAutoBlockToCharacter(player, player.Character)
	end
	local conn = player.CharacterAdded:Connect(function(character)
	task.wait(0.5) -- let character replicate
	if character and character.Parent then
		bindAutoBlockToCharacter(player, character)
	end
end)
local existing = autoBlockConnections[player]
if existing then
	existing[#existing + 1] = conn
else
	autoBlockConnections[player] = { conn }
end
end

-- initialize auto block for all current and future players
for _, player in ipairs(playersService:GetPlayers()) do
	task.spawn(attachAutoBlockPlayer, player)
end
playersService.PlayerAdded:Connect(attachAutoBlockPlayer)
playersService.PlayerRemoving:Connect(cleanupAutoBlock)

-- ═══════ UI ═══════

task.spawn(function()
local uiOk, BlackwineLib = pcall(function()
return loadstring(game:HttpGet("https://raw.githubusercontent.com/gfn8879-hub/blackwine/refs/heads/main/ui.lua"))()
end)

if not uiOk or not BlackwineLib then
	logger.warn("failed to load UI library — running headless".. tostring(BlackwineLib))
	return
end

local BlackwineLib = loadstring(game:HttpGet("https://raw.githubusercontent.com/gfn8879-hub/blackwine/refs/heads/main/ui.lua"))()

local Window = BlackwineLib:CreateWindow({
Title = "blackwine",
Size = UDim2.fromOffset(640, 440),
ToggleKey = Enum.KeyCode.RightShift,
})

-- ═══════ Home Tab ═══════
local HomeTab = Window:CreateTab({ Name = "Home" })
local HomeSection = HomeTab:AddSection({ Name = "welcome to blackwine." })

HomeSection:AddButton({
Name = "Rejoin Server",
Callback = rejoinServer,
})

HomeSection:AddButton({
Name = "Join Ranked",
Callback = teleportToRanked,
})

-- ═══════ Offense Tab ═══════
local OffenseTab = Window:CreateTab({ Name = "Offense" })

-- Shooting section (left)
local ShootSec = OffenseTab:AddSection({ Name = "Shooting", Side = "left" })

ShootSec:AddToggle({
Name = "Auto Green",
Default = config.moves.jumpshot.autoGreen,
Callback = function(v) config.moves.jumpshot.autoGreen = v; scheduleConfigSave() end,
})

ShootSec:AddToggle({
Name = "Perfect Release",
Default = config.moves.jumpshot.perfectRelease,
Callback = function(v) config.moves.jumpshot.perfectRelease = v; scheduleConfigSave() end,
})

ShootSec:AddSlider({
Name = "Green Chance",
Min = 0, Max = 100, Increment = 1, Default = config.moves.jumpshot.greenChance,
Suffix = "%",
Callback = function(v) config.moves.jumpshot.greenChance = v; scheduleConfigSave() end,
})

ShootSec:AddSlider({
Name = "Shot Speed",
Min = 0.5, Max = 3, Increment = 0.05, Default = config.moves.jumpshot.shotSpeed,
Callback = function(v) config.moves.jumpshot.shotSpeed = v; scheduleConfigSave() end,
})

ShootSec:AddToggle({
Name = "Auto Release",
Default = config.moves.jumpshot.autoRelease,
Callback = function(v) config.moves.jumpshot.autoRelease = v; scheduleConfigSave() end,
})

ShootSec:AddSlider({
Name = "Release Delay",
Min = 0.05, Max = 0.75, Increment = 0.05, Default = config.moves.jumpshot.releaseDelay,
Callback = function(v) config.moves.jumpshot.releaseDelay = v; scheduleConfigSave() end,
})

ShootSec:AddSlider({
Name = "Jumpshot Boost",
Min = 0.5, Max = 3, Increment = 0.1, Default = config.moves.jumpshot.boost,
Callback = function(v) config.moves.jumpshot.boost = v; scheduleConfigSave() end,
})

-- Dribble / PumpFake section (right)
local DribbleSec = OffenseTab:AddSection({ Name = "Dribble & Pump Fake", Side = "right" })

DribbleSec:AddToggle({
Name = "No Dribble Cooldown",
Default = config.moves.dribble.noDribbleCooldown,
Callback = function(v) config.moves.dribble.noDribbleCooldown = v; scheduleConfigSave() end,
})

DribbleSec:AddSlider({
Name = "Dribble Anim Speed",
Min = 0.5, Max = 5, Increment = 0.1, Default = config.moves.dribble.animSpeed,
Callback = function(v) config.moves.dribble.animSpeed = v; scheduleConfigSave() end,
})

DribbleSec:AddSlider({
Name = "Dribble Boost",
Min = 0.5, Max = 3, Increment = 0.1, Default = config.moves.dribble.boost,
Callback = function(v) config.moves.dribble.boost = v; scheduleConfigSave() end,
})

DribbleSec:AddToggle({
Name = "Force Shot (Pump Fake)",
Default = config.moves.pumpFake.forceShot,
Callback = function(v) config.moves.pumpFake.forceShot = v; scheduleConfigSave() end,
})

DribbleSec:AddToggle({
Name = "Jumpshot Fake",
Default = config.moves.pumpFake.jumpshotFake,
Callback = function(v) config.moves.pumpFake.jumpshotFake = v; scheduleConfigSave() end,
})

DribbleSec:AddToggle({
Name = "No Pump Fake Cooldown",
Default = config.moves.pumpFake.noPumpFakeCooldown,
Callback = function(v) config.moves.pumpFake.noPumpFakeCooldown = v; scheduleConfigSave() end,
})

DribbleSec:AddToggle({
Name = "Infinite Pump Fake",
Default = config.moves.pumpFake.infinitePumpFake,
Callback = function(v) config.moves.pumpFake.infinitePumpFake = v; scheduleConfigSave() end,
})

-- Dunking section (left)
local DunkSec = OffenseTab:AddSection({ Name = "Dunking", Side = "left" })

DunkSec:AddToggle({
Name = "Dunk Changer",
Default = config.moves.dunk.dunkChanger,
Callback = function(v) config.moves.dunk.dunkChanger = v; scheduleConfigSave() end,
})

DunkSec:AddDropdown({
Name = "Dunk Type",
Items = { "Tomahawk", "360", "Reverse", "Eastbay", "Double Clutch", "Under the Legs", "Windmill" },
Default = config.moves.dunk.dunkType,
Callback = function(v) config.moves.dunk.dunkType = v; scheduleConfigSave() end,
})

DunkSec:AddSlider({
Name = "Dunk Height",
Min = -3, Max = 3, Increment = 0.1, Default = config.moves.dunk.dunkHeight,
Callback = function(v) config.moves.dunk.dunkHeight = v; scheduleConfigSave() end,
})

DunkSec:AddToggle({
Name = "No Dunk Cooldown",
Default = config.moves.dunk.noDunkCooldown,
Callback = function(v) config.moves.dunk.noDunkCooldown = v; scheduleConfigSave() end,
})

DunkSec:AddToggle({
Name = "Unlock Dunk Range",
Default = config.moves.dunk.unlockRange,
Callback = function(v) config.moves.dunk.unlockRange = v; scheduleConfigSave() end,
})

DunkSec:AddSlider({
Name = "Dunk Boost",
Min = 0.5, Max = 3, Increment = 0.1, Default = config.moves.dunk.boost,
Callback = function(v) config.moves.dunk.boost = v; scheduleConfigSave() end,
})

-- Movement / Ranges section (right)
local MovesSec = OffenseTab:AddSection({ Name = "Movement & Ranges", Side = "right" })

MovesSec:AddToggle({
Name = "Unlock Euro Range",
Default = config.moves.euro.unlockRange,
Callback = function(v) config.moves.euro.unlockRange = v; scheduleConfigSave() end,
})

MovesSec:AddToggle({
Name = "Unlock Post Range",
Default = config.moves.post.unlockRange,
Callback = function(v) config.moves.post.unlockRange = v; scheduleConfigSave() end,
})

MovesSec:AddToggle({
Name = "Unlock Self Lob Range",
Default = config.moves.selfLob.unlockRange,
Callback = function(v) config.moves.selfLob.unlockRange = v; scheduleConfigSave() end,
})

MovesSec:AddSlider({
Name = "Euro Boost",
Min = 0.5, Max = 3, Increment = 0.1, Default = config.moves.euro.boost,
Callback = function(v) config.moves.euro.boost = v; scheduleConfigSave() end,
})

MovesSec:AddSlider({
Name = "Fade Boost",
Min = 0.5, Max = 3, Increment = 0.1, Default = config.moves.fade.boost,
Callback = function(v) config.moves.fade.boost = v; scheduleConfigSave() end,
})

MovesSec:AddSlider({
Name = "Layup Boost",
Min = 0.5, Max = 3, Increment = 0.1, Default = config.moves.layup.boost,
Callback = function(v) config.moves.layup.boost = v; scheduleConfigSave() end,
})

MovesSec:AddSlider({
Name = "Stepback Boost",
Min = 0.5, Max = 3, Increment = 0.1, Default = config.moves.stepback.boost,
Callback = function(v) config.moves.stepback.boost = v; scheduleConfigSave() end,
})

MovesSec:AddSlider({
Name = "Layup Anim Speed",
Min = 0.5, Max = 2, Increment = 0.1, Default = config.moves.layup.animSpeed,
Callback = function(v) config.moves.layup.animSpeed = v; scheduleConfigSave() end,
})

MovesSec:AddSlider({
Name = "Pass Boost",
Min = 0.5, Max = 3, Increment = 0.1, Default = config.moves.pass.boost,
Callback = function(v) config.moves.pass.boost = v; scheduleConfigSave() end,
})

-- Post section (left)
local PostSec = OffenseTab:AddSection({ Name = "Post", Side = "left" })

PostSec:AddToggle({
Name = "Auto Dropstep",
Default = config.moves.post.autoDropstep,
Callback = function(v) config.moves.post.autoDropstep = v; scheduleConfigSave() end,
})

PostSec:AddSlider({
Name = "Dropstep Radius",
Min = 3, Max = 12, Increment = 0.5, Default = config.moves.post.dropstepRange,
Callback = function(v) config.moves.post.dropstepRange = v; scheduleConfigSave() end,
})

PostSec:AddToggle({
Name = "Auto Hook",
Default = config.moves.post.autoHook,
Callback = function(v) config.moves.post.autoHook = v; scheduleConfigSave() end,
})

PostSec:AddSlider({
Name = "Hook Range",
Min = 5, Max = 15, Increment = 0.5, Default = config.moves.post.hookRange,
Callback = function(v) config.moves.post.hookRange = v; scheduleConfigSave() end,
})

PostSec:AddSlider({
Name = "Hand Scale",
Min = 1, Max = 2.5, Increment = 0.05, Default = config.moves.post.handScale,
Callback = function(v) config.moves.post.handScale = v; updateActivePostHandScale(); scheduleConfigSave() end,
})

PostSec:AddToggle({
Name = "Face Defender",
Default = config.moves.post.faceDefender,
Callback = function(v) config.moves.post.faceDefender = v; scheduleConfigSave() end,
})

PostSec:AddSlider({
Name = "Post Boost",
Min = 0.5, Max = 3, Increment = 0.1, Default = config.moves.post.boost,
Callback = function(v) config.moves.post.boost = v; scheduleConfigSave() end,
})

PostSec:AddSlider({
Name = "Assist Cooldown",
Min = 0, Max = 5, Increment = 0.05, Default = config.moves.post.assistCooldown,
Callback = function(v) config.moves.post.assistCooldown = v; scheduleConfigSave() end,
})

PostSec:AddSlider({
Name = "Hook Cooldown",
Min = 0, Max = 5, Increment = 0.05, Default = config.moves.post.hookCooldown,
Callback = function(v) config.moves.post.hookCooldown = v; scheduleConfigSave() end,
})

PostSec:AddSlider({
Name = "Hook Windup",
Min = 0, Max = 1, Increment = 0.01, Default = config.moves.post.hookTriggerDelay,
Callback = function(v) config.moves.post.hookTriggerDelay = v; scheduleConfigSave() end,
})

-- ═══════ Defense Tab ═══════
local DefenseTab = Window:CreateTab({ Name = "Defense" })

local BlockSec = DefenseTab:AddSection({ Name = "Blocking", Side = "left" })

BlockSec:AddToggle({
Name = "Auto Block",
Default = config.defense.autoBlock,
Callback = function(v) config.defense.autoBlock = v; scheduleConfigSave() end,
})

BlockSec:AddToggle({
Name = "Extreme Auto Block",
Default = config.defense.autoBlockExtreme,
Callback = function(v) config.defense.autoBlockExtreme = v; scheduleConfigSave() end,
})

BlockSec:AddSlider({
Name = "Blockbox Size",
Min = 0, Max = 200, Increment = 1, Default = config.defense.blockboxSize,
Callback = function(v)
config.defense.blockboxSize = normalizeBlockboxSize(v)
refreshPhysicalBlockbox()
scheduleConfigSave()
end,
})

BlockSec:AddSlider({
Name = "Block Boost",
Min = 0.5, Max = 3, Increment = 0.1, Default = config.moves.block.boost,
Callback = function(v) config.moves.block.boost = v; scheduleConfigSave() end,
})

BlockSec:AddSlider({
Name = "Auto Block Range",
Min = 5, Max = 60, Increment = 1, Default = config.defense.autoBlockRange,
Callback = function(v) config.defense.autoBlockRange = v; scheduleConfigSave() end,
})

BlockSec:AddSlider({
Name = "Block Cooldown",
Min = 0, Max = 3, Increment = 0.05, Default = config.defense.autoBlockCooldown,
Callback = function(v) config.defense.autoBlockCooldown = v; scheduleConfigSave() end,
})

BlockSec:AddSlider({
Name = "Block Windup",
Min = 0, Max = 1, Increment = 0.01, Default = config.defense.autoBlockTriggerDelay,
Callback = function(v) config.defense.autoBlockTriggerDelay = v; scheduleConfigSave() end,
})

BlockSec:AddSlider({
Name = "Release Window",
Min = 0, Max = 1, Increment = 0.01, Default = config.defense.autoBlockReleaseDelay,
Callback = function(v) config.defense.autoBlockReleaseDelay = v; scheduleConfigSave() end,
})

BlockSec:AddSlider({
Name = "Extreme Interval",
Min = 0.01, Max = 0.5, Increment = 0.01, Default = config.defense.extremeAutoBlockInterval,
Callback = function(v) config.defense.extremeAutoBlockInterval = v; scheduleConfigSave() end,
})

local GuardSec = DefenseTab:AddSection({ Name = "Guarding", Side = "right" })

GuardSec:AddToggle({
Name = "Auto Guard",
Default = config.defense.autoGuard,
Callback = function(v)
	config.defense.autoGuard = v
	if v ~= true then
		guardInputState.holdActive = false
		guardInputState.toggleActive = false
		syncDesiredGuardState(false, true)
	end
	scheduleConfigSave()
end,
})

GuardSec:AddToggle({
Name = "Auto Lock",
Default = config.defense.autoLock,
Callback = function(v) config.defense.autoLock = v; scheduleConfigSave() end,
})

GuardSec:AddToggle({
Name = "Prefer Off-Ball Lock",
Default = config.defense.autoLockPreferOffBall,
Callback = function(v) config.defense.autoLockPreferOffBall = v; scheduleConfigSave() end,
})

GuardSec:AddLabel({ Text = "Hold F for guard assist. Press B to toggle sticky guard." })

GuardSec:AddSlider({
Name = "Guard Range",
Min = 5, Max = 100, Increment = 1, Default = config.defense.guardRange,
Callback = function(v) config.defense.guardRange = v; scheduleConfigSave() end,
})

GuardSec:AddSlider({
Name = "Guard Refresh",
Min = 0.01, Max = 0.5, Increment = 0.01, Default = config.defense.guardRefreshInterval,
Callback = function(v) config.defense.guardRefreshInterval = v; scheduleConfigSave() end,
})

GuardSec:AddSlider({
Name = "Target Switch Cooldown",
Min = 0.05, Max = 1, Increment = 0.05, Default = config.defense.guardTargetSwitchCooldown,
Callback = function(v) config.defense.guardTargetSwitchCooldown = v; scheduleConfigSave() end,
})

GuardSec:AddSlider({
Name = "Lock Lead Distance",
Min = 0, Max = 15, Increment = 0.25, Default = config.defense.autoLockLeadDistance,
Callback = function(v) config.defense.autoLockLeadDistance = v; scheduleConfigSave() end,
})

GuardSec:AddSlider({
Name = "Lock Refresh",
Min = 0.01, Max = 0.5, Increment = 0.01, Default = config.defense.autoLockRefreshInterval,
Callback = function(v) config.defense.autoLockRefreshInterval = v; scheduleConfigSave() end,
})

GuardSec:AddSlider({
Name = "Guard Speed Factor",
Min = 1, Max = 60, Increment = 1, Default = config.defense.autoGuardSpeedFactor,
Callback = function(v) config.defense.autoGuardSpeedFactor = v; scheduleConfigSave() end,
})

GuardSec:AddSlider({
Name = "Guard Min Speed",
Min = 0, Max = 40, Increment = 1, Default = config.defense.autoGuardMinSpeed,
Callback = function(v) config.defense.autoGuardMinSpeed = v; scheduleConfigSave() end,
})

GuardSec:AddSlider({
Name = "Guard Max Speed",
Min = 0, Max = 60, Increment = 1, Default = config.defense.autoGuardMaxSpeed,
Callback = function(v) config.defense.autoGuardMaxSpeed = v; scheduleConfigSave() end,
})

GuardSec:AddToggle({
Name = "Anti Bump",
Default = config.defense.antiBump,
Callback = function(v) config.defense.antiBump = v; scheduleConfigSave() end,
})

local StealSec = DefenseTab:AddSection({ Name = "Stealing", Side = "left" })

StealSec:AddToggle({
Name = "Perfect Steal",
Default = config.moves.steal.perfectSteal,
Callback = function(v) config.moves.steal.perfectSteal = v; scheduleConfigSave() end,
})

StealSec:AddToggle({
Name = "No Steal Cooldown",
Default = config.moves.steal.noStealCooldown,
Callback = function(v) config.moves.steal.noStealCooldown = v; scheduleConfigSave() end,
})

StealSec:AddToggle({
Name = "Phantom Steal",
Default = config.moves.steal.phantomSteal,
Callback = function(v) config.moves.steal.phantomSteal = v; scheduleConfigSave() end,
})

StealSec:AddSlider({
Name = "Steal Boost",
Min = 0.5, Max = 3, Increment = 0.1, Default = config.moves.steal.boost,
Callback = function(v) config.moves.steal.boost = v; scheduleConfigSave() end,
})

StealSec:AddToggle({
Name = "Passive Steal",
Default = config.moves.steal.passiveSteal,
Callback = function(v) setPassiveSteal(v) end,
})

StealSec:AddSlider({
Name = "Passive Interval",
Min = 0.05, Max = 2, Increment = 0.05, Default = config.moves.steal.passiveInterval,
Callback = function(v) config.moves.steal.passiveInterval = v; scheduleConfigSave() end,
})

StealSec:AddToggle({
Name = "Auto Ankle Breaker",
Default = config.defense.autoAnkleBreaker,
Callback = function(v) config.defense.autoAnkleBreaker = v; scheduleConfigSave() end,
})

StealSec:AddSlider({
Name = "Ankle Breaker Range",
Min = 5, Max = 35, Increment = 1, Default = config.defense.ankleBreakerRange,
Callback = function(v) config.defense.ankleBreakerRange = v; scheduleConfigSave() end,
})

StealSec:AddSlider({
Name = "Ankle Breaker Delay",
Min = 0, Max = 0.3, Increment = 0.01, Default = config.defense.ankleBreakerDelay,
Callback = function(v) config.defense.ankleBreakerDelay = v; scheduleConfigSave() end,
})

StealSec:AddSlider({
Name = "Rebound Boost",
Min = 0.5, Max = 3, Increment = 0.1, Default = config.moves.rebound.boost,
Callback = function(v) config.moves.rebound.boost = v; scheduleConfigSave() end,
})

local BallMagnetSec = DefenseTab:AddSection({ Name = "Ball Magnet", Side = "right" })

BallMagnetSec:AddToggle({
Name = "Ball Magnet",
Default = config.ballMagnet.enabled,
Callback = function(v) setBallMagnet(v) end,
})

BallMagnetSec:AddSlider({
Name = "Scale",
Min = 10, Max = 100, Increment = 5, Default = config.ballMagnet.scale,
Callback = function(v) config.ballMagnet.scale = v; refreshBallMagnet(); scheduleConfigSave() end,
})

BallMagnetSec:AddToggle({
Name = "Resize Ball",
Default = config.ballMagnet.resizeEnabled,
Callback = function(v) config.ballMagnet.resizeEnabled = v; refreshBallMagnet(); scheduleConfigSave() end,
})

BallMagnetSec:AddToggle({
Name = "Direct Touch Fire",
Default = config.ballMagnet.directTouchEnabled,
Callback = function(v) config.ballMagnet.directTouchEnabled = v; scheduleConfigSave() end,
})

BallMagnetSec:AddSlider({
Name = "Grab Radius",
Min = 5, Max = 40, Increment = 1, Default = config.ballMagnet.range,
Callback = function(v) config.ballMagnet.range = v; refreshBallMagnet(); scheduleConfigSave() end,
})

BallMagnetSec:AddSlider({
Name = "Touch Cooldown",
Min = 0.01, Max = 1, Increment = 0.01, Default = config.ballMagnet.touchCooldown,
Callback = function(v) config.ballMagnet.touchCooldown = v; scheduleConfigSave() end,
})

BallMagnetSec:AddSlider({
Name = "Screen Boost",
Min = 0.5, Max = 3, Increment = 0.1, Default = config.moves.screen.boost,
Callback = function(v) config.moves.screen.boost = v; scheduleConfigSave() end,
})

-- ═══════ Movement Tab ═══════
local MovementTab = Window:CreateTab({ Name = "Movement" })
local SpeedSec = MovementTab:AddSection({ Name = "Speed", Side = "left" })

SpeedSec:AddToggle({
Name = "Speed Override",
Default = config.movement.speedOverride,
Callback = function(v) config.movement.speedOverride = v; scheduleConfigSave() end,
})

SpeedSec:AddSlider({
Name = "Walk Speed",
Min = 1, Max = 50, Increment = 1, Default = config.movement.speed,
Callback = function(v) config.movement.speed = v; scheduleConfigSave() end,
})

SpeedSec:AddToggle({
Name = "No Jump Cooldown",
Default = config.movement.noJumpCooldown,
Callback = function(v) config.movement.noJumpCooldown = v; scheduleConfigSave() end,
})

SpeedSec:AddSlider({
Name = "Gyro Torque",
Min = 0, Max = 2000000, Increment = 50000, Default = config.movement.bodyGyroTorque,
Callback = function(v) config.movement.bodyGyroTorque = v; scheduleConfigSave() end,
})

SpeedSec:AddSlider({
Name = "Velocity Force",
Min = 0, Max = 2000000, Increment = 50000, Default = config.movement.bodyVelocityForce,
Callback = function(v) config.movement.bodyVelocityForce = v; scheduleConfigSave() end,
})

SpeedSec:AddSlider({
Name = "Turn Unlock Delay",
Min = 0, Max = 1, Increment = 0.01, Default = config.movement.turnUnlockDelay,
Callback = function(v) config.movement.turnUnlockDelay = v; scheduleConfigSave() end,
})

local AbilitySec = MovementTab:AddSection({ Name = "Abilities", Side = "right" })

AbilitySec:AddToggle({
Name = "Unlock All Moves",
Default = config.abilities.unlockAllMoves,
Callback = function(v) config.abilities.unlockAllMoves = v; scheduleConfigSave() end,
})

AbilitySec:AddToggle({
Name = "Ignore Team/Possession Checks",
Default = config.abilities.ignoreTeamPossessionChecks,
Callback = function(v) config.abilities.ignoreTeamPossessionChecks = v; scheduleConfigSave() end,
})

SpeedSec:AddToggle({
Name = "Hide CoreGui",
Default = config.movement.hideCoreGui,
Callback = function(v) config.movement.hideCoreGui = v; scheduleConfigSave() end,
})

-- ═══════ Settings Tab ═══════
local SettingsTab = Window:CreateTab({ Name = "Settings" })
local ConfigSec = SettingsTab:AddSection({ Name = "Configuration", Side = "left" })

ConfigSec:AddButton({
Name = "Save Config",
Callback = function()
saveConfig(config)
end,
})

ConfigSec:AddButton({
Name = "Load Config",
Callback = function()
configApplying = true
loadConfigFromDisk(config)
configApplying = false
syncDebugState()
refreshPhysicalBlockbox()
refreshBallMagnet()
logger.info("config loaded — some changes may require rejoin")
end,
})

ConfigSec:AddButton({
Name = "Reset Config",
Callback = function()
	if canUseFileApi() then
		local ok = pcall(function()
			if typeof(delfile) == "function" then
				delfile(CONFIG_FILE)
				if typeof(isfile) == "function" and isfile(LEGACY_CONFIG_FILE) then
					delfile(LEGACY_CONFIG_FILE)
				end
			elseif typeof(writefile) == "function" then
				writefile(CONFIG_FILE, "{}")
				if typeof(isfile) == "function" and isfile(LEGACY_CONFIG_FILE) then
					writefile(LEGACY_CONFIG_FILE, "{}")
				end
			end
		end)
		if ok then
			logger.info("config reset — rejoin to apply defaults")
		end
	end
end,
})

local DebugSec = SettingsTab:AddSection({ Name = "Diagnostics", Side = "right" })

DebugSec:AddToggle({
Name = "Debug Logging",
Default = config.debug.enabled,
Callback = function(v)
config.debug.enabled = v
syncDebugState()
scheduleConfigSave()
end,
})

DebugSec:AddToggle({
Name = "Trace Body Movers",
Default = config.debug.traceBodyMovers,
Callback = function(v)
config.debug.traceBodyMovers = v
syncDebugState()
scheduleConfigSave()
end,
})

local InfoSec = SettingsTab:AddSection({ Name = "Info", Side = "right" })
InfoSec:AddLabel({ Text = "Config auto-saves after changes." })
InfoSec:AddLabel({ Text = "File: " .. CONFIG_FILE })
InfoSec:AddLabel({ Text = "Legacy Import: " .. LEGACY_CONFIG_FILE })
InfoSec:AddLabel({ Text = "Mode: " .. (is5v5 and "5v5" or "MyPark") })

end)

logger.info("blackwine fully initialized")

]])
