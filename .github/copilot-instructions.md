Context: World of Warcraft Retail (11.x+) Lua API - Questing

1. Party Member Status

Function: C_QuestLog.IsUnitOnQuest(unit, questID)

Usage: local hasQuest = C_QuestLog.IsUnitOnQuest("party1", 12345)

Constraints:

Returns boolean.

Unreliable if the unit is not visible/in inspection range (returns false even if they have it).

Does not return progress steps, only binary active status.

2. Quest Sharing

Function: QuestLogPushQuest() (Legacy Wrapper)

Workflow:

C_QuestLog.SetSelectedQuest(questID)

if C_QuestLog.IsPushableQuest(questID) then QuestLogPushQuest() end

Critical Security Constraint: Requires a Hardware Event (mouse click/keypress). You cannot share quests automatically on event triggers (e.g., ZONE_CHANGED).

3. Retrieving Quest Names

Function: C_QuestLog.GetTitleForQuestID(questID)

Usage: local title = C_QuestLog.GetTitleForQuestID(questID)

Gotcha: Returns nil if data is not cached.

Fix: Call C_QuestLog.RequestLoadQuestByID(questID) and wait for QUEST_DATA_LOAD_RESULT.

4. Retrieving Quest Zones

No Direct API: There is no function to get a zone ID from a quest ID directly.

Workaround: Iterate the Quest Log looking for headers.

-- Logic pattern
local currentHeader = "Unknown"
for i = 1, C_QuestLog.GetNumQuestLogEntries() do
    local info = C_QuestLog.GetInfo(i)
    if info.isHeader then
        currentHeader = info.title
    elseif info.questID == targetID then
        return currentHeader
    end
end


5. Quest Completion (History)

Function: C_QuestLog.IsQuestFlaggedCompleted(questID)

Usage: Checks if the quest has ever been completed by the character (useful for one-time treasures or attunements).

Distinction: distinct from C_QuestLog.IsOnQuest(questID) which only checks the active log.

6. Objectives

Function: C_QuestLog.GetQuestObjectives(questID)

Returns: Array of objective tables (text, type, finished status).

7. Abandoning Quests

Function: C_QuestLog.AbandonQuest()

Workflow:

C_QuestLog.SetSelectedQuest(questID)

C_QuestLog.SetAbandonQuest()

C_QuestLog.AbandonQuest()

Constraints:

Protected: Requires a Hardware Event (click/keypress) to execute without a confirmation prompt.

Validation: Always check C_QuestLog.CanAbandonQuest(questID) first, as some campaign quests are locked.