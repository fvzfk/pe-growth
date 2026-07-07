-- ============================================================
-- HackerAI | Prior Extinction Growth Automation v4.0 (FINAL)
-- Opiumware Compatible | One-Liner Ready
-- ============================================================

-- ⚠️ CHANGE THIS TO YOUR WEBHOOK URL BEFORE HOSTING
local WEBHOOK_URL = "https://discord.com/api/webhooks/1524160370107744306/1dMK69XbzTEOtjmJBO0hddaHL1NYdQGkwO8h-mP1N-pSBxYeHaUzLVA0798gvmxa88Ws"

-- Load compatibility layer
pcall(function() loadstring(game:HttpGet("https://raw.githubusercontent.com/luau/Executor-API-Docs/master/script/compatibility_layer.lua"))() end)

-- Load Linoria UI
local repo = 'https://raw.githubusercontent.com/wally-rblx/LinoriaLib/main/'
local Library = loadstring(game:HttpGet(repo .. 'Library.lua'))()
local ThemeManager = loadstring(game:HttpGet(repo .. 'addons/ThemeManager.lua'))()
local SaveManager = loadstring(game:HttpGet(repo .. 'addons/SaveManager.lua'))()

-- Services
local Players = game:GetService('Players')
local RunService = game:GetService('RunService')
local UserInputService = game:GetService('UserInputService')
local Workspace = game:GetService('Workspace')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Lighting = game:GetService('Lighting')
local VirtualUser = game:GetService('VirtualUser')
local VirtualInputManager = game:GetService('VirtualInputManager')
local HttpService = game:GetService('HttpService')
local TeleportService = game:GetService('TeleportService')
local CoreGui = game:GetService('CoreGui')

local LocalPlayer = Players.LocalPlayer
local Mouse = LocalPlayer:GetMouse()

-- ============================================================
-- STATE
-- ============================================================
local Connections = {}
local GrowthLoop = nil
local HealthMonitor = nil
local WebhookUpdateLoop = nil
local AutoGrowthRunning = false
local SafeModeActive = false
local circleAngle = 0
local lastSaveTime = tick()
local lastDrinkTime = tick()
local lastWebhookUpdate = 0

local CONFIG = {
    DinoName = 'Unknown',
    DinoSpecies = 'Unknown',
    DietType = 'Unknown',
    GrowthStage = 'Unknown',
    GrowthProgress = 0,
    MassMultiplier = 0,
    CurrentAction = 'Idle',
    FoodEaten = 0,
    SessionStartTime = tick(),
    LastServerHop = 0,
    ServerHopCooldown = 120,
    HealingActive = false,
    WebhookMessageId = nil,
    StopAtStage = "Don't Stop",
    CustomStopPercent = 100,
    ScanRange = 300,
    DangerRange = 300,
    EatDuration = 8,
    CircleDuration = 20,
    DrinkInterval = 30,
    SaveInterval = 90,
    AvoidPlayers = true,
    ServerHopMods = true,
    ServerHopRestart = true,
    AutoSave = true,
    NoFallDamage = true,
    SafeModeEnabled = true,
    InfiniteWater = true,
}

-- ============================================================
-- WEBHOOK SYSTEM (Single Embed, Live Updated)
-- ============================================================
local function sendWebhook(isEdit)
    local embed = {
        ['title'] = '🦖 Prior Extinction — Live Growth Monitor',
        ['color'] = SafeModeActive and 16711680 or 5763719,
        ['fields'] = {
            { ['name'] = '👤 Roblox User', ['value'] = LocalPlayer.Name, ['inline'] = true },
            { ['name'] = '🦕 Dinosaur', ['value'] = CONFIG.DinoName, ['inline'] = true },
            { ['name'] = '🍖 Diet', ['value'] = CONFIG.DietType, ['inline'] = true },
            { ['name'] = '📊 Stage', ['value'] = CONFIG.GrowthStage, ['inline'] = true },
            { ['name'] = '📈 Growth', ['value'] = string.format('%.1f%%', CONFIG.GrowthProgress), ['inline'] = true },
            { ['name'] = '⚡ Mass Mult', ['value'] = string.format('%.1f%%', CONFIG.MassMultiplier), ['inline'] = true },
            { ['name'] = '🔄 Status', ['value'] = CONFIG.CurrentAction, ['inline'] = false },
            { ['name'] = '🍗 Food Eaten', ['value'] = tostring(CONFIG.FoodEaten), ['inline'] = true },
            { ['name'] = '⏱ Session', ['value'] = string.format('%.0f min', (tick() - CONFIG.SessionStartTime) / 60), ['inline'] = true },
            { ['name'] = '📍 Server', ['value'] = game.JobId:sub(1, 12) .. '...', ['inline'] = true },
        },
        ['footer'] = { ['text'] = 'HackerAI Growth Automation v4.0 | Updates every 15s' },
        ['timestamp'] = DateTime.now():ToIsoDate(),
    }

    local payload = {
        ['username'] = 'Prior Extinction Monitor',
        ['embeds'] = { embed },
    }

    local body = HttpService:JSONEncode(payload)

    -- Try request() first (UNC standard — needed to get response body for message ID)
    local reqFunc = request or http_request or (syn and syn.request)
    if reqFunc then
        if isEdit and CONFIG.WebhookMessageId then
            -- PATCH to edit existing message
            pcall(function()
                reqFunc({
                    Url = WEBHOOK_URL .. "/messages/" .. CONFIG.WebhookMessageId,
                    Method = "PATCH",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = body,
                })
            end)
        else
            -- POST to create new message
            local success, response = pcall(function()
                return reqFunc({
                    Url = WEBHOOK_URL,
                    Method = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body = body,
                })
            end)
            if success and response and response.Body then
                local ok, data = pcall(function()
                    return HttpService:JSONDecode(response.Body)
                end)
                if ok and data and data.id then
                    CONFIG.WebhookMessageId = data.id
                    print('[HackerAI] Webhook message created: ' .. data.id)
                end
            end
        end
    else
        -- Fallback: HttpService (can't get message ID, so just POST)
        pcall(function()
            HttpService:PostAsync(WEBHOOK_URL, body, Enum.HttpContentType.ApplicationJson)
        end)
    end
end

local function updateWebhook()
    if tick() - lastWebhookUpdate < 15 then return end -- Rate limit: every 15s
    lastWebhookUpdate = tick()

    if CONFIG.WebhookMessageId then
        sendWebhook(true) -- Edit existing
    else
        sendWebhook(false) -- Create new
    end
end

-- ============================================================
-- DIET AUTO-DETECTION
-- ============================================================
local function detectDiet()
    local char = LocalPlayer.Character
    local diet = 'Unknown'

    -- Method 1: Check character attributes/values for diet info
    if char then
        for _, v in ipairs(char:GetDescendants()) do
            local n = v.Name:lower()
            if (v:IsA('StringValue') or v:IsA('StringValue') or v:GetAttribute('Diet')) then
                local val = ''
                if v:IsA('StringValue') then val = v.Value:lower() end
                if n:find('diet') then
                    if val:find('carn') then return 'Carnivore', val end
                    if val:find('herb') then return 'Herbivore', val end
                    if val:find('omni') or val:find('pisci') then return 'Omnivore', val end
                end
            end
        end
        -- Check attributes
        local attrDiet = char:GetAttribute('Diet') or char:GetAttribute('diet')
        if attrDiet then
            attrDiet = tostring(attrDiet):lower()
            if attrDiet:find('carn') then return 'Carnivore', attrDiet end
            if attrDiet:find('herb') then return 'Herbivore', attrDiet end
            if attrDiet:find('omni') or attrDiet:find('pisci') then return 'Omnivore', attrDiet end
        end
    end

    -- Method 2: Scan ReplicatedStorage for dinosaur data tables
    local dinoDataPaths = {'Dinosaurs', 'DinoData', 'Species', 'Creatures', 'Data', 'Mobs', 'Stats'}
    for _, folderName in ipairs(dinoDataPaths) do
        local folder = ReplicatedStorage:FindFirstChild(folderName)
        if folder then
            for _, v in ipairs(folder:GetDescendants()) do
                local n = v.Name:lower()
                if n:find('diet') and (v:IsA('StringValue') or v:IsA('Attribute')) then
                    local val = (v.Value or tostring(v)):lower()
                    if val:find('carn') then return 'Carnivore', val end
                    if val:find('herb') then return 'Herbivore', val end
                    if val:find('omni') or val:find('pisci') then return 'Omnivore', val end
                end
            end
        end
    end

    -- Method 3: Check wellbeing GUI for diet text
    for _, v in ipairs(CoreGui:GetDescendants()) do
        if v:IsA('TextLabel') then
            local t = v.Text:lower()
            if t:find('carnivore') then return 'Carnivore', t end
            if t:find('herbivore') then return 'Herbivore', t end
            if t:find('omnivore') or t:find('piscivore') then return 'Omnivore', t end
        end
    end

    -- Method 4: Known dinosaur species lookup
    local knownDinos = {
        ['tyrannosaurus'] = 'Carnivore', ['rex'] = 'Carnivore', ['t.rex'] = 'Carnivore',
        ['giganotosaurus'] = 'Carnivore', ['spinosaurus'] = 'Carnivore', ['carcharodontosaurus'] = 'Carnivore',
        ['allosaurus'] = 'Carnivore', ['ceratosaurus'] = 'Carnivore', ['carnotaurus'] = 'Carnivore',
        ['utahraptor'] = 'Carnivore', ['deinonychus'] = 'Carnivore', ['dilophosaurus'] = 'Carnivore',
        ['megalosaurus'] = 'Carnivore', ['torvosaurus'] = 'Carnivore', ['acrocanthosaurus'] = 'Carnivore',
        ['triceratops'] = 'Herbivore', ['trike'] = 'Herbivore', ['stegosaurus'] = 'Herbivore',
        ['ankylosaurus'] = 'Herbivore', ['diplodocus'] = 'Herbivore', ['apatosaurus'] = 'Herbivore',
        ['brachiosaurus'] = 'Herbivore', ['parasaurolophus'] = 'Herbivore', ['iguanodon'] = 'Herbivore',
        ['pterosaur'] = 'Carnivore', ['pteranodon'] = 'Carnivore', ['pterodactyl'] = 'Carnivore',
        ['deinocheirus'] = 'Omnivore', ['therizinosaurus'] = 'Herbivore', ['gallimimus'] = 'Omnivore',
        ['oviraptor'] = 'Omnivore', ['ornithomimus'] = 'Omnivore', ['struthiomimus'] = 'Omnivore',
        ['baryonyx'] = 'Carnivore', ['suchomimus'] = 'Carnivore', ['sarcosuchus'] = 'Carnivore',
        ['deinosuchus'] = 'Carnivore', ['mosasaurus'] = 'Carnivore', ['plesiosaurus'] = 'Carnivore',
        ['kentro'] = 'Herbivore', ['kentrosaurus'] = 'Herbivore', ['styracosaurus'] = 'Herbivore',
        ['pachycephalosaurus'] = 'Herbivore', ['pachy'] = 'Herbivore', ['lambeosaurus'] = 'Herbivore',
        ['corythosaurus'] = 'Herbivore', ['edmontosaurus'] = 'Herbivore', ['maiasaura'] = 'Herbivore',
        ['saurolophus'] = 'Herbivore', ['amargasaurus'] = 'Herbivore', ['camarasaurus'] = 'Herbivore',
        ['euoplocephalus'] = 'Herbivore', ['polacanthus'] = 'Herbivore', ['gastonia'] = 'Herbivore',
        ['majangasuchus'] = 'Carnivore', ['mahajanga'] = 'Carnivore',
        ['protoceratops'] = 'Herbivore', ['psittacosaurus'] = 'Herbivore',
    }

    -- Get character model name and check against known list
    if char then
        local modelName = char.Name:lower()
        for dinoName, dinoDiet in pairs(knownDinos) do
            if modelName:find(dinoName) then
                return dinoDiet, dinoName
            end
        end

        -- Also check the character's primary part name
        local hrp = char:FindFirstChild('HumanoidRootPart')
        if hrp then
            for _, v in ipairs(char:GetChildren()) do
                local childName = v.Name:lower()
                for dinoName, dinoDiet in pairs(knownDinos) do
                    if childName:find(dinoName) then
                        return dinoDiet, dinoName
                    end
                end
            end
        end
    end

    -- Method 5: Check PlayerGui for species name
    local playerGui = LocalPlayer:FindFirstChild('PlayerGui')
    if playerGui then
        for _, v in ipairs(playerGui:GetDescendants()) do
            if v:IsA('TextLabel') then
                local t = v.Text:lower()
                for dinoName, dinoDiet in pairs(knownDinos) do
                    if t:find(dinoName) then
                        return dinoDiet, t
                    end
                end
            end
        end
    end

    return 'Unknown', 'Unknown'
end

local function detectDinoName()
    local char = LocalPlayer.Character
    if not char then return 'Unknown' end

    -- Check character name
    local name = char.Name
    if name and name ~= 'Model' and name ~= 'StarterCharacter' then
        -- Try to get a cleaner name
        for _, v in ipairs(char:GetChildren()) do
            if v:IsA('Model') or v:IsA('StringValue') then
                if v.Name ~= 'HumanoidRootPart' and v.Name ~= 'Humanoid' and v.Name ~= 'Head' then
                    local n = v.Name
                    if n:find('saurus') or n:find('raptor') or n:find('don') or n:find('tops') or n:find('chus') then
                        return n
                    end
                end
            end
        end
        return name
    end

    -- Check GUI for species
    local playerGui = LocalPlayer:FindFirstChild('PlayerGui')
    if playerGui then
        for _, v in ipairs(playerGui:GetDescendants()) do
            if v:IsA('TextLabel') then
                local t = v.Text
                if t:find('saurus') or t:find('raptor') or t:find('don') or t:find('tops') or t:find('chus') then
                    return t
                end
            end
        end
    end

    return 'Unknown'
end

-- ============================================================
-- GROWTH STAGE DETECTION
-- ============================================================
local function detectGrowthStage()
    -- Try to read from GUI
    local stages = { 'Hatchling', 'Juvenile', 'Teen', 'Sub-Adult', 'Sub Adult', 'Adult', 'Elder', 'Baby' }
    for _, v in ipairs(CoreGui:GetDescendants()) do
        if v:IsA('TextLabel') then
            for _, stage in ipairs(stages) do
                if v.Text:lower():find(stage:lower()) and #v.Text < 50 then
                    return stage
                end
            end
        end
    end

    local playerGui = LocalPlayer:FindFirstChild('PlayerGui')
    if playerGui then
        for _, v in ipairs(playerGui:GetDescendants()) do
            if v:IsA('TextLabel') then
                for _, stage in ipairs(stages) do
                    if v.Text:lower():find(stage:lower()) and #v.Text < 50 then
                        return stage
                    end
                end
            end
        end
    end

    return CONFIG.GrowthStage
end

local function detectGrowthProgress()
    -- Try to parse percentage from GUI labels
    local searchAreas = { CoreGui, LocalPlayer:FindFirstChild('PlayerGui') }
    for _, area in ipairs(searchAreas) do
        if area then
            for _, v in ipairs(area:GetDescendants()) do
                if v:IsA('TextLabel') then
                    local pct = v.Text:match('(%d+%.?%d*)%%')
                    if pct then
                        local num = tonumber(pct)
                        if num and num <= 100 then
                            return num
                        end
                    end
                end
            end
        end
    end
    return CONFIG.GrowthProgress
end

-- ============================================================
-- FOOD DETECTION (Corpses, Plants, Player Corpses)
-- ============================================================
local function findAllFood(range)
    local results = {}
    local char = LocalPlayer.Character
    if not char then return results end
    local hrp = char:FindFirstChild('HumanoidRootPart')
    if not hrp then return results end
    local pos = hrp.Position

    -- Carnivore food terms
    local carniTerms = {
        'corpse', 'body', 'dead', 'remains', 'carcass', 'bone', 'skeleton',
        'meat', 'ragdoll', 'food_carn', 'carrion', 'flesh', 'kill', 'prey'
    }

    -- Herbivore food terms
    local herbiTerms = {
        'plant', 'bush', 'berry', 'flower', 'grass', 'leaf', 'fern',
        'vegetation', 'tree_food', 'fruit', 'food_herb', 'foliage', 'shoot',
        'reed', 'moss', 'algae', 'seed', 'nut', 'root', 'trunk'
    }

    -- Determine which terms to search based on diet
    local dietLower = CONFIG.DietType:lower()
    local terms = {}
    if dietLower:find('carn') then
        terms = carniTerms
    elseif dietLower:find('herb') then
        terms = herbiTerms
    elseif dietLower:find('omni') then
        -- Omnivore: search both
        for _, t in ipairs(carniTerms) do table.insert(terms, t) end
        for _, t in ipairs(herbiTerms) do table.insert(terms, t) end
    else
        -- Unknown diet: search everything
        for _, t in ipairs(carniTerms) do table.insert(terms, t) end
        for _, t in ipairs(herbiTerms) do table.insert(terms, t) end
    end

    -- Scan workspace for food objects
    for _, v in ipairs(Workspace:GetDescendants()) do
        if v:IsA('BasePart') or v:IsA('Model') then
            local n = v.Name:lower()
            local matched = false
            for _, term in ipairs(terms) do
                if n:find(term) then matched = true break end
            end

            -- Skip our own character
            if v:IsDescendantOf(char) then matched = false end

            if matched then
                local vPos = nil
                if v:IsA('Model') then
                    local ref = v:FindFirstChild('HumanoidRootPart') or v:FindFirstChildWhichIsA('BasePart')
                    if ref then vPos = ref.Position end
                    if not vPos and v.PrimaryPart then vPos = v.PrimaryPart.Position end
                else
                    vPos = v.Position
                end

                if vPos then
                    local dist = (vPos - pos).Magnitude
                    if dist <= range then
                        table.insert(results, {
                            Instance = v,
                            Position = vPos,
                            Distance = dist,
                            Type = 'Food'
                        })
                    end
                end
            end
        end
    end

    -- ALSO SCAN FOR DEAD PLAYER DINO CORPSES
    -- These are player characters or models with dead humanoids
    for _, v in ipairs(Workspace:GetChildren()) do
        if v:IsA('Model') and not v:IsDescendantOf(char) then
            local hum = v:FindFirstChildOfClass('Humanoid')
            if hum and hum.Health <= 0 then
                -- This is a dead dino/player corpse
                local ref = v:FindFirstChild('HumanoidRootPart') or v:FindFirstChildWhichIsA('BasePart')
                if ref then
                    local dist = (ref.Position - pos).Magnitude
                    if dist <= range then
                        -- Check it's not our own corpse
                        local isOurs = false
                        for _, player in ipairs(Players:GetPlayers()) do
                            if player.Character == v and player == LocalPlayer then
                                isOurs = true
                                break
                            end
                        end
                        if not isOurs then
                            table.insert(results, {
                                Instance = v,
                                Position = ref.Position,
                                Distance = dist,
                                Type = 'Player Corpse'
                            })
                        end
                    end
                end
            end
        end
    end

    -- Check for dead player characters specifically (even if health > 0 but state is dead)
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character then
            local hum = player.Character:FindFirstChildOfClass('Humanoid')
            if hum then
                local isDead = hum.Health <= 0 or hum:GetState() == Enum.HumanoidStateType.Dead
                if isDead then
                    local ref = player.Character:FindFirstChild('HumanoidRootPart')
                    if ref then
                        local dist = (ref.Position - pos).Magnitude
                        if dist <= range then
                            table.insert(results, {
                                Instance = player.Character,
                                Position = ref.Position,
                                Distance = dist,
                                Type = 'Player Corpse'
                            })
                        end
                    end
                end
            end
        end
    end

    -- Sort by distance
    table.sort(results, function(a, b) return a.Distance < b.Distance end)
    return results
end

-- ============================================================
-- SAFETY HELPERS
-- ============================================================
local function getDinoHealth()
    local char = LocalPlayer.Character
    if not char then return 0, 100 end
    local hum = char:FindFirstChildOfClass('Humanoid')
    if not hum then return 0, 100 end
    return hum.Health, hum.MaxHealth
end

local function teleportTo(pos)
    local char = LocalPlayer.Character
    if char and char:FindFirstChild('HumanoidRootPart') then
        char:SetPrimaryPartCFrame(CFrame.new(pos))
        char.HumanoidRootPart.Velocity = Vector3.new()
    end
end

local function findSafeSkyPosition()
    local char = LocalPlayer.Character
    if not char or not char:FindFirstChild('HumanoidRootPart') then return Vector3.new(0, 1000, 0) end
    local pos = char.HumanoidRootPart.Position
    return Vector3.new(pos.X, pos.Y + 1000, pos.Z)
end

local function findSafeGroundPosition()
    local startPos = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild('HumanoidRootPart') and
                     LocalPlayer.Character.HumanoidRootPart.Position or Vector3.new(0, 50, 0)

    for i = 1, 15 do
        local angle = math.random() * math.pi * 2
        local dist = 500 + math.random() * 2000
        local testPos = startPos + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)

        local ray = Ray.new(testPos + Vector3.new(0, 500, 0), Vector3.new(0, -1000, 0))
        local hit, hitPos = Workspace:FindPartOnRay(ray, LocalPlayer.Character)
        local groundPos = hit and hitPos or testPos

        local safe = true
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild('HumanoidRootPart') then
                if (player.Character.HumanoidRootPart.Position - groundPos).Magnitude < 2000 then
                    safe = false
                    break
                end
            end
        end

        if safe then
            return groundPos + Vector3.new(0, 10, 0)
        end
    end

    return findSafeSkyPosition()
end

local function isPositionSafe(pos, range)
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character and player.Character:FindFirstChild('HumanoidRootPart') then
            if (player.Character.HumanoidRootPart.Position - pos).Magnitude < range then
                return false, player.Name
            end
        end
    end
    return true, nil
end

local function checkModerators()
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local n = player.Name:lower()
            if n:find('mod') or n:find('admin') or n:find('staff') or n:find('cm') or n:find('gm') then
                return true, player.Name
            end
        end
    end
    return false, nil
end

local function checkServerRestart()
    for _, v in ipairs(CoreGui:GetDescendants()) do
        if v:IsA('TextLabel') then
            local t = v.Text:lower()
            if t:find('restart') or t:find('shutdown') or t:find('server will') then
                return true
            end
        end
    end
    return false
end

local function serverHop()
    if tick() - CONFIG.LastServerHop < CONFIG.ServerHopCooldown then return end

    CONFIG.LastServerHop = tick()
    CONFIG.CurrentAction = 'Server hopping...'
    Library:Notify('🔄 Server hopping...')

    local placeId = game.PlaceId
    pcall(function()
        local success, servers = pcall(function()
            return HttpService:JSONDecode(game:HttpGet('https://games.roblox.com/v1/games/' .. placeId .. '/servers/Public?limit=100'))
        end)

        if success and servers and servers.data then
            local currentPlayers = #Players:GetPlayers()
            for _, server in ipairs(servers.data) do
                if server.id ~= game.JobId and server.playing > 0 and server.playing < server.maxPlayers then
                    if server.playing >= math.max(1, currentPlayers - 5) and server.playing <= currentPlayers + 5 then
                        TeleportService:TeleportToPlaceInstance(placeId, server.id, LocalPlayer)
                        return
                    end
                end
            end
            for _, server in ipairs(servers.data) do
                if server.id ~= game.JobId and server.playing < server.maxPlayers then
                    TeleportService:TeleportToPlaceInstance(placeId, server.id, LocalPlayer)
                    return
                end
            end
        end
    end)

    task.wait(2)
    TeleportService:Teleport(placeId, LocalPlayer)
end

-- ============================================================
-- KEY PRESS HELPERS
-- ============================================================
local function pressKey(key)
    pcall(function()
        VirtualInputManager:SendKeyEvent(true, key, false, game)
        task.wait(0.05)
        VirtualInputManager:SendKeyEvent(false, key, false, game)
    end)
end

-- ============================================================
-- EAT / DRINK
-- ============================================================
local EatRemote = nil
local WaterRemote = nil

local function findRemotes()
    for _, v in ipairs(ReplicatedStorage:GetDescendants()) do
        local n = v.Name:lower()
        if v:IsA('RemoteEvent') or v:IsA('UnreliableRemoteEvent') then
            if not EatRemote and (n:find('eat') or n:find('feed') or n:find('consum') or n:find('food')) then
                EatRemote = v
            end
            if not WaterRemote and (n:find('water') or n:find('drink') or n:find('thirst') or n:find('hydrat')) then
                WaterRemote = v
            end
        end
    end
end
findRemotes()

local function doEat(targetInstance)
    -- Method 1: Fire eat remote
    if EatRemote then
        pcall(function() EatRemote:FireServer(targetInstance) end)
    end

    -- Method 2: Proximity prompt
    if targetInstance then
        local searchList = targetInstance:IsA('Model') and targetInstance:GetDescendants() or { targetInstance }
        for _, v in ipairs(searchList) do
            if v:IsA('ProximityPrompt') then
                pcall(function()
                    v:InputHoldBegin()
                    task.wait(0.1)
                    v:InputHoldEnd()
                end)
            end
        end
    end

    -- Method 3: Virtual E key press (silent eat, no animation shown to others)
    pressKey(Enum.KeyCode.E)
end

local function doDrink()
    if WaterRemote then
        pcall(function() WaterRemote:FireServer() end)
    end
    pressKey(Enum.KeyCode.E)
end

-- ============================================================
-- SAFE MODE (Emergency teleport + heal)
-- ============================================================
local function enterSafeMode(reason)
    if SafeModeActive then return end
    if not CONFIG.SafeModeEnabled then return end

    SafeModeActive = true
    CONFIG.CurrentAction = '⚠️ SAFE MODE: ' .. reason
    CONFIG.HealingActive = true

    Library:Notify('⚠️ ' .. reason .. ' — Teleporting to safety!')

    -- Stop all movement
    local char = LocalPlayer.Character
    if char and char:FindFirstChild('HumanoidRootPart') then
        char.HumanoidRootPart.Velocity = Vector3.new()
    end

    -- Teleport 1000 studs into the sky
    local skyPos = findSafeSkyPosition()
    teleportTo(skyPos)
    task.wait(0.5)

    -- Rest (R key)
    pressKey(Enum.KeyCode.R)
    task.wait(0.5)

    -- Sleep (Z key)
    pressKey(Enum.KeyCode.Z)
    task.wait(0.5)

    -- Keep anchored in the sky
    if char and char:FindFirstChild('HumanoidRootPart') then
        char.HumanoidRootPart.Anchored = true
    end
end

local function exitSafeMode()
    SafeModeActive = false
    CONFIG.HealingActive = false
    CONFIG.CurrentAction = 'Healed! Resuming growth...'

    -- Unanchor
    local char = LocalPlayer.Character
    if char and char:FindFirstChild('HumanoidRootPart') then
        char.HumanoidRootPart.Anchored = false
    end

    -- Wake up: Z first (stop sleeping), then R (stand up)
    pressKey(Enum.KeyCode.Z)
    task.wait(0.5)
    pressKey(Enum.KeyCode.R)
    task.wait(0.5)

    -- Teleport to safe ground (2000 studs from any player)
    local groundPos = findSafeGroundPosition()
    teleportTo(groundPos)

    Library:Notify('✅ Fully healed! Resuming growth.')
end

-- ============================================================
-- DAMAGE DETECTION
-- ============================================================
local function setupDamageDetection()
    local char = LocalPlayer.Character
    if not char then return end

    local hum = char:FindFirstChildOfClass('Humanoid')
    if not hum then return end

    local lastHealth = hum.Health
    local lastCheck = tick()

    local dmgConn = hum:GetPropertyChangedSignal('Health'):Connect(function()
        if not AutoGrowthRunning then return end
        if not CONFIG.SafeModeEnabled then return end

        local currentHealth = hum.Health
        if currentHealth < lastHealth and currentHealth > 0 and tick() - lastCheck > 1 then
            lastCheck = tick()
            -- ANY damage triggers safe mode
            enterSafeMode('Damage taken (' .. string.format('%.0f', lastHealth - currentHealth) .. ' HP)')
        end
        lastHealth = currentHealth
    end)
    table.insert(Connections, dmgConn)
end

-- ============================================================
-- HEALTH MONITOR (checks if healed while in safe mode)
-- ============================================================
local function startHealthMonitor()
    if HealthMonitor then HealthMonitor:Disconnect() end

    HealthMonitor = RunService.Stepped:Connect(function()
        if not AutoGrowthRunning then
            if HealthMonitor then HealthMonitor:Disconnect() HealthMonitor = nil end
            return
        end

        local health, maxHealth = getDinoHealth()

        -- If in safe mode, check if fully healed
        if SafeModeActive and CONFIG.HealingActive then
            if health >= maxHealth and maxHealth > 0 then
                exitSafeMode()
            else
                CONFIG.CurrentAction = 'Healing... ' .. string.format('%.0f/%.0f HP', health, maxHealth)
            end
        end
    end)
    table.insert(Connections, HealthMonitor)
end

-- ============================================================
-- NO FALL DAMAGE
-- ============================================================
local fallConn = RunService.Stepped:Connect(function()
    if not CONFIG.NoFallDamage then return end
    local char = LocalPlayer.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass('Humanoid')
    if not hum then return end

    if hum:GetState() == Enum.HumanoidStateType.FallingDown or
       hum:GetState() == Enum.HumanoidStateType.Freefall then
        hum:ChangeState(Enum.HumanoidStateType.Running)
    end
end)
table.insert(Connections, fallConn)

-- ============================================================
-- SAVE FUNCTION
-- ============================================================
local function doSave()
    if not CONFIG.AutoSave then return end
    if tick() - lastSaveTime < CONFIG.SaveInterval then return end

    CONFIG.CurrentAction = 'Saving dino...'
    Library:Notify('💾 Saving... Teleporting to safety')

    -- Teleport to sky to save safely
    local skyPos = findSafeSkyPosition()
    teleportTo(skyPos)
    task.wait(1)

    -- Open menu wheel (M key)
    pressKey(Enum.KeyCode.M)
    task.wait(0.5)

    -- Try to find and click the menu/save button in the wheel
    local clicked = false
    for _, v in ipairs(CoreGui:GetDescendants()) do
        if (v:IsA('TextButton') or v:IsA('ImageButton')) and not clicked then
            local t = ''
            pcall(function() t = v.Text:lower() end)
            if t:find('menu') or t:find('save') or t:find('log') or t:find('confirm') then
                pcall(function()
                    local pos = v.AbsolutePosition + v.AbsoluteSize / 2
                    VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 0)
                    task.wait(0.05)
                    VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 0)
                    clicked = true
                end)
            end
        end
    end

    if not clicked then
        -- Try M again to confirm selection
        pressKey(Enum.KeyCode.M)
    end

    Library:Notify('⏳ Waiting 30s save timer...')
    CONFIG.CurrentAction = 'Saving (30s timer)'

    -- Wait for the 30-second safe-log timer
    task.wait(32)

    -- Close menu
    pressKey(Enum.KeyCode.M)
    task.wait(0.3)

    lastSaveTime = tick()
    CONFIG.CurrentAction = 'Saved!'
    Library:Notify('✅ Dino saved!')

    -- Teleport back to safe ground
    local groundPos = findSafeGroundPosition()
    teleportTo(groundPos)
end

-- ============================================================
-- WINDOW
-- ============================================================
local Window = Library:CreateWindow({
    Title = 'HackerAI | Prior Extinction Growth',
    Center = true,
    AutoShow = true,
    Size = UDim2.fromOffset(720, 580),
})

local Tabs = {
    Growth = Window:AddTab('Growth'),
    Safety = Window:AddTab('Safety'),
    Debug = Window:AddTab('Debug'),
    UI = Window:AddTab('UI Settings'),
}

-- ============================================================
-- GROWTH TAB
-- ============================================================
local G = Tabs.Growth:AddLeftGroupbox('Growth Automation')

G:AddLabel('MASTER TOGGLE — Full auto growth pipeline')
G:AddLabel('Diet is auto-detected. No manual selection needed.')

G:AddToggle('AutoGrowth', {
    Text = '▶ Auto Growth (Master Toggle)',
    Default = false,
    Tooltip = 'Full automation: eat → circle → save → heal → server hop',
})

G:AddDropdown('StopAtStage', {
    Values = { "Don't Stop", 'Juvenile', 'Teen', 'Sub-Adult', 'Adult', 'Elder', 'Custom %' },
    Default = 1,
    Text = 'Stop Growing At',
})

G:AddSlider('CustomStopPercent', {
    Text = 'Custom Stop %',
    Default = 100,
    Min = 1,
    Max = 100,
    Rounding = 1,
    Compact = false,
    Visible = false,
})

G:AddSlider('ScanRange', {
    Text = 'Food Scan Range',
    Default = 300,
    Min = 50,
    Max = 1000,
    Rounding = 1,
    Compact = false,
})

G:AddSlider('EatDuration', {
    Text = 'Eat Duration (seconds)',
    Default = 8,
    Min = 2,
    Max = 30,
    Rounding = 1,
    Compact = false,
})

G:AddSlider('CircleDuration', {
    Text = 'Circle Duration (seconds)',
    Default = 20,
    Min = 5,
    Max = 60,
    Rounding = 1,
    Compact = false,
})

G:AddToggle('InfiniteWater', {
    Text = 'Auto Drink (Infinite Water)',
    Default = true,
    Tooltip = 'Automatically drink to maintain hydration',
})

G:AddSlider('DrinkInterval', {
    Text = 'Drink Interval (seconds)',
    Default = 30,
    Min = 10,
    Max = 120,
    Rounding = 1,
    Compact = false,
})

local G2 = Tabs.Growth:AddRightGroupbox('Live Status')

local DietLabel = G2:AddLabel('Diet: Detecting...')
local DinoLabel = G2:AddLabel('Dino: Detecting...')
local StatusLabel = G2:AddLabel('Status: Stopped')
local ActionLabel = G2:AddLabel('Action: None')
local HealthLabel = G2:AddLabel('Health: --/--')
local FoodLabel = G2:AddLabel('Food Eaten: 0')
local SessionLabel = G2:AddLabel('Session: 0m')
local StageLabel = G2:AddLabel('Stage: Unknown')

Options.StopAtStage:OnChanged(function()
    CONFIG.StopAtStage = Options.StopAtStage.Value
    Options.CustomStopPercent:SetVisible(Options.StopAtStage.Value == 'Custom %')
end)

Options.CustomStopPercent:OnChanged(function()
    CONFIG.CustomStopPercent = Options.CustomStopPercent.Value
end)

Options.ScanRange:OnChanged(function() CONFIG.ScanRange = Options.ScanRange.Value end)
Options.EatDuration:OnChanged(function() CONFIG.EatDuration = Options.EatDuration.Value end)
Options.CircleDuration:OnChanged(function() CONFIG.CircleDuration = Options.CircleDuration.Value end)
Options.DrinkInterval:OnChanged(function() CONFIG.DrinkInterval = Options.DrinkInterval.Value end)
Options.InfiniteWater:OnChanged(function() CONFIG.InfiniteWater = Toggles.InfiniteWater.Value end)

-- ============================================================
-- SAFETY TAB
-- ============================================================
local S = Tabs.Safety:AddLeftGroupbox('Damage & Safety')

S:AddToggle('SafeModeEnabled', {
    Text = 'Emergency Safe Mode',
    Default = true,
    Tooltip = 'Teleport to sky + sleep to heal on ANY damage',
})

S:AddToggle('NoFallDamage', {
    Text = 'No Fall Damage',
    Default = true,
    Tooltip = 'Prevent all fall damage',
})

S:AddToggle('AvoidPlayers', {
    Text = 'Avoid Players Near Food',
    Default = true,
    Tooltip = 'Find food with no nearby players',
})

S:AddSlider('DangerRange', {
    Text = 'Danger Detection Range',
    Default = 300,
    Min = 50,
    Max = 500,
    Rounding = 1,
    Compact = false,
})

local S2 = Tabs.Safety:AddRightGroupbox('Server Safety')

S2:AddToggle('ServerHopMods', {
    Text = 'Server Hop on Moderators',
    Default = true,
    Tooltip = 'Auto hop if a moderator joins',
})

S2:AddToggle('ServerHopRestart', {
    Text = 'Server Hop on Restart',
    Default = true,
    Tooltip = 'Auto hop if server is restarting',
})

S2:AddToggle('AutoSave', {
    Text = 'Auto Save Dino',
    Default = true,
    Tooltip = 'Automatically save progress',
})

S2:AddSlider('SaveInterval', {
    Text = 'Save Interval (seconds)',
    Default = 90,
    Min = 30,
    Max = 600,
    Rounding = 1,
    Compact = false,
})

-- Sync safety toggles to CONFIG
Toggles.SafeModeEnabled:OnChanged(function() CONFIG.SafeModeEnabled = Toggles.SafeModeEnabled.Value end)
Toggles.NoFallDamage:OnChanged(function() CONFIG.NoFallDamage = Toggles.NoFallDamage.Value end)
Toggles.AvoidPlayers:OnChanged(function() CONFIG.AvoidPlayers = Toggles.AvoidPlayers.Value end)
Toggles.ServerHopMods:OnChanged(function() CONFIG.ServerHopMods = Toggles.ServerHopMods.Value end)
Toggles.ServerHopRestart:OnChanged(function() CONFIG.ServerHopRestart = Toggles.ServerHopRestart.Value end)
Toggles.AutoSave:OnChanged(function() CONFIG.AutoSave = Toggles.AutoSave.Value end)
Options.DangerRange:OnChanged(function() CONFIG.DangerRange = Options.DangerRange.Value end)
Options.SaveInterval:OnChanged(function() CONFIG.SaveInterval = Options.SaveInterval.Value end)

-- ============================================================
-- DEBUG TAB
-- ============================================================
local Dbg = Tabs.Debug:AddLeftGroupbox('Debug Tools')

Dbg:AddButton('Scan All Remotes', function()
    local count = 0
    for _, v in ipairs(ReplicatedStorage:GetDescendants()) do
        if v:IsA('RemoteEvent') or v:IsA('RemoteFunction') or v:IsA('UnreliableRemoteEvent') then
            count = count + 1
            print('[REMOTE] ' .. v.ClassName .. ' | ' .. v:GetFullName())
        end
    end
    Library:Notify('Found ' .. count .. ' remotes. Check F9.')
end)

Dbg:AddButton('Re-detect Diet & Dino', function()
    local diet, species = detectDiet()
    local name = detectDinoName()
    CONFIG.DietType = diet
    CONFIG.DinoName = name
    CONFIG.DinoSpecies = species
    Library:Notify('Diet: ' .. diet .. ' | Dino: ' .. name)
    print('[HackerAI] Diet: ' .. diet .. ' | Species: ' .. tostring(species) .. ' | Name: ' .. name)
end)

Dbg:AddButton('Force Save Now', function()
    lastSaveTime = 0
    doSave()
end)

Dbg:AddButton('Emergency Sky Teleport', function()
    teleportTo(findSafeSkyPosition())
    Library:Notify('Teleported to sky')
end)

Dbg:AddButton('Find Safe Ground (2000 studs)', function()
    teleportTo(findSafeGroundPosition())
    Library:Notify('Teleported to safe ground')
end)

Dbg:AddButton('Test Webhook', function()
    sendWebhook(false)
    Library:Notify('Webhook sent (new message)')
end)

Dbg:AddButton('Print State Info', function()
    print('=== HACKERAI STATE ===')
    print('AutoGrowth:', AutoGrowthRunning)
    print('SafeMode:', SafeModeActive)
    print('Diet:', CONFIG.DietType)
    print('Dino:', CONFIG.DinoName)
    print('Action:', CONFIG.CurrentAction)
    print('Food Eaten:', CONFIG.FoodEaten)
    local h, m = getDinoHealth()
    print('Health:', h, '/', m)
    print('Session:', string.format('%.0fm', (tick() - CONFIG.SessionStartTime) / 60))
    print('WebhookMsgId:', CONFIG.WebhookMessageId or 'None')
    print('=======================')
end)

-- ============================================================
-- GROWTH ENGINE
-- ============================================================
local function startGrowthEngine()
    if GrowthLoop then GrowthLoop:Disconnect() GrowthLoop = nil end

    AutoGrowthRunning = true
    CONFIG.SessionStartTime = tick()
    CONFIG.FoodEaten = 0
    lastSaveTime = tick()
    lastDrinkTime = tick()

    -- Detect diet and dino name
    local diet, species = detectDiet()
    local name = detectDinoName()
    CONFIG.DietType = diet
    CONFIG.DinoName = name
    CONFIG.DinoSpecies = species

    Library:Notify('🚀 Growth started | Diet: ' .. diet .. ' | Dino: ' .. name)

    -- Create initial webhook message
    sendWebhook(false)
    task.wait(1)

    -- State machine
    local state = 'search_food'
    local foodTarget = nil
    local eatTimer = 0
    local circleTimer = 0
    local detectionTimer = 0

    GrowthLoop = RunService.RenderStepped:Connect(function()
        if not Toggles.AutoGrowth.Value or Library.Unloaded then
            AutoGrowthRunning = false
            if GrowthLoop then GrowthLoop:Disconnect() GrowthLoop = nil end
            CONFIG.CurrentAction = 'Stopped'
            return
        end

        local char = LocalPlayer.Character
        if not char then CONFIG.CurrentAction = 'No character'; return end
        local hrp = char:FindFirstChild('HumanoidRootPart')
        if not hrp then CONFIG.CurrentAction = 'No HumanoidRootPart'; return end

        -- Re-detect diet every 10 seconds
        detectionTimer = detectionTimer + (1/60)
        if detectionTimer >= 10 then
            detectionTimer = 0
            local newDiet = detectDiet()
            if newDiet ~= 'Unknown' then CONFIG.DietType = newDiet end
            CONFIG.GrowthStage = detectGrowthStage()
            CONFIG.GrowthProgress = detectGrowthProgress()
        end

        -- EMERGENCY OVERRIDE: Safe mode takes priority
        if SafeModeActive then
            hrp.Velocity = Vector3.new()
            updateWebhook()
            return
        end

        -- CHECK SERVER RESTART
        if CONFIG.ServerHopRestart and checkServerRestart() and tick() - CONFIG.LastServerHop > CONFIG.ServerHopCooldown then
            CONFIG.CurrentAction = 'Server restarting, hopping...'
            lastSaveTime = 0
            doSave()
            task.wait(1)
            serverHop()
            return
        end

        -- CHECK MODERATORS
        if CONFIG.ServerHopMods then
            local hasMod, modName = checkModerators()
            if hasMod and tick() - CONFIG.LastServerHop > CONFIG.ServerHopCooldown then
                CONFIG.CurrentAction = 'Mod detected: ' .. modName
                lastSaveTime = 0
                doSave()
                Library:Notify('🚨 Mod detected: ' .. modName)
                task.wait(1)
                serverHop()
                return
            end
        end

        -- AUTO DRINK
        if CONFIG.InfiniteWater and tick() - lastDrinkTime > CONFIG.DrinkInterval then
            lastDrinkTime = tick()
            CONFIG.CurrentAction = 'Drinking...'
            doDrink()
            task.wait(0.2)
        end

        -- AUTO SAVE
        if CONFIG.AutoSave and tick() - lastSaveTime >= CONFIG.SaveInterval then
            doSave()
            return
        end

        -- CHECK STOP CONDITION
        if CONFIG.StopAtStage ~= "Don't Stop" then
            if CONFIG.StopAtStage == 'Custom %' then
                if CONFIG.GrowthProgress >= CONFIG.CustomStopPercent then
                    CONFIG.CurrentAction = 'Reached target growth %, stopping'
                    Toggles.AutoGrowth:SetValue(false)
                    return
                end
            elseif CONFIG.GrowthStage:lower():find(CONFIG.StopAtStage:lower()) then
                CONFIG.CurrentAction = 'Reached ' .. CONFIG.StopAtStage .. ', stopping'
                Toggles.AutoGrowth:SetValue(false)
                return
            end
        end

        -- === STATE MACHINE ===

        if state == 'search_food' then
            CONFIG.CurrentAction = 'Searching for food...'
            foodTarget = nil

            local foodList = findAllFood(CONFIG.ScanRange)

            if #foodList > 0 then
                -- If avoid players, find safe food
                if CONFIG.AvoidPlayers then
                    for _, food in ipairs(foodList) do
                        local safe, threatName = isPositionSafe(food.Position, CONFIG.DangerRange)
                        if safe then
                            foodTarget = food
                            break
                        end
                    end
                end
                -- Fallback to nearest if no safe food found
                if not foodTarget then
                    foodTarget = foodList[1]
                end

                state = 'move_to_food'
            else
                -- No food found, circle to maintain growth multiplier
                circleAngle = circleAngle + 0.05
                local center = hrp.Position
                local newPos = center + Vector3.new(math.cos(circleAngle) * 5, 0, math.sin(circleAngle) * 5)
                if (newPos - hrp.Position).Magnitude > 0 then
                    hrp.Velocity = (newPos - hrp.Position).Unit * 12
                end
                CONFIG.CurrentAction = 'No food found, circling...'
            end

        elseif state == 'move_to_food' then
            if not foodTarget then
                state = 'search_food'
                return
            end

            -- Re-verify food still exists
            if not foodTarget.Instance or not foodTarget.Instance.Parent then
                state = 'search_food'
                return
            end

            local dist = (foodTarget.Position - hrp.Position).Magnitude

            if dist < 5 then
                state = 'eating'
                eatTimer = 0
                CONFIG.CurrentAction = 'Eating...'
                hrp.Velocity = Vector3.new()
                doEat(foodTarget.Instance)
            else
                -- Walk to food (walking = best growth multiplier)
                local dir = (foodTarget.Position - hrp.Position).Unit
                hrp.Velocity = dir * 12
                CONFIG.CurrentAction = 'Walking to food (' .. string.format('%.0f', dist) .. ' studs)'
            end

        elseif state == 'eating' then
            eatTimer = eatTimer + (1/60)
            hrp.Velocity = Vector3.new()

            -- Eat every second
            if math.floor(eatTimer) > math.floor(eatTimer - (1/60)) then
                doEat(foodTarget and foodTarget.Instance)
                CONFIG.FoodEaten = CONFIG.FoodEaten + 1
            end

            -- Check if food still exists
            if foodTarget and (not foodTarget.Instance or not foodTarget.Instance.Parent) then
                state = 'search_food'
                eatTimer = 0
                return
            end

            if eatTimer >= CONFIG.EatDuration then
                state = 'full_circle'
                circleTimer = 0
                CONFIG.CurrentAction = 'Food full, circling for growth...'
            end

        elseif state == 'full_circle' then
            circleTimer = circleTimer + (1/60)

            -- Walk in circles (best mass gain multiplier)
            circleAngle = circleAngle + 0.04
            local center = hrp.Position
            local newPos = center + Vector3.new(math.cos(circleAngle) * 6, 0, math.sin(circleAngle) * 6)
            if (newPos - hrp.Position).Magnitude > 0 then
                hrp.Velocity = (newPos - hrp.Position).Unit * 12
            end
            CONFIG.CurrentAction = 'Circling (' .. string.format('%.0f', circleTimer) .. '/' .. CONFIG.CircleDuration .. 's)'

            if circleTimer >= CONFIG.CircleDuration then
                state = 'search_food'
                eatTimer = 0
                CONFIG.CurrentAction = 'Checking for more food...'
            end
        end

        -- UPDATE WEBHOOK (every 15s, edits the same message)
        updateWebhook()

        -- UPDATE GUI LABELS
        pcall(function()
            DietLabel:SetText('Diet: ' .. CONFIG.DietType)
            DinoLabel:SetText('Dino: ' .. CONFIG.DinoName)
            StatusLabel:SetText('Status: ' .. (AutoGrowthRunning and '🟢 Running' or '🔴 Stopped'))
            ActionLabel:SetText('Action: ' .. CONFIG.CurrentAction)
            local h, m = getDinoHealth()
            HealthLabel:SetText('Health: ' .. string.format('%.0f/%.0f', h, m))
            FoodLabel:SetText('Food Eaten: ' .. CONFIG.FoodEaten)
            SessionLabel:SetText('Session: ' .. string.format('%.0fm', (tick() - CONFIG.SessionStartTime) / 60))
            StageLabel:SetText('Stage: ' .. CONFIG.GrowthStage .. ' (' .. string.format('%.1f%%', CONFIG.GrowthProgress) .. ')')
        end)
    end)

    table.insert(Connections, GrowthLoop)
end

-- ============================================================
-- TOGGLE HANDLER
-- ============================================================
Toggles.AutoGrowth:OnChanged(function()
    if Toggles.AutoGrowth.Value then
        startGrowthEngine()
        startHealthMonitor()
    else
        AutoGrowthRunning = false
        if GrowthLoop then GrowthLoop:Disconnect() GrowthLoop = nil end
        if HealthMonitor then HealthMonitor:Disconnect() HealthMonitor = nil end

        local char = LocalPlayer.Character
        if char and char:FindFirstChild('HumanoidRootPart') then
            char.HumanoidRootPart.Velocity = Vector3.new()
            char.HumanoidRootPart.Anchored = false
        end

        CONFIG.CurrentAction = 'Stopped by user'
        Library:Notify('⏹ Growth stopped')

        -- Update webhook one last time
        updateWebhook()
    end
end)

-- ============================================================
-- CHARACTER ADDED
-- ============================================================
local function onCharacterAdded(char)
    task.wait(1)
    setupDamageDetection()

    -- Re-detect diet and dino name on respawn
    task.spawn(function()
        task.wait(2)
        local diet, species = detectDiet()
        local name = detectDinoName()
        if diet ~= 'Unknown' then CONFIG.DietType = diet end
        if name ~= 'Unknown' then CONFIG.DinoName = name end
        CONFIG.DinoSpecies = species
    end)
end

if LocalPlayer.Character then
    onCharacterAdded(LocalPlayer.Character)
end
LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

-- ============================================================
-- CLEANUP
-- ============================================================
local function cleanup()
    AutoGrowthRunning = false
    SafeModeActive = false

    for _, conn in ipairs(Connections) do
        pcall(function() conn:Disconnect() end)
    end
    Connections = {}

    if GrowthLoop then GrowthLoop:Disconnect() GrowthLoop = nil end
    if HealthMonitor then HealthMonitor:Disconnect() HealthMonitor = nil end

    local char = LocalPlayer.Character
    if char and char:FindFirstChild('HumanoidRootPart') then
        char.HumanoidRootPart.Velocity = Vector3.new()
        char.HumanoidRootPart.Anchored = false
    end

    CONFIG.CurrentAction = 'Unloaded'
    updateWebhook()
    Library:Notify('Script unloaded')
end

-- ============================================================
-- UI SETTINGS
-- ============================================================
local UI = Tabs.UI:AddLeftGroupbox('Menu')
UI:AddButton('Unload Script', function()
    cleanup()
    Library:Unload()
end)

UI:AddLabel('Menu bind'):AddKeyPicker('MenuKeybind', {
    Default = 'End',
    NoUI = true,
    Text = 'Menu keybind',
})
Library.ToggleKeybind = Options.MenuKeybind

ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ 'MenuKeybind' })
ThemeManager:SetFolder('HackerAI/PriorExtinctionGrowth')
SaveManager:SetFolder('HackerAI/PriorExtinctionGrowth')
SaveManager:BuildConfigSection(Tabs.UI)
ThemeManager:ApplyToTab(Tabs.UI)

Library:OnUnload(function()
    cleanup()
end)

-- ============================================================
-- INIT
-- ============================================================
Library:SetWatermarkVisibility(false)
Library:Notify('✅ HackerAI Growth v4 loaded | Prior Extinction')
Library:Notify('Press End to open/close menu')

-- Initial diet detection
task.spawn(function()
    task.wait(2)
    local diet, species = detectDiet()
    local name = detectDinoName()
    CONFIG.DietType = diet
    CONFIG.DinoName = name
    CONFIG.DinoSpecies = species
    CONFIG.GrowthStage = detectGrowthStage()
    CONFIG.GrowthProgress = detectGrowthProgress()
    print('[HackerAI] Detected: Diet=' .. diet .. ' Dino=' .. name .. ' Stage=' .. CONFIG.GrowthStage)
end)

print('=== HackerAI Prior Extinction Growth v4.0 ===')
print('Player: ' .. LocalPlayer.Name)
print('Place: ' .. game.PlaceId .. ' | Job: ' .. game.JobId)
print('Webhook: ' .. (WEBHOOK_URL ~= "" and 'Configured' or 'NOT SET (change WEBHOOK_URL in source)'))
print('==============================================')
