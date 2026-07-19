-- Prior Growth | Functional Stall Recovery V2
-- Run AFTER the current full Prior Growth script.
-- Focused fix for: usable food detected, Auto Growth ON, but dinosaur remains idle.
-- Creates no Parts, platforms, elevators, guardians, ESP objects, or UI.

if getgenv and getgenv().PriorGrowthFunctionalStallV2Loaded then
    warn("[Prior Growth Stall V2] Already loaded")
    return
end
if getgenv then getgenv().PriorGrowthFunctionalStallV2Loaded = true end

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local function globalValue(name)
    local env = getgenv and getgenv() or _G
    return rawget(env, name) or rawget(_G, name)
end

local function waitForGlobal(name, timeout)
    local started = tick()
    while tick() - started < (timeout or 30) do
        local value = globalValue(name)
        if value ~= nil then return value end
        task.wait(0.1)
    end
    return nil
end

local startGrowth = waitForGlobal("_PG_startGrowth", 30)
if type(startGrowth) ~= "function" then
    error("[Prior Growth Stall V2] Run the full Prior Growth script first.")
end

local dbg = debug
local function upvalues(fn)
    local out = {}
    if type(fn) ~= "function" then return out end

    local bulk = globalValue("getupvalues") or (dbg and dbg.getupvalues)
    if type(bulk) == "function" then
        local ok, values = pcall(bulk, fn)
        if ok and type(values) == "table" then
            for key, value in pairs(values) do out[key] = value end
        end
    end

    if dbg and type(dbg.getupvalue) == "function" then
        for index = 1, 260 do
            local ok, name, value = pcall(dbg.getupvalue, fn, index)
            if not ok or name == nil then break end
            out[name] = value
        end
    end
    return out
end

local captured, visited = {}, {}
local function harvest(fn, depth)
    if type(fn) ~= "function" or visited[fn] or depth > 5 then return end
    visited[fn] = true
    for name, value in pairs(upvalues(fn)) do
        if captured[name] == nil then captured[name] = value end
        if type(value) == "function" then harvest(value, depth + 1) end
    end
end

harvest(startGrowth, 1)
for _, name in ipairs({
    "_PG_tweenDirectlyToFood",
    "_PG_beginMealMovementLock",
    "_PG_cancelActiveTweenMovement",
    "_PG_releaseMealMovementLock",
}) do
    harvest(globalValue(name), 1)
end

local State = captured.State
local getRoot = captured.getRoot
local getFood = captured.getFood
local targetDepleted = globalValue("_PG_targetDepleted") or captured._PG_targetDepleted
local cancelTween = globalValue("_PG_cancelActiveTweenMovement")
local releaseMealLock = globalValue("_PG_releaseMealMovementLock")

if type(State) ~= "table" then
    error("[Prior Growth Stall V2] Could not access the active controller State.")
end

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

local function foodValues()
    if type(getFood) ~= "function" then return 0, 0, 100 end
    local ok, current, maximum = pcall(getFood)
    if not ok then return 0, 0, 100 end
    current, maximum = tonumber(current) or 0, tonumber(maximum) or 0
    local pct = maximum > 0 and math.clamp(current / maximum * 100, 0, 100) or 100
    return current, maximum, pct
end

local function healingLocked()
    return State.Saved == true
        or State.HealingLock == true
        or State.SafeExitBusy == true
        or State.SleepSequenceBusy == true
        or State.WakeSequenceBusy == true
end

local function targetValid(target)
    if not target or not target.Part or not target.Part.Parent then return false end
    if type(targetDepleted) == "function" then
        local ok, depleted = pcall(targetDepleted, target)
        if ok and depleted then return false end
    end
    return true
end

local recoveryBusy = false
local lastRealProgress = tick()
local lastPosition = nil
local lastFood = select(1, foodValues())
local lastTarget = nil
local lastEating = State.Eating == true
local lastMovementActive = false
local movementStartedAt = 0
local movementLastMovedAt = tick()

local function markProgress()
    lastRealProgress = tick()
end

local function recover(reason)
    if recoveryBusy or healingLocked() or State.Eating or State.MealMovementLock then return end

    recoveryBusy = true
    markProgress()
    State.LastAction = reason or "Functional food recovery"
    State.ControllerRecoveryBusy = true

    -- Stop only stale ownership. Never touch an active meal or Safe Mode healing.
    if type(cancelTween) == "function" then pcall(cancelTween) end
    State.Landing = false
    State.LandingSince = 0
    State.ExpectedMovement = false
    State.ExpectedMoveSince = 0
    State.FoodScanInProgress = false
    State.LowFoodScanPending = false
    State.FoodAttemptToken = (State.FoodAttemptToken or 0) + 1
    State.MovementGeneration = (State.MovementGeneration or 0) + 1

    -- Preserve a real locked target. Only clear dead/depleted targets.
    if targetValid(State.LockedTarget) then
        State.CurrentTarget = State.LockedTarget
    elseif targetValid(State.CurrentTarget) then
        State.LockedTarget = State.CurrentTarget
    else
        State.LockedTarget = nil
        State.CurrentTarget = nil
    end

    -- Force exactly one coordinator replacement. Do not clear the completed
    -- food cache, so usable food cannot collapse from a temporary retry.
    State.Running = false
    State.ControllerToken = (State.ControllerToken or 0) + 1
    State.ControllerHeartbeat = 0

    task.delay(0.15, function()
        if State.AutoGrowthDesired and not healingLocked() then
            pcall(startGrowth)
        end
        State.ControllerRecoveryBusy = false
        recoveryBusy = false
        markProgress()
    end)
end

task.spawn(function()
    while task.wait(0.5) do
        pcall(function()
            local root = rootPart()
            local position = root and root.Position or nil
            local currentFood, maximumFood, foodPct = foodValues()
            local trigger = tonumber(State.DynamicHungerTriggerPct)
                or tonumber(State.HungerTriggerPct) or 75
            local hungry = State.HungryMode == true
                or (maximumFood > 0 and foodPct <= trigger)

            if healingLocked() then
                -- Safe Mode owns everything while healing. Do not restart, scan,
                -- select food, unanchor, cancel sleep, or touch movement.
                lastPosition = position or lastPosition
                lastFood = currentFood
                lastTarget = State.CurrentTarget or State.LockedTarget
                lastEating = State.Eating == true
                lastMovementActive = State.ActiveMovementTween ~= nil or State.Landing == true
                markProgress()
                return
            end

            local movementActive = State.ActiveMovementTween ~= nil or State.Landing == true
            local eatingActive = State.Eating == true or State.MealMovementLock == true
            local target = State.CurrentTarget or State.LockedTarget

            -- Only real gameplay changes count as progress. Status/action text and
            -- ControllerHeartbeat updates deliberately do NOT count.
            if position and lastPosition and (position - lastPosition).Magnitude >= 1.5 then
                markProgress()
                movementLastMovedAt = tick()
            end
            if currentFood > (lastFood or currentFood) + 0.05 then markProgress() end
            if target ~= lastTarget and targetValid(target) then markProgress() end
            if eatingActive and not lastEating then markProgress() end
            if movementActive and not lastMovementActive then
                movementStartedAt = tick()
                movementLastMovedAt = tick()
                markProgress()
            end

            lastPosition = position or lastPosition
            lastFood = currentFood
            lastTarget = target
            lastEating = eatingActive
            lastMovementActive = movementActive

            if not State.AutoGrowthDesired or not State.Running or not hungry then return end
            if State.MenuSequence or State.WasHit or recoveryBusy then return end
            if eatingActive then return end

            local usable = tonumber(State.FoodsFound) or 0
            local idleFor = tick() - lastRealProgress

            -- A tween exists but the dinosaur has not physically changed position.
            if movementActive and tick() - movementLastMovedAt >= 5 then
                recover("Food tween made no physical progress - restarting the same target")
                return
            end

            -- Exact screenshot state: usable foods exist, hungry, Auto Growth ON,
            -- but no tween, no eating and no movement begins.
            if not movementActive and usable > 0 and idleFor >= 4 then
                recover("Usable food detected but controller remained idle - forcing selection now")
                return
            end

            -- Keep a still-existing locked target alive instead of endlessly
            -- printing failed/rescan status with no new movement attempt.
            if not movementActive and targetValid(State.LockedTarget) and idleFor >= 3.5 then
                recover("Locked food still exists but movement stopped - retrying it immediately")
                return
            end

            -- Scanner flags can remain true even after usable food was produced.
            if not movementActive and State.FoodScanInProgress and usable > 0 and idleFor >= 3 then
                recover("Scanner finished usable food but never handed it to movement")
            end
        end)
    end
end)

print("[Prior Growth Stall V2] Strict functional-progress recovery loaded")
