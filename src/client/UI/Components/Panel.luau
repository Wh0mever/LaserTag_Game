--!nonstrict
--[[
	Panel.luau
	Titled window used by every menu screen: dimmed backdrop, drop shadow, title
	bar with a close button, and a content frame for the screen to fill.

	props = {
		title: string,
		parent: Instance,              -- required, normally a ScreenGui from UIController
		size: UDim2?,                  -- body size; default UDim2.fromScale(0.52, 0.62)
		position: UDim2?,              -- body position; default centred
		anchorPoint: Vector2?,         -- default Vector2.new(0.5, 0.5)
		subtitle: string?,             -- small dim line under the title
		accentColor: Color3?,          -- title underline / stroke tint
		showOverlay: boolean?,         -- default true; dims the rest of the screen
		closeOnOverlay: boolean?,      -- default true; clicking the backdrop closes
		name: string?,
		onClose: (() -> ())?,          -- called after :close() finishes tweening out
	}

	Returns an object:
		.instance      Frame (full-screen root; toggle this to show/hide everything)
		.body          Frame (the window itself)
		.content       Frame (put your children in here)
		.titleBar      Frame
		:open()
		:close()                  -- tweens out, then hides. Never destroys.
		:isOpen(): boolean
		:setTitle(text)
		:setSubtitle(text)
		:asMenuHandle()           -- {open, close, isOpen} for UIController.registerMenu
		:destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Button = require(script.Parent.Button)
local Trove = require(Shared.Util.Trove)
local UITheme = require(script.Parent.Parent.UITheme)

local Panel = {}
Panel.__index = Panel

local DEFAULT_SIZE = UDim2.fromScale(0.52, 0.62)
local TITLE_BAR_HEIGHT = 52
local CLOSED_SCALE = 0.92
local OVERLAY_TRANSPARENCY = 0.45
local SHADOW_TRANSPARENCY = 0.6
local SHADOW_SPREAD = 14
local SHADOW_GROWTH = Vector2.new(SHADOW_SPREAD * 2, SHADOW_SPREAD * 2)
local MIN_BODY_SIZE = Vector2.new(280, 220)
local MAX_BODY_SIZE = Vector2.new(820, 640)

function Panel.create(props: { [string]: any })
	assert(type(props) == "table", "Panel.create expects a props table")
	assert(typeof(props.parent) == "Instance", "Panel.create requires props.parent")

	local accent = props.accentColor or UITheme.Colors.Accent
	local trove = Trove.new()

	local root = Instance.new("Frame")
	root.Name = props.name or `{props.title or "Panel"}Panel`
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Visible = false

	local overlay = Instance.new("TextButton")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = UITheme.Colors.Background
	overlay.BackgroundTransparency = OVERLAY_TRANSPARENCY
	overlay.BorderSizePixel = 0
	overlay.AutoButtonColor = false
	overlay.Text = ""
	overlay.ZIndex = 1
	overlay.Visible = props.showOverlay ~= false
	overlay.Active = props.showOverlay ~= false
	overlay.Parent = root

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.Size = props.size or DEFAULT_SIZE
	body.Position = props.position or UDim2.fromScale(0.5, 0.5)
	body.AnchorPoint = props.anchorPoint or Vector2.new(0.5, 0.5)
	body.BackgroundColor3 = UITheme.Colors.Panel
	body.BorderSizePixel = 0
	body.ZIndex = 3
	body.Parent = root
	UITheme.corner(UITheme.Radius.Large).Parent = body
	UITheme.stroke(UITheme.Colors.Stroke, 1.5).Parent = body

	-- Keeps a menu usable on a phone without letting it balloon on ultrawide.
	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MinSize = MIN_BODY_SIZE
	sizeConstraint.MaxSize = MAX_BODY_SIZE
	sizeConstraint.Parent = body

	local shadow = UITheme.dropShadow(body, SHADOW_SPREAD, SHADOW_TRANSPARENCY)
	shadow.ZIndex = 2
	-- The shadow is a sibling, so it needs the same clamp or it would keep
	-- growing past the body once UISizeConstraint kicks in on a large viewport.
	local shadowConstraint = Instance.new("UISizeConstraint")
	shadowConstraint.MinSize = MIN_BODY_SIZE + SHADOW_GROWTH
	shadowConstraint.MaxSize = MAX_BODY_SIZE + SHADOW_GROWTH
	shadowConstraint.Parent = shadow

	local bodyScale = Instance.new("UIScale")
	bodyScale.Name = "OpenScale"
	bodyScale.Scale = CLOSED_SCALE
	bodyScale.Parent = body

	-- The shadow is a sibling, so it does not inherit the body's open scale and
	-- needs its own copy to stay glued to the window while it animates.
	local shadowScale = Instance.new("UIScale")
	shadowScale.Name = "OpenScale"
	shadowScale.Scale = CLOSED_SCALE
	shadowScale.Parent = shadow

	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, TITLE_BAR_HEIGHT)
	titleBar.BackgroundTransparency = 1
	titleBar.ZIndex = 3
	titleBar.Parent = body
	UITheme.padding(18, 10).Parent = titleBar

	local titleLabel =
		UITheme.label(props.title or "", UITheme.TextSizes.Title, UITheme.Colors.Text, UITheme.Fonts.Heading)
	titleLabel.Name = "Title"
	titleLabel.Size = UDim2.new(1, -48, props.subtitle and 0.62 or 1, 0)
	titleLabel.ZIndex = 3
	titleLabel.Parent = titleBar

	local subtitleLabel = UITheme.label(props.subtitle or "", UITheme.TextSizes.Small, UITheme.Colors.TextDim)
	subtitleLabel.Name = "Subtitle"
	subtitleLabel.AnchorPoint = Vector2.new(0, 1)
	subtitleLabel.Position = UDim2.fromScale(0, 1)
	subtitleLabel.Size = UDim2.new(1, -48, 0.38, 0)
	subtitleLabel.Visible = props.subtitle ~= nil and props.subtitle ~= ""
	subtitleLabel.ZIndex = 3
	subtitleLabel.Parent = titleBar

	local underline = Instance.new("Frame")
	underline.Name = "Underline"
	underline.AnchorPoint = Vector2.new(0.5, 0)
	underline.Position = UDim2.new(0.5, 0, 0, TITLE_BAR_HEIGHT)
	underline.Size = UDim2.new(1, -36, 0, 2)
	underline.BackgroundColor3 = accent
	underline.BorderSizePixel = 0
	underline.ZIndex = 3
	underline.Parent = body
	UITheme.gradient(accent, UITheme.Colors.AccentAlt, 0).Parent = underline

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Position = UDim2.new(0, 0, 0, TITLE_BAR_HEIGHT + 8)
	content.Size = UDim2.new(1, 0, 1, -(TITLE_BAR_HEIGHT + 8))
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.ZIndex = 3
	content.ClipsDescendants = true
	content.Parent = body
	UITheme.padding(18, 14).Parent = content

	local self = setmetatable({
		instance = root,
		body = body,
		content = content,
		titleBar = titleBar,
		titleLabel = titleLabel,
		subtitleLabel = subtitleLabel,
		_trove = trove,
		_scale = bodyScale,
		_shadow = shadow,
		_shadowScale = shadowScale,
		_overlay = overlay,
		_open = false,
		_closeTween = nil,
		_onClose = props.onClose,
	}, Panel)

	self.closeButton = Button.create({
		name = "Close",
		text = "",
		icon = "✕",
		size = UDim2.fromOffset(32, 32),
		position = UDim2.new(1, -14, 0, 10),
		anchorPoint = Vector2.new(1, 0),
		color = UITheme.Colors.PanelLight,
		parent = body,
		onActivated = function()
			self:close()
		end,
	})
	self.closeButton.instance.ZIndex = 4
	trove:Add(function()
		self.closeButton:destroy()
	end)

	if props.closeOnOverlay ~= false then
		trove:Connect(overlay.Activated, function()
			self:close()
		end)
	end

	trove:Add(root)
	root.Parent = props.parent

	return self
end

function Panel:isOpen(): boolean
	return self._open
end

function Panel:open()
	if self._open then
		return
	end
	self._open = true

	if self._closeTween then
		self._closeTween:Cancel()
		self._closeTween = nil
	end

	self.instance.Visible = true
	self._scale.Scale = CLOSED_SCALE
	self._shadowScale.Scale = CLOSED_SCALE
	self._overlay.BackgroundTransparency = 1

	TweenService:Create(self._scale, UITheme.Tween.Pop, { Scale = 1 }):Play()
	TweenService:Create(self._shadowScale, UITheme.Tween.Pop, { Scale = 1 }):Play()
	TweenService:Create(self._shadow, UITheme.Tween.Normal, {
		BackgroundTransparency = SHADOW_TRANSPARENCY,
	}):Play()
	TweenService:Create(self._overlay, UITheme.Tween.Normal, {
		BackgroundTransparency = OVERLAY_TRANSPARENCY,
	}):Play()
end

--[[
	Tweens out and then hides. The instances are kept so reopening keeps scroll
	position and any list the screen already built.
]]
function Panel:close()
	if not self._open then
		return
	end
	-- Flipped before the tween so UIController.isAnyMenuOpen() (and therefore the
	-- mouse lock) reacts immediately rather than after the animation.
	self._open = false

	TweenService:Create(self._overlay, UITheme.Tween.Exit, { BackgroundTransparency = 1 }):Play()
	TweenService:Create(self._shadow, UITheme.Tween.Exit, { BackgroundTransparency = 1 }):Play()
	TweenService:Create(self._shadowScale, UITheme.Tween.Exit, { Scale = CLOSED_SCALE }):Play()

	local tween = TweenService:Create(self._scale, UITheme.Tween.Exit, { Scale = CLOSED_SCALE })
	self._closeTween = tween
	tween.Completed:Once(function(state: Enum.PlaybackState)
		self._closeTween = nil
		if state ~= Enum.PlaybackState.Completed or self._open then
			return
		end
		self.instance.Visible = false
		if self._onClose then
			self._onClose()
		end
	end)
	tween:Play()
end

function Panel:setTitle(text: string)
	self.titleLabel.Text = text or ""
end

function Panel:setSubtitle(text: string?)
	self.subtitleLabel.Text = text or ""
	self.subtitleLabel.Visible = text ~= nil and text ~= ""
end

--[[
	The {open, close, isOpen} shape UIController.registerMenu expects.
]]
function Panel:asMenuHandle()
	return {
		open = function()
			self:open()
		end,
		close = function()
			self:close()
		end,
		isOpen = function()
			return self:isOpen()
		end,
	}
end

function Panel:destroy()
	self._trove:Clean()
end

return Panel
