-- ============================================================
-- PRIOR GROWTH COMPATIBILITY FIX
-- Free camera + local-only lava checks + walking after full food
--
-- IMPORTANT:
-- Run your latest full Prior Growth script first, then run this file.
-- This patch preserves the existing 5000-stud scanner in that build.
-- ============================================================

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualInputManager = game:GetService("VirtualInputManager")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local originalKeepLockedFoodOnTerrain
local lastPaceAt = 0
local paceSide = 1
local lastSafeWalkSpeed = 16

local function getCharacter()
    return LocalPlayer and LocalPlayer.Character
end

local function getRoot()
    local character = getCharacter()
    if not character then return nil end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    return (humanoid and humanoid.RootPart)
        or character:FindFirstChild("HumanoidRootPart")
        or character.PrimaryPart
end

local function getHumanoid()
    local character = getCharacter()
    return character and character:FindFirstChildOfClass("Humanoid")
end

local function getCharacterReplicaData()
    local common = ReplicatedStorage:FindFirstChild("Common")
    local characterStateModule = common and common:FindFirstChild("CharacterState")
    if not characterStateModule or not characterStateModule:IsA("ModuleScript") then
        return nil
    end

    local ok, characterState = pcall(require, characterStateModule)
    if not ok or type(characterState) ~= "table" then return nil end

    local replica = characterState.Replica
    return replica and replica.Data or nil
end

local function readFood()
    local data = getCharacterReplicaData()
    if type(data) == "table"
        and type(data.Stats) == "table"
        and type(data.MaxStats) == "table" then

        local current = tonumber(data.Stats.Food)
        local maximum = tonumber(data.MaxStats.Food)
        if current and maximum and maximum > 0 then
            return current, maximum
        end
    end

    local character = getCharacter()
    if character then
        local current = tonumber(character:GetAttribute("Food"))
        local maximum = tonumber(character:GetAttribute("MaxFood"))
        if current and maximum and maximum > 0 then
            return current, maximum
        end
    end

    return 0, 0
end

local function isFoodFull()
    local current, maximum = readFood()
    return maximum > 0 and current >= maximum * 0.995
end

local function releaseInteractionKeys()
    pcall(function()
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.R, false, game)
        VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Z, false, game)
    end)
end

local function restoreCameraAndMovement()
    local character = getCharacter()
    local humanoid = getHumanoid()
    local root = getRoot()

    pcall(function()
        Camera = Workspace.CurrentCamera or Camera
        if Camera then
            Camera.CameraType = Enum.CameraType.Custom
            if humanoid then Camera.CameraSubject = humanoid end
        end
    end)

    if root then
        pcall(function()
            root.Anchored = false
            root.AssemblyAngularVelocity = Vector3.zero
        end)
    end

    if humanoid then
        pcall(function()
            if humanoid.WalkSpeed > 0 then
                lastSafeWalkSpeed = humanoid.WalkSpeed
            else
                humanoid.WalkSpeed = math.max(lastSafeWalkSpeed, 8)
            end

            humanoid.PlatformStand = false
            humanoid.Sit = false
            humanoid.AutoRotate = true
            humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
            task.defer(function()
                if humanoid and humanoid.Parent then
                    pcall(function()
                        humanoid:ChangeState(Enum.HumanoidStateType.Running)
                    end)
                end
            end)
        end)
    end

    releaseInteractionKeys()
end

local function isLavaName(instance)
    local node = instance
    for _ = 1, 7 do
        if not node or node == Workspace then break end
        local token = tostring(node.Name or ""):lower():gsub("[^%a%d]", "")
        if token:find("hardeninglava", 1, true)
            or token:find("hardenedlava", 1, true) then
            return true
        end
        node = node.Parent
    end
    return false
end

local function getLocalLavaRadius()
    local character = getCharacter()
    if not character then return 18 end

    local radius = 18
    pcall(function()
        local _, size = character:GetBoundingBox()
        radius = math.clamp(math.max(size.X, size.Z) * 0.35 + 8, 14, 35)
    end)
    return radius
end

local function localLavaCheck(position, radius, ignoreInstance)
    if typeof(position) ~= "Vector3" then return false end

    radius = math.clamp(tonumber(radius) or getLocalLavaRadius(), 8, 40)

    local overlap = OverlapParams.new()
    overlap.FilterType = Enum.RaycastFilterType.Blacklist
    overlap.MaxParts = 128

    local ignored = {}
    local character = getCharacter()
    if character then table.insert(ignored, character) end
    if ignoreInstance then table.insert(ignored, ignoreInstance) end
    overlap.FilterDescendantsInstances = ignored

    local ok, nearby = pcall(function()
        return Workspace:GetPartBoundsInRadius(position, radius, overlap)
    end)
    if not ok or type(nearby) ~= "table" then return false end

    for _, part in ipairs(nearby) do
        if part:IsA("BasePart") and isLavaName(part) then
            return true
        end
    end

    return false
end

local function validGroundAt(position)
    local character = getCharacter()
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Blacklist
    params.FilterDescendantsInstances = character and {character} or {}
    params.IgnoreWater = false

    local result = Workspace:Raycast(
        position + Vector3.new(0, 35, 0),
        Vector3.new(0, -90, 0),
        params
    )

    if not result then return nil end
    if result.Material == Enum.Material.Water then return nil end
    if result.Instance and isLavaName(result.Instance) then return nil end
    if localLavaCheck(result.Position, getLocalLavaRadius(), character) then return nil end

    return result.Position
end

local function choosePacePoint()
    local root = getRoot()
    if not root then return nil end

    local forward = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
    if forward.Magnitude < 0.1 then forward = Vector3.new(0, 0, -1) end
    forward = forward.Unit

    local directions = {
        forward * paceSide,
        -forward * paceSide,
        Vector3.new(-forward.Z, 0, forward.X),
        Vector3.new(forward.Z, 0, -forward.X),
    }

    for _, direction in ipairs(directions) do
        local wanted = root.Position + direction * 8
        local ground = validGroundAt(wanted)
        if ground then
            return Vector3.new(wanted.X, ground.Y + 2, wanted.Z)
        end
    end

    return nil
end

local function paceAfterFull()
    if not isFoodFull() then return end
    if tick() - lastPaceAt < 3 then return end

    local humanoid = getHumanoid()
    local root = getRoot()
    if not humanoid or not root then return end

    restoreCameraAndMovement()

    local target = choosePacePoint()
    if not target then return end

    lastPaceAt = tick()
    paceSide *= -1

    pcall(function()
        humanoid:MoveTo(target)
    end)
end

local function installOverrides()
    -- Never let the food routine switch the player's camera to Scriptable.
    _G._PG_positionFoodCameraOnce = function()
        restoreCameraAndMovement()
        return false
    end

    _G._PG_restoreFoodCamera = function()
        restoreCameraAndMovement()
    end

    -- Lava only matters when a lava MeshPart is physically near this exact point.
    _G._PG_isNearLavaHazard = function(position, radius, ignoreInstance)
        return localLavaCheck(position, radius, ignoreInstance)
    end

    _G._PG_foodNearLavaHazard = function(food)
        if not food or not food.Part or not food.Part.Parent then return true end
        return localLavaCheck(
            food.Part.Position,
            getLocalLavaRadius(),
            food.Model or food.Part
        )
    end

    if not originalKeepLockedFoodOnTerrain
        and type(_G._PG_keepLockedFoodOnTerrain) == "function" then
        originalKeepLockedFoodOnTerrain = _G._PG_keepLockedFoodOnTerrain
    end

    _G._PG_keepLockedFoodOnTerrain = function(target)
        -- Once full, never pull, snap, settle, or tether the dinosaur to old food.
        if isFoodFull() then
            restoreCameraAndMovement()
            return true
        end

        if originalKeepLockedFoodOnTerrain then
            return originalKeepLockedFoodOnTerrain(target)
        end

        return true
    end
end

-- Reapply because the main script may finish defining its globals after this patch starts.
task.spawn(function()
    while true do
        installOverrides()
        task.wait(1)
    end
end)

-- Full-food watchdog: restore controls and make the dinosaur resume safe pacing.
task.spawn(function()
    while true do
        task.wait(0.5)
        if isFoodFull() then
            restoreCameraAndMovement()
            paceAfterFull()
        end
    end
end)

LocalPlayer.CharacterAdded:Connect(function()
    task.wait(2)
    restoreCameraAndMovement()
    installOverrides()
end)

installOverrides()
restoreCameraAndMovement()

print("[Prior Growth Fix] Free camera, local-only lava checks, and full-food walking active")
