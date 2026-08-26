--!nonstrict
--[[
	UITheme.luau
	The single palette every client screen draws from. Nothing here touches
	remotes or state — it is pure styling, so a screen can require it from its
	module body without ordering concerns.

	Shared config modules store colours as plain {r, g, b} tables so they stay
	Roblox-free and testable; `fromRGB` is the one conversion point between that
	representation and Color3.
]]

local UITheme = {}

--[[
	Palette. Dark charcoal surfaces, near-white text, neon cyan/purple accents.
	Team colours are mirrored from Constants.TEAMS via fromRGB at the bottom of
	this file so the HUD can never drift from the in-world team colours.
]]
UITheme.Colors = {
	Background = Color3.fromRGB(14, 15, 20), -- full-screen dim behind menus
	Panel = Color3.fromRGB(26, 28, 36),
	PanelLight = Color3.fromRGB(38, 41, 52),
	PanelDark = Color3.fromRGB(20, 21, 28),

	Text = Color3.fromRGB(245, 246, 250),
	TextDim = Color3.fromRGB(150, 156, 172),
	TextMuted = Color3.fromRGB(104, 110, 126),

	Accent = Color3.fromRGB(0, 224, 255), -- cyan: primary action / selection
	AccentAlt = Color3.fromRGB(167, 96, 255), -- purple: secondary highlight
	Positive = Color3.fromRGB(45, 216, 129),
	Negative = Color3.fromRGB(235, 70, 90),
	Warning = Color3.fromRGB(255, 168, 46),
	Coin = Color3.fromRGB(255, 199, 44),

	Stroke = Color3.fromRGB(66, 72, 92),
	Shadow = Color3.fromRGB(0, 0, 0),
	Disabled = Color3.fromRGB(58, 61, 72),

	TeamA = Color3.fromRGB(45, 216, 129),
	TeamB = Color3.fromRGB(235, 87, 158),
}

UITheme.Fonts = {
	Heading = Enum.Font.GothamBlack,
	Body = Enum.Font.Gotham,
	Bold = Enum.Font.GothamBold,
	Number = Enum.Font.RobotoMono,
}

UITheme.TextSizes = {
	Display = 34,
	Title = 26,
	Heading = 20,
	Subtitle = 17,
	Body = 15,
	Small = 13,
	Tiny = 11,
}

UITheme.Radius = {
	Small = 6,
	Medium = 10,
	Large = 16,
	Pill = 999,
}

-- Shared tween timings. Menus use Pop (a slight overshoot reads as "physical");
-- hover/press states use Fast so the UI never feels laggy under a 60 Hz cursor.
UITheme.Tween = {
	Fast = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Normal = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Pop = TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	Exit = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
	Count = TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
}

--[[
	Converts a shared-config colour table into a Color3. Accepts both the keyed
	form ({r = 45, g = 216, b = 129}) used by Constants/SkinCatalog and the plain
	array form, and falls back to Text so a malformed config tints something
	visible instead of erroring inside a UI build.
]]
function UITheme.fromRGB(rgbTable: any): Color3
	if typeof(rgbTable) == "Color3" then
		return rgbTable
	end
	if type(rgbTable) ~= "table" then
		return UITheme.Colors.Text
	end

	local r = rgbTable.r or rgbTable[1] or 255
	local g = rgbTable.g or rgbTable[2] or 255
	local b = rgbTable.b or rgbTable[3] or 255
	return Color3.fromRGB(r, g, b)
end

--[[
	Team id -> HUD colour. Unknown ids (including "LOBBY") fall back to TextDim
	so lobby chips read as neutral rather than borrowing a team's colour.
]]
function UITheme.teamColor(teamId: string?): Color3
	if teamId == "A" then
		return UITheme.Colors.TeamA
	elseif teamId == "B" then
		return UITheme.Colors.TeamB
	end
	return UITheme.Colors.TextDim
end

function UITheme.corner(radius: number?): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or UITheme.Radius.Medium)
	return corner
end

function UITheme.stroke(color: Color3?, thickness: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or UITheme.Colors.Stroke
	stroke.Thickness = thickness or 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	-- Round joins so the stroke follows a sibling UICorner instead of cutting
	-- square notches at the four corners.
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	return stroke
end

--[[
	Uniform padding. Pass a second value for a different vertical inset.
]]
function UITheme.padding(px: number, vertical: number?): UIPadding
	local horizontalUDim = UDim.new(0, px)
	local verticalUDim = UDim.new(0, vertical or px)

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = horizontalUDim
	padding.PaddingRight = horizontalUDim
	padding.PaddingTop = verticalUDim
	padding.PaddingBottom = verticalUDim
	return padding
end

function UITheme.gradient(c1: Color3, c2: Color3, rotation: number?): UIGradient
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(c1, c2)
	gradient.Rotation = rotation or 90
	return gradient
end

--[[
	Fake drop shadow. There are no image assets in this project, so the shadow is
	a dark slab sitting slightly outside `target` and offset downwards.

	It is created as a SIBLING of the target, not a child: under
	ZIndexBehavior.Sibling a descendant always draws on top of its parent, so a
	child could never appear behind it. The caller still owns the ZIndex ordering
	between the two — set the target above the returned frame.

	`spread` is how many pixels the shadow grows on every side.
]]
function UITheme.dropShadow(target: GuiObject, spread: number?, transparency: number?): Frame
	local grow = spread or 10

	local shadow = Instance.new("Frame")
	shadow.Name = "DropShadow"
	shadow.AnchorPoint = target.AnchorPoint
	shadow.Position = target.Position + UDim2.fromOffset(0, math.floor(grow * 0.5))
	shadow.Size = target.Size + UDim2.fromOffset(grow * 2, grow * 2)
	shadow.BackgroundColor3 = UITheme.Colors.Shadow
	shadow.BackgroundTransparency = transparency or 0.62
	shadow.BorderSizePixel = 0
	shadow.ZIndex = math.max(target.ZIndex - 1, 0)
	UITheme.corner(UITheme.Radius.Large + grow).Parent = shadow

	shadow.Parent = target.Parent
	return shadow
end

--[[
	Convenience label factory used by every component in this folder. Keeps
	BackgroundTransparency/BorderSizePixel defaults in one place instead of six.
]]
function UITheme.label(text: string, size: number?, color: Color3?, font: Enum.Font?): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Text = text
	label.TextSize = size or UITheme.TextSizes.Body
	label.TextColor3 = color or UITheme.Colors.Text
	label.Font = font or UITheme.Fonts.Body
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	return label
end

return UITheme
