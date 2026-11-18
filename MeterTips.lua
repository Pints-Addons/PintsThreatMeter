-- Pint's Threat Meter - tooltips for the game's own Damage Meter (WoW Forever): hover a player's bar to see what their
-- damage (or healing - whatever the meter window shows) came from, spell by spell. Hold Shift for it by mob instead.
-- Reads the meter's own data (C_DamageMeter); nothing is added to or changed on the game's meter window itself.
-- The game hides the amounts while you're in a fight: the breakdown shows again once the fight ends.
-- /pth metertips turns it off or on.
if not (C_DamageMeter and C_DamageMeter.GetCombatSessionSourceFromType) then return end   -- (WoW Forever only)

local function Secret(v) return type(issecretvalue) == "function" and issecretvalue(v) end
local function DB() PintsThreatDB = PintsThreatDB or {}; return PintsThreatDB end
local MAX_LINES = 12

local function Short(n)
	if n >= 1e6 then return ("%.2fM"):format(n / 1e6) elseif n >= 1e4 then return ("%.1fK"):format(n / 1e3) end
	return tostring(math.floor(n + 0.5))
end

-- the meter entry under the mouse: { data, window } or nil
local function EntryAt(f)
	for _ = 1, 3 do
		if not f or (f.IsForbidden and f:IsForbidden()) then return end
		local ok, data = pcall(function() return f.GetElementData and f:GetElementData() end)
		if ok and type(data) == "table" and (data.sourceGUID ~= nil or data.sourceCreatureID ~= nil) and data.damageMeterType ~= nil then
			local w = f:GetParent()
			for _ = 1, 8 do
				if not w then break end
				if w.GetSessionType and w.GetSessionID then return f, data, w end
				w = w:GetParent()
			end
			return
		end
		f = f:GetParent()
	end
end

local function GetSource(data, window)
	local okT, sType = pcall(window.GetSessionType, window)
	local okI, sID = pcall(window.GetSessionID, window)
	local ok, src
	if okT and sType then ok, src = pcall(C_DamageMeter.GetCombatSessionSourceFromType, sType, data.damageMeterType, data.sourceGUID, data.sourceCreatureID)
	elseif okI and sID then ok, src = pcall(C_DamageMeter.GetCombatSessionSourceFromID, sID, data.damageMeterType, data.sourceGUID, data.sourceCreatureID) end
	if ok then return src end
end

local function SpellLabel(id, pet)
	local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)) or (GetSpellInfo and GetSpellInfo(id)) or ("Spell " .. tostring(id))
	local icon = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(id)) or (GetSpellTexture and GetSpellTexture(id))
	if pet and pet ~= "" and not Secret(pet) then name = name .. " |cff909090(" .. pet .. ")|r" end
	return (icon and ("|T" .. icon .. ":14:14:0:0:64:64:5:59:5:59|t ") or "") .. name
end

local function Show(owner, data, window)
	local tt = GameTooltip
	tt:SetOwner(owner, "ANCHOR_RIGHT")
	local name = data.name
	tt:AddLine((name and not Secret(name)) and name or "Breakdown", 1, 0.82, 0)
	local src = GetSource(data, window)
	local spells = src and src.combatSpells
	if not spells or Secret(src.totalAmount) then
		tt:AddLine("The game hides the breakdown during a fight - it shows once the fight ends.", 0.8, 0.8, 0.8, true)
		tt:Show(); return
	end
	local total = src.totalAmount or 0
	local rows = {}
	local byMob = IsShiftKeyDown()
	if byMob then
		local mobs = {}
		for _, sp in ipairs(spells) do
			local d = sp.combatSpellDetails
			local list = (type(d) == "table" and d.unitName ~= nil) and { d } or d
			for _, u in ipairs(type(list) == "table" and list or {}) do
				local n = u.unitName
				if n and not Secret(n) and u.amount and not Secret(u.amount) then mobs[n] = (mobs[n] or 0) + u.amount end
			end
		end
		for n, a in pairs(mobs) do rows[#rows + 1] = { n, a } end
		tt:AddLine("By mob  |cff909090(let go of Shift: by spell)|r", 0.6, 0.8, 1)
	else
		for _, sp in ipairs(spells) do
			if sp.totalAmount and not Secret(sp.totalAmount) and sp.totalAmount > 0 then
				rows[#rows + 1] = { SpellLabel(sp.spellID, sp.creatureName), sp.totalAmount }
			end
		end
		tt:AddLine("By spell  |cff909090(hold Shift: by mob)|r", 0.6, 0.8, 1)
	end
	table.sort(rows, function(a, b) return a[2] > b[2] end)
	for i, r in ipairs(rows) do
		if i > MAX_LINES then tt:AddLine(("... and %d more"):format(#rows - MAX_LINES), 0.6, 0.6, 0.6); break end
		local pct = total > 0 and (" |cffb0b0b0%d%%|r"):format(math.floor(r[2] / total * 100 + 0.5)) or ""
		tt:AddDoubleLine(r[1], Short(r[2]) .. pct, 1, 1, 1, 1, 1, 1)
	end
	if #rows == 0 then tt:AddLine(byMob and "No targets recorded." or "Nothing recorded yet.", 0.7, 0.7, 0.7) end
	tt:Show()
end

-- watch what the mouse is over (nothing is hooked on the game's meter, so it can't be tainted)
local cur, curData, curWin, shift
local w = CreateFrame("Frame")
local acc = 0
w:SetScript("OnUpdate", function(_, el)
	acc = acc + el
	if acc < 0.1 then return end
	acc = 0
	if DB().meterTips == false then return end
	local foci = GetMouseFoci and GetMouseFoci()
	local f = foci and foci[1] or (GetMouseFocus and GetMouseFocus())
	local e, data, win = EntryAt(f)
	local s = IsShiftKeyDown()
	if e then
		if e ~= cur or data ~= curData or s ~= shift then cur, curData, curWin, shift = e, data, win, s; Show(e, data, win) end
	elseif cur then
		if GameTooltip:IsOwned(cur) then GameTooltip:Hide() end
		cur, curData, curWin = nil, nil, nil
	end
end)

-- /pth metertips
local orig = SlashCmdList.PINTSTHREAT
if orig then
	SlashCmdList.PINTSTHREAT = function(msg)
		if (msg or ""):lower():match("^%s*metertips%s*$") then
			DB().meterTips = (DB().meterTips == false)
			print("|cffd4a017Pint's|r Threat Meter: Damage Meter tooltips " .. (DB().meterTips and "on" or "off") .. ".")
			return
		end
		return orig(msg)
	end
end
