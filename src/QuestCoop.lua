local addonName, addon = ...
local ADDON_PREFIX = addonName or "QuestCoop"
local ADDON_VERSION = "1"

-- Party quest state cache: partyQuestStates[playerName][questID] = {tracked=bool, ready=bool, has=true, title=title}
local partyQuestStates = {}

-- Re-added utility and party sync functions lost during refactor
local DEBUG = true
local function Log(...)
    if not DEBUG then return end
    print("QuestCoopDBG:", ...)
end

local function EnsurePrefix()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
    end
end

local function BuildLocalSnapshot()
    local snapshot = {}
    local numEntries = C_QuestLog.GetNumQuestLogEntries()
    for i=1,numEntries do
        local qi = C_QuestLog.GetInfo(i)
        if qi and not qi.isHeader and qi.questID then
            local tracked = false
            if C_QuestLog.GetQuestWatchType then
                tracked = C_QuestLog.GetQuestWatchType(qi.questID) ~= nil
            elseif IsQuestWatched then
                local logIndex = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(qi.questID)
                if logIndex then tracked = IsQuestWatched(logIndex) end
            end
            local ready = false
            if C_QuestLog.IsComplete then ready = C_QuestLog.IsComplete(qi.questID)
            elseif IsQuestComplete then ready = IsQuestComplete(qi.questID)
            elseif qi.isComplete ~= nil then ready = qi.isComplete end
            snapshot[qi.questID] = {tracked=tracked, ready=ready, has=true, title=qi.title or "(no title)"}
        end
    end
    return snapshot
end

local function SerializeSnapshot(snapshot)
    local parts = {"SNAP", ADDON_VERSION}
    local entries = {}
    for qid,data in pairs(snapshot) do
        table.insert(entries, string.format("%d,%d,%d", qid, data.tracked and 1 or 0, data.ready and 1 or 0))
    end
    table.insert(parts, table.concat(entries, ";"))
    return table.concat(parts, "|")
end

local function SendSnapshot()
    if not IsInGroup() then return end
    EnsurePrefix()
    local snapshot = BuildLocalSnapshot()
    local msg = SerializeSnapshot(snapshot)
    if #msg > 240 and C_ChatInfo and C_ChatInfo.SendAddonMessage then
        local header = "SNAP_PART|"..ADDON_VERSION
        local current, length = {}, #header
        for qid,data in pairs(snapshot) do
            local seg = string.format("%d,%d,%d;", qid, data.tracked and 1 or 0, data.ready and 1 or 0)
            if length + #seg > 240 then
                C_ChatInfo.SendAddonMessage(ADDON_PREFIX, header.."|"..table.concat(current, ""), "PARTY")
                current = {}; length = #header
            end
            table.insert(current, seg); length = length + #seg
        end
        if #current > 0 then
            C_ChatInfo.SendAddonMessage(ADDON_PREFIX, header.."|"..table.concat(current, ""), "PARTY")
        end
    elseif C_ChatInfo and C_ChatInfo.SendAddonMessage then
        C_ChatInfo.SendAddonMessage(ADDON_PREFIX, msg, "PARTY")
    end
end

local function ApplySnapshot(fromPlayer, snapshotStr)
    partyQuestStates[fromPlayer] = partyQuestStates[fromPlayer] or {}
    for seg in snapshotStr:gmatch("[^;]+") do
        local qid, tracked, ready = seg:match("^(%d+),(%d),(%d)$")
        if qid then
            qid = tonumber(qid)
            local entry = partyQuestStates[fromPlayer][qid] or {}
            entry.has = true
            entry.tracked = tracked == "1"
            entry.ready = ready == "1"
            partyQuestStates[fromPlayer][qid] = entry
        end
    end
end

local function SafeCall(label, func)
    local ok, err = pcall(func)
    if ok then Log("SafeCall success", label) else Log("SafeCall ERROR", label, err) end
end

local function MakeDraggable(frame, key)
    if not frame then return end
    frame:SetMovable(true); frame:EnableMouse(true); frame:RegisterForDrag("LeftButton"); frame:SetClampedToScreen(true)
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if not QuestCoopDB then QuestCoopDB = {} end
        if key then
            local point, _, relativePoint, xOfs, yOfs = self:GetPoint()
            QuestCoopDB[key] = {point=point, relativePoint=relativePoint, x=xOfs, y=yOfs}
        end
    end)
end

local questWindow, questScrollFrame, questScrollChild
local function CreateQuestWindow()
    if questWindow then return end
    questWindow = CreateFrame("Frame", "QuestCoopQuestWindow", UIParent, "BackdropTemplate")
    questWindow:SetSize(560,300)
    questWindow:SetPoint("CENTER")
    questWindow:SetMovable(true)
    questWindow:EnableMouse(true)
    questWindow:RegisterForDrag("LeftButton")
    questWindow:SetScript("OnDragStart", function(self) self:StartMoving() end)
    questWindow:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    questWindow:SetBackdrop({bgFile="Interface/Tooltips/UI-Tooltip-Background", edgeFile="Interface/Tooltips/UI-Tooltip-Border", tile=true, tileSize=16, edgeSize=16, insets={left=4,right=4,top=4,bottom=4}})
    questWindow:SetBackdropColor(0,0,0,0.85)
    questWindow:Hide()

    local title = questWindow:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    title:SetPoint("TOP",0,-10); title:SetText("Quest Co-op")
    local close = CreateFrame("Button", nil, questWindow, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT",0,0)

    questScrollFrame = CreateFrame("ScrollFrame","QuestCoopQuestScroll",questWindow,"UIPanelScrollFrameTemplate")
    questScrollFrame:SetPoint("TOPLEFT",16,-40); questScrollFrame:SetPoint("BOTTOMRIGHT",-30,16)
    questScrollChild = CreateFrame("Frame", nil, questScrollFrame)
    questScrollChild:SetSize(520,1)
    questScrollFrame:SetScrollChild(questScrollChild)
    questScrollChild.lines = {}
end

local function RefreshQuestWindowIfVisible()
    if questWindow and questWindow:IsShown() then PrintQuestIDs(true) end
end

local function ShortName(name)
    if not name then return "?" end
    return name:match("^[^%-]+") or name
end

-- Function to print current quest IDs
-- PrintQuestIDs(silentRefresh)
-- When silentRefresh is true, we don't echo to chat even if shift is down.
function PrintQuestIDs(silentRefresh)
    Log("PrintQuestIDs START")
    CreateQuestWindow()
    local rows = {}
    local numEntries = C_QuestLog.GetNumQuestLogEntries()
    Log("PrintQuestIDs numEntries", numEntries)
    local shiftDown = IsShiftKeyDown and IsShiftKeyDown() and not silentRefresh
    if shiftDown and not silentRefresh then
        print("QuestCoop: (Shift) Also printing quest IDs to chat...")
    end

    for i = 1, numEntries do
        local questInfo = C_QuestLog.GetInfo(i)
        Log("PrintQuestIDs loop", i, questInfo and questInfo.title, questInfo and questInfo.isHeader)
        if questInfo and not questInfo.isHeader then
            local questID = questInfo.questID
            if questID then
                local title = questInfo.title or "(no title)"
                -- Tracked state
                local tracked = false
                if C_QuestLog.GetQuestWatchType then
                    tracked = C_QuestLog.GetQuestWatchType(questID) ~= nil
                elseif IsQuestWatched then
                    local logIndex = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
                    if logIndex then tracked = IsQuestWatched(logIndex) end
                end
                local trackText = tracked and "Yes" or "No"
                -- Ready state
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
                local isHidden = questTagInfo and questTagInfo.tagName == "Hidden Quest"
                if isHidden then
                    Log("Skipping hidden quest", questID, title)
                else
                    local zoneOrSort = questInfo.campaignID and ("Campaign") or (questInfo.zoneOrSort or "")
                    local detailedCategory = questInfo.header and questInfo.header or zoneOrSort
                    Log("Quest data", questID, "tag:", questTagInfo and questTagInfo.tagName or "nil", "category:", detailedCategory, "zone:", zoneOrSort)
                    table.insert(rows, {id = questID, title = title, tracked = trackText, inlog = "Yes", ready = readyText, tag = questTagInfo, category = detailedCategory, zoneOrSort = zoneOrSort, questInfo = questInfo})
                    local chatLine = string.format("%d - %s (Tracked:%s Ready:%s)", questID, title, trackText, readyText)
                    Log("PrintQuestIDs row", chatLine)
                    if shiftDown and not silentRefresh then print("QuestCoop:", chatLine) end
                end
            end
        end
    end

    -- Clear previous fontstrings
    for _, fs in ipairs(questScrollChild.lines) do fs:Hide() end
    if wipe then wipe(questScrollChild.lines) else for k in pairs(questScrollChild.lines) do questScrollChild.lines[k]=nil end end

    -- Column layout constants
    local COL_ID_X = 0
    local COL_TITLE_X = 60
    local COL_TRACKED_X = 270
    local COL_INLOG_X = 330
    local COL_READY_X = 390
    local ROW_HEIGHT = 14
    local yOff = -2

    -- Header row: use individual header cells for precise alignment
    local headerID = questScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerID:SetPoint("TOPLEFT", COL_ID_X, yOff)
    headerID:SetJustifyH("LEFT")
    headerID:SetText("ID")
    table.insert(questScrollChild.lines, headerID)

    local headerTitle = questScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerTitle:SetPoint("TOPLEFT", COL_TITLE_X, yOff)
    headerTitle:SetJustifyH("LEFT")
    headerTitle:SetText("Title")
    table.insert(questScrollChild.lines, headerTitle)

    local headerTracked = questScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerTracked:SetPoint("TOPLEFT", COL_TRACKED_X, yOff)
    headerTracked:SetJustifyH("LEFT")
    headerTracked:SetText("Trk")
    table.insert(questScrollChild.lines, headerTracked)

    local headerInLog = questScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerInLog:SetPoint("TOPLEFT", COL_INLOG_X, yOff)
    headerInLog:SetJustifyH("LEFT")
    headerInLog:SetText("Log")
    table.insert(questScrollChild.lines, headerInLog)

    local headerReady = questScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerReady:SetPoint("TOPLEFT", COL_READY_X, yOff)
    headerReady:SetJustifyH("LEFT")
    headerReady:SetText("Ready")
    table.insert(questScrollChild.lines, headerReady)
    yOff = yOff - ROW_HEIGHT - 4

    -- Merge quests that party members have which we do not.
    local rowMap = {}
    for _, r in ipairs(rows) do rowMap[r.id] = r end
    for player, quests in pairs(partyQuestStates) do
        for qid, data in pairs(quests) do
            if data.has and not rowMap[qid] then
                table.insert(rows, {id = qid, title = data.title or ("Quest "..qid), tracked = data.tracked and "Yes" or "No", inlog = "No", ready = data.ready and "Yes" or "No", remoteOnly = true})
                rowMap[qid] = rows[#rows]
            end
        end
    end
    table.sort(rows, function(a,b) return a.id < b.id end)

    for _, row in ipairs(rows) do
        -- ID cell
        local idFS = questScrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        idFS:SetPoint("TOPLEFT", COL_ID_X, yOff)
        idFS:SetJustifyH("LEFT")
        idFS:SetText(row.id)
        table.insert(questScrollChild.lines, idFS)

        -- Title cell
        local titleFS = questScrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        titleFS:SetPoint("TOPLEFT", COL_TITLE_X, yOff)
        titleFS:SetJustifyH("LEFT")
        -- Truncate title to fit within available width (rough width: COL_TRACKED_X - COL_TITLE_X - padding)
        local maxPixelWidth = (COL_TRACKED_X - COL_TITLE_X) - 8
        local displayTitle = row.title
        titleFS:SetText(displayTitle)
        if titleFS:GetStringWidth() > maxPixelWidth then
            -- iterative truncate; naive but safe for small number of rows
            local len = displayTitle:len()
            while len > 3 and titleFS:GetStringWidth() > maxPixelWidth do
                len = len - 1
                displayTitle = displayTitle:sub(1, len) .. "…"
                titleFS:SetText(displayTitle)
            end
        end
        titleFS.fullTitle = row.title
        table.insert(questScrollChild.lines, titleFS)

        -- Tracked cell
        local trackedFS = questScrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        trackedFS:SetPoint("TOPLEFT", COL_TRACKED_X, yOff)
        trackedFS:SetJustifyH("LEFT")
        trackedFS:SetText(row.tracked)
        table.insert(questScrollChild.lines, trackedFS)

        -- In Log cell (always Yes because we enumerate quest log)
        local inlogFS = questScrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        inlogFS:SetPoint("TOPLEFT", COL_INLOG_X, yOff)
        inlogFS:SetJustifyH("LEFT")
        inlogFS:SetText(row.inlog)
        table.insert(questScrollChild.lines, inlogFS)

        -- Ready cell (quest complete -> can turn in)
        local readyFS = questScrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        readyFS:SetPoint("TOPLEFT", COL_READY_X, yOff)
        readyFS:SetJustifyH("LEFT")
        readyFS:SetText(row.ready)
        table.insert(questScrollChild.lines, readyFS)

        -- Mouseover tooltip region (use an invisible button spanning the row for simplicity)
        local rowButton = CreateFrame("Button", nil, questScrollChild)
        rowButton:SetPoint("TOPLEFT", idFS, "TOPLEFT", -2, 2)
        rowButton:SetPoint("BOTTOMRIGHT", readyFS, "BOTTOMRIGHT", 2, -2)
        rowButton:SetScript("OnEnter", function()
            GameTooltip:SetOwner(rowButton, "ANCHOR_CURSOR")
            GameTooltip:AddLine(row.fullTitle or row.title, 1,1,1, true)
            GameTooltip:AddLine(string.format("Quest ID: %d", row.id), 0.9,0.9,0.9)
            -- Always show tag field for debugging
            local tagStr = (row.tag and row.tag.tagName and row.tag.tagName ~= "") and row.tag.tagName or "(no tag)"
            GameTooltip:AddLine("Tag: " .. tagStr, 0.8,0.8,0.8)
            -- Always show category for debugging
            local catStr = (row.category and row.category ~= "") and tostring(row.category) or "(no category)"
            GameTooltip:AddLine("Category: " .. catStr, 0.8,0.8,0.8)
            -- Always show zone for debugging
            local zoneStr = (row.zoneOrSort and row.zoneOrSort ~= "") and tostring(row.zoneOrSort) or "(no zone)"
            GameTooltip:AddLine("Zone: " .. zoneStr, 0.8,0.8,0.8)
            if row.remoteOnly then
                GameTooltip:AddLine("(Quest from party member)", 0.7,0.7,0.7)
            end
            -- Party member aggregation
            local hasMembers, trackedMembers, readyMembers = {}, {}, {}
            for player,quests in pairs(partyQuestStates) do
                local q = quests[row.id]
                if q and q.has then table.insert(hasMembers, ShortName(player)) end
                if q and q.tracked then table.insert(trackedMembers, ShortName(player)) end
                if q and q.ready then table.insert(readyMembers, ShortName(player)) end
            end
            local function fmt(list)
                if #list == 0 then return "None" end
                table.sort(list)
                return table.concat(list, ", ")
            end
            GameTooltip:AddLine("Has: " .. fmt(hasMembers), 0.7,0.9,0.7)
            GameTooltip:AddLine("Tracking: " .. fmt(trackedMembers), 0.7,0.7,0.9)
            GameTooltip:AddLine("Ready: " .. fmt(readyMembers), 0.9,0.7,0.7)
            GameTooltip:Show()
        end)
        rowButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
        table.insert(questScrollChild.lines, rowButton)

        -- Determine row color classification (simplified spec):
        -- Light green if ALL players in group have the quest; light red if ANY player missing.
        local totalPlayers = GetNumGroupMembers() -- includes self; 0 if solo
        if totalPlayers == 0 then totalPlayers = 1 end -- treat solo as 1
        local haveCount = 0
        -- Count party possession (excluding ourselves first)
        for player, quests in pairs(partyQuestStates) do
            local q = quests[row.id]
            if q and q.has then haveCount = haveCount + 1 end
        end
        if row.inlog == "Yes" then haveCount = haveCount + 1 end
        local r,g,b
        if haveCount == totalPlayers then
            r,g,b = 0.6,0.85,0.6 -- light green
        else
            r,g,b = 0.9,0.55,0.55 -- light red
        end
        rowButton.tex = rowButton:CreateTexture(nil, "BACKGROUND")
        rowButton.tex:SetAllPoints(rowButton)
        rowButton.tex:SetColorTexture(r,g,b,0.25)

        yOff = yOff - ROW_HEIGHT - 2
    end

    local totalHeight = (-yOff) + 4
    questScrollChild:SetHeight(totalHeight)
    Log("QuestWindow rows populated", #rows, "height", totalHeight)
    questWindow:Show()
    Log("QuestWindow populated", #rows)
    Log("PrintQuestIDs END")
end

-- Create frame to handle events
local frame = CreateFrame("Frame")
Log("Frame created")
frame:RegisterEvent("PLAYER_LOGIN")
Log("Registered PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event, ...)
    Log("OnEvent", event)
    print("QuestCoop: OnEvent called with event: " .. event)
    if event == "PLAYER_LOGIN" then
        print("QuestCoop: PLAYER_LOGIN event detected") -- Debug message
        Log("Handle PLAYER_LOGIN")
        EnsurePrefix()
        
        -- Set up click handler for the button defined in XML
    if not QuestCoopDB then QuestCoopDB = {} end
    local printButton = _G["PrintQuestIDsButton"]
    Log("Fetched buttons", printButton ~= nil)

        if printButton then
            Log("PrintQuestIDsButton setup")
            printButton:SetScript("OnClick", function(self, button)
                Log("PrintQuestIDsButton clicked")
                PrintQuestIDs()
            end)
            printButton:ClearAllPoints()
            if QuestCoopDB.printButtonPos then
                local pos = QuestCoopDB.printButtonPos
                printButton:SetPoint(pos.point or "CENTER", UIParent, pos.relativePoint or "CENTER", pos.x or 0, pos.y or -40)
                print("QuestCoop: Restored PrintQuestIDsButton position")
            else
                printButton:SetPoint("CENTER", UIParent, "CENTER", 0, -40)
                print("QuestCoop: Using default PrintQuestIDsButton position")
            end
            SafeCall("PrintQuestIDsButton SetUserPlaced", function() printButton:SetUserPlaced(true) end)
            local isUserPlaced2 = printButton.IsUserPlaced and printButton:IsUserPlaced() or "(method missing)"
            Log("PrintQuestIDsButton IsUserPlaced", isUserPlaced2)
            SafeCall("PrintQuestIDsButton Show", function() printButton:Show() end)
            Log("PrintQuestIDsButton IsShown", printButton:IsShown())
            MakeDraggable(printButton, "printButtonPos")
            Log("PrintQuestIDsButton MakeDraggable complete")
            Log("PrintQuestIDsButton draggable ready")
            print("QuestCoop: PrintQuestIDsButton positioned and shown")
        else
            print("QuestCoop: PrintQuestIDsButton not found")
            Log("PrintQuestIDsButton missing")
        end
    end
    -- Auto-refresh triggers
    if event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED" or event == "QUEST_WATCH_LIST_CHANGED" or event == "QUEST_LOG_UPDATE" then
        Log("AutoRefresh event", event)
        RefreshQuestWindowIfVisible()
        SendSnapshot()
    end
    if event == "GROUP_ROSTER_UPDATE" then
        Log("Group roster changed")
        SendSnapshot() -- share current state when group changes
    end
    if event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = ...
        if prefix == ADDON_PREFIX and sender ~= UnitName("player") then
            local msgType, version, payload = strsplit("|", message)
            if msgType == "SNAP" and payload then
                ApplySnapshot(sender, payload)
                RefreshQuestWindowIfVisible()
            elseif msgType == "SNAP_PART" and payload then
                ApplySnapshot(sender, payload) -- partial sequences accumulate
                RefreshQuestWindowIfVisible()
            end
        end
    end
end)

-- Register quest-related events for auto refresh
frame:RegisterEvent("QUEST_ACCEPTED")
frame:RegisterEvent("QUEST_REMOVED")
frame:RegisterEvent("QUEST_WATCH_LIST_CHANGED")
frame:RegisterEvent("QUEST_LOG_UPDATE")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("CHAT_MSG_ADDON")
Log("Registered quest update events")