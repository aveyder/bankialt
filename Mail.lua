local ADDON, ns = ...

local MAX_SEND = ATTACHMENTS_MAX_SEND or 12

--[[ Outgoing list (main at mailbox) ]]--

-- BA_STAGED lets the bags grey out queued items.
local function StagedChanged()
	ns.Fire("BA_STAGED")
	ns.Changed()
end

-- Returns true when the slot is on the outgoing list (newly added or already there).
function ns.Stage(bag, slot)
	if ns.Mode() ~= "send" then return end
	local info = C_Container.GetContainerItemInfo(bag, slot)
	if not info or not info.itemID then return end
	if info.isBound then
		ns.Print(info.hyperlink, "is soulbound and can't be mailed.")
		return
	end
	for _, s in ipairs(ns.staged) do
		if s.bag == bag and s.slot == slot then return true end
	end
	tinsert(ns.staged, { bag = bag, slot = slot, itemID = info.itemID, link = info.hyperlink, count = info.stackCount or 1 })
	StagedChanged()
	return true
end

function ns.IsStaged(bag, slot)
	for _, s in ipairs(ns.staged) do
		if s.bag == bag and s.slot == slot then return true end
	end
	return false
end

function ns.Unstage(entry)
	tDeleteItem(ns.staged, entry)
	StagedChanged()
end

function ns.ClearStaged()
	wipe(ns.staged)
	StagedChanged()
end

--[[ Sending ]]--

local S = { active = false }

function ns.IsSending()
	return S.active
end

function ns.MailCount()
	return math.ceil(#ns.staged / MAX_SEND)
end

local function Finish(msg)
	S.active, S.pending = false, nil
	if S.timer then S.timer:Cancel() end
	if msg then ns.Print(msg) end
	ns.Changed()
end

local NextMail

local function DoSend()
	local items, n = {}, 0
	for i = 1, MAX_SEND do
		local itemID = ns.ItemIDFromLink(GetSendMailItemLink(i))
		if itemID then
			local _, _, _, count = GetSendMailItem(i)
			items[itemID] = (items[itemID] or 0) + (count or 1)
			n = n + 1
		end
	end
	if n == 0 then
		for _, s in ipairs(S.chunks[S.index]) do tDeleteItem(ns.staged, s) end
		return NextMail()
	end
	if GetMoney() < GetSendMailPrice() then
		ClearSendMail()
		return Finish("Not enough money for postage. The rest of the outgoing list was kept.")
	end

	local id = format("%x%04x", time(), math.random(0, 0xffff))
	S.pending = { id = id, items = items }
	S.timer = C_Timer.NewTimer(20, function()
		if S.pending then Finish("No answer from the server. Check your sent items before sending again.") end
	end)
	SendMail(ns.db.banker, format("[%s:%s] %d/%d", ns.TAG, id, S.index, #S.chunks), "")
end

local function WaitAttached(expected, tries)
	local attached = 0
	for i = 1, MAX_SEND do
		if GetSendMailItemLink(i) then attached = attached + 1 end
	end
	if attached >= expected or tries >= 30 then
		DoSend()
	else
		C_Timer.After(0.1, function() if S.active then WaitAttached(expected, tries + 1) end end)
	end
end

function NextMail()
	S.index = S.index + 1
	local chunk = S.chunks[S.index]
	if not chunk then
		Finish(format("Sent %d mail(s) to %s.", S.sent, ns.db.banker))
		return
	end
	if not ns.open.mail then
		return Finish("Mailbox closed, sending stopped.")
	end

	ClearSendMail()
	local attached = 0
	for _, s in ipairs(chunk) do
		local info = C_Container.GetContainerItemInfo(s.bag, s.slot)
		if info and info.itemID == s.itemID and not info.isLocked then
			attached = attached + 1
			ClearCursor()
			C_Container.PickupContainerItem(s.bag, s.slot)
			ClickSendMailItemButton(attached)
		end
	end
	ClearCursor()

	if attached == 0 then
		for _, s in ipairs(chunk) do tDeleteItem(ns.staged, s) end
		return NextMail()
	end
	WaitAttached(attached, 0)
end

function ns.Send()
	if ns.Mode() ~= "send" or S.active or #ns.staged == 0 then return end

	S.chunks = {}
	local chunk
	for _, s in ipairs(ns.staged) do
		if not chunk or #chunk == MAX_SEND then
			chunk = {}
			tinsert(S.chunks, chunk)
		end
		tinsert(chunk, s)
	end

	S.active, S.index, S.sent = true, 0, 0
	if MailFrameTab2 and not (SendMailFrame and SendMailFrame:IsShown()) then
		MailFrameTab2:Click()
	end
	ns.Changed()
	NextMail()
end

function ns.RecordSent(id, items)
	local d = ns.Data()
	d.mails[id] = { sender = ns.PlayerName(), sent = time(), items = items }
	for itemID, c in pairs(items) do
		d.tracked[itemID] = (d.tracked[itemID] or 0) + c
	end
end

ns.On("MAIL_SEND_SUCCESS", function()
	if not S.pending then return end -- not ours
	S.timer:Cancel()
	ns.RecordSent(S.pending.id, S.pending.items)
	S.pending = nil
	S.sent = S.sent + 1
	for _, s in ipairs(S.chunks[S.index]) do tDeleteItem(ns.staged, s) end
	StagedChanged()
	C_Timer.After(1, function() if S.active then NextMail() end end)
end)

ns.On("MAIL_FAILED", function()
	if not S.pending then return end
	ClearSendMail()
	Finish("Sending failed. The remaining items are still in the outgoing list.")
end)

ns.On("BA_MAIL_CLOSED", function()
	if S.active then Finish("Mailbox closed, sending stopped.") end
end)

-- Drop outgoing entries whose bag slot no longer holds the same item (moved, sold, ...).
ns.On("BAG_UPDATE_DELAYED", function()
	if S.active or #ns.staged == 0 then return end
	local removed = false
	for i = #ns.staged, 1, -1 do
		local s = ns.staged[i]
		local info = C_Container.GetContainerItemInfo(s.bag, s.slot)
		if not info or info.itemID ~= s.itemID then
			tremove(ns.staged, i)
			removed = true
		else
			s.count, s.link = info.stackCount or 1, info.hyperlink
		end
	end
	if removed then StagedChanged() else ns.Changed() end
end)

-- Right-click in the bags while the virtual bag is open on the mailbox's Send tab: add to the outgoing list
-- instead of attaching to the Blizzard send-mail form. The game attaches the item first; take it off again.
-- On the Inbox tab a right-click uses the item (equips, eats...), so it is left alone there.
local undo, undoTimer = 0, nil

local function UndoAttachments()
	if undo <= 0 or S.active then return end
	for i = 1, MAX_SEND do
		local link = GetSendMailItemLink(i)
		if link then
			for _, s in ipairs(ns.staged) do
				if s.link == link then
					ClickSendMailItemButton(i, true)
					undo = undo - 1
					break
				end
			end
		end
		if undo <= 0 then return end
	end
end

hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
	if not ns.db or ns.Mode() ~= "send" or S.active or not ns.UI.IsShown() then return end
	if not (SendMailFrame and SendMailFrame:IsShown()) then return end
	if ns.Stage(bag, slot) then
		undo = undo + 1
		if undoTimer then undoTimer:Cancel() end
		undoTimer = C_Timer.NewTimer(2, function() undo = 0 end)
		C_Timer.After(0, UndoAttachments)
	end
end)

ns.On("MAIL_SEND_INFO_UPDATE", UndoAttachments)

--[[ Collecting (banker at mailbox) ]]--

local C = { active = false }

local function IsCollectable(i)
	local _, _, sender, subject, _, cod, _, hasItem = GetInboxHeaderInfo(i)
	local id = ns.ParseTag(subject)
	return hasItem and (cod or 0) == 0 and sender and ns.IsMainName(sender) and id
end

function ns.CollectableCount()
	local n = 0
	for i = 1, GetInboxNumItems() do
		if IsCollectable(i) then n = n + 1 end
	end
	return n
end

function ns.IsCollecting()
	return C.active
end

local function StopCollect(msg)
	C.active = false
	if C.timer then C.timer:Cancel() end
	if msg then ns.Print(msg) end
	ns.Changed()
end

local function CollectStep()
	if not C.active then return end
	if not ns.open.mail then return StopCollect() end

	for i = 1, GetInboxNumItems() do
		local id = IsCollectable(i)
		if id then
			C.tries = (C.last == id) and C.tries + 1 or 0
			if C.tries > 3 then
				return StopCollect("Could not take the items. Are your bags full?")
			end
			C.last = id
			AutoLootMailItem(i)
			if C.timer then C.timer:Cancel() end
			C.timer = C_Timer.NewTimer(2, CollectStep) -- fallback if no inbox update arrives
			return
		end
	end
	StopCollect("Collected everything from your main characters.")
end

function ns.Collect()
	if ns.Mode() ~= "collect" or C.active then return end
	C.active, C.last, C.tries = true, nil, 0
	ns.Changed()
	CollectStep()
end

ns.On("MAIL_INBOX_UPDATE", function()
	if not C.active then
		if ns.open.mail then ns.Changed() end
		return
	end
	if C.timer then C.timer:Cancel() end
	C.timer = C_Timer.NewTimer(0.3, CollectStep)
end)

ns.On("UI_ERROR_MESSAGE", function(_, msg)
	if C.active and msg == ERR_INV_FULL then
		StopCollect("Your bags are full.")
	end
end)
