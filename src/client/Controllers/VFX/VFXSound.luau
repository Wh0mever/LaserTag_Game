--!nonstrict
--[[
	VFXSound.luau
	Every sound the combat feel depends on, in two flavours:

	  * 2D — things that happen TO the local player (their own shot, their
	    reload, a hitmarker). One pre-built Sound per key, restarted on each
	    play, so a 600 RPM burst allocates nothing.
	  * positional — things that happen somewhere in the world (another player's
	    shot, an impact). Those Sounds live on the pooled part the effect already
	    owns, so they are pooled for free.

	The source table is NOT here: VFXController owns it, because that is the file
	a developer opens looking for "where do the asset ids go". This module takes
	it via `setup` and never assumes what is in it.

	Helper module for VFXController: no init/start, so the Loader leaves it alone.
]]

local SoundService = game:GetService("SoundService")

local VFXSound = {}

local sources: { [string]: { id: string, volume: number, speed: number, jitter: number } } = {}
local group: SoundGroup? = nil
local flat: { [string]: Sound } = {}

--[[
	Stamp a source definition onto a Sound. Returns false for an unknown key so
	callers can skip playing rather than play silence.
]]
function VFXSound.configure(sound: Sound, key: string): boolean
	local def = sources[key]
	if not def then
		return false
	end

	sound.SoundId = def.id
	sound.Volume = def.volume
	-- Pitch jitter is what stops a sustained burst turning into a machine tone:
	-- identical samples fired 100 ms apart phase-lock and buzz.
	sound.PlaybackSpeed = def.speed + (math.random() - 0.5) * 2 * def.jitter
	return true
end

--[[
	A positional Sound parented to `parent`, ready to be configured and played.
	Built once per pooled effect instance, never per shot.
]]
function VFXSound.positional(parent: Instance, minDistance: number, maxDistance: number): Sound
	local sound = Instance.new("Sound")
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = minDistance
	sound.RollOffMaxDistance = maxDistance
	sound.SoundGroup = group
	sound.Parent = parent
	return sound
end

--[[
	Play a positional Sound that `positional` created. No-op for an unknown key.
]]
function VFXSound.playAt(sound: Sound, key: string)
	if VFXSound.configure(sound, key) then
		sound.TimePosition = 0
		sound:Play()
	end
end

--[[
	Play the shared 2D Sound for `key`. Restarting an already-playing Sound is
	deliberate: overlapping copies of the same short stinger just smear it.
]]
function VFXSound.playLocal(key: string)
	local sound = flat[key]
	if not sound then
		return
	end

	VFXSound.configure(sound, key)
	sound.TimePosition = 0
	sound:Play()
end

--[[
	Whether a key has a sound behind it.

	playLocal returns silently for an unknown key, which is right at runtime — a
	missing sound should never interrupt a fight — but it also means a weapon
	added without one fires mutely and nothing says so. This is what lets that be
	checked instead of discovered.
]]
function VFXSound.has(key: string): boolean
	return flat[key] ~= nil
end

function VFXSound.getGroup(): SoundGroup?
	return group
end

--[[
	Build the SoundGroup and one 2D Sound per source. Yields nothing, but is
	called from VFXController.start() rather than init() because it creates a
	dozen instances and boot order should not pay for that.
]]
function VFXSound.setup(soundSources: { [string]: any }): SoundGroup
	VFXSound.teardown()
	sources = soundSources

	local created = Instance.new("SoundGroup")
	created.Name = "LaserTagSFX"
	created.Volume = 1
	created.Parent = SoundService
	group = created

	for key in sources do
		local sound = Instance.new("Sound")
		sound.Name = key
		sound.SoundGroup = created
		VFXSound.configure(sound, key)
		sound.Parent = created
		flat[key] = sound
	end

	return created
end

function VFXSound.teardown()
	table.clear(flat)
	if group then
		group:Destroy()
	end
	group = nil
end

return VFXSound
