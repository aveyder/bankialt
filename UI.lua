local ADDON, ns = ...

local UI = {}
ns.UI = UI

local COLS, SIZE, GAP, PAD = 10, 37, 4, 8
local MIN_ROWS = 4
local GRID_W = COLS * (SIZE + GAP) - GAP
local ATTIC, BOTTOM_BAR = 60, 44 -- inset starts 60px below the top; bottom bar fits two money rows

local GetItemInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
local GetItemIcon = C_Item and C_Item.GetItemIconByID or GetItemIcon
local GetItemQuality = C_Item and C_Item.GetItemQualityByID or function() end

local EMPTY_SLOT = "Interface\\PaperDoll\\UI-Backpack-EmptySlot"
-- label, r, g, b, corner icon
local STATUS = {
	flight   = { "In flight",                        0.40, 0.78, 1.00, "Interface\\Minimap\\Tracking\\Mailbox" },
	mailbox  = { "In the banker's mailbox",          1.00, 0.82, 0.00, "Interface\\Minimap\\Tracking\\Mailbox" },
	returned = { "Returned by the AH, in mailbox",   1.00, 0.60, 0.20, "Interface\\Buttons\\UI-RefreshButton" },
	toMain   = { "Sent back to a main",              0.40, 1.00, 0.40, "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up" },
	owned    = { "With the banker",                  1.00, 1.00, 1.00 },
	unknown  = { "Unknown: left the banker's bags",  0.60, 0.60, 0.60, "Interface\\RaidFrame\\ReadyCheck-Waiting" },
}

-- One corner icon per slot: the status that most needs attention wins.
local FLAG_ORDER = { "unknown", "returned", "toMain", "flight", "mailbox" }

local function Flag(r)
	for _, key in ipairs(FLAG_ORDER) do
		if r[key] then return STATUS[key][5] end
	end
end

--[[ Window ]]--

local f = CreateFrame("Frame", "BankiAltFrame", UIParent, "ButtonFrameTemplate")
f:SetWidth(GRID_W + 2 * PAD + 10)
f:SetPoint("CENTER")
f:SetToplevel(true)
f:SetMovable(true)
f:SetClampedToScreen(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:Hide()
tinsert(UISpecialFrames, f:GetName())

if f.SetPortraitToAsset then f:SetPortraitToAsset(ns.ICON) end

local function SetTitle(text)
	if f.SetTitle then f:SetTitle(text) end
end

f:SetScript("OnDragStart", f.StartMoving)
f:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local point, _, relPoint, x, y = self:GetPoint()
	ns.db.ui.point = { point, relPoint, x, y }
	UI.dock = nil -- dragged away: no longer docked
end)
f:SetScript("OnShow", function() PlaySound(SOUNDKIT.IG_BACKPACK_OPEN) end)
f:SetScript("OnHide", function() PlaySound(SOUNDKIT.IG_BACKPACK_CLOSE) end)

local ageText = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
ageText:SetPoint("TOPLEFT", 64, -38)
ageText:SetPoint("RIGHT", -10, 0)
ageText:SetJustifyH("LEFT")

-- Bag grid
local bag = CreateFrame("Frame", nil, f.Inset)
bag:SetPoint("TOPLEFT", PAD, -PAD)
bag:SetWidth(GRID_W)

local setupText = f.Inset:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
setupText:SetPoint("CENTER", bag)
setupText:SetWidth(GRID_W - 40)

-- Bottom bar: action buttons or summary on the left; the banker's money on the right in two rows
f.Inset:SetPoint("BOTTOMRIGHT", -6, BOTTOM_BAR)

local action = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
action:SetSize(130, 22)
action:SetPoint("BOTTOMLEFT", 4, 11)

local clear = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
clear:SetSize(80, 22)
clear:SetPoint("LEFT", action, "RIGHT", 2, 0)
clear:SetText(CLEAR_ALL or "Clear")
clear:SetScript("OnClick", ns.ClearStaged)

-- The Send button explains what it will send (also while disabled, when nothing is added yet).
if action.SetMotionScriptsWhileDisabled then action:SetMotionScriptsWhileDisabled(true) end
action:SetScript("OnEnter", function(self)
	if ns.Mode() ~= "send" then return end
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	local items, mails = #ns.staged, ns.MailCount()
	if items == 0 then
		GameTooltip:SetText("Nothing to send yet")
		GameTooltip:AddLine("Drag items into the bag or Alt-click them in your bags.", 1, 1, 1, true)
	else
		GameTooltip:SetText(format("Send to %s", ns.db.banker))
		GameTooltip:AddLine(format("%d item%s in %d mail%s", items, items == 1 and "" or "s", mails, mails == 1 and "" or "s"), 1, 1, 1)
	end
	GameTooltip:Show()
end)
action:SetScript("OnLeave", GameTooltip_Hide)

local summary = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
summary:SetPoint("BOTTOMLEFT", 12, 17)

local moneyBox = CreateFrame("Frame", nil, f)
moneyBox:SetAllPoints()

local function MoneyRow(name, label, y)
	local m = CreateFrame("Frame", name, moneyBox, "SmallMoneyFrameTemplate")
	m:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, y)
	MoneyFrame_SetType(m, "STATIC")
	local text = moneyBox:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	text:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 222, y + 2)
	text:SetText(label)
	return m, text
end

local money = MoneyRow("BankiAltFrameMoney", "Current:", 24)
local expected, expectedLabel = MoneyRow("BankiAltFrameExpected", "Auctions:", 7)

--[[ The AH balance: the "Auctions" row lists the banker's auctions on hover ]]--

local MAX_AUCTION_ROWS = 15

local MoneyText = GetMoneyString or GetCoinTextureString

-- an orange "!" after the amount while an auction is past its time with no mail from the AH seen
local stuckMark = moneyBox:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
stuckMark:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 9)
stuckMark:SetText("|cffff8000!|r")

local function HasExpired(d)
	for _, p in ipairs(d.snap.posted) do
		if ns.IsExpired(p) then return true end
	end
	return false
end

-- running auctions first (ending soonest on top), then the expired ones
local function SortedAuctions(d)
	local list = {}
	for _, p in ipairs(d.snap.posted) do tinsert(list, p) end
	table.sort(list, function(a, b)
		local ea, eb = ns.IsExpired(a), ns.IsExpired(b)
		if ea ~= eb then return eb end
		return a.expires < b.expires
	end)
	return list
end

local function AuctionLabel(p)
	return format("|T%s:14|t %s x%d", GetItemIcon(p.itemID) or "", GetItemInfo(p.itemID) or ("item " .. p.itemID), p.qty)
end

local expectedHit = CreateFrame("Frame", nil, moneyBox)
expectedHit:SetPoint("TOPLEFT", expectedLabel, -2, 2)
expectedHit:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 5)
expectedHit:SetFrameLevel(expected:GetFrameLevel() + 5) -- above the coins, so they don't take the mouse
expectedHit:EnableMouse(true)

expectedHit:SetScript("OnEnter", function(self)
	local d = ns.Data()
	if not d then return end
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:AddDoubleLine("On the auction house", MoneyText(ns.ExpectedIncome(d)),
		NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b, 1, 1, 1)
	local list = SortedAuctions(d)
	for i, p in ipairs(list) do
		if i > MAX_AUCTION_ROWS then
			GameTooltip:AddLine(format("and %d more", #list - MAX_AUCTION_ROWS), 0.6, 0.6, 0.6)
			break
		end
		local left = ns.IsExpired(p) and "|cff808080expired|r" or SecondsToTime(p.expires - time(), true, false, 1)
		GameTooltip:AddDoubleLine(AuctionLabel(p), format("%s  %s", MoneyText(math.floor(ns.AuctionWorth(p))), left), 1, 1, 1, 1, 1, 1)
	end
	local sale = d.snap.saleMoney or 0
	if sale > 0 then
		GameTooltip:AddDoubleLine("Sale gold in the mailbox", MoneyText(sale), 1, 1, 1, 1, 1, 1)
	end
	if HasExpired(d) then
		GameTooltip:AddLine("Expired: past its time, but the AH's mail hasn't been seen.", 0.6, 0.6, 0.6, true)
		GameTooltip:AddLine("Right-click: remove expired auctions", 0.6, 0.6, 0.6)
	end
	GameTooltip:Show()
end)
expectedHit:SetScript("OnLeave", GameTooltip_Hide)

-- Right-click: settle each expired auction by hand: it sold (drop it), or it came back (back into the bag).
local SOLD, BACK = "It sold", "It came back"
local easyMenuFrame

local function ShowAuctionMenu(owner)
	local d = ns.Data()
	if not d then return end
	local expired = {}
	for _, p in ipairs(SortedAuctions(d)) do
		if ns.IsExpired(p) then tinsert(expired, p) end
	end
	if #expired == 0 then return end
	GameTooltip:Hide()

	if MenuUtil and MenuUtil.CreateContextMenu then
		MenuUtil.CreateContextMenu(owner, function(_, root)
			root:CreateTitle("Expired auctions")
			for _, p in ipairs(expired) do
				local entry = root:CreateButton(AuctionLabel(p))
				entry:CreateButton(SOLD, function() ns.DropAuction(p, false) end)
				entry:CreateButton(BACK, function() ns.DropAuction(p, true) end)
			end
		end)
	elseif EasyMenu then
		local list = { { text = "Expired auctions", isTitle = true, notCheckable = true } }
		for _, p in ipairs(expired) do
			tinsert(list, { text = AuctionLabel(p), hasArrow = true, notCheckable = true, menuList = {
				{ text = SOLD, notCheckable = true, func = function() ns.DropAuction(p, false) CloseDropDownMenus() end },
				{ text = BACK, notCheckable = true, func = function() ns.DropAuction(p, true) CloseDropDownMenus() end },
			} })
		end
		easyMenuFrame = easyMenuFrame or CreateFrame("Frame", "BankiAltAuctionMenu", UIParent, "UIDropDownMenuTemplate")
		EasyMenu(list, easyMenuFrame, "cursor", 0, 0, "MENU")
	end
end

expectedHit:SetScript("OnMouseUp", function(self, button)
	if button == "RightButton" then ShowAuctionMenu(self) end
end)

-- The row is shown while there are AH entries or sale gold; the "!" while an entry is expired.
local function UpdateAuctionsRow(d)
	local s = d.snap
	local shown = #s.posted > 0 or (s.saleMoney or 0) > 0
	local stuck = shown and HasExpired(d)
	MoneyFrame_Update(expected, ns.ExpectedIncome(d))
	expected:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", stuck and -14 or -2, 7)
	expected:SetShown(shown)
	expectedLabel:SetShown(shown)
	expectedHit:SetShown(shown)
	stuckMark:SetShown(stuck)
end

--[[ Dropping items ]]--

function UI.Drop()
	local kind, itemID = GetCursorInfo()
	if kind ~= "item" then return end
	if ns.Mode() ~= "send" then
		ns.Print("Items can only be added at a mailbox, on one of your main characters.")
		return
	end
	local bagID, slot = ns.FindLockedSlot(itemID)
	ClearCursor()
	if bagID then
		ns.Stage(bagID, slot)
	else
		ns.Print("Only items from your bags can be added.")
	end
end

f:SetScript("OnReceiveDrag", UI.Drop)
f.Inset:EnableMouse(true)
f.Inset:SetScript("OnReceiveDrag", UI.Drop)
f.Inset:SetScript("OnMouseUp", UI.Drop)

--[[ Slots ]]--

StaticPopupDialogs["BANKIALT_FORGET"] = {
	text = "Remove %s from the virtual bag?",
	button1 = REMOVE or YES,
	button2 = CANCEL,
	-- the item is set on the dialog after showing it (as Auctionator does): this client may not pass the data argument on
	OnAccept = function(self) if self.data then ns.Forget(self.data) end end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

local function SlotOnEnter(self)
	if not self.itemID then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	if self.link then
		GameTooltip:SetHyperlink(self.link)
	else
		GameTooltip:SetItemByID(self.itemID)
	end

	local r = self.breakdown
	GameTooltip:AddLine(" ")
	if self.staged then
		GameTooltip:AddLine(format("Will be mailed to %s when you press Send.", ns.db.banker), 0.4, 0.78, 1, true)
		GameTooltip:AddLine("Click to take it back. Right-click to take it off the list.", 0.6, 0.6, 0.6, true)
	elseif r then
		GameTooltip:AddDoubleLine(ns.db.banker, r.total, NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b, 1, 1, 1)
		for _, key in ipairs(ns.STATUSES) do
			if r[key] then
				local s = STATUS[key]
				local label = s[5] and format("|T%s:14|t %s", s[5], s[1]) or s[1]
				GameTooltip:AddDoubleLine(label, r[key], s[2], s[3], s[4], 1, 1, 1)
			end
		end
		GameTooltip:AddLine("Right-click to remove it from the virtual bag.", 0.6, 0.6, 0.6)
	end
	GameTooltip:Show()
end

-- Items added this session are still in your bags: picking one up puts the real item on the cursor.
-- Everything else is with the banker (or on its way) and can't be taken out.
local function PickUp(self)
	if self.staged then
		if ns.IsSending() then return end
		local s = self.staged
		ns.Unstage(s)
		C_Container.PickupContainerItem(s.bag, s.slot)
	elseif self.itemID then
		UIErrorsFrame:AddMessage(format("That item is with %s.", ns.db.banker or "your banker"), 1, 0.1, 0.1, 1)
	end
end

local function SlotOnClick(self, button)
	if GetCursorInfo() then
		return UI.Drop()
	end
	if not self.itemID then return end
	local link = self.link or select(2, GetItemInfo(self.itemID))
	if IsModifiedClick() then
		HandleModifiedItemClick(link)
	elseif button == "RightButton" then
		if self.staged then
			ns.Unstage(self.staged)
		else
			local dialog = StaticPopup_Show("BANKIALT_FORGET", link or ("item " .. self.itemID))
			if dialog then dialog.data = self.itemID end
		end
	else
		PickUp(self)
	end
end

local function NewPool(parent)
	local pool = {}
	function pool:Get(i)
		if self[i] then return self[i] end
		local ok, b = pcall(CreateFrame, "ItemButton", nil, parent)
		if not ok then
			b = CreateFrame("Button", nil, parent, "ItemButtonTemplate")
		end
		b:SetSize(SIZE, SIZE)
		b:SetPoint("TOPLEFT", ((i - 1) % COLS) * (SIZE + GAP), -math.floor((i - 1) / COLS) * (SIZE + GAP))
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		b:RegisterForDrag("LeftButton")
		b:SetScript("OnDragStart", PickUp)
		b:SetScript("OnEnter", SlotOnEnter)
		b:SetScript("OnLeave", GameTooltip_Hide)
		b:SetScript("OnClick", SlotOnClick)
		b:SetScript("OnReceiveDrag", UI.Drop)
		b.flag = b:CreateTexture(nil, "OVERLAY", nil, 7)
		b.flag:SetSize(16, 16)
		b.flag:SetPoint("TOPRIGHT", 3, 3)
		self[i] = b
		return b
	end
	-- Fills `slots` slots: the first ones with entries, the rest empty. Returns the grid height.
	function pool:Fill(entries, slots)
		for i = 1, slots do
			local b, e = self:Get(i), entries[i]
			b.itemID, b.link, b.staged, b.breakdown = e and e.itemID, e and e.link, e and e.staged, e and e.breakdown
			if e then
				SetItemButtonTexture(b, GetItemIcon(e.itemID))
				SetItemButtonCount(b, e.count)
				SetItemButtonQuality(b, GetItemQuality(e.itemID), e.link or e.itemID)
			else
				SetItemButtonTexture(b, EMPTY_SLOT)
				SetItemButtonCount(b, 0)
				SetItemButtonQuality(b, nil)
			end
			SetItemButtonDesaturated(b, e and e.dim or false)
			local r = e and e.breakdown
			local flag = r and Flag(r)
			b.flag:SetTexture(flag or nil)
			b.flag:SetShown(flag and true or false)
			b:Show()
		end
		for i = slots + 1, #self do self[i]:Hide() end
		return math.ceil(slots / COLS) * (SIZE + GAP) - GAP
	end
	return pool
end

local bagSlots = NewPool(bag)

--[[ Refresh ]]--

local function Age(t)
	return SecondsToTime(math.max(60, time() - t), true, false, 1)
end

local function ItemName(itemID)
	return GetItemInfo(itemID) or ""
end

local function TrackedEntries(d)
	local list = {}
	if not d then return list end
	for itemID in pairs(d.tracked) do
		local r = ns.Breakdown(d, itemID)
		if r.total > 0 then
			tinsert(list, { itemID = itemID, count = r.total, breakdown = r })
		end
	end
	table.sort(list, function(a, b)
		local na, nb = ItemName(a.itemID), ItemName(b.itemID)
		if na ~= nb then return na < nb end
		return a.itemID < b.itemID
	end)
	return list
end

local function Rows(n, min)
	return math.max(min, math.ceil(n / COLS)) * COLS
end

function UI.Refresh()
	if not f:IsShown() or not ns.db then return end
	local mode = ns.Mode()
	local d = ns.Data()

	-- header
	SetTitle(ns.db.banker or ns.TAG)
	if not d then
		ageText:SetText("")
	elseif ns.IsBanker() then
		ageText:SetText("This character")
	elseif d.snap.time then
		ageText:SetText(format("Banker data from %s ago", Age(d.snap.time)))
	else
		ageText:SetText("Log in on the banker once to load its data")
	end

	-- bag grid: at the mailbox, what was already sent is greyed out and the items added this session
	-- follow in color, in the order they were added
	local entries = TrackedEntries(d)
	local slots = {}
	for _, e in ipairs(entries) do
		e.dim = mode == "send"
		tinsert(slots, e)
	end
	if mode == "send" then
		for _, s in ipairs(ns.staged) do
			tinsert(slots, { itemID = s.itemID, link = s.link, count = s.count, staged = s })
		end
	end
	local bagH = bagSlots:Fill(slots, Rows(#slots, MIN_ROWS))
	bag:SetHeight(bagH)
	setupText:SetText(mode == "setup" and "Choose your banker and your main characters in the settings." or "")

	f:SetHeight(ATTIC + PAD + bagH + PAD + BOTTOM_BAR)

	-- bottom bar
	local s = d and d.snap
	if s and s.money then
		MoneyFrame_Update(money, s.money)
		UpdateAuctionsRow(d)
		moneyBox:Show()
	else
		moneyBox:Hide()
	end

	action:Hide()
	clear:Hide()
	summary:SetText("")
	action:Enable()

	if mode == "setup" then
		action:SetText(SETTINGS or "Settings")
		action:SetScript("OnClick", ns.OpenSettings)
		action:Show()
	elseif mode == "send" then
		local n = ns.MailCount()
		action:SetScript("OnClick", ns.Send)
		if ns.IsSending() then
			action:SetText("Sending...")
			action:Disable()
		else
			action:SetText(n > 0 and format("%s (%d)", SEND_LABEL or "Send", n) or (SEND_LABEL or "Send"))
			action:SetEnabled(n > 0)
		end
		action:Show()
		clear:SetShown(#ns.staged > 0 and not ns.IsSending())
	elseif mode == "collect" then
		local n = ns.CollectableCount()
		action:SetScript("OnClick", ns.Collect)
		if ns.IsCollecting() then
			action:SetText("Collecting...")
			action:Disable()
		else
			action:SetText(format("Collect (%d)", n))
			action:SetEnabled(n > 0)
		end
		action:Show()
	else
		summary:SetText(format("%d item%s", #entries, #entries == 1 and "" or "s"))
	end
end

ns.Listen(UI.Refresh)

-- Where the window can be attached: next to the mailbox, or to the left of Bagnon's bag window.
local function DockTarget(dock)
	if dock == "mail" and MailFrame:IsShown() then
		return MailFrame, "TOPLEFT", "TOPRIGHT", 40, 0
	elseif dock == "bagnon" and UI.bagnon and UI.bagnon:IsShown() then
		return UI.bagnon, "TOPRIGHT", "TOPLEFT", -36, 0
	end
end

-- dock: "mail", "bagnon" or nil (free-floating, at the last place the window was dragged to)
function UI.Show(dock)
	if not f:IsShown() then
		f:ClearAllPoints()
		local target, point, relPoint, x, y = DockTarget(dock)
		local p = ns.db.ui.point
		if target then
			f:SetPoint(point, target, relPoint, x, y)
		elseif p then
			f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
		else
			f:SetPoint("CENTER")
		end
		UI.dock = target and dock or nil
		f:Show()
	end
	UI.Refresh()
end

-- At the mailbox, dock to Bagnon's bag window when it's open (Bagnon opens it with the mailbox), else to the mailbox.
local function MailboxDock()
	return ns.db.ui.bagnon and UI.bagnon and UI.bagnon:IsShown() and "bagnon" or "mail"
end

function UI.Toggle(dock)
	if f:IsShown() then
		f:Hide()
	else
		UI.Show(dock)
	end
end

function UI.IsShown()
	return f:IsShown()
end

-- Open automatically at the mailbox on the banker and the mains (next frame, once the mailbox and
-- Bagnon's bag window are shown), unless turned off in the settings.
ns.On("BA_MAIL_OPENED", function()
	C_Timer.After(0, function()
		local mode = ns.Mode()
		if ns.db.ui.autoOpen and ns.open.mail and (mode == "send" or mode == "collect") then
			UI.Show(MailboxDock())
		end
	end)
end)

-- A docked window closes together with what it is docked to, like the bags do.
ns.On("BA_MAIL_CLOSED", function()
	if UI.dock == "mail" then f:Hide() end
end)

--[[ Alt-click in bags (Blizzard bags and Bagnon) adds the item to the outgoing list ]]--

hooksecurefunc("HandleModifiedItemClick", function(link, itemLocation)
	if not ns.db or not link or not IsAltKeyDown() or IsShiftKeyDown() or IsControlKeyDown() then return end
	if ns.Mode() ~= "send" then return end
	if GetMouseButtonClicked and GetMouseButtonClicked() ~= "LeftButton" then return end

	local bagID, slot
	local focus = GetMouseFoci and GetMouseFoci()[1] or GetMouseFocus and GetMouseFocus()
	if focus and type(focus.bag) == "number" and focus.GetID then -- Bagnon item button
		bagID, slot = focus.bag, focus:GetID()
	elseif itemLocation and itemLocation.IsBagAndSlot and itemLocation:IsBagAndSlot() then
		bagID, slot = itemLocation:GetBagAndSlot()
	end

	if bagID and C_Container.GetContainerItemLink(bagID, slot) == link and ns.Stage(bagID, slot) then
		UI.Show(MailboxDock())
	end
end)

--[[ Side tabs (spellbook-style) on the mailbox and on Bagnon's bag window ]]--

-- side "right": the tab sticks out of the parent's right edge; "left": out of its left edge (mirrored art)
local function CreateSideTab(name, parent, side, dock)
	local b = CreateFrame("Button", name, parent)
	b:SetSize(32, 32)

	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
	bg:SetSize(64, 64)
	if side == "right" then
		b:SetPoint("TOPLEFT", parent, "TOPRIGHT", 0, -50)
		bg:SetPoint("TOPLEFT", -3, 11)
	else
		b:SetPoint("TOPRIGHT", parent, "TOPLEFT", 0, -50)
		bg:SetPoint("TOPRIGHT", 3, 11)
		bg:SetTexCoord(1, 0, 0, 1)
	end

	b:SetNormalTexture(ns.ICON)
	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	b:SetScript("OnClick", function() UI.Toggle(dock) end)
	b:SetScript("OnEnter", function(self) UI.ShowButtonTip(self, side == "right" and "ANCHOR_RIGHT" or "ANCHOR_LEFT") end)
	b:SetScript("OnLeave", GameTooltip_Hide)
	return b
end

function UI.ShowButtonTip(owner, anchor)
	GameTooltip:SetOwner(owner, anchor)
	GameTooltip:SetText(ns.TAG)
	GameTooltip:AddLine(ns.db.banker and ("Virtual bag of " .. ns.db.banker) or "Not set up yet", 1, 1, 1)
	GameTooltip:Show()
end

--[[ Bagnon (optional) ]]--
-- A BankiAlt button in the row of buttons at the top of Bagnon's bag window (next to the character
-- selector, bag toggle, sort and search), built from Bagnon's own button template. It opens the virtual
-- bag docked to Bagnon's window. Falls back to a side tab if Bagnon's layout ever changes.

local function AddBagnonButton(frame)
	if not (frame.GetExtraButtons and frame.Layout) then return false end
	local ok, b = pcall(CreateFrame, "Button", "BankiAltBagnonButton", frame, "BagnonButtonTemplate")
	if not ok or not b.Icon then return false end

	b.Icon:SetTexture(ns.ICON)
	b:SetScript("OnClick", function() UI.Toggle("bagnon") end)
	b:SetScript("OnEnter", function(self) UI.ShowButtonTip(self, "ANCHOR_TOP") end)
	b:SetScript("OnLeave", GameTooltip_Hide)

	local GetExtraButtons = frame.GetExtraButtons
	frame.GetExtraButtons = function(self)
		local list = {}
		for _, button in ipairs(GetExtraButtons(self)) do tinsert(list, button) end
		if ns.db.ui.bagnon then tinsert(list, b) else b:Hide() end
		return list
	end
	frame:Layout()
	return true
end

local function AttachToBagnon()
	if UI.bagnon then return end
	local frame = Bagnon.Frames:Get("inventory")
	if not (frame and frame[0]) then return end -- Bagnon hasn't built its bag window yet

	UI.bagnon = frame
	if not AddBagnonButton(frame) then
		UI.bagnonTab = CreateSideTab("BankiAltBagnonTab", frame, "left", "bagnon")
		UI.bagnonTab:SetShown(ns.db.ui.bagnon)
	end
	frame:HookScript("OnHide", function()
		if UI.dock == "bagnon" then f:Hide() end
	end)
end

local function HookBagnon()
	local frames = Bagnon and Bagnon.Frames
	if not (frames and frames.Get and frames.Show) then return end -- not installed, or its layout changed
	hooksecurefunc(frames, "Show", function(_, id)
		if id == "inventory" then AttachToBagnon() end
	end)
	AttachToBagnon()
end

--[[ Grey out queued items in the bags, like the mailbox does with attached ones ]]--

hooksecurefunc("SetItemButtonDesaturated", function(button, desaturated)
	if desaturated or #ns.staged == 0 or not button.GetID then return end
	local bag = type(button.bag) == "number" and button.bag -- Bagnon
	if not bag and button.GetBagID then                     -- Blizzard bags
		local ok, id = pcall(button.GetBagID, button)
		bag = ok and type(id) == "number" and id
	end
	if bag and ns.IsStaged(bag, button:GetID()) then
		local icon = GetItemButtonIconTexture and GetItemButtonIconTexture(button) or button.icon or button.Icon
		if icon then icon:SetDesaturated(true) end
	end
end)

ns.On("BA_STAGED", function()
	local frames = Bagnon and Bagnon.Frames
	if frames and frames.Update then frames:Update() end -- redraw Bagnon's items
end)

--[[ Minimap button ]]--

local function CreateMinimapButton()
	local b = CreateFrame("Button", "BankiAltMinimapButton", Minimap)
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local overlay = b:CreateTexture(nil, "OVERLAY")
	overlay:SetSize(53, 53)
	overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	overlay:SetPoint("TOPLEFT")

	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetSize(20, 20)
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	bg:SetPoint("TOPLEFT", 7, -5)

	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetSize(17, 17)
	icon:SetTexture(ns.ICON)
	icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
	icon:SetPoint("TOPLEFT", 7, -6)

	local function Place()
		local a = math.rad(ns.db.ui.minimapAngle or 200)
		local r = Minimap:GetWidth() / 2 + 5
		b:ClearAllPoints()
		b:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
	end

	b:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local cx, cy = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			ns.db.ui.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
			Place()
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	b:SetScript("OnClick", function(_, button)
		if button == "RightButton" then ns.OpenSettings() else UI.Toggle() end
	end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText(ns.TAG)
		GameTooltip:AddLine("Left-click: open the virtual bag", 1, 1, 1)
		GameTooltip:AddLine("Right-click: settings", 1, 1, 1)
		GameTooltip:AddLine("Drag: move this button", 1, 1, 1)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)

	Place()
	UI.minimap = b
end

-- Show the icons the settings ask for.
local function ApplyOptions()
	local ui = ns.db.ui
	if UI.mailTab then UI.mailTab:SetShown(ui.mailTab) end
	if UI.minimap then UI.minimap:SetShown(ui.minimap) end
	if UI.bagnonTab then UI.bagnonTab:SetShown(ui.bagnon) end
	if UI.bagnon and not UI.bagnonTab then UI.bagnon:Layout() end -- re-reads GetExtraButtons
end

ns.On("BA_OPTIONS", ApplyOptions)

ns.On("PLAYER_LOGIN", function()
	UI.mailTab = CreateSideTab("BankiAltMailTab", MailFrame, "right", "mail")
	CreateMinimapButton()
	HookBagnon()
	ApplyOptions()
end)
