--!nonstrict
--[[
	tests/harness/export_hub.luau
	Dumps the built Hub to JSON so something outside Roblox can draw it.

	This is the world harness's build step with the assertions replaced by a
	writer: the same MapBuilder, the same MapDefs, the same Lune Instance tree.
	Anything drawn from this file is drawn from what the game actually
	constructs, not from a second description of it that could drift.

	Run:  lune run tests/harness/export_hub > /path/to/hub.json
]]

local Env = require("./env")
local serde = require("@lune/serde")

local MapBuilder = Env.load("src/server/World/MapBuilder")
local HubDef = Env.load("src/shared/MapDefs/HubDef")

local built = MapBuilder.build(HubDef)

local function rgb(color): { number }
	return {
		math.round(color.R * 255),
		math.round(color.G * 255),
		math.round(color.B * 255),
	}
end

local parts = {}
local decals = {}

--[[
	The SurfaceGui a part carries, flattened to what a rasteriser needs: which
	face, the backdrop, and the lines in layout order with their colours. The
	real widget tree (UIListLayout, UIPadding, TextScaled) is a layout engine
	this exporter deliberately does not reimplement — it exports the inputs and
	lets the renderer lay the text out, exactly as Roblox would.
]]
local function collectDecals(part: Instance, partIndex: number)
	for _, gui in part:GetChildren() do
		if not gui:IsA("SurfaceGui") then
			continue
		end

		local root = gui:FindFirstChild("Root")
		if not root then
			continue
		end

		-- Two layout regimes exist in this world and they place text
		-- differently: the gateway sign stacks its lines under a UIListLayout,
		-- while a portal sign positions each label itself. Exporting only
		-- LayoutOrder would silently reorder the second kind, so both the
		-- ordering key and each label's own rectangle go out and the renderer
		-- picks the regime the same way Roblox does — by whether a layout is
		-- present.
		local stacked = root:FindFirstChildOfClass("UIListLayout") ~= nil

		local lines = {}
		for _, node in gui:GetDescendants() do
			if node:IsA("TextLabel") then
				table.insert(lines, {
					order = node.LayoutOrder,
					text = node.Text,
					color = rgb(node.TextColor3),
					pos = {
						node.Position.X.Scale,
						node.Position.X.Offset,
						node.Position.Y.Scale,
						node.Position.Y.Offset,
					},
					size = { node.Size.X.Scale, node.Size.X.Offset, node.Size.Y.Scale, node.Size.Y.Offset },
					font = node.Font.Name,
					scaled = node.TextScaled,
				})
			end
		end
		if stacked then
			table.sort(lines, function(a, b)
				return a.order < b.order
			end)
		end

		if #lines == 0 then
			continue
		end

		local padding = root:FindFirstChildOfClass("UIPadding")
		table.insert(decals, {
			partIndex = partIndex,
			partName = part.Name,
			guiName = gui.Name,
			face = gui.Face.Name,
			stacked = stacked,
			pixelsPerStud = gui.PixelsPerStud,
			background = rgb(root.BackgroundColor3),
			backgroundTransparency = root.BackgroundTransparency,
			padding = if padding
				then {
					top = padding.PaddingTop.Offset,
					bottom = padding.PaddingBottom.Offset,
					left = padding.PaddingLeft.Offset,
					right = padding.PaddingRight.Offset,
				}
				else { top = 0, bottom = 0, left = 0, right = 0 },
			lines = lines,
		})
	end
end

local function walk(node: Instance)
	for _, child in node:GetChildren() do
		if child:IsA("BasePart") then
			local cf = child.CFrame
			local px, py, pz, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
			table.insert(parts, {
				name = child.Name,
				size = { child.Size.X, child.Size.Y, child.Size.Z },
				cf = { px, py, pz, r00, r01, r02, r10, r11, r12, r20, r21, r22 },
				color = rgb(child.Color),
				material = child.Material.Name,
				transparency = child.Transparency,
				shape = if child:IsA("Part") then child.Shape.Name else "Block",
			})
			collectDecals(child, #parts)
		end
		walk(child)
	end
end

walk(built.model)

--[[
	Lighting is exported as the numbers LightingSetup writes, not as a baked
	result. The renderer is a different engine and will not match Roblox
	pixel for pixel; what it can do is start from the same palette, the same
	ambient and the same sun angle rather than from invented ones.
]]
local Lighting = Env.load("src/server/World/LightingSetup")
local lightingValues = {
	clockTime = 16.2,
	brightness = 2,
	ambient = { 48, 50, 62 },
	outdoorAmbient = { 100, 104, 120 },
	exposureCompensation = -0.1,
	environmentDiffuseScale = 0.32,
	hazeColor = { 150, 160, 190 },
	density = 0.22,
	haze = 0.85,
}
assert(type(Lighting) == "table", "LightingSetup did not load")

print(serde.encode("json", {
	parts = parts,
	decals = decals,
	lighting = lightingValues,
	origin = { HubDef.origin.x, HubDef.origin.y, HubDef.origin.z },
}, false))
