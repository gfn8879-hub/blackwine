-- Blackwine UI Library
-- Usage:
--   local Library = loadstring(...)()
--   local Window = Library:CreateWindow({ Title = "blackwine" })
--   local Tab = Window:CreateTab({ Name = "Main", Icon = "rbxassetid://7539983773" })
--   local Section = Tab:AddSection({ Name = "Combat", Side = "left" })
--   Section:AddToggle({ Name = "Speed Override", Default = false, Callback = function(v) end })

local BlackwineLib = {}
BlackwineLib.__index = BlackwineLib

-- ══════════════════════════════════════════════════
--  Theming System & Palette
-- ══════════════════════════════════════════════════

-- Derive lighter / darker shades from an accent Color3
local function accentShade(c3, lightDelta, darkDelta)
	local h, s, v = c3:ToHSV()
	local light = Color3.fromHSV(h, math.clamp(s - 0.12, 0, 1), math.clamp(v + (lightDelta or 0.12), 0, 1))
	local dark  = Color3.fromHSV(h, math.clamp(s + 0.08, 0, 1), math.clamp(v - (darkDelta or 0.12), 0, 1))
	return light, dark
end

-- Build a full palette from base surface colors + an accent
local function buildPalette(base, accent)
	local al, ad = accentShade(accent)
	local p = {}
	for k, v in pairs(base) do p[k] = v end
	p.Accent      = accent
	p.AccentLight = al
	p.AccentDark  = ad
	p.Toggle_On   = accent
	p.SliderFill  = accent
	return p
end

-- Preset themes  (surface palette without accent – accent is separate)
local THEME_PRESETS = {
	Dark = {
		Background   = Color3.fromRGB(14, 14, 14),
		Surface      = Color3.fromRGB(20, 20, 20),
		SurfaceLight = Color3.fromRGB(28, 28, 28),
		Divider      = Color3.fromRGB(34, 34, 34),
		Border       = Color3.fromRGB(40, 40, 40),
		Text         = Color3.fromRGB(232, 232, 232),
		TextDim      = Color3.fromRGB(148, 148, 148),
		TextMuted    = Color3.fromRGB(88, 88, 88),
		Toggle_Off   = Color3.fromRGB(50, 50, 50),
		SliderTrack  = Color3.fromRGB(40, 40, 40),
		Error        = Color3.fromRGB(200, 60, 60),
		Success      = Color3.fromRGB(60, 180, 90),
		White        = Color3.fromRGB(255, 255, 255),
	},
	Midnight = {
		Background   = Color3.fromRGB(10, 10, 18),
		Surface      = Color3.fromRGB(16, 16, 28),
		SurfaceLight = Color3.fromRGB(24, 24, 40),
		Divider      = Color3.fromRGB(30, 30, 48),
		Border       = Color3.fromRGB(38, 38, 56),
		Text         = Color3.fromRGB(220, 220, 240),
		TextDim      = Color3.fromRGB(140, 140, 170),
		TextMuted    = Color3.fromRGB(80, 80, 110),
		Toggle_Off   = Color3.fromRGB(44, 44, 62),
		SliderTrack  = Color3.fromRGB(36, 36, 54),
		Error        = Color3.fromRGB(200, 60, 60),
		Success      = Color3.fromRGB(60, 180, 90),
		White        = Color3.fromRGB(255, 255, 255),
	},
	Dimmed = {
		Background   = Color3.fromRGB(22, 22, 22),
		Surface      = Color3.fromRGB(30, 30, 30),
		SurfaceLight = Color3.fromRGB(40, 40, 40),
		Divider      = Color3.fromRGB(50, 50, 50),
		Border       = Color3.fromRGB(58, 58, 58),
		Text         = Color3.fromRGB(210, 210, 210),
		TextDim      = Color3.fromRGB(155, 155, 155),
		TextMuted    = Color3.fromRGB(100, 100, 100),
		Toggle_Off   = Color3.fromRGB(60, 60, 60),
		SliderTrack  = Color3.fromRGB(52, 52, 52),
		Error        = Color3.fromRGB(200, 60, 60),
		Success      = Color3.fromRGB(60, 180, 90),
		White        = Color3.fromRGB(255, 255, 255),
	},
	Light = {
		Background   = Color3.fromRGB(235, 235, 235),
		Surface      = Color3.fromRGB(245, 245, 245),
		SurfaceLight = Color3.fromRGB(252, 252, 252),
		Divider      = Color3.fromRGB(210, 210, 210),
		Border       = Color3.fromRGB(195, 195, 195),
		Text         = Color3.fromRGB(30, 30, 30),
		TextDim      = Color3.fromRGB(90, 90, 90),
		TextMuted    = Color3.fromRGB(150, 150, 150),
		Toggle_Off   = Color3.fromRGB(180, 180, 180),
		SliderTrack  = Color3.fromRGB(195, 195, 195),
		Error        = Color3.fromRGB(200, 60, 60),
		Success      = Color3.fromRGB(60, 180, 90),
		White        = Color3.fromRGB(255, 255, 255),
	},
}

-- Active palette – starts with Dark theme + wine purple accent
local DEFAULT_ACCENT = Color3.fromRGB(124, 90, 181)
local PALETTE = buildPalette(THEME_PRESETS.Dark, DEFAULT_ACCENT)

-- Expose themes for external use
BlackwineLib.Themes = THEME_PRESETS

local FONT        = Font.new("rbxassetid://12187365364", Enum.FontWeight.Bold,     Enum.FontStyle.Normal)
local FONT_MEDIUM  = Font.new("rbxassetid://12187365364", Enum.FontWeight.Medium,   Enum.FontStyle.Normal)
local FONT_REGULAR = Font.new("rbxassetid://12187365364", Enum.FontWeight.Regular,  Enum.FontStyle.Normal)
local FONT_SEMI    = Font.new("rbxassetid://12187365364", Enum.FontWeight.SemiBold, Enum.FontStyle.Normal)

local CORNER_SM   = UDim.new(0, 4)
local CORNER_MD   = UDim.new(0, 6)
local CORNER_FULL = UDim.new(1, 0)

local TWEEN_FAST   = TweenInfo.new(0.15, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)
local TWEEN_SMOOTH = TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local TWEEN_BOUNCE = TweenInfo.new(0.4,  Enum.EasingStyle.Back,  Enum.EasingDirection.Out)

local COMPONENT_HEIGHT = 36
local COMPONENT_PAD    = 6
local SECTION_PAD      = 12

-- ══════════════════════════════════════════════════
--  Services
-- ══════════════════════════════════════════════════

local TweenService    = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Players          = game:GetService("Players")

-- ══════════════════════════════════════════════════
--  Utility Helpers
-- ══════════════════════════════════════════════════

local function tw(obj, info, props)
	local t = TweenService:Create(obj, info, props)
	t:Play()
	return t
end

local function create(cls, props, children)
	local inst = Instance.new(cls)
	for k, v in pairs(props or {}) do
		if k ~= "Parent" then inst[k] = v end
	end
	for _, c in ipairs(children or {}) do c.Parent = inst end
	if props and props.Parent then inst.Parent = props.Parent end
	return inst
end

local function corner(p, r) return create("UICorner", { CornerRadius = r or CORNER_SM, Parent = p }) end

local function stroke(p, col, th, tr)
	return create("UIStroke", {
		Color = col or PALETTE.Border, Thickness = th or 1,
		Transparency = tr or 0.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = p,
	})
end

local function pad(p, t, r, b, l)
	return create("UIPadding", {
		PaddingTop = UDim.new(0, t or 0), PaddingRight = UDim.new(0, r or 0),
		PaddingBottom = UDim.new(0, b or 0), PaddingLeft = UDim.new(0, l or 0), Parent = p,
	})
end

local function listLayout(p, spacing, dir, hA, vA)
	return create("UIListLayout", {
		Padding = UDim.new(0, spacing or 4),
		FillDirection = dir or Enum.FillDirection.Vertical,
		HorizontalAlignment = hA or Enum.HorizontalAlignment.Center,
		VerticalAlignment = vA or Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = p,
	})
end

local function clamp01(v) return math.clamp(v, 0, 1) end
local function lerp(a, b, t) return a + (b - a) * t end
local function round(n, d) local m = 10 ^ (d or 0); return math.floor(n * m + 0.5) / m end

local function shadow(p, depth)
	depth = depth or 1
	return create("ImageLabel", {
		Name = "Shadow", AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 24 * depth, 1, 24 * depth),
		BackgroundTransparency = 1,
		Image = "rbxassetid://5554236805",
		ImageColor3 = Color3.fromRGB(0, 0, 0), ImageTransparency = 0.6,
		ScaleType = Enum.ScaleType.Slice, SliceCenter = Rect.new(23, 23, 277, 277),
		ZIndex = p.ZIndex - 1, Parent = p,
	})
end

-- ══════════════════════════════════════════════════
--  Window
-- ══════════════════════════════════════════════════

function BlackwineLib:CreateWindow(opts)
	opts = opts or {}
	local winTitle = opts.Title or "blackwine"
	local winSize  = opts.Size  or UDim2.fromOffset(640, 440)

	local W = { Tabs = {}, ActiveTab = nil, SidebarOpen = true, Toggled = true }

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild("blackwine_ui")
	if old then old:Destroy() end

	-- ScreenGui
	local gui = create("ScreenGui", {
		Name = "blackwine_ui", ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Global, DisplayOrder = 100,
		Parent = playerGui,
	})

	-- Main
	local main = create("Frame", {
		Name = "main", Size = winSize,
		Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = PALETTE.Background, BorderSizePixel = 0,
		ClipsDescendants = true, Parent = gui,
	})
	corner(main, CORNER_MD); stroke(main, PALETTE.Divider, 1, 0.3); shadow(main, 2)

	-- ═══════════  Topbar  ═══════════
	local topbar = create("Frame", {
		Name = "topbar", Size = UDim2.new(1, 0, 0, 44),
		BackgroundColor3 = PALETTE.Surface, BackgroundTransparency = 0.3,
		BorderSizePixel = 0, Parent = main,
	})
	create("Frame", { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, 0),
		AnchorPoint = Vector2.new(0, 1), BackgroundColor3 = PALETTE.Divider, BorderSizePixel = 0, Parent = topbar })

	-- Hamburger
	local extendBtn = create("ImageButton", {
		Name = "extend", Size = UDim2.fromOffset(28, 28),
		Position = UDim2.new(0, 10, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5),
		BackgroundTransparency = 1, Image = "rbxassetid://11889177340",
		ImageColor3 = PALETTE.TextDim, ScaleType = Enum.ScaleType.Fit, Parent = topbar,
	})

	-- Accent dot
	create("Frame", { Size = UDim2.fromOffset(4, 4), Position = UDim2.new(0, 42, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5), BackgroundColor3 = PALETTE.Accent, BorderSizePixel = 0, Parent = topbar,
	}, { create("UICorner", { CornerRadius = CORNER_FULL }) })

	-- Title
	create("TextLabel", {
		Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.new(0, 50, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5), BackgroundTransparency = 1,
		Text = winTitle, TextColor3 = PALETTE.Text, TextSize = 15,
		FontFace = FONT, TextXAlignment = Enum.TextXAlignment.Left, Parent = topbar,
	})

	-- Minimize btn
	local minBtn = create("ImageButton", {
		Size = UDim2.fromOffset(24, 24), Position = UDim2.new(1, -14, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5), BackgroundTransparency = 1,
		Image = "rbxassetid://7072725342", ImageColor3 = PALETTE.TextMuted,
		ScaleType = Enum.ScaleType.Fit, Parent = topbar,
	})

	-- ═══════════  Drag  ═══════════
	do
		local dragging, dragStart, startPos
		topbar.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true; dragStart = input.Position; startPos = main.Position
				input.Changed:Connect(function()
					if input.UserInputState == Enum.UserInputState.End then dragging = false end
				end)
			end
		end)
		UserInputService.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local d = input.Position - dragStart
				tw(main, TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y),
				})
			end
		end)
	end

	-- ═══════════  Content  ═══════════
	local content = create("Frame", {
		Name = "content", Size = UDim2.new(1, 0, 1, -44), Position = UDim2.new(0, 0, 0, 44),
		BackgroundTransparency = 1, BorderSizePixel = 0, ClipsDescendants = true, Parent = main,
	})

	-- Sidebar
	local SW = 140
	local sidebar = create("Frame", {
		Name = "sidebar", Size = UDim2.new(0, SW, 1, 0),
		BackgroundColor3 = PALETTE.Surface, BackgroundTransparency = 0.5,
		BorderSizePixel = 0, ClipsDescendants = true, Parent = content,
	})
	create("Frame", { Size = UDim2.new(0, 1, 1, 0), Position = UDim2.new(1, 0, 0, 0),
		BackgroundColor3 = PALETTE.Divider, BorderSizePixel = 0, Parent = sidebar })

	local tabScroll = create("ScrollingFrame", {
		Name = "tabs", Size = UDim2.new(1, -1, 1, -8), Position = UDim2.new(0, 0, 0, 4),
		BackgroundTransparency = 1, ScrollBarThickness = 2,
		ScrollBarImageColor3 = PALETTE.Divider, ScrollBarImageTransparency = 0.5,
		CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ElasticBehavior = Enum.ElasticBehavior.WhenScrollable, Parent = sidebar,
	})
	listLayout(tabScroll, 2); pad(tabScroll, 4, 6, 4, 6)

	-- Tab content area
	local tabArea = create("Frame", {
		Name = "tab_area", Size = UDim2.new(1, -SW, 1, 0), Position = UDim2.new(0, SW, 0, 0),
		BackgroundTransparency = 1, ClipsDescendants = true, Parent = content,
	})

	-- Sidebar toggle
	extendBtn.MouseButton1Click:Connect(function()
		W.SidebarOpen = not W.SidebarOpen
		local w = W.SidebarOpen and SW or 0
		tw(sidebar,  TWEEN_SMOOTH, { Size = UDim2.new(0, w, 1, 0) })
		tw(tabArea,  TWEEN_SMOOTH, { Size = UDim2.new(1, -w, 1, 0), Position = UDim2.new(0, w, 0, 0) })
		tw(extendBtn, TWEEN_FAST,  { ImageColor3 = W.SidebarOpen and PALETTE.TextDim or PALETTE.Accent, Rotation = W.SidebarOpen and 0 or 180 })
	end)

	-- Minimize
	minBtn.MouseButton1Click:Connect(function()
		W.Toggled = not W.Toggled
		if W.Toggled then
			tw(main, TWEEN_SMOOTH, { Size = winSize }); content.Visible = true
		else
			tw(main, TWEEN_SMOOTH, { Size = UDim2.fromOffset(winSize.X.Offset, 44) })
			task.delay(0.25, function() if not W.Toggled then content.Visible = false end end)
		end
		tw(minBtn, TWEEN_FAST, { Rotation = W.Toggled and 0 or 180 })
	end)

	-- Toggle key
	local tkey = opts.ToggleKey or Enum.KeyCode.RightShift
	UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		if input.KeyCode == tkey then gui.Enabled = not gui.Enabled end
	end)

	-- ═══════════  Tab Selection  ═══════════
	local function selectTab(tab)
		if W.ActiveTab == tab then return end
		if W.ActiveTab then
			local p = W.ActiveTab
			tw(p._btn,  TWEEN_FAST, { BackgroundTransparency = 1 })
			tw(p._lbl,  TWEEN_FAST, { TextColor3 = PALETTE.TextDim })
			if p._ico then tw(p._ico, TWEEN_FAST, { ImageColor3 = PALETTE.TextDim }) end
			if p._ind then tw(p._ind, TWEEN_FAST, { BackgroundTransparency = 1 }) end
			p._frame.Visible = false
		end
		W.ActiveTab = tab
		tw(tab._btn,  TWEEN_FAST, { BackgroundTransparency = 0.85 })
		tw(tab._lbl,  TWEEN_FAST, { TextColor3 = PALETTE.Text })
		if tab._ico then tw(tab._ico, TWEEN_FAST, { ImageColor3 = PALETTE.Text }) end
		if tab._ind then tw(tab._ind, TWEEN_FAST, { BackgroundTransparency = 0 }) end
		tab._frame.Visible = true
	end

	-- ══════════════════════════════════════════════════
	--  CreateTab
	-- ══════════════════════════════════════════════════

	function W:CreateTab(tOpts)
		tOpts = tOpts or {}
		local name = tOpts.Name or ("Tab " .. (#self.Tabs + 1))
		local icon = tOpts.Icon or "rbxassetid://7539983773"

		local T = {}

		-- Sidebar button
		local btn = create("TextButton", {
			Name = "t_" .. name, Size = UDim2.new(1, 0, 0, 34),
			BackgroundColor3 = PALETTE.Accent, BackgroundTransparency = 1,
			BorderSizePixel = 0, Text = "", AutoButtonColor = false,
			LayoutOrder = #self.Tabs + 1, Parent = tabScroll,
		})
		corner(btn, CORNER_SM)

		local ind = create("Frame", {
			Size = UDim2.new(0, 3, 0.6, 0), Position = UDim2.new(0, 0, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5), BackgroundColor3 = PALETTE.Accent,
			BackgroundTransparency = 1, BorderSizePixel = 0, Parent = btn,
		}); corner(ind, CORNER_FULL)

		local ico = create("ImageLabel", {
			Size = UDim2.fromOffset(20, 20), Position = UDim2.new(0, 12, 0.5, 0),
			AnchorPoint = Vector2.new(0, 0.5), BackgroundTransparency = 1,
			Image = icon, ImageColor3 = PALETTE.TextDim, Parent = btn,
		})

		local lbl = create("TextLabel", {
			Size = UDim2.new(1, -42, 1, 0), Position = UDim2.new(0, 40, 0, 0),
			BackgroundTransparency = 1, Text = name, TextColor3 = PALETTE.TextDim,
			TextSize = 13, FontFace = FONT_SEMI, TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd, Parent = btn,
		})

		T._btn = btn; T._lbl = lbl; T._ico = ico; T._ind = ind

		btn.MouseEnter:Connect(function() if W.ActiveTab ~= T then tw(btn, TWEEN_FAST, { BackgroundTransparency = 0.92 }) end end)
		btn.MouseLeave:Connect(function() if W.ActiveTab ~= T then tw(btn, TWEEN_FAST, { BackgroundTransparency = 1 }) end end)
		btn.MouseButton1Click:Connect(function() selectTab(T) end)

		-- Tab content scroll
		local frame = create("ScrollingFrame", {
			Name = "f_" .. name, Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1, BorderSizePixel = 0,
			ScrollBarThickness = 2, ScrollBarImageColor3 = PALETTE.Divider,
			ScrollBarImageTransparency = 0.3, CanvasSize = UDim2.new(0, 0, 0, 0),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ElasticBehavior = Enum.ElasticBehavior.WhenScrollable,
			Visible = false, Parent = tabArea,
		})
		pad(frame, 8, 0, 8, 0)
		T._frame = frame

		-- Two-column holder
		local cols = create("Frame", {
			Size = UDim2.new(1, -20, 0, 0), Position = UDim2.new(0.5, 0, 0, 0),
			AnchorPoint = Vector2.new(0.5, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1, Parent = frame,
		})

		local leftCol = create("Frame", {
			Name = "left", Size = UDim2.new(0.5, -4, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = cols,
		})
		local ll = listLayout(leftCol, SECTION_PAD); ll.HorizontalAlignment = Enum.HorizontalAlignment.Left

		local rightCol = create("Frame", {
			Name = "right", Size = UDim2.new(0.5, -4, 0, 0), Position = UDim2.new(0.5, 4, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = cols,
		})
		local rl = listLayout(rightCol, SECTION_PAD); rl.HorizontalAlignment = Enum.HorizontalAlignment.Left

		T._left = leftCol; T._right = rightCol

		-- ══════════════════════════════════════════════════
		--  AddSection
		-- ══════════════════════════════════════════════════

		function T:AddSection(sOpts)
			sOpts = sOpts or {}
			local sName  = sOpts.Name or "Section"
			local parent = ((sOpts.Side or "left"):lower() == "right") and rightCol or leftCol

			local S = {}

			local sf = create("Frame", {
				Name = "s_" .. sName, Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundColor3 = PALETTE.Surface, BackgroundTransparency = 0.4,
				BorderSizePixel = 0, Parent = parent,
			})
			corner(sf, CORNER_MD); stroke(sf, PALETTE.Divider, 1, 0.6)

			-- Header
			local hdr = create("Frame", {
				Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, LayoutOrder = 0, Parent = sf,
			})
			create("TextLabel", {
				Size = UDim2.new(1, -16, 1, 0), Position = UDim2.new(0, 12, 0, 0),
				BackgroundTransparency = 1, Text = sName:upper(),
				TextColor3 = PALETTE.TextMuted, TextSize = 10, FontFace = FONT,
				TextXAlignment = Enum.TextXAlignment.Left, Parent = hdr,
			})

			-- Items container
			local items = create("Frame", {
				Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1, LayoutOrder = 1, Parent = sf,
			})
			local il = listLayout(items, COMPONENT_PAD); il.HorizontalAlignment = Enum.HorizontalAlignment.Center
			pad(items, 0, 10, 10, 10)

			local ml = listLayout(sf, 2); ml.HorizontalAlignment = Enum.HorizontalAlignment.Center
			S._f = sf; S._items = items

			--  ╔════════════════════════════════════╗
			--  ║            COMPONENTS              ║
			--  ╚════════════════════════════════════╝

			-- ────────── LABEL ──────────
			function S:AddLabel(o)
				o = o or {}
				local c = create("Frame", { Size = UDim2.new(1, 0, 0, 22), BackgroundTransparency = 1, Parent = items })
				local l = create("TextLabel", {
					Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1,
					Text = o.Text or "Label", TextColor3 = o.Color or PALETTE.TextDim,
					TextSize = 13, FontFace = FONT_REGULAR, TextXAlignment = Enum.TextXAlignment.Left,
					TextWrapped = true, Parent = c,
				})
				local obj = {}
				function obj:Set(t) l.Text = t end
				function obj:SetColor(col) l.TextColor3 = col end
				return obj
			end

			-- ────────── BUTTON ──────────
			function S:AddButton(o)
				o = o or {}
				local cb = o.Callback or function() end
				local c = create("Frame", { Size = UDim2.new(1, 0, 0, COMPONENT_HEIGHT), BackgroundTransparency = 1, Parent = items })

				local b = create("TextButton", {
					Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = PALETTE.SurfaceLight,
					BackgroundTransparency = 0.3, BorderSizePixel = 0, Text = "",
					AutoButtonColor = false, ClipsDescendants = true, Parent = c,
				})
				corner(b, CORNER_SM); stroke(b, PALETTE.Border, 1, 0.6)

				local bl = create("TextLabel", {
					Size = UDim2.new(1, -16, 1, 0), Position = UDim2.fromScale(0.5, 0.5),
					AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1,
					Text = o.Name or "Button", TextColor3 = PALETTE.Text,
					TextSize = 13, FontFace = FONT_SEMI, Parent = b,
				})

				b.MouseEnter:Connect(function()
					tw(b, TWEEN_FAST, { BackgroundTransparency = 0.15 })
					tw(bl, TWEEN_FAST, { TextColor3 = PALETTE.AccentLight })
				end)
				b.MouseLeave:Connect(function()
					tw(b, TWEEN_FAST, { BackgroundTransparency = 0.3 })
					tw(bl, TWEEN_FAST, { TextColor3 = PALETTE.Text })
				end)
				b.MouseButton1Click:Connect(function()
					tw(b, TweenInfo.new(0.08), { BackgroundColor3 = PALETTE.Accent })
					task.delay(0.12, function() tw(b, TWEEN_FAST, { BackgroundColor3 = PALETTE.SurfaceLight }) end)
					pcall(cb)
				end)

				local obj = {}
				function obj:SetText(t) bl.Text = t end
				return obj
			end

			-- ────────── TOGGLE ──────────
			function S:AddToggle(o)
				o = o or {}
				local state = o.Default or false
				local cb    = o.Callback or function() end

				local c = create("Frame", { Size = UDim2.new(1, 0, 0, COMPONENT_HEIGHT), BackgroundTransparency = 1, Parent = items })

				local tb = create("TextButton", {
					Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = PALETTE.SurfaceLight,
					BackgroundTransparency = 0.5, BorderSizePixel = 0, Text = "",
					AutoButtonColor = false, Parent = c,
				})
				corner(tb, CORNER_SM)

				create("TextLabel", {
					Size = UDim2.new(1, -60, 1, 0), Position = UDim2.new(0, 10, 0, 0),
					BackgroundTransparency = 1, Text = o.Name or "Toggle",
					TextColor3 = PALETTE.Text, TextSize = 13, FontFace = FONT_MEDIUM,
					TextXAlignment = Enum.TextXAlignment.Left, Parent = tb,
				})

				local track = create("Frame", {
					Size = UDim2.fromOffset(36, 20),
					Position = UDim2.new(1, -12, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5),
					BackgroundColor3 = state and PALETTE.Toggle_On or PALETTE.Toggle_Off,
					BorderSizePixel = 0, Parent = tb,
				})
				corner(track, CORNER_FULL)

				local knob = create("Frame", {
					Size = UDim2.fromOffset(14, 14),
					Position = state and UDim2.new(1, -3, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
					AnchorPoint = state and Vector2.new(1, 0.5) or Vector2.new(0, 0.5),
					BackgroundColor3 = PALETTE.White,
					BackgroundTransparency = state and 0 or 0.2,
					BorderSizePixel = 0, Parent = track,
				})
				corner(knob, CORNER_FULL)

				local function vis(on, anim)
					if anim then
						tw(track, TWEEN_SMOOTH, { BackgroundColor3 = on and PALETTE.Toggle_On or PALETTE.Toggle_Off })
						tw(knob, TWEEN_BOUNCE, {
							Position = on and UDim2.new(1, -3, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
							AnchorPoint = on and Vector2.new(1, 0.5) or Vector2.new(0, 0.5),
							BackgroundTransparency = on and 0 or 0.2,
						})
					else
						track.BackgroundColor3 = on and PALETTE.Toggle_On or PALETTE.Toggle_Off
						knob.Position = on and UDim2.new(1, -3, 0.5, 0) or UDim2.new(0, 3, 0.5, 0)
						knob.AnchorPoint = on and Vector2.new(1, 0.5) or Vector2.new(0, 0.5)
						knob.BackgroundTransparency = on and 0 or 0.2
					end
				end

				tb.MouseEnter:Connect(function() tw(tb, TWEEN_FAST, { BackgroundTransparency = 0.3 }) end)
				tb.MouseLeave:Connect(function() tw(tb, TWEEN_FAST, { BackgroundTransparency = 0.5 }) end)
				tb.MouseButton1Click:Connect(function()
					state = not state; vis(state, true); pcall(cb, state)
				end)

				local obj = {}
				function obj:Set(v) if state == v then return end; state = v; vis(state, true); pcall(cb, state) end
				function obj:Get() return state end
				if o.Flag then W[o.Flag] = obj end
				return obj
			end

			-- ────────── SLIDER ──────────
			function S:AddSlider(o)
				o = o or {}
				local mn, mx = o.Min or 0, o.Max or 100
				local inc = o.Increment or 1
				local suf = o.Suffix or ""
				local cb  = o.Callback or function() end
				local cur = math.clamp(o.Default or mn, mn, mx)

				local c = create("Frame", { Size = UDim2.new(1, 0, 0, COMPONENT_HEIGHT + 16), BackgroundTransparency = 1, Parent = items })

				local sf = create("Frame", {
					Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = PALETTE.SurfaceLight,
					BackgroundTransparency = 0.5, BorderSizePixel = 0, Parent = c,
				})
				corner(sf, CORNER_SM)

				create("TextLabel", {
					Size = UDim2.new(0.6, 0, 0, 20), Position = UDim2.new(0, 10, 0, 6),
					BackgroundTransparency = 1, Text = o.Name or "Slider",
					TextColor3 = PALETTE.Text, TextSize = 13, FontFace = FONT_MEDIUM,
					TextXAlignment = Enum.TextXAlignment.Left, Parent = sf,
				})
				local vl = create("TextLabel", {
					Size = UDim2.new(0.4, -10, 0, 20), Position = UDim2.new(0.6, 0, 0, 6),
					BackgroundTransparency = 1, Text = tostring(cur) .. suf,
					TextColor3 = PALETTE.Accent, TextSize = 13, FontFace = FONT_SEMI,
					TextXAlignment = Enum.TextXAlignment.Right, Parent = sf,
				})

				local trackF = create("Frame", {
					Size = UDim2.new(1, -20, 0, 6),
					Position = UDim2.new(0.5, 0, 1, -12), AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundColor3 = PALETTE.SliderTrack, BorderSizePixel = 0, ClipsDescendants = true, Parent = sf,
				})
				corner(trackF, CORNER_FULL)

				local pct = clamp01((cur - mn) / (mx - mn))
				local fill = create("Frame", {
					Size = UDim2.new(pct, 0, 1, 0),
					BackgroundColor3 = PALETTE.SliderFill, BorderSizePixel = 0, Parent = trackF,
				})
				corner(fill, CORNER_FULL)

				local sk = create("Frame", {
					Size = UDim2.fromOffset(14, 14),
					Position = UDim2.new(pct, 0, 0.5, 0), AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundColor3 = PALETTE.White, BorderSizePixel = 0, ZIndex = 2, Parent = trackF,
				})
				corner(sk, CORNER_FULL); stroke(sk, PALETTE.Accent, 2, 0)

				local glow = create("Frame", {
					Size = UDim2.fromOffset(24, 24), Position = UDim2.fromScale(0.5, 0.5),
					AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = PALETTE.Accent,
					BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 1, Parent = sk,
				})
				corner(glow, CORNER_FULL)

				local function setVal(v, fire)
					v = math.clamp(v, mn, mx)
					v = round(mn + round((v - mn) / inc) * inc, 4)
					v = math.clamp(v, mn, mx)
					cur = v
					local p = clamp01((v - mn) / (mx - mn))
					tw(fill, TWEEN_FAST, { Size = UDim2.new(p, 0, 1, 0) })
					tw(sk,   TWEEN_FAST, { Position = UDim2.new(p, 0, 0.5, 0) })
					vl.Text = tostring(v) .. suf
					if fire then pcall(cb, v) end
				end

				local function startSlide(input)
					tw(glow, TWEEN_FAST, { BackgroundTransparency = 0.7 })
					tw(sk, TWEEN_FAST, { Size = UDim2.fromOffset(16, 16) })
					local function upd(pos)
						local rel = clamp01((pos.X - trackF.AbsolutePosition.X) / trackF.AbsoluteSize.X)
						setVal(lerp(mn, mx, rel), true)
					end
					upd(input.Position)
					local mc, rc
					mc = UserInputService.InputChanged:Connect(function(mi)
						if mi.UserInputType == Enum.UserInputType.MouseMovement or mi.UserInputType == Enum.UserInputType.Touch then upd(mi.Position) end
					end)
					rc = UserInputService.InputEnded:Connect(function(ei)
						if ei.UserInputType == Enum.UserInputType.MouseButton1 or ei.UserInputType == Enum.UserInputType.Touch then
							mc:Disconnect(); rc:Disconnect()
							tw(glow, TWEEN_FAST, { BackgroundTransparency = 1 })
							tw(sk, TWEEN_FAST, { Size = UDim2.fromOffset(14, 14) })
						end
					end)
				end

				trackF.InputBegan:Connect(function(i)
					if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then startSlide(i) end
				end)
				sk.InputBegan:Connect(function(i)
					if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then startSlide(i) end
				end)

				local obj = {}
				function obj:Set(v) setVal(v, true) end
				function obj:Get() return cur end
				if o.Flag then W[o.Flag] = obj end
				return obj
			end

			-- ────────── DROPDOWN ──────────
			function S:AddDropdown(o)
				o = o or {}
				local itms = o.Items or {}
				local sel  = o.Default or (itms[1] or "")
				local cb   = o.Callback or function() end
				local open = false

				local c = create("Frame", {
					Size = UDim2.new(1, 0, 0, COMPONENT_HEIGHT), AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1, ClipsDescendants = false, Parent = items,
				})

				local hdr = create("TextButton", {
					Size = UDim2.new(1, 0, 0, COMPONENT_HEIGHT),
					BackgroundColor3 = PALETTE.SurfaceLight, BackgroundTransparency = 0.5,
					BorderSizePixel = 0, Text = "", AutoButtonColor = false, LayoutOrder = 0, Parent = c,
				})
				corner(hdr, CORNER_SM)

				create("TextLabel", {
					Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.new(0, 10, 0, 0),
					BackgroundTransparency = 1, Text = o.Name or "Dropdown",
					TextColor3 = PALETTE.Text, TextSize = 13, FontFace = FONT_MEDIUM,
					TextXAlignment = Enum.TextXAlignment.Left, Parent = hdr,
				})
				local selLbl = create("TextLabel", {
					Size = UDim2.new(0.5, -36, 1, 0), Position = UDim2.new(0.5, 0, 0, 0),
					BackgroundTransparency = 1, Text = tostring(sel),
					TextColor3 = PALETTE.Accent, TextSize = 13, FontFace = FONT_SEMI,
					TextXAlignment = Enum.TextXAlignment.Right,
					TextTruncate = Enum.TextTruncate.AtEnd, Parent = hdr,
				})
				local arr = create("ImageLabel", {
					Size = UDim2.fromOffset(16, 16), Position = UDim2.new(1, -10, 0.5, 0),
					AnchorPoint = Vector2.new(1, 0.5), BackgroundTransparency = 1,
					Image = "rbxassetid://6031091004", ImageColor3 = PALETTE.TextDim, Parent = hdr,
				})

				local dl = create("Frame", {
					Size = UDim2.new(1, 0, 0, 0), BackgroundColor3 = PALETTE.Surface,
					BackgroundTransparency = 0.1, BorderSizePixel = 0, ClipsDescendants = true,
					Visible = false, LayoutOrder = 1, Parent = c,
				})
				corner(dl, CORNER_SM); stroke(dl, PALETTE.Border, 1, 0.5)

				local dlc = create("Frame", {
					Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1, Parent = dl,
				})
				local dll = listLayout(dlc, 1); dll.HorizontalAlignment = Enum.HorizontalAlignment.Center
				pad(dlc, 4, 4, 4, 4)
				local cl = listLayout(c, 4); cl.HorizontalAlignment = Enum.HorizontalAlignment.Center

				local function mkItem(txt)
					local it = create("TextButton", {
						Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = PALETTE.SurfaceLight,
						BackgroundTransparency = (txt == sel) and 0.5 or 1, BorderSizePixel = 0,
						Text = "", AutoButtonColor = false, Parent = dlc,
					})
					corner(it, CORNER_SM)
					local il = create("TextLabel", {
						Size = UDim2.new(1, -16, 1, 0), Position = UDim2.new(0, 8, 0, 0),
						BackgroundTransparency = 1, Text = txt,
						TextColor3 = (txt == sel) and PALETTE.Accent or PALETTE.Text,
						TextSize = 12, FontFace = FONT_REGULAR, TextXAlignment = Enum.TextXAlignment.Left, Parent = it,
					})
					it.MouseEnter:Connect(function() if txt ~= sel then tw(it, TWEEN_FAST, { BackgroundTransparency = 0.6 }) end end)
					it.MouseLeave:Connect(function() if txt ~= sel then tw(it, TWEEN_FAST, { BackgroundTransparency = 1 }) end end)
					it.MouseButton1Click:Connect(function()
						if sel == txt then return end
						for _, ch in ipairs(dlc:GetChildren()) do
							if ch:IsA("TextButton") then
								tw(ch, TWEEN_FAST, { BackgroundTransparency = 1 })
								local lb = ch:FindFirstChild("label") or ch:FindFirstChildWhichIsA("TextLabel")
								if lb then tw(lb, TWEEN_FAST, { TextColor3 = PALETTE.Text }) end
							end
						end
						sel = txt
						tw(it, TWEEN_FAST, { BackgroundTransparency = 0.5 })
						tw(il, TWEEN_FAST, { TextColor3 = PALETTE.Accent })
						selLbl.Text = txt; pcall(cb, sel)
						task.delay(0.1, function()
							open = false; tw(arr, TWEEN_FAST, { Rotation = 0 })
							tw(dl, TWEEN_FAST, { Size = UDim2.new(1, 0, 0, 0) })
							task.delay(0.15, function() if not open then dl.Visible = false end end)
						end)
					end)
					return it
				end
				for _, v in ipairs(itms) do mkItem(v) end

				local function toggle()
					open = not open
					if open then
						dl.Visible = true
						local th = math.min(#itms * 29 + 9, 180)
						tw(arr, TWEEN_FAST, { Rotation = 180 })
						tw(dl, TWEEN_SMOOTH, { Size = UDim2.new(1, 0, 0, th) })
					else
						tw(arr, TWEEN_FAST, { Rotation = 0 })
						tw(dl, TWEEN_SMOOTH, { Size = UDim2.new(1, 0, 0, 0) })
						task.delay(0.35, function() if not open then dl.Visible = false end end)
					end
				end
				hdr.MouseButton1Click:Connect(toggle)
				hdr.MouseEnter:Connect(function() tw(hdr, TWEEN_FAST, { BackgroundTransparency = 0.3 }) end)
				hdr.MouseLeave:Connect(function() tw(hdr, TWEEN_FAST, { BackgroundTransparency = 0.5 }) end)

				local obj = {}
				function obj:Set(v)
					sel = v; selLbl.Text = tostring(v)
					for _, ch in ipairs(dlc:GetChildren()) do
						if ch:IsA("TextButton") then
							local lb = ch:FindFirstChildWhichIsA("TextLabel")
							if lb then
								local on = lb.Text == v
								ch.BackgroundTransparency = on and 0.5 or 1
								lb.TextColor3 = on and PALETTE.Accent or PALETTE.Text
							end
						end
					end
					pcall(cb, v)
				end
				function obj:Get() return sel end
				function obj:Refresh(newItems, keep)
					itms = newItems
					for _, ch in ipairs(dlc:GetChildren()) do if ch:IsA("TextButton") then ch:Destroy() end end
					if not keep or not table.find(newItems, sel) then sel = newItems[1] or ""; selLbl.Text = tostring(sel) end
					for _, v in ipairs(newItems) do mkItem(v) end
				end
				if o.Flag then W[o.Flag] = obj end
				return obj
			end

			-- ────────── INPUT / TEXTBOX ──────────
			function S:AddInput(o)
				o = o or {}
				local cb = o.Callback or function() end

				local c = create("Frame", { Size = UDim2.new(1, 0, 0, COMPONENT_HEIGHT + 20), BackgroundTransparency = 1, Parent = items })

				create("TextLabel", {
					Size = UDim2.new(1, 0, 0, 18), Position = UDim2.new(0, 2, 0, 0),
					BackgroundTransparency = 1, Text = o.Name or "Input",
					TextColor3 = PALETTE.Text, TextSize = 13, FontFace = FONT_MEDIUM,
					TextXAlignment = Enum.TextXAlignment.Left, Parent = c,
				})

				local inf = create("Frame", {
					Size = UDim2.new(1, 0, 0, COMPONENT_HEIGHT), Position = UDim2.new(0, 0, 0, 20),
					BackgroundColor3 = PALETTE.SurfaceLight, BackgroundTransparency = 0.3,
					BorderSizePixel = 0, Parent = c,
				})
				corner(inf, CORNER_SM)
				local ins = stroke(inf, PALETTE.Border, 1, 0.5)

				local tb = create("TextBox", {
					Size = UDim2.new(1, -16, 1, 0), Position = UDim2.fromScale(0.5, 0.5),
					AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1,
					Text = o.Default or "", PlaceholderText = o.Placeholder or "Type here...",
					PlaceholderColor3 = PALETTE.TextMuted, TextColor3 = PALETTE.Text,
					TextSize = 13, FontFace = FONT_REGULAR, TextXAlignment = Enum.TextXAlignment.Left,
					ClearTextOnFocus = o.ClearOnFocus or false, ClipsDescendants = true, Parent = inf,
				})

				tb.Focused:Connect(function()
					tw(ins, TWEEN_FAST, { Color = PALETTE.Accent, Transparency = 0 })
					tw(inf, TWEEN_FAST, { BackgroundTransparency = 0.15 })
				end)
				tb.FocusLost:Connect(function()
					tw(ins, TWEEN_FAST, { Color = PALETTE.Border, Transparency = 0.5 })
					tw(inf, TWEEN_FAST, { BackgroundTransparency = 0.3 })
					local val = tb.Text
					if o.Numeric then val = tonumber(val); if not val then tb.Text = ""; return end end
					pcall(cb, val)
				end)

				local obj = {}
				function obj:Set(v) tb.Text = tostring(v); pcall(cb, v) end
				function obj:Get() return o.Numeric and tonumber(tb.Text) or tb.Text end
				if o.Flag then W[o.Flag] = obj end
				return obj
			end

			-- ────────── MULTISELECT ──────────
			function S:AddMultiSelect(o)
				o = o or {}
				local itms = o.Items or {}
				local cb   = o.Callback or function() end
				local open = false
				local sels = {}
				for _, v in ipairs(o.Default or {}) do sels[v] = true end

				local function getList()
					local r = {}; for _, v in ipairs(itms) do if sels[v] then table.insert(r, v) end end; return r
				end
				local function getText()
					local s = getList()
					if #s == 0 then return "None" end
					if #s == #itms then return "All" end
					if #s <= 2 then return table.concat(s, ", ") end
					return s[1] .. " +" .. (#s - 1)
				end

				local c = create("Frame", {
					Size = UDim2.new(1, 0, 0, COMPONENT_HEIGHT), AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1, ClipsDescendants = false, Parent = items,
				})

				local hdr = create("TextButton", {
					Size = UDim2.new(1, 0, 0, COMPONENT_HEIGHT),
					BackgroundColor3 = PALETTE.SurfaceLight, BackgroundTransparency = 0.5,
					BorderSizePixel = 0, Text = "", AutoButtonColor = false, LayoutOrder = 0, Parent = c,
				})
				corner(hdr, CORNER_SM)

				create("TextLabel", {
					Size = UDim2.new(0.5, 0, 1, 0), Position = UDim2.new(0, 10, 0, 0),
					BackgroundTransparency = 1, Text = o.Name or "Multi Select",
					TextColor3 = PALETTE.Text, TextSize = 13, FontFace = FONT_MEDIUM,
					TextXAlignment = Enum.TextXAlignment.Left, Parent = hdr,
				})
				local selLbl = create("TextLabel", {
					Size = UDim2.new(0.5, -36, 1, 0), Position = UDim2.new(0.5, 0, 0, 0),
					BackgroundTransparency = 1, Text = getText(),
					TextColor3 = PALETTE.Accent, TextSize = 12, FontFace = FONT_SEMI,
					TextXAlignment = Enum.TextXAlignment.Right,
					TextTruncate = Enum.TextTruncate.AtEnd, Parent = hdr,
				})
				local arr = create("ImageLabel", {
					Size = UDim2.fromOffset(16, 16), Position = UDim2.new(1, -10, 0.5, 0),
					AnchorPoint = Vector2.new(1, 0.5), BackgroundTransparency = 1,
					Image = "rbxassetid://6031091004", ImageColor3 = PALETTE.TextDim, Parent = hdr,
				})

				local ol = create("Frame", {
					Size = UDim2.new(1, 0, 0, 0), BackgroundColor3 = PALETTE.Surface,
					BackgroundTransparency = 0.1, BorderSizePixel = 0, ClipsDescendants = true,
					Visible = false, LayoutOrder = 1, Parent = c,
				})
				corner(ol, CORNER_SM); stroke(ol, PALETTE.Border, 1, 0.5)

				local olc = create("Frame", {
					Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1, Parent = ol,
				})
				local oll = listLayout(olc, 1); oll.HorizontalAlignment = Enum.HorizontalAlignment.Center
				pad(olc, 4, 4, 4, 4)
				local cll = listLayout(c, 4); cll.HorizontalAlignment = Enum.HorizontalAlignment.Center

				local function mkItem(txt)
					local it = create("TextButton", {
						Size = UDim2.new(1, 0, 0, 28), BackgroundColor3 = PALETTE.SurfaceLight,
						BackgroundTransparency = 1, BorderSizePixel = 0, Text = "",
						AutoButtonColor = false, Parent = olc,
					})
					corner(it, CORNER_SM)

					local cb2 = create("Frame", {
						Name = "checkbox",
						Size = UDim2.fromOffset(16, 16), Position = UDim2.new(0, 8, 0.5, 0),
						AnchorPoint = Vector2.new(0, 0.5),
						BackgroundColor3 = sels[txt] and PALETTE.Accent or PALETTE.Toggle_Off,
						BorderSizePixel = 0, Parent = it,
					})
					corner(cb2, CORNER_SM)

					local cm = create("ImageLabel", {
						Size = UDim2.fromOffset(10, 10), Position = UDim2.fromScale(0.5, 0.5),
						AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1,
						Image = "rbxassetid://6031094667", ImageColor3 = PALETTE.White,
						ImageTransparency = sels[txt] and 0 or 1, Parent = cb2,
					})

					local il = create("TextLabel", {
						Size = UDim2.new(1, -36, 1, 0), Position = UDim2.new(0, 30, 0, 0),
						BackgroundTransparency = 1, Text = txt,
						TextColor3 = sels[txt] and PALETTE.Text or PALETTE.TextDim,
						TextSize = 12, FontFace = FONT_REGULAR, TextXAlignment = Enum.TextXAlignment.Left, Parent = it,
					})

					it.MouseEnter:Connect(function() tw(it, TWEEN_FAST, { BackgroundTransparency = 0.6 }) end)
					it.MouseLeave:Connect(function() tw(it, TWEEN_FAST, { BackgroundTransparency = 1 }) end)
					it.MouseButton1Click:Connect(function()
						sels[txt] = not sels[txt]
						local on = sels[txt]
						tw(cb2, TWEEN_FAST, { BackgroundColor3 = on and PALETTE.Accent or PALETTE.Toggle_Off })
						tw(cm, TWEEN_FAST, { ImageTransparency = on and 0 or 1 })
						tw(il, TWEEN_FAST, { TextColor3 = on and PALETTE.Text or PALETTE.TextDim })
						selLbl.Text = getText()
						pcall(o.Callback or function() end, getList())
					end)
					return it
				end
				for _, v in ipairs(itms) do mkItem(v) end

				hdr.MouseButton1Click:Connect(function()
					open = not open
					if open then
						ol.Visible = true
						tw(arr, TWEEN_FAST, { Rotation = 180 })
						tw(ol, TWEEN_SMOOTH, { Size = UDim2.new(1, 0, 0, math.min(#itms * 29 + 9, 200)) })
					else
						tw(arr, TWEEN_FAST, { Rotation = 0 })
						tw(ol, TWEEN_SMOOTH, { Size = UDim2.new(1, 0, 0, 0) })
						task.delay(0.35, function() if not open then ol.Visible = false end end)
					end
				end)
				hdr.MouseEnter:Connect(function() tw(hdr, TWEEN_FAST, { BackgroundTransparency = 0.3 }) end)
				hdr.MouseLeave:Connect(function() tw(hdr, TWEEN_FAST, { BackgroundTransparency = 0.5 }) end)

				local obj = {}
				function obj:Set(list)
					sels = {}; for _, v in ipairs(list) do sels[v] = true end
					selLbl.Text = getText()
					for _, ch in ipairs(olc:GetChildren()) do
						if ch:IsA("TextButton") then
							local lb = ch:FindFirstChildWhichIsA("TextLabel")
							local cb3 = ch:FindFirstChild("checkbox")
							if lb and cb3 then
								local on = sels[lb.Text] or false
								cb3.BackgroundColor3 = on and PALETTE.Accent or PALETTE.Toggle_Off
								local cmk = cb3:FindFirstChildWhichIsA("ImageLabel")
								if cmk then cmk.ImageTransparency = on and 0 or 1 end
								lb.TextColor3 = on and PALETTE.Text or PALETTE.TextDim
							end
						end
					end
					pcall(o.Callback or function() end, getList())
				end
				function obj:Get() return getList() end
				if o.Flag then W[o.Flag] = obj end
				return obj
			end

			-- ────────── KEYBIND ──────────
			function S:AddKeybind(o)
				o = o or {}
				local key = o.Default or Enum.KeyCode.Unknown
				local cb  = o.Callback or function() end
				local listening = false

				local c = create("Frame", { Size = UDim2.new(1, 0, 0, COMPONENT_HEIGHT), BackgroundTransparency = 1, Parent = items })

				local kb = create("TextButton", {
					Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = PALETTE.SurfaceLight,
					BackgroundTransparency = 0.5, BorderSizePixel = 0, Text = "",
					AutoButtonColor = false, Parent = c,
				})
				corner(kb, CORNER_SM)

				create("TextLabel", {
					Size = UDim2.new(0.6, 0, 1, 0), Position = UDim2.new(0, 10, 0, 0),
					BackgroundTransparency = 1, Text = o.Name or "Keybind",
					TextColor3 = PALETTE.Text, TextSize = 13, FontFace = FONT_MEDIUM,
					TextXAlignment = Enum.TextXAlignment.Left, Parent = kb,
				})

				local kl = create("TextLabel", {
					Size = UDim2.new(0, 0, 0, 22), AutomaticSize = Enum.AutomaticSize.X,
					Position = UDim2.new(1, -10, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5),
					BackgroundColor3 = PALETTE.Surface, BackgroundTransparency = 0.3,
					BorderSizePixel = 0,
					Text = key == Enum.KeyCode.Unknown and "..." or key.Name,
					TextColor3 = PALETTE.TextDim, TextSize = 11, FontFace = FONT_SEMI, Parent = kb,
				})
				corner(kl, CORNER_SM); pad(kl, 2, 8, 2, 8)

				kb.MouseButton1Click:Connect(function()
					if listening then return end
					listening = true; kl.Text = "..."; tw(kl, TWEEN_FAST, { TextColor3 = PALETTE.Accent })
					local conn
					conn = UserInputService.InputBegan:Connect(function(input)
						if input.UserInputType == Enum.UserInputType.Keyboard then
							listening = false; conn:Disconnect()
							if input.KeyCode == Enum.KeyCode.Escape then
								key = Enum.KeyCode.Unknown; kl.Text = "..."
							else
								key = input.KeyCode; kl.Text = input.KeyCode.Name
							end
							tw(kl, TWEEN_FAST, { TextColor3 = PALETTE.TextDim })
						end
					end)
				end)

				UserInputService.InputBegan:Connect(function(input, gpe)
					if gpe or listening then return end
					if input.KeyCode == key and key ~= Enum.KeyCode.Unknown then pcall(cb, key) end
				end)

				kb.MouseEnter:Connect(function() tw(kb, TWEEN_FAST, { BackgroundTransparency = 0.3 }) end)
				kb.MouseLeave:Connect(function() tw(kb, TWEEN_FAST, { BackgroundTransparency = 0.5 }) end)

				local obj = {}
				function obj:Set(k) key = k; kl.Text = k == Enum.KeyCode.Unknown and "..." or k.Name end
				function obj:Get() return key end
				if o.Flag then W[o.Flag] = obj end
				return obj
			end

			-- ────────── SEPARATOR ──────────
			function S:AddSeparator()
				create("Frame", {
					Size = UDim2.new(1, -8, 0, 1), BackgroundColor3 = PALETTE.Divider,
					BackgroundTransparency = 0.4, BorderSizePixel = 0, Parent = items,
				})
			end

			-- ────────── COLOR PICKER ──────────
			function S:AddColorPicker(o)
				o = o or {}
				local cpName = o.Name or "Color"
				local default = o.Default or PALETTE.Accent
				local cb = o.Callback or function() end
				local curColor = default
				local curH, curS, curV = default:ToHSV()
				local pickerOpen = false

				local c = create("Frame", {
					Size = UDim2.new(1, 0, 0, COMPONENT_HEIGHT),
					AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1, ClipsDescendants = false, Parent = items,
				})
				local cLayout = listLayout(c, 4); cLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

				-- Header row
				local hdr = create("TextButton", {
					Size = UDim2.new(1, 0, 0, COMPONENT_HEIGHT),
					BackgroundColor3 = PALETTE.SurfaceLight, BackgroundTransparency = 0.5,
					BorderSizePixel = 0, Text = "", AutoButtonColor = false, LayoutOrder = 0, Parent = c,
				})
				corner(hdr, CORNER_SM)

				create("TextLabel", {
					Size = UDim2.new(1, -46, 1, 0), Position = UDim2.new(0, 10, 0, 0),
					BackgroundTransparency = 1, Text = cpName,
					TextColor3 = PALETTE.Text, TextSize = 13, FontFace = FONT_MEDIUM,
					TextXAlignment = Enum.TextXAlignment.Left, Parent = hdr,
				})

				local swatch = create("Frame", {
					Name = "swatch",
					Size = UDim2.fromOffset(24, 24),
					Position = UDim2.new(1, -10, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5),
					BackgroundColor3 = curColor, BorderSizePixel = 0, Parent = hdr,
				})
				corner(swatch, CORNER_SM)
				stroke(swatch, PALETTE.Border, 1, 0.3)

				-- Picker panel
				local panel = create("Frame", {
					Name = "picker_panel",
					Size = UDim2.new(1, 0, 0, 0),
					BackgroundColor3 = PALETTE.Surface, BackgroundTransparency = 0.05,
					BorderSizePixel = 0, ClipsDescendants = true,
					Visible = false, LayoutOrder = 1, Parent = c,
				})
				corner(panel, CORNER_SM); stroke(panel, PALETTE.Border, 1, 0.5)

				local panelContent = create("Frame", {
					Size = UDim2.new(1, -16, 0, 140),
					Position = UDim2.new(0.5, 0, 0, 8), AnchorPoint = Vector2.new(0.5, 0),
					BackgroundTransparency = 1, Parent = panel,
				})

				-- Saturation-Value box (gradient canvas)
				local svBox = create("Frame", {
					Name = "sv_box",
					Size = UDim2.new(1, -28, 0, 100),
					BackgroundColor3 = Color3.fromHSV(curH, 1, 1),
					BorderSizePixel = 0, ClipsDescendants = true, Parent = panelContent,
				})
				corner(svBox, CORNER_SM)

				-- White → transparent (saturation gradient, left to right)
				create("UIGradient", {
					Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(255, 255, 255)),
					Transparency = NumberSequence.new(0, 1),
					Rotation = 0,
					Parent = svBox,
				})

				-- Overlay: black → transparent (value gradient, bottom to top)
				local valOverlay = create("Frame", {
					Size = UDim2.fromScale(1, 1),
					BackgroundColor3 = Color3.fromRGB(0, 0, 0),
					BorderSizePixel = 0, Parent = svBox,
				})
				create("UIGradient", {
					Color = ColorSequence.new(Color3.fromRGB(0, 0, 0), Color3.fromRGB(0, 0, 0)),
					Transparency = NumberSequence.new(1, 0),
					Rotation = 90,
					Parent = valOverlay,
				})

				-- SV cursor
				local svCursor = create("Frame", {
					Name = "sv_cursor",
					Size = UDim2.fromOffset(12, 12),
					Position = UDim2.new(curS, 0, 1 - curV, 0),
					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundColor3 = PALETTE.White, BackgroundTransparency = 0.1,
					BorderSizePixel = 0, ZIndex = 3, Parent = svBox,
				})
				corner(svCursor, CORNER_FULL)
				stroke(svCursor, Color3.fromRGB(0, 0, 0), 2, 0.3)

				-- Hue bar (vertical, right side)
				local hueBar = create("Frame", {
					Name = "hue_bar",
					Size = UDim2.new(0, 16, 0, 100),
					Position = UDim2.new(1, 0, 0, 0), AnchorPoint = Vector2.new(1, 0),
					BackgroundColor3 = PALETTE.White, BorderSizePixel = 0,
					ClipsDescendants = true, Parent = panelContent,
				})
				corner(hueBar, CORNER_SM)

				-- Rainbow gradient for hue
				create("UIGradient", {
					Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0.000, Color3.fromRGB(255, 0, 0)),
						ColorSequenceKeypoint.new(0.167, Color3.fromRGB(255, 255, 0)),
						ColorSequenceKeypoint.new(0.333, Color3.fromRGB(0, 255, 0)),
						ColorSequenceKeypoint.new(0.500, Color3.fromRGB(0, 255, 255)),
						ColorSequenceKeypoint.new(0.667, Color3.fromRGB(0, 0, 255)),
						ColorSequenceKeypoint.new(0.833, Color3.fromRGB(255, 0, 255)),
						ColorSequenceKeypoint.new(1.000, Color3.fromRGB(255, 0, 0)),
					}),
					Rotation = 90,
					Parent = hueBar,
				})

				-- Hue cursor
				local hueCursor = create("Frame", {
					Name = "hue_cursor",
					Size = UDim2.new(1, 4, 0, 6),
					Position = UDim2.new(0.5, 0, curH, 0),
					AnchorPoint = Vector2.new(0.5, 0.5),
					BackgroundColor3 = PALETTE.White,
					BorderSizePixel = 0, ZIndex = 3, Parent = hueBar,
				})
				corner(hueCursor, CORNER_FULL)
				stroke(hueCursor, Color3.fromRGB(0, 0, 0), 1, 0.4)

				-- RGB input row
				local rgbRow = create("Frame", {
					Size = UDim2.new(1, 0, 0, 26),
					Position = UDim2.new(0, 0, 0, 106),
					BackgroundTransparency = 1, Parent = panelContent,
				})

				local hexBox
				local function updateColor(h, s, v, fromInput)
					curH, curS, curV = h, s, v
					curColor = Color3.fromHSV(h, s, v)
					swatch.BackgroundColor3 = curColor
					svBox.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
					svCursor.Position = UDim2.new(s, 0, 1 - v, 0)
					hueCursor.Position = UDim2.new(0.5, 0, h, 0)
					if hexBox then
						hexBox.Text = string.format("#%02X%02X%02X",
							math.floor(curColor.R * 255 + 0.5),
							math.floor(curColor.G * 255 + 0.5),
							math.floor(curColor.B * 255 + 0.5))
					end
					if fromInput then pcall(cb, curColor) end
				end

				-- Hex label + input
				create("TextLabel", {
					Size = UDim2.new(0, 28, 1, 0),
					BackgroundTransparency = 1, Text = "HEX",
					TextColor3 = PALETTE.TextMuted, TextSize = 10, FontFace = FONT,
					TextXAlignment = Enum.TextXAlignment.Left, Parent = rgbRow,
				})

				local hexFrame = create("Frame", {
					Size = UDim2.new(1, -34, 1, 0), Position = UDim2.new(0, 34, 0, 0),
					BackgroundColor3 = PALETTE.SurfaceLight, BackgroundTransparency = 0.3,
					BorderSizePixel = 0, Parent = rgbRow,
				})
				corner(hexFrame, CORNER_SM)
				local hexStroke = stroke(hexFrame, PALETTE.Border, 1, 0.5)

				hexBox = create("TextBox", {
					Size = UDim2.new(1, -8, 1, 0), Position = UDim2.fromScale(0.5, 0.5),
					AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1,
					Text = string.format("#%02X%02X%02X",
						math.floor(curColor.R * 255 + 0.5),
						math.floor(curColor.G * 255 + 0.5),
						math.floor(curColor.B * 255 + 0.5)),
					PlaceholderText = "#FFFFFF", PlaceholderColor3 = PALETTE.TextMuted,
					TextColor3 = PALETTE.Text, TextSize = 12, FontFace = FONT_REGULAR,
					TextXAlignment = Enum.TextXAlignment.Left,
					ClearTextOnFocus = false, ClipsDescendants = true, Parent = hexFrame,
				})

				hexBox.Focused:Connect(function()
					tw(hexStroke, TWEEN_FAST, { Color = PALETTE.Accent, Transparency = 0 })
				end)
				hexBox.FocusLost:Connect(function()
					tw(hexStroke, TWEEN_FAST, { Color = PALETTE.Border, Transparency = 0.5 })
					local txt = hexBox.Text:gsub("#", "")
					if #txt == 6 then
						local r = tonumber(txt:sub(1, 2), 16)
						local g = tonumber(txt:sub(3, 4), 16)
						local b = tonumber(txt:sub(5, 6), 16)
						if r and g and b then
							local col = Color3.fromRGB(r, g, b)
							local h2, s2, v2 = col:ToHSV()
							updateColor(h2, s2, v2, true)
							return
						end
					end
					-- Revert if invalid
					hexBox.Text = string.format("#%02X%02X%02X",
						math.floor(curColor.R * 255 + 0.5),
						math.floor(curColor.G * 255 + 0.5),
						math.floor(curColor.B * 255 + 0.5))
				end)

				-- SV box interaction
				local function startSV(input)
					local function upd(pos)
						local rx = clamp01((pos.X - svBox.AbsolutePosition.X) / svBox.AbsoluteSize.X)
						local ry = clamp01((pos.Y - svBox.AbsolutePosition.Y) / svBox.AbsoluteSize.Y)
						updateColor(curH, rx, 1 - ry, true)
					end
					upd(input.Position)
					local mc, rc
					mc = UserInputService.InputChanged:Connect(function(mi)
						if mi.UserInputType == Enum.UserInputType.MouseMovement or mi.UserInputType == Enum.UserInputType.Touch then upd(mi.Position) end
					end)
					rc = UserInputService.InputEnded:Connect(function(ei)
						if ei.UserInputType == Enum.UserInputType.MouseButton1 or ei.UserInputType == Enum.UserInputType.Touch then mc:Disconnect(); rc:Disconnect() end
					end)
				end

				svBox.InputBegan:Connect(function(i)
					if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then startSV(i) end
				end)

				-- Hue bar interaction
				local function startHue(input)
					local function upd(pos)
						local ry = clamp01((pos.Y - hueBar.AbsolutePosition.Y) / hueBar.AbsoluteSize.Y)
						updateColor(ry, curS, curV, true)
					end
					upd(input.Position)
					local mc, rc
					mc = UserInputService.InputChanged:Connect(function(mi)
						if mi.UserInputType == Enum.UserInputType.MouseMovement or mi.UserInputType == Enum.UserInputType.Touch then upd(mi.Position) end
					end)
					rc = UserInputService.InputEnded:Connect(function(ei)
						if ei.UserInputType == Enum.UserInputType.MouseButton1 or ei.UserInputType == Enum.UserInputType.Touch then mc:Disconnect(); rc:Disconnect() end
					end)
				end

				hueBar.InputBegan:Connect(function(i)
					if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then startHue(i) end
				end)

				-- Toggle panel
				hdr.MouseButton1Click:Connect(function()
					pickerOpen = not pickerOpen
					if pickerOpen then
						panel.Visible = true
						tw(panel, TWEEN_SMOOTH, { Size = UDim2.new(1, 0, 0, 156) })
					else
						tw(panel, TWEEN_SMOOTH, { Size = UDim2.new(1, 0, 0, 0) })
						task.delay(0.35, function() if not pickerOpen then panel.Visible = false end end)
					end
				end)

				hdr.MouseEnter:Connect(function() tw(hdr, TWEEN_FAST, { BackgroundTransparency = 0.3 }) end)
				hdr.MouseLeave:Connect(function() tw(hdr, TWEEN_FAST, { BackgroundTransparency = 0.5 }) end)

				local obj = {}
				function obj:Set(col)
					local h2, s2, v2 = col:ToHSV()
					updateColor(h2, s2, v2, false)
				end
				function obj:Get() return curColor end
				if o.Flag then W[o.Flag] = obj end
				return obj
			end

			return S
		end

		table.insert(self.Tabs, T)
		if #self.Tabs == 1 then selectTab(T) end
		return T
	end

	-- ══════════════════════════════════════════════════
	--  Notification System
	-- ══════════════════════════════════════════════════

	local nc = create("Frame", {
		Name = "notifs", Size = UDim2.new(0, 260, 1, -60),
		Position = UDim2.new(1, -16, 0, 50), AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1, Parent = gui,
	})
	local nl = listLayout(nc, 6); nl.VerticalAlignment = Enum.VerticalAlignment.Bottom; nl.HorizontalAlignment = Enum.HorizontalAlignment.Right

	function W:Notify(o)
		o = o or {}
		local dur = o.Duration or 3
		local nType = (o.Type or "info"):lower()
		local ac = PALETTE.Accent
		if nType == "success" then ac = PALETTE.Success
		elseif nType == "error" then ac = PALETTE.Error
		elseif nType == "warning" then ac = Color3.fromRGB(220, 170, 40) end

		local nf = create("Frame", {
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = PALETTE.Surface, BackgroundTransparency = 1,
			BorderSizePixel = 0, ClipsDescendants = true, Parent = nc,
		})
		corner(nf, CORNER_MD); stroke(nf, PALETTE.Divider, 1, 0.4)

		create("Frame", { Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = ac, BorderSizePixel = 0, Parent = nf })

		local nfc = create("Frame", {
			Size = UDim2.new(1, -12, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
			Position = UDim2.new(0, 12, 0, 0), BackgroundTransparency = 1, Parent = nf,
		})
		pad(nfc, 8, 8, 8, 8); listLayout(nfc, 2)

		create("TextLabel", {
			Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1,
			Text = o.Title or "Notification", TextColor3 = PALETTE.Text,
			TextSize = 13, FontFace = FONT_SEMI, TextXAlignment = Enum.TextXAlignment.Left, Parent = nfc,
		})
		if (o.Message or "") ~= "" then
			create("TextLabel", {
				Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1, Text = o.Message,
				TextColor3 = PALETTE.TextDim, TextSize = 12, FontFace = FONT_REGULAR,
				TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true, Parent = nfc,
			})
		end

		local pb = create("Frame", {
			Size = UDim2.new(1, 0, 0, 2), Position = UDim2.new(0, 0, 1, 0),
			AnchorPoint = Vector2.new(0, 1), BackgroundColor3 = ac,
			BackgroundTransparency = 0.5, BorderSizePixel = 0, Parent = nf,
		})

		tw(nf, TWEEN_SMOOTH, { BackgroundTransparency = 0.05 })
		tw(pb, TweenInfo.new(dur, Enum.EasingStyle.Linear), { Size = UDim2.new(0, 0, 0, 2) })
		task.delay(dur, function()
			tw(nf, TWEEN_FAST, { BackgroundTransparency = 1 })
			task.delay(0.2, function() nf:Destroy() end)
		end)
	end

	function W:Destroy() gui:Destroy() end

	-- ═══════════  Theming API  ═══════════
	W._themeCallbacks = {}

	--- Apply a preset theme by name ("Dark", "Midnight", "Dimmed", "Light")
	--- or pass a custom base table. Preserves the current accent.
	function W:SetTheme(themeName)
		local base = THEME_PRESETS[themeName]
		if not base then warn("[blackwine] Unknown theme: " .. tostring(themeName)); return end
		local newP = buildPalette(base, PALETTE.Accent)
		for k, v in pairs(newP) do PALETTE[k] = v end
		self:_refreshTheme()
	end

	--- Change the accent color. Automatically updates AccentLight, AccentDark,
	--- Toggle_On, and SliderFill.
	function W:SetAccent(color)
		local al, ad = accentShade(color)
		PALETTE.Accent      = color
		PALETTE.AccentLight = al
		PALETTE.AccentDark  = ad
		PALETTE.Toggle_On   = color
		PALETTE.SliderFill  = color
		self:_refreshTheme()
	end

	--- Internal: re-skin the persistent chrome (topbar, sidebar, main frame).
	--- Components read PALETTE at interaction time, so they auto-pick up changes.
	function W:_refreshTheme()
		-- Main frame
		tw(main, TWEEN_SMOOTH, { BackgroundColor3 = PALETTE.Background })
		-- Topbar
		local tb = main:FindFirstChild("topbar")
		if tb then tw(tb, TWEEN_SMOOTH, { BackgroundColor3 = PALETTE.Surface }) end
		-- Sidebar
		local sb = content:FindFirstChild("sidebar")
		if sb then tw(sb, TWEEN_SMOOTH, { BackgroundColor3 = PALETTE.Surface }) end
		-- Accent dot
		if tb then
			local dot = tb:FindFirstChild("accent_dot")
			if dot then tw(dot, TWEEN_FAST, { BackgroundColor3 = PALETTE.Accent }) end
		end
		-- Tab sidebar indicators & active tab
		if self.ActiveTab then
			local at = self.ActiveTab
			if at._ind then tw(at._ind, TWEEN_FAST, { BackgroundColor3 = PALETTE.Accent }) end
		end
		-- Fire registered callbacks
		for _, fn in ipairs(self._themeCallbacks) do pcall(fn, PALETTE) end
	end

	--- Register a callback that fires whenever the theme or accent changes.
	function W:OnThemeChanged(fn)
		table.insert(self._themeCallbacks, fn)
	end

	-- ══════════════════════════════════════════════════
	--  CreateThemeTab — auto-generates a full theme editor tab
	-- ══════════════════════════════════════════════════

	function W:CreateThemeTab(tOpts)
		tOpts = tOpts or {}
		local tabName = tOpts.Name or "Theme"
		local tabIcon = tOpts.Icon or "rbxassetid://7734053495" -- palette icon

		local themeTab = self:CreateTab({ Name = tabName, Icon = tabIcon })

		-- ── Preset section (left) ──
		local presetSection = themeTab:AddSection({ Name = "Presets", Side = "left" })

		presetSection:AddLabel({ Text = "Select a base theme preset." })

		-- Determine current theme name
		local currentThemeName = "Dark"
		local themeNames = {}
		for name in pairs(THEME_PRESETS) do
			table.insert(themeNames, name)
		end
		table.sort(themeNames)

		local presetDrop = presetSection:AddDropdown({
			Name = "Base Theme",
			Items = themeNames,
			Default = currentThemeName,
			Callback = function(selected)
				self:SetTheme(selected)
			end,
		})

		presetSection:AddSeparator()
		presetSection:AddLabel({ Text = "Fine-tune accent colors below." })

		-- Accent-linked pickers
		local accentPickers = {}

		-- Define accent color entries
		local accentEntries = {
			{ key = "Accent",      name = "Accent" },
			{ key = "AccentLight", name = "Accent Light" },
			{ key = "AccentDark",  name = "Accent Dark" },
			{ key = "Toggle_On",   name = "Toggle On" },
			{ key = "SliderFill",  name = "Slider Fill" },
		}

		for _, entry in ipairs(accentEntries) do
			local picker = presetSection:AddColorPicker({
				Name = entry.name,
				Default = PALETTE[entry.key],
				Callback = function(col)
					PALETTE[entry.key] = col
					-- If main Accent changed, also update derived colors
					if entry.key == "Accent" then
						self:SetAccent(col)
					else
						self:_refreshTheme()
					end
				end,
			})
			accentPickers[entry.key] = picker
		end

		-- ── Surface section (left) ──
		local surfaceSection = themeTab:AddSection({ Name = "Surfaces", Side = "left" })
		surfaceSection:AddLabel({ Text = "Background and surface colors." })

		local surfacePickers = {}
		local surfaceEntries = {
			{ key = "Background",   name = "Background" },
			{ key = "Surface",      name = "Surface" },
			{ key = "SurfaceLight", name = "Surface Light" },
			{ key = "Divider",      name = "Divider" },
			{ key = "Border",       name = "Border" },
		}

		for _, entry in ipairs(surfaceEntries) do
			local picker = surfaceSection:AddColorPicker({
				Name = entry.name,
				Default = PALETTE[entry.key],
				Callback = function(col)
					PALETTE[entry.key] = col
					self:_refreshTheme()
				end,
			})
			surfacePickers[entry.key] = picker
		end

		-- ── Text section (right) ──
		local textSection = themeTab:AddSection({ Name = "Text", Side = "right" })
		textSection:AddLabel({ Text = "Text and label colors." })

		local textPickers = {}
		local textEntries = {
			{ key = "Text",     name = "Text" },
			{ key = "TextDim",  name = "Text Dim" },
			{ key = "TextMuted", name = "Text Muted" },
		}

		for _, entry in ipairs(textEntries) do
			local picker = textSection:AddColorPicker({
				Name = entry.name,
				Default = PALETTE[entry.key],
				Callback = function(col)
					PALETTE[entry.key] = col
					self:_refreshTheme()
				end,
			})
			textPickers[entry.key] = picker
		end

		-- ── Component section (right) ──
		local compSection = themeTab:AddSection({ Name = "Components", Side = "right" })
		compSection:AddLabel({ Text = "Toggle, slider, and status colors." })

		local compPickers = {}
		local compEntries = {
			{ key = "Toggle_Off",  name = "Toggle Off" },
			{ key = "SliderTrack", name = "Slider Track" },
			{ key = "Error",       name = "Error" },
			{ key = "Success",     name = "Success" },
			{ key = "White",       name = "White" },
		}

		for _, entry in ipairs(compEntries) do
			local picker = compSection:AddColorPicker({
				Name = entry.name,
				Default = PALETTE[entry.key],
				Callback = function(col)
					PALETTE[entry.key] = col
					self:_refreshTheme()
				end,
			})
			compPickers[entry.key] = picker
		end

		-- ── Sync function: updates all pickers to current PALETTE values ──
		local allPickers = {}
		for k, v in pairs(accentPickers)  do allPickers[k] = v end
		for k, v in pairs(surfacePickers) do allPickers[k] = v end
		for k, v in pairs(textPickers)    do allPickers[k] = v end
		for k, v in pairs(compPickers)    do allPickers[k] = v end

		self._themePickerSync = function()
			for key, picker in pairs(allPickers) do
				if PALETTE[key] then
					picker:Set(PALETTE[key])
				end
			end
		end

		-- Also sync when theme changes from external SetTheme/SetAccent calls
		self:OnThemeChanged(function()
			if self._themePickerSync then
				self._themePickerSync()
			end
		end)

		return themeTab
	end

	W._gui = gui; W._main = main
	return W
end

return BlackwineLib
