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
function PrintQuestIDs()
    Log("PrintQuestIDs START")
    print("QuestCoop: Listing current quest IDs...")
    local numEntries = C_QuestLog.GetNumQuestLogEntries()
    Log("PrintQuestIDs numEntries", numEntries)
    for i = 1, numEntries do
        local questInfo = C_QuestLog.GetInfo(i)
        Log("PrintQuestIDs loop", i, questInfo and questInfo.title, questInfo and questInfo.isHeader)
        if questInfo and not questInfo.isHeader then
            local questID = questInfo.questID
            if questID then
                print(string.format("QuestCoop: %s => %d", questInfo.title or "(no title)", questID))
                Log("PrintQuestIDs printed", questID)
            end
        end
    end
    print("QuestCoop: Finished listing quest IDs")
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
end)