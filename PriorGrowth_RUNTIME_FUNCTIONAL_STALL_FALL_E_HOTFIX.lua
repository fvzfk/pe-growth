-- Prior Growth runtime hotfix
-- Fixes functional controller stalls, falling during food tween/arrival,
-- cave drops when visible food is above, and one-shot E interactions.
-- Run this AFTER the current full Prior Growth script. It patches the running
-- controller in-place and creates no Parts or invisible platforms.

if getgenv and getgenv().PriorGrowthRuntimeHotfixLoaded then
    warn("[Prior Growth Hotfix] Already loaded")
    return
end
if getgenv then getgenv().PriorGrowthRuntimeHotfixLoaded = true end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

local function waitForGlobal(name, timeout)
    local started = tick()
    while tick() - started < (timeout or 30) do
        local value = rawget(getgenv and getgenv() or _G, name) or rawget(_G, name)
        if value ~= nil then return value end
        task.wait(0.1)
    end
    return nil
end

local startGrowth = waitForGlobal("_PG_startGrowth", 30)
if type(startGrowth) ~= "function" then
    error("[Prior Growth Hotfix] Run the full Prior Growth script first, then run this hotfix.")
end

local dbg = debug
local function readUpvalues(fn)
    local result = {}
    if type(fn) ~= "function" then return result end

    local bulk = rawget(getgenv and getgenv() or _G, "getupvalues")
        or (dbg and dbg.getupvalues)
    if type(bulk) == "function" then
        local ok, values = pcall(bulk, fn)
        if ok and type(values) == "table" then
            for key, value in pairs(values) do result[key] = value end
        end
    end

    if dbg and type(dbg.getupvalue) == "function" then
        for index = 1, 240 do
            local ok, name, value = pcall(dbg.getupvalue, fn, index)
            if not ok or name == nil then break end
            result[name] = value
        end
    end
    return result
end

local candidates = {
    startGrowth,
    rawget(getgenv and getgenv() or _G, "_PG_tweenDirectlyToFood"),
    rawget(getgenv and getgenv() or _G, "_PG_beginMealMovementLock"),
    rawget(getgenv and getgenv() or _G, "_PG_targetDepleted"),
    rawget(getgenv and getgenv() or _G, "_PG_holdAndClickFoodE"),
}

local captured = {}
local visited = {}
local function harvest(fn, depth)
    if type(fn) ~= "function" or visited[fn] or depth > 4 then return end
    visited[fn] = true
    local values = readUpvalues(fn)
    for name, value in pairs(values) do
        if captured[name] == nil then captured[name] = value end
        if type(value) == "function" then harvest(value, depth + 1) end
    end
end
for _, fn in ipairs(candidates) do harvest(fn, 1) end

local State = captured.State
if type(State) ~= "table" then
    error("[Prior Growth Hotfix] Could not access the running controller State table.")
end

local getRoot = captured.getRoot
local getFood = captured.getFood
local findAllFoods = captured.findAllFoods
local findNearestFood = captured.findNearestFood
local eatTarget = captured.eatTarget
local activateCurrentConsumptionHint = captured.activateCurrentConsumptionHint
local removeFromFoodCache = captured.removeFromFoodCache

local function rootPart()
    if type(getRoot) == "function" then
        local ok, value = pcall(getRoot)
        if ok and value then return value end
    end
    local character = LocalPlayer.Character
    if not character then return nil end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    return (humanoid and humanoid.RootPart)
        or character:FindFirstChild("HumanoidRootPart")
        or character:FindFirstChild("Body")
        or character:FindFirstChild("Torso")
        or character.PrimaryPart
end

local function character()
    return LocalPlayer.Character
end

local function currentFoodPercent()
    if type(getFood) ~= "function" then return 100, 0, 0 end
    local ok, current, maximum = pcall(getFood)
    if not ok then return 100, 0, 0 end
    current, maximum = tonumber(current) or 0, tonumber(maximum) or 0
    return maximum > 0 and math.clamp(current / maximum * 100, 0, 100) or 100,
        current, maximum
end

local function healingLocked()
    return State.Saved == true
        or State.HealingLock == true
        or State.SafeExitBusy == true
        or State.SleepSequenceBusy == true
end

-- -------------------------------------------------------------------------
-- 1) Keep the real root supported for every tween frame. No generated Part.
-- -------------------------------------------------------------------------
local oldRunTween = rawget(getgenv and getgenv() or _G, "_PG_runWholeCharacterTween")
if type(oldRunTween) == "function" then
    _PG_runWholeCharacterTween = function(char, root, goalCF, duration, cancelCheck)
        if State.MealMovementLock then return false end
        if not char or not char.Parent or not root or not root.Parent then return false end

        local previousAnchored = root.Anchored
        pcall(function()
            root.Anchored = true
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end)

        local ok, result = pcall(oldRunTween, char, root, goalCF, duration, cancelCheck)
        if not ok then
            pcall(function() root.Anchored = previousAnchored end)
            warn("[Prior Growth Hotfix] Tween error: " .. tostring(result))
            return false
        end

        -- A successful food move stays anchored across the tiny arrival handoff.
        -- The meal lock adopts it immediately; a failed/cancelled move releases it.
        if result and State.Eating and State.FoodTravelPart and not healingLocked() then
            State.RuntimeArrivalAnchorRoot = root
            State.RuntimeArrivalPreviousAnchored = previousAnchored
            pcall(function()
                root.Anchored = true
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
            end)
        else
            pcall(function() root.Anchored = previousAnchored end)
        end
        return result
    end
end

-- Old cleanup used to unanchor between the final tween and meal lock.
local oldRestoreMovement = rawget(getgenv and getgenv() or _G, "_PG_restoreActiveTweenMovement")
if type(oldRestoreMovement) == "function" then
    _PG_restoreActiveTweenMovement = function(generation, cancelling)
        local root = State.ActiveMovementRoot or rootPart()
        local previous = root and root.Anchored or false
        local ok, result = pcall(oldRestoreMovement, generation, cancelling)
        if not ok then warn("[Prior Growth Hotfix] Movement restore error: " .. tostring(result)) end

        if not cancelling and State.Eating and State.FoodTravelPart
            and not healingLocked() and root and root.Parent then
            State.RuntimeArrivalAnchorRoot = root
            State.RuntimeArrivalPreviousAnchored = previous
            pcall(function()
                root.Anchored = true
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
            end)
        end
        return ok and result or nil
    end
end

-- -------------------------------------------------------------------------
-- 2) Transfer arrival ownership directly into the meal lock. There is no
--    unanchored/gravity gap and no mid-meal tween can take control.
-- -------------------------------------------------------------------------
_PG_beginMealMovementLock = function(target)
    if healingLocked() or State.WasHit then return false end
    if not target or not target.Part or not target.Part.Parent then return false end

    local char = character()
    local root = State.RuntimeArrivalAnchorRoot or rootPart()
    if not char or not root or not root.Parent then return false end

    if type(_PG_cancelActiveTweenMovement) == "function" and State.ActiveMovementTween then
        pcall(_PG_cancelActiveTweenMovement)
    end

    local humanoid = char:FindFirstChildOfClass("Humanoid")
    State.MealLockRoot = root
    State.MealLockRootWasAnchored = State.RuntimeArrivalPreviousAnchored == true
    State.MealLockTarget = target.Part
    State.MealLockCFrame = root.CFrame
    State.MealLockHumanoid = humanoid
    State.MealLockHumanoidState = humanoid and {
        PlatformStand = humanoid.PlatformStand,
        AutoRotate = humanoid.AutoRotate,
        WalkSpeed = humanoid.WalkSpeed,
    } or nil

    State.RuntimeArrivalAnchorRoot = nil
    State.RuntimeArrivalPreviousAnchored = nil
    State.MovementGeneration = (State.MovementGeneration or 0) + 1
    State.Landing = false
    State.LandingSince = 0

    pcall(function()
        root.Anchored = true
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end)
    if humanoid then
        pcall(function()
            humanoid.PlatformStand = false
            humanoid.Sit = false
            humanoid.AutoRotate = false
            humanoid.WalkSpeed = 0
        end)
    end

    State.MealMovementLock = true
    State.LastFunctionalFoodProgress = tick()
    return true
end

local oldReleaseMeal = rawget(getgenv and getgenv() or _G, "_PG_releaseMealMovementLock")
if type(oldReleaseMeal) == "function" then
    _PG_releaseMealMovementLock = function(...)
        local ok, result = pcall(oldReleaseMeal, ...)
        local arrivalRoot = State.RuntimeArrivalAnchorRoot
        if arrivalRoot and arrivalRoot.Parent then
            pcall(function()
                arrivalRoot.Anchored = State.RuntimeArrivalPreviousAnchored == true
                arrivalRoot.AssemblyLinearVelocity = Vector3.zero
                arrivalRoot.AssemblyAngularVelocity = Vector3.zero
            end)
        end
        State.RuntimeArrivalAnchorRoot = nil
        State.RuntimeArrivalPreviousAnchored = nil
        return ok and result or nil
    end
end

-- -------------------------------------------------------------------------
-- 3) Never descend into a cave when the visible food is level with/above us.
-- -------------------------------------------------------------------------
local oldDirectApproach = rawget(getgenv and getgenv() or _G, "_PG_getDirectFoodApproach")
if type(oldDirectApproach) == "function" then
    _PG_getDirectFoodApproach = function(target, root, char)
        local approach, visibleFood, extra = oldDirectApproach(target, root, char)
        if not approach or not visibleFood or not root then return approach, visibleFood, extra end

        local safeFloor = (tonumber(Workspace.FallenPartsDestroyHeight) or -500) + 180
        local fixedY = math.max(approach.Y, safeFloor)

        -- The bug case: the corpse is visibly above/level, but a buried limb/root
        -- supplies a cave-level Y. Never permit a downward dive in that case.
        if visibleFood.Y >= root.Position.Y - 22 then
            fixedY = math.max(fixedY, root.Position.Y - 5, visibleFood.Y - 8)
        end

        -- Also reject impossible one-step drops near the same X/Z map region.
        local horizontal = Vector3.new(
            visibleFood.X - root.Position.X, 0, visibleFood.Z - root.Position.Z
        ).Magnitude
        if horizontal < 1800 and fixedY < root.Position.Y - 220 then
            fixedY = root.Position.Y - 12
        end

        return Vector3.new(approach.X, fixedY, approach.Z), visibleFood, extra
    end
end

-- -------------------------------------------------------------------------
-- 4) Prompt loss alone is not depletion. Explicit reserve/empty state or the
--    actual object disappearing is required while eating.
-- -------------------------------------------------------------------------
_PG_targetDepleted = function(target)
    if not target or not target.Part or not target.Part.Parent then return true end

    local reserveKeys = {
        "Food", "FoodLeft", "RemainingFood", "Reserves", "Remaining",
        "Amount", "Bites", "CurrentFood", "FoodReserve", "FoodReserves"
    }
    local emptyKeys = {
        "Depleted", "Consumed", "Eaten", "Empty", "Destroyed", "Finished", "Exhausted"
    }

    local reserveSeen, positiveReserve = false, false
    local function inspect(object)
        if not object or not object.Parent then return false end
        if object:GetAttribute("Spawned") == false then return true end
        for _, key in ipairs(emptyKeys) do
            if object:GetAttribute(key) == true then return true end
        end
        for _, key in ipairs(reserveKeys) do
            local value = tonumber(object:GetAttribute(key))
            if value ~= nil then
                reserveSeen = true
                if value > 0 then positiveReserve = true end
            end
        end
        if object:IsA("ValueBase") then
            local low = object.Name:lower():gsub("[^%a]", "")
            if low:find("food", 1, true) or low:find("reserve", 1, true)
                or low:find("remaining", 1, true) or low:find("amount", 1, true)
                or low:find("bites", 1, true) then
                local value = tonumber(object.Value)
                if value ~= nil then
                    reserveSeen = true
                    if value > 0 then positiveReserve = true end
                end
            end
        end
        return false
    end

    if inspect(target.Part) or inspect(target.Model) then return true end
    if target.Model and target.Model.Parent then
        local checked = 0
        for _, object in ipairs(target.Model:GetDescendants()) do
            checked += 1
            if checked > 260 then break end
            if inspect(object) then return true end
        end
    end
    if reserveSeen and not positiveReserve then return true end

    -- Missing prompts are often hidden while the consumption UI is open.
    -- During a meal, never use that temporary disappearance to abandon food.
    if State.MealMovementLock and State.MealLockTarget == target.Part then
        return false
    end

    if target.HadPrompt then
        local owner = target.Model or target.Part.Parent
        local found = false
        if owner and owner.Parent then
            local checked = 0
            for _, object in ipairs(owner:GetDescendants()) do
                checked += 1
                if checked > 420 then break end
                if object:IsA("ProximityPrompt") then
                    found = true
                    target.Prompt = object
                    break
                end
            end
        end
        if found then
            target.PromptMissingSince = nil
        else
            target.PromptMissingSince = target.PromptMissingSince or tick()
            if tick() - target.PromptMissingSince >= 10 then return true end
        end
    end
    return false
end

-- -------------------------------------------------------------------------
-- 5) Strong persistent hold-E -> release -> click-E interaction.
-- -------------------------------------------------------------------------
local firePrompt = rawget(getgenv and getgenv() or _G, "fireproximityprompt")
    or rawget(_G, "fireproximityprompt")

_PG_holdAndClickFoodE = function(target, prompt)
    if healingLocked() or not State.Eating or not State.MealMovementLock then return false end

    local carnivoreFood = type(_PG_isCarnivoreFoodKind) == "function"
        and _PG_isCarnivoreFoodKind(target)
    local minimum = carnivoreFood and 3.2 or 2.2
    local holdTime = math.max(tonumber(prompt and prompt.HoldDuration) or 0, minimum)
    State.LastInteractionAttemptAt = tick()
    State.InteractionTargetPart = target and target.Part or nil
    State.LastFunctionalFoodProgress = tick()

    if type(activateCurrentConsumptionHint) == "function" then
        pcall(activateCurrentConsumptionHint)
    end
    if prompt and prompt.Parent then pcall(function() prompt:InputHoldBegin() end) end

    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
    local started = tick()
    while tick() - started < holdTime do
        if healingLocked() or State.WasHit or not State.Eating or not State.MealMovementLock then break end
        local root = State.MealLockRoot or rootPart()
        if root and root.Parent then
            pcall(function()
                root.Anchored = true
                root.AssemblyLinearVelocity = Vector3.zero
                root.AssemblyAngularVelocity = Vector3.zero
            end)
        end
        if type(activateCurrentConsumptionHint) == "function"
            and tick() - started > 0.65 then
            pcall(activateCurrentConsumptionHint)
        end
        task.wait(0.08)
    end

    -- Complete the held prompt before the clean click phase.
    if firePrompt and prompt and prompt.Parent then pcall(firePrompt, prompt, holdTime) end
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
    if prompt and prompt.Parent then pcall(function() prompt:InputHoldEnd() end) end
    task.wait(0.16)

    for _ = 1, 3 do
        if healingLocked() or State.WasHit or not State.Eating or not State.MealMovementLock then break end
        if type(activateCurrentConsumptionHint) == "function" then
            pcall(activateCurrentConsumptionHint)
        end
        VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
        task.wait(0.10)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
        task.wait(0.28)
    end

    -- Allow the authoritative server food tick to arrive before another cycle.
    task.wait(0.85)
    return true
end

-- -------------------------------------------------------------------------
-- 6) Functional-progress watchdog. The original heartbeat can update forever
--    while the controller is stationary, so this watches actual action/motion.
-- -------------------------------------------------------------------------
State.LastFunctionalFoodProgress = tick()
State.RuntimeRescueBusy = false
local previousAction = tostring(State.LastAction or "")
local previousPosition = rootPart() and rootPart().Position or nil
local previousFood = select(2, currentFoodPercent())

local function validTarget(target)
    return target and target.Part and target.Part.Parent
        and not (type(_PG_targetDepleted) == "function" and _PG_targetDepleted(target))
end

local function functionalRestart(reason)
    if State.RuntimeRescueBusy or healingLocked() or State.Eating
        or State.MealMovementLock or State.ActiveMovementTween then return end

    State.RuntimeRescueBusy = true
    State.LastFunctionalFoodProgress = tick()
    State.LastAction = reason or "Functional food controller recovery"

    pcall(function()
        if type(_PG_cancelActiveTweenMovement) == "function" then _PG_cancelActiveTweenMovement() end
    end)
    State.Landing = false
    State.LandingSince = 0
    State.ExpectedMovement = false
    State.ControllerRecoveryBusy = false
    State.FoodScanInProgress = false
    State.FoodAttemptToken = (State.FoodAttemptToken or 0) + 1
    State.MovementGeneration = (State.MovementGeneration or 0) + 1

    local locked = State.LockedTarget
    if not validTarget(locked) then
        State.LockedTarget = nil
        State.CurrentTarget = nil
    else
        State.CurrentTarget = locked
    end

    -- Replace exactly one coordinator. UI, ESP, caches, safety and scanner
    -- connections remain installed; this is the reliable manual OFF->ON recovery.
    State.Running = false
    State.ControllerToken = (State.ControllerToken or 0) + 1
    task.delay(0.12, function()
        if State.AutoGrowthDesired and not healingLocked() then
            pcall(_PG_startGrowth)
        end
        State.RuntimeRescueBusy = false
    end)
end

-- Direct rescue for the screenshot state: usable foods exist, hungry, but no
-- target/tween/eating action has begun for several seconds.
task.spawn(function()
    while task.wait(0.75) do
        pcall(function()
            local root = rootPart()
            local action = tostring(State.LastAction or "")
            local foodPct, foodNow, maxFood = currentFoodPercent()
            local trigger = tonumber(State.DynamicHungerTriggerPct)
                or tonumber(State.HungerTriggerPct) or 75
            local hungry = State.HungryMode == true or (maxFood > 0 and foodPct <= trigger)

            if healingLocked() then
                -- Absolutely no food/movement recovery while Safe Mode heals.
                State.LastFunctionalFoodProgress = tick()
                previousAction = action
                previousPosition = root and root.Position or previousPosition
                previousFood = foodNow
                return
            end

            local progressed = false
            if action ~= previousAction then progressed = true end
            if root and previousPosition and (root.Position - previousPosition).Magnitude >= 2 then
                progressed = true
            end
            if foodNow > (previousFood or foodNow) + 0.05 then progressed = true end
            if State.Eating or State.MealMovementLock or State.ActiveMovementTween or State.Landing then
                progressed = true
            end
            if validTarget(State.CurrentTarget) and State.CurrentTarget ~= State.RuntimeLastTarget then
                progressed = true
                State.RuntimeLastTarget = State.CurrentTarget
            end
            if progressed then State.LastFunctionalFoodProgress = tick() end

            previousAction = action
            previousPosition = root and root.Position or previousPosition
            previousFood = foodNow

            if not State.AutoGrowthDesired or not State.Running or not hungry then return end
            if State.Eating or State.MealMovementLock or State.ActiveMovementTween or State.Landing then return end
            if State.MenuSequence or State.WasHit then return end

            local stalledFor = tick() - (State.LastFunctionalFoodProgress or tick())
            local usable = tonumber(State.FoodsFound) or 0
            local scanningAction = action:lower():find("scan", 1, true)
                or action:lower():find("rescan", 1, true)
                or action:lower():find("failed", 1, true)
                or action:lower():find("retry", 1, true)

            if usable > 0 and stalledFor >= 4.5 then
                functionalRestart("Usable food exists but controller was idle - forcing immediate retry")
            elseif scanningAction and stalledFor >= 7 then
                functionalRestart("Scanner/controller loop made no functional progress - restarting food selection")
            elseif validTarget(State.LockedTarget) and stalledFor >= 4 then
                functionalRestart("Locked food still exists - restarting movement to the same target")
            end
        end)
    end
end)

print("[Prior Growth Hotfix] Functional stall + no-fall arrival + persistent E fix loaded")
