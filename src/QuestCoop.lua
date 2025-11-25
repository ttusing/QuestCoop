local addonName, addon = ...

-- Default settings
local DEFAULT_SETTINGS = {
    textSize = "medium", -- small, medium, large
    recentLookbackMinutes = 10, -- How far back to look for "recent" quest activity
    visibleSections = {
        wrappingUp = true,
        kickingOff = true,
        sharedQuests = true,
        myQuests = true,
        partyQuests = true,
    },
}

-- Network protocol constants
local ADDON_PREFIX = "QuestCoop"
local MESSAGE_COOLDOWN = 1.0 -- 1 second between messages
local STALE_DATA_RETENTION = 300 -- 5 minutes (300 seconds)
local DISPLAY_REFRESH_DEBOUNCE = 0.1 -- 100ms debounce for UI updates
local QUEST_CACHE_EXPIRATION = 2592000 -- 30 days in seconds

-- Runtime data structures
local partyQuestStates = {} -- ["PlayerName-Realm"] = {activeQuestIDs, wrappingUp, kickingOff, lastUpdate, inParty}
local incomingChunks = {} -- ["PlayerName-Realm"] = {[chunkIndex] = payload, totalChunks, receivedAt}
local messageQueue = {} -- Array of {type, payload, chunk, total}
local lastMessageSentTime = 0
local pendingDisplayRefresh = false
local lastDisplayRefreshTime = 0

local function ShortName(name)
    if not name then return "?" end
    return name:match("^[^%-]+") or name
end

-- Settings management
local function GetSetting(key)
    if not QuestCoopDB then QuestCoopDB = {} end
    if not QuestCoopDB.settings then QuestCoopDB.settings = {} end
    if QuestCoopDB.settings[key] ~= nil then
        return QuestCoopDB.settings[key]
    end
    return DEFAULT_SETTINGS[key]
end

local function SetSetting(key, value)
    if not QuestCoopDB then QuestCoopDB = {} end
    if not QuestCoopDB.settings then QuestCoopDB.settings = {} end
    QuestCoopDB.settings[key] = value
end

local function GetFontSize()
    local size = GetSetting("textSize")
    if size == "small" then
        return "GameFontHighlightSmall", "GameFontNormalSmall", "GameFontNormal"
    elseif size == "large" then
        return "GameFontNormal", "GameFontNormalLarge", "GameFontNormalHuge"
    else -- medium
        return "GameFontHighlightSmall", "GameFontNormal", "GameFontNormalLarge"
    end
end

-- Quest name cache management
local function GetQuestName(questID)
    -- Check cache first
    if QuestCoopDB.questCache and QuestCoopDB.questCache[questID] then
        return QuestCoopDB.questCache[questID].name
    end
    
    -- Try to get from API
    local name = C_QuestLog.GetTitleForQuestID(questID)
    if name then
        -- Cache it
        if not QuestCoopDB.questCache then QuestCoopDB.questCache = {} end
        QuestCoopDB.questCache[questID] = {name = name, timestamp = time()}
        return name
    end
    
    -- Request load if not available
    C_QuestLog.RequestLoadQuestByID(questID)
    return "Quest " .. questID -- Placeholder until loaded
end

local function CleanupQuestCache()
    if not QuestCoopDB.questCache then return end
    local currentTime = time()
    local removed = 0
    for questID, data in pairs(QuestCoopDB.questCache) do
        if currentTime - data.timestamp > QUEST_CACHE_EXPIRATION then
            QuestCoopDB.questCache[questID] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then
        print("QuestCoop: Cleaned up " .. removed .. " expired quest cache entries")
    end
end

-- Player identification helper
local function GetFullPlayerName(unit)
    local name, realm = UnitFullName(unit)
    if not name then return nil end
    if not realm or realm == "" then
        realm = GetRealmName()
    end
    return name .. "-" .. realm
end

-- Message queue and throttling
local function QueueMessage(msgType, payload, chunk, total)
    table.insert(messageQueue, {
        type = msgType,
        payload = payload,
        chunk = chunk,
        total = total
    })
end

local function SendQueuedMessages(elapsed)
    if #messageQueue == 0 then return end
    
    local currentTime = time()
    if currentTime - lastMessageSentTime >= MESSAGE_COOLDOWN then
        local msg = table.remove(messageQueue, 1)
        if msg then
            -- Safety check: ensure payload is under 250 bytes
            if #msg.payload <= 250 then
                C_ChatInfo.SendAddonMessage(ADDON_PREFIX, msg.payload, "PARTY")
                lastMessageSentTime = currentTime
            else
                print("QuestCoop: Warning - Message too large (" .. #msg.payload .. " bytes), skipped")
            end
        end
    end
end

-- Broadcast quest log in chunks
local function BroadcastQuestLog()
    local questIDs = {}
    local numEntries = C_QuestLog.GetNumQuestLogEntries()
    
    for i = 1, numEntries do
        local questInfo = C_QuestLog.GetInfo(i)
        if questInfo and not questInfo.isHeader then
            local questID = questInfo.questID
            if questID then
                -- Skip hidden quests
                local questTagInfo = C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(questID)
                if not (questTagInfo and questTagInfo.tagName and questTagInfo.tagName:lower() == "hidden quest") then
                    table.insert(questIDs, questID)
                end
            end
        end
    end
    
    -- Split into chunks of 10 IDs
    local chunkSize = 10
    local totalChunks = math.ceil(#questIDs / chunkSize)
    
    for i = 1, totalChunks do
        local startIdx = (i - 1) * chunkSize + 1
        local endIdx = math.min(i * chunkSize, #questIDs)
        local chunkIDs = {}
        
        for j = startIdx, endIdx do
            table.insert(chunkIDs, tostring(questIDs[j]))
        end
        
        local payload = string.format("QUEST_LOG:%d:%d:%s", i, totalChunks, table.concat(chunkIDs, ","))
        QueueMessage("QUEST_LOG", payload, i, totalChunks)
    end
end

-- UI refresh debouncing
local function QueueDisplayRefresh()
    pendingDisplayRefresh = true
end

-- Helper to get party member quest data using C_QuestLog.IsUnitOnQuest
local function GetPartyMemberQuestData(unit, questID)
    if not C_QuestLog.IsUnitOnQuest then return nil end
    
    local isOnQuest = C_QuestLog.IsUnitOnQuest(unit, questID)
    if not isOnQuest then return nil end
    
    -- They have the quest, but we can't reliably determine tracking or ready state for other players
    -- We'll just mark that they have it
    return {has = true}
end

-- Auto-sync quest tracking based on party members
local function AutoSyncQuestTracking()
    if not IsInGroup() then return end
    
    local numEntries = C_QuestLog.GetNumQuestLogEntries()
    local playerName = UnitName("player")
    
    -- Build list of all party members including self
    local allPartyMembers = {playerName}
    for i = 1, GetNumGroupMembers() do
        local unit = (IsInRaid() and "raid" or "party") .. i
        local memberName = UnitName(unit)
        if memberName and ShortName(memberName) ~= ShortName(playerName) then
            table.insert(allPartyMembers, unit)
        end
    end
    
    local partySize = #allPartyMembers
    if partySize <= 1 then return end -- No one to sync with
    
    -- Check each quest in our log
    for i = 1, numEntries do
        local questInfo = C_QuestLog.GetInfo(i)
        if questInfo and not questInfo.isHeader then
            local questID = questInfo.questID
            if questID then
                -- Check if ALL party members have this quest
                local sharedByAll = true
                for j = 2, partySize do -- Skip index 1 (ourselves)
                    local unit = allPartyMembers[j]
                    local questData = GetPartyMemberQuestData(unit, questID)
                    if not questData or not questData.has then
                        sharedByAll = false
                        break
                    end
                end
                
                -- Check current tracking state
                local isTracked = false
                if C_QuestLog.GetQuestWatchType then
                    isTracked = C_QuestLog.GetQuestWatchType(questID) ~= nil
                end
                
                -- Track if shared by all, untrack if not
                if sharedByAll and not isTracked then
                    if C_QuestLog.AddQuestWatch then
                        C_QuestLog.AddQuestWatch(questID)
                    end
                elseif not sharedByAll and isTracked then
                    if C_QuestLog.RemoveQuestWatch then
                        C_QuestLog.RemoveQuestWatch(questID)
                    end
                end
            end
        end
    end
end

-- Generic helper to make a frame draggable
local function MakeDraggable(frame, key)
    if not frame then return end
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if not QuestCoopDB then QuestCoopDB = {} end
        if key then
            local point, relativeTo, relativePoint, xOfs, yOfs = self:GetPoint()
            QuestCoopDB[key] = {point = point, relativePoint = relativePoint, x = xOfs, y = yOfs}
        end
    end)
end

-- Forward declaration for RefreshQuestWindowIfVisible (defined later)
local RefreshQuestWindowIfVisible

-- Quest ID window (created lazily)
local questWindow, questScrollFrame, questScrollChild
local function CreateQuestWindow()
    if questWindow then return end
    questWindow = CreateFrame("Frame", "QuestCoopQuestWindow", UIParent, "BackdropTemplate")
    questWindow:SetSize(400, 300) -- adjusted width for ID and Title columns only
    questWindow:SetPoint("CENTER")
    questWindow:SetMovable(true)
    questWindow:EnableMouse(true)
    questWindow:RegisterForDrag("LeftButton")
    questWindow:SetScript("OnDragStart", function(self) self:StartMoving() end)
    questWindow:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    questWindow:SetBackdrop({bgFile = "Interface/Tooltips/UI-Tooltip-Background", edgeFile = "Interface/Tooltips/UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 }})
    questWindow:SetBackdropColor(0,0,0,0.85)
    questWindow:Hide()

    local title = questWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("Quest Co-op")

    local close = CreateFrame("Button", nil, questWindow, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    questScrollFrame = CreateFrame("ScrollFrame", "QuestCoopQuestScroll", questWindow, "UIPanelScrollFrameTemplate")
    questScrollFrame:SetPoint("TOPLEFT", 16, -40)
    questScrollFrame:SetPoint("BOTTOMRIGHT", -30, 16)

    questScrollChild = CreateFrame("Frame", nil, questScrollFrame)
    questScrollChild:SetSize(360, 1) -- adjusted for narrower window
    questScrollFrame:SetScrollChild(questScrollChild)
    questScrollChild.lines = {}
end

-- Settings panel
local settingsPanel
local function CreateSettingsPanel()
    if settingsPanel then return settingsPanel end
    
    settingsPanel = CreateFrame("Frame", "QuestCoopSettingsPanel", UIParent)
    settingsPanel.name = "QuestCoop"
    
    local title = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("QuestCoop Settings")
    
    local subtitle = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetText("Configure quest display and synchronization options")
    
    -- Text Size Section
    local textSizeLabel = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    textSizeLabel:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -24)
    textSizeLabel:SetText("Text Size:")
    
    local textSizeDropdown = CreateFrame("Frame", "QuestCoopTextSizeDropdown", settingsPanel, "UIDropDownMenuTemplate")
    textSizeDropdown:SetPoint("TOPLEFT", textSizeLabel, "BOTTOMLEFT", -15, -8)
    
    local textSizeOptions = {
        {text = "Small", value = "small"},
        {text = "Medium", value = "medium"},
        {text = "Large", value = "large"},
    }
    
    local function TextSizeDropdown_OnClick(self)
        SetSetting("textSize", self.value)
        UIDropDownMenu_SetText(textSizeDropdown, self:GetText())
        RefreshQuestWindowIfVisible()
    end
    
    local function TextSizeDropdown_Initialize(self, level)
        local info = UIDropDownMenu_CreateInfo()
        for _, option in ipairs(textSizeOptions) do
            info.text = option.text
            info.value = option.value
            info.func = TextSizeDropdown_OnClick
            info.checked = (GetSetting("textSize") == option.value)
            UIDropDownMenu_AddButton(info)
        end
    end
    
    UIDropDownMenu_Initialize(textSizeDropdown, TextSizeDropdown_Initialize)
    UIDropDownMenu_SetWidth(textSizeDropdown, 120)
    
    -- Set initial text
    local currentSize = GetSetting("textSize")
    for _, option in ipairs(textSizeOptions) do
        if option.value == currentSize then
            UIDropDownMenu_SetText(textSizeDropdown, option.text)
            break
        end
    end
    
    -- Recent Activity Lookback Slider
    local lookbackLabel = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    lookbackLabel:SetPoint("TOPLEFT", textSizeDropdown, "BOTTOMLEFT", 15, -24)
    lookbackLabel:SetText("Recent Activity Lookback (minutes):")
    
    local lookbackSlider = CreateFrame("Slider", "QuestCoopLookbackSlider", settingsPanel, "OptionsSliderTemplate")
    lookbackSlider:SetPoint("TOPLEFT", lookbackLabel, "BOTTOMLEFT", 0, -16)
    lookbackSlider:SetMinMaxValues(5, 120)
    lookbackSlider:SetValueStep(5)
    lookbackSlider:SetObeyStepOnDrag(true)
    lookbackSlider:SetWidth(200)
    _G[lookbackSlider:GetName() .. "Low"]:SetText("5")
    _G[lookbackSlider:GetName() .. "High"]:SetText("120")
    _G[lookbackSlider:GetName() .. "Text"]:SetText(GetSetting("recentLookbackMinutes") or 10)
    lookbackSlider:SetValue(GetSetting("recentLookbackMinutes") or 10)
    
    lookbackSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5) -- Round to nearest integer
        _G[self:GetName() .. "Text"]:SetText(value)
        SetSetting("recentLookbackMinutes", value)
        RefreshQuestWindowIfVisible()
    end)
    
    local lookbackHelp = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    lookbackHelp:SetPoint("TOPLEFT", lookbackSlider, "BOTTOMLEFT", 0, -8)
    lookbackHelp:SetText("How far back to look for 'Wrapping Up' and 'Kicking Off' quests")
    lookbackHelp:SetTextColor(0.7, 0.7, 0.7)
    
    -- Display Sections Checkboxes
    local sectionsLabel = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    sectionsLabel:SetPoint("TOPLEFT", lookbackHelp, "BOTTOMLEFT", 0, -24)
    sectionsLabel:SetText("Display Sections:")
    
    local checkboxYOffset = -24
    local checkboxOptions = {
        {key = "wrappingUp", label = "Wrapping Up (recently turned in by party)"},
        {key = "kickingOff", label = "Kicking Off (recently accepted by party)"},
        {key = "sharedQuests", label = "Shared Quests (quests all party members have)"},
        {key = "myQuests", label = "My Unique Quests"},
        {key = "partyQuests", label = "Party Unique Quests"},
    }
    
    for i, option in ipairs(checkboxOptions) do
        local checkbox = CreateFrame("CheckButton", "QuestCoopCheckbox" .. option.key, settingsPanel, "UICheckButtonTemplate")
        checkbox:SetPoint("TOPLEFT", sectionsLabel, "BOTTOMLEFT", 0, checkboxYOffset)
        _G[checkbox:GetName() .. "Text"]:SetText(option.label)
        
        -- Get current value
        local visibleSections = GetSetting("visibleSections")
        if not visibleSections then
            visibleSections = DEFAULT_SETTINGS.visibleSections
        end
        checkbox:SetChecked(visibleSections[option.key] ~= false)
        
        checkbox:SetScript("OnClick", function(self)
            local sections = GetSetting("visibleSections")
            if not sections then
                sections = {}
                for k, v in pairs(DEFAULT_SETTINGS.visibleSections) do
                    sections[k] = v
                end
            end
            sections[option.key] = self:GetChecked()
            SetSetting("visibleSections", sections)
            RefreshQuestWindowIfVisible()
        end)
        
        checkboxYOffset = checkboxYOffset - 28
    end
    
    -- Register with Interface Options
    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(settingsPanel)
    elseif Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(settingsPanel, settingsPanel.name)
        Settings.RegisterAddOnCategory(category)
    end
    
    return settingsPanel
end

-- Internal helper to refresh quest window if shown (silent)
RefreshQuestWindowIfVisible = function()
    if not questWindow or not questWindow:IsShown() then return end
    -- Call PrintQuestIDs but without shift printing and without forcing visibility changes beyond refresh.
    PrintQuestIDs(true) -- pass silent flag
end

-- Function to print current quest IDs
-- PrintQuestIDs(silentRefresh)
-- When silentRefresh is true, we don't echo to chat even if shift is down.
function PrintQuestIDs(silentRefresh)
    CreateQuestWindow()
    -- Build structured rows organized by player and tag
    -- questsByPlayer[playerName][tagName] = {quest1, quest2, ...}
    local questsByPlayer = {}
    local playerName = UnitName("player")
    questsByPlayer[playerName] = {}
    
    -- First, collect local player's quests
    local numEntries = C_QuestLog.GetNumQuestLogEntries()
    local shiftDown = IsShiftKeyDown and IsShiftKeyDown() and not silentRefresh
    for i = 1, numEntries do
        local questInfo = C_QuestLog.GetInfo(i)
        if questInfo and not questInfo.isHeader then
            local questID = questInfo.questID
            if questID then
                local title = questInfo.title or "(no title)"
                -- Determine tracked state. Retail API first, legacy fallback.
                local tracked = false
                if C_QuestLog.GetQuestWatchType then
                    tracked = C_QuestLog.GetQuestWatchType(questID) ~= nil
                elseif IsQuestWatched then
                    local logIndex = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
                    if logIndex then
                        tracked = IsQuestWatched(logIndex)
                    end
                end
                local trackText = tracked and "Yes" or "No"
                -- Determine readiness for turn-in (completion of objectives)
                local ready = false
                if C_QuestLog.IsComplete then
                    ready = C_QuestLog.IsComplete(questID)
                elseif IsQuestComplete then
                    ready = IsQuestComplete(questID)
                elseif questInfo.isComplete ~= nil then
                    ready = questInfo.isComplete
                end
                local readyText = ready and "Yes" or "No"
                local questTagInfo = C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(questID)
                -- Skip quests with "hidden quest" tag
                if questTagInfo and questTagInfo.tagName and questTagInfo.tagName:lower() == "hidden quest" then
                    -- Skip hidden quests
                else
                    local zoneOrSort = questInfo.campaignID and ("Campaign") or (questInfo.zoneOrSort or "")
                    local detailedCategory = questInfo.header and questInfo.header or zoneOrSort
                    local tagName = questTagInfo and questTagInfo.tagName or "No Tag"
                    
                    -- Initialize tag group if needed
                    if not questsByPlayer[playerName][tagName] then
                        questsByPlayer[playerName][tagName] = {}
                    end
                    
                    table.insert(questsByPlayer[playerName][tagName], {id = questID, title = title, tracked = trackText, inlog = "Yes", ready = readyText, tag = questTagInfo, category = detailedCategory, isLocal = true})
                end
                if shiftDown and not silentRefresh then
                    local chatLine = string.format("%d - %s (Tracked:%s Ready:%s)", questID, title, trackText, readyText)
                    print("QuestCoop:", chatLine)
                end
            end
        end
    end
    
    -- Now collect party members' quests (excluding local player to avoid duplication)
    if IsInGroup() then
        for i = 1, GetNumGroupMembers() do
            local unit = (IsInRaid() and "raid" or "party") .. i
            local partyMember = UnitName(unit)
            
            -- Skip if this is the local player or invalid unit
            if partyMember and ShortName(partyMember) ~= ShortName(playerName) then
                questsByPlayer[partyMember] = {}
                
                -- Check all local player's quests to see if party member has them
                for i = 1, numEntries do
                    local questInfo = C_QuestLog.GetInfo(i)
                    if questInfo and not questInfo.isHeader then
                        local questID = questInfo.questID
                        if questID then
                            local questData = GetPartyMemberQuestData(unit, questID)
                            if questData and questData.has then
                                local title = questInfo.title or ("(Quest " .. questID .. ")")
                                
                                -- Try to get tag info from our own quest log if we have this quest
                                local questTagInfo = C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(questID)
                                local tagName = questTagInfo and questTagInfo.tagName or "No Tag"
                                
                                -- Skip hidden quests for party members too
                                if not (questTagInfo and questTagInfo.tagName and questTagInfo.tagName:lower() == "hidden quest") then
                                    -- Initialize tag group if needed
                                    if not questsByPlayer[partyMember][tagName] then
                                        questsByPlayer[partyMember][tagName] = {}
                                    end
                                    
                                    table.insert(questsByPlayer[partyMember][tagName], {id = questID, title = title, tracked = "?", inlog = "Yes", ready = "?", tag = questTagInfo, category = "", isLocal = false})
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Build a list of all party members (including local player)
    local allPartyMembers = {}
    for member, _ in pairs(questsByPlayer) do
        table.insert(allPartyMembers, member)
    end
    local partySize = #allPartyMembers
    
    -- Identify shared quests (quests that ALL party members have)
    local sharedQuestsByTag = {}
    if partySize > 1 then
        -- Get all quest IDs from the first player
        local allQuestIDs = {}
        for tagName, quests in pairs(questsByPlayer[allPartyMembers[1]]) do
            for _, quest in ipairs(quests) do
                allQuestIDs[quest.id] = {tagName = tagName, quest = quest}
            end
        end
        
        -- Check which quests exist in ALL players' quest logs
        for questID, questInfo in pairs(allQuestIDs) do
            local sharedByAll = true
            for i = 2, partySize do
                local member = allPartyMembers[i]
                local hasQuest = false
                for _, quests in pairs(questsByPlayer[member]) do
                    for _, quest in ipairs(quests) do
                        if quest.id == questID then
                            hasQuest = true
                            break
                        end
                    end
                    if hasQuest then break end
                end
                if not hasQuest then
                    sharedByAll = false
                    break
                end
            end
            
            if sharedByAll then
                local tagName = questInfo.tagName
                if not sharedQuestsByTag[tagName] then
                    sharedQuestsByTag[tagName] = {}
                end
                table.insert(sharedQuestsByTag[tagName], questInfo.quest)
            end
        end
    end
    
    -- Remove shared quests from individual player lists
    for questTag, sharedQuests in pairs(sharedQuestsByTag) do
        for _, sharedQuest in ipairs(sharedQuests) do
            for member, questsByTag in pairs(questsByPlayer) do
                if questsByTag[questTag] then
                    for i = #questsByTag[questTag], 1, -1 do
                        if questsByTag[questTag][i].id == sharedQuest.id then
                            table.remove(questsByTag[questTag], i)
                        end
                    end
                    -- Clean up empty tag groups
                    if #questsByTag[questTag] == 0 then
                        questsByTag[questTag] = nil
                    end
                end
            end
        end
    end
    
    -- Clear previous row frames / fontstrings
    for _, fs in ipairs(questScrollChild.lines) do fs:Hide() end
    wipe(questScrollChild.lines)

    -- Column layout constants
    local COL_ID_X = 10
    local COL_TITLE_X = 70
    
    -- Adjust row height and spacing based on text size
    local textSize = GetSetting("textSize")
    local ROW_HEIGHT = (textSize == "small" and 14) or (textSize == "large" and 18) or 14
    local PLAYER_HEADING_HEIGHT = (textSize == "large" and 26) or 22
    local SUBHEADING_HEIGHT = (textSize == "large" and 20) or 18
    local yOff = -2
    
    -- Sort players: local player first, then others alphabetically
    local sortedPlayers = {}
    for playerName, _ in pairs(questsByPlayer) do
        table.insert(sortedPlayers, playerName)
    end
    table.sort(sortedPlayers, function(a, b)
        local localPlayer = UnitName("player")
        if a == localPlayer then return true end
        if b == localPlayer then return false end
        return a < b
    end)
    
    -- Get font sizes based on settings
    local fontSmall, fontNormal, fontLarge = GetFontSize()
    
    -- Header row with column labels
    local headerID = questScrollChild:CreateFontString(nil, "OVERLAY", fontNormal)
    headerID:SetPoint("TOPLEFT", COL_ID_X, yOff)
    headerID:SetJustifyH("LEFT")
    headerID:SetText("ID")
    table.insert(questScrollChild.lines, headerID)

    local headerTitle = questScrollChild:CreateFontString(nil, "OVERLAY", fontNormal)
    headerTitle:SetPoint("TOPLEFT", COL_TITLE_X, yOff)
    headerTitle:SetJustifyH("LEFT")
    headerTitle:SetText("Title")
    table.insert(questScrollChild.lines, headerTitle)
    
    yOff = yOff - ROW_HEIGHT - 4
    
    -- First, render shared quests section if there are any
    local sharedQuestCount = 0
    for _, quests in pairs(sharedQuestsByTag) do
        sharedQuestCount = sharedQuestCount + #quests
    end
    
    -- Check if sections are visible from settings (define here so it's available for all sections)
    local showWrappingUp = GetSetting("visibleSections") and GetSetting("visibleSections").wrappingUp ~= false
    local showKickingOff = GetSetting("visibleSections") and GetSetting("visibleSections").kickingOff ~= false
    local showSharedQuests = GetSetting("visibleSections") and GetSetting("visibleSections").sharedQuests ~= false
    local showMyQuests = GetSetting("visibleSections") and GetSetting("visibleSections").myQuests ~= false
    local showPartyQuests = GetSetting("visibleSections") and GetSetting("visibleSections").partyQuests ~= false
    local lookbackMinutes = GetSetting("recentLookbackMinutes") or 10
    
    if sharedQuestCount > 0 and showSharedQuests then
        -- Create shared section heading
        local sharedHeading = questScrollChild:CreateFontString(nil, "OVERLAY", fontLarge)
        sharedHeading:SetPoint("TOPLEFT", 0, yOff)
        sharedHeading:SetJustifyH("LEFT")
        sharedHeading:SetTextColor(0.5, 0.8, 1) -- Light blue for shared quests
        sharedHeading:SetText(string.format("Shared by All (%d players) - %d quests", partySize, sharedQuestCount))
        table.insert(questScrollChild.lines, sharedHeading)
        yOff = yOff - PLAYER_HEADING_HEIGHT
        
        -- Sort tags alphabetically
        local sortedSharedTags = {}
        for tagName, _ in pairs(sharedQuestsByTag) do
            table.insert(sortedSharedTags, tagName)
        end
        table.sort(sortedSharedTags)
        
        -- Render shared quests grouped by tag
        for _, tagName in ipairs(sortedSharedTags) do
            local questsInTag = sharedQuestsByTag[tagName]
            
            -- Create subheading for this tag
            local subheading = questScrollChild:CreateFontString(nil, "OVERLAY", fontNormal)
            subheading:SetPoint("TOPLEFT", 10, yOff)
            subheading:SetJustifyH("LEFT")
            subheading:SetTextColor(1, 0.82, 0) -- Gold color for subheadings
            subheading:SetText(string.format("%s (%d)", tagName, #questsInTag))
            table.insert(questScrollChild.lines, subheading)
            yOff = yOff - SUBHEADING_HEIGHT
            
            -- Render each shared quest under this tag
            for _, row in ipairs(questsInTag) do
        -- ID cell
        local idFS = questScrollChild:CreateFontString(nil, "OVERLAY", fontSmall)
        idFS:SetPoint("TOPLEFT", COL_ID_X, yOff)
        idFS:SetJustifyH("LEFT")
        idFS:SetText(row.id)
        table.insert(questScrollChild.lines, idFS)

        -- Title cell
        local titleFS = questScrollChild:CreateFontString(nil, "OVERLAY", fontNormal)
        titleFS:SetPoint("TOPLEFT", COL_TITLE_X, yOff)
        titleFS:SetJustifyH("LEFT")
        titleFS:SetTextColor(1, 1, 1) -- White text
        titleFS:SetText(row.title)
        titleFS.fullTitle = row.title
        table.insert(questScrollChild.lines, titleFS)

        -- Mouseover tooltip
        local rowButton = CreateFrame("Button", nil, questScrollChild)
        rowButton:SetPoint("TOPLEFT", idFS, "TOPLEFT", -2, 2)
        rowButton:SetPoint("BOTTOMRIGHT", titleFS, "BOTTOMRIGHT", 2, -2)
        rowButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        rowButton:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                -- Create context menu using modern API
                MenuUtil.CreateContextMenu(UIParent, function(owner, rootDescription)
                    rootDescription:CreateTitle(row.title)
                    rootDescription:CreateButton("Share Quest", function()
                        -- Select the quest in the quest log first, then share it
                        C_QuestLog.SetSelectedQuest(row.id)
                        QuestLogPushQuest()
                    end)
                    rootDescription:CreateButton("Cancel", function() end)
                end)
            end
        end)
        rowButton:SetScript("OnEnter", function()
            GameTooltip:SetOwner(rowButton, "ANCHOR_CURSOR")
            GameTooltip:AddLine(row.fullTitle or row.title, 1,1,1, true)
            GameTooltip:AddLine(string.format("Quest ID: %d", row.id), 0.9,0.9,0.9)
            GameTooltip:AddLine("Shared by all party members", 0.5,0.8,1)
            if row.category and row.category ~= "" then
                GameTooltip:AddLine("Category: " .. tostring(row.category), 0.8,0.8,0.8)
            end
            if row.tag and row.tag.tagName then
                GameTooltip:AddLine("Tag: " .. row.tag.tagName, 0.8,0.8,0.8)
            end
            GameTooltip:Show()
        end)
        rowButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
        table.insert(questScrollChild.lines, rowButton)

        yOff = yOff - ROW_HEIGHT - 2
            end
            
            -- Add spacing after each tag group
            yOff = yOff - 6
        end
        
        -- Add spacing after shared section
        yOff = yOff - 15
    end
    
    -- Render "Wrapping Up" section (party members' recent turn-ins where local player still has the quest)
    if showWrappingUp then
        local wrappingUpQuests = {}
        local currentTime = time()
        local cutoffTime = currentTime - (lookbackMinutes * 60)
        
        for playerName, state in pairs(partyQuestStates) do
            if playerName ~= GetFullPlayerName("player") then
                for _, turnin in ipairs(state.wrappingUp) do
                    if turnin.timestamp >= cutoffTime then
                        -- Check if local player still has this quest
                        if C_QuestLog.IsOnQuest(turnin.questID) then
                            table.insert(wrappingUpQuests, {
                                questID = turnin.questID,
                                playerName = playerName,
                                timestamp = turnin.timestamp
                            })
                        end
                    end
                end
            end
        end
        
        if #wrappingUpQuests > 0 then
            -- Create section heading
            local wrappingUpHeading = questScrollChild:CreateFontString(nil, "OVERLAY", fontLarge)
            wrappingUpHeading:SetPoint("TOPLEFT", 0, yOff)
            wrappingUpHeading:SetJustifyH("LEFT")
            wrappingUpHeading:SetTextColor(1, 0.6, 0) -- Orange for wrapping up
            wrappingUpHeading:SetText(string.format("Wrapping Up (%d quests)", #wrappingUpQuests))
            table.insert(questScrollChild.lines, wrappingUpHeading)
            yOff = yOff - PLAYER_HEADING_HEIGHT
            
            -- Sort by timestamp (most recent first)
            table.sort(wrappingUpQuests, function(a, b) return a.timestamp > b.timestamp end)
            
            for _, quest in ipairs(wrappingUpQuests) do
                local questName = GetQuestName(quest.questID)
                
                -- ID cell
                local idFS = questScrollChild:CreateFontString(nil, "OVERLAY", fontSmall)
                idFS:SetPoint("TOPLEFT", COL_ID_X, yOff)
                idFS:SetJustifyH("LEFT")
                idFS:SetText(quest.questID)
                table.insert(questScrollChild.lines, idFS)
                
                -- Title cell with player name
                local titleFS = questScrollChild:CreateFontString(nil, "OVERLAY", fontNormal)
                titleFS:SetPoint("TOPLEFT", COL_TITLE_X, yOff)
                titleFS:SetJustifyH("LEFT")
                titleFS:SetTextColor(1, 1, 1)
                titleFS:SetText(questName .. " [" .. ShortName(quest.playerName) .. "]")
                table.insert(questScrollChild.lines, titleFS)
                
                -- Tooltip
                local rowButton = CreateFrame("Button", nil, questScrollChild)
                rowButton:SetPoint("TOPLEFT", idFS, "TOPLEFT", -2, 2)
                rowButton:SetPoint("BOTTOMRIGHT", titleFS, "BOTTOMRIGHT", 2, -2)
                rowButton:SetScript("OnEnter", function()
                    GameTooltip:SetOwner(rowButton, "ANCHOR_CURSOR")
                    GameTooltip:AddLine(questName, 1, 1, 1, true)
                    GameTooltip:AddLine(string.format("Quest ID: %d", quest.questID), 0.9, 0.9, 0.9)
                    local minutesAgo = math.floor((currentTime - quest.timestamp) / 60)
                    GameTooltip:AddLine(ShortName(quest.playerName) .. " turned this in " .. minutesAgo .. " minutes ago", 1, 0.6, 0)
                    GameTooltip:Show()
                end)
                rowButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
                table.insert(questScrollChild.lines, rowButton)
                
                yOff = yOff - ROW_HEIGHT - 2
            end
            
            yOff = yOff - 15
        end
    end
    
    -- Render "Kicking Off" section (party members' recent accepts where local player doesn't have the quest)
    if showKickingOff then
        local kickingOffQuests = {}
        local currentTime = time()
        local cutoffTime = currentTime - (lookbackMinutes * 60)
        
        for playerName, state in pairs(partyQuestStates) do
            if playerName ~= GetFullPlayerName("player") then
                for _, accept in ipairs(state.kickingOff) do
                    if accept.timestamp >= cutoffTime then
                        -- Check if local player does NOT have this quest
                        if not C_QuestLog.IsOnQuest(accept.questID) then
                            table.insert(kickingOffQuests, {
                                questID = accept.questID,
                                playerName = playerName,
                                timestamp = accept.timestamp
                            })
                        end
                    end
                end
            end
        end
        
        if #kickingOffQuests > 0 then
            -- Create section heading
            local kickingOffHeading = questScrollChild:CreateFontString(nil, "OVERLAY", fontLarge)
            kickingOffHeading:SetPoint("TOPLEFT", 0, yOff)
            kickingOffHeading:SetJustifyH("LEFT")
            kickingOffHeading:SetTextColor(0, 0.8, 1) -- Cyan for kicking off
            kickingOffHeading:SetText(string.format("Kicking Off (%d quests)", #kickingOffQuests))
            table.insert(questScrollChild.lines, kickingOffHeading)
            yOff = yOff - PLAYER_HEADING_HEIGHT
            
            -- Sort by timestamp (most recent first)
            table.sort(kickingOffQuests, function(a, b) return a.timestamp > b.timestamp end)
            
            for _, quest in ipairs(kickingOffQuests) do
                local questName = GetQuestName(quest.questID)
                
                -- ID cell
                local idFS = questScrollChild:CreateFontString(nil, "OVERLAY", fontSmall)
                idFS:SetPoint("TOPLEFT", COL_ID_X, yOff)
                idFS:SetJustifyH("LEFT")
                idFS:SetText(quest.questID)
                table.insert(questScrollChild.lines, idFS)
                
                -- Title cell with player name
                local titleFS = questScrollChild:CreateFontString(nil, "OVERLAY", fontNormal)
                titleFS:SetPoint("TOPLEFT", COL_TITLE_X, yOff)
                titleFS:SetJustifyH("LEFT")
                titleFS:SetTextColor(1, 1, 1)
                titleFS:SetText(questName .. " [" .. ShortName(quest.playerName) .. "]")
                table.insert(questScrollChild.lines, titleFS)
                
                -- Tooltip
                local rowButton = CreateFrame("Button", nil, questScrollChild)
                rowButton:SetPoint("TOPLEFT", idFS, "TOPLEFT", -2, 2)
                rowButton:SetPoint("BOTTOMRIGHT", titleFS, "BOTTOMRIGHT", 2, -2)
                rowButton:SetScript("OnEnter", function()
                    GameTooltip:SetOwner(rowButton, "ANCHOR_CURSOR")
                    GameTooltip:AddLine(questName, 1, 1, 1, true)
                    GameTooltip:AddLine(string.format("Quest ID: %d", quest.questID), 0.9, 0.9, 0.9)
                    local minutesAgo = math.floor((currentTime - quest.timestamp) / 60)
                    GameTooltip:AddLine(ShortName(quest.playerName) .. " picked this up " .. minutesAgo .. " minutes ago", 0, 0.8, 1)
                    GameTooltip:Show()
                end)
                rowButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
                table.insert(questScrollChild.lines, rowButton)
                
                yOff = yOff - ROW_HEIGHT - 2
            end
            
            yOff = yOff - 15
        end
    end
    
    -- Then render individual player quests (excluding shared)
    for _, playerDisplayName in ipairs(sortedPlayers) do
        local questsByTag = questsByPlayer[playerDisplayName]
        
        -- Count total quests for this player
        local totalQuests = 0
        for _, quests in pairs(questsByTag) do
            totalQuests = totalQuests + #quests
        end
        
        -- Only display players with quests
        if totalQuests > 0 then
            -- Check visibility settings
            local isLocalPlayer = (playerDisplayName == UnitName("player"))
            local shouldShow = (isLocalPlayer and showMyQuests) or (not isLocalPlayer and showPartyQuests)
            
            if shouldShow then
            -- Create player name heading
            local playerHeading = questScrollChild:CreateFontString(nil, "OVERLAY", fontLarge)
            playerHeading:SetPoint("TOPLEFT", 0, yOff)
            playerHeading:SetJustifyH("LEFT")
            playerHeading:SetTextColor(0.3, 1, 0.3) -- Bright green for player names
            local displayName = ShortName(playerDisplayName)
            if playerDisplayName == UnitName("player") then
                displayName = displayName .. " (You)"
            end
            local questLabel = totalQuests == 1 and "unique quest" or "unique quests"
            playerHeading:SetText(string.format("%s - %d %s", displayName, totalQuests, questLabel))
            table.insert(questScrollChild.lines, playerHeading)
            yOff = yOff - PLAYER_HEADING_HEIGHT
            
            -- Sort tags alphabetically for consistent display
            local sortedTags = {}
            for tagName, _ in pairs(questsByTag) do
                table.insert(sortedTags, tagName)
            end
            table.sort(sortedTags)
            
            -- Render quests grouped by tag within this player
            for _, tagName in ipairs(sortedTags) do
                local questsInTag = questsByTag[tagName]
                
                -- Create subheading for this tag
                local subheading = questScrollChild:CreateFontString(nil, "OVERLAY", fontNormal)
                subheading:SetPoint("TOPLEFT", 10, yOff)
                subheading:SetJustifyH("LEFT")
                subheading:SetTextColor(1, 0.82, 0) -- Gold color for subheadings
                subheading:SetText(string.format("%s (%d)", tagName, #questsInTag))
                table.insert(questScrollChild.lines, subheading)
                yOff = yOff - SUBHEADING_HEIGHT
                
                -- Render each quest under this tag
                for _, row in ipairs(questsInTag) do
        -- ID cell
        local idFS = questScrollChild:CreateFontString(nil, "OVERLAY", fontSmall)
        idFS:SetPoint("TOPLEFT", COL_ID_X, yOff)
        idFS:SetJustifyH("LEFT")
        idFS:SetText(row.id)
        table.insert(questScrollChild.lines, idFS)

        -- Title cell
        local titleFS = questScrollChild:CreateFontString(nil, "OVERLAY", fontNormal)
        titleFS:SetPoint("TOPLEFT", COL_TITLE_X, yOff)
        titleFS:SetJustifyH("LEFT")
        titleFS:SetTextColor(1, 1, 1) -- White text
        titleFS:SetText(row.title)
        titleFS.fullTitle = row.title
        table.insert(questScrollChild.lines, titleFS)

        -- Mouseover tooltip region (use an invisible button spanning the row for simplicity)
        local rowButton = CreateFrame("Button", nil, questScrollChild)
        rowButton:SetPoint("TOPLEFT", idFS, "TOPLEFT", -2, 2)
        rowButton:SetPoint("BOTTOMRIGHT", titleFS, "BOTTOMRIGHT", 2, -2)
        rowButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        rowButton:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                -- Create context menu using modern API
                MenuUtil.CreateContextMenu(UIParent, function(owner, rootDescription)
                    rootDescription:CreateTitle(row.title)
                    rootDescription:CreateButton("Share Quest", function()
                        -- Select the quest in the quest log first, then share it
                        C_QuestLog.SetSelectedQuest(row.id)
                        QuestLogPushQuest()
                    end)
                    rootDescription:CreateButton("Cancel", function() end)
                end)
            end
        end)
        rowButton:SetScript("OnEnter", function()
            GameTooltip:SetOwner(rowButton, "ANCHOR_CURSOR")
            GameTooltip:AddLine(row.fullTitle or row.title, 1,1,1, true)
            GameTooltip:AddLine(string.format("Quest ID: %d", row.id), 0.9,0.9,0.9)
            if row.category and row.category ~= "" then
                GameTooltip:AddLine("Category: " .. tostring(row.category), 0.8,0.8,0.8)
            end
            if row.tag and row.tag.tagName then
                GameTooltip:AddLine("Tag: " .. row.tag.tagName, 0.8,0.8,0.8)
            end
            -- Party member aggregation - check who has this quest
            if IsInGroup() then
                local hasMembers = {}
                for i = 1, GetNumGroupMembers() do
                    local unit = (IsInRaid() and "raid" or "party") .. i
                    local memberName = UnitName(unit)
                    if memberName then
                        local questData = GetPartyMemberQuestData(unit, row.id)
                        if questData and questData.has then
                            table.insert(hasMembers, ShortName(memberName))
                        end
                    end
                end
                local function fmt(list)
                    if #list == 0 then return "None" end
                    table.sort(list)
                    return table.concat(list, ", ")
                end
                GameTooltip:AddLine("Has: " .. fmt(hasMembers), 0.7,0.9,0.7)
            end
            GameTooltip:Show()
        end)
        rowButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
        table.insert(questScrollChild.lines, rowButton)

        yOff = yOff - ROW_HEIGHT - 2
        end
        
        -- Add spacing after each tag group
        yOff = yOff - 6
            end -- end for tags loop
            
            -- Add spacing after each player
            yOff = yOff - 10
            end -- end if shouldShow
        end -- end if totalQuests > 0
    end -- end for players loop

    local totalHeight = (-yOff) + 4
    questScrollChild:SetHeight(totalHeight)
    questWindow:Show()
end

-- Create frame to handle events
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")

-- Periodic timer for auto-syncing quest tracking
local autoSyncTimer = 0
local AUTO_SYNC_INTERVAL = 15 -- seconds

frame:SetScript("OnUpdate", function(self, elapsed)
    autoSyncTimer = autoSyncTimer + elapsed
    if autoSyncTimer >= AUTO_SYNC_INTERVAL then
        autoSyncTimer = 0
        AutoSyncQuestTracking()
    end
    
    -- Process message queue
    SendQueuedMessages(elapsed)
    
    -- Handle debounced display refresh
    if pendingDisplayRefresh and (time() - lastDisplayRefreshTime >= DISPLAY_REFRESH_DEBOUNCE) then
        pendingDisplayRefresh = false
        lastDisplayRefreshTime = time()
        RefreshQuestWindowIfVisible()
    end
end)

-- Handle incoming addon messages
local function HandleAddonMessage(prefix, message, channel, sender)
    if prefix ~= ADDON_PREFIX then return end
    if channel ~= "PARTY" and channel ~= "RAID" then return end
    
    -- Parse message type
    local msgType, rest = message:match("^([^:]+):(.*)$")
    if not msgType then return end
    
    -- Initialize player state if needed
    if not partyQuestStates[sender] then
        partyQuestStates[sender] = {
            activeQuestIDs = {},
            wrappingUp = {},
            kickingOff = {},
            lastUpdate = time(),
            inParty = true
        }
    end
    
    partyQuestStates[sender].lastUpdate = time()
    partyQuestStates[sender].inParty = true
    
    if msgType == "QUEST_ACCEPT" then
        local questID, timestamp = rest:match("^(%d+):(%d+)$")
        if questID and timestamp then
            questID = tonumber(questID)
            timestamp = tonumber(timestamp)
            table.insert(partyQuestStates[sender].kickingOff, {questID = questID, timestamp = timestamp})
            partyQuestStates[sender].activeQuestIDs[questID] = true
            QueueDisplayRefresh()
        end
        
    elseif msgType == "QUEST_TURNIN" then
        local questID, timestamp = rest:match("^(%d+):(%d+)$")
        if questID and timestamp then
            questID = tonumber(questID)
            timestamp = tonumber(timestamp)
            table.insert(partyQuestStates[sender].wrappingUp, {questID = questID, timestamp = timestamp})
            partyQuestStates[sender].activeQuestIDs[questID] = nil
            QueueDisplayRefresh()
        end
        
    elseif msgType == "QUEST_LOG" then
        local chunkIndex, totalChunks, questIDsStr = rest:match("^(%d+):(%d+):(.*)$")
        if chunkIndex and totalChunks and questIDsStr then
            chunkIndex = tonumber(chunkIndex)
            totalChunks = tonumber(totalChunks)
            
            -- Initialize chunk buffer
            if not incomingChunks[sender] then
                incomingChunks[sender] = {totalChunks = totalChunks, receivedAt = time()}
            end
            
            incomingChunks[sender][chunkIndex] = questIDsStr
            
            -- Check if we have all chunks
            local complete = true
            for i = 1, totalChunks do
                if not incomingChunks[sender][i] then
                    complete = false
                    break
                end
            end
            
            if complete then
                -- Reconstruct full quest list
                local allQuestIDs = {}
                for i = 1, totalChunks do
                    for questID in string.gmatch(incomingChunks[sender][i], "(%d+)") do
                        allQuestIDs[tonumber(questID)] = true
                    end
                end
                
                partyQuestStates[sender].activeQuestIDs = allQuestIDs
                incomingChunks[sender] = nil -- Clear buffer
                QueueDisplayRefresh()
            end
        end
    end
end

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        -- Initialize settings
        if not QuestCoopDB then QuestCoopDB = {} end
        if not QuestCoopDB.settings then
            QuestCoopDB.settings = {}
            for k, v in pairs(DEFAULT_SETTINGS) do
                if QuestCoopDB.settings[k] == nil then
                    QuestCoopDB.settings[k] = v
                end
            end
        end
        
        -- Create settings panel
        CreateSettingsPanel()
        
        -- Register slash command
        SLASH_QUESTCOOP1 = "/questcoop"
        SLASH_QUESTCOOP2 = "/qc"
        SlashCmdList["QUESTCOOP"] = function(msg)
            msg = msg:lower():trim()
            if msg == "settings" or msg == "config" or msg == "options" then
                if InterfaceOptionsFrame_OpenToCategory then
                    InterfaceOptionsFrame_OpenToCategory(settingsPanel)
                    InterfaceOptionsFrame_OpenToCategory(settingsPanel) -- Call twice for proper navigation
                elseif Settings and Settings.OpenToCategory then
                    Settings.OpenToCategory(settingsPanel.name)
                end
            else
                PrintQuestIDs()
            end
        end
        
        -- Set up click handler for the button defined in XML
        local printButton = _G["PrintQuestIDsButton"]

        if printButton then
            printButton:SetScript("OnClick", function(self, button)
                PrintQuestIDs()
            end)
            printButton:ClearAllPoints()
            if QuestCoopDB.printButtonPos then
                local pos = QuestCoopDB.printButtonPos
                printButton:SetPoint(pos.point or "CENTER", UIParent, pos.relativePoint or "CENTER", pos.x or 0, pos.y or -40)
            else
                printButton:SetPoint("CENTER", UIParent, "CENTER", 0, -40)
            end
            MakeDraggable(printButton, "printButtonPos")
            printButton:SetUserPlaced(true)
            printButton:Show()
        end
        
        -- Initialize quest cache
        if not QuestCoopDB.questCache then
            QuestCoopDB.questCache = {}
        end
        CleanupQuestCache()
        
        -- Register addon message prefix
        C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
        
        -- Run initial auto-sync after login
        C_Timer.After(2, AutoSyncQuestTracking)
    end
    
    -- Handle addon messages
    if event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = ...
        HandleAddonMessage(prefix, message, channel, sender)
    end
    
    -- Handle quest data load results (for cache population)
    if event == "QUEST_DATA_LOAD_RESULT" then
        local questID, success = ...
        if success then
            local name = C_QuestLog.GetTitleForQuestID(questID)
            if name then
                if not QuestCoopDB.questCache then QuestCoopDB.questCache = {} end
                QuestCoopDB.questCache[questID] = {name = name, timestamp = time()}
            end
        end
    end
    
    -- Handle quest turn-ins
    if event == "QUEST_TURNED_IN" then
        local questID = ...
        if questID then
            local payload = string.format("QUEST_TURNIN:%d:%d", questID, time())
            QueueMessage("QUEST_TURNIN", payload)
            
            -- Update local state
            local playerName = GetFullPlayerName("player")
            if playerName and partyQuestStates[playerName] then
                table.insert(partyQuestStates[playerName].wrappingUp, {questID = questID, timestamp = time()})
                partyQuestStates[playerName].activeQuestIDs[questID] = nil
            end
            
            QueueDisplayRefresh()
        end
    end
    
    -- Handle quest accepts
    if event == "QUEST_ACCEPTED" then
        local questID = ...
        if questID then
            local payload = string.format("QUEST_ACCEPT:%d:%d", questID, time())
            QueueMessage("QUEST_ACCEPT", payload)
            
            -- Update local state
            local playerName = GetFullPlayerName("player")
            if playerName and partyQuestStates[playerName] then
                table.insert(partyQuestStates[playerName].kickingOff, {questID = questID, timestamp = time()})
                partyQuestStates[playerName].activeQuestIDs[questID] = true
            end
            
            QueueDisplayRefresh()
        end
    end
    
    -- Handle roster updates with player tracking
    if event == "GROUP_ROSTER_UPDATE" then
        local currentTime = time()
        local currentMembers = {}
        
        -- Build list of current party members
        if IsInGroup() then
            for i = 1, GetNumGroupMembers() do
                local unit = (IsInRaid() and "raid" or "party") .. i
                local fullName = GetFullPlayerName(unit)
                if fullName then
                    currentMembers[fullName] = true
                end
            end
        end
        
        -- Add self
        local selfName = GetFullPlayerName("player")
        if selfName then
            currentMembers[selfName] = true
            
            -- Initialize self state if needed
            if not partyQuestStates[selfName] then
                partyQuestStates[selfName] = {
                    activeQuestIDs = {},
                    wrappingUp = {},
                    kickingOff = {},
                    lastUpdate = currentTime,
                    inParty = true
                }
            end
        end
        
        -- Update party states
        for playerName, state in pairs(partyQuestStates) do
            if currentMembers[playerName] then
                state.inParty = true
                state.lastUpdate = currentTime
            else
                if state.inParty then
                    -- Player just left, mark as inactive
                    state.inParty = false
                end
            end
        end
        
        -- Cleanup stale entries
        for playerName, state in pairs(partyQuestStates) do
            if not state.inParty and (currentTime - state.lastUpdate > STALE_DATA_RETENTION) then
                partyQuestStates[playerName] = nil
            end
        end
        
        -- Broadcast quest log with jitter (skip if we just synced recently)
        if IsInGroup() and selfName then
            local state = partyQuestStates[selfName]
            if not state.lastBroadcast or (currentTime - state.lastBroadcast > 30) then
                local jitter = math.random(0, 5000) / 1000
                C_Timer.After(jitter, function()
                    BroadcastQuestLog()
                    if partyQuestStates[selfName] then
                        partyQuestStates[selfName].lastBroadcast = time()
                    end
                end)
            end
        end
        
        QueueDisplayRefresh()
    end
    
    -- Auto-refresh triggers
    if event == "QUEST_REMOVED" or event == "QUEST_WATCH_LIST_CHANGED" or event == "QUEST_LOG_UPDATE" then
        QueueDisplayRefresh()
        -- Also trigger auto-sync on these events
        AutoSyncQuestTracking()
    end
    -- Monitor for quest share acceptance
    if event == "CHAT_MSG_SYSTEM" then
        local message = ...
        -- ERR_QUEST_PUSH_SUCCESS_S is "%s accepted your quest."
        -- Create a pattern from the global string
        local pattern = string.gsub(ERR_QUEST_PUSH_SUCCESS_S, "%%s", "(.+)")
        local characterName = string.match(message, pattern)
        
        if characterName then
            -- Wait 1 second then refresh auto-sync to pick up the newly shared quest
            C_Timer.After(1, function()
                AutoSyncQuestTracking()
                RefreshQuestWindowIfVisible()
            end)
        end
    end
end)

-- Register quest-related events for auto refresh
frame:RegisterEvent("QUEST_ACCEPTED")
frame:RegisterEvent("QUEST_REMOVED")
frame:RegisterEvent("QUEST_WATCH_LIST_CHANGED")
frame:RegisterEvent("QUEST_LOG_UPDATE")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("CHAT_MSG_SYSTEM")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("QUEST_TURNED_IN")
frame:RegisterEvent("QUEST_DATA_LOAD_RESULT")