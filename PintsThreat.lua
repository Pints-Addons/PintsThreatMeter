-- Pint's Threat Meter: a threat meter. Everyone in your group on your target's threat list, with you always shown,
-- the threat needed to pull aggro, threat per second and time to pull, warnings, healer and tank modes.  /pth
local ADDON = ...
-- Compatibility: WoW Forever runs on the modern game client, where these older functions moved or were renamed.
local IsAddOnLoaded = IsAddOnLoaded or (C_AddOns and C_AddOns.IsAddOnLoaded)

local PTH = {}
_G.PintsThreat = PTH

local DEFAULTS = {
	bars = 10, width = 220, barHeight = 16, font = 11, scale = 1, alpha = 0.85, locked = false, pos = nil,
	scaled = true,            -- 100% = you'd pull aggro; off = raw (110% melee / 130% ranged pulls)
	showValue = true, showPct = true, showTPS = false, pullBar = true, timeToPull = true,
	classColors = true, meColor = { 0.9, 0.2, 0.2 }, tankColor = { 0.55, 0.55, 0.55 }, otherColor = { 0.3, 0.6, 1 },
	rangedStyle = "fade",     -- out of melee: "none", "fade", "darken"
	healerMode = true,        -- targeting a friend shows their target's threat
	hide = "never",           -- "never", "nocombat", "solo", "nocombatsolo"
	-- warnings
	warn = true, warnPct = 85, warnSound = true, warnFlash = true, warnCooldown = 4, warnMin = 0,
	tankMode = "auto",        -- "auto" (stance/form/Righteous Fury), "on", "off"
	tankWarnPct = 85,
	minimap = {},
}
local db
local function Print(m) print("|cffd4a017Pint's|r Threat Meter: " .. m) end

---------------------------------------------------------------- helpers
local function Short(v)
	v = v or 0
	if v >= 1000000 then return ("%.1fm"):format(v / 1000000) end
	if v >= 10000 then return ("%dk"):format(math.floor(v / 1000 + 0.5)) end
	if v >= 1000 then return ("%.1fk"):format(v / 1000) end
	return tostring(math.floor(v + 0.5))
end
local function ClassRGB(unit)
	local _, file = UnitClass(unit)
	local cc = (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[file or ""]
	if cc then return cc.r, cc.g, cc.b end
	return 0.6, 0.6, 0.6
end
local function Hidden(v) return type(issecretvalue) == "function" and issecretvalue(v) end
-- true / false, or nil when the game hides buffs right now (in combat on the modern client)
local function HasBuff(unit, names)
	for i = 1, 40 do
		local n
		if UnitBuff then n = UnitBuff(unit, i)
		elseif C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
			local ok, a = pcall(C_UnitAuras.GetBuffDataByIndex, unit, i)
			if not ok or Hidden(a) then return nil end
			n = a and a.name
		end
		if Hidden(n) then return nil end
		if not n then return false end
		if names[n] then return true end
	end
	return false
end
local TANK_BUFFS = { ["Bear Form"] = true, ["Dire Bear Form"] = true, ["Righteous Fury"] = true }
local IAmTankKnown = false
local function IAmTank()
	if db.tankMode == "on" then return true elseif db.tankMode == "off" then return false end
	local _, class = UnitClass("player")
	if class == "WARRIOR" then return GetShapeshiftForm() == 2 end
	if class == "DRUID" or class == "PALADIN" then
		local r = HasBuff("player", TANK_BUFFS)
		if r ~= nil then IAmTankKnown = r end
		return IAmTankKnown or false
	end
	return false
end

---------------------------------------------------------------- who to check
local units = {}
local function BuildUnits()
	wipe(units)
	units[#units + 1] = "player"; units[#units + 1] = "pet"
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i; units[#units + 1] = "raidpet" .. i end
	elseif IsInGroup() then
		for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i; units[#units + 1] = "partypet" .. i end
	end
end

---------------------------------------------------------------- threat per second (from the last few seconds)
local history = {}   -- guid -> { {t, v}, ... }
local function Track(guid, v, now)
	local h = history[guid]
	if not h then h = {}; history[guid] = h end
	h[#h + 1] = { now, v }
	while #h > 1 and now - h[1][1] > 6 do table.remove(h, 1) end
end
local function TPS(guid)
	local h = history[guid]
	if not h or #h < 2 then return 0 end
	local a, b = h[1], h[#h]
	if b[1] - a[1] < 1 then return 0 end
	return math.max(0, (b[2] - a[2]) / (b[1] - a[1]))
end

---------------------------------------------------------------- reading the threat list
local rows, mobName, lastMob = {}, nil, nil
local function MobUnit()
	if UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDead("target") then return "target" end
	if db.healerMode and UnitExists("target") and not UnitCanAttack("player", "target") and UnitExists("targettarget") and UnitCanAttack("player", "targettarget") then return "targettarget" end
end
local function Read()
	wipe(rows)
	local mob = MobUnit()
	mobName = mob and UnitName(mob)
	if not mob then return end
	local guid = UnitGUID(mob)
	if guid ~= lastMob then wipe(history); lastMob = guid end
	local now, seen = GetTime(), {}
	local tank
	for _, u in ipairs(units) do
		if UnitExists(u) then
			local g = UnitGUID(u)
			if g and not seen[g] then
				seen[g] = true
				local isTanking, status, scaled, raw, value = UnitDetailedThreatSituation(u, mob)
				-- the modern client may hide other people's threat: skip anyone it won't tell us about
				if Hidden(isTanking) or Hidden(scaled) or Hidden(raw) or Hidden(value) then value = nil end
				if value and (value > 0 or u == "player" or isTanking) then
					value = value / 100
					Track(g, value, now)
					local r = { unit = u, guid = g, name = UnitName(u), tanking = isTanking, status = status, scaled = scaled or 0, raw = raw or 0, value = value,
						me = u == "player", pet = (u == "pet" or u:find("pet")) and true or false, tps = TPS(g) }
					-- raw / scaled = what it takes to pull (1.1 in melee, 1.3 at range)
					r.ranged = (r.scaled > 0 and r.raw / r.scaled > 1.2) or false
					rows[#rows + 1] = r
					if isTanking then tank = r end
				end
			end
		end
	end
	-- you're always on the list, even with no threat yet
	local haveMe = false
	for _, r in ipairs(rows) do if r.me then haveMe = true end end
	if not haveMe then rows[#rows + 1] = { unit = "player", guid = UnitGUID("player"), name = (GetUnitName and GetUnitName("player", false) or UnitName("player")), scaled = 0, raw = 0, value = 0, me = true, tps = 0 } end
	-- the threat you'd need to pull aggro
	local me
	for _, r in ipairs(rows) do if r.me then me = r end end
	PTH.me, PTH.tank = me, tank
	if me and tank and not me.tanking then
		local pull
		if me.scaled > 0 and me.value > 0 then pull = me.value * 100 / me.scaled
		else
			local ok, near = pcall(CheckInteractDistance, mob, 3)
			pull = tank.value * ((ok and near) and 1.1 or 1.3)
		end
		PTH.pull = pull
		if db.pullBar and pull then rows[#rows + 1] = { name = "Pull aggro", value = pull, scaled = 100, raw = pull / math.max(tank.value, 1) * 100, pullBar = true } end
		-- time to pull: the gap, closing at your rate minus the tank's (with the same margin)
		local closing = me.tps - tank.tps * (pull / math.max(tank.value, 1))
		PTH.ttp = (closing > 0) and ((pull - me.value) / closing) or nil
	else
		PTH.pull, PTH.ttp = nil, nil
	end
	table.sort(rows, function(a, b) if a.value ~= b.value then return a.value > b.value end return (a.name or "") < (b.name or "") end)
	-- keep yourself in view even outside the top bars
	if #rows > db.bars then
		local myIdx
		for i, r in ipairs(rows) do if r.me then myIdx = i end end
		if myIdx and myIdx > db.bars then local r = table.remove(rows, myIdx); table.insert(rows, db.bars, r) end
	end
end

---------------------------------------------------------------- the window
local frame, bars = nil, {}
local function SavePos()
	local p, _, rp, x, y = frame:GetPoint()
	db.pos = { p, rp, x, y }
end
local function Bar(i)
	local b = bars[i]
	if b then return b end
	b = CreateFrame("StatusBar", nil, frame)
	b:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	b:SetMinMaxValues(0, 1)
	b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints(); b.bg:SetColorTexture(0, 0, 0, 0.45)
	b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); b.name:SetPoint("LEFT", 4, 0); b.name:SetJustifyH("LEFT")
	b.pct = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); b.pct:SetPoint("RIGHT", -3, 0); b.pct:SetJustifyH("RIGHT")
	b.val = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); b.val:SetPoint("RIGHT", b.pct, "LEFT", -6, 0); b.val:SetJustifyH("RIGHT")
	bars[i] = b
	return b
end
local function Style()
	if not frame then return end
	frame:SetScale(db.scale)
	frame:SetBackdropColor(0, 0, 0, db.alpha)
	for _, b in ipairs(bars) do
		for _, fs in ipairs({ b.name, b.pct, b.val }) do local f, _, fl = fs:GetFont(); if f then fs:SetFont(f, db.font, fl) end end
	end
end
PTH.Style = Style

local function ShouldHide()
	local inCombat = UnitAffectingCombat("player")
	local solo = not IsInGroup() and not UnitExists("pet")
	if db.hide == "nocombat" then return not inCombat end
	if db.hide == "solo" then return solo end
	if db.hide == "nocombatsolo" then return not inCombat or solo end
	return false
end

local function Draw()
	if not frame then return end
	if PTH.userHidden or ShouldHide() then frame:Hide(); return end
	frame:Show()
	local top = rows[1] and rows[1].value or 0
	local tankV = PTH.tank and PTH.tank.value or top
	local n = math.min(#rows, db.bars)
	local h = db.barHeight
	local title = mobName and ("|cffffd100" .. mobName .. "|r") or "|cff888888no target|r"
	if db.timeToPull and PTH.ttp and PTH.ttp < 120 then title = title .. ("  |cffff8040pull in %.0fs|r"):format(PTH.ttp) end
	frame.title:SetText(title)
	for i = 1, n do
		local r, b = rows[i], Bar(i)
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -20 - (i - 1) * (h + 1)); b:SetSize(db.width - 8, h)
		b:SetValue(top > 0 and (r.value / top) or (r.me and 0 or 0))
		local cr, cg, cb
		if r.pullBar then cr, cg, cb = 0.85, 0.1, 0.1
		elseif db.classColors and r.unit and not r.pet then cr, cg, cb = ClassRGB(r.unit)
		elseif r.me then cr, cg, cb = unpack(db.meColor)
		elseif r.tanking then cr, cg, cb = unpack(db.tankColor)
		else cr, cg, cb = unpack(db.otherColor) end
		if r.pet and db.classColors then cr, cg, cb = 0.25, 0.65, 0.3 end
		local a = 1
		if r.ranged and not r.pullBar then
			if db.rangedStyle == "fade" then a = 0.55 elseif db.rangedStyle == "darken" then cr, cg, cb = cr * 0.55, cg * 0.55, cb * 0.55 end
		end
		b:SetStatusBarColor(cr, cg, cb, a)
		local nm = r.name or "?"
		if r.tanking then nm = "|TInterface\\GroupFrame\\UI-Group-MainTankIcon:0|t" .. nm end
		if r.me then nm = "|cffffffff" .. nm .. "|r" end
		b.name:SetText(nm)
		local pct = db.scaled and r.scaled or r.raw
		b.pct:SetText(db.showPct and (r.pullBar and (db.scaled and "100%" or ("%d%%"):format(r.raw)) or ("%d%%"):format(math.floor(pct + 0.5))) or "")
		local v = ""
		if db.showValue then v = Short(r.value) end
		if db.showTPS and not r.pullBar then v = v .. (v ~= "" and " " or "") .. "|cffaaaaaa" .. Short(r.tps) .. "/s|r" end
		b.val:SetText(v)
		b.name:SetPoint("RIGHT", b.val, "LEFT", -4, 0)
		if r.me then b.bg:SetColorTexture(0.25, 0.25, 0.25, 0.6) else b.bg:SetColorTexture(0, 0, 0, 0.45) end
		b:Show()
	end
	for i = n + 1, #bars do bars[i]:Hide() end
	frame:SetSize(db.width, 24 + math.max(n, 1) * (h + 1))
end

local function Build()
	frame = CreateFrame("Frame", "PintsThreatFrame", UIParent, "BackdropTemplate")
	frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
	frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
	frame:SetClampedToScreen(true); frame:SetMovable(true); frame:EnableMouse(true); frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self) if not db.locked then self:StartMoving() end end)
	frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePos() end)
	frame:SetScript("OnMouseUp", function(_, b) if b == "RightButton" then PTH.ToggleOptions() end end)
	local head = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); head:SetPoint("TOPLEFT", 6, -5); head:SetText("Threat")
	frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); frame.title:SetPoint("LEFT", head, "RIGHT", 8, 0); frame.title:SetPoint("RIGHT", frame, "RIGHT", -6, 0); frame.title:SetJustifyH("RIGHT")
	if db.pos then frame:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4]) else frame:SetPoint("CENTER", UIParent, "CENTER", 300, -120) end
	Style()
end

---------------------------------------------------------------- warnings
local flash
local function Flash()
	if not flash then
		flash = CreateFrame("Frame", nil, UIParent); flash:SetAllPoints(); flash:SetFrameStrata("FULLSCREEN_DIALOG")
		local t = flash:CreateTexture(nil, "BACKGROUND"); t:SetAllPoints(); t:SetTexture("Interface\\FullScreenTextures\\LowHealth"); t:SetBlendMode("ADD"); t:SetVertexColor(1, 0.1, 0.1)
		flash:Hide()
		flash:SetScript("OnUpdate", function(self, e)
			self.t = self.t + e
			local a = self.t < 0.25 and self.t / 0.25 or math.max(0, 1 - (self.t - 0.25) / 0.6)
			self:SetAlpha(a)
			if self.t > 0.85 then self:Hide() end
		end)
	end
	flash.t = 0; flash:SetAlpha(0); flash:Show()
end
local lastWarn, wasOver = 0, false
local function Warn(msg)
	local now = GetTime()
	if now - lastWarn < db.warnCooldown then return end
	lastWarn = now
	if db.warnSound then PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master") end
	if db.warnFlash then Flash() end
	if RaidNotice_AddMessage and RaidWarningFrame then RaidNotice_AddMessage(RaidWarningFrame, msg, { r = 1, g = 0.3, b = 0.2 }) end
end
local function CheckWarnings()
	if not db.warn then return end
	local me, tank = PTH.me, PTH.tank
	if not me then wasOver = false; return end
	if IAmTank() then
		-- tank: someone else getting close to taking it
		if not me.tanking then wasOver = false; return end
		local worst
		for _, r in ipairs(rows) do if not r.me and not r.pullBar and r.scaled and (not worst or r.scaled > worst.scaled) then worst = r end end
		local over = worst and worst.scaled >= db.tankWarnPct and worst.value >= db.warnMin
		if over and not wasOver then Warn((worst.name or "?") .. " is about to pull aggro (" .. math.floor(worst.scaled) .. "%)") end
		wasOver = over and true or false
	else
		if me.tanking then wasOver = false; return end
		local over = me.scaled >= db.warnPct and me.value >= db.warnMin
		if over and not wasOver then Warn("Threat " .. math.floor(me.scaled) .. "% - ease off!") end
		wasOver = over and true or false
	end
end

---------------------------------------------------------------- updates
local function Update()
	if not db then return end
	Read()
	CheckWarnings()
	Draw()
end
PTH.Update = Update
local ev = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_TARGET_CHANGED", "UNIT_THREAT_LIST_UPDATE", "UNIT_THREAT_SITUATION_UPDATE", "GROUP_ROSTER_UPDATE",
	"UNIT_PET", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "UNIT_TARGET" }) do ev:RegisterEvent(e) end
ev:SetScript("OnEvent", function(_, e, a1)
	if e == "ADDON_LOADED" and a1 == ADDON then
		PintsThreatDB = PintsThreatDB or {}
		db = PintsThreatDB
		for k, v in pairs(DEFAULTS) do if db[k] == nil then if type(v) == "table" then db[k] = {}; for kk, vv in pairs(v) do db[k][kk] = vv end else db[k] = v end end end
		PTH.db = db
	elseif e == "PLAYER_LOGIN" then
		BuildUnits(); Build(); Update()
		if PTH.BuildMinimap then PTH.BuildMinimap() end
		if PTH.TC2Loaded() then Print("ThreatClassic2 is on too - /pth off-tc2 to switch it off, then /reload.") end
	elseif e == "GROUP_ROSTER_UPDATE" or e == "UNIT_PET" then BuildUnits(); Update()
	elseif e == "PLAYER_REGEN_ENABLED" then wipe(history); wasOver = false; Update()
	elseif e == "UNIT_TARGET" then if a1 == "target" then Update() end
	else Update() end
end)
local acc = 0
ev:SetScript("OnUpdate", function(_, el)
	acc = acc + el
	if acc < 0.25 then return end
	acc = 0
	if db and UnitAffectingCombat("player") then Update() end
end)

---------------------------------------------------------------- options
local opt
local function Check(x, y, label, key, tip)
	local c = CreateFrame("CheckButton", nil, opt, "UICheckButtonTemplate"); c:SetSize(22, 22); c:SetPoint("TOPLEFT", x, y)
	local t = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); t:SetPoint("LEFT", c, "RIGHT", 2, 0); t:SetText(label)
	c:SetScript("OnShow", function(self) self:SetChecked(db[key] and true or false) end)
	c:SetScript("OnClick", function(self) db[key] = self:GetChecked() and true or false; Style(); Update() end)
	if tip then c:SetScript("OnEnter", function(s) GameTooltip:SetOwner(s, "ANCHOR_RIGHT"); GameTooltip:AddLine(tip, 1, 1, 1, true); GameTooltip:Show() end); c:SetScript("OnLeave", function() GameTooltip:Hide() end) end
end
local function Stepper(x, y, label, key, lo, hi, step, fmt)
	local t = opt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); t:SetPoint("TOPLEFT", x, y - 4); t:SetText(label)
	local m = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate"); m:SetSize(20, 18); m:SetPoint("TOPLEFT", x + 130, y); m:SetText("-")
	local v = opt:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); v:SetPoint("LEFT", m, "RIGHT", 2, 0); v:SetWidth(44)
	local p = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate"); p:SetSize(20, 18); p:SetPoint("LEFT", v, "RIGHT", 2, 0); p:SetText("+")
	local function show() v:SetText((fmt or tostring)(db[key])) end
	local function go(d) db[key] = math.max(lo, math.min(hi, math.floor((db[key] + d) * 100 + 0.5) / 100)); show(); Style(); Update() end
	m:SetScript("OnClick", function() go(-step) end); p:SetScript("OnClick", function() go(step) end)
	opt:HookScript("OnShow", show)
end
local function Cycle(x, y, label, key, choices)
	local t = opt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); t:SetPoint("TOPLEFT", x, y - 4); t:SetText(label)
	local b = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate"); b:SetSize(150, 20); b:SetPoint("TOPLEFT", x + 130, y)
	local function show() for _, c in ipairs(choices) do if c[1] == db[key] then b:SetText(c[2]) end end end
	b:SetScript("OnClick", function()
		local i = 1; for k, c in ipairs(choices) do if c[1] == db[key] then i = k end end
		db[key] = choices[i % #choices + 1][1]; show(); Update()
	end)
	opt:HookScript("OnShow", show)
end
local function Pct(v) return math.floor(v * 100 + 0.5) .. "%" end
function PTH.ToggleOptions()
	if not opt then
		opt = CreateFrame("Frame", "PintsThreatOptions", UIParent, "BasicFrameTemplateWithInset")
		opt:SetSize(360, 560); opt:SetPoint("CENTER"); opt:SetFrameStrata("DIALOG")
		opt:SetMovable(true); opt:EnableMouse(true); opt:RegisterForDrag("LeftButton")
		opt:SetScript("OnDragStart", opt.StartMoving); opt:SetScript("OnDragStop", opt.StopMovingOrSizing)
		tinsert(UISpecialFrames, "PintsThreatOptions")
		local title = opt:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); title:SetPoint("TOP", 0, -5); title:SetText("|cffd4a017Pint's|r Threat Meter")
		local function head(y, s) local h = opt:CreateFontString(nil, "OVERLAY", "GameFontNormal"); h:SetPoint("TOPLEFT", 16, y); h:SetText(s) end
		head(-32, "Show")
		Check(16, -50, "Threat amount", "showValue"); Check(180, -50, "Percent", "showPct")
		Check(16, -72, "Threat per second", "showTPS"); Check(180, -72, "\"Pull aggro\" bar", "pullBar", "A red bar showing how much threat it takes to pull aggro from the tank.")
		Check(16, -94, "Time to pull aggro", "timeToPull"); Check(180, -94, "Scaled percent", "scaled", "On: 100% means you'd pull aggro. Off: raw percent of the tank's threat (pulls at 110% in melee, 130% at range).")
		Check(16, -116, "Class colours", "classColors"); Check(180, -116, "Healer mode", "healerMode", "Targeting a friend shows the threat on whatever they're targeting.")
		Cycle(16, -142, "Out of melee range", "rangedStyle", { { "none", "Look the same" }, { "fade", "Fade them" }, { "darken", "Darken them" } })
		Cycle(16, -166, "Hide the meter", "hide", { { "never", "Never" }, { "nocombat", "Out of combat" }, { "solo", "When solo" }, { "nocombatsolo", "Out of combat or solo" } })
		head(-196, "Look")
		Stepper(16, -214, "Bars", "bars", 3, 40, 1)
		Stepper(16, -236, "Width", "width", 120, 400, 10)
		Stepper(16, -258, "Bar height", "barHeight", 10, 30, 1)
		Stepper(16, -280, "Text size", "font", 8, 18, 1)
		Stepper(16, -302, "Scale", "scale", 0.5, 2, 0.05, Pct)
		Stepper(16, -324, "Background", "alpha", 0, 1, 0.05, Pct)
		Check(16, -346, "Lock position", "locked")
		head(-376, "Warnings")
		Check(16, -394, "Warn me", "warn"); Check(180, -394, "Sound", "warnSound"); Check(260, -394, "Flash", "warnFlash")
		Stepper(16, -418, "Warn at threat", "warnPct", 50, 100, 5, function(v) return v .. "%" end)
		Stepper(16, -440, "Tank: warn when others reach", "tankWarnPct", 50, 100, 5, function(v) return v .. "%" end)
		Stepper(16, -462, "Seconds between warnings", "warnCooldown", 1, 30, 1)
		Stepper(16, -484, "Ignore below threat", "warnMin", 0, 20000, 250, Short)
		Cycle(16, -508, "Tank mode", "tankMode", { { "auto", "Auto (stance/form/RF)" }, { "on", "Always" }, { "off", "Never" } })
		opt.tc2 = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate"); opt.tc2:SetSize(180, 20); opt.tc2:SetPoint("BOTTOMLEFT", 16, 10)
		opt.tc2:SetText("Switch ThreatClassic2 off"); opt.tc2:SetScript("OnClick", function() PTH.TC2Off() end)
		opt:HookScript("OnShow", function() opt.tc2:SetShown(PTH.TC2Loaded()) end)
		local test = CreateFrame("Button", nil, opt, "UIPanelButtonTemplate"); test:SetSize(110, 20); test:SetPoint("BOTTOMRIGHT", -16, 10); test:SetText("Test warning")
		test:SetScript("OnClick", function() lastWarn = 0; Warn("Test: threat warning") end)
		opt:Hide()
	end
	opt:SetShown(not opt:IsShown())
end

---------------------------------------------------------------- ThreatClassic2 off, slash, minimap
local function Loaded(a) if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded(a) end return IsAddOnLoaded and IsAddOnLoaded(a) end
function PTH.TC2Loaded() return Loaded("ThreatClassic2") end
function PTH.TC2Off()
	local off = (C_AddOns and C_AddOns.DisableAddOn) or DisableAddOn
	pcall(off, "ThreatClassic2")
	Print("ThreatClassic2 switched off - /reload to finish.")
end
SLASH_PINTSTHREAT1 = "/pth"
SLASH_PINTSTHREAT2 = "/pintsthreat"
SLASH_PINTSTHREAT3 = "/threatmeter"
SlashCmdList.PINTSTHREAT = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "toggle" then PTH.userHidden = not PTH.userHidden; Update()
	elseif msg == "off-tc2" then PTH.TC2Off()
	elseif msg == "minimap" then PTH.ToggleMinimap()
	elseif msg == "test" then lastWarn = 0; Warn("Test: threat warning")
	elseif msg == "" or msg == "options" then PTH.ToggleOptions()
	else Print("/pth - options   /pth toggle - show/hide   /pth test - test warning   /pth minimap") end
end
do
	local NAME, ICON, ANGLE = "PintsThreat", "Interface\\Icons\\Ability_Defend", 250
	local btn
	local function Tip(tt) tt:AddLine("|cffd4a017Pint's|r Threat Meter"); tt:AddLine("Click: show/hide   Right-click: options", 1, 1, 1); tt:AddLine("/pth minimap to hide", 0.5, 0.5, 0.5) end
	local function Click(_, b) if b == "RightButton" then PTH.ToggleOptions() else PTH.userHidden = not PTH.userHidden; Update() end end
	function PTH.BuildMinimap()
		local store = db.minimap
		local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
		local Icon = LibStub and LibStub("LibDBIcon-1.0", true)
		if LDB and Icon then
			local obj = LDB:NewDataObject(NAME, { type = "launcher", text = "Pint's Threat Meter", icon = ICON, OnClick = Click, OnTooltipShow = Tip })
			Icon:Register(NAME, obj, store); btn = { lib = Icon }; return
		end
		local b = CreateFrame("Button", NAME .. "MinimapButton", Minimap)
		b:SetSize(31, 31); b:SetFrameStrata("MEDIUM"); b:SetFrameLevel(8)
		b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
		local ic = b:CreateTexture(nil, "BACKGROUND"); ic:SetTexture(ICON); ic:SetSize(20, 20); ic:SetPoint("CENTER", 0, 1); ic:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		local border = b:CreateTexture(nil, "OVERLAY"); border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder"); border:SetSize(53, 53); border:SetPoint("TOPLEFT")
		local function Place() local a = math.rad(store.angle or ANGLE); b:ClearAllPoints(); b:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(a), 80 * math.sin(a)) end
		Place()
		b:RegisterForClicks("LeftButtonUp", "RightButtonUp"); b:RegisterForDrag("LeftButton")
		b:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter(); local px, py = GetCursorPosition(); local s = Minimap:GetEffectiveScale()
			store.angle = math.deg(math.atan2(py / s - my, px / s - mx)); Place() end) end)
		b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
		b:SetScript("OnClick", Click)
		b:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_LEFT"); Tip(GameTooltip); GameTooltip:Show() end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		b:SetShown(not store.hide); btn = b
	end
	function PTH.ToggleMinimap()
		local store = db.minimap; store.hide = not store.hide
		if btn and btn.lib then if store.hide then btn.lib:Hide(NAME) else btn.lib:Show(NAME) end elseif btn then btn:SetShown(not store.hide) end
	end
end
