# Plan: Network-Based Party Quest Sync

Add addon communication to track party members' quest states (IDs, completions, turn-ins) with a persistent quest name cache. Display "Wrapping Up" (recently turned in) and "Kicking Off" (recently accepted) sections in the quest window, with configurable display options and 10-minute default lookback in the options panel.

## Steps

1. **Implement addon message protocol in `QuestCoop.lua`**: Register `CHAT_MSG_ADDON` and `QUEST_TURNED_IN` events, define message types (`QUEST_LOG`, `QUEST_COMPLETE`, `QUEST_TURNIN`, `QUEST_ACCEPT`, `REQUEST_SYNC`), add throttled broadcast using `SendAddonMessage("QuestCoop", payload, "PARTY")` chunking quest lists to 10 IDs per message with 1-second frame-based queue delays between chunks.

2. **Build persistent quest name cache**: Add `QuestCoopDB.questCache = { [questID] = {name="...", timestamp=time()} }` with 30-day expiration on load, populate via `C_QuestLog.GetTitleForQuestID()` with `C_QuestLog.RequestLoadQuestByID()` fallback, register `QUEST_DATA_LOAD_RESULT` event to handle async name fetches, implement cache cleanup function removing entries where `time() - timestamp > 2592000` (30 days).

3. **Track party member quest states and broadcast**: Store runtime `questsByPlayer[playerName] = { activeQuestIDs={...}, wrappingUp={{questID, timestamp},...}, kickingOff={{questID, timestamp},...} }`, handle incoming addon messages to reconstruct multi-chunk `QUEST_LOG` broadcasts and update remote player data, send full quest log on `GROUP_ROSTER_UPDATE` (chunked, 1s delays), send instant `QUEST_ACCEPT` message on `QUEST_ACCEPTED` event, send instant `QUEST_TURNIN` message on `QUEST_TURNED_IN` event. **Trigger UI refresh after processing incoming messages**: call debounced `QueueDisplayRefresh()` after updating `partyQuestStates` to prevent UI flicker during multi-chunk syncs.

4. **Add "Wrapping Up" and "Kicking Off" sections to quest window**: Insert new sections in `CreateQuestWindow()` after shared quests section: "Wrapping Up (X quests)" showing party member turn-ins where local player still has the quest, "Kicking Off (Y quests)" showing party member recent accepts where local player doesn't have the quest, filter both by `timestamp >= (time() - lookbackMinutes*60)`, use orange color for "Wrapping Up" and cyan color for "Kicking Off" headers, display player names per quest row.

5. **Extend options panel with visibility toggles and lookback setting**: Add "Display Sections" checkboxes in `settingsPanel` for "Wrapping Up", "Kicking Off", "Shared Quests", "My Unique Quests", "Party Unique Quests" (all default enabled), add slider/editbox for "Recent Activity Lookback (minutes)" with range 5-120 and default 10 minutes, save to `QuestCoopDB.settings.visibleSections` table and `QuestCoopDB.settings.recentLookbackMinutes`, update `RefreshQuestWindowIfVisible()` to respect visibility toggles.

## Further Considerations

1. **Message payload format**: - Use compact colon-and-comma format: `QUEST_LOG:1:5:12345,67890,...`. This stays well under 255 bytes (~73 bytes for 10 IDs) and is trivial to parse with `strsplit(":", payload)` and `strsplit(",", idString)`. Avoid JSON/table serialization overhead.

2. **Handling players leaving party**:  - Retain `partyQuestStates` entry for **5 minutes** after player leaves party (mark `inParty=false`, track `lastUpdate` timestamp). This handles DC/reconnect gracefully without forcing full re-sync. Purge entries older than 5-minute grace period on `GROUP_ROSTER_UPDATE`. Optional: make grace period configurable (0-15 min range, 0 = immediate clear for users who want strict cleanup).

3. **Quest name cache size management**:  - Rely **solely on 30-day expiration** (cleanup on `PLAYER_LOGIN`). No hard cap needed—most players won't accumulate enough unique quest IDs in 30 days to cause SavedVariables bloat. Even completionists doing 5000+ quests will naturally purge old entries. Simpler code, better performance. Optional: Add debug stat in settings panel showing cache size for troubleshooting.

4. **Multi-chunk message reconstruction**: When receiving chunked `QUEST_LOG` messages, store partial data in `incomingChunks[playerName][chunkIndex] = payload`. Once all chunks received (check `chunkIndex == totalChunks`), concatenate and parse full quest list. Handle missing chunks (timeout after 30 seconds, request re-sync).

5. **Version compatibility**: If protocol changes in future (e.g., adding quest progress %), prefix messages with version: `v1:QUEST_LOG:...`. Addon ignores messages with unknown version prefix, preventing parse errors across addon updates.

6. **UnitFullName API**: Use `local name, realm = UnitFullName(unit)` which returns name and realm separately. If `realm == nil` (same realm as player), construct key as `name .. "-" .. GetRealmName()`. If `realm ~= nil`, construct as `name .. "-" .. realm`. This ensures consistent `"Name-Realm"` format across all scenarios (same-realm, cross-realm, sender from addon message).

## User Requirements Summary

- **Network messaging**: Use addon message protocol to sync quest data between party members
- **Quest tracking**: Track active quests, recent turn-ins, recent accepts for all party members
- **Quest name cache**: Persistent cache with 30-day expiration in SavedVariables
- **Message throttling**: 10 quest IDs per message, 1-second delay between messages
- **Display sections**:
  - "Wrapping Up": Recently turned in by party (where local player still has quest)
  - "Kicking Off": Recently accepted by party (where local player doesn't have quest)
  - Existing: Shared quests, My unique quests, Party unique quests
- **Configuration**:
  - Lookback time: 5-120 minutes (default 10)
  - Section visibility toggles for all 5 sections
- **Event usage**: `QUEST_TURNED_IN` for turn-in detection

## Technical Specifications

### Message Protocol

**Prefix**: `"QuestCoop"`
**Channel**: `"PARTY"`
**Critical Constraint**: WoW addon messages limited to **255 bytes per message**

**Message Types**:
- `QUEST_LOG`: Full quest list (chunked)
  - Format: `QUEST_LOG:<chunkIndex>:<totalChunks>:<questID1>,<questID2>,...`
  - Max 10 IDs per chunk (safely under 255 bytes: ~20 char prefix + 50 chars for IDs + 9 commas = ~80 bytes)
  - Example: `QUEST_LOG:1:5:12345,67890,11111,22222,33333,44444,55555,66666,77777,88888`
- `QUEST_ACCEPT`: Single quest accepted
  - Format: `QUEST_ACCEPT:<questID>:<timestamp>`
  - Example: `QUEST_ACCEPT:12345:1732492800`
- `QUEST_TURNIN`: Single quest turned in
  - Format: `QUEST_TURNIN:<questID>:<timestamp>`
  - Example: `QUEST_TURNIN:12345:1732492800`
- `REQUEST_SYNC`: Request full quest log from party
  - Format: `REQUEST_SYNC`

### Data Structures

**Saved Variables (persistent)**:
```lua
QuestCoopDB = {
  settings = {
    textSize = "small" | "medium" | "large",
    recentLookbackMinutes = 10,  -- NEW
    visibleSections = {          -- NEW
      wrappingUp = true,
      kickingOff = true,
      sharedQuests = true,
      myQuests = true,
      partyQuests = true
    }
  },
  printButtonPos = { ... },
  questCache = {                 -- NEW
    [questID] = {
      name = "Quest Title",
      timestamp = 1234567890
    }
  }
}
```

**Runtime Variables (in-memory)**:
```lua
-- Party member quest states (keyed by full "PlayerName-Realm" string)
partyQuestStates = {
  ["PlayerName-Realm"] = {
    activeQuestIDs = { [12345] = true, [67890] = true },
    wrappingUp = {
      { questID = 11111, timestamp = 1234567890 },
      { questID = 22222, timestamp = 1234567891 }
    },
    kickingOff = {
      { questID = 33333, timestamp = 1234567892 }
    },
    lastUpdate = 1234567890,  -- time() of last message/roster check
    inParty = true            -- false = player left, retained for DC grace period
  }
}

-- Incoming multi-chunk message reconstruction buffer
incomingChunks = {
  ["PlayerName-Realm"] = {
    [1] = "12345,67890,...",  -- chunk index -> payload
    [2] = "44444,55555,...",
    totalChunks = 5,
    receivedAt = 1234567890   -- timeout detection
  }
}

-- Message queue for throttling (global across all message types)
messageQueue = {
  { type = "QUEST_LOG", chunk = 1, total = 5, payload = "12345,67890,..." },
  { type = "QUEST_ACCEPT", payload = "QUEST_ACCEPT:12345:1732492800" },
  { type = "QUEST_LOG", chunk = 2, total = 5, payload = "44444,55555,..." }
}

-- Global message cooldown tracker
lastMessageSentTime = 0  -- time() of last SendAddonMessage call
MESSAGE_COOLDOWN = 1.0   -- 1 second minimum between ANY addon messages

-- Stale data retention settings
STALE_DATA_RETENTION = 300  -- 5 minutes (300 seconds) grace period for DC/reconnects

-- UI refresh debouncing
pendingDisplayRefresh = false  -- flag indicating refresh is queued
lastDisplayRefreshTime = 0     -- time() of last actual refresh
DISPLAY_REFRESH_DEBOUNCE = 0.1 -- 100ms debounce window
```

### Event Handlers

**New events to register**:
- `CHAT_MSG_ADDON`: Receive addon messages
- `QUEST_TURNED_IN`: Detect quest turn-ins
- `QUEST_DATA_LOAD_RESULT`: Handle async quest name lookups

**Modified event handlers**:
- `QUEST_ACCEPTED`: Queue instant `QUEST_ACCEPT` message (respects global cooldown)
- `QUEST_TURNED_IN`: Queue instant `QUEST_TURNIN` message (respects global cooldown)
- `GROUP_ROSTER_UPDATE`: 
  1. Iterate party units, capture full names via `UnitFullName(unit)`
  2. Update `partyQuestStates` entries: mark active players `inParty=true`, inactive as `inParty=false`
  3. Purge stale entries (inactive > 5 min grace period)
  4. Queue full quest log sync with **random 0-5 second jitter** (skip if player already has cached data within grace period)
- `PLAYER_LOGIN`: Add cache cleanup (30-day expiration) and initialize message queue/cooldown tracker
- `CHAT_MSG_ADDON`: 
  1. Extract sender (already `"Name-Realm"`), parse message type
  2. Handle `QUEST_ACCEPT`/`QUEST_TURNIN`: Add to `partyQuestStates[sender].kickingOff`/`wrappingUp`
  3. Handle `QUEST_LOG` chunk: Store in `incomingChunks[sender][chunkIndex]`, check if complete
  4. If QUEST_LOG complete: Reconstruct full list, update `partyQuestStates[sender].activeQuestIDs`
  5. After ANY state update: Call `QueueDisplayRefresh()` to trigger debounced UI update

### UI Layout Changes

**New sections in quest window** (in order):
1. Shared Quests (existing)
2. **Wrapping Up** (new) - orange header
3. **Kicking Off** (new) - cyan header
4. My Unique Quests (existing)
5. Party Unique Quests (existing)

Each section respects visibility toggle from settings.

### Cache Management

**Quest name resolution**:
1. Check `QuestCoopDB.questCache[questID]`
2. If miss, try `C_QuestLog.GetTitleForQuestID(questID)`
3. If nil, call `C_QuestLog.RequestLoadQuestByID(questID)` and wait for `QUEST_DATA_LOAD_RESULT`
4. Cache result with current timestamp

**Cleanup logic** (on `PLAYER_LOGIN`):
- Iterate `QuestCoopDB.questCache`
- Remove entries where `time() - entry.timestamp > 2592000` (30 days)
- **No hard cap**: 30-day expiration is sufficient for normal usage (most players won't accumulate problematic cache sizes)

### Message Throttling

**Global Cooldown Queue-based Approach**:

**Rationale**: WoW enforces a 255-byte message limit and server-side rate limiting. Multiple party members syncing simultaneously (e.g., on party formation) can overwhelm the server and cause message loss or throttling penalties.

**Strategy**:
1. **Single Global Queue**: All addon messages (QUEST_LOG chunks, QUEST_ACCEPT, QUEST_TURNIN) go into one `messageQueue`
2. **Global 1-Second Cooldown**: Track `lastMessageSentTime`. Only send next message if `time() - lastMessageSentTime >= MESSAGE_COOLDOWN` (1.0 seconds)
3. **OnUpdate Processor**: Frame `OnUpdate` checks queue head, compares cooldown, sends if ready, updates `lastMessageSentTime`, removes from queue
4. **Sync Jitter**: On `GROUP_ROSTER_UPDATE`, add random delay (0-5 seconds) before queuing quest log to desynchronize party-wide broadcasts and prevent sync storms
5. **Chunk Generation**: Split quest log into chunks of 10 quest IDs (~80 bytes each, safely under 255-byte limit)

**Benefits**:
- Prevents flooding during party formation (5 players × 5 chunks = 25 messages spread over 25+ seconds)
- Gracefully handles reconnects without overwhelming server
- Ensures instant messages (QUEST_ACCEPT/TURNIN) don't get dropped due to concurrent chunk sends
- Random jitter prevents thundering herd when multiple players join simultaneously

**Example Timeline**:
- T+0s: Player joins party, rolls random delay (e.g., 2.7s)
- T+2.7s: Queue 5 QUEST_LOG chunks
- T+2.7s: Send chunk 1 (cooldown starts)
- T+3.7s: Send chunk 2
- T+4.7s: Send chunk 3
- T+5.2s: Player accepts new quest, QUEST_ACCEPT queued
- T+5.7s: Send chunk 4
- T+6.7s: Send QUEST_ACCEPT
- T+7.7s: Send chunk 5

### Display Logic

**Wrapping Up section**:
- Iterate all party members' `wrappingUp` lists
- Filter: `timestamp >= (time() - lookbackMinutes * 60)`
- Filter: local player still has quest in log (`C_QuestLog.IsOnQuest(questID)`)
- Display: Quest ID, quest name (from cache), player name who turned it in
- Tooltip: "PlayerName turned this in X minutes ago"

**Kicking Off section**:
- Iterate all party members' `kickingOff` lists
- Filter: `timestamp >= (time() - lookbackMinutes * 60)`
- Filter: local player does NOT have quest (`not C_QuestLog.IsOnQuest(questID)`)
- Display: Quest ID, quest name (from cache), player name who accepted
- Tooltip: "PlayerName picked this up X minutes ago"

**Filter Logic Validation**:
- ✅ **Wrapping Up filter is correct**: Only show quests local player still has (should turn in next)
- ✅ **Kicking Off filter is correct**: Only show quests local player doesn't have (may want to pick up)
- **Rationale**: These filters provide high-value, actionable information—highlighting coordination opportunities without UI clutter

## Implementation Notes

### Message Size Verification
- **255-Byte Limit**: Each `SendAddonMessage()` call must stay under 255 bytes
- **Payload Calculation**: For `QUEST_LOG:1:5:12345,67890,...` with 10 five-digit IDs:
  - Prefix: "QUEST_LOG:" = 10 bytes
  - Chunk metadata: "1:5:" = 4 bytes (worst case: "99:99:" = 6 bytes)
  - Quest IDs: 10 × 5 digits = 50 bytes
  - Commas: 9 bytes
  - **Total**: ~73 bytes (safely under 255 bytes)
- **Safety Check**: Before sending, verify `#payload <= 250` to leave margin for encoding overhead

### UI Refresh & Debouncing

**Problem**: Incoming messages update `partyQuestStates` frequently (multi-chunk `QUEST_LOG` syncs, rapid `QUEST_ACCEPT`/`QUEST_TURNIN` events). Refreshing UI immediately after each message causes flicker and performance issues.

**Solution**: Debounced refresh mechanism

**Implementation**:
```lua
function QueueDisplayRefresh()
  if not pendingDisplayRefresh then
    pendingDisplayRefresh = true
    -- Frame OnUpdate will handle actual refresh after debounce window
  end
end

-- In Frame OnUpdate handler:
if pendingDisplayRefresh and (time() - lastDisplayRefreshTime >= DISPLAY_REFRESH_DEBOUNCE) then
  pendingDisplayRefresh = false
  lastDisplayRefreshTime = time()
  RefreshQuestWindowIfVisible()  -- Existing function, only refreshes if window open
end
```

**Benefits**:
- **Multi-chunk sync**: 5 QUEST_LOG chunks arrive over 1-5 seconds, UI refreshes once 100ms after last chunk
- **Rapid events**: Multiple QUEST_ACCEPT messages in quick succession refresh once, not N times
- **Performance**: Prevents unnecessary layout recalculations during message bursts
- **User experience**: No UI flicker, smooth updates

**Trigger Points** (call `QueueDisplayRefresh()` after):
- Processing any `CHAT_MSG_ADDON` that updates `partyQuestStates`
- Completing multi-chunk `QUEST_LOG` reconstruction
- Receiving instant `QUEST_ACCEPT`/`QUEST_TURNIN` messages
- `GROUP_ROSTER_UPDATE` (after roster/stale data updates)
- Local player events: `QUEST_ACCEPTED`, `QUEST_TURNED_IN`, `QUEST_REMOVED`

**Edge Case**: If window is closed, `RefreshQuestWindowIfVisible()` no-ops (existing behavior preserved)

### Player Identification & Stale Data Management

**Player Name Resolution**:
- **Full Name Key**: Always use `"PlayerName-Realm"` format as the key for `partyQuestStates`
- **Capture on Events**:
  - On `GROUP_ROSTER_UPDATE`: Iterate party units (`"party1"` through `"party4"`), call `UnitFullName(unit)` to get `"Name-Realm"` string
  - On `CHAT_MSG_ADDON`: Extract sender parameter (already in `"Name-Realm"` format)
- **Rationale**: Full name-realm ensures uniqueness and allows retention after player leaves party (for DC grace period)

**Stale Data Retention (DC/Reconnect Handling)**:
- On `GROUP_ROSTER_UPDATE`:
  1. Build list of current party members (full names)
  2. For each entry in `partyQuestStates`:
     - If player in current roster: set `inParty = true`, update `lastUpdate = time()`
     - If player NOT in roster but `inParty == true`: set `inParty = false`, keep `lastUpdate` timestamp
  3. **Grace Period Cleanup**: Remove entries where `inParty == false` AND `time() - lastUpdate > STALE_DATA_RETENTION` (5 minutes)
- **Benefit**: Player who DCs and reconnects within 5 minutes retains their "Wrapping Up"/"Kicking Off" history without re-sync delay
- **Alternative**: Make retention time configurable in settings (default 5 min, range 0-15 min, 0 = immediate clear)

**Sync Storm Prevention**:
- On `GROUP_ROSTER_UPDATE`, add `math.random(0, 5000) / 1000` second delay before queuing quest log sync
- On DC/reconnect, same random jitter applies (prevents repeated storms)
- Do NOT queue sync if player's data still exists in `partyQuestStates` (they're within grace period)

### Protocol Versioning
- Implement message version prefix for future protocol changes: `v1:QUEST_LOG:...`
- Ignore messages from incompatible versions (parse version, compare to current)

### Debugging
- Add debug logging toggle in settings (default: off)
- Log: message queue size, cooldown remaining, chunk send/receive events
- Display queue size in settings panel for visibility into sync backlog

### Testing Scenarios
- **5-player party formation**: Verify ~25+ second sync time (5 players × 5 chunks × 1s + jitter)
- **Mid-dungeon DC**: Verify rejoining player doesn't cause UI freezes or message loss
- **Rapid quest accepts**: Verify instant messages don't get dropped behind slow chunk sync
- **50+ quest log**: Verify chunking handles edge cases (exact 10 IDs, 1 remaining ID, etc.)
- **UI refresh performance**: Verify no flicker during multi-chunk sync (should refresh once after final chunk, not 5 times)
- **Debounce validation**: Accept 3 quests rapidly (<1 second apart), verify UI refreshes once ~100ms after last accept
