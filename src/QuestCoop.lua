local addonName, addon = ...

-- Default settings
local DEFAULT_SETTINGS = {
    textSize = "medium", -- small, medium, large
    alwaysLeader = false,
    showWorldQuestsInRecent = false,
    maxQuestsToTrack = 5,
}

-- QC categories that are hidden from the window entirely
local HIDDEN_CATEGORIES = {
    ["Emissary Quest"] = true,
    ["Island Weekly Quest"] = true,
    ["Hidden"] = true,
}

-- Tracking mode cycling and display
local TRACK_MODE_CYCLE   = {auto = "always", always = "never", never = "auto"}
local TRACK_MODE_LABELS  = {auto = "Auto", always = "Always", never = "Never"}
local TRACK_MODE_COLORS  = {
    auto   = {0.7, 0.7, 0.7},
    always = {0.3, 1.0, 0.3},
    never  = {1.0, 0.4, 0.4},
}

local function ShortName(name)
    if not name then return "?" end
    return name:match("^[^%-]+") or name
end

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

-- Determine the QC category for a quest. Prefers WoW tag, falls back to campaign/zone/general.
local function GetQuestCategory(questInfo, questTagInfo)
    if questTagInfo and questTagInfo.tagName and questTagInfo.tagName ~= "" then
        if HIDDEN_CATEGORIES[questTagInfo.tagName] then
            return "Hidden"
        end
        return questTagInfo.tagName
    end
    if questInfo.campaignID then
        return "Campaign"
    end
    if questInfo.zoneOrSort and questInfo.zoneOrSort ~= "" then
        return questInfo.zoneOrSort
    end
    return "General"
end

-- Party / leader management
local leaderPrefs = {}

local function IsQuestCoopActive()
    local _, instanceType = IsInInstance()
    return instanceType ~= "pvp" and instanceType ~= "arena" and instanceType ~= "raid"
end

-- Quest activity timestamps for smart tracking
local questLastActivity = {} -- [questID] = GetTime()

-- QC Alerts data
local recentlyCompletedQuests = {}  -- [questID] = {title, completors, completorSet}
local pendingCompletedQuests = {}
local selfCompletedQuests = {}
local notSharedAlerts = {}          -- [questID] = {title, detectedTime}

-- Forward declarations
local RefreshQuestWindowIfVisible
local ToggleQCAlertsWindow
local ShowQCAlerts
local RefreshQCAlertsWindow
local RemoveQuestFromRecentlyCompleted

local function BroadcastLeaderPref()
    if not IsQuestCoopActive() then return end
    if not IsInGroup() then return end
    local val = GetSetting("alwaysLeader") and "1" or "0"
    C_ChatInfo.SendAddonMessage("QuestCoop", "LEADER_PREF|" .. val, "PARTY")
end

local function CleanupLeaderPrefs()
    local currentMembers = {}
    currentMembers[ShortName(UnitName("player"))] = true
    for i = 1, GetNumGroupMembers() do
        local unit = (IsInRaid() and "raid" or "party") .. i
        local name = UnitName(unit)
        if name then currentMembers[ShortName(name)] = true end
    end
    for name in pairs(leaderPrefs) do
        if not currentMembers[name] then leaderPrefs[name] = nil end
    end
end

local function GetWoWPartyLeaderName()
    local units = {"player"}
    for i = 1, GetNumGroupMembers() do
        table.insert(units, (IsInRaid() and "raid" or "party") .. i)
    end
    for _, unit in ipairs(units) do
        if UnitIsGroupLeader(unit) then
            return ShortName(UnitName(unit))
        end
    end
    return ShortName(UnitName("player"))
end

local function GetQuestCoopLeader()
    local selfName = ShortName(UnitName("player"))
    leaderPrefs[selfName] = GetSetting("alwaysLeader")
    local candidates = {}
    for name, wantsLeader in pairs(leaderPrefs) do
        if wantsLeader then table.insert(candidates, name) end
    end
    if #candidates == 0 then return GetWoWPartyLeaderName() end
    table.sort(candidates)
    return candidates[1]
end

-- Tracking mode management
local function GetTrackingModeStore()
    if not QuestCoopDB then QuestCoopDB = {} end
    if not QuestCoopDB.questTrackingMode then QuestCoopDB.questTrackingMode = {} end
    return QuestCoopDB.questTrackingMode
end

-- Returns nil (auto), "always", or "never"
local function GetEffectiveTrackingMode(questID)
    return GetTrackingModeStore()[questID]
end

local function GetEffectiveMaxTrack()
    return GetSetting("maxQuestsToTrack")
end

local function BroadcastQuestTrackList(toTrack)
    if not IsQuestCoopActive() then return end
    if not IsInGroup() then return end
    local selfName = ShortName(UnitName("player"))
    if GetQuestCoopLeader() ~= selfName then return end
    local ids = {}
    for questID in pairs(toTrack) do
        table.insert(ids, tostring(questID))
    end
    C_ChatInfo.SendAddonMessage("QuestCoop", "QUEST_TRACK|" .. table.concat(ids, ","), "PARTY")
end

local function SetQuestTrackingMode(questID, mode)
    -- mode: nil = auto, "always", "never"
    GetTrackingModeStore()[questID] = mode
end

local function BroadcastQuestCompleted(questID)
    if not IsQuestCoopActive() then return end
    if not IsInGroup() then return end
    if not GetSetting("showWorldQuestsInRecent") and C_QuestLog.IsWorldQuest and C_QuestLog.IsWorldQuest(questID) then return end
    local title = (C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)) or ("Quest " .. questID)
    C_ChatInfo.SendAddonMessage("QuestCoop", string.format("QUEST_COMPLETED|%d|%s", questID, title or ""), "PARTY")
end

local function GetPartyMemberQuestData(unit, questID)
    if not C_QuestLog.IsUnitOnQuest then return nil end
    local isOnQuest = C_QuestLog.IsUnitOnQuest(unit, questID)
    if not isOnQuest then return nil end
    return {has = true}
end

-- Smart quest tracking: selects up to maxQuestsToTrack quests, prioritizing
-- always-track, campaign, recent activity, and current zone.
-- Only the QuestCoop leader (or a solo player) runs the algorithm and applies tracking;
-- non-leaders receive the computed list via QUEST_TRACK addon messages.
local function AutoSyncQuestTracking()
    if not IsQuestCoopActive() then return end
    local selfName = ShortName(UnitName("player"))
    local isLeader = not IsInGroup() or GetQuestCoopLeader() == selfName
    if not isLeader then return end

    local currentTime = GetTime()
    local maxTrack = GetEffectiveMaxTrack()
    local currentZone = GetZoneText() or ""

    local numEntries = C_QuestLog.GetNumQuestLogEntries()
    local alwaysQuests = {}
    local autoQuests = {}

    for i = 1, numEntries do
        local questInfo = C_QuestLog.GetInfo(i)
        if questInfo and not questInfo.isHeader then
            local questID = questInfo.questID
            if questID then
                local questTagInfo = C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(questID)
                local category = GetQuestCategory(questInfo, questTagInfo)
                if category ~= "Hidden" then
                    local mode = GetEffectiveTrackingMode(questID)
                    if mode == "always" then
                        table.insert(alwaysQuests, {id = questID, category = category})
                    elseif mode ~= "never" then
                        local score = 0
                        if questInfo.campaignID then score = score + 3 end
                        local lastActivity = questLastActivity[questID]
                        if lastActivity and (currentTime - lastActivity) < 600 then
                            score = score + 2
                        end
                        if category == currentZone or (questInfo.zoneOrSort and questInfo.zoneOrSort == currentZone) then
                            score = score + 1
                        end
                        table.insert(autoQuests, {id = questID, score = score})
                    end
                end
            end
        end
    end

    table.sort(autoQuests, function(a, b) return a.score > b.score end)

    local toTrack = {}
    for _, q in ipairs(alwaysQuests) do
        toTrack[q.id] = true
    end
    local remaining = math.max(0, maxTrack - #alwaysQuests)
    for i = 1, remaining do
        if autoQuests[i] then toTrack[autoQuests[i].id] = true end
    end

    -- Apply tracking state
    for i = 1, numEntries do
        local questInfo = C_QuestLog.GetInfo(i)
        if questInfo and not questInfo.isHeader then
            local questID = questInfo.questID
            if questID then
                local isTracked = C_QuestLog.GetQuestWatchType and C_QuestLog.GetQuestWatchType(questID) ~= nil
                if toTrack[questID] and not isTracked then
                    if C_QuestLog.AddQuestWatch then C_QuestLog.AddQuestWatch(questID) end
                elseif not toTrack[questID] and isTracked then
                    if C_QuestLog.RemoveQuestWatch then C_QuestLog.RemoveQuestWatch(questID) end
                end
            end
        end
    end

    -- Alert for always-track quests not shared by the whole party
    if IsInGroup() then
        -- Build set of current always-quests for O(1) lookup
        local alwaysQuestSet = {}
        for _, q in ipairs(alwaysQuests) do alwaysQuestSet[q.id] = true end

        -- Clear stale alerts: quest no longer "always" mode, or now shared by everyone
        local anyCleared = false
        for questID in pairs(notSharedAlerts) do
            if not alwaysQuestSet[questID] then
                notSharedAlerts[questID] = nil
                anyCleared = true
            else
                local sharedByAll = true
                for i = 1, GetNumGroupMembers() do
                    local unit = (IsInRaid() and "raid" or "party") .. i
                    local questData = GetPartyMemberQuestData(unit, questID)
                    if not questData or not questData.has then
                        sharedByAll = false
                        break
                    end
                end
                if sharedByAll then
                    notSharedAlerts[questID] = nil
                    anyCleared = true
                end
            end
        end
        if anyCleared then RefreshQCAlertsWindow() end

        -- Add new alerts for always-quests missing from some party members
        for _, q in ipairs(alwaysQuests) do
            local questID = q.id
            if not notSharedAlerts[questID] then
                local sharedByAll = true
                for i = 1, GetNumGroupMembers() do
                    local unit = (IsInRaid() and "raid" or "party") .. i
                    local questData = GetPartyMemberQuestData(unit, questID)
                    if not questData or not questData.has then
                        sharedByAll = false
                        break
                    end
                end
                if not sharedByAll then
                    local title = (C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)) or ("Quest " .. questID)
                    notSharedAlerts[questID] = {title = title, detectedTime = currentTime}
                    ShowQCAlerts()
                end
            end
        end
    end

    BroadcastQuestTrackList(toTrack)
end

-- Forward declarations for quest window
local questWindow, questScrollFrame, questScrollChild, questLeaderLabel
local function CreateQuestWindow()
    if questWindow then return end
    questWindow = CreateFrame("Frame", "QuestCoopQuestWindow", UIParent, "BackdropTemplate")

    local savedW = QuestCoopDB and QuestCoopDB.questWindowWidth or 440
    local savedH = QuestCoopDB and QuestCoopDB.questWindowHeight or 300
    questWindow:SetSize(savedW, savedH)
    questWindow:SetPoint("CENTER")
    questWindow:SetMovable(true)
    questWindow:SetResizable(true)
    questWindow:SetResizeBounds(320, 200)
    questWindow:EnableMouse(true)
    questWindow:RegisterForDrag("LeftButton")
    questWindow:SetScript("OnDragStart", function(self) self:StartMoving() end)
    questWindow:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    questWindow:SetBackdrop({bgFile = "Interface/Tooltips/UI-Tooltip-Background", edgeFile = "Interface/Tooltips/UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = {left = 4, right = 4, top = 4, bottom = 4}})
    questWindow:SetBackdropColor(0, 0, 0, 0.85)
    questWindow:Hide()

    local title = questWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("Quest Co-op")

    questLeaderLabel = questWindow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    questLeaderLabel:SetPoint("TOP", 0, -30)
    questLeaderLabel:SetTextColor(1, 0.85, 0)
    questLeaderLabel:SetText("QuestCoop Leader: ...")

    local close = CreateFrame("Button", nil, questWindow, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    local alertBtn = CreateFrame("Button", nil, questWindow, "UIPanelButtonTemplate")
    alertBtn:SetSize(120, 20)
    alertBtn:SetPoint("TOP", questLeaderLabel, "BOTTOM", 0, -4)
    alertBtn:SetText("QC Alerts")
    alertBtn:SetScript("OnClick", function() ToggleQCAlertsWindow() end)

    questScrollFrame = CreateFrame("ScrollFrame", "QuestCoopQuestScroll", questWindow, "UIPanelScrollFrameTemplate")
    questScrollFrame:SetPoint("TOPLEFT", 16, -82)
    questScrollFrame:SetPoint("BOTTOMRIGHT", -30, 16)

    questScrollChild = CreateFrame("Frame", nil, questScrollFrame)
    questScrollChild:SetSize(400, 1)
    questScrollFrame:SetScrollChild(questScrollChild)
    questScrollChild.lines = {}

    local resizeHandle = CreateFrame("Button", nil, questWindow)
    resizeHandle:SetSize(16, 16)
    resizeHandle:SetPoint("BOTTOMRIGHT", -4, 4)
    resizeHandle:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeHandle:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeHandle:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeHandle:SetScript("OnMouseDown", function() questWindow:StartSizing("BOTTOMRIGHT") end)
    resizeHandle:SetScript("OnMouseUp", function()
        questWindow:StopMovingOrSizing()
        if not QuestCoopDB then QuestCoopDB = {} end
        QuestCoopDB.questWindowWidth  = questWindow:GetWidth()
        QuestCoopDB.questWindowHeight = questWindow:GetHeight()
        RefreshQuestWindowIfVisible()
    end)
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

    -- Text Size
    local textSizeLabel = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    textSizeLabel:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -24)
    textSizeLabel:SetText("Text Size:")

    local textSizeDropdown = CreateFrame("Frame", "QuestCoopTextSizeDropdown", settingsPanel, "UIDropDownMenuTemplate")
    textSizeDropdown:SetPoint("TOPLEFT", textSizeLabel, "BOTTOMLEFT", -15, -8)

    local textSizeOptions = {
        {text = "Small",  value = "small"},
        {text = "Medium", value = "medium"},
        {text = "Large",  value = "large"},
    }

    local function TextSizeDropdown_OnClick(self)
        SetSetting("textSize", self.value)
        UIDropDownMenu_SetText(textSizeDropdown, self:GetText())
        RefreshQuestWindowIfVisible()
    end

    UIDropDownMenu_Initialize(textSizeDropdown, function(self, level)
        local info = UIDropDownMenu_CreateInfo()
        for _, option in ipairs(textSizeOptions) do
            info.text    = option.text
            info.value   = option.value
            info.func    = TextSizeDropdown_OnClick
            info.checked = (GetSetting("textSize") == option.value)
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetWidth(textSizeDropdown, 120)

    local currentSize = GetSetting("textSize")
    for _, option in ipairs(textSizeOptions) do
        if option.value == currentSize then
            UIDropDownMenu_SetText(textSizeDropdown, option.text)
            break
        end
    end

    -- Always Leader
    local alwaysLeaderCheckbox = CreateFrame("CheckButton", "QuestCoopAlwaysLeaderCheckbox", settingsPanel, "UICheckButtonTemplate")
    alwaysLeaderCheckbox:SetPoint("TOPLEFT", textSizeDropdown, "BOTTOMLEFT", 15, -16)
    alwaysLeaderCheckbox:SetChecked(GetSetting("alwaysLeader"))
    alwaysLeaderCheckbox:SetScript("OnClick", function(self)
        SetSetting("alwaysLeader", self:GetChecked())
        BroadcastLeaderPref()
        RefreshQuestWindowIfVisible()
    end)

    local alwaysLeaderLabel = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    alwaysLeaderLabel:SetPoint("LEFT", alwaysLeaderCheckbox, "RIGHT", 2, 0)
    alwaysLeaderLabel:SetText("Always be QuestCoop Leader")

    local alwaysLeaderDesc = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    alwaysLeaderDesc:SetPoint("TOPLEFT", alwaysLeaderCheckbox, "BOTTOMLEFT", 4, -4)
    alwaysLeaderDesc:SetText("If multiple party members have this checked, the alphabetically earliest name leads. Overrides the WoW party leader.")

    -- Max Quests to Track
    local maxTrackLabel = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    maxTrackLabel:SetPoint("TOPLEFT", alwaysLeaderDesc, "BOTTOMLEFT", -4, -20)
    maxTrackLabel:SetText("Max Quests to Track:")

    local maxTrackSlider = CreateFrame("Slider", "QuestCoopMaxTrackSlider", settingsPanel, "OptionsSliderTemplate")
    maxTrackSlider:SetPoint("TOPLEFT", maxTrackLabel, "BOTTOMLEFT", 0, -14)
    maxTrackSlider:SetMinMaxValues(1, 20)
    maxTrackSlider:SetValueStep(1)
    maxTrackSlider:SetValue(GetSetting("maxQuestsToTrack"))
    maxTrackSlider:SetWidth(200)
    if maxTrackSlider.SetObeyStepOnDrag then maxTrackSlider:SetObeyStepOnDrag(true) end
    _G[maxTrackSlider:GetName() .. "Low"]:SetText("1")
    _G[maxTrackSlider:GetName() .. "High"]:SetText("20")
    _G[maxTrackSlider:GetName() .. "Text"]:SetText("")

    local maxTrackValueLabel = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    maxTrackValueLabel:SetPoint("LEFT", maxTrackSlider, "RIGHT", 10, 0)
    maxTrackValueLabel:SetText(tostring(GetSetting("maxQuestsToTrack")))

    maxTrackSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        SetSetting("maxQuestsToTrack", value)
        maxTrackValueLabel:SetText(tostring(value))
        AutoSyncQuestTracking()
    end)

    local maxTrackDesc = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    maxTrackDesc:SetPoint("TOPLEFT", maxTrackSlider, "BOTTOMLEFT", 0, -10)
    maxTrackDesc:SetText("Max tracked quests. 'Always' mode quests count toward this limit first. Leader's value syncs to party.")

    -- World Quests in QC Alerts
    local worldQuestCheckbox = CreateFrame("CheckButton", "QuestCoopWorldQuestCheckbox", settingsPanel, "UICheckButtonTemplate")
    worldQuestCheckbox:SetPoint("TOPLEFT", maxTrackDesc, "BOTTOMLEFT", -4, -16)
    worldQuestCheckbox:SetChecked(GetSetting("showWorldQuestsInRecent"))
    worldQuestCheckbox:SetScript("OnClick", function(self)
        SetSetting("showWorldQuestsInRecent", self:GetChecked())
    end)

    local worldQuestLabel = settingsPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    worldQuestLabel:SetPoint("LEFT", worldQuestCheckbox, "RIGHT", 2, 0)
    worldQuestLabel:SetText("Show World Quests in QC Alerts")

    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(settingsPanel)
    elseif Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(settingsPanel, settingsPanel.name)
        Settings.RegisterAddOnCategory(category)
    end

    return settingsPanel
end

RefreshQuestWindowIfVisible = function()
    if not questWindow or not questWindow:IsShown() then return end
    PrintQuestIDs(true)
end

-- Main quest window rendering
function PrintQuestIDs(silentRefresh)
    CreateQuestWindow()
    if questLeaderLabel then
        questLeaderLabel:SetText("QuestCoop Leader: " .. GetQuestCoopLeader())
    end

    local playerName = UnitName("player")
    local questsByPlayer = {}
    questsByPlayer[playerName] = {}

    local numEntries = C_QuestLog.GetNumQuestLogEntries()
    local shiftDown = IsShiftKeyDown and IsShiftKeyDown() and not silentRefresh

    -- Collect local player's quests
    for i = 1, numEntries do
        local questInfo = C_QuestLog.GetInfo(i)
        if questInfo and not questInfo.isHeader then
            local questID = questInfo.questID
            if questID then
                local title = questInfo.title or "(no title)"
                local questTagInfo = C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(questID)
                local category = GetQuestCategory(questInfo, questTagInfo)

                if category ~= "Hidden" then
                    local tracked = C_QuestLog.GetQuestWatchType and C_QuestLog.GetQuestWatchType(questID) ~= nil
                    local ready = (C_QuestLog.IsComplete and C_QuestLog.IsComplete(questID))
                        or (questInfo.isComplete ~= nil and questInfo.isComplete)

                    if not questsByPlayer[playerName][category] then
                        questsByPlayer[playerName][category] = {}
                    end
                    table.insert(questsByPlayer[playerName][category], {
                        id = questID, title = title,
                        tracked = tracked, ready = ready,
                        tag = questTagInfo, category = category,
                        isCampaign = questInfo.campaignID ~= nil,
                        isLocal = true,
                    })

                    if shiftDown then
                        print(string.format("QuestCoop: %d - %s [%s]%s", questID, title, category, questInfo.campaignID and " [Campaign]" or ""))
                    end
                end
            end
        end
    end

    -- Collect party members' quests
    if IsInGroup() then
        for i = 1, GetNumGroupMembers() do
            local unit = (IsInRaid() and "raid" or "party") .. i
            local partyMember = UnitName(unit)
            if partyMember and ShortName(partyMember) ~= ShortName(playerName) then
                questsByPlayer[partyMember] = {}
                for j = 1, numEntries do
                    local questInfo = C_QuestLog.GetInfo(j)
                    if questInfo and not questInfo.isHeader then
                        local questID = questInfo.questID
                        if questID then
                            local questData = GetPartyMemberQuestData(unit, questID)
                            if questData and questData.has then
                                local questTagInfo = C_QuestLog.GetQuestTagInfo and C_QuestLog.GetQuestTagInfo(questID)
                                local category = GetQuestCategory(questInfo, questTagInfo)
                                if category ~= "Hidden" then
                                    if not questsByPlayer[partyMember][category] then
                                        questsByPlayer[partyMember][category] = {}
                                    end
                                    local title = questInfo.title or ("Quest " .. questID)
                                    table.insert(questsByPlayer[partyMember][category], {
                                        id = questID, title = title,
                                        tracked = false, ready = false,
                                        tag = questTagInfo, category = category,
                                        isCampaign = questInfo.campaignID ~= nil,
                                        isLocal = false,
                                    })
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Build party member list and find shared quests
    local allPartyMembers = {}
    for member in pairs(questsByPlayer) do table.insert(allPartyMembers, member) end
    local partySize = #allPartyMembers

    local sharedQuestsByCategory = {}
    if partySize > 1 then
        local allQuestIDs = {}
        for category, quests in pairs(questsByPlayer[allPartyMembers[1]]) do
            for _, quest in ipairs(quests) do
                allQuestIDs[quest.id] = {category = category, quest = quest}
            end
        end
        for questID, info in pairs(allQuestIDs) do
            local sharedByAll = true
            for i = 2, partySize do
                local member = allPartyMembers[i]
                local hasQuest = false
                for _, quests in pairs(questsByPlayer[member]) do
                    for _, q in ipairs(quests) do
                        if q.id == questID then hasQuest = true; break end
                    end
                    if hasQuest then break end
                end
                if not hasQuest then sharedByAll = false; break end
            end
            if sharedByAll then
                local cat = info.category
                if not sharedQuestsByCategory[cat] then sharedQuestsByCategory[cat] = {} end
                table.insert(sharedQuestsByCategory[cat], info.quest)
            end
        end
    end

    -- Remove shared quests from individual player lists
    for cat, sharedQuests in pairs(sharedQuestsByCategory) do
        for _, sq in ipairs(sharedQuests) do
            for member, questsByCategory in pairs(questsByPlayer) do
                if questsByCategory[cat] then
                    for i = #questsByCategory[cat], 1, -1 do
                        if questsByCategory[cat][i].id == sq.id then
                            table.remove(questsByCategory[cat], i)
                        end
                    end
                    if #questsByCategory[cat] == 0 then questsByCategory[cat] = nil end
                end
            end
        end
    end

    -- Clear previous UI elements
    for _, fs in ipairs(questScrollChild.lines) do fs:Hide() end
    wipe(questScrollChild.lines)

    -- Column layout constants
    local COL_TRACK_X = 2
    local COL_ID_X    = 54
    local COL_TITLE_X = 106

    local selfName = ShortName(UnitName("player"))
    local isLeader = (GetQuestCoopLeader() == selfName)

    local textSize = GetSetting("textSize")
    local ROW_HEIGHT          = (textSize == "small" and 14) or (textSize == "large" and 18) or 14
    local PLAYER_HEADING_HEIGHT = (textSize == "large" and 26) or 22
    local SUBHEADING_HEIGHT   = (textSize == "large" and 20) or 18
    local yOff = -2

    local sortedPlayers = {}
    for p in pairs(questsByPlayer) do table.insert(sortedPlayers, p) end
    table.sort(sortedPlayers, function(a, b)
        if a == playerName then return true end
        if b == playerName then return false end
        return a < b
    end)

    local fontSmall, fontNormal, fontLarge = GetFontSize()

    -- Column headers
    local headerTrack = questScrollChild:CreateFontString(nil, "OVERLAY", fontSmall)
    headerTrack:SetPoint("TOPLEFT", COL_TRACK_X, yOff)
    headerTrack:SetJustifyH("LEFT")
    headerTrack:SetTextColor(0.7, 0.7, 0.7)
    headerTrack:SetText("Track")
    table.insert(questScrollChild.lines, headerTrack)

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

    -- Helper: render the multi-state tracking mode button for a quest row
    local function RenderTrackButton(questID, rowYOff)
        local mode = GetEffectiveTrackingMode(questID) or "auto"
        local col = TRACK_MODE_COLORS[mode]

        local btn = CreateFrame("Button", nil, questScrollChild)
        btn:SetSize(50, ROW_HEIGHT + 2)
        btn:SetPoint("TOPLEFT", COL_TRACK_X, rowYOff + 1)

        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(col[1] * 0.2, col[2] * 0.2, col[3] * 0.2, 0.8)

        btn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")

        local fs = btn:CreateFontString(nil, "OVERLAY", fontSmall)
        fs:SetAllPoints()
        fs:SetJustifyH("CENTER")
        fs:SetTextColor(col[1], col[2], col[3])
        fs:SetText(TRACK_MODE_LABELS[mode])

        if isLeader then
            btn:SetScript("OnClick", function()
                local current = GetEffectiveTrackingMode(questID) or "auto"
                local next = TRACK_MODE_CYCLE[current]
                SetQuestTrackingMode(questID, next == "auto" and nil or next)
                AutoSyncQuestTracking()
                RefreshQuestWindowIfVisible()
            end)
        end

        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:AddLine("Quest Tracking Mode", 1, 1, 1)
            GameTooltip:AddLine("Auto: smart selection by priority", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Always: always kept in tracker", 0.3, 1, 0.3)
            GameTooltip:AddLine("Never: never tracked", 1, 0.4, 0.4)
            if isLeader then
                GameTooltip:AddLine("Click to cycle", 1, 0.82, 0)
            else
                GameTooltip:AddLine("Only the QuestCoop leader can change modes", 0.6, 0.6, 0.6)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        table.insert(questScrollChild.lines, btn)
    end

    -- Helper: render a single quest row (track button + id + title + tooltip)
    local function RenderQuestRow(row, rowYOff, tooltipExtraFn)
        RenderTrackButton(row.id, rowYOff)

        local idFS = questScrollChild:CreateFontString(nil, "OVERLAY", fontSmall)
        idFS:SetPoint("TOPLEFT", COL_ID_X, rowYOff)
        idFS:SetJustifyH("LEFT")
        idFS:SetText(row.id)
        table.insert(questScrollChild.lines, idFS)

        local titleFS = questScrollChild:CreateFontString(nil, "OVERLAY", fontNormal)
        titleFS:SetPoint("TOPLEFT", COL_TITLE_X, rowYOff)
        titleFS:SetJustifyH("LEFT")
        if row.isCampaign then
            titleFS:SetTextColor(1, 0.82, 0) -- gold for campaign quests
        else
            titleFS:SetTextColor(1, 1, 1)
        end
        titleFS:SetText(row.title)
        table.insert(questScrollChild.lines, titleFS)

        local rowButton = CreateFrame("Button", nil, questScrollChild)
        rowButton:SetPoint("TOPLEFT", idFS, "TOPLEFT", -2, 2)
        rowButton:SetPoint("BOTTOMRIGHT", titleFS, "BOTTOMRIGHT", 2, -2)
        rowButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        rowButton:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                MenuUtil.CreateContextMenu(UIParent, function(owner, rootDescription)
                    rootDescription:CreateTitle(row.title)
                    rootDescription:CreateButton("Share Quest", function()
                        C_QuestLog.SetSelectedQuest(row.id)
                        QuestLogPushQuest()
                    end)
                    rootDescription:CreateButton("Cancel", function() end)
                end)
            end
        end)
        rowButton:SetScript("OnEnter", function()
            GameTooltip:SetOwner(rowButton, "ANCHOR_CURSOR")
            GameTooltip:AddLine(row.title, 1, 1, 1, true)
            GameTooltip:AddLine(string.format("Quest ID: %d", row.id), 0.9, 0.9, 0.9)
            GameTooltip:AddLine("Category: " .. row.category, 0.8, 0.8, 0.8)
            if row.isCampaign then
                GameTooltip:AddLine("Campaign Quest", 1, 0.82, 0)
            end
            if tooltipExtraFn then tooltipExtraFn() end
            if IsInGroup() then
                local hasMembers = {}
                for j = 1, GetNumGroupMembers() do
                    local unit = (IsInRaid() and "raid" or "party") .. j
                    local memberName = UnitName(unit)
                    if memberName then
                        local questData = GetPartyMemberQuestData(unit, row.id)
                        if questData and questData.has then
                            table.insert(hasMembers, ShortName(memberName))
                        end
                    end
                end
                if #hasMembers > 0 then
                    table.sort(hasMembers)
                    GameTooltip:AddLine("Has: " .. table.concat(hasMembers, ", "), 0.7, 0.9, 0.7)
                end
            end
            GameTooltip:Show()
        end)
        rowButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
        table.insert(questScrollChild.lines, rowButton)
    end

    -- Shared quests section
    local sharedQuestCount = 0
    for _, quests in pairs(sharedQuestsByCategory) do sharedQuestCount = sharedQuestCount + #quests end

    if sharedQuestCount > 0 then
        local sharedHeading = questScrollChild:CreateFontString(nil, "OVERLAY", fontLarge)
        sharedHeading:SetPoint("TOPLEFT", 0, yOff)
        sharedHeading:SetJustifyH("LEFT")
        sharedHeading:SetTextColor(0.5, 0.8, 1)
        sharedHeading:SetText(string.format("Shared by All (%d) — %d quest%s", partySize, sharedQuestCount, sharedQuestCount ~= 1 and "s" or ""))
        table.insert(questScrollChild.lines, sharedHeading)
        yOff = yOff - PLAYER_HEADING_HEIGHT

        local sortedSharedCats = {}
        for cat in pairs(sharedQuestsByCategory) do table.insert(sortedSharedCats, cat) end
        table.sort(sortedSharedCats)

        for _, cat in ipairs(sortedSharedCats) do
            local quests = sharedQuestsByCategory[cat]
            local subheading = questScrollChild:CreateFontString(nil, "OVERLAY", fontNormal)
            subheading:SetPoint("TOPLEFT", 10, yOff)
            subheading:SetJustifyH("LEFT")
            subheading:SetTextColor(1, 0.82, 0)
            subheading:SetText(string.format("%s (%d)", cat, #quests))
            table.insert(questScrollChild.lines, subheading)
            yOff = yOff - SUBHEADING_HEIGHT

            for _, row in ipairs(quests) do
                RenderQuestRow(row, yOff, function()
                    GameTooltip:AddLine("Shared by all party members", 0.5, 0.8, 1)
                end)
                yOff = yOff - ROW_HEIGHT - 2
            end
            yOff = yOff - 6
        end
        yOff = yOff - 15
    end

    -- Individual player sections
    for _, pName in ipairs(sortedPlayers) do
        local questsByCategory = questsByPlayer[pName]
        local totalQuests = 0
        for _, quests in pairs(questsByCategory) do totalQuests = totalQuests + #quests end

        if totalQuests > 0 then
            local playerHeading = questScrollChild:CreateFontString(nil, "OVERLAY", fontLarge)
            playerHeading:SetPoint("TOPLEFT", 0, yOff)
            playerHeading:SetJustifyH("LEFT")
            playerHeading:SetTextColor(0.3, 1, 0.3)
            local displayName = ShortName(pName)
            if pName == playerName then displayName = displayName .. " (You)" end
            playerHeading:SetText(string.format("%s — %d unique quest%s", displayName, totalQuests, totalQuests ~= 1 and "s" or ""))
            table.insert(questScrollChild.lines, playerHeading)
            yOff = yOff - PLAYER_HEADING_HEIGHT

            local sortedCats = {}
            for cat in pairs(questsByCategory) do table.insert(sortedCats, cat) end
            table.sort(sortedCats)

            for _, cat in ipairs(sortedCats) do
                local quests = questsByCategory[cat]
                local subheading = questScrollChild:CreateFontString(nil, "OVERLAY", fontNormal)
                subheading:SetPoint("TOPLEFT", 10, yOff)
                subheading:SetJustifyH("LEFT")
                subheading:SetTextColor(1, 0.82, 0)
                subheading:SetText(string.format("%s (%d)", cat, #quests))
                table.insert(questScrollChild.lines, subheading)
                yOff = yOff - SUBHEADING_HEIGHT

                for _, row in ipairs(quests) do
                    RenderQuestRow(row, yOff)
                    yOff = yOff - ROW_HEIGHT - 2
                end
                yOff = yOff - 6
            end
            yOff = yOff - 10
        end
    end

    local totalHeight = (-yOff) + 4
    questScrollChild:SetHeight(totalHeight)
    questScrollChild:SetWidth(math.max(questScrollFrame:GetWidth(), 220))
    questWindow:Show()
end

-- QC Alerts window (replaces "Recently Completed Party Quests")
local qcAlertsWindow, qcAlertsScrollFrame, qcAlertsScrollChild

RefreshQCAlertsWindow = function()
    if not qcAlertsWindow then return end
    if qcAlertsScrollChild.lines then
        for _, el in ipairs(qcAlertsScrollChild.lines) do el:Hide() end
        wipe(qcAlertsScrollChild.lines)
    end
    qcAlertsScrollChild.lines = {}

    local yOff = -2
    local hasEntries = false

    -- Not-shared alerts (always-track quests missing from some party members)
    for questID, data in pairs(notSharedAlerts) do
        hasEntries = true
        local btn = CreateFrame("Button", nil, qcAlertsScrollChild)
        btn:SetPoint("TOPLEFT", 8, yOff)
        btn:SetSize(340, 18)
        btn:RegisterForClicks("RightButtonUp")
        btn:SetScript("OnClick", function()
            notSharedAlerts[questID] = nil
            RefreshQCAlertsWindow()
        end)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetText("Right-click to dismiss", 1, 1, 1)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        local line = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        line:SetAllPoints()
        line:SetJustifyH("LEFT")
        line:SetText(string.format("|cffff9900[!]|r %s — not shared with full party", data.title))
        table.insert(qcAlertsScrollChild.lines, btn)
        yOff = yOff - 18
    end

    -- Recently completed quests
    for questID, data in pairs(recentlyCompletedQuests) do
        hasEntries = true
        local btn = CreateFrame("Button", nil, qcAlertsScrollChild)
        btn:SetPoint("TOPLEFT", 8, yOff)
        btn:SetSize(340, 18)
        btn:RegisterForClicks("RightButtonUp")
        btn:SetScript("OnClick", function()
            RemoveQuestFromRecentlyCompleted(questID)
        end)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetText("Right-click to dismiss", 1, 1, 1)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        local line = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        line:SetAllPoints()
        line:SetJustifyH("LEFT")
        line:SetTextColor(1, 1, 1)
        line:SetText(string.format("%s  |cff90ee90(by %s)|r", data.title, table.concat(data.completors, ", ")))
        table.insert(qcAlertsScrollChild.lines, btn)
        yOff = yOff - 18
    end

    qcAlertsScrollChild:SetHeight((-yOff) + 4)

    if not hasEntries then
        qcAlertsWindow:Hide()
    end
end

local function CreateQCAlertsWindow()
    if qcAlertsWindow then return end
    qcAlertsWindow = CreateFrame("Frame", "QuestCoopQCAlertsWindow", UIParent, "BackdropTemplate")
    qcAlertsWindow:SetSize(380, 200)
    qcAlertsWindow:SetPoint("CENTER", 0, -120)
    qcAlertsWindow:SetMovable(true)
    qcAlertsWindow:EnableMouse(true)
    qcAlertsWindow:RegisterForDrag("LeftButton")
    qcAlertsWindow:SetScript("OnDragStart", function(self) self:StartMoving() end)
    qcAlertsWindow:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    qcAlertsWindow:SetBackdrop({bgFile = "Interface/Tooltips/UI-Tooltip-Background", edgeFile = "Interface/Tooltips/UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = {left = 4, right = 4, top = 4, bottom = 4}})
    qcAlertsWindow:SetBackdropColor(0, 0, 0, 0.85)
    qcAlertsWindow:Hide()

    local title = qcAlertsWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("QC Alerts")

    local close = CreateFrame("Button", nil, qcAlertsWindow, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    qcAlertsScrollFrame = CreateFrame("ScrollFrame", "QuestCoopQCAlertsScroll", qcAlertsWindow, "UIPanelScrollFrameTemplate")
    qcAlertsScrollFrame:SetPoint("TOPLEFT", 16, -40)
    qcAlertsScrollFrame:SetPoint("BOTTOMRIGHT", -30, 16)

    qcAlertsScrollChild = CreateFrame("Frame", nil, qcAlertsScrollFrame)
    qcAlertsScrollChild:SetSize(320, 1)
    qcAlertsScrollFrame:SetScrollChild(qcAlertsScrollChild)
    qcAlertsScrollChild.lines = {}
end

ShowQCAlerts = function()
    CreateQCAlertsWindow()
    RefreshQCAlertsWindow()
    local hasEntries = false
    for _ in pairs(notSharedAlerts) do hasEntries = true; break end
    if not hasEntries then
        for _ in pairs(recentlyCompletedQuests) do hasEntries = true; break end
    end
    if hasEntries then qcAlertsWindow:Show() end
end

ToggleQCAlertsWindow = function()
    CreateQCAlertsWindow()
    if qcAlertsWindow:IsShown() then
        qcAlertsWindow:Hide()
    else
        ShowQCAlerts()
    end
end

local function AddQuestToRecentlyCompleted(questID, title, completors, completorSet)
    recentlyCompletedQuests[questID] = {title = title, completors = completors, completorSet = completorSet}
    C_Timer.After(300, function()
        if recentlyCompletedQuests[questID] then
            RemoveQuestFromRecentlyCompleted(questID)
        end
    end)
    ShowQCAlerts()
end

RemoveQuestFromRecentlyCompleted = function(questID)
    recentlyCompletedQuests[questID] = nil
    pendingCompletedQuests[questID] = nil
    if qcAlertsWindow then RefreshQCAlertsWindow() end
end

-- Minimap button
local minimapButton
local function CreateMinimapButton()
    if minimapButton then return end

    minimapButton = CreateFrame("Button", "QuestCoopMinimapButton", Minimap)
    minimapButton:SetSize(32, 32)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")

    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetSize(52, 52)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

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

    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Quest Co-op", 1, 1, 1)
        GameTooltip:AddLine("Left-click: Show quest window", 0.5, 1, 0.5)
        GameTooltip:AddLine("Right-click: Settings", 0.5, 1, 0.5)
        GameTooltip:Show()
    end)
    minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    minimapButton:SetMovable(true)
    minimapButton:EnableMouse(true)
    minimapButton:RegisterForDrag("LeftButton")

    local function UpdatePosition()
        local angle = QuestCoopDB.minimapAngle or 225
        local x, y = math.cos(angle), math.sin(angle)
        minimapButton:SetPoint("CENTER", Minimap, "CENTER", x * 100, y * 100)
    end

    minimapButton:SetScript("OnDragStart", function(self) self:LockHighlight(); self.isDragging = true end)
    minimapButton:SetScript("OnDragStop", function(self) self:UnlockHighlight(); self.isDragging = false end)
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

-- Event handler frame
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")

local autoSyncTimer = 0
local AUTO_SYNC_INTERVAL = 15

frame:SetScript("OnUpdate", function(self, elapsed)
    autoSyncTimer = autoSyncTimer + elapsed
    if autoSyncTimer >= AUTO_SYNC_INTERVAL then
        autoSyncTimer = 0
        AutoSyncQuestTracking()
    end
end)

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        if not QuestCoopDB then QuestCoopDB = {} end
        if not QuestCoopDB.settings then QuestCoopDB.settings = {} end
        for k, v in pairs(DEFAULT_SETTINGS) do
            if QuestCoopDB.settings[k] == nil then
                QuestCoopDB.settings[k] = v
            end
        end
        -- Migrate old untrackedQuests -> questTrackingMode "never"
        if QuestCoopDB.untrackedQuests then
            if not QuestCoopDB.questTrackingMode then QuestCoopDB.questTrackingMode = {} end
            for questID in pairs(QuestCoopDB.untrackedQuests) do
                if not QuestCoopDB.questTrackingMode[questID] then
                    QuestCoopDB.questTrackingMode[questID] = "never"
                end
            end
            QuestCoopDB.untrackedQuests = nil
        end

        CreateSettingsPanel()
        CreateMinimapButton()

        SLASH_QUESTCOOP1 = "/questcoop"
        SLASH_QUESTCOOP2 = "/qc"
        SlashCmdList["QUESTCOOP"] = function(msg)
            msg = msg:lower():trim()
            if msg == "settings" or msg == "config" or msg == "options" then
                if InterfaceOptionsFrame_OpenToCategory then
                    InterfaceOptionsFrame_OpenToCategory(settingsPanel)
                    InterfaceOptionsFrame_OpenToCategory(settingsPanel)
                elseif Settings and Settings.OpenToCategory then
                    Settings.OpenToCategory(settingsPanel.name)
                end
            else
                PrintQuestIDs()
            end
        end

        C_ChatInfo.RegisterAddonMessagePrefix("QuestCoop")

        C_Timer.After(2, function()
            BroadcastLeaderPref()
            AutoSyncQuestTracking()
        end)
    end

    if event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED" or event == "QUEST_WATCH_LIST_CHANGED" or event == "QUEST_LOG_UPDATE" or event == "GROUP_ROSTER_UPDATE" or event == "QUEST_TURNED_IN" then
        RefreshQuestWindowIfVisible()
        AutoSyncQuestTracking()
    end

    if event == "QUEST_ACCEPTED" then
        local questID = ...
        if questID then questLastActivity[questID] = GetTime() end
    end

    if event == "QUEST_WATCH_UPDATE" then
        local questID = ...
        if questID then questLastActivity[questID] = GetTime() end
    end

    if event == "GROUP_ROSTER_UPDATE" then
        CleanupLeaderPrefs()
        C_Timer.After(1, BroadcastLeaderPref)
        C_Timer.After(1.5, AutoSyncQuestTracking)
    end

    if event == "CHAT_MSG_SYSTEM" and IsQuestCoopActive() then
        local message = ...
        local ok, characterName = pcall(function()
            local pattern = string.gsub(ERR_QUEST_PUSH_SUCCESS_S, "%%s", "(.+)")
            return string.match(message, pattern)
        end)
        if ok and characterName then
            C_Timer.After(1, function()
                AutoSyncQuestTracking()
                RefreshQuestWindowIfVisible()
            end)
        end
    end

    if event == "QUEST_TURNED_IN" then
        local questID = ...
        if questID then
            selfCompletedQuests[questID] = true
            BroadcastQuestCompleted(questID)
            RemoveQuestFromRecentlyCompleted(questID)
        end
    end

    if event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = ...
        if prefix == "QuestCoop" then
            -- LEADER_PREF
            local pref = message:match("^LEADER_PREF|(%d)$")
            if pref then
                leaderPrefs[ShortName(sender)] = (pref == "1")
                RefreshQuestWindowIfVisible()
            end

            -- QUEST_TRACK: leader's computed list of quest IDs to track
            local trackPayload = message:match("^QUEST_TRACK|(.*)$")
            if trackPayload then
                local senderShort = ShortName(sender)
                local leaderName = GetQuestCoopLeader()
                local selfName2 = ShortName(UnitName("player"))
                if senderShort == leaderName and leaderName ~= selfName2 then
                    local toTrack = {}
                    for idStr in trackPayload:gmatch("[^,]+") do
                        local qid = tonumber(idStr)
                        if qid then toTrack[qid] = true end
                    end
                    local numEntries = C_QuestLog.GetNumQuestLogEntries()
                    for i = 1, numEntries do
                        local questInfo = C_QuestLog.GetInfo(i)
                        if questInfo and not questInfo.isHeader and questInfo.questID then
                            local questID = questInfo.questID
                            local isTracked = C_QuestLog.GetQuestWatchType and C_QuestLog.GetQuestWatchType(questID) ~= nil
                            if toTrack[questID] and not isTracked then
                                if C_QuestLog.AddQuestWatch then C_QuestLog.AddQuestWatch(questID) end
                            elseif not toTrack[questID] and isTracked then
                                if C_QuestLog.RemoveQuestWatch then C_QuestLog.RemoveQuestWatch(questID) end
                            end
                        end
                    end
                    RefreshQuestWindowIfVisible()
                end
            end

            -- QUEST_COMPLETED: party member finished a quest
            local completedPayload = message:match("^QUEST_COMPLETED|(.+)$")
            if completedPayload then
                local questIDStr, title = completedPayload:match("^(%d+)|(.*)$")
                local questID = tonumber(questIDStr)
                if questID and title and not selfCompletedQuests[questID] then
                    local senderShort = ShortName(sender)
                    if recentlyCompletedQuests[questID] then
                        local data = recentlyCompletedQuests[questID]
                        if not data.completorSet[senderShort] then
                            data.completorSet[senderShort] = true
                            table.insert(data.completors, senderShort)
                            RefreshQCAlertsWindow()
                        end
                    elseif not pendingCompletedQuests[questID] then
                        pendingCompletedQuests[questID] = {title = title, completors = {senderShort}, completorSet = {[senderShort] = true}}
                        C_Timer.After(10, function()
                            if pendingCompletedQuests[questID] then
                                local pending = pendingCompletedQuests[questID]
                                pendingCompletedQuests[questID] = nil
                                if not selfCompletedQuests[questID] then
                                    AddQuestToRecentlyCompleted(questID, pending.title, pending.completors, pending.completorSet)
                                end
                            end
                        end)
                    else
                        local pending = pendingCompletedQuests[questID]
                        if not pending.completorSet[senderShort] then
                            pending.completorSet[senderShort] = true
                            table.insert(pending.completors, senderShort)
                        end
                    end
                end
            end
        end
    end

    if event == "PLAYER_ENTERING_WORLD" then
        if IsQuestCoopActive() then
            AutoSyncQuestTracking()
            RefreshQuestWindowIfVisible()
        end
    end
end)

-- Register events
frame:RegisterEvent("QUEST_ACCEPTED")
frame:RegisterEvent("QUEST_REMOVED")
frame:RegisterEvent("QUEST_WATCH_LIST_CHANGED")
frame:RegisterEvent("QUEST_LOG_UPDATE")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("CHAT_MSG_SYSTEM")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("QUEST_TURNED_IN")
frame:RegisterEvent("QUEST_WATCH_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
