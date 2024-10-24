--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

------ Constants
local MAX_PARTICIPANTS = 50
local NUM_LEADERS = 5
local CHANGEUP_CD = 10

local AVOID_RADIUS = 5
local SQR_AVOID = AVOID_RADIUS * AVOID_RADIUS
local CHECK_RANGE = 20
local SQR_CHECK = CHECK_RANGE * CHECK_RANGE

local MAX_SPEED = 15

local COLOR_MODE: string | number = "leader"
local RAINBOW_HUE = 0
local RAINBOW_SPEED = 0.1

local rand = Random.new(1234)

------ Precalculated bounds definitions for efficiency
local bounds = {}
do
	local volume = workspace.Volume :: Part
	bounds.height = volume.Size.X
	bounds.radius = volume.Size.Y / 2
	bounds.center = volume.Position
	bounds.transDist = 5

	--Square calculations allow for easy distance comparisons while avoiding a square root operation
	bounds.sqrRadius = bounds.radius * bounds.radius
	bounds.sqrRadiusCheckDist = (bounds.radius - bounds.transDist) * (bounds.radius - bounds.transDist)
	bounds.sqrTransDist = bounds.transDist * bounds.transDist

	bounds.top = bounds.center.Y + bounds.height / 2
	bounds.bottom = bounds.center.Y - bounds.height / 2

	bounds.yMax = bounds.top - bounds.transDist
	bounds.yMin = bounds.bottom + bounds.transDist
end

----BoidMember class, would usually go in a different module

type BoidMemberImpl = {
	__index: BoidMemberImpl,
	new: (body: Part, isLeader: boolean) -> BoidMember,
	setLeader: (self: BoidMember, leader: BoidMember?) -> (),
}

type BoidMember = typeof(setmetatable(
	{} :: { body: Part, isLeader: boolean, leadBy: BoidMember? },
	{} :: BoidMemberImpl
))

local BoidMember: BoidMemberImpl = {} :: BoidMemberImpl
BoidMember.__index = BoidMember

function BoidMember.new(body: Part, isLeader: boolean)
	local self = {}
	self.body = body
	self.isLeader = isLeader
	self.leadBy = nil

	return setmetatable(self, BoidMember)
end

function BoidMember:setLeader(leader: BoidMember?)
	self.leadBy = leader

	if self.leadBy then
		--Match color to leader but a little lest bright
		local leaderHue = self.leadBy.body.Color:ToHSV()
		self.body.Color = Color3.fromHSV(leaderHue, 0.7, 1)
	else
		self.body.Color = Color3.fromHSV(rand:NextNumber(), 1, 1)
	end
end

--All boid members stored in this array for ease of access
local participants: { BoidMember } = {}

--leaders don't care for other boid members, they just wander
local function getLeaderHeading(current: BoidMember)
	local dir: Vector3 = current.body.CFrame.LookVector + rand:NextUnitVector() * 100

	return dir.Unit * MAX_SPEED
end

--For boid behavior each member has to have Separation, velocity matching and cohesion relative to the rest of the flock
local function getHeading(current: BoidMember)
	local dir, separation, matching, cohesion = Vector3.zero, Vector3.zero, Vector3.zero, Vector3.zero
	local numChecked = 0

	local offset: Vector3, sqrDistance: number = nil, nil
	for _, other: BoidMember in participants do
		if other ~= current then
			offset = other.body.Position - current.body.Position

			--Use squared distance to avoid expensive math.sqr
			sqrDistance = offset.X * offset.X + offset.Y * offset.Y + offset.Z * offset.Z

			--if checked member outside of distance then skip them
			if sqrDistance > SQR_CHECK then
				continue
			end
			numChecked += 1
			------Separation
			--Only avoid if inside set avoid distance
			if sqrDistance <= SQR_AVOID then
				separation -= offset
			end

			------Matching
			--Equate speed and heading to its flockmates
			--Add up all other velocities, we'll average it out later
			matching += other.body:GetAttribute("Velocity") :: Vector3

			------Cohesion
			--Try to go the center of the checked flockmates
			cohesion += offset
		end
	end

	--Vector3.zero checks to prevent a NaN error due to division by 0
	if separation ~= Vector3.zero then
		separation = separation / separation.Magnitude * MAX_SPEED
	end
	if matching ~= Vector3.zero then
		matching /= numChecked
		matching = matching / matching.Magnitude * MAX_SPEED
	end
	--If it's being lead by a specific leader try to follow them instead of the middle of the pack
	if current.leadBy ~= nil then
		cohesion = (current.leadBy.body.Position - current.body.Position).Unit * MAX_SPEED
	elseif cohesion ~= Vector3.zero then
		cohesion /= numChecked
		--target pos is now stored in cohesion
		cohesion = cohesion / cohesion.Magnitude * MAX_SPEED
	end
	--Weighting of different attributes
	dir = separation * 0.4 + matching * 0.3 + cohesion * 1

	return dir
end

local changeupTimer: number = CHANGEUP_CD
local function onUpdate(dt: number)
	--precalculate rainbow color in case it's needed for efficiency
	RAINBOW_HUE = (RAINBOW_HUE + RAINBOW_SPEED * dt) % 1
	local rainbowColor = if COLOR_MODE == "rainbow" then Color3.fromHSV(RAINBOW_HUE, 1, 1) else nil

	local velocity: Vector3 = nil
	--Iterate through every boid member to update their AI behavior
	for i, member: BoidMember in participants do
		local body = member.body
		velocity = body:GetAttribute("Velocity") :: Vector3

		---get the different steerings
		--differentiate between a leader and a member and call appropriate heading function
		local accel: Vector3 = if member.isLeader then getLeaderHeading(member) else getHeading(member)
		--Clamp velocity to the MAX_SPEED while maintaining direction
		velocity += accel * dt
		local speed = velocity.Magnitude
		local dir = velocity / speed
		speed = math.clamp(speed, 0.1, MAX_SPEED)
		velocity = dir * speed
		--print(i, accel, speed, velocity)

		body.CFrame = CFrame.lookAlong(body.Position + velocity * dt, velocity)

		body:SetAttribute("Velocity", velocity)

		--If boid member leaves the bounds of the Volume transport them to the opposite side, making an illusion of continuity
		if body.Position.Y > bounds.top then
			body.CFrame = body.CFrame - Vector3.new(0, bounds.height, 0)
		elseif body.Position.Y < bounds.bottom then
			body.CFrame = body.CFrame + Vector3.new(0, bounds.height, 0)
		end

		local radiusSqrDist = (body.Position.X * body.Position.X) + (body.Position.Z * body.Position.Z)
		if radiusSqrDist > bounds.sqrRadius then
			local pos2D = Vector3.new(body.Position.X, 0, body.Position.Z)
			-- elem.Position = Vector3.new(-pos2D.X,elem.Position.Y,-pos2D.Z)+pos2D.Unit*bounds.transDist
			body.CFrame = body.CFrame - pos2D.Unit * bounds.radius * 2
		end

		--As boid members approach the bounds of the volume make them transparent using a linear interpolation
		local transparencyFactor = 0

		if body.Position.Y < bounds.yMin then
			transparencyFactor = math.max(transparencyFactor, (bounds.yMin - body.Position.Y) / bounds.transDist)
		elseif body.Position.Y > bounds.yMax then
			transparencyFactor = math.max(transparencyFactor, (body.Position.Y - bounds.yMax) / bounds.transDist)
		end

		if radiusSqrDist > bounds.sqrRadiusCheckDist then
			transparencyFactor =
				math.max(transparencyFactor, (radiusSqrDist - bounds.sqrRadiusCheckDist) / bounds.sqrTransDist)
		end

		body.Transparency = transparencyFactor

		--if color mode is rainbow: update color
		if rainbowColor then
			member.body.Color = rainbowColor
		end
	end

	--Every CHANGEUP_CD seconds take a random amount of participants and either remove their leader if they already have one or set a random leader
	-- changeupTimer -= dt
	if changeupTimer <= 0 then
		--Only non leaders are eligible to be chosen
		local eligible: number = #participants - NUM_LEADERS
		if eligible > 0 then
			--math.min to ensure that we don't go out of bounds of the array
			for i = 1, rand:NextInteger(math.min(3, eligible), math.min(15, eligible)), 1 do
				local index = rand:NextInteger(1, eligible) + NUM_LEADERS
				local participant = participants[index]
				if participant.leadBy ~= nil then
					participant:setLeader(nil)
				else
					participant:setLeader(participants[rand:NextInteger(1, NUM_LEADERS)])
				end
			end
		end

		changeupTimer = CHANGEUP_CD
	end
end

---- Chat commands

--change the color mode of the boids
local function onColorCommand(textSource: TextSource, message: string)
	local arguments = string.split(message, " ")
	local predicate = arguments[2]

	--If no predicate then exit, also ensure predicate is lower case
	if not predicate then
		return
	end
	predicate = string.lower(predicate)

	--Different color modes for each command
	if predicate == "leader" then
		--Participants copy their leader color with slightly less saturation
		COLOR_MODE = "leader"
		for i, participant in participants do
			if i <= NUM_LEADERS then
				participant.body.Color = Color3.fromHSV(i / NUM_LEADERS, 1, 1)
			elseif participant.leadBy then
				local leaderHue = participant.leadBy.body.Color:ToHSV()
				participant.body.Color = Color3.fromHSV(leaderHue, 0.8, 1)
			end
		end
	elseif predicate == "random" then
		COLOR_MODE = "random"
		--Every participant gets a random color
		for _, participant in participants do
			participant.body.Color = Color3.fromHSV(rand:NextNumber(), 1, 1)
		end
	elseif predicate == "hue" then
		--Sets all of the participants' color to be the same
		local hue = tonumber(arguments[3])
		if hue then
			COLOR_MODE = hue
			for _, participant in participants do
				participant.body.Color = Color3.fromHSV(hue, 1, 1)
			end
		end
	elseif predicate == "rainbow" then
		COLOR_MODE = "rainbow"
		local speed = tonumber(arguments[3])
		if speed then
			RAINBOW_SPEED = speed
		end
	end
end

--Change the maximum speed of the boid members
local function onSpeedCommand(textSource: TextSource, message: string)
	local argument = string.split(message, " ")
	local num = tonumber(argument)
	if num then
		MAX_SPEED = num
	end
end

---- Connections
RunService.Heartbeat:Connect(onUpdate)
do
	local TextChatService = game:GetService("TextChatService")
	TextChatService:FindFirstChild("ColorCommand").Triggered:Connect(onColorCommand)
	TextChatService:FindFirstChild("SpeedCommand").Triggered:Connect(onSpeedCommand)
end

--Wait until place has loaded to start spawning the fireflies
task.delay(5, function()
	local firefly = ReplicatedStorage:WaitForChild("Firefly")
	--slowly fill up the whole array of participants
	while #participants < MAX_PARTICIPANTS do
		local curr = firefly:Clone() :: Part

		--Ensure that fireflies are elongated
		local sizeNum = rand:NextNumber(0.2, 0.4)
		curr.Size = Vector3.new(sizeNum, sizeNum, sizeNum * 1.8)

		--Randomize position and velocity within bounds
		curr.Position = rand:NextUnitVector() * rand:NextNumber(5, math.min(bounds.height, bounds.radius))
			+ bounds.center
		curr.Orientation = rand:NextUnitVector()
		curr:SetAttribute("Velocity", curr.Orientation * MAX_SPEED)

		curr.Parent = workspace

		--Only the first NUM_LEADERS of participants will be leaders, this way we know they're always at the start of the array
		local boidPart = BoidMember.new(curr, #participants < NUM_LEADERS)
		table.insert(participants, boidPart)
		if #participants > NUM_LEADERS then
			boidPart:setLeader(participants[#participants % NUM_LEADERS])
		end

		--Set its color depending on current mode
		if COLOR_MODE == "leader" then
			if #participants <= NUM_LEADERS then
				curr.Color = Color3.fromHSV((#participants / NUM_LEADERS), 1, 1)
			end
			--No need for else clause because their color has already been set with :setLeader
		elseif COLOR_MODE == "random" then
			curr.Color = Color3.fromHSV(rand:NextNumber(), 1, 1)
		elseif COLOR_MODE == "rainbow" then
			curr.Color = Color3.fromHSV(RAINBOW_HUE, 1, 1)
		else
			--Hue mode, the hue is encoded in the mode
			local hue = tonumber(COLOR_MODE)
			if not hue then
				warn("Hue mode but couldn't cast to number!")
				continue
			end
			curr.Color = Color3.fromHSV(hue, 1, 1)
		end

		task.wait(rand:NextNumber(0.3, 0.8))
	end
	print("Finished generating")
end)
