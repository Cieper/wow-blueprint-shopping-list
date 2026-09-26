--[[ BlueprintShoppingList
     Reopen the housing blueprint "contents / what am I missing" window anywhere in
     the world, and stop it from vanishing when you leave the housing zone.

     Why the stock window disappears (12.1.0 source):

       HousingBlueprintBaseFrameMixin:ShowSelf() parents the frame to
       GetAppropriateTopLevelParent(), which is HouseEditorFrame while the House
       Editor is open. Leaving the plot runs HouseEditorFrameMixin:OnHide, so the
       parent goes away -> the child stops being visible -> the list frame's own
       OnHide fires, which does two fatal things:

         ClearData()                          -- throws away blueprintContentInfo
         BaseOnHide() -> unregisters the      -- so the "top level parent changed"
           UI.AlternateTopLevelParentChanged     callback that would have
           callback                              reparented it to UIParent

       So by the time ClearAlternateTopLevelParent() fires, nothing is listening
       and the payload is already gone. Nothing about the data is location-locked;
       only the frame's plumbing is.

       One trap when fixing this: an ancestor being hidden does NOT clear the
       frame's own shown flag. IsShown() keeps returning true, and the frame is a
       registered UI panel (area = "left", Blizzard_HousingBlueprintRegistration.lua),
       so ShowUIPanel would early-out on that stale flag and quietly do nothing.
       We clear it first. That same flag is what tells an ancestor-driven hide
       apart from a real close, so we never fight the panel manager.

     What this addon does:

       * keeps its own copy of the HousingBlueprintContentInfo payload, so the
         window can always be rebuilt
       * asks for contents against an explicit house GUID
         (C_HousingBlueprint.RequestBlueprintContentsForContext), which is what
         makes the server fill in numMissing when you are nowhere near your plot
       * adds a "Keep open" checkbox that re-shows the frame after an editor
         close, a plot exit, or a parent swap. Closing it yourself still closes it
       * remembers the last good snapshot per share code, so you still have
         missing counts if the server declines to give you a house context
       * only trusts the house you are standing in if you actually own it, so
         visiting a neighbour doesn't skew the counts

     Slash commands: /bsl  (also /blueprintlist)
     Macro-friendly global: LoadBlueprint("<CODE>")
]]--

local ADDON_NAME = ...

local BSL = {}
_G.BlueprintShoppingList = BSL

local BLIZZ_ADDON = "Blizzard_HousingBlueprint"
local PREFIX = "|cff66bbffBlueprint List|r: "
local MAX_SNAPSHOTS = 10

local db                    -- BlueprintShoppingListDB, set at ADDON_LOADED
local sessionHouseGUID      -- learned from PLAYER_HOUSE_LIST_UPDATED / TRACKED_HOUSE_CHANGED
local uiInstalled = false

-- state for the keep-open watchdog
local wantShown = false     -- true while the user wants the window up
local internalHide = false  -- true only while we hide the frame for bookkeeping
local reshowScheduled = false

local DEFAULTS = {
	keepOpen = true,
	missingOnlyByDefault = true,
	strata = "HIGH",        -- see ApplyStrata
	snapshots = {},         -- [shareCode] = { info = <payload>, guid = <string>, when = <time> }
	houseGUID = nil,
	lastCode = nil,
}

--=========================================================================
-- small helpers
--=========================================================================

local function Print(fmt, ...)
	local msg = select("#", ...) > 0 and fmt:format(...) or fmt
	print(PREFIX .. msg)
end

-- GUIDs are normally plain strings, but 12.x can hand back values that are not
-- safe to persist. Only ever write a string into SavedVariables.
local function PersistableGUID(guid)
	return type(guid) == "string" and guid ~= "" and guid or nil
end

local function ResultText(result)
	local tbl = _G.HousingResultToErrorText
	return (tbl and tbl[result]) or ("result " .. tostring(result))
end

--=========================================================================
-- Blizzard UI loading
--=========================================================================

-- Returns the content list frame, or nil plus a reason.
local function EnsureBlizzardUI()
	if not _G.HousingBlueprintContentListFrame then
		local loaded, reason = C_AddOns.LoadAddOn(BLIZZ_ADDON)
		if not loaded then
			return nil, tostring(reason)
		end
	end
	if not _G.HousingBlueprintContentListFrame then
		return nil, "frame missing after load"
	end
	return _G.HousingBlueprintContentListFrame
end

--=========================================================================
-- house GUID resolution
--
-- The missing counts only appear when the payload comes back with a
-- targetHouseGUID, and that only happens if the server was told which house to
-- compare against. Inside your plot the client fills that in for you. Outside
-- it, we have to supply it, so we cache it from every source we can.
--=========================================================================

local function RememberHouseGUID(guid, source)
	if not guid then return end
	sessionHouseGUID = guid
	local persistable = PersistableGUID(guid)
	if persistable and db then
		db.houseGUID = persistable
	end
	if source and BSL.debug then
		Print("learned house GUID from %s", source)
	end
end

-- GetCurrentHouseInfo answers for whatever house you are standing in, including a
-- neighbour's. Blizzard's own house dropdown cross-checks ownership before
-- trusting it, so gate on the ownership call or one visit next door poisons the
-- cached GUID for good.
local function CurrentOwnedHouseGUID()
	if not (C_Housing and C_Housing.GetCurrentHouseInfo) then return nil end

	local isOwned = C_Housing.IsInsideOwnedHouseOrPlot
	if isOwned then
		if not isOwned() then return nil end
	elseif C_Housing.IsInsideOwnedHouse then
		if not C_Housing.IsInsideOwnedHouse() then return nil end
	else
		return nil   -- no way to prove it's ours; don't guess
	end

	local info = C_Housing.GetCurrentHouseInfo()
	return info and info.houseGUID or nil
end

function BSL:ResolveHouseGUID()
	-- standing in / on your own house: authoritative
	local ownGUID = CurrentOwnedHouseGUID()
	if ownGUID then
		RememberHouseGUID(ownGUID, "current house")
		return ownGUID, "current house"
	end

	if C_Housing and C_Housing.GetTrackedHouseGuid then
		local tracked = C_Housing.GetTrackedHouseGuid()
		if tracked then
			RememberHouseGUID(tracked, "tracked house")
			return tracked, "tracked house"
		end
	end

	if sessionHouseGUID then
		return sessionHouseGUID, "owned house list"
	end

	if db and db.houseGUID then
		return db.houseGUID, "saved"
	end

	return nil, "unknown"
end

-- Nudge the server for the owned-house list. Answer arrives as
-- PLAYER_HOUSE_LIST_UPDATED, which we cache.
local function RequestOwnedHouses()
	if C_Housing and C_Housing.GetPlayerOwnedHouses then
		pcall(C_Housing.GetPlayerOwnedHouses)
	end
end

--=========================================================================
-- snapshots
--=========================================================================

local function StoreSnapshot(info)
	if not db or not info or not info.shareCode then return end
	-- only worth keeping if it carries real comparison data
	if not info.targetHouseGUID then return end

	db.snapshots[info.shareCode] = {
		info = info,
		guid = PersistableGUID(info.targetHouseGUID),
		when = time(),
	}

	-- trim oldest
	local codes = {}
	for code, snap in pairs(db.snapshots) do
		codes[#codes + 1] = { code = code, when = snap.when or 0 }
	end
	if #codes > MAX_SNAPSHOTS then
		table.sort(codes, function(a, b) return a.when > b.when end)
		for i = MAX_SNAPSHOTS + 1, #codes do
			db.snapshots[codes[i].code] = nil
		end
	end
end

local function GetSnapshot(code)
	local snap = db and db.snapshots and db.snapshots[code]
	if snap and snap.info and snap.info.contentGroups then
		-- If the GUID inside the payload didn't survive being written to
		-- SavedVariables, put the string copy back so the missing columns still
		-- render.
		if not snap.info.targetHouseGUID and snap.guid then
			snap.info.targetHouseGUID = snap.guid
		end
		return snap
	end
	return nil
end

--=========================================================================
-- counting
--=========================================================================

-- Mirrors the arithmetic in Blizzard_HousingBlueprintContentList.lua.
local function CountInfo(info)
	local total, missing = 0, 0
	for _, group in ipairs(info.contentGroups or {}) do
		for _, entry in ipairs(group.entries or {}) do
			total = total + (entry.total or 0)
			if entry.invalid then
				missing = missing + (entry.total or 0)
			else
				missing = missing + (entry.numMissing or 0)
			end
		end
	end
	return total, missing
end

--=========================================================================
-- showing the window
--=========================================================================

-- When an ancestor is hidden (the House Editor closing is exactly this), the frame
-- stops being visible but keeps its OWN shown flag set. ShowUIPanel early-outs on
-- `frame:IsShown()`, so a re-show would silently do nothing and the frame would
-- never get re-registered in its "left" panel slot. Drop the stale flag first.
-- The frame is already invisible at this point, so nothing flickers.
local VALID_STRATA = {
	BACKGROUND = true, LOW = true, MEDIUM = true, HIGH = true,
	DIALOG = true, FULLSCREEN = true, FULLSCREEN_DIALOG = true, TOOLTIP = true,
}

-- The frame declares no strata of its own, so as a UI panel it inherits UIParent's
-- MEDIUM. Every action bar is explicitly frameStrata="MEDIUM"
-- (Blizzard_ActionBar/Shared/MultiActionBars.xml), so within the same strata the
-- bars win on frame level and draw over the window. Blizzard already raises this
-- very frame to HIGH when it draws over the House Editor
-- (HousingBlueprintBaseFrameMixin:ShowSelf), so HIGH is the consistent fix, and it
-- still sits below DIALOG so static popups keep working.
--
-- Only applied on the UIParent path. In the editor, ShowSelf's own HIGH is left
-- alone so a custom setting can't push the window behind the editor UI.
local function ApplyStrata(frame)
	if frame:GetParent() ~= UIParent then return end
	local strata = (db and db.strata) or "HIGH"
	if not VALID_STRATA[strata] then strata = "HIGH" end
	if frame:GetFrameStrata() ~= strata then
		frame:SetFrameStrata(strata)
	end
end

local function ClearStaleShownFlag(frame)
	if frame:IsShown() and not frame:IsVisible() then
		internalHide = true
		frame:Hide()
		internalHide = false
	end
end

-- info: a HousingBlueprintContentInfo payload (live or snapshot)
-- opts.setMissingFilter: tick Blizzard's "missing only" box before showing
function BSL:ShowInfo(info, opts)
	opts = opts or {}
	local frame, reason = EnsureBlizzardUI()
	if not frame then
		Print("could not load %s (%s).", BLIZZ_ADDON, reason)
		return false
	end

	if InCombatLockdown() then
		-- ShowUIPanel refuses to run for addon code in combat; try again after.
		Print("can't open frames in combat, will retry when you drop out.")
		self.pendingInfo = info
		return false
	end

	self:InstallUI(frame)
	ClearStaleShownFlag(frame)

	self.lastInfo = info
	self.lastGUID = info.targetHouseGUID
	if db then db.lastCode = info.shareCode end
	wantShown = true

	if opts.setMissingFilter and db and db.missingOnlyByDefault
		and info.targetHouseGUID and frame.MissingOnlyCheckbox then
		frame.MissingOnlyCheckbox.Checkbox:SetChecked(true)
	end

	-- This is exactly the call Blizzard's own summary panel makes when you click
	-- "Contents". Passing targetHouseGUID through is what unlocks the
	-- "x of y available" columns and the missing-only filter.
	frame:ShowBlueprintContents(info, info.targetHouseGUID)

	-- Deliberately no manual frame:Show() fallback here. The frame is registered
	-- as a UI panel (area = "left", see Blizzard_HousingBlueprintRegistration.lua),
	-- so ShowUIPanel owns both showing and positioning it; forcing Show() would
	-- skip the panel bookkeeping and leave it unpositioned.

	ApplyStrata(frame)   -- also done in the OnShow hook; harmless twice
	return true
end

--=========================================================================
-- requesting
--=========================================================================

function BSL:Request(code, opts)
	opts = opts or {}

	if not C_HousingBlueprint or not C_HousingBlueprint.IsShareCodeValid then
		Print("C_HousingBlueprint is unavailable on this client.")
		return
	end

	-- Normalise the way the import box does, so a pasted link or padded code works.
	if C_HousingBlueprint.UpdateBlueprintStringFromInput then
		local updated = C_HousingBlueprint.UpdateBlueprintStringFromInput(code)
		if updated and updated ~= "" then
			code = updated
		end
	end

	if not C_HousingBlueprint.IsShareCodeValid(code) then
		Print("|cffff4040%s|r isn't a valid share code.", code)
		return
	end

	-- an explicit request is a fresh start for the keep-open watchdog
	self:ResetReshowBurst()

	local guid, source = self:ResolveHouseGUID()
	self.pendingCode = code
	self.pendingOpts = opts
	self.pendingGUID = guid

	if guid and C_HousingBlueprint.RequestBlueprintContentsForContext then
		C_HousingBlueprint.RequestBlueprintContentsForContext(code, guid)
		if BSL.debug then Print("requested with house context (%s)", source) end
	else
		C_HousingBlueprint.RequestBlueprintContents(code)
		if not guid then
			Print("no house GUID cached yet, so missing counts may be blank. Visit your plot once, or try /bsl house.")
		end
	end

	-- Nothing came back? Say so rather than sitting silent.
	self.requestToken = (self.requestToken or 0) + 1
	local token = self.requestToken
	C_Timer.After(10, function()
		if BSL.pendingCode == code and BSL.requestToken == token then
			BSL.pendingCode = nil
			local snap = GetSnapshot(code)
			if snap then
				Print("no answer from the server. Showing the snapshot from %s instead.",
					date("%d %b %H:%M", snap.when or time()))
				BSL:ShowInfo(snap.info, opts)
			else
				Print("no answer from the server for that code.")
			end
		end
	end)
end

local function OnContentsReceived(info)
	if not info or info.shareCode ~= BSL.pendingCode then
		return
	end
	BSL.pendingCode = nil
	local opts = BSL.pendingOpts or {}
	BSL.pendingOpts = nil

	if info.targetHouseGUID then
		StoreSnapshot(info)
		local total, missing = CountInfo(info)
		BSL:ShowInfo(info, opts)
		if missing > 0 then
			Print("%d of %d items missing.", missing, total)
		else
			Print("you have everything (%d items).", total)
		end
		return
	end

	-- No house context came back, so numMissing is meaningless. Prefer a
	-- snapshot that does have one.
	local snap = GetSnapshot(info.shareCode)
	if snap then
		Print("server gave no house context from here. Showing the snapshot from %s (missing counts as of then).",
			date("%d %b %H:%M", snap.when or time()))
		BSL:ShowInfo(snap.info, opts)
	else
		Print("server gave no house context from here, so this is a plain contents list with no missing counts.")
		BSL:ShowInfo(info, opts)
	end
end

local function OnContentsFailure(code, result)
	if code ~= BSL.pendingCode then return end
	BSL.pendingCode = nil
	local snap = GetSnapshot(code)
	if snap then
		Print("request failed (%s). Showing the snapshot from %s.",
			ResultText(result), date("%d %b %H:%M", snap.when or time()))
		BSL:ShowInfo(snap.info, BSL.pendingOpts)
	else
		Print("request failed: %s", ResultText(result))
	end
	BSL.pendingOpts = nil
end

--=========================================================================
-- keep-open watchdog
--=========================================================================

local function ShouldReshow()
	return db and db.keepOpen and wantShown and BSL.lastInfo and not internalHide
end

-- If something out there is determined to keep the frame hidden, stop fighting it
-- rather than flickering forever.
local reshowBurst, reshowBurstStart = 0, 0
local RESHOW_BURST_LIMIT, RESHOW_BURST_WINDOW = 6, 10

function BSL:ResetReshowBurst()
	reshowBurst, reshowBurstStart = 0, GetTime()
end

local function ReShow(delay)
	if not ShouldReshow() then return end
	if reshowScheduled then return end

	local now = GetTime()
	if now - reshowBurstStart > RESHOW_BURST_WINDOW then
		reshowBurst, reshowBurstStart = 0, now
	end
	reshowBurst = reshowBurst + 1
	if reshowBurst > RESHOW_BURST_LIMIT then
		wantShown = false
		Print("something keeps closing the list, so I've stopped reopening it. /bsl to bring it back.")
		return
	end

	reshowScheduled = true
	C_Timer.After(delay or 0.1, function()
		reshowScheduled = false
		if not ShouldReshow() then return end
		local frame = _G.HousingBlueprintContentListFrame
		-- IsVisible, not IsShown: after an ancestor is hidden the frame's own
		-- shown flag lies, and IsShown() would make us think it's still up.
		if not frame or frame:IsVisible() then return end
		if InCombatLockdown() then return end   -- PLAYER_REGEN_ENABLED retries
		BSL:ShowInfo(BSL.lastInfo)
	end)
end

--=========================================================================
-- UI additions (idempotent)
--=========================================================================

local CHECK_TEMPLATES = { "MinimalCheckboxArtTemplate", "UICheckButtonTemplate", "InterfaceOptionsCheckButtonTemplate" }

local function CreateCheckbox(parent)
	for _, template in ipairs(CHECK_TEMPLATES) do
		local ok, cb = pcall(CreateFrame, "CheckButton", nil, parent, template)
		if ok and cb then
			return cb
		end
	end
	return CreateFrame("CheckButton", nil, parent)
end

function BSL:InstallUI(frame)
	if uiInstalled then return end
	frame = frame or _G.HousingBlueprintContentListFrame
	if not frame then return end
	uiInstalled = true

	--------------------------------------------------------------------
	-- "Keep this window open" checkbox
	--------------------------------------------------------------------
	-- Bottom-left, in the band below the scroll box. The label stays short so it
	-- can't run into BottomCloseButton, which is centred there and 152 wide on a
	-- 384-wide frame; the tooltip carries the full explanation.
	local holder = CreateFrame("Frame", nil, frame)
	holder.ignoreInLayout = true          -- the base template is layout-aware
	holder:SetSize(100, 24)
	holder:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 12)

	local cb = CreateCheckbox(holder)
	cb.ignoreInLayout = true
	cb:SetSize(24, 24)
	cb:SetPoint("LEFT", holder, "LEFT", 0, 0)

	local label = holder:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	label:SetText("Keep open")

	cb:SetChecked(db and db.keepOpen)
	cb:SetScript("OnClick", function(self)
		local on = self:GetChecked() and true or false
		if db then db.keepOpen = on end
		PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
		if on then wantShown = true end
	end)
	cb:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip_SetTitle(GameTooltip, "Keep this window open")
		GameTooltip_AddNormalLine(GameTooltip,
			"Bring the list back if it gets closed by leaving the housing zone, closing the House Editor, or zoning.")
		GameTooltip_AddNormalLine(GameTooltip,
			"Clicking the close button or pressing Escape still closes it for good.")
		GameTooltip:Show()
	end)
	cb:SetScript("OnLeave", function() GameTooltip:Hide() end)

	frame.BSLKeepOpen = cb

	--------------------------------------------------------------------
	-- Tell "my ancestor was hidden" apart from "something closed me".
	--
	-- OnHide fires for both, but the frame's own shown flag distinguishes them:
	--   * ancestor hidden  -> self:IsShown() is still true  (House Editor closing,
	--                         leaving the plot: the case this addon exists for)
	--   * closed directly  -> self:IsShown() is false       (X button, bottom
	--                         Close, Escape via CloseAllWindows, or another
	--                         "left" panel taking the slot)
	--
	-- Anything that closes it directly is treated as intent, so we never fight
	-- the panel manager or reopen a window you just dismissed. /bsl brings it back.
	--------------------------------------------------------------------
	frame:HookScript("OnHide", function(self)
		if internalHide then return end

		if self:IsShown() then
			ReShow(0.15)
		else
			wantShown = false
		end
	end)

	-- Covers every way the window can open, including Blizzard's own import flow,
	-- so the stock "Contents" button gets the fix too.
	frame:HookScript("OnShow", function(self)
		ApplyStrata(self)
	end)

	ApplyStrata(frame)
end

--=========================================================================
-- events
--=========================================================================

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("ADDON_LOADED")
watcher:RegisterEvent("PLAYER_LOGIN")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:RegisterEvent("PLAYER_REGEN_ENABLED")
watcher:RegisterEvent("HOUSING_BLUEPRINT_CONTENTS_RECEIVED")
watcher:RegisterEvent("HOUSING_BLUEPRINT_CONTENTS_FAILURE")
watcher:RegisterEvent("PLAYER_HOUSE_LIST_UPDATED")
watcher:RegisterEvent("TRACKED_HOUSE_CHANGED")
watcher:RegisterEvent("CURRENT_HOUSE_INFO_RECIEVED")   -- yes, Blizzard spells it that way
watcher:RegisterEvent("HOUSE_PLOT_ENTERED")
watcher:RegisterEvent("HOUSE_PLOT_EXITED")

watcher:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		local name = ...
		if name == ADDON_NAME then
			BlueprintShoppingListDB = BlueprintShoppingListDB or {}
			db = BlueprintShoppingListDB
			for key, value in pairs(DEFAULTS) do
				if db[key] == nil then
					db[key] = (type(value) == "table") and {} or value
				end
			end
		elseif name == BLIZZ_ADDON then
			-- someone else loaded it; get our bits in there
			BSL:InstallUI()
		end

	elseif event == "PLAYER_LOGIN" then
		RequestOwnedHouses()
		-- If the blueprint UI is already loaded, get our checkbox and the strata
		-- fix in now, so opening the window Blizzard's own way benefits too.
		BSL:InstallUI()

	elseif event == "PLAYER_ENTERING_WORLD" then
		RequestOwnedHouses()
		ReShow(1.5)

	elseif event == "PLAYER_REGEN_ENABLED" then
		if BSL.pendingInfo then
			local info = BSL.pendingInfo
			BSL.pendingInfo = nil
			BSL:ShowInfo(info)
		else
			ReShow(0.2)
		end

	elseif event == "HOUSING_BLUEPRINT_CONTENTS_RECEIVED" then
		OnContentsReceived(...)

	elseif event == "HOUSING_BLUEPRINT_CONTENTS_FAILURE" then
		OnContentsFailure(...)

	elseif event == "PLAYER_HOUSE_LIST_UPDATED" then
		local houseInfos = ...
		if type(houseInfos) == "table" then
			for _, info in ipairs(houseInfos) do
				if info.houseGUID then
					RememberHouseGUID(info.houseGUID, "owned house list")
					break
				end
			end
		end

	elseif event == "TRACKED_HOUSE_CHANGED" then
		if C_Housing and C_Housing.GetTrackedHouseGuid then
			RememberHouseGUID(C_Housing.GetTrackedHouseGuid(), "tracked house changed")
		end

	elseif event == "CURRENT_HOUSE_INFO_RECIEVED" then
		-- ownership-gated, so visiting a neighbour doesn't overwrite our GUID
		RememberHouseGUID(CurrentOwnedHouseGUID(), "current house info")

	elseif event == "HOUSE_PLOT_ENTERED" or event == "HOUSE_PLOT_EXITED" then
		BSL:ResolveHouseGUID()
		ReShow(0.5)
	end
end)

-- The parent swap is the exact moment the stock window dies. Catch it for good.
EventRegistry:RegisterCallback("UI.AlternateTopLevelParentChanged", function()
	ReShow(0.2)
end, watcher)

EventRegistry:RegisterCallback("HouseEditor.StateUpdated", function()
	ReShow(0.3)
end, watcher)

--=========================================================================
-- entry points
--=========================================================================

--- Open the missing-decor list for a share code from anywhere.
--- Handy as: /run LoadBlueprint("ABC123")
function _G.LoadBlueprint(code)
	if type(code) ~= "string" or code == "" then
		Print("usage: /run LoadBlueprint(\"<share code>\")")
		return
	end
	BSL:Request(code, { setMissingFilter = true })
end

local function PrintMissing()
	local info = BSL.lastInfo
	if not info then
		Print("nothing loaded. Try /bsl <code> first.")
		return
	end
	if not info.targetHouseGUID then
		Print("this list has no house context, so there are no missing counts to print.")
		return
	end

	local lines = 0
	for _, group in ipairs(info.contentGroups or {}) do
		for _, entry in ipairs(group.entries or {}) do
			local short = entry.invalid and (entry.total or 0) or (entry.numMissing or 0)
			if short > 0 then
				local text = entry.name or ("record " .. tostring(entry.recordID))
				if entry.contentType == Enum.HousingBlueprintContentType.Decor
					and C_HousingDecor and C_HousingDecor.GetDecorHyperlink then
					local link = C_HousingDecor.GetDecorHyperlink(entry.recordID)
					if link then text = link end
				end
				print(("  %dx %s%s"):format(short, text, entry.invalid and " |cffff4040(unusable)|r" or ""))
				lines = lines + 1
			end
		end
	end
	if lines == 0 then
		Print("nothing missing.")
	else
		Print("%d entries short (shift-click a decor link to chat).", lines)
	end
end

local function HandleSlash(msg)
	if type(msg) ~= "string" then msg = "" end
	msg = strtrim(msg)
	local cmd, rest = msg:match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()

	if cmd == "" then
		local code = db and db.lastCode
		if code then
			BSL:Request(code, { setMissingFilter = true })
		else
			Print("usage: /bsl <share code>   (see /bsl help)")
		end

	elseif cmd == "help" then
		Print("commands:")
		print("  |cffffff00/bsl <code>|r      open that blueprint's contents list, anywhere")
		print("  |cffffff00/bsl|r             reopen the last one")
		print("  |cffffff00/bsl missing|r     print what you're short of, to chat")
		print("  |cffffff00/bsl import|r      open the full import window (needs a code)")
		print("  |cffffff00/bsl keep|r        toggle \"keep this window open\"")
		print("  |cffffff00/bsl strata|r      layer it above/below other frames (default HIGH)")
		print("  |cffffff00/bsl house|r       show which house the counts compare against")
		print("  |cffffff00/bsl snapshots|r   list cached blueprints")
		print("  |cffffff00/bsl reset|r       clear snapshots and re-detect your house")
		print("  also: |cffffff00/run LoadBlueprint(\"<code>\")|r")

	elseif cmd == "missing" or cmd == "list" then
		PrintMissing()

	elseif cmd == "keep" then
		if db then
			db.keepOpen = not db.keepOpen
			if _G.HousingBlueprintContentListFrame and _G.HousingBlueprintContentListFrame.BSLKeepOpen then
				_G.HousingBlueprintContentListFrame.BSLKeepOpen:SetChecked(db.keepOpen)
			end
			Print("keep open is now %s.", db.keepOpen and "|cff40ff40on|r" or "|cffff4040off|r")
		end

	elseif cmd == "strata" then
		local want = rest:upper()
		if want == "" then
			Print("strata is %s. Set another with /bsl strata <LOW|MEDIUM|HIGH|DIALOG>.",
				(db and db.strata) or "HIGH")
		elseif VALID_STRATA[want] then
			db.strata = want
			local frame = _G.HousingBlueprintContentListFrame
			if frame then ApplyStrata(frame) end
			Print("strata set to %s.", want)
		else
			Print("|cffff4040%s|r isn't a strata. Use LOW, MEDIUM, HIGH or DIALOG.", want)
		end

	elseif cmd == "house" then
		local guid, source = BSL:ResolveHouseGUID()
		if guid then
			Print("comparing against house %s (source: %s).", tostring(guid), source)
		else
			Print("no house GUID known yet. Requesting the owned-house list; try again in a moment.")
			RequestOwnedHouses()
		end

	elseif cmd == "import" then
		local code = (rest ~= "" and rest) or (db and db.lastCode)
		if not code then
			Print("usage: /bsl import <share code>")
			return
		end
		if HousingFramesUtil and HousingFramesUtil.ShowBlueprintImport then
			HousingFramesUtil.ShowBlueprintImport(code)
		else
			Print("HousingFramesUtil is unavailable.")
		end

	elseif cmd == "snapshots" then
		local any = false
		for code, snap in pairs((db and db.snapshots) or {}) do
			local total, missing = CountInfo(snap.info)
			print(("  %s  %d/%d missing  %s"):format(code, missing, total,
				date("%d %b %H:%M", snap.when or 0)))
			any = true
		end
		if not any then Print("no snapshots cached yet.") end

	elseif cmd == "reset" then
		if db then
			db.snapshots = {}
			db.houseGUID = nil
			sessionHouseGUID = nil
			RequestOwnedHouses()
			Print("snapshots cleared and house GUID re-requested.")
		end

	elseif cmd == "debug" then
		BSL.debug = not BSL.debug
		Print("debug %s.", BSL.debug and "on" or "off")

	else
		-- anything else is treated as a share code
		BSL:Request(msg, { setMissingFilter = true })
	end
end

SLASH_BLUEPRINTSHOPPINGLIST1 = "/bsl"
SLASH_BLUEPRINTSHOPPINGLIST2 = "/blueprintlist"
SlashCmdList["BLUEPRINTSHOPPINGLIST"] = HandleSlash
