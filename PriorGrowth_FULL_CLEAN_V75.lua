--[[
    PRIOR GROWTH | FULL CLEAN V75
    One-file controller for Prior Extinction-style Roblox testing.

    Core guarantees:
    - ONE scanner index, ONE controller loop, ONE movement owner.
    - NO generated Parts, landing pads, elevators, guardians, or void guard.
    - Corpses are ONLY exact models named Physics or Host.
    - Meat chunks are ONLY known meat models/containers.
    - Bones are ONLY exact BonePile models and are selected when no corpse/meat exists.
    - Food ESP remains independent of Auto Growth and disappears only when the
      food instance/prompt is genuinely removed.
    - Eating hard-locks all movement and repeats Hold E -> Click E until full
      or the exact food is gone.
    - Safe Mode owns the controller completely while healing.
]]

-- ============================================================
-- SINGLE-INSTANCE STARTUP
-- ============================================================
local ENV = (getgenv and getgenv()) or _G
if ENV.PriorGrowthV75 and type(ENV.PriorGrowthV75.Destroy) == "function" then
    pcall(ENV.PriorGrowthV75.Destroy)
end

if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser = game:GetService("VirtualUser")
local CollectionService = game:GetService("CollectionService")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera
local firePrompt = fireproximityprompt or (ENV and ENV.fireproximityprompt)

local App = {
    Connections = {},
    Running = false,
    Destroyed = false,
    ControllerToken = 0,
    MovementToken = 0,
    Moving = false,
    Eating = false,
    Healing = false,
    HealingLock = false,
    WasHit = false,
    DamagePosition = nil,
    CurrentTarget = nil,
    LockedTarget = nil,
    LastAction = "Loaded",
    LastProgress = tick(),
    LastPosition = nil,
    LastFoodValue = 0,
    LastTarget = nil,
    LastScanDuration = 0,
    ScanVisited = 0,
    UsableCount = 0,
    DetectedCount = 0,
    FoodIndexReady = false,
    ScanInProgress = false,
    FoodIndex = {},
    FoodByInstance = {},
    FoodESP = {},
    DinoESP = {},
    FoodESPOn = true,
    DinoESPOn = false,
    LastSurfaceCFrame = nil,
    CharacterCollisionState = nil,
    MealRoot = nil,
    MealCFrame = nil,
    MealPromptMissingSince = 0,
    ActiveTween = nil,
    ActiveTweenValue = nil,
    ActiveTweenConnection = nil,
    SafeModeEnabled = true,
    StageStop = "Don't Stop",
    StopPct = 100,
    Config = {
        TweenSpeed = 300,
        TweenSpeedMin = 50,
        TweenSpeedMax = 1000,
        SkyClearance = 1800,
        VerticalSpeed = 800,
        HungerSmall = 75,
        HungerLarge = 85,
        LargeTank = 2000,
        FullFoodPct = 99.5,
        DangerRadius = 500,
        FoodCrowdRadius = 170,
        SafeDistance = 1200,
        ScanBatch = 500,
        ReconcileSeconds = 90,
        FoodESPRefresh = 1.0,
        DinoESPRefresh = 1.0,
        PromptMissingGrace = 1.5,
        ArrivalTolerance = 35,
        ArrivalRetries = 5,
        NoGainRepositionSeconds = 35,
        StallSeconds = 5,
        CorpseESPMax = 1000,
        PlantESPMax = 100,
    },
}
ENV.PriorGrowthV75 = App

-- ============================================================
-- CONNECTION / CLEANUP HELPERS
-- ============================================================
local function connect(signal, fn)
    local connection = signal:Connect(fn)
    table.insert(App.Connections, connection)
    return connection
end

local function disconnect(connection)
    if connection then pcall(function() connection:Disconnect() end) end
end

local function safeDestroy(instance)
    if instance then pcall(function() instance:Destroy() end) end
end

local function clearTableInstances(tbl)
    for key, value in pairs(tbl) do
        safeDestroy(value)
        tbl[key] = nil
    end
end

local function log(message)
    App.LastAction = tostring(message)
    print("[Prior Growth V75] " .. App.LastAction)
end

-- ============================================================
-- SETTINGS SAVE / LOAD
-- ============================================================
local SETTINGS_FILE = "PriorGrowthV75_Settings.json"
local function saveSettings()
    if not writefile then return end
    pcall(function()
        writefile(SETTINGS_FILE, HttpService:JSONEncode({
            TweenSpeed = App.Config.TweenSpeed,
            FoodESPOn = App.FoodESPOn,
            DinoESPOn = App.DinoESPOn,
            SafeModeEnabled = App.SafeModeEnabled,
            StageStop = App.StageStop,
            StopPct = App.StopPct,
        }))
    end)
end

local function loadSettings()
    if not readfile or not isfile then return end
    pcall(function()
        if not isfile(SETTINGS_FILE) then return end
        local data = HttpService:JSONDecode(readfile(SETTINGS_FILE))
        if type(data) ~= "table" then return end
        App.Config.TweenSpeed = math.clamp(
            tonumber(data.TweenSpeed) or App.Config.TweenSpeed,
            App.Config.TweenSpeedMin,
            App.Config.TweenSpeedMax
        )
        App.FoodESPOn = data.FoodESPOn ~= false
        App.DinoESPOn = data.DinoESPOn == true
        App.SafeModeEnabled = data.SafeModeEnabled ~= false
        App.StageStop = tostring(data.StageStop or App.StageStop)
        App.StopPct = math.clamp(tonumber(data.StopPct) or 100, 0, 100)
    end)
end
loadSettings()

-- ============================================================
-- CHARACTER / STAT HELPERS
-- ============================================================
local function getCharacter()
    return LocalPlayer.Character
end

local function getHumanoid(character)
    character = character or getCharacter()
    return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function getRoot(character)
    character = character or getCharacter()
    if not character then return nil end
    local humanoid = getHumanoid(character)
    return (humanoid and humanoid.RootPart)
        or character:FindFirstChild("HumanoidRootPart")
        or character:FindFirstChild("Body")
        or character:FindFirstChild("Torso")
        or character.PrimaryPart
        or character:FindFirstChildWhichIsA("BasePart", true)
end

local CharacterState = nil
pcall(function()
    local common = ReplicatedStorage:FindFirstChild("Common")
    local module = common and common:FindFirstChild("CharacterState")
    if module and module:IsA("ModuleScript") then CharacterState = require(module) end
end)

local function replicaData()
    if type(CharacterState) == "table"
        and type(CharacterState.Replica) == "table"
        and type(CharacterState.Replica.Data) == "table" then
        return CharacterState.Replica.Data
    end
    return nil
end

local function parseHudFraction(keyword)
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not playerGui then return 0, 0 end
    keyword = tostring(keyword):lower()
    for _, object in ipairs(playerGui:GetDescendants()) do
        if object:IsA("TextLabel") or object:IsA("TextBox") then
            local name = tostring(object.Name):lower()
            local parentName = object.Parent and tostring(object.Parent.Name):lower() or ""
            if name:find(keyword, 1, true) or parentName:find(keyword, 1, true) then
                local current, maximum = tostring(object.Text or ""):match("(%d+%.?%d*)%s*/%s*(%d+%.?%d*)")
                if current and maximum then return tonumber(current) or 0, tonumber(maximum) or 0 end
            end
        end
    end
    return 0, 0
end

local function getFoodStat()
    local data = replicaData()
    if data and type(data.Stats) == "table" and type(data.MaxStats) == "table" then
        local current = tonumber(data.Stats.Food)
        local maximum = tonumber(data.MaxStats.Food)
        if current and maximum then return current, maximum end
    end
    local current, maximum = parseHudFraction("food")
    if maximum > 0 then return current, maximum end
    local character = getCharacter()
    return tonumber(character and character:GetAttribute("Food")) or 0,
        tonumber(character and character:GetAttribute("MaxFood")) or 100
end

local function getHealthStat()
    local data = replicaData()
    if data and type(data.Stats) == "table" and type(data.MaxStats) == "table" then
        local current = tonumber(data.Stats.Health)
        local maximum = tonumber(data.MaxStats.Health)
        if current and maximum then return current, maximum end
    end
    local humanoid = getHumanoid()
    if humanoid then return humanoid.Health, humanoid.MaxHealth end
    local character = getCharacter()
    return tonumber(character and character:GetAttribute("Health")) or 0,
        tonumber(character and character:GetAttribute("MaxHealth")) or 0
end

local function getSpecies()
    local character = getCharacter()
    if not character then return "Unknown" end
    local value = character:GetAttribute("Type")
        or character:GetAttribute("Species")
        or character:GetAttribute("Dinosaur")
        or character.Name
    value = tostring(value or "Unknown")
    value = value:match("^%s*(.-)%s*$") or value
    return value:match("^([^%(]+)") or value
end

local STAGE_RANK = {
    hatchling = 1,
    juvenile = 2,
    adolescent = 3,
    subadult = 4,
    adult = 5,
    elder = 6,
    monster = 7,
}

local function normalizeStage(value)
    value = tostring(value or ""):lower():gsub("[^%a]", "")
    if value:find("subadult", 1, true) then return "subadult" end
    for stage in pairs(STAGE_RANK) do
        if value:find(stage, 1, true) then return stage end
    end
    return "hatchling"
end

local function getStage()
    local data = replicaData()
    local value = data and (data.Stage or data.GrowthStage or data.LifeStage)
    local character = getCharacter()
    value = value or (character and (
        character:GetAttribute("Stage")
        or character:GetAttribute("GrowthStage")
        or character:GetAttribute("LifeStage")
    ))
    return normalizeStage(value)
end

local function getStageProgress()
    local data = replicaData()
    local value = data and (data.StageProgress or data.GrowthProgress or data.Progress)
    local character = getCharacter()
    value = tonumber(value) or tonumber(character and (
        character:GetAttribute("StageProgress")
        or character:GetAttribute("GrowthProgress")
        or character:GetAttribute("Progress")
    )) or 0
    if value <= 1 then value *= 100 end
    return math.clamp(value, 0, 100)
end

-- ============================================================
-- DIETS / SPECIES PROFILES
-- ============================================================
local CARNIVORES = {
    Acrocanthosaurus=true, Allosaurus=true, Austroraptor=true, Baryonyx=true,
    Carcharodontosaurus=true, Carnotaurus=true, Ceratosaurus=true,
    Concavenator=true, Deinosuchus=true, Deinonychus=true, Dilophosaurus=true,
    Dynamotitan=true, Giganotosaurus=true, Guanlong=true, Ichthyovenator=true,
    Irritator=true, Majungasaurus=true, Mapusaurus=true, Megaraptor=true,
    Nanuqsaurus=true, Pteranodon=true, Quetzalcoatlus=true, Rugops=true,
    Sarcosuchus=true, Siats=true, Spinosaurus=true, Suchomimus=true,
    Tarbosaurus=true, Torvosaurus=true, Troodon=true, Tyrannosaurus=true,
    Utahraptor=true, Velociraptor=true, Yutyrannus=true, Yutyrannosaurus=true,
}

local OMNIVORES = {
    Arbovenator=true, Avimimus=true, Beipiaosaurus=true, Citipati=true,
    Deinocheirus=true, Gallimimus=true, Gigantoraptor=true,
    Jianchangosaurus=true, Ornithomimus=true, Oviraptor=true,
    Segnosaurus=true, Sinopterus=true, Tupandactylus=true, Yunnanosaurus=true,
}

local OMNIVORE_PROFILES = {
    Gigantoraptor = {Allowed={Plant=true,Fruit=true,Insect=true,Anthill=true}, Priority={Fruit=1,Plant=2,Anthill=3,Insect=4}},
    Deinocheirus = {Allowed={Plant=true,Fruit=true,Fish=true}, Priority={Plant=1,Fruit=2,Fish=3}},
    Gallimimus = {Allowed={Plant=true,Fruit=true,Anthill=true}, Priority={Plant=1,Fruit=2,Anthill=3}},
    Citipati = {Allowed={Plant=true,Fruit=true,Egg=true,Bone=true}, Priority={Egg=1,Bone=2,Plant=3,Fruit=4}},
    Jianchangosaurus = {Allowed={Plant=true,Fruit=true,Insect=true,Anthill=true}, Priority={Fruit=1,Anthill=2,Plant=3,Insect=4}},
    Beipiaosaurus = {Allowed={Plant=true,Fruit=true,Insect=true,Anthill=true}, Priority={Plant=1,Anthill=2,Fruit=3,Insect=4}},
    Yunnanosaurus = {Allowed={Plant=true,Fruit=true,Egg=true,Shell=true}, Priority={Plant=1,Fruit=2,Egg=3,Shell=4}},
    Sinopterus = {Allowed={Fish=true,Fruit=true,Shell=true,Corpse=true,MeatChunk=true,Anthill=true,Honey=true,Insect=true}, Priority={Fish=1,Fruit=2,Shell=3,Corpse=4,MeatChunk=5,Anthill=6,Honey=7,Insect=8}},
}

local function getDiet()
    local species = getSpecies()
    if CARNIVORES[species] then return "Carnivore" end
    if OMNIVORES[species] then return "Omnivore" end
    local character = getCharacter()
    local attribute = character and character:GetAttribute("Diet")
    if attribute == "Carnivore" or attribute == "Omnivore" or attribute == "Herbivore" then
        return attribute
    end
    return "Herbivore"
end

local function canEatBone()
    local species = getSpecies()
    if species == "Austroraptor" then return false end
    if species == "Citipati" then return true end
    if getDiet() ~= "Carnivore" then return false end
    local rank = STAGE_RANK[getStage()] or 1
    return rank >= STAGE_RANK.subadult
end

local function allowedKind(kind)
    local diet = getDiet()
    local species = getSpecies()
    local _, maxFood = getFoodStat()

    if diet == "Herbivore" then
        return kind == "Plant" or kind == "Fruit"
    end

    if diet == "Carnivore" then
        if kind == "Corpse" or kind == "MeatChunk" or kind == "Fish" then return true end
        if kind == "Bone" then return canEatBone() end
        if kind == "Shell" or kind == "Mussel" then
            if maxFood >= App.Config.LargeTank then return false end
            if species == "Carcharodontosaurus" or species == "Giganotosaurus" then return false end
            return kind == "Shell"
        end
        return false
    end

    local profile = OMNIVORE_PROFILES[species]
    if profile then return profile.Allowed[kind] == true end
    return kind == "Plant" or kind == "Fruit" or kind == "Insect" or kind == "Anthill"
end

local function kindPriority(kind)
    local diet = getDiet()
    if diet == "Carnivore" then
        return ({Corpse=1, MeatChunk=2, Bone=3, Shell=4, Fish=5, Mussel=99})[kind] or 99
    elseif diet == "Herbivore" then
        return ({Fruit=1, Plant=2})[kind] or 99
    end
    local profile = OMNIVORE_PROFILES[getSpecies()]
    return profile and (profile.Priority[kind] or 99)
        or (({Anthill=1, Insect=2, Fruit=3, Plant=4})[kind] or 99)
end

-- ============================================================
-- STRICT FOOD CLASSIFICATION
-- ============================================================
local MEAT_CONTAINERS = {
    CollectedMeat=true, Meat=true, SpawnedMeat=true, Chunks=true,
    DroppedMeat=true, MeatChunks=true,
}

local COLLECTIBLE_WORDS = {
    "fossil", "gem", "crystal", "mineral", "ore", "artifact", "relic",
    "treasure", "collectible", "excavation", "digsite", "dig site",
}

local PLANT_WORDS = {
    "plant", "foliage", "fern", "bush", "shrub", "tree", "leaf",
    "grass", "coniopteris", "lauraceae", "osmunda", "blechnum",
    "gleicheniaceae", "monanthesia", "marmarthia", "horsetail",
    "cycad", "flower", "frond", "herb",
}

local FRUIT_WORDS = {"fruit", "berry", "berries", "apple", "melon", "palaeoaster"}
local INSECT_WORDS = {"insect", "termite", "ant", "bug", "beetle", "mound"}

local function compactName(value)
    return tostring(value or ""):lower():gsub("[%s_%-]", "")
end

local function hasWord(value, words)
    value = tostring(value or ""):lower()
    for _, word in ipairs(words) do
        if value:find(word, 1, true) then return true end
    end
    return false
end

local function isCollectible(object)
    local node = object
    for _ = 1, 8 do
        if not node or node == Workspace then break end
        if hasWord(node.Name, COLLECTIBLE_WORDS) then return true end
        node = node.Parent
    end
    return false
end

local function exactAncestorModel(object, exactName)
    local node = object
    for _ = 1, 10 do
        if not node or node == Workspace then break end
        if node:IsA("Model") and node.Name == exactName then return node end
        node = node.Parent
    end
    return nil
end

local function meatOwner(object)
    local node = object
    for _ = 1, 10 do
        if not node or node == Workspace then break end
        if MEAT_CONTAINERS[node.Name] then
            if object:IsA("Model") then return object end
            local model = object:FindFirstAncestorWhichIsA("Model")
            return model or object
        end
        local compact = compactName(node.Name)
        if compact == "meatchunk" or compact == "meatpiece" or compact == "chunkofmeat" then
            return node
        end
        node = node.Parent
    end
    return nil
end

local function boneOwner(object)
    local node = object
    for _ = 1, 10 do
        if not node or node == Workspace then break end
        if node:IsA("Model") and compactName(node.Name) == "bonepile" then return node end
        node = node.Parent
    end
    return nil
end

local function findPrompt(owner)
    if not owner or not owner.Parent then return nil end
    if owner:IsA("ProximityPrompt") then return owner end
    local prompt = owner:FindFirstChildWhichIsA("ProximityPrompt", true)
    if prompt then return prompt end
    local parent = owner.Parent
    if parent and parent ~= Workspace then
        for _, siblingName in ipairs({"Host", "Physics", "Visual", "Prompt", "Interaction"}) do
            local sibling = parent:FindFirstChild(siblingName)
            if sibling then
                prompt = sibling:FindFirstChildWhichIsA("ProximityPrompt", true)
                if prompt then return prompt end
            end
        end
    end
    return nil
end

local function bestAnchor(owner, prompt)
    if prompt and prompt.Parent and prompt.Parent:IsA("BasePart") then return prompt.Parent end
    if owner:IsA("BasePart") then return owner end
    if owner:IsA("Model") then
        return owner.PrimaryPart
            or owner:FindFirstChild("HumanoidRootPart", true)
            or owner:FindFirstChild("Body", true)
            or owner:FindFirstChildWhichIsA("BasePart", true)
    end
    return owner:FindFirstAncestorWhichIsA("BasePart")
end

local function classifyObject(object)
    if not object or not object.Parent or isCollectible(object) then return nil end

    local physics = exactAncestorModel(object, "Physics")
    if physics then
        local prompt = findPrompt(physics)
        return physics, "Corpse", prompt, bestAnchor(physics, prompt)
    end

    local host = exactAncestorModel(object, "Host")
    if host then
        local prompt = findPrompt(host)
        return host, "Corpse", prompt, bestAnchor(host, prompt)
    end

    local bone = boneOwner(object)
    if bone then
        local prompt = findPrompt(bone)
        return bone, "Bone", prompt, bestAnchor(bone, prompt)
    end

    local meat = meatOwner(object)
    if meat then
        local prompt = findPrompt(meat)
        return meat, "MeatChunk", prompt, bestAnchor(meat, prompt)
    end

    local node = object:IsA("Model") and object or object:FindFirstAncestorWhichIsA("Model")
    local name = tostring((node and node.Name) or object.Name)
    local compact = compactName(name)

    if compact == "deadfish" or compact == "fishcorpse" or compact == "fishmeat" then
        local owner = node or object
        local prompt = findPrompt(owner)
        return owner, "Fish", prompt, bestAnchor(owner, prompt)
    end

    if compact == "seashell" or compact == "seashells" or compact == "shellfish" then
        local owner = node or object
        local prompt = findPrompt(owner)
        return owner, "Shell", prompt, bestAnchor(owner, prompt)
    end

    if compact:find("mussel", 1, true) then
        local owner = node or object
        local prompt = findPrompt(owner)
        return owner, "Mussel", prompt, bestAnchor(owner, prompt)
    end

    if compact == "anthill" or compact == "termitemound" then
        local owner = node or object
        local prompt = findPrompt(owner)
        return owner, "Anthill", prompt, bestAnchor(owner, prompt)
    end

    if hasWord(name, FRUIT_WORDS) then
        local owner = node or object
        local prompt = findPrompt(owner)
        return owner, "Fruit", prompt, bestAnchor(owner, prompt)
    end

    if hasWord(name, INSECT_WORDS) then
        local owner = node or object
        local prompt = findPrompt(owner)
        return owner, "Insect", prompt, bestAnchor(owner, prompt)
    end

    if hasWord(name, PLANT_WORDS)
        or CollectionService:HasTag(object, "ConsumableFoliage")
        or (node and CollectionService:HasTag(node, "ConsumableFoliage")) then
        local owner = node or object
        local prompt = findPrompt(owner)
        return owner, "Plant", prompt, bestAnchor(owner, prompt)
    end

    return nil
end

local function foodKey(owner)
    return owner
end

local function addFoodCandidate(object, destinationIndex)
    if App.HealingLock then return end
    local owner, kind, prompt, anchor = classifyObject(object)
    if not owner or not owner.Parent or not anchor then return end
    if owner == Workspace or owner.Name == "Workspace" or owner.Name == "Visual" then return end

    local key = foodKey(owner)
    local existing = destinationIndex[key] or App.FoodIndex[key]
    local food = existing or {
        Owner = owner,
        Kind = kind,
        Name = owner.Name,
        CreatedAt = tick(),
        MissingPromptSince = 0,
    }
    food.Kind = kind
    food.Name = kind == "Bone" and "BonePile" or owner.Name
    food.Prompt = prompt
    food.Anchor = anchor
    food.LastSeen = tick()
    food.Removed = false
    destinationIndex[key] = food
end

local function removeFoodOwner(owner)
    local food = App.FoodIndex[owner]
    if food then
        food.Removed = true
        App.FoodIndex[owner] = nil
        local marker = App.FoodESP[owner]
        safeDestroy(marker)
        App.FoodESP[owner] = nil
        if App.LockedTarget == food then App.LockedTarget = nil end
        if App.CurrentTarget == food then App.CurrentTarget = nil end
    end
end

local function likelyFoodNode(object)
    if not object or not object.Parent then return false end
    if object:IsA("ProximityPrompt") then return true end
    local compact = compactName(object.Name)
    if object:IsA("Model") then
        if object.Name == "Physics" or object.Name == "Host" then return true end
        if compact == "bonepile" or compact == "meatchunk" or compact == "meatpiece"
            or compact == "deadfish" or compact == "fishcorpse"
            or compact == "seashell" or compact == "seashells"
            or compact == "shellfish" or compact == "anthill"
            or compact == "termitemound" or compact:find("mussel", 1, true) then
            return true
        end
    end
    if CollectionService:HasTag(object, "ConsumableFoliage") then return true end
    if hasWord(object.Name, PLANT_WORDS) or hasWord(object.Name, FRUIT_WORDS) then return true end
    local parent = object.Parent
    return parent and MEAT_CONTAINERS[parent.Name] == true
end

local function fullReconcile()
    if App.ScanInProgress or App.HealingLock or App.Eating or App.Moving then return end
    App.ScanInProgress = true
    local started = tick()
    local snapshot = {}
    local descendants = Workspace:GetDescendants()
    local visited = 0
    for index, object in ipairs(descendants) do
        if App.Destroyed or App.HealingLock then break end
        if likelyFoodNode(object) then addFoodCandidate(object, snapshot) end
        visited += 1
        if index % App.Config.ScanBatch == 0 then task.wait() end
    end

    if not App.Destroyed and not App.HealingLock then
        App.FoodIndex = snapshot
        App.FoodIndexReady = true
        App.ScanVisited = visited
        App.LastScanDuration = tick() - started
    end
    App.ScanInProgress = false
end

connect(Workspace.DescendantAdded, function(object)
    if App.Destroyed or App.HealingLock then return end
    if likelyFoodNode(object) then
        task.defer(function()
            if object.Parent then addFoodCandidate(object, App.FoodIndex) end
        end)
    end
end)

connect(Workspace.DescendantRemoving, function(object)
    if App.Destroyed then return end
    if App.FoodIndex[object] then removeFoodOwner(object) end
end)

task.spawn(fullReconcile)

task.spawn(function()
    while not App.Destroyed do
        task.wait(App.Config.ReconcileSeconds)
        if not App.HealingLock and not App.Eating and not App.Moving then
            fullReconcile()
        end
    end
end)

-- ============================================================
-- FOOD ACTIVE / DEPLETION
-- ============================================================
local function refreshFood(food)
    if not food or food.Removed or not food.Owner or not food.Owner.Parent then return false end
    if not food.Anchor or not food.Anchor.Parent then
        food.Anchor = bestAnchor(food.Owner, food.Prompt)
    end
    if not food.Prompt or not food.Prompt.Parent then
        food.Prompt = findPrompt(food.Owner)
    end

    if food.Prompt and food.Prompt.Parent then
        food.MissingPromptSince = 0
        return food.Anchor ~= nil and food.Anchor.Parent ~= nil
    end

    if food.MissingPromptSince == 0 then food.MissingPromptSince = tick() end
    if tick() - food.MissingPromptSince >= App.Config.PromptMissingGrace then
        removeFoodOwner(food.Owner)
        return false
    end
    return true
end

local function foodPosition(food)
    return food and food.Anchor and food.Anchor.Parent and food.Anchor.Position or nil
end

local function foodDistance(food)
    local root = getRoot()
    local position = foodPosition(food)
    return root and position and (root.Position - position).Magnitude or math.huge
end

local function visiblePartsForFood(food)
    local parts = {}
    local function gather(container)
        if not container then return end
        if container:IsA("BasePart") then
            if container.Transparency < 0.95 and container.Size.Magnitude > 0.4 then table.insert(parts, container) end
            return
        end
        for _, part in ipairs(container:GetDescendants()) do
            if part:IsA("BasePart")
                and part.Transparency < 0.95
                and part.Size.Magnitude > 0.4
                and not compactName(part.Name):find("hitbox", 1, true)
                and compactName(part.Name) ~= "humanoidrootpart" then
                table.insert(parts, part)
            end
        end
    end

    gather(food.Owner)
    local parent = food.Owner and food.Owner.Parent
    if #parts == 0 and parent then
        gather(parent:FindFirstChild("Visual"))
        gather(parent:FindFirstChild("Host"))
        gather(parent:FindFirstChild("Physics"))
    end
    return parts
end

local function corpseSizeScore(food)
    if food.Kind ~= "Corpse" then return 0 end
    local parts = visiblePartsForFood(food)
    local volume = 0
    for _, part in ipairs(parts) do volume += part.Size.X * part.Size.Y * part.Size.Z end
    return math.min(500, math.pow(math.max(volume, 1), 1 / 3) * 6)
end

-- ============================================================
-- DINOSAUR / DANGER HELPERS
-- ============================================================
local function isDinosaurModel(model)
    if not model or not model:IsA("Model") or model == getCharacter() then return false end
    if model:GetAttribute("Species") or model:GetAttribute("Type") or model:GetAttribute("Stage") then
        return getRoot(model) ~= nil
    end
    return model:FindFirstChildOfClass("Humanoid") ~= nil and getRoot(model) ~= nil
end

local function modelSpecies(model)
    return tostring(model:GetAttribute("Species") or model:GetAttribute("Type") or model.Name)
end

local function modelDiet(model)
    local attribute = model:GetAttribute("Diet")
    if attribute then return tostring(attribute) end
    return CARNIVORES[modelSpecies(model)] and "Carnivore" or "Unknown"
end

local function modelStageRank(model)
    return STAGE_RANK[normalizeStage(
        model:GetAttribute("Stage") or model:GetAttribute("GrowthStage") or model:GetAttribute("LifeStage")
    )] or 1
end

local function nearbyDinosaurDanger(position, radius)
    local myRank = STAGE_RANK[getStage()] or 1
    local smallerOnly = true
    local count = 0
    for _, object in ipairs(Workspace:GetChildren()) do
        if isDinosaurModel(object) then
            local root = getRoot(object)
            if root then
                local distance = (root.Position - position).Magnitude
                if distance <= radius then
                    count += 1
                    local rank = modelStageRank(object)
                    if rank >= myRank then smallerOnly = false end
                    if modelDiet(object) == "Carnivore" and rank > STAGE_RANK.subadult then
                        return true, object, distance
                    end
                end
            end
        end
    end
    return false, nil, nil, smallerOnly, count
end

local function foodSafe(food)
    local position = foodPosition(food)
    if not position then return false end
    local danger, _, _, smallerOnly, count = nearbyDinosaurDanger(position, App.Config.DangerRadius)
    if danger then return false end
    if count > 0 and not smallerOnly and count > 2 then return false end
    return true
end

-- ============================================================
-- FOOD SELECTION
-- ============================================================
local function buildUsableFoods()
    local foods = {}
    local detected = 0
    for _, food in pairs(App.FoodIndex) do
        if refreshFood(food) then
            detected += 1
            if allowedKind(food.Kind) and foodSafe(food) then
                table.insert(foods, food)
            end
        end
    end
    App.DetectedCount = detected
    App.UsableCount = #foods
    return foods
end

local function candidateScore(food)
    local distance = foodDistance(food)
    if food.Kind == "Corpse" then distance -= corpseSizeScore(food) end
    return distance
end

local function chooseFood()
    if App.LockedTarget and refreshFood(App.LockedTarget) and allowedKind(App.LockedTarget.Kind) then
        return App.LockedTarget
    end
    App.LockedTarget = nil

    local foods = buildUsableFoods()
    local diet = getDiet()
    if #foods == 0 then return nil end

    if diet == "Carnivore" then
        -- Exact requested fallback order. Bones are chosen immediately whenever
        -- there is no usable Physics/Host corpse or meat chunk.
        for _, wantedKind in ipairs({"Corpse", "MeatChunk", "Bone", "Shell", "Fish"}) do
            local best, bestScore = nil, math.huge
            for _, food in ipairs(foods) do
                if food.Kind == wantedKind then
                    local score = candidateScore(food)
                    if score < bestScore then best, bestScore = food, score end
                end
            end
            if best then
                App.LockedTarget = best
                log(wantedKind == "Bone"
                    and "No corpse/meat found - selecting nearest BonePile"
                    or ("Selecting " .. wantedKind .. " target"))
                return best
            end
        end
        return nil
    end

    local best, bestScore = nil, math.huge
    for _, food in ipairs(foods) do
        local score
        if diet == "Herbivore" then
            score = foodDistance(food)
        else
            score = kindPriority(food.Kind) * 100000 + foodDistance(food)
        end
        if score < bestScore then best, bestScore = food, score end
    end
    App.LockedTarget = best
    return best
end

-- ============================================================
-- NOCLIP / COLLISION STATE
-- ============================================================
local function disableCharacterCollisions()
    local character = getCharacter()
    if not character then return nil end
    local state = {}
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            state[part] = part.CanCollide
            part.CanCollide = false
            part.AssemblyLinearVelocity = Vector3.zero
            part.AssemblyAngularVelocity = Vector3.zero
        end
    end
    return state
end

local function restoreCharacterCollisions(state)
    if type(state) ~= "table" then return end
    for part, canCollide in pairs(state) do
        if part and part.Parent then pcall(function() part.CanCollide = canCollide end) end
    end
end

local function cancelActiveTween()
    App.MovementToken += 1
    if App.ActiveTween then pcall(function() App.ActiveTween:Cancel() end) end
    disconnect(App.ActiveTweenConnection)
    safeDestroy(App.ActiveTweenValue)
    App.ActiveTween = nil
    App.ActiveTweenValue = nil
    App.ActiveTweenConnection = nil
end

-- ============================================================
-- VISIBLE FOOD DESTINATION (NO TERRAIN LAYER SEARCH)
-- ============================================================
local function characterHalfHeight()
    local character = getCharacter()
    if not character then return 4 end
    local _, size = character:GetBoundingBox()
    return math.max(3, size.Y * 0.5)
end

local function visibleFoodDestination(food)
    local root = getRoot()
    if not root then return nil, "no root" end
    local parts = visiblePartsForFood(food)
    local anchor = food.Anchor
    if #parts == 0 then
        if not anchor then return nil, "no visible food part" end
        return Vector3.new(anchor.Position.X, math.max(anchor.Position.Y + characterHalfHeight(), root.Position.Y - 5), anchor.Position.Z)
    end

    local reference = anchor and anchor.Position or root.Position
    local bestPart, bestDistance = nil, math.huge
    for _, part in ipairs(parts) do
        local horizontal = Vector3.new(part.Position.X - reference.X, 0, part.Position.Z - reference.Z).Magnitude
        if horizontal < bestDistance then bestPart, bestDistance = part, horizontal end
    end
    bestPart = bestPart or parts[1]

    local topY = bestPart.Position.Y + bestPart.Size.Y * 0.5
    local finalY = topY + characterHalfHeight() + 0.25

    -- Never dive into a lower cave/map layer for food whose visible body is above.
    -- A target requiring a drop larger than this is skipped instead of pulling the
    -- dinosaur beneath the current terrain level.
    if finalY < root.Position.Y - 45 then
        return nil, "food visible body is on a lower map layer"
    end

    return Vector3.new(bestPart.Position.X, finalY, bestPart.Position.Z)
end

local function highestNearbyDinosaurY()
    local highest = -math.huge
    for _, object in ipairs(Workspace:GetChildren()) do
        if isDinosaurModel(object) then
            local root = getRoot(object)
            if root then highest = math.max(highest, root.Position.Y) end
        end
    end
    return highest == -math.huge and 0 or highest
end

local function facingCFrame(position, targetPosition, fallbackLook)
    local look = Vector3.new(targetPosition.X, position.Y, targetPosition.Z)
    if (look - position).Magnitude < 0.1 then
        local direction = fallbackLook or Vector3.new(0, 0, -1)
        look = position + Vector3.new(direction.X, 0, direction.Z)
    end
    return CFrame.lookAt(position, look)
end

local function tweenCharacterTo(destination, targetPosition, speed, movementToken)
    local character = getCharacter()
    local root = getRoot(character)
    if not character or not root then return false end
    if movementToken ~= App.MovementToken or App.HealingLock or App.Eating then return false end

    local start = root.CFrame
    local goal = facingCFrame(destination, targetPosition, start.LookVector)
    local distance = (start.Position - destination).Magnitude
    local duration = math.max(0.05, distance / math.max(1, speed))

    local value = Instance.new("CFrameValue")
    value.Value = start
    App.ActiveTweenValue = value
    App.ActiveTweenConnection = value:GetPropertyChangedSignal("Value"):Connect(function()
        if App.Destroyed or movementToken ~= App.MovementToken or App.HealingLock or App.Eating then return end
        local currentCharacter = getCharacter()
        if currentCharacter then
            currentCharacter:PivotTo(value.Value)
            local currentRoot = getRoot(currentCharacter)
            if currentRoot then
                currentRoot.AssemblyLinearVelocity = Vector3.zero
                currentRoot.AssemblyAngularVelocity = Vector3.zero
            end
        end
    end)

    local tween = TweenService:Create(value, TweenInfo.new(duration, Enum.EasingStyle.Linear), {Value = goal})
    App.ActiveTween = tween
    tween:Play()
    tween.Completed:Wait()

    disconnect(App.ActiveTweenConnection)
    App.ActiveTweenConnection = nil
    safeDestroy(value)
    App.ActiveTweenValue = nil
    App.ActiveTween = nil

    return movementToken == App.MovementToken and not App.HealingLock and not App.Eating
end

local function moveToFood(food)
    if App.HealingLock or App.Eating or App.Moving then return false end
    if not refreshFood(food) then return false end

    local character = getCharacter()
    local root = getRoot(character)
    if not character or not root then return false end

    local destination, reason = visibleFoodDestination(food)
    if not destination then
        log("Food destination rejected: " .. tostring(reason) .. " - keeping target for retry")
        return false
    end

    local danger = nearbyDinosaurDanger(destination, App.Config.DangerRadius)
    if danger then
        log("Adult+ carnivore near food - waiting for safer opening")
        return false
    end

    App.Moving = true
    App.MovementToken += 1
    local token = App.MovementToken
    App.CurrentTarget = food
    App.LastProgress = tick()

    local collisionState = disableCharacterCollisions()
    root.Anchored = true
    local humanoid = getHumanoid(character)
    if humanoid then
        humanoid.PlatformStand = true
        humanoid.AutoRotate = false
    end

    local targetPosition = foodPosition(food) or destination
    local skyY = math.max(root.Position.Y, destination.Y, highestNearbyDinosaurY()) + App.Config.SkyClearance
    local phases = {
        {Position = Vector3.new(root.Position.X, skyY, root.Position.Z), Speed = App.Config.VerticalSpeed},
        {Position = Vector3.new(destination.X, skyY, destination.Z), Speed = App.Config.TweenSpeed},
        {Position = destination, Speed = App.Config.VerticalSpeed},
    }

    local success = true
    for _, phase in ipairs(phases) do
        if token ~= App.MovementToken or App.HealingLock or App.Eating or not refreshFood(food) then
            success = false
            break
        end
        log("Tweening to " .. food.Kind .. " at " .. tostring(math.floor(phase.Speed)) .. " studs/sec")
        if not tweenCharacterTo(phase.Position, targetPosition, phase.Speed, token) then
            success = false
            break
        end
    end

    if success then
        -- Keep correcting the SAME destination instead of cancelling verification.
        for attempt = 1, App.Config.ArrivalRetries do
            if token ~= App.MovementToken or App.HealingLock or not refreshFood(food) then
                success = false
                break
            end
            root = getRoot()
            if root and (root.Position - destination).Magnitude <= App.Config.ArrivalTolerance then break end
            log("Arrival resisted - retrying same food " .. attempt .. "/" .. App.Config.ArrivalRetries)
            if not tweenCharacterTo(destination, targetPosition, App.Config.VerticalSpeed, token) then
                success = false
                break
            end
        end
    end

    root = getRoot()
    if not root or (root.Position - destination).Magnitude > App.Config.ArrivalTolerance then
        success = false
    end

    if not success then
        cancelActiveTween()
        root = getRoot()
        if root then root.Anchored = false end
        if humanoid then
            humanoid.PlatformStand = false
            humanoid.AutoRotate = true
        end
        restoreCharacterCollisions(collisionState)
        App.Moving = false
        App.LastProgress = tick()
        -- Preserve the exact target. No blacklist and no usable-count collapse.
        App.LockedTarget = refreshFood(food) and food or nil
        return false
    end

    -- There is intentionally NO unanchored gap here. Eating takes ownership of
    -- the already-anchored root immediately, preventing falling or a mid-meal tween.
    App.CharacterCollisionState = collisionState
    App.MealRoot = root
    App.MealCFrame = root.CFrame
    App.Moving = false
    App.LastProgress = tick()
    return true
end

-- ============================================================
-- EATING: HARD MOVEMENT LOCK UNTIL FULL OR FOOD GONE
-- ============================================================
local function sendE(down)
    pcall(function()
        VirtualInputManager:SendKeyEvent(down, Enum.KeyCode.E, false, game)
    end)
end

local function holdThenClickE(prompt)
    if prompt and prompt.Parent and type(firePrompt) == "function" then
        pcall(function() firePrompt(prompt, math.max(0.1, tonumber(prompt.HoldDuration) or 2)) end)
    end

    sendE(true)
    task.wait(math.max(2.1, prompt and tonumber(prompt.HoldDuration) or 2.1))
    sendE(false)
    task.wait(0.12)
    for _ = 1, 2 do
        sendE(true)
        task.wait(0.08)
        sendE(false)
        task.wait(0.12)
    end
end

local function releaseMealLock()
    sendE(false)
    local root = App.MealRoot or getRoot()
    if root and root.Parent then
        root.Anchored = false
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end
    local humanoid = getHumanoid()
    if humanoid then
        humanoid.PlatformStand = false
        humanoid.AutoRotate = true
    end
    restoreCharacterCollisions(App.CharacterCollisionState)
    App.CharacterCollisionState = nil
    App.MealRoot = nil
    App.MealCFrame = nil
    App.Eating = false
    App.CurrentTarget = nil
    App.LastProgress = tick()
end

local function eatFood(food)
    if App.HealingLock or not refreshFood(food) then
        releaseMealLock()
        return false
    end

    cancelActiveTween()
    App.Eating = true
    App.Moving = false
    App.CurrentTarget = food
    App.LockedTarget = food
    local root = App.MealRoot or getRoot()
    if not root then
        releaseMealLock()
        return false
    end
    root.Anchored = true
    App.MealRoot = root
    App.MealCFrame = root.CFrame

    local startFood = select(1, getFoodStat())
    local lastFood = startFood
    local lastGainAt = tick()
    local lastRepositionAt = tick()
    local gained = false

    log("Arrived at " .. food.Kind .. " - holding E then clicking E until finished")

    while App.Running and not App.Destroyed and not App.HealingLock do
        if not refreshFood(food) then
            log("Food prompt/object gone - meal finished and ESP removed")
            break
        end

        local currentFood, maximumFood = getFoodStat()
        local percent = maximumFood > 0 and currentFood / maximumFood * 100 or 100
        if percent >= App.Config.FullFoodPct then
            gained = true
            log("Dinosaur is full - meal complete")
            break
        end

        if App.WasHit then break end

        -- Hard lock: no tween, verification, scanner recovery, pacing or unstuck
        -- routine is permitted to move the dinosaur while this loop is active.
        root = getRoot()
        if root then
            root.Anchored = true
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            if App.MealCFrame and (root.Position - App.MealCFrame.Position).Magnitude > 2 then
                getCharacter():PivotTo(App.MealCFrame)
            end
        end

        food.Prompt = food.Prompt and food.Prompt.Parent and food.Prompt or findPrompt(food.Owner)
        if not food.Prompt then
            task.wait(0.2)
            continue
        end

        holdThenClickE(food.Prompt)
        App.LastProgress = tick()

        local afterFood = select(1, getFoodStat())
        if afterFood > lastFood + 0.05 then
            gained = true
            lastGainAt = tick()
            lastFood = afterFood
            log("Eating " .. food.Name .. " | " .. math.floor(afterFood) .. "/" .. math.floor(maximumFood))
        else
            -- Never abandon the food after a single failed E cycle. Continue the
            -- same Hold E -> Click E sequence and occasionally re-approach the same
            -- visible food without switching targets.
            if tick() - lastGainAt >= App.Config.NoGainRepositionSeconds
                and tick() - lastRepositionAt >= App.Config.NoGainRepositionSeconds then
                lastRepositionAt = tick()
                log("No food tick yet - retrying the SAME food interaction")
                local destination = visibleFoodDestination(food)
                if destination and root then
                    local targetPosition = foodPosition(food) or destination
                    local cf = facingCFrame(destination, targetPosition, root.CFrame.LookVector)
                    getCharacter():PivotTo(cf)
                    App.MealCFrame = cf
                    root.AssemblyLinearVelocity = Vector3.zero
                    root.AssemblyAngularVelocity = Vector3.zero
                end
            end
        end
        task.wait(0.18)
    end

    releaseMealLock()
    if not refreshFood(food) then
        App.LockedTarget = nil
    elseif select(1, getFoodStat()) >= select(2, getFoodStat()) * 0.995 then
        App.LockedTarget = nil
    else
        -- Damage is the only normal reason to interrupt an existing meal.
        App.LockedTarget = food
    end
    return gained
end

-- ============================================================
-- SAFE MODE: MOVE ONCE, THEN DO NOTHING BUT HEAL
-- ============================================================
local function pressKey(key)
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, key, false, game)
        task.wait(0.12)
        VirtualInputManager:SendKeyEvent(false, key, false, game)
    end)
end

local function safeGroundNear(origin, awayFrom)
    local direction = origin - (awayFrom or (origin - Vector3.new(1, 0, 0)))
    direction = Vector3.new(direction.X, 0, direction.Z)
    if direction.Magnitude < 0.1 then
        local angle = math.random() * math.pi * 2
        direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
    else
        direction = direction.Unit
    end

    local character = getCharacter()
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = character and {character} or {}
    params.IgnoreWater = false

    for ring = 1, 8 do
        local angle = (ring - 1) * math.pi / 4
        local rotated = CFrame.fromAxisAngle(Vector3.yAxis, angle):VectorToWorldSpace(direction)
        local xz = origin + rotated * App.Config.SafeDistance
        local castOrigin = Vector3.new(xz.X, origin.Y + 600, xz.Z)
        local result = Workspace:Raycast(castOrigin, Vector3.new(0, -1200, 0), params)
        if result and result.Normal.Y > 0.45 then
            local y = result.Position.Y + characterHalfHeight() + 0.5
            if y >= origin.Y - 100 and y <= origin.Y + 250 then
                local destination = Vector3.new(result.Position.X, y, result.Position.Z)
                local danger = nearbyDinosaurDanger(destination, 650)
                if not danger then return destination end
            end
        end
    end
    return App.LastSurfaceCFrame and App.LastSurfaceCFrame.Position or origin
end

local function enterSafeMode(reason, dangerPosition)
    if App.HealingLock or not App.SafeModeEnabled then return end
    App.HealingLock = true
    App.Healing = false
    App.WasHit = true
    App.ControllerToken += 1
    cancelActiveTween()

    if App.Eating then releaseMealLock() end
    App.Moving = false
    App.CurrentTarget = nil

    local character = getCharacter()
    local root = getRoot(character)
    if not character or not root then
        App.HealingLock = false
        return
    end

    local destination = safeGroundNear(root.Position, dangerPosition)
    local collisionState = disableCharacterCollisions()
    root.Anchored = true
    local cf = CFrame.new(destination) * (root.CFrame - root.CFrame.Position)

    -- Safe Mode uses an immediate replicated escape, not the normal food tween.
    for _ = 1, 8 do
        character:PivotTo(cf)
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        RunService.Heartbeat:Wait()
    end
    root.Anchored = false
    restoreCharacterCollisions(collisionState)

    App.Healing = true
    log("SAFE MODE: refuge reached - resting and sleeping until full HP")
    pressKey(Enum.KeyCode.R)
    task.wait(0.6)
    pressKey(Enum.KeyCode.Z)

    -- COMPLETE HEALING LOCK. Nothing else scans, tweens, targets, eats, paces,
    -- verifies, unstucks or rebuilds ESP while this loop owns the controller.
    while not App.Destroyed do
        local health, maxHealth = getHealthStat()
        if maxHealth > 0 and health >= maxHealth - 0.5 then break end
        task.wait(0.5)
    end

    if not App.Destroyed then
        log("SAFE MODE: full HP - waking with Z then R")
        pressKey(Enum.KeyCode.Z)
        task.wait(0.55)
        pressKey(Enum.KeyCode.R)
        task.wait(0.8)
    end

    App.Healing = false
    App.HealingLock = false
    App.WasHit = false
    App.LastProgress = tick()
    log("SAFE MODE complete - awake and resuming")
end

-- Confirmed health-loss monitor.
task.spawn(function()
    local previousHealth, previousMax = getHealthStat()
    local pendingLoss = nil
    while not App.Destroyed do
        task.wait(0.18)
        local health, maxHealth = getHealthStat()
        if maxHealth > 0 and previousMax > 0 and health < previousHealth - 0.5 then
            if pendingLoss and tick() - pendingLoss.Time <= 0.5 then
                local root = getRoot()
                local dangerPosition = root and root.Position or Vector3.zero
                task.spawn(enterSafeMode, "confirmed damage", dangerPosition)
                pendingLoss = nil
            else
                pendingLoss = {Time=tick(), Health=health}
            end
        elseif pendingLoss and health <= pendingLoss.Health + 0.1 and tick() - pendingLoss.Time >= 0.15 then
            local root = getRoot()
            local dangerPosition = root and root.Position or Vector3.zero
            task.spawn(enterSafeMode, "confirmed damage", dangerPosition)
            pendingLoss = nil
        elseif pendingLoss and health > pendingLoss.Health + 0.1 then
            pendingLoss = nil
        end
        previousHealth, previousMax = health, maxHealth
    end
end)

-- ============================================================
-- ESP
-- ============================================================
local FOOD_COLORS = {
    Corpse = Color3.fromRGB(255, 70, 55),
    MeatChunk = Color3.fromRGB(255, 100, 70),
    Bone = Color3.fromRGB(255, 150, 80),
    Shell = Color3.fromRGB(60, 255, 130),
    Fish = Color3.fromRGB(60, 190, 255),
    Plant = Color3.fromRGB(50, 255, 120),
    Fruit = Color3.fromRGB(255, 100, 220),
    Insect = Color3.fromRGB(255, 220, 50),
    Anthill = Color3.fromRGB(255, 190, 50),
}

local function makeFoodESP(food)
    if App.FoodESP[food.Owner] then return App.FoodESP[food.Owner] end
    local anchor = food.Anchor
    if not anchor or not anchor.Parent then return nil end
    local gui = Instance.new("BillboardGui")
    gui.Name = "PriorGrowthFoodESP"
    gui.Adornee = anchor
    gui.AlwaysOnTop = true
    gui.Size = UDim2.fromOffset(220, 50)
    gui.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
    gui.Parent = LocalPlayer:WaitForChild("PlayerGui")

    local label = Instance.new("TextLabel")
    label.Name = "Label"
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 14
    label.TextStrokeTransparency = 0.2
    label.TextColor3 = FOOD_COLORS[food.Kind] or Color3.new(1, 1, 1)
    label.TextWrapped = true
    label.Parent = gui

    App.FoodESP[food.Owner] = gui
    return gui
end

local function updateFoodESP()
    if App.HealingLock then return end
    if not App.FoodESPOn then
        clearTableInstances(App.FoodESP)
        return
    end

    local root = getRoot()
    if not root then return end
    local diet = getDiet()
    local shownPlants = 0

    for _, food in pairs(App.FoodIndex) do
        local active = refreshFood(food)
        local show = active and allowedKind(food.Kind)
        if show and diet ~= "Carnivore" and (food.Kind == "Plant" or food.Kind == "Fruit") then
            shownPlants += 1
            if shownPlants > App.Config.PlantESPMax then show = false end
        end

        if show then
            local gui = makeFoodESP(food)
            if gui then
                gui.Adornee = food.Anchor
                local label = gui:FindFirstChild("Label")
                if label then
                    local prefix = App.LockedTarget == food and "CURRENT TARGET\n" or ""
                    local name = food.Kind == "Corpse" and food.Owner.Name
                        or food.Kind == "Bone" and "BonePile"
                        or food.Name
                    label.Text = prefix .. string.upper(food.Kind) .. " | EDIBLE\n"
                        .. tostring(name) .. "\n" .. tostring(math.floor(foodDistance(food))) .. "st"
                    label.TextColor3 = FOOD_COLORS[food.Kind] or Color3.new(1, 1, 1)
                end
            end
        else
            safeDestroy(App.FoodESP[food.Owner])
            App.FoodESP[food.Owner] = nil
        end
    end

    for owner, gui in pairs(App.FoodESP) do
        if not App.FoodIndex[owner] or not owner.Parent then
            safeDestroy(gui)
            App.FoodESP[owner] = nil
        end
    end
end

task.spawn(function()
    while not App.Destroyed do
        task.wait(App.Config.FoodESPRefresh)
        pcall(updateFoodESP)
    end
end)

local function updateDinoESP()
    if App.HealingLock then return end
    if not App.DinoESPOn then
        clearTableInstances(App.DinoESP)
        return
    end

    local alive = {}
    for _, model in ipairs(Workspace:GetChildren()) do
        if isDinosaurModel(model) then
            alive[model] = true
            local root = getRoot(model)
            if root then
                local gui = App.DinoESP[model]
                if not gui then
                    gui = Instance.new("BillboardGui")
                    gui.Name = "PriorGrowthDinoESP"
                    gui.AlwaysOnTop = true
                    gui.Size = UDim2.fromOffset(220, 55)
                    gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
                    local label = Instance.new("TextLabel")
                    label.Name = "Label"
                    label.BackgroundTransparency = 1
                    label.Size = UDim2.fromScale(1, 1)
                    label.Font = Enum.Font.GothamBold
                    label.TextSize = 14
                    label.TextStrokeTransparency = 0.2
                    label.TextColor3 = modelDiet(model) == "Carnivore"
                        and Color3.fromRGB(255, 145, 35)
                        or Color3.fromRGB(80, 255, 130)
                    label.Parent = gui
                    App.DinoESP[model] = gui
                end
                gui.Adornee = root
                local label = gui:FindFirstChild("Label")
                if label then
                    label.Text = "DINOSAUR\n" .. modelSpecies(model) .. " "
                        .. normalizeStage(model:GetAttribute("Stage")) .. "\n"
                        .. math.floor((getRoot() and (getRoot().Position - root.Position).Magnitude) or 0) .. "st"
                end
            end
        end
    end
    for model, gui in pairs(App.DinoESP) do
        if not alive[model] or not model.Parent then
            safeDestroy(gui)
            App.DinoESP[model] = nil
        end
    end
end

task.spawn(function()
    while not App.Destroyed do
        task.wait(App.Config.DinoESPRefresh)
        pcall(updateDinoESP)
    end
end)

-- ============================================================
-- MAIN SINGLE CONTROLLER
-- ============================================================
local function hungerTrigger(maxFood)
    return maxFood >= App.Config.LargeTank and App.Config.HungerLarge or App.Config.HungerSmall
end

local function shouldStopAtStage()
    if App.StageStop == "Don't Stop" then return false end
    return getStage() == normalizeStage(App.StageStop) and getStageProgress() >= App.StopPct
end

local function controllerLoop(token)
    local hungryMode = false
    while App.Running and not App.Destroyed and token == App.ControllerToken do
        App.LastProgress = App.LastProgress or tick()

        if App.HealingLock then
            task.wait(0.4)
            continue
        end

        if shouldStopAtStage() then
            App.Running = false
            log("Target growth stage reached - Auto Growth stopped")
            break
        end

        local currentFood, maximumFood = getFoodStat()
        local percent = maximumFood > 0 and currentFood / maximumFood * 100 or 100
        local trigger = hungerTrigger(maximumFood)
        if not hungryMode and percent <= trigger then hungryMode = true end
        if hungryMode and percent >= App.Config.FullFoodPct then
            hungryMode = false
            App.LockedTarget = nil
            App.CurrentTarget = nil
        end

        if hungryMode then
            if not App.Moving and not App.Eating then
                local target = chooseFood()
                if target then
                    App.CurrentTarget = target
                    local arrived = moveToFood(target)
                    if arrived and refreshFood(target) and not App.HealingLock then
                        eatFood(target)
                    else
                        -- Never clear a still-valid target because one destination
                        -- attempt failed. Retry the same target on the next loop.
                        if refreshFood(target) then App.LockedTarget = target else App.LockedTarget = nil end
                        task.wait(0.35)
                    end
                else
                    log("No usable food currently indexed - waiting for Workspace events")
                    task.wait(0.8)
                end
            end
        else
            -- Light local walking only while not hungry. No teleporting and no
            -- terrain correction. Release every key before the next cycle.
            local humanoid = getHumanoid()
            local root = getRoot()
            if humanoid and root and not App.Moving and not App.Eating then
                humanoid:Move(root.CFrame.LookVector, false)
                task.wait(0.35)
                humanoid:Move(Vector3.zero, false)
            end
        end
        task.wait(0.15)
    end
end

local function startGrowth()
    if App.Running then return end
    App.Running = true
    App.ControllerToken += 1
    local token = App.ControllerToken
    App.LastProgress = tick()
    task.spawn(controllerLoop, token)
end

local function stopGrowth()
    App.Running = false
    App.ControllerToken += 1
    cancelActiveTween()
    if App.Eating then releaseMealLock() end
    App.Moving = false
    local humanoid = getHumanoid()
    if humanoid then humanoid:Move(Vector3.zero, false) end
    log("Auto Growth OFF")
end

-- Functional stall watchdog integrated into this full script.
task.spawn(function()
    local lastPosition = nil
    local lastFood = select(1, getFoodStat())
    while not App.Destroyed do
        task.wait(0.5)
        local root = getRoot()
        local position = root and root.Position or nil
        local currentFood, maximumFood = getFoodStat()
        local percent = maximumFood > 0 and currentFood / maximumFood * 100 or 100
        local hungry = percent <= hungerTrigger(maximumFood) or App.LockedTarget ~= nil

        if App.HealingLock or App.Eating then
            App.LastProgress = tick()
        else
            if position and lastPosition and (position - lastPosition).Magnitude >= 1.5 then
                App.LastProgress = tick()
            end
            if currentFood > lastFood + 0.05 then App.LastProgress = tick() end
            if App.CurrentTarget ~= App.LastTarget and App.CurrentTarget then App.LastProgress = tick() end

            if App.Running and hungry and tick() - App.LastProgress >= App.Config.StallSeconds then
                log("Controller stalled with usable food - forcing immediate retry")
                cancelActiveTween()
                App.Moving = false
                local rootNow = getRoot()
                if rootNow and not App.Eating then rootNow.Anchored = false end
                App.ControllerToken += 1
                local token = App.ControllerToken
                App.LastProgress = tick()
                task.spawn(controllerLoop, token)
            end
        end

        App.LastTarget = App.CurrentTarget
        lastPosition = position or lastPosition
        lastFood = currentFood
    end
end)

-- Keep a safe surface memory, but NEVER teleport or pull the character back.
task.spawn(function()
    while not App.Destroyed do
        task.wait(1)
        if not App.HealingLock and not App.Moving and not App.Eating then
            local root = getRoot()
            if root and math.abs(root.AssemblyLinearVelocity.Y) < 5 then
                App.LastSurfaceCFrame = root.CFrame
            end
        end
    end
end)

-- ============================================================
-- UI
-- ============================================================
local ACCENT = Color3.fromRGB(112, 116, 124)
local BG = Color3.fromRGB(17, 18, 21)
local CARD = Color3.fromRGB(29, 31, 36)
local TEXT = Color3.fromRGB(235, 235, 235)
local SUBTEXT = Color3.fromRGB(165, 169, 177)

local oldGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    and LocalPlayer.PlayerGui:FindFirstChild("PriorGrowthV75")
if oldGui then oldGui:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "PriorGrowthV75"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
App.Gui = gui

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.fromOffset(330, 470)
main.Position = UDim2.new(1, -355, 0.5, -235)
main.BackgroundColor3 = BG
main.BorderSizePixel = 0
main.Active = true
main.Draggable = true
main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 14)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -80, 0, 55)
title.Position = UDim2.fromOffset(18, 0)
title.BackgroundTransparency = 1
title.Text = "🦖  Prior Growth"
title.Font = Enum.Font.GothamBold
title.TextSize = 21
title.TextColor3 = TEXT
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = main

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.fromOffset(38, 38)
closeButton.Position = UDim2.new(1, -48, 0, 9)
closeButton.BackgroundColor3 = ACCENT
closeButton.Text = "×"
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 20
closeButton.TextColor3 = TEXT
closeButton.Parent = main
Instance.new("UICorner", closeButton).CornerRadius = UDim.new(0, 10)

local content = Instance.new("ScrollingFrame")
content.Size = UDim2.new(1, -20, 1, -68)
content.Position = UDim2.fromOffset(10, 58)
content.BackgroundTransparency = 1
content.BorderSizePixel = 0
content.ScrollBarThickness = 4
content.CanvasSize = UDim2.fromOffset(0, 700)
content.Parent = main

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.Parent = content

local function makeCard(height)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, -6, 0, height)
    frame.BackgroundColor3 = CARD
    frame.BorderSizePixel = 0
    frame.Parent = content
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
    return frame
end

local function makeToggle(text, initial, callback)
    local card = makeCard(48)
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -90, 1, 0)
    label.Position = UDim2.fromOffset(12, 0)
    label.BackgroundTransparency = 1
    label.Text = text
    label.Font = Enum.Font.GothamMedium
    label.TextSize = 14
    label.TextColor3 = TEXT
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = card

    local button = Instance.new("TextButton")
    button.Size = UDim2.fromOffset(62, 32)
    button.Position = UDim2.new(1, -72, 0.5, -16)
    button.BackgroundColor3 = ACCENT
    button.Font = Enum.Font.GothamBold
    button.TextSize = 13
    button.TextColor3 = TEXT
    button.Parent = card
    Instance.new("UICorner", button).CornerRadius = UDim.new(0, 9)

    local value = initial == true
    local function render() button.Text = value and "ON" or "OFF" end
    render()
    button.MouseButton1Click:Connect(function()
        value = not value
        render()
        callback(value)
        saveSettings()
    end)
    return button, function(newValue) value = newValue == true; render() end
end

local statusCard = makeCard(125)
local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -18, 1, -14)
statusLabel.Position = UDim2.fromOffset(9, 7)
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 12
statusLabel.TextWrapped = true
statusLabel.TextColor3 = SUBTEXT
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextYAlignment = Enum.TextYAlignment.Top
statusLabel.Parent = statusCard
App.StatusLabel = statusLabel

local _, setGrowthToggle = makeToggle("Auto Growth", false, function(enabled)
    if enabled then startGrowth() else stopGrowth() end
end)
App.SetGrowthToggle = setGrowthToggle

makeToggle("Food ESP", App.FoodESPOn, function(enabled)
    App.FoodESPOn = enabled
    if not enabled then clearTableInstances(App.FoodESP) end
end)

makeToggle("Dinosaur ESP", App.DinoESPOn, function(enabled)
    App.DinoESPOn = enabled
    if not enabled then clearTableInstances(App.DinoESP) end
end)

makeToggle("Damage Safe Mode", App.SafeModeEnabled, function(enabled)
    App.SafeModeEnabled = enabled
end)

local speedCard = makeCard(76)
local speedTitle = Instance.new("TextLabel")
speedTitle.Size = UDim2.new(1, -20, 0, 28)
speedTitle.Position = UDim2.fromOffset(10, 3)
speedTitle.BackgroundTransparency = 1
speedTitle.Text = "Tween Speed (50–1000 studs/sec)"
speedTitle.Font = Enum.Font.GothamMedium
speedTitle.TextSize = 13
speedTitle.TextColor3 = TEXT
speedTitle.TextXAlignment = Enum.TextXAlignment.Left
speedTitle.Parent = speedCard

local speedBox = Instance.new("TextBox")
speedBox.Size = UDim2.new(1, -20, 0, 34)
speedBox.Position = UDim2.fromOffset(10, 34)
speedBox.BackgroundColor3 = ACCENT
speedBox.Text = tostring(App.Config.TweenSpeed)
speedBox.PlaceholderText = "300"
speedBox.ClearTextOnFocus = false
speedBox.Font = Enum.Font.GothamBold
speedBox.TextSize = 14
speedBox.TextColor3 = TEXT
speedBox.Parent = speedCard
Instance.new("UICorner", speedBox).CornerRadius = UDim.new(0, 8)
speedBox.FocusLost:Connect(function()
    App.Config.TweenSpeed = math.clamp(
        tonumber(speedBox.Text) or App.Config.TweenSpeed,
        App.Config.TweenSpeedMin,
        App.Config.TweenSpeedMax
    )
    speedBox.Text = tostring(math.floor(App.Config.TweenSpeed))
    saveSettings()
end)

local rejoinCard = makeCard(48)
local rejoinButton = Instance.new("TextButton")
rejoinButton.Size = UDim2.new(1, -16, 1, -10)
rejoinButton.Position = UDim2.fromOffset(8, 5)
rejoinButton.BackgroundColor3 = ACCENT
rejoinButton.Text = "Rejoin This Exact Server"
rejoinButton.Font = Enum.Font.GothamBold
rejoinButton.TextSize = 14
rejoinButton.TextColor3 = TEXT
rejoinButton.Parent = rejoinCard
Instance.new("UICorner", rejoinButton).CornerRadius = UDim.new(0, 9)
rejoinButton.MouseButton1Click:Connect(function()
    log("Rejoining current server...")
    pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
    end)
end)

local rescanCard = makeCard(48)
local rescanButton = rejoinButton:Clone()
rescanButton.Text = "Refresh Whole Workspace Food Index"
rescanButton.Parent = rescanCard
rescanButton.MouseButton1Click:Connect(function()
    if not App.HealingLock and not App.Eating and not App.Moving then task.spawn(fullReconcile) end
end)

closeButton.MouseButton1Click:Connect(function()
    main.Visible = false
end)

connect(UserInputService.InputBegan, function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.RightShift then main.Visible = not main.Visible end
end)

-- UI status updater.
task.spawn(function()
    while not App.Destroyed do
        task.wait(0.4)
        pcall(function()
            local currentFood, maxFood = getFoodStat()
            local health, maxHealth = getHealthStat()
            local target = App.CurrentTarget or App.LockedTarget
            statusLabel.Text = "Dino: " .. getSpecies() .. " | " .. getDiet()
                .. "\nStage: " .. getStage() .. " " .. math.floor(getStageProgress()) .. "%"
                .. "\nFood: " .. math.floor(currentFood) .. "/" .. math.floor(maxFood)
                .. " | HP: " .. math.floor(health) .. "/" .. math.floor(maxHealth)
                .. "\nScanner: " .. App.UsableCount .. " usable / " .. App.DetectedCount .. " detected"
                .. " | " .. string.format("%.2fs", App.LastScanDuration)
                .. "\nTarget: " .. (target and (target.Kind .. " - " .. target.Name) or "None")
                .. "\nAction: " .. App.LastAction
            setGrowthToggle(App.Running)
        end)
    end
end)

-- Anti-AFK.
connect(LocalPlayer.Idled, function()
    pcall(function()
        VirtualUser:Button2Down(Vector2.new(0, 0), Camera.CFrame)
        task.wait(0.1)
        VirtualUser:Button2Up(Vector2.new(0, 0), Camera.CFrame)
    end)
end)

-- Character reset handling.
connect(LocalPlayer.CharacterAdded, function()
    cancelActiveTween()
    App.Moving = false
    App.Eating = false
    App.Healing = false
    App.HealingLock = false
    App.CurrentTarget = nil
    App.LockedTarget = nil
    App.LastProgress = tick()
    task.wait(2)
    task.spawn(fullReconcile)
end)

-- ============================================================
-- DESTROY
-- ============================================================
function App.Destroy()
    if App.Destroyed then return end
    App.Destroyed = true
    App.Running = false
    App.ControllerToken += 1
    cancelActiveTween()
    if App.Eating then releaseMealLock() end
    for _, connection in ipairs(App.Connections) do disconnect(connection) end
    clearTableInstances(App.FoodESP)
    clearTableInstances(App.DinoESP)
    safeDestroy(App.Gui)
    if ENV.PriorGrowthV75 == App then ENV.PriorGrowthV75 = nil end
end

print("[Prior Growth V75] FULL clean one-file controller loaded")
print("[Prior Growth V75] Physics + Host corpses | Meat chunks | SubAdult+ BonePile fallback")
print("[Prior Growth V75] No generated Parts, no void guard, no mid-meal tween")
