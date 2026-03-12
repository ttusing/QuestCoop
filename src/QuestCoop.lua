local addonName, addon = ...

-- Default settings
local DEFAULT_SETTINGS = {
    textSize = "medium", -- small, medium, large
}

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
    
    if sharedQuestCount > 0 then
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
        end -- end if totalQuests > 0
    end -- end for players loop

    local totalHeight = (-yOff) + 4
    questScrollChild:SetHeight(totalHeight)
    questWindow:Show()
end

-- Minimap button creation
local minimapButton
local function CreateMinimapButton()
    if minimapButton then return end
    
    minimapButton = CreateFrame("Button", "QuestCoopMinimapButton", Minimap)
    minimapButton:SetSize(32, 32)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    
    -- Icon texture
    local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01") -- Quest scroll icon
    minimapButton.icon = icon
    
    -- Border
    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetSize(52, 52)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    
    -- Click handler
    minimapButton:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            PrintQuestIDs()
        elseif button == "RightButton" then
            if InterfaceOptionsFrame_OpenToCategory then
                InterfaceOptionsFrame_OpenToCategory(settingsPanel)
                InterfaceOptionsFrame_OpenToCategory(settingsPanel)
            elseif Settings and Settings.OpenToCategory then
                Settings.OpenToCategory(settingsPanel.name)
            end
        end
    end)
    
    -- Tooltip
    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Quest Co-op", 1, 1, 1)
        GameTooltip:AddLine("Left-click: Show quest window", 0.5, 1, 0.5)
        GameTooltip:AddLine("Right-click: Settings", 0.5, 1, 0.5)
        GameTooltip:Show()
    end)
    
    minimapButton:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
    
    -- Dragging functionality
    minimapButton:SetMovable(true)
    minimapButton:EnableMouse(true)
    minimapButton:RegisterForDrag("LeftButton")
    
    local function UpdatePosition()
        local angle = QuestCoopDB.minimapAngle or 225
        local x, y = math.cos(angle), math.sin(angle)
        minimapButton:SetPoint("CENTER", Minimap, "CENTER", x * 100, y * 100)
    end
    
    minimapButton:SetScript("OnDragStart", function(self)
        self:LockHighlight()
        self.isDragging = true
    end)
    
    minimapButton:SetScript("OnDragStop", function(self)
        self:UnlockHighlight()
        self.isDragging = false
    end)
    
    minimapButton:SetScript("OnUpdate", function(self)
        if self.isDragging then
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            px, py = px / scale, py / scale
            
            local angle = math.atan2(py - my, px - mx)
            QuestCoopDB.minimapAngle = angle
            UpdatePosition()
        end
    end)
    
    UpdatePosition()
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
end)

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
        
        -- Create minimap button
        CreateMinimapButton()
        
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
        
        -- Run initial auto-sync after login
        C_Timer.After(2, AutoSyncQuestTracking)
    end
    -- Auto-refresh triggers
    if event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED" or event == "QUEST_WATCH_LIST_CHANGED" or event == "QUEST_LOG_UPDATE" or event == "GROUP_ROSTER_UPDATE" then
        RefreshQuestWindowIfVisible()
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