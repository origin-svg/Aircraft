local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer

local CONFIG = {
	DETECT_RANGE = 10000,
	MOUNT_NAME = "PTZCamera", AIRCRAFT_NAME = "Aircraft",
	SCAN_INTERVAL = 0.25, LOSE_MARGIN = 1.1,
	DWELL_TIME = 8, MIN_SHOT_TIME = 3.5, IDLE_RETURN_DELAY = 4,
	PRIORITY_HOLD = 6, PRIORITY_MAX = 12, PRIORITY_COOLDOWN = 6,
	PRIORITY_SPEED = 250, PRIORITY_ACCEL = 80, PRIORITY_SPIN = 60, TELEPORT_SPEED = 3000,
	PHASE_DETECTION = true, AGL_MAX = 600, PHASE_AGL = 250, ON_GROUND_FACTOR = 0.3,
	LAND_VY = 2, CLIMB_VY = 3, ROLL_SPEED = 35, PHASE_HOLD = 5, CRITICAL_MAX = 35, CRITICAL_COOLDOWN = 8,
	CHECK_OBSTRUCTION = true, BLOCK_GRACE = 1.2,
	FILL_FRACTION = 0.3, LEAD_ROOM = 0.6, ZOOM_DEADZONE = 0.12, ZOOM_FOLLOW = 1.5,
	REACQUIRE_FRACTION = 0.25, AIM_DEADZONE = 0.015,
	ONLY_TRACK_MOVING = false, MIN_TRACK_SPEED = 15, OVERLAY = true,
	PAN_SPEED = 140, TILT_SPEED = 100, IDLE_SPEED_SCALE = 0.35,
	ZOOM_IN_SPEED = 0.5, ZOOM_OUT_SPEED = 1.4, ZOOM_IN_ACCEL = 1.5, ZOOM_OUT_ACCEL = 4, ZOOM_DECEL = 3.5,
	PAN_ACCEL = 280, PAN_DECEL = 320, TILT_ACCEL = 240, TILT_DECEL = 280,
	TRACK_GAIN = 4, FEEDFORWARD_SMOOTH = 10, TARGET_SMOOTH = 0.06,
	TILT_MIN = -80, TILT_MAX = 80, PAN_RANGE = nil,
	MIN_FOV = 1, MAX_FOV = 70, START_FOV = 60,
	ONLY_USER_IDS = {},
	MAX_GRAPHICS = true, HIDE_CORE_UI = true, POST_FX = true, DEPTH_OF_FIELD = true,
	LETTERBOX = true, LETTERBOX_RATIO = 2.39, AIRCRAFT_DETAIL = true, STREAM_ASSIST = true,
}

if #CONFIG.ONLY_USER_IDS > 0 and not table.find(CONFIG.ONLY_USER_IDS, player.UserId) then
	return
end

while not workspace.CurrentCamera do
	task.wait()
end

local mount = workspace:FindFirstChild(CONFIG.MOUNT_NAME, true) or workspace:WaitForChild(CONFIG.MOUNT_NAME, 2)
local startCFrame
if mount and mount:IsA("PVInstance") then
	startCFrame = mount:GetPivot()
else
	mount = nil
	if not player.Character then
		player.CharacterAdded:Wait()
	end
	task.wait(0.3)
	startCFrame = workspace.CurrentCamera.CFrame
end

local camPos = startCFrame.Position
local startPitch, startYaw = startCFrame:ToOrientation()
local homeYaw = math.deg(startYaw)
local homePitch = math.clamp(math.deg(startPitch), CONFIG.TILT_MIN, CONFIG.TILT_MAX)
local logMin, logMax = math.log(CONFIG.MIN_FOV), math.log(CONFIG.MAX_FOV)
local homeLogFov = math.clamp(math.log(CONFIG.START_FOV), logMin, logMax)
local yaw, pitch, logFov = homeYaw, homePitch, homeLogFov
local yawVel, pitchVel, zoomVel, yawTgtF, pitchTgtF = 0, 0, 0, 0, 0
local yawMin = CONFIG.PAN_RANGE and homeYaw - CONFIG.PAN_RANGE
local yawMax = CONFIG.PAN_RANGE and homeYaw + CONFIG.PAN_RANGE

local aircraft = {}

local function qualifies(i)
	if not i:IsA("PVInstance") then
		return false
	end
	local p = i.Parent
	return i.Name == CONFIG.AIRCRAFT_NAME
		or CollectionService:HasTag(i, CONFIG.AIRCRAFT_NAME)
		or (p ~= nil and p:IsA("Folder") and p.Name == CONFIG.AIRCRAFT_NAME)
end

local function tuneAircraft(i)
	if not CONFIG.AIRCRAFT_DETAIL then
		return
	end
	pcall(function()
		if i:IsA("Model") then
			i.LevelOfDetail = Enum.ModelLevelOfDetail.Disabled
		end
		for _, d in ipairs(i:GetDescendants()) do
			if d:IsA("MeshPart") then
				d.RenderFidelity = Enum.RenderFidelity.Precise
			end
		end
		if i:IsA("MeshPart") then
			i.RenderFidelity = Enum.RenderFidelity.Precise
		end
	end)
end

local function register(i)
	if i == mount or not qualifies(i) then
		return
	end
	local a = i.Parent
	while a and a ~= workspace do
		if qualifies(a) then
			return
		end
		a = a.Parent
	end
	aircraft[i] = true
	tuneAircraft(i)
end

for _, i in ipairs(workspace:GetDescendants()) do
	register(i)
end
workspace.DescendantAdded:Connect(register)
workspace.DescendantRemoving:Connect(function(i)
	aircraft[i] = nil
end)
CollectionService:GetInstanceAddedSignal(CONFIG.AIRCRAFT_NAME):Connect(function(i)
	if i:IsDescendantOf(workspace) then
		register(i)
	end
end)

local function isValid(i)
	return i ~= nil and i.Parent ~= nil and i:IsDescendantOf(workspace)
end

local function sizeOf(i)
	local s = i:IsA("Model") and i:GetExtentsSize() or i.Size
	return math.max(s.X, s.Y, s.Z, 1)
end

local function angle(a, b)
	return math.deg(math.acos(math.clamp(a:Dot(b), -1, 1)))
end

local function wrap(a)
	return (a + 180) % 360 - 180
end

local filter = {}
local function newParams()
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.IgnoreWater = true
	return p
end
local groundParams, losParams = newParams(), newParams()

local function refreshFilters()
	table.clear(filter)
	for i in pairs(aircraft) do
		table.insert(filter, i)
	end
	if mount then
		table.insert(filter, mount)
	end
	if player.Character then
		table.insert(filter, player.Character)
	end
	groundParams.FilterDescendantsInstances = filter
end

local function obstructed(pos)
	local dist = (pos - camPos).Magnitude
	if dist < 8 or dist > 14000 then
		return false
	end
	local from = camPos + (pos - camPos) / dist * 3
	local list = table.clone(filter)
	for _ = 1, 4 do
		losParams.FilterDescendantsInstances = list
		local hit = workspace:Raycast(from, pos - from, losParams)
		if not hit then
			return false
		end
		if hit.Instance:IsA("BasePart") and hit.Instance.Transparency >= 0.9 then
			table.insert(list, hit.Instance)
		else
			return true
		end
	end
	return false
end

local target, isPriority = nil, false
local priorityStart, switchTime, lastScan, lastTargetTime = 0, 0, 0, -math.huge
local leadVec, zoomGoal = Vector3.zero, nil
local prevYaw, prevPitch, ffYaw, ffPitch = nil, nil, 0, 0
local weak = { __mode = "k" }
local lastTracked, motion, sizeCache = setmetatable({}, weak), setmetatable({}, weak), setmetatable({}, weak)
local holdLevel, holdUntil = setmetatable({}, weak), setmetatable({}, weak)
local cooldownUntil, blockedSince = setmetatable({}, weak), setmetatable({}, weak)
local PHASE_WEIGHT = { landing = 3, takeoff = 2.5, roll = 2 }

local function updateMotion(inst, now)
	local cf = inst:GetPivot()
	local m = motion[inst]
	if not m then
		m = { pos = cf.Position, vel = Vector3.zero, look = cf.LookVector, up = cf.UpVector, t = now, speed = 0, accel = 0, spin = 0, ready = false }
		motion[inst] = m
		return m
	end
	local dt = now - m.t
	if dt < 0.05 then
		return m
	end
	local raw = (cf.Position - m.pos) / dt
	if raw.Magnitude > CONFIG.TELEPORT_SPEED then
		m.vel, m.speed, m.accel, m.spin, m.ready = Vector3.zero, 0, 0, 0, false
	else
		local nv = m.ready and m.vel:Lerp(raw, 0.6) or raw
		m.accel = m.ready and (nv - m.vel).Magnitude / dt or 0
		m.vel, m.speed = nv, nv.Magnitude
		m.spin = math.max(angle(m.look, cf.LookVector), angle(m.up, cf.UpVector)) / dt
		m.ready = true
	end
	m.pos, m.look, m.up, m.t = cf.Position, cf.LookVector, cf.UpVector, now
	return m
end

local function activity(m)
	if m.ready and (m.speed >= CONFIG.PRIORITY_SPEED or m.accel >= CONFIG.PRIORITY_ACCEL or m.spin >= CONFIG.PRIORITY_SPIN) then
		return 1, m.speed / CONFIG.PRIORITY_SPEED + m.accel / CONFIG.PRIORITY_ACCEL + m.spin / CONFIG.PRIORITY_SPIN
	end
	return 0, 0
end

local function phaseOf(m, size, pos)
	if not (CONFIG.PHASE_DETECTION and m.ready) then
		return nil
	end
	local hit = workspace:Raycast(pos, Vector3.new(0, -CONFIG.AGL_MAX, 0), groundParams)
	if not hit then
		return nil
	end
	local agl = pos.Y - hit.Position.Y
	if agl <= size * CONFIG.ON_GROUND_FACTOR + 4 then
		return m.speed >= CONFIG.ROLL_SPEED and "roll" or nil
	end
	if agl <= CONFIG.PHASE_AGL then
		if m.vel.Y <= -CONFIG.LAND_VY then
			return "landing"
		end
		if m.vel.Y >= CONFIG.CLIMB_VY then
			return "takeoff"
		end
	end
	return nil
end

local function rotationScore(c, now)
	local m = c.m
	local score = math.min((now - (lastTracked[c.inst] or -math.huge)) / CONFIG.DWELL_TIME, 3)
		+ 1 - math.min(c.dist / CONFIG.DETECT_RANGE, 1)
	if m.ready then
		score += m.speed < 2 and -1.5 or 0.5
		local toCam = camPos - m.pos
		if toCam.Magnitude > 1 and m.vel:Dot(toCam.Unit) > 5 then
			score += 0.5
		end
	end
	return score
end

local function setTarget(inst, now, priority)
	if inst ~= target then
		prevYaw, prevPitch, ffYaw, ffPitch, leadVec, zoomGoal = nil, nil, 0, 0, Vector3.zero, nil
	end
	if priority and (inst ~= target or not isPriority) then
		priorityStart = now
	end
	target, isPriority, switchTime = inst, priority and inst ~= nil, now
	if inst then
		lastTracked[inst] = now
	end
end

local function selectTarget(now)
	local range = CONFIG.DETECT_RANGE
	refreshFilters()

	if isPriority and isValid(target) then
		local critical = (holdLevel[target] or 0) >= 2
		if now - priorityStart >= (critical and CONFIG.CRITICAL_MAX or CONFIG.PRIORITY_MAX) then
			cooldownUntil[target] = now + (critical and CONFIG.CRITICAL_COOLDOWN or CONFIG.PRIORITY_COOLDOWN)
			holdUntil[target], isPriority, switchTime = 0, false, -math.huge
		end
	end

	local candidates, candMap = {}, {}
	for inst in pairs(aircraft) do
		if not isValid(inst) then
			aircraft[inst] = nil
		else
			local pos = inst:GetPivot().Position
			local dist = (pos - camPos).Magnitude
			if dist <= range then
				local size = sizeOf(inst)
				sizeCache[inst] = size
				local m = updateMotion(inst, now)
				local live, score = activity(m)
				local phase = phaseOf(m, size, pos)
				if phase then
					live, score = 2, PHASE_WEIGHT[phase] + 1 - dist / range
				end
				if live > 0 then
					local held = (holdUntil[inst] or 0) > now and holdLevel[inst] or 0
					holdLevel[inst] = math.max(live, held)
					holdUntil[inst] = now + (live >= 2 and CONFIG.PHASE_HOLD or CONFIG.PRIORITY_HOLD)
				end

				local blocked = false
				if CONFIG.CHECK_OBSTRUCTION then
					if obstructed(pos) then
						blockedSince[inst] = blockedSince[inst] or now
						blocked = now - blockedSince[inst] >= CONFIG.BLOCK_GRACE
					else
						blockedSince[inst] = nil
					end
				end

				local level = (holdUntil[inst] or 0) > now and holdLevel[inst] or 0
				if blocked or (cooldownUntil[inst] or 0) > now then
					level = 0
				end
				if not (CONFIG.ONLY_TRACK_MOVING and level == 0 and m.ready and m.speed < CONFIG.MIN_TRACK_SPEED) then
					local c = { inst = inst, dist = dist, level = level, score = score, blocked = blocked, m = m }
					table.insert(candidates, c)
					candMap[inst] = c
				end
			end
		end
	end

	local cur = isValid(target) and candMap[target] or nil
	if isPriority and not (cur and cur.level > 0) then
		isPriority = false
	end

	local bestP
	for _, c in ipairs(candidates) do
		if c.level > 0 and (not bestP or c.level * 1e6 + c.score > bestP.level * 1e6 + bestP.score) then
			bestP = c
		end
	end

	if bestP then
		if not cur or (bestP.level > cur.level and (cur.blocked or now - switchTime >= CONFIG.MIN_SHOT_TIME)) then
			setTarget(bestP.inst, now, true)
			return
		elseif cur.level > 0 then
			if not isPriority then
				isPriority, priorityStart = true, now
			end
			return
		end
	end

	local needNew = not isValid(target)
	if not needNew then
		local dist = (target:GetPivot().Position - camPos).Magnitude
		if dist > range * CONFIG.LOSE_MARGIN or (dist <= range and not cur) then
			needNew = true
		elseif cur and cur.blocked then
			for _, c in ipairs(candidates) do
				if c.inst ~= target and not c.blocked then
					needNew = true
					break
				end
			end
		end
		if #candidates > 1 and now - switchTime >= CONFIG.DWELL_TIME then
			needNew = true
		end
	end
	if not needNew then
		return
	end

	local best, bestScore = nil, -math.huge
	for _, c in ipairs(candidates) do
		if c.inst ~= target or #candidates == 1 then
			local sc = rotationScore(c, now) - (c.blocked and 100 or 0)
			if sc > bestScore then
				best, bestScore = c.inst, sc
			end
		end
	end
	setTarget(best, now, false)
end

local function stepVel(vel, goal, accel, decel, dt)
	local up = math.abs(goal) > math.abs(vel) and (vel == 0 or math.sign(goal) == math.sign(vel))
	local d, step = goal - vel, (up and accel or decel) * dt
	return math.abs(d) <= step and goal or vel + math.sign(d) * step
end

local function limitSpeed(pos, speed, lo, hi, decel)
	if speed > 0 and hi then
		return math.min(speed, math.sqrt(2 * decel * math.max(hi - pos, 0)))
	elseif speed < 0 and lo then
		return -math.min(-speed, math.sqrt(2 * decel * math.max(pos - lo, 0)))
	end
	return speed
end

local function axisStep(pos, vel, tgt, lo, hi, accel, decel, dt)
	return limitSpeed(pos, stepVel(vel, limitSpeed(pos, tgt, lo, hi, decel), accel, decel, dt), lo, hi, decel)
end

local function clampAxis(pos, vel, lo, hi)
	if lo and pos < lo then
		return lo, 0
	end
	if hi and pos > hi then
		return hi, 0
	end
	return pos, vel
end

local function trackSpeed(err, decel)
	return math.sign(err) * math.min(CONFIG.TRACK_GAIN * math.abs(err), math.sqrt(2 * decel * math.abs(err)))
end

local function deadzone(err, dz)
	return math.sign(err) * math.max(math.abs(err) - dz, 0)
end

local label
if CONFIG.OVERLAY then
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "AircraftOverlay", false, 50
	gui.Parent = player:WaitForChild("PlayerGui")
	label = Instance.new("TextLabel")
	label.Position, label.Size = UDim2.fromOffset(24, 20), UDim2.fromOffset(340, 50)
	label.BackgroundTransparency, label.TextColor3, label.TextStrokeTransparency = 1, Color3.new(1, 1, 1), 0.6
	label.Font, label.TextSize, label.RichText = Enum.Font.GothamBold, 22, true
	label.TextXAlignment, label.TextYAlignment = Enum.TextXAlignment.Left, Enum.TextYAlignment.Top
	label.Visible = false
	label.Parent = gui
end

local lastOverlay = 0

local function numAttr(inst, a, b)
	local v = inst:GetAttribute(a)
	if type(v) ~= "number" and b then
		v = inst:GetAttribute(b)
	end
	return type(v) == "number" and v or nil
end

local function updateOverlay(now)
	if not label or now - lastOverlay < 0.1 then
		return
	end
	lastOverlay = now
	label.Visible = isValid(target)
	if not label.Visible then
		return
	end

	local m = motion[target]
	local title = tostring(target:GetAttribute("Callsign") or target.Name)
	local kind = target:GetAttribute("Type") or target:GetAttribute("Model")
	if kind ~= nil then
		title ..= "  " .. tostring(kind)
	end
	local alt = numAttr(target, "Altitude", "Alt") or target:GetPivot().Position.Y
	local spd = numAttr(target, "Speed", "Velocity") or (m and m.ready and m.speed or nil)
	local hdg = numAttr(target, "Heading")
	if not hdg and m and m.ready and m.speed > 5 then
		hdg = math.deg(math.atan2(m.vel.X, -m.vel.Z)) % 360
	end

	local data = string.format("ALT %.0f", alt)
	if spd then
		data ..= string.format("   SPD %.0f", spd)
	end
	if hdg then
		data ..= string.format("   HDG %03.0f°", hdg)
	end
	label.Text = title .. '\n<font size="15">' .. data .. "</font>"
end

local function makeEffect(className, props)
	local e = Instance.new(className)
	e.Name = "Spotter" .. className
	for k, v in pairs(props) do
		e[k] = v
	end
	e.Parent = Lighting
	return e
end

if CONFIG.MAX_GRAPHICS then
	pcall(function()
		UserSettings():GetService("UserGameSettings").SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel10
	end)
end

if CONFIG.HIDE_CORE_UI then
	UserInputService.MouseIconEnabled = false
	task.spawn(function()
		for _ = 1, 5 do
			pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.All, false)
			task.wait(2)
		end
	end)
end

if CONFIG.POST_FX then
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.2
	Lighting.EnvironmentSpecularScale = 1
	Lighting.EnvironmentDiffuseScale = 1
	makeEffect("ColorCorrectionEffect", { Contrast = 0.1, Saturation = 0.12, TintColor = Color3.fromRGB(255, 250, 244) })
	makeEffect("BloomEffect", { Intensity = 0.3, Size = 24, Threshold = 1.6 })
	makeEffect("SunRaysEffect", { Intensity = 0.1, Spread = 0.7 })
end

local dof
if CONFIG.DEPTH_OF_FIELD then
	dof = makeEffect("DepthOfFieldEffect", { Enabled = false, FocusDistance = 200, InFocusRadius = 40, NearIntensity = 0.8, FarIntensity = 0.4 })
end

local barTop, barBottom
if CONFIG.LETTERBOX then
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder, gui.IgnoreGuiInset = "SpotterBars", false, 40, true
	gui.Parent = player:WaitForChild("PlayerGui")
	local function bar(anchorY)
		local f = Instance.new("Frame")
		f.AnchorPoint, f.Position = Vector2.new(0, anchorY), UDim2.fromScale(0, anchorY)
		f.BackgroundColor3, f.BorderSizePixel = Color3.new(0, 0, 0), 0
		f.Parent = gui
		return f
	end
	barTop, barBottom = bar(0), bar(1)
end

local visible, lastVp, lastStream = 1, Vector2.zero, 0

local function update(dt)
	dt = math.min(dt, 1 / 20)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	if cam.CameraType ~= Enum.CameraType.Scriptable then
		cam.CameraType = Enum.CameraType.Scriptable
	end
	if mount and mount.Parent then
		camPos = mount:GetPivot().Position
	end

	local vp = cam.ViewportSize
	if barTop and vp ~= lastVp and vp.Y > 0 then
		lastVp = vp
		local barH = math.max(0, 0.5 * (1 - vp.X / vp.Y / CONFIG.LETTERBOX_RATIO))
		barTop.Size, barBottom.Size = UDim2.fromScale(1, barH), UDim2.fromScale(1, barH)
		visible = 1 - 2 * barH
	end

	local now = os.clock()
	if now - lastScan >= CONFIG.SCAN_INTERVAL then
		lastScan = now
		selectTarget(now)
	end

	local fov = math.exp(logFov)
	local yawErr, pitchErr, zoomErr, speedScale = 0, 0, 0, 1

	if isValid(target) then
		lastTargetTime = now
		local offset = target:GetPivot().Position - camPos
		local dist = math.max(offset.Magnitude, 1)
		local los = offset / dist
		local size = sizeCache[target] or sizeOf(target)

		if dof then
			dof.Enabled = true
			dof.FocusDistance += (dist - dof.FocusDistance) * math.min(1, dt * 3)
			dof.InFocusRadius = math.max(size * 1.5, dist * 0.1)
		end
		if CONFIG.STREAM_ASSIST and workspace.StreamingEnabled and now - lastStream > 3 then
			lastStream = now
			task.spawn(pcall, player.RequestStreamAroundAsync, player, target:GetPivot().Position, 1)
		end

		local m = motion[target]
		local lead = Vector3.zero
		if m and m.ready and m.speed > 8 then
			local perp = m.vel - los * m.vel:Dot(los)
			local pm = perp.Magnitude
			if pm > 1 then
				lead = perp / pm * size * CONFIG.LEAD_ROOM * math.min(pm / 60, 1)
			end
		end
		leadVec = leadVec:Lerp(lead, math.min(1, dt * 2.5))

		local aim = offset + leadVec
		local d = aim / math.max(aim.Magnitude, 1e-3)
		local rawYaw = math.deg(math.atan2(-d.X, -d.Z))
		local rawPitch = math.deg(math.asin(math.clamp(d.Y, -1, 1)))

		if prevYaw then
			local k = math.min(1, dt * CONFIG.FEEDFORWARD_SMOOTH)
			ffYaw += (wrap(rawYaw - prevYaw) / dt - ffYaw) * k
			ffPitch += ((rawPitch - prevPitch) / dt - ffPitch) * k
		end
		prevYaw, prevPitch = rawYaw, rawPitch

		local ref = CONFIG.PAN_RANGE and homeYaw or yaw
		yawErr = ref + wrap(rawYaw - ref) - yaw
		pitchErr = math.clamp(rawPitch, CONFIG.TILT_MIN, CONFIG.TILT_MAX) - pitch

		local cp = math.cos(math.rad(pitch))
		local look = Vector3.new(-math.sin(math.rad(yaw)) * cp, math.sin(math.rad(pitch)), -math.cos(math.rad(yaw)) * cp)
		local errAngle = angle(look, d)

		local dz = fov * visible * CONFIG.AIM_DEADZONE
		yawErr, pitchErr = deadzone(yawErr, dz), deadzone(pitchErr, dz)

		local logWant = math.log(math.clamp(math.deg(2 * math.atan(size / 2 / dist)) / (CONFIG.FILL_FRACTION * visible), CONFIG.MIN_FOV, CONFIG.MAX_FOV))
		if not zoomGoal then
			zoomGoal = logWant
		elseif math.abs(logWant - zoomGoal) > CONFIG.ZOOM_DEADZONE then
			zoomGoal += (logWant - zoomGoal) * math.min(1, dt * CONFIG.ZOOM_FOLLOW)
		end

		local need = (errAngle + math.sqrt(ffYaw ^ 2 + ffPitch ^ 2) * 0.1) / (CONFIG.REACQUIRE_FRACTION * visible)
		zoomErr = math.max(zoomGoal, math.log(math.clamp(need, CONFIG.MIN_FOV, CONFIG.MAX_FOV))) - logFov
	else
		ffYaw, ffPitch, prevYaw, prevPitch, zoomGoal = 0, 0, nil, nil, nil
		if dof then
			dof.Enabled = false
		end
		if now - lastTargetTime >= CONFIG.IDLE_RETURN_DELAY then
			speedScale = CONFIG.IDLE_SPEED_SCALE
			yawErr = CONFIG.PAN_RANGE and homeYaw - yaw or wrap(homeYaw - yaw)
			pitchErr, zoomErr = homePitch - pitch, homeLogFov - logFov
		end
	end

	local panMax, tiltMax = CONFIG.PAN_SPEED * speedScale, CONFIG.TILT_SPEED * speedScale
	local yawTarget = math.clamp(trackSpeed(yawErr, CONFIG.PAN_DECEL) + ffYaw, -panMax, panMax)
	local pitchTarget = math.clamp(trackSpeed(pitchErr, CONFIG.TILT_DECEL) + ffPitch, -tiltMax, tiltMax)
	local smooth = 1 - math.exp(-dt / CONFIG.TARGET_SMOOTH)
	yawTgtF += (yawTarget - yawTgtF) * smooth
	pitchTgtF += (pitchTarget - pitchTgtF) * smooth

	local zoomOut = zoomErr > 0
	local zoomMax = (zoomOut and CONFIG.ZOOM_OUT_SPEED or CONFIG.ZOOM_IN_SPEED) * speedScale
	local zoomAccel = zoomOut and CONFIG.ZOOM_OUT_ACCEL or CONFIG.ZOOM_IN_ACCEL
	local zoomTarget = math.clamp(trackSpeed(zoomErr, CONFIG.ZOOM_DECEL), -zoomMax, zoomMax)

	yawVel = axisStep(yaw, yawVel, yawTgtF, yawMin, yawMax, CONFIG.PAN_ACCEL, CONFIG.PAN_DECEL, dt)
	pitchVel = axisStep(pitch, pitchVel, pitchTgtF, CONFIG.TILT_MIN, CONFIG.TILT_MAX, CONFIG.TILT_ACCEL, CONFIG.TILT_DECEL, dt)
	zoomVel = axisStep(logFov, zoomVel, zoomTarget, logMin, logMax, zoomAccel, CONFIG.ZOOM_DECEL, dt)

	yaw += yawVel * dt
	pitch += pitchVel * dt
	logFov += zoomVel * dt
	yaw, yawVel = clampAxis(yaw, yawVel, yawMin, yawMax)
	pitch, pitchVel = clampAxis(pitch, pitchVel, CONFIG.TILT_MIN, CONFIG.TILT_MAX)
	logFov, zoomVel = clampAxis(logFov, zoomVel, logMin, logMax)

	cam.CFrame = CFrame.new(camPos) * CFrame.Angles(0, math.rad(yaw), 0) * CFrame.Angles(math.rad(pitch), 0, 0)
	cam.Focus = cam.CFrame * CFrame.new(0, 0, -20)
	cam.FieldOfView = math.exp(logFov)

	updateOverlay(now)
end

RunService:BindToRenderStep("AircraftSpotter", Enum.RenderPriority.Camera.Value + 1, update)
