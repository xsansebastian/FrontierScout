-- Fake frame API and AceGUI for smoke-testing UI files outside the game.
-- Any CamelCase method exists and returns a new fake; lowercase fields stay
-- nil unless set, so lazy "if row.label then" setups behave as in WoW.
-- Scripts and AceGUI callbacks are recorded so tests can fire them.
local M = {}

local fakeMethods = {}

local function fake(kind)
	local obj = { kind = kind, scripts = {}, shown = true, text = "" }
	return setmetatable(obj, {
		__index = function(t, k)
			if fakeMethods[k] then return fakeMethods[k] end
			if type(k) == "string" and k:match("^%u") then
				local fn = function() return fake(k) end
				rawset(t, k, fn)
				return fn
			end
		end,
	})
end
M.fake = fake

function fakeMethods:SetScript(name, fn) self.scripts[name] = fn end
function fakeMethods:HookScript(name, fn) self.scripts[name] = fn end
function fakeMethods:GetScript(name) return self.scripts[name] end
function fakeMethods:Show() self.shown = true if self.scripts.OnShow then self.scripts.OnShow(self) end end
function fakeMethods:Hide() self.shown = false if self.scripts.OnHide then self.scripts.OnHide(self) end end
function fakeMethods:SetShown(on) self.shown = on and true or false end
function fakeMethods:IsShown() return self.shown end
function fakeMethods:SetText(text) self.text = text end
function fakeMethods:GetText() return self.text end
function fakeMethods:GetStringHeight() return 12 end
function fakeMethods:GetChecked() return self.checked end
function fakeMethods:SetChecked(on) self.checked = on end
function fakeMethods:Enable() self.enabled = true end
function fakeMethods:Disable() self.enabled = false end
function fakeMethods:HasFocus() return self.focus end
function fakeMethods:Insert(text) self.text = self.text .. text end
function fakeMethods:Click() self.scripts.OnClick(self) end

-- ScrollBox: SetDataProvider runs the view's element initializer on a fresh
-- row for every element, and keeps the rows in box.rows.
local function scrollBox()
	local box = fake("ScrollBox")
	function box.SetDataProvider(b, dp)
		b.rows = {}
		for _, data in ipairs(dp.list) do
			local row = fake("Button")
			b.view.initializer(row, data)
			b.rows[#b.rows + 1] = row
		end
	end
	return box
end

function M.install(env, state)
	state.frames = {}
	env.CreateFrame = function(kind, name, _, template)
		local f = template == "WowScrollBoxList" and scrollBox() or fake(kind)
		if template == "ButtonFrameTemplate" then f.Inset = fake("Frame") end
		if name then state.frames[name] = f end
		return f
	end
	env.CreateScrollBoxListLinearView = function()
		local view = fake("View")
		function view.SetElementInitializer(v, _, fn) v.initializer = fn end
		return view
	end
	env.ScrollUtil = { InitScrollBoxListWithScrollBar = function(box, _, view) box.view = view end }
	env.CreateDataProvider = function(list) return { list = list } end
	env.ScrollBoxConstants = { RetainScrollPosition = true }
	env.ButtonFrameTemplate_HidePortrait = function() end
	env.UIParent = fake("UIParent")
	env.UISpecialFrames = {}
	env.tinsert = table.insert
	env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	env.hooksecurefunc = function(t, name, fn)
		if type(t) == "string" then return end
		local orig = t[name]
		t[name] = function(...) orig(...) fn(...) end
	end
	env.GameTooltip = fake("GameTooltip")
	env.GameTooltip_Hide = function() end
	env.StaticPopupDialogs = {}
	state.popups = {}
	env.StaticPopup_Show = function(which, a, b, data) state.popups[#state.popups + 1] = { which, a, b, data } end
	env.YES, env.NO = "Yes", "No"
	env.Ambiguate = function(name) return (name:gsub("%-.*", "")) end
	env.C_Texture = { GetAtlasInfo = function() return nil end }
	env.C_Item = { GetItemInfo = function(id) return "Item " .. id, "[Item " .. id .. "]" end }
	env.ChatFrameUtil = { InsertLink = function() end }

	-- AceGUI: widgets record text, children and callbacks.
	state.widgets = {}
	local AceGUI = {}
	function AceGUI.Create(_, kind)
		local w = fake(kind)
		w.children, w.callbacks = {}, {}
		w.editBox, w.editbox = fake("EditBox"), fake("EditBox")
		function w.SetCallback(self, name, fn) self.callbacks[name] = fn end
		function w.Fire(self, name, ...) if self.callbacks[name] then self.callbacks[name](self, name, ...) end end
		function w.AddChild(self, child) self.children[#self.children + 1] = child end
		function w.ReleaseChildren(self) self.children = {} end
		function w.SetLabel(self, label) self.label = label end
		function w.SetValue(self, value) self.value = value end
		function w.SetStatusText(self, text) self.status = text end
		function w.Hide(self) self.shown = false self:Fire("OnClose") end
		state.widgets[#state.widgets + 1] = w
		return w
	end
	function AceGUI.Release(_, w) w.released = true end
	state.libs["AceGUI-3.0"] = AceGUI
end

-- Depth-first search of AceGUI widgets under `root` by label or button text.
function M.find(root, label)
	for _, child in ipairs(root.children or {}) do
		if child.label == label or child.text == label then return child end
		local found = M.find(child, label)
		if found then return found end
	end
end

return M
