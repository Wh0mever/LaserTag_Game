--!nonstrict
--[[
	Icon.luau
	Icons drawn out of Frames.

	WHY NOT SVG, WHICH IS WHAT WAS ASKED FOR. Roblox has no vector image format
	at all. A picture in a GUI is an ImageLabel pointing at `rbxassetid://…` — an
	uploaded raster that has to clear moderation and belongs to whoever's account
	uploaded it. This game deliberately ships no image assets: `rojo build` on a
	fresh clone produces a complete, playable place, and that stops being true the
	moment the interface depends on files living in somebody's inventory.

	The other option is a font glyph, and this project has already decided
	against that where it matters: the hamburger toggle is three Frames precisely
	because the one control a player must be able to find is not the place to
	gamble on Gotham carrying U+2630.

	So the icons are geometry. Each is a list of rectangles — position, size,
	rotation, all as fractions of the icon's box — which is as close to a vector
	drawing as the engine allows, scales to any size, needs no upload, and cannot
	render as tofu.

	Shapes are centred: `x`/`y` are the centre of the rectangle, not its corner,
	because every one of these is built by reflecting parts around the middle and
	corner coordinates make that arithmetic unreadable.
]]

local Icon = {}

--[[
	`round` marks a rectangle that should be drawn as a circle or a pill, and
	`hollow` one that is an outline rather than a fill. Everything else is a
	plain bar, which most of these are made of.
]]
export type Shape = {
	x: number,
	y: number,
	w: number,
	h: number,
	rot: number?,
	round: boolean?,
	hollow: boolean?,
}

local function bar(x: number, y: number, w: number, h: number, rot: number?): Shape
	return { x = x, y = y, w = w, h = h, rot = rot }
end

--[[
	An arc approximated by short tangential bars.

	Roblox can draw a rounded rectangle and nothing else, so a curve has to be
	made of straight pieces. Eight of them over 280 degrees reads as a circle at
	icon size, and the gap left by stopping short of 360 is where the arrowhead
	goes — which is what makes it a RELOAD symbol rather than a ring.
]]
local function arc(
	cx: number,
	cy: number,
	radius: number,
	fromDeg: number,
	toDeg: number,
	count: number,
	thickness: number
): { Shape }
	local shapes = {}
	local step = (toDeg - fromDeg) / (count - 1)

	for index = 0, count - 1 do
		local deg = fromDeg + step * index
		local rad = math.rad(deg)
		table.insert(
			shapes,
			bar(
				cx + math.cos(rad) * radius,
				cy + math.sin(rad) * radius,
				-- Long enough to overlap its neighbour, or the arc reads as a
				-- dotted line rather than a stroke.
				radius * 0.62,
				thickness,
				-- Tangent to the circle at this point.
				deg + 90
			)
		)
	end

	return shapes
end

--[[
	A chevron: two bars meeting at a point, which is how every arrowhead here is
	made. `dir` is the direction the point faces, in degrees.
]]
local function chevron(x: number, y: number, size: number, thickness: number, dir: number): { Shape }
	return {
		bar(
			x - math.cos(math.rad(dir)) * size * 0.25,
			y - math.sin(math.rad(dir)) * size * 0.25,
			size,
			thickness,
			dir + 45
		),
		bar(
			x - math.cos(math.rad(dir)) * size * 0.25,
			y - math.sin(math.rad(dir)) * size * 0.25,
			size,
			thickness,
			dir - 45
		),
	}
end

local function concat(...): { Shape }
	local out = {}
	for _, list in { ... } do
		for _, shape in list do
			table.insert(out, shape)
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- The icons
--------------------------------------------------------------------------------

local T = 0.11 -- stroke thickness shared by the line-drawn icons

Icon.SHAPES = {
	--[[
		Fire: a crosshair. Four ticks around a centre dot — the same mark the HUD
		puts in the middle of the screen, so the control and the thing it aims
		read as one idea.
	]]
	crosshair = {
		bar(0.5, 0.15, T, 0.24),
		bar(0.5, 0.85, T, 0.24),
		bar(0.15, 0.5, 0.24, T),
		bar(0.85, 0.5, 0.24, T),
		{ x = 0.5, y = 0.5, w = 0.18, h = 0.18, round = true },
	},

	-- Reload: an arrow chasing its own tail.
	reload = concat(arc(0.5, 0.5, 0.3, 120, 400, 8, T), chevron(0.28, 0.30, 0.26, T, 300)),

	--[[
		Switch weapon: two arrows passing each other. Not a picture of a gun —
		which at this size would be a smudge — but of the exchange.
	]]
	swap = concat({
		bar(0.46, 0.33, 0.52, T),
		bar(0.54, 0.67, 0.52, T),
	}, chevron(0.72, 0.33, 0.24, T, 0), chevron(0.28, 0.67, 0.24, T, 180)),

	--[[
		View: an eye. A hollow pill for the lid and a filled disc for the pupil;
		the engine's rounded rectangle cannot make the pointed corners of a real
		eye, and at 40 pixels nobody misses them.
	]]
	eye = {
		{ x = 0.5, y = 0.5, w = 0.86, h = 0.5, round = true, hollow = true },
		{ x = 0.5, y = 0.5, w = 0.26, h = 0.26, round = true },
	},
}

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

--[[
	Draws `name` into `parent`, filling it. Returns the number of pieces drawn,
	which is what tests assert on: an icon that silently drew nothing looks
	exactly like a button whose label was removed and never replaced.
]]
function Icon.draw(parent: Instance, name: string, color: Color3, thickness: number?): number
	local shapes = Icon.SHAPES[name]
	if not shapes then
		warn(`[Icon] unknown icon "{tostring(name)}"`)
		return 0
	end

	local holder = Instance.new("Frame")
	holder.Name = "Icon"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	-- Square, and sized off the smaller edge, so an icon in a non-square box is
	-- not stretched into a different shape.
	holder.Size = UDim2.fromScale(0.52, 0.52)
	holder.SizeConstraint = Enum.SizeConstraint.RelativeYY
	holder.BackgroundTransparency = 1
	holder.Active = false
	holder.Parent = parent

	for index, shape in shapes do
		local piece = Instance.new("Frame")
		piece.Name = `Piece{index}`
		piece.AnchorPoint = Vector2.new(0.5, 0.5)
		piece.Position = UDim2.fromScale(shape.x, shape.y)
		piece.Size = UDim2.fromScale(shape.w, shape.h)
		piece.Rotation = shape.rot or 0
		piece.BorderSizePixel = 0
		piece.Active = false

		if shape.hollow then
			piece.BackgroundTransparency = 1
			local stroke = Instance.new("UIStroke")
			stroke.Color = color
			stroke.Thickness = thickness or 2
			stroke.Parent = piece
		else
			piece.BackgroundColor3 = color
		end

		-- Rounded on everything, not just the circles: a bar with square ends
		-- looks like a crack at this size.
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(if shape.round then 1 else 0.5, 0)
		corner.Parent = piece

		piece.Parent = holder
	end

	return #shapes
end

return Icon
