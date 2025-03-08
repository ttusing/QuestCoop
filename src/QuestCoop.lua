local addonName, addon = ...

-- Function to hide all quests
local function HideAllQuests()
    print("QuestCoop: Attempting to hide quests...")
    
    -- Try to get all quests
    local numEntries = C_QuestLog.GetNumQuestLogEntries()
    print("QuestCoop: Number of quests found: " .. numEntries)
    
    for i = 1, numEntries do
        local questInfo = C_QuestLog.GetInfo(i)
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
                end
            else
                print("QuestCoop: Skipping header: " .. questInfo.title)
            end
        end
    end
    
    -- Force update the objective tracker
    ObjectiveTracker_Update()
    print("QuestCoop: Finished hiding quests")
end

-- Create frame to handle events
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event, ...)
    print("QuestCoop: OnEvent called with event: " .. event)
    if event == "PLAYER_LOGIN" then
        print("QuestCoop: PLAYER_LOGIN event detected") -- Debug message
        
        -- Set up click handler for the button defined in XML
        local button = _G["HideQuestsButton"]
        if button then
            print("QuestCoop: Button found")
            button:SetScript("OnClick", function(self, button)
                print("QuestCoop: Button clicked!")
                HideAllQuests()
            end)
            print("QuestCoop: Button handler set up")
            
            -- Explicitly set the button's position and show it
            button:ClearAllPoints()
            button:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
            button:SetBackdrop({bgFile = "Interface/Tooltips/UI-Tooltip-Background"})
            button:SetBackdropColor(0, 0, 0, 1)
            button:Show()
            print("QuestCoop: Button position set and shown")
        else
            print("QuestCoop: Button not found")
        end
    end
end)