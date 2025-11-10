local addonName, addon = ...

-- Debug flag
local DEBUG = true
local function Log(...)
    if not DEBUG then return end
    print("QuestCoopDBG:", ...)
end

local function SafeCall(label, func)
    local ok, err = pcall(func)
    if ok then
        Log("SafeCall success", label)
    else
        Log("SafeCall ERROR", label, err)
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
        Log("DragStart", key)
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if not QuestCoopDB then QuestCoopDB = {} end
        if key then
            local point, relativeTo, relativePoint, xOfs, yOfs = self:GetPoint()
            QuestCoopDB[key] = {point = point, relativePoint = relativePoint, x = xOfs, y = yOfs}
            print(string.format("QuestCoop: Saved position for %s: %s %d %d", key, relativePoint, xOfs, yOfs))
            Log("DragStop saved", key, point, relativePoint, xOfs, yOfs)
        end
    end)
end

-- Quest ID window (created lazily)
local questWindow, questScrollFrame, questScrollChild
local function CreateQuestWindow()
    if questWindow then return end
    questWindow = CreateFrame("Frame", "QuestCoopQuestWindow", UIParent, "BackdropTemplate")
    questWindow:SetSize(560, 300) -- widened to accommodate extra columns
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
    title:SetText("Quest IDs")

    local close = CreateFrame("Button", nil, questWindow, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    questScrollFrame = CreateFrame("ScrollFrame", "QuestCoopQuestScroll", questWindow, "UIPanelScrollFrameTemplate")
    questScrollFrame:SetPoint("TOPLEFT", 16, -40)
    questScrollFrame:SetPoint("BOTTOMRIGHT", -30, 16)

    questScrollChild = CreateFrame("Frame", nil, questScrollFrame)
    questScrollChild:SetSize(520, 1) -- widened for additional columns
    questScrollFrame:SetScrollChild(questScrollChild)
    questScrollChild.lines = {}

    Log("QuestWindow created")
end

-- Internal helper to refresh quest window if shown (silent)
local function RefreshQuestWindowIfVisible()
    if not questWindow or not questWindow:IsShown() then return end
    -- Call PrintQuestIDs but without shift printing and without forcing visibility changes beyond refresh.
    PrintQuestIDs(true) -- pass silent flag
end

-- Function to hide all quests
function HideAllQuests()
    Log("HideAllQuests START")
    print("QuestCoop: Attempting to hide quests...")
    
    -- Try to get all quests
    local numEntries = C_QuestLog.GetNumQuestLogEntries()
    Log("HideAllQuests numEntries", numEntries)
    print("QuestCoop: Number of quests found: " .. numEntries)
    
    for i = 1, numEntries do
    local questInfo = C_QuestLog.GetInfo(i)
    Log("HideAllQuests loop", i, questInfo and questInfo.title, questInfo and questInfo.isHeader)
        if questInfo then
            print("QuestCoop: Processing index " .. i .. ": " .. (questInfo.title or "No title"))
            
            if not questInfo.isHeader then
                print("QuestCoop: Quest is not a header")
                local questID = questInfo.questID
                print("QuestCoop: Quest ID " .. questID)
                
                if questID then
                    print("QuestCoop: Attempting to untrack quest: " .. questInfo.title)
                    C_QuestLog.RemoveQuestWatch(questID)
                    print("QuestCoop: Untracked quest: " .. questInfo.title)
                    Log("HideAllQuests untracked", questID)
                end
            else
                print("QuestCoop: Skipping header: " .. questInfo.title)
            end
        end
    end
    
    -- Force update the objective tracker
    ObjectiveTracker_Update()
    Log("HideAllQuests ObjectiveTracker_Update")
    print("QuestCoop: Finished hiding quests")
    Log("HideAllQuests END")
end

-- Function to print current quest IDs
-- PrintQuestIDs(silentRefresh)
-- When silentRefresh is true, we don't echo to chat even if shift is down.
function PrintQuestIDs(silentRefresh)
    Log("PrintQuestIDs START")
    CreateQuestWindow()
    -- Build structured rows instead of a single concatenated string per quest.
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
                table.insert(rows, {id = questID, title = title, tracked = trackText, inlog = "Yes", ready = readyText})
                local chatLine = string.format("%d - %s (Tracked:%s Ready:%s)", questID, title, trackText, readyText)
                Log("PrintQuestIDs row", chatLine)
                if shiftDown and not silentRefresh then print("QuestCoop:", chatLine) end
            end
        end
    end
    -- Clear previous row frames / fontstrings
    for _, fs in ipairs(questScrollChild.lines) do fs:Hide() end
    wipe(questScrollChild.lines)

    -- Column layout constants
    local COL_ID_X = 0
    local COL_TITLE_X = 60
    local COL_TRACKED_X = 270
    local COL_INLOG_X = 330
    local COL_READY_X = 390
    local ROW_HEIGHT = 14
    local yOff = -2

    -- Header row
    local header = questScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header:SetPoint("TOPLEFT", COL_ID_X, yOff)
    header:SetJustifyH("LEFT")
    header:SetText("ID   Title                               Trk  Log  Ready")
    table.insert(questScrollChild.lines, header)
    yOff = yOff - ROW_HEIGHT - 4

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
        titleFS:SetText(row.title)
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
        
        -- Set up click handler for the button defined in XML
    if not QuestCoopDB then QuestCoopDB = {} end
    local button = _G["HideQuestsButton"]
    local printButton = _G["PrintQuestIDsButton"]
    Log("Fetched buttons", button ~= nil, printButton ~= nil)
        if button then
            print("QuestCoop: Button found")
            Log("HideQuestsButton setup")
            button:SetScript("OnClick", function(self, button)
                Log("HideQuestsButton clicked")
                print("QuestCoop: Button clicked!")
                HideAllQuests()
            end)
            print("QuestCoop: Button handler set up")
            
            -- Explicitly set the button's position and show it
            button:ClearAllPoints()
            if QuestCoopDB.hideButtonPos then
                local pos = QuestCoopDB.hideButtonPos
                button:SetPoint(pos.point or "CENTER", UIParent, pos.relativePoint or "CENTER", pos.x or 0, pos.y or 0)
                print("QuestCoop: Restored HideQuestsButton position")
            else
                button:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                print("QuestCoop: Using default HideQuestsButton position")
            end
            SafeCall("HideQuestsButton SetUserPlaced", function() button:SetUserPlaced(true) end)
            local isUserPlaced = button.IsUserPlaced and button:IsUserPlaced() or "(method missing)"
            Log("HideQuestsButton IsUserPlaced", isUserPlaced)
            -- Show and draggable wiring
            SafeCall("HideQuestsButton Show", function() button:Show() end)
            Log("HideQuestsButton IsShown", button:IsShown())
            MakeDraggable(button, "hideButtonPos")
            Log("HideQuestsButton MakeDraggable complete")
            Log("HideQuestsButton draggable ready")
            print("QuestCoop: Button position set and shown")
        else
            print("QuestCoop: Button not found")
            Log("HideQuestsButton missing")
        end

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
    end
end)

-- Register quest-related events for auto refresh
frame:RegisterEvent("QUEST_ACCEPTED")
frame:RegisterEvent("QUEST_REMOVED")
frame:RegisterEvent("QUEST_WATCH_LIST_CHANGED")
frame:RegisterEvent("QUEST_LOG_UPDATE")
Log("Registered quest update events")