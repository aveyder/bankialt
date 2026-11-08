local ADDON, ns = ...

-- Keeps the virtual bag up to date with explicit rules. An item only leaves the virtual bag when we
-- know why:
--   sold to a vendor / destroyed / mailed to someone who isn't a main / AH sale notice  -> removed
--   mailed back to a main                       -> "sent back" until that main takes the mail, then removed
--   posted on the AH and the server confirmed   -> "on the AH"
--   sent back by the AH (expired or cancelled)  -> "returned" while it waits in the banker's mailbox
--   left the banker's bags any other way        -> "?" (unknown), until removed by hand

local GetItemInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
local MAX_SEND = ATTACHMENTS_MAX_SEND or 12
local destroyedAt = -100 -- GetTime() of the last item deletion
local AUCTION_HOURS = { 12, 24, 48 } -- by duration index

local BankBags = {}
do
	if BANK_CONTAINER then tinsert(BankBags, BANK_CONTAINER) end
	local first = (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS) + 1
	local n = NUM_BANKBAGSLOTS or (Constants.InventoryConstants and Constants.InventoryConstants.NumCharacterBankSlots) or 0
	for bag = first, first + n - 1 do tinsert(BankBags, bag) end
	if REAGENTBANK_CONTAINER then tinsert(BankBags, REAGENTBANK_CONTAINER) end
end

local function Count(bags)
	local t = {}
	for _, bag in ipairs(bags) do
		for slot = 1, C_Container.GetContainerNumSlots(bag) do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID then
				t[info.itemID] = (t[info.itemID] or 0) + (info.stackCount or 1)
			end
		end
	end
	return t
end

local function Remove(d, itemID, n)
	local left = (d.tracked[itemID] or 0) - n
	d.tracked[itemID] = left > 0 and left or nil
end

local function ReducePosted(s, itemID, n)
	local i = 1
	while n > 0 and i <= #s.posted do
		local p = s.posted[i]
		if p.itemID == itemID then
			local used = math.min(n, p.qty)
			p.qty, n = p.qty - used, n - used
			if p.qty == 0 then tremove(s.posted, i) else i = i + 1 end
		else
			i = i + 1
		end
	end
end

-- The main a mail recipient refers to ("Kinsinar Rybkin", or just "Kinsinar").
local function MainFor(name)
	name = ns.NormName(name)
	if not name then return nil end
	for _, main in ipairs(ns.db.mains) do
		if ns.SameName(main, name) or (not name:find(" ") and ns.SameName(main:match("^%S+"), name)) then
			return main
		end
	end
end

local function ReadAttachments(i)
	local items = {}
	for j = 1, ATTACHMENTS_MAX_RECEIVE do
		local itemID = ns.ItemIDFromLink(GetInboxItemLink(i, j))
		if itemID then
			local _, _, _, count = GetInboxItem(i, j)
			items[itemID] = (items[itemID] or 0) + (count or 1)
		end
	end
	return items
end

--[[ Banker: bags and bank ]]--

local function ScanOwned()
	local d = ns.Data()
	local s = d.snap
	local bags = Count(ns.InventoryBags)
	local bank = ns.open.bank and Count(BankBags) or s.bank -- the bank can only be read while it's open

	for itemID in pairs(d.tracked) do
		local gone = (s.bags[itemID] or 0) + (s.bank[itemID] or 0) - (bags[itemID] or 0) - (bank[itemID] or 0)
		if gone > 0 then
			if ns.open.merchant or GetTime() - destroyedAt < 3 then
				Remove(d, itemID, gone) -- sold to a vendor or destroyed
			end
			-- posted on the AH / mailed: the hooks below take care of it; anything else becomes "?"
		end
	end

	s.bags = bags
	if ns.open.bank then
		s.bank = bank
		s.bankTime = time()
	end
	for i = #s.posted, 1, -1 do -- past the longest auction time without news: "?"
		if s.posted[i].expires < time() then tremove(s.posted, i) end
	end
	s.time = time()
end

local function ScanMoney()
	local s = ns.Data().snap
	s.money = GetMoney()
	s.moneyTime = time()
	s.time = time()
end

--[[ Banker: auction house ]]--
-- Posts are seen through C_AuctionHouse.PostItem/PostCommodity (used by the Blizzard UI and Auctionator),
-- which also gives the price. They count as "on the AH" once the server confirms them.

local pendingPosts = {}

local function NotePost(item, duration, quantity, unitPrice)
	if not (ns.db and ns.db.banker and ns.IsBanker()) then return end
	local itemID = item and C_Item.GetItemID and C_Item.GetItemID(item)
	local n = itemID and math.min(quantity or 1, ns.Data().tracked[itemID] or 0)
	if n and n > 0 then
		tinsert(pendingPosts, { itemID = itemID, qty = n, unit = unitPrice or 0,
			hours = AUCTION_HOURS[duration] or 48, at = GetTime() })
	end
end

if C_AuctionHouse then
	-- prices are per item: Auctionator posts (bid or) buyout as a unit price for both
	hooksecurefunc(C_AuctionHouse, "PostItem", function(item, duration, quantity, bid, buyout)
		NotePost(item, duration, quantity, buyout or bid)
	end)
	hooksecurefunc(C_AuctionHouse, "PostCommodity", function(item, duration, quantity, unitPrice)
		NotePost(item, duration, quantity, unitPrice)
	end)
end

-- The server confirmed an auction: the oldest post still waiting becomes "on the AH".
local function ConfirmPost()
	while pendingPosts[1] and GetTime() - pendingPosts[1].at > 60 do
		tremove(pendingPosts, 1) -- never answered: its items will show as "?"
	end
	local p = tremove(pendingPosts, 1)
	if p then
		tinsert(ns.Data().snap.posted, { itemID = p.itemID, qty = p.qty, unit = p.unit,
			expires = time() + p.hours * 3600, confirmed = true })
	end
end

--[[ Banker: mailbox ]]--

local function SubjectPattern(fmt)
	if type(fmt) ~= "string" then return nil end
	return "^" .. fmt:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0"):gsub("%%s", ".+") .. "$"
end

local RETURN_SUBJECTS = { SubjectPattern(AUCTION_EXPIRED_MAIL_SUBJECT), SubjectPattern(AUCTION_REMOVED_MAIL_SUBJECT) }

local function IsAuctionReturn(subject)
	for _, pattern in ipairs(RETURN_SUBJECTS) do
		if subject and subject:match(pattern) then return true end
	end
end

local function TrackedByName(d, name)
	for itemID in pairs(d.tracked) do
		if GetItemInfo(itemID) == name then return itemID end
	end
end

local function ScanInbox()
	local d = ns.Data()
	local s = d.snap
	local num, total = GetInboxNumItems()
	local whole = num >= (total or num) -- the client shows at most 50 mails
	local present, returned, notices = {}, {}, {}
	local saleMoney = 0 -- AH sale gold waiting in the mailbox

	for i = 1, num do
		local _, _, sender, subject, money, _, _, hasItem = GetInboxHeaderInfo(i)
		local id = ns.ParseTag(subject)
		local mail = id and sender and ns.IsMainName(sender) and d.mails[id]
		local items = hasItem and ReadAttachments(i) or {}

		if mail then
			present[id] = true
			if next(items) then
				mail.seen = mail.seen or time()
				mail.items = items -- reflects partially taken mails
			else
				d.mails[id] = nil -- emptied: the items are in the banker's bags now
			end
		elseif IsAuctionReturn(subject) then
			for itemID, c in pairs(items) do
				returned[itemID] = (returned[itemID] or 0) + c
				local key = format("ret|%s|%d|%d", subject, itemID, c)
				notices[key] = notices[key] or { n = 0, itemID = itemID, count = c }
				notices[key].n = notices[key].n + 1
			end
		else
			local invoiceType, itemName, _, bid, buyout, deposit, consignment, _, _, _, count = GetInboxInvoiceInfo(i)
			if itemName and (invoiceType == "seller" or invoiceType == "seller_temp_invoice") then
				-- a delayed ("temp") notice carries no gold yet: count what it will pay
				saleMoney = saleMoney + ((money or 0) > 0 and money
					or math.max(0, (bid or 0) + (deposit or 0) - (consignment or 0)))
				local key = format("sold|%s|%d|%d|%d", itemName, count or 1, bid or 0, buyout or 0)
				notices[key] = notices[key] or { n = 0, name = itemName, count = count or 1, sold = true }
				notices[key].n = notices[key].n + 1
			end
		end
	end

	if whole then
		-- a seen mail from a main that's no longer here was taken (or returned/deleted)
		for id, mail in pairs(d.mails) do
			if mail.seen and not present[id] then d.mails[id] = nil end
		end
		-- AH notices that are new since last time: a sale removes the item, a return ends its auction
		for key, notice in pairs(notices) do
			local new = notice.n - (s.inboxKeys[key] or 0)
			if new > 0 then
				local itemID = notice.itemID or TrackedByName(d, notice.name)
				if itemID then
					ReducePosted(s, itemID, notice.count * new)
					if notice.sold then Remove(d, itemID, notice.count * new) end
				else
					notice.n = notice.n - new -- item info not loaded yet: count it on a later scan
				end
			end
		end
		s.inboxKeys = {}
		for key, notice in pairs(notices) do s.inboxKeys[key] = notice.n end
	end

	s.returned = returned
	s.saleMoney = saleMoney
	s.mailTime = time()
	s.time = time()
end

-- Mail the banker sends: back to a main -> "sent back"; to anyone else -> gone.
local outgoing

hooksecurefunc("SendMail", function(recipient)
	outgoing = nil
	if not (ns.db and ns.db.banker and ns.IsBanker()) then return end
	local items = {}
	for i = 1, MAX_SEND do
		local itemID = ns.ItemIDFromLink(GetSendMailItemLink(i))
		if itemID then
			local _, _, _, count = GetSendMailItem(i)
			items[itemID] = (items[itemID] or 0) + (count or 1)
		end
	end
	if next(items) then outgoing = { to = recipient, items = items } end
end)

local function OnMailSent()
	if not outgoing then return end
	local d = ns.Data()
	local main = MainFor(outgoing.to)
	local back = {}
	for itemID, c in pairs(outgoing.items) do
		local n = math.min(c, d.tracked[itemID] or 0)
		if n > 0 then
			if main then back[itemID] = n else Remove(d, itemID, n) end
		end
	end
	if next(back) then
		d.returns[format("%x%04x", time(), math.random(0, 0xffff))] = { to = main, items = back, sent = time() }
	end
	outgoing = nil
end

--[[ Main: picking up what the banker sent back ]]--

local function Contains(items, need)
	for itemID, c in pairs(need) do
		if (items[itemID] or 0) < c then return false end
	end
	return true
end

local function ScanReturns()
	local d = ns.Data()
	local me = ns.PlayerName()
	local num, total = GetInboxNumItems()
	local fromBanker = {}
	for i = 1, num do
		local _, _, sender, _, _, _, _, hasItem = GetInboxHeaderInfo(i)
		if hasItem and ns.SameName(sender, ns.db.banker) then tinsert(fromBanker, ReadAttachments(i)) end
	end

	for id, r in pairs(d.returns) do
		if ns.SameName(r.to, me) then
			local found
			for k, items in ipairs(fromBanker) do
				if Contains(items, r.items) then found = k break end
			end
			if found then
				r.seen = true
				tremove(fromBanker, found)
			elseif r.seen and num >= (total or num) then -- taken by this main: no longer in the virtual bag
				for itemID, c in pairs(r.items) do Remove(d, itemID, c) end
				d.returns[id] = nil
			end
		end
	end
end

--[[ Events ]]--

local function OnBanker(fn)
	return function(...)
		if ns.db and ns.db.banker and ns.IsBanker() then
			fn(...)
			ns.Changed()
		end
	end
end

ns.On("PLAYER_ENTERING_WORLD", OnBanker(function()
	ScanOwned()
	ScanMoney()
end))

ns.On("PLAYER_MONEY", OnBanker(ScanMoney))
ns.On("BAG_UPDATE_DELAYED", OnBanker(ScanOwned))
ns.On("PLAYERBANKSLOTS_CHANGED", OnBanker(ScanOwned))

ns.On("BA_BANK_OPENED", OnBanker(function()
	ScanOwned()
	C_Timer.After(1, OnBanker(ScanOwned)) -- in case bank data arrives late
end))

ns.On("MAIL_INBOX_UPDATE", function()
	if not (ns.db and ns.db.banker and ns.open.mail) then return end
	if ns.IsBanker() then
		ScanInbox()
	elseif ns.IsMain() then
		ScanReturns()
	end
	ns.Changed()
end)

ns.On("MAIL_SEND_SUCCESS", OnBanker(OnMailSent))
ns.On("MAIL_FAILED", function() outgoing = nil end)

-- A sale notice may have waited for its item's info: scan the inbox again once it arrives.
ns.On("GET_ITEM_INFO_RECEIVED", function()
	if ns.db and ns.db.banker and ns.open.mail and ns.IsBanker() then
		ScanInbox()
		ns.Changed()
	end
end)

hooksecurefunc("DeleteCursorItem", function() destroyedAt = GetTime() end)

ns.On("AUCTION_HOUSE_AUCTION_CREATED", OnBanker(ConfirmPost))
ns.On("CHAT_MSG_SYSTEM", OnBanker(function(msg)
	if msg == ERR_AUCTION_STARTED then ConfirmPost() end
end))
