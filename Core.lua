local ADDON, ns = ...

ns.TAG = "BankiAlt"
ns.ICON = "Interface\\Icons\\INV_Box_02"
ns.open = { mail = false, bank = false, ah = false, merchant = false }
ns.staged = {}

--[[ Events ]]--
-- Game events, plus our own "BA_*" events fired with ns.Fire.

local driver = CreateFrame("Frame")
local handlers = {}

function ns.On(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		if not event:match("^BA_") then
			pcall(driver.RegisterEvent, driver, event) -- tolerate events this client doesn't know
		end
	end
	tinsert(handlers[event], fn)
end

function ns.Fire(event, ...)
	for _, fn in ipairs(handlers[event] or {}) do
		fn(...)
	end
end

driver:SetScript("OnEvent", function(_, event, ...)
	ns.Fire(event, ...)
end)

-- Batched "something changed, redraw" notifications.
local listeners, queued = {}, false

function ns.Listen(fn)
	tinsert(listeners, fn)
end

function ns.Changed()
	if queued then return end
	queued = true
	C_Timer.After(0.1, function()
		queued = false
		for _, fn in ipairs(listeners) do fn() end
	end)
end

function ns.Print(...)
	print("|cff33ff99" .. ns.TAG .. "|r:", ...)
end

--[[ Names ]]--
-- WoW Forever characters are "Name Surname" with no realm. Compare names trimmed and case-insensitively.

function ns.NormName(name)
	if type(name) ~= "string" then return nil end
	name = strtrim(name):gsub("%s+", " ")
	return name ~= "" and name or nil
end

function ns.NameKey(name)
	name = ns.NormName(name)
	return name and name:lower()
end

function ns.SameName(a, b)
	local ka = ns.NameKey(a)
	return ka ~= nil and ka == ns.NameKey(b)
end

function ns.PlayerName()
	local name, surname = UnitNameUnmodified("player")
	if surname and surname ~= "" then
		return name .. " " .. surname
	end
	return name
end

--[[ Roles ]]--

function ns.IsBanker()
	return ns.SameName(ns.PlayerName(), ns.db.banker)
end

function ns.IsMainName(name)
	for _, main in ipairs(ns.db.mains) do
		if ns.SameName(main, name) then return true end
	end
	return false
end

function ns.IsMain()
	return not ns.IsBanker() and ns.IsMainName(ns.PlayerName())
end

-- "setup" | "send" (main at mailbox) | "collect" (banker at mailbox) | "view"
function ns.Mode()
	if not ns.db.banker or #ns.db.mains == 0 then return "setup" end
	if ns.open.mail then
		if ns.IsBanker() then return "collect" end
		if ns.IsMain() then return "send" end
	end
	return "view"
end

--[[ Data ]]--
-- Everything is kept per banker name, so changing the banker never mixes two ledgers.
--   tracked[itemID] = count                 items the mains sent that are still in the virtual bag
--   mails[id]       = {sender, sent, seen, items = {[itemID] = count}}   tagged mails not yet emptied by the banker
--   snap            = last known banker state: bags, bank, money, posted, returned, *Time

function ns.Data()
	local key = ns.NameKey(ns.db.banker)
	if not key then return nil end
	local d = ns.db.data[key]
	if not d then
		d = { tracked = {}, mails = {}, snap = { bags = {}, bank = {} } }
		ns.db.data[key] = d
	end
	-- returns:   items the banker mailed back to a main: [id] = {to, items, sent, seen}
	-- posted:    items that left the banker's bags at the AH: {itemID, qty, expires, confirmed}
	-- returned:  items the AH sent back (expired/cancelled) waiting in the banker's mailbox
	-- inboxKeys: AH notices seen last time, so a notice that stays in the mailbox counts only once
	d.returns = d.returns or {}
	d.snap.posted = d.snap.posted or {}
	d.snap.returned = d.snap.returned or {}
	d.snap.inboxKeys = d.snap.inboxKeys or {}
	return d
end

function ns.ParseTag(subject)
	return subject and subject:match("%[" .. ns.TAG .. ":(%w+)%]")
end

function ns.ItemIDFromLink(link)
	return link and tonumber(link:match("item:(%d+)"))
end

-- Manual cleanup: stop tracking an item entirely.
function ns.Forget(itemID)
	local d = ns.Data()
	if not d then return end
	d.tracked[itemID] = nil
	for _, list in ipairs({ d.mails, d.returns }) do
		for id, mail in pairs(list) do
			mail.items[itemID] = nil
			if not next(mail.items) then list[id] = nil end
		end
	end
	for i = #d.snap.posted, 1, -1 do
		if d.snap.posted[i].itemID == itemID then tremove(d.snap.posted, i) end
	end
	ns.Changed()
end

-- Gold the banker can still expect: running auctions (after the AH's cut) plus sale gold in its mailbox.
-- Drops as items come back from the AH or the gold is taken (it's then part of the banker's money).
local AH_CUT = 0.05

function ns.ExpectedIncome(d)
	local s = d.snap
	local total = s.saleMoney or 0
	for _, p in ipairs(s.posted) do
		if p.confirmed and p.unit and p.expires > time() then
			total = total + p.unit * p.qty * (1 - AH_CUT)
		end
	end
	return math.floor(total)
end

-- Display order of the statuses (tooltip lines).
ns.STATUSES = { "flight", "mailbox", "returned", "auction", "toMain", "owned", "unknown" }

-- Splits an item's tracked count into where it is believed to be.
function ns.Breakdown(d, itemID)
	local total = d.tracked[itemID] or 0
	local r, rest = { total = total }, total

	local function take(key, n)
		local t = math.min(rest, n or 0)
		if t > 0 then
			r[key] = (r[key] or 0) + t
			rest = rest - t
		end
	end

	local flight, mailbox, toMain, auction = 0, 0, 0, 0
	for _, mail in pairs(d.mails) do
		local c = mail.items[itemID]
		if c then
			if mail.seen then mailbox = mailbox + c else flight = flight + c end
		end
	end
	for _, mail in pairs(d.returns) do
		toMain = toMain + (mail.items[itemID] or 0)
	end

	local s = d.snap
	for _, p in ipairs(s.posted) do
		if p.confirmed and p.itemID == itemID and p.expires > time() then auction = auction + p.qty end
	end

	take("flight", flight)
	take("mailbox", mailbox)
	take("toMain", toMain)
	take("returned", s.returned[itemID])
	take("auction", auction)
	take("owned", (s.bags[itemID] or 0) + (s.bank[itemID] or 0))
	take("unknown", rest) -- left the banker's bags without a known reason
	return r
end

--[[ Bags ]]--

ns.InventoryBags = {}
for bag = BACKPACK_CONTAINER, NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS do
	tinsert(ns.InventoryBags, bag)
end

-- The bag slot an item on the cursor was picked up from (that slot is locked while the item is on the cursor).
function ns.FindLockedSlot(itemID)
	for _, bag in ipairs(ns.InventoryBags) do
		for slot = 1, C_Container.GetContainerNumSlots(bag) do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.isLocked and info.itemID == itemID then
				return bag, slot
			end
		end
	end
end

--[[ Init ]]--

ns.On("ADDON_LOADED", function(name)
	if name ~= ADDON then return end
	BankiAltDB = BankiAltDB or {}
	local db = BankiAltDB
	db.mains = db.mains or {}
	db.data = db.data or {}
	db.ui = db.ui or { minimapAngle = 200 }

	-- Display options. Bagnon (loaded before us, see OptionalDeps) is the preferred place for the icon;
	-- without it the minimap button is shown instead.
	local ui = db.ui
	ns.hasBagnon = Bagnon and Bagnon.Frames and true or false
	if ui.autoOpen == nil then ui.autoOpen = true end
	if ui.mailTab == nil then ui.mailTab = false end
	if ui.bagnon == nil then ui.bagnon = true end
	if ui.minimap == nil then ui.minimap = not ns.hasBagnon end
	ui.hideMinimap = nil -- replaced by ui.minimap
	ns.db = db
end)

--[[ Mailbox / bank / auction house open state ]]--
-- This client reports these windows through PLAYER_INTERACTION_MANAGER_FRAME_SHOW/HIDE; the older
-- MAIL_CLOSED etc. can't be relied on. Listen to both and fire BA_<KIND>_OPENED / BA_<KIND>_CLOSED once per change.

local function SetOpen(kind, state)
	if ns.open[kind] == state then return end
	ns.open[kind] = state
	if kind == "mail" and not state then
		wipe(ns.staged)
		ns.Fire("BA_STAGED")
	end
	ns.Fire(format("BA_%s_%s", kind:upper(), state and "OPENED" or "CLOSED"))
	ns.Changed()
end

local INTERACTION = {}
local types = Enum.PlayerInteractionType
if types then
	if types.MailInfo then INTERACTION[types.MailInfo] = "mail" end
	if types.Banker then INTERACTION[types.Banker] = "bank" end
	if types.Auctioneer then INTERACTION[types.Auctioneer] = "ah" end
	if types.Merchant then INTERACTION[types.Merchant] = "merchant" end
end

ns.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(t) if INTERACTION[t] then SetOpen(INTERACTION[t], true) end end)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(t) if INTERACTION[t] then SetOpen(INTERACTION[t], false) end end)
ns.On("MAIL_SHOW", function() SetOpen("mail", true) end)
ns.On("MAIL_CLOSED", function() SetOpen("mail", false) end)
ns.On("BANKFRAME_OPENED", function() SetOpen("bank", true) end)
ns.On("BANKFRAME_CLOSED", function() SetOpen("bank", false) end)
ns.On("AUCTION_HOUSE_SHOW", function() SetOpen("ah", true) end)
ns.On("AUCTION_HOUSE_CLOSED", function() SetOpen("ah", false) end)
ns.On("MERCHANT_SHOW", function() SetOpen("merchant", true) end)
ns.On("MERCHANT_CLOSED", function() SetOpen("merchant", false) end)

ns.On("PLAYER_LOGIN", function()
	-- last line of defence: the mailbox can't be open while its window is hidden
	MailFrame:HookScript("OnHide", function() SetOpen("mail", false) end)
end)

ns.On("GET_ITEM_INFO_RECEIVED", ns.Changed)
