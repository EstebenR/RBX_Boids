--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MAX_PARTICIPANTS = 50
local NUM_LEADERS = 5
local CHANGEUP_CD = 10

local AVOID_RADIUS = 5
local SQR_AVOID = AVOID_RADIUS * AVOID_RADIUS
local CHECK_RANGE = 20
local SQR_CHECK = CHECK_RANGE * CHECK_RANGE

local MAX_SPEED = 15

local rand = Random.new(1234)

local bounds = {}
do
	local volume = workspace.Volume :: Part
	bounds.height = volume.Size.X
	bounds.radius = volume.Size.Y / 2
	bounds.center = volume.Position
	bounds.transDist = 10
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

local participants: { BoidMember } = {}

--leaders don't care for other boid members, they just wander
local function getLeaderHeading(current: BoidMember)
	local dir: Vector3 = current.body.CFrame.LookVector + rand:NextUnitVector() * 100

	return dir.Unit * MAX_SPEED
end

--Separation, velocity matching and cohesion
local function getHeading(current: BoidMember)
	local dir, separation, matching, cohesion = Vector3.zero, Vector3.zero, Vector3.zero, Vector3.zero
	local numChecked = 0

	local offset: Vector3, sqrDistance: number = nil, nil
	for _, other: BoidMember in participants do
		if other ~= current then
			offset = other.body.Position - current.body.Position

			--Use squared distance to avoid expensive math.sqr
			sqrDistance = offset.X * offset.X + offset.Y * offset.Y + offset.Z * offset.Z

			if sqrDistance > SQR_CHECK then
				continue
			end
			numChecked += 1
			------Separation
			--Only avoid if inside set distance
			if sqrDistance <= SQR_AVOID then
				separation -= offset
			end

			------Matching
			--Add up all other velocities, we'll average it out later
			matching += other.body:GetAttribute("Velocity") :: Vector3

			------Cohesion
			--Get the center of the checked flockmates if not lead by anybody
			if not current.leadBy then
				cohesion += offset
			end
		end
	end

	if separation ~= Vector3.zero then
		separation = separation / separation.Magnitude * MAX_SPEED
	end
	if matching ~= Vector3.zero then
		matching /= numChecked
		matching = matching / matching.Magnitude * MAX_SPEED
	end
	if current.leadBy ~= nil then
		cohesion = (current.leadBy.body.Position - current.body.Position).Unit * MAX_SPEED
	elseif cohesion ~= Vector3.zero then
		cohesion /= numChecked
		--target pos is now stored in cohesion
		cohesion = cohesion / cohesion.Magnitude * MAX_SPEED
	end
	--Weighting
	dir = separation * 0.4 + matching * 0.3 + cohesion * 1

	return dir
end

local changeupTimer: number = CHANGEUP_CD
local function onUpdate(dt: number)
	local velocity: Vector3 = nil
	for i, member: BoidMember in participants do
		local body = member.body
		velocity = body:GetAttribute("Velocity") :: Vector3

		---get the different steerings
		local accel: Vector3 = if member.isLeader then getLeaderHeading(member) else getHeading(member)
		velocity += accel * dt
		local speed = velocity.Magnitude
		local dir = velocity / speed
		speed = math.clamp(speed, 0.1, MAX_SPEED)
		velocity = dir * speed
		--print(i, accel, speed, velocity)

		body.CFrame = CFrame.lookAlong(body.Position + velocity * dt, velocity)

		body:SetAttribute("Velocity", velocity)

		--keep in bounds
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

		--Fancy color checks
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
	end

	-- changeupTimer -= dt
	if changeupTimer <= 0 then
		local eligible: number = #participants - NUM_LEADERS
		if eligible > 0 then
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

RunService.Heartbeat:Connect(onUpdate)

task.wait(5)
--Spawner
task.spawn(function()
	local firefly = ReplicatedStorage:WaitForChild("Firefly")
	while #participants < MAX_PARTICIPANTS do
		local curr = firefly:Clone() :: Part

		local sizeNum = rand:NextNumber(0.2, 0.4)
		curr.Size = Vector3.new(sizeNum, sizeNum, sizeNum * 1.8)

		curr.Position = rand:NextUnitVector() * rand:NextNumber(5, math.min(bounds.height, bounds.radius))
			+ bounds.center
		curr.Orientation = rand:NextUnitVector()
		curr:SetAttribute("Velocity", curr.Orientation * MAX_SPEED)

		curr.Parent = workspace

		local boidPart = BoidMember.new(curr, #participants < NUM_LEADERS)
		table.insert(participants, boidPart)

		if #participants > NUM_LEADERS then
			boidPart:setLeader(participants[#participants % NUM_LEADERS])
		else
			curr.Color = Color3.fromHSV((#participants/NUM_LEADERS), 1, 1)
		end

		task.wait(rand:NextNumber(0.3, .8))
	end
	print("Finished generating")
end)
