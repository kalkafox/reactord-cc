reactord = reactord or {}

require("config")

local sides = redstone.getSides()

local p = nil

print("Searching for " .. reactord.config.type .. "...")

local function getDevice()
	for _, side in ipairs(sides) do
		local device = peripheral.wrap(side)

		if not device then
			goto continue
		end

		if peripheral.hasType(peripheral.wrap(side), reactord.config.type) then
			-- check if device has methods/is connected
			return device
		end

		::continue::
	end
end

p = getDevice()

if not p then
	error("Device type" .. "was not found, make sure the computer is connected directly to it!")
end

if not p.connected() then
	error("Device was found, but it is not connected. Are you sure it is fully formed?")
end

if p then
	print("Found.")
end

if reactord.config.access_token:len() == 0 then
	error("You need to get an access token from the web interface and set it in reactord.config.access_token")
end

if reactord.config.url:len() == 0 then
	error("Websocket url needed! e.g ws://foo.bar:3030/baz")
end

print("Attempting to connect to the endpoint... (deviceId " .. reactord.config.id .. ")")

local ws = assert(http.websocket(reactord.config.url .. "/" .. reactord.config.type, {
	token = reactord.config.access_token,
}))

print("Connected!")
local reactor_data = {}

local function send()
	while true do
		os.sleep(0.2)

		local battery = p.battery()
		local fuel_tank = p.fuelTank()
		local coolant_tank = p.coolantTank()

		local controlRodCount = p.controlRodCount()

		-- data snapshot
		local data = {
			apiVersion = p.apiVersion(),
			active = p.active(),
			ambientTemperature = p.ambientTemperature(),
			casingTemperature = p.casingTemperature(),
			connected = p.connected(),
			stackTemperature = p.stackTemperature(),
			fuelTemperature = p.fuelTemperature(),
			controlRodCount = controlRodCount,
			controlRodData = {},
		}

		-- get data from all control rods
		for i = 0, controlRodCount - 1 do
			local controlRod = p.getControlRod(i)
			data.controlRodData["" .. i .. ""] = {
				level = controlRod.level(),
				name = controlRod.name(),
				valid = controlRod.valid(),
				index = controlRod.index(),
			}
		end

		if battery then
			fuel_tank = p.fuelTank()

			data.type = "passive"
			data.capacity = battery.capacity()
			data.producedLastTick = battery.producedLastTick()
			data.stored = battery.stored()
			data.burnedLastTick = fuel_tank.burnedLastTick()
			data.capacity = fuel_tank.capacity()
			data.fuel = fuel_tank.fuel()
			data.fuelReactivity = fuel_tank.fuelReactivity()
			data.totalReactant = fuel_tank.totalReactant()
		end

		if not battery then
			coolant_tank = p.coolantTank()

			data.type = "active"

			data.coolantCapacity = coolant_tank.capacity()
			data.coldFluidAmount = coolant_tank.coldFluidAmount()
			data.hotFluidAmount = coolant_tank.hotFluidAmount()
			data.maxTransitionedLastTick = coolant_tank.maxTransitionedLastTick()
			data.transitionedLastTick = coolant_tank.transitionedLastTick()
		end

		local to_send = {}
		local count = 0

		for k, v in pairs(data.controlRodData) do
			local success, err = pcall(function()
				return reactor_data.controlRodData[k]
			end)

			if not success then
				reactor_data.controlRodData = data.controlRodData
				to_send.controlRodData = data.controlRodData
			end

			if reactor_data.controlRodData[k].level ~= v.level then
				reactor_data.controlRodData[k] = v
				to_send.controlRodData = to_send.controlRodData or {}
				to_send.controlRodData["" .. k .. ""] = v
				count = count + 1
			end

			if reactor_data.controlRodData[k].name ~= v.name then
				reactor_data.controlRodData[k] = v
				to_send.controlRodData = to_send.controlRodData or {}
				to_send.controlRodData["" .. k .. ""] = v
				count = count + 1
			end
		end

		for k, v in pairs(data) do
			if k == "controlRodData" then
				goto continue_data_loop
			end

			if reactor_data[k] ~= v then
				reactor_data[k] = v
				to_send[k] = v
				count = count + 1
			end
			::continue_data_loop::
		end

		if count == 0 then
			goto continue
		end

		ws.send(textutils.serializeJSON({ sent_by_daemon = true, data = to_send }))

		::continue::
	end
end

local function reactor_wrapper()
	::back_to_send::
	local success, err = pcall(send)

	if not success then
		print("Device had an error/context lost! Retrying...")
		print(err)
		reactor_data.connected = false
		ws.send(textutils.serializeJSON({ sent_by_daemon = true, data = { connected = false } }))
		repeat
			local connected = p.connected()
			os.sleep(0.1)
		until connected == true
		print("Reconnected!")
		goto back_to_send
	end
end

local function listen()
	while true do
		::back_to_receive::
		local data, idk = ws.receive()

		local d = textutils.unserialiseJSON(data)

		print(d.data.active)

		if d.sentByDaemon then
			goto back_to_receive
		end

		-- in the event we lose access to the device
		if not p.connected() then
			goto back_to_receive
		end

		if d.data.active ~= reactor_data.active then
			p.setActive(d.data.active)
		end
	end
end

local function wait_for_q()
	repeat
		local _, key = os.pullEvent("key")
	until key == keys.q
	print("Q was pressed!")
	ws.send(textutils.serializeJSON({ sent_by_daemon = true, data = { device = { connected = false } } }))
	ws.close()
end

parallel.waitForAny(wait_for_q, listen, reactor_wrapper)
