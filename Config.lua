local ADDON, ns = ...

--[[ Changing the setup ]]--

local function SetBanker(name)
	name = ns.NormName(name)
	-- drop the previous banker's data if nothing was ever recorded for it (e.g. a mistyped name)
	local old = ns.NameKey(ns.db.banker)
	local d = old and ns.db.data[old]
	if d and old ~= ns.NameKey(name) and not next(d.tracked) and not next(d.mails) and not d.snap.time then
		ns.db.data[old] = nil
	end
	ns.db.banker = name
	if name then
		for i = #ns.db.mains, 1, -1 do
			if ns.SameName(ns.db.mains[i], name) then tremove(ns.db.mains, i) end
		end
	end
	ns.Changed()
end

local function AddMain(name)
	name = ns.NormName(name)
	if not name then return end
	if ns.SameName(name, ns.db.banker) then
		ns.Print("The banker can't also be a main character.")
		return
	end
	if not ns.IsMainName(name) then
		tinsert(ns.db.mains, name)
		ns.Changed()
	end
end

local function RemoveMain(name)
	for i = #ns.db.mains, 1, -1 do
		if ns.SameName(ns.db.mains[i], name) then tremove(ns.db.mains, i) end
	end
	ns.Changed()
end

--[[ Settings panel ]]--

local panel = CreateFrame("Frame")
panel.name = ns.TAG

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText(ns.TAG)

local intro = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
intro:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
intro:SetWidth(560)
intro:SetJustifyH("LEFT")
intro:SetText("Enter names exactly as they appear in the mail \"To:\" field, for example \"Bankinar Rybkin\". "
	.. "The banker only counts mail sent by BankiAlt from the main characters listed below and ignores all other mail. "
	.. "This data is stored on your computer and shared by all characters on this account.")

local function Label(text, anchor, y)
	local l = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	l:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y)
	l:SetText(text)
	return l
end

local function NameBox(anchor)
	local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	box:SetSize(220, 20)
	box:SetAutoFocus(false)
	box:SetScript("OnEditFocusGained", box.HighlightText) -- typing replaces the name instead of appending to it
	box:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 6, -6)
	box:SetScript("OnEscapePressed", box.ClearFocus)
	return box
end

local function Button(text, width, anchor)
	local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
	b:SetText(text)
	return b
end

-- Display: where the BankiAlt icon is shown, and whether the window opens with the mailbox
local displayLabel = Label("Display", intro, -20)
local checks = {}

local function Check(key, text)
	local c = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	local anchor = checks[#checks] or displayLabel
	c:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", #checks == 0 and -2 or 0, #checks == 0 and -4 or 4)
	c.label = c.Text or c.text
	if c.label then c.label:SetText(text) end
	c.key = key
	c:SetScript("OnClick", function(self)
		ns.db.ui[key] = self:GetChecked() and true or false
		ns.Fire("BA_OPTIONS")
	end)
	tinsert(checks, c)
	return c
end

Check("autoOpen", "Open the virtual bag when the mailbox opens")
Check("mailTab", "Show the BankiAlt tab on the mailbox")
local bagnonCheck = Check("bagnon", "Show the BankiAlt button in Bagnon's bag window")
Check("minimap", "Show the minimap button")

-- Banker
local bankerLabel = Label("Banker character", checks[#checks], -12)
bankerLabel:SetPoint("TOPLEFT", checks[#checks], "BOTTOMLEFT", 2, -12)
local bankerBox = NameBox(bankerLabel)
local bankerSave = Button(SAVE or "Save", 70, bankerBox)
local bankerMe = Button("Use this character", 140, bankerSave)

local function SaveBanker()
	SetBanker(bankerBox:GetText())
	bankerBox:ClearFocus()
end
bankerBox:SetScript("OnEnterPressed", SaveBanker)
bankerSave:SetScript("OnClick", SaveBanker)
bankerMe:SetScript("OnClick", function() SetBanker(ns.PlayerName()) end)

-- Mains
local mainsLabel = Label("Main characters", bankerBox, -20)
mainsLabel:SetPoint("TOPLEFT", bankerBox, "BOTTOMLEFT", -6, -20)
local mainBox = NameBox(mainsLabel)
local mainAdd = Button(ADD or "Add", 70, mainBox)
local mainMe = Button("Add this character", 140, mainAdd)

local function SaveMain()
	AddMain(mainBox:GetText())
	mainBox:SetText("")
	mainBox:ClearFocus()
end
mainBox:SetScript("OnEnterPressed", SaveMain)
mainAdd:SetScript("OnClick", SaveMain)
mainMe:SetScript("OnClick", function() AddMain(ns.PlayerName()) end)

local rows = {}
local function GetRow(i)
	if rows[i] then return rows[i] end
	local row = CreateFrame("Frame", nil, panel)
	row:SetSize(360, 22)
	row:SetPoint("TOPLEFT", mainBox, "BOTTOMLEFT", -6, -8 - (i - 1) * 24)
	row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	row.text:SetPoint("LEFT", 4, 0)
	row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.remove:SetSize(80, 20)
	row.remove:SetPoint("LEFT", 240, 0)
	row.remove:SetText(REMOVE or "Remove")
	row.remove:SetScript("OnClick", function() RemoveMain(row.name) end)
	rows[i] = row
	return row
end

local function RefreshPanel()
	if not panel:IsVisible() or not ns.db then return end
	if not bankerBox:HasFocus() then
		bankerBox:SetText(ns.db.banker or "")
		bankerBox:SetCursorPosition(0) -- otherwise the text can end up scrolled out of view and look empty
	end
	for i, name in ipairs(ns.db.mains) do
		local row = GetRow(i)
		row.name = name
		row.text:SetText(name)
		row:Show()
	end
	for i = #ns.db.mains + 1, #rows do rows[i]:Hide() end

	for _, c in ipairs(checks) do
		c:SetChecked(ns.db.ui[c.key])
	end
	bagnonCheck:SetEnabled(ns.hasBagnon)
	if bagnonCheck.label then
		bagnonCheck.label:SetFontObject(ns.hasBagnon and GameFontHighlight or GameFontDisable)
		bagnonCheck.label:SetText("Show the BankiAlt button in Bagnon's bag window"
			.. (ns.hasBagnon and "" or " (Bagnon is not installed)"))
	end
end

panel:SetScript("OnShow", RefreshPanel)
ns.Listen(RefreshPanel)

if Settings and Settings.RegisterCanvasLayoutCategory then
	local category = Settings.RegisterCanvasLayoutCategory(panel, ns.TAG)
	Settings.RegisterAddOnCategory(category)
	function ns.OpenSettings() Settings.OpenToCategory(category:GetID()) end
else
	InterfaceOptions_AddCategory(panel)
	function ns.OpenSettings() InterfaceOptionsFrame_OpenToCategory(panel) end
end

--[[ Slash commands ]]--

StaticPopupDialogs["BANKIALT_RESET"] = {
	text = "Forget everything " .. ns.TAG .. " has recorded for %s?",
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		ns.db.data[ns.NameKey(ns.db.banker)] = nil
		ns.Changed()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

local function Debug()
	ns.Print("You are:", "\"" .. ns.PlayerName() .. "\"", ns.IsBanker() and "(banker)" or ns.IsMain() and "(main)" or "")
	ns.Print("Banker:", ns.db.banker and ("\"" .. ns.db.banker .. "\"") or "not set")
	ns.Print("Mains:", #ns.db.mains > 0 and table.concat(ns.db.mains, ", ") or "none")
	ns.Print(format("Open: mailbox %s, bank %s, AH %s, merchant %s",
		tostring(ns.open.mail), tostring(ns.open.bank), tostring(ns.open.ah), tostring(ns.open.merchant)))
	local d = ns.Data()
	if d then
		for _, p in ipairs(d.snap.posted) do
			print(format("  posted: item %d x%d, %s, ends by %s", p.itemID, p.qty,
				p.confirmed and "confirmed" or "NOT confirmed", date("%d.%m %H:%M", p.expires)))
		end
		for _, r in pairs(d.returns) do
			for itemID, c in pairs(r.items) do
				print(format("  sent back to %s: item %d x%d%s", r.to, itemID, c, r.seen and " (in their mailbox)" or ""))
			end
		end
	end
	if ns.open.mail then
		local num, total = GetInboxNumItems()
		ns.Print(format("Inbox: %d shown of %d", num, total or num))
		for i = 1, num do
			local _, _, sender, subject, _, _, _, hasItem = GetInboxHeaderInfo(i)
			print(format("  %d. from \"%s\": %s (%d items)%s", i, tostring(sender), tostring(subject), hasItem or 0,
				sender and ns.IsMainName(sender) and " [main]" or ""))
		end
	end
end

SLASH_BANKIALT1 = "/bankialt"
SLASH_BANKIALT2 = "/balt"
SlashCmdList.BANKIALT = function(msg)
	local cmd = strtrim(msg or ""):lower()
	if cmd == "" then
		ns.UI.Toggle()
	elseif cmd == "config" or cmd == "settings" then
		ns.OpenSettings()
	elseif cmd == "debug" then
		Debug()
	elseif cmd == "reset" then
		if ns.db.banker then StaticPopup_Show("BANKIALT_RESET", ns.db.banker) end
	else
		ns.Print("/balt: open the virtual bag; /balt config: settings; /balt debug: show names and inbox senders; /balt reset: forget everything tracked for the banker")
	end
end
