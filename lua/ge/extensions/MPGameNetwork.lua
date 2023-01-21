--====================================================================================
-- All work by Titch2000, jojos38 & 20dka.
-- You have no permission to edit, redistribute or upload. Contact BeamMP for more info!
--====================================================================================



local M = {}



-- ============= VARIABLES =============
local socket = require('socket')
local TCPSocket
local launcherConnected = false
local useSocket = true -- Use V2 Networking by default. Set to false for V3
local isConnecting = false
local eventTriggers = {}
--keypress handling
local keyStates = {} -- table of keys and their states, used as a reference
local keysToPoll = {} -- list of keys we want to poll for state changes
local keypressTriggers = {}
-- ============= VARIABLES =============

setmetatable(_G,{}) -- temporarily disable global notifications

local function connectToLauncher(useSocket)
	log('M', 'connectToLauncher', "Connecting MPGameNetwork!")

	if not useSocket then launcherConnected = true end
	if not launcherConnected and useSocket then
		isConnecting = true
		TCPSocket = socket.tcp()
		TCPSocket:setoption("keepalive", true)
		TCPSocket:settimeout(0) -- Set timeout to 0 to avoid freezing
		TCPSocket:connect((settings.getValue("launcherIp") or '127.0.0.1'), (settings.getValue("launcherPort") or 4444)+1)
		M.send('A')
	
	else
		log('W', 'connectToLauncher', 'Launcher already connected!')
	end
end



local function disconnectLauncher()
	if launcherConnected and useSocket then
		TCPSocket:close()
		launcherConnected = false
	end
end



local function sendData(s)
	-- First check if we are V3 Networking or not
	if MP and not useSocket then
		MP.Game(s)
		if not launcherConnected then launcherConnected = true isConnecting = false end
		if settings.getValue("showDebugOutput") then
			log('M', 'sendData', 'Sending Data ('..#s..'): '..s)
		end
		if MPDebug then MPDebug.packetSent(#s) end
		return
	end

	-- Else we now will use the V2 Networking
	if not TCPSocket then return end
	local bytes, error, index = TCPSocket:send(#s..'>'..s)
	if error then
		isConnecting = false
		log('E', 'sendData', 'Socket error: '..error)
		if error == "closed" and launcherConnected then
			log('W', 'sendData', 'Lost launcher connection!')
			launcherConnected = false
		elseif error == "Socket is not connected" then

		else
			log('E', 'sendData', 'Stopped at index: '..index..' while trying to send '..#s..' bytes of data.')
		end
		return
	else
		if not launcherConnected then launcherConnected = true isConnecting = false end
		if settings.getValue("showDebugOutput") then
			log('M', 'sendData', 'Sending Data ('..bytes..'): '..s)
		end
		if MPDebug then MPDebug.packetSent(bytes) end
	end
end

local function sessionData(data)
	local code = string.sub(data, 1, 1)
	local data = string.sub(data, 2)
	if code == "s" then
		local playerCount, playerList = string.match(data, "^(%d+%/%d+)%:(.*)") -- 1/10:player1,player2
		UI.setPlayerCount(playerCount)
		UI.updatePlayersList(playerList)
	elseif code == "n" then
		UI.setNickname(data)
		MPConfig.setNickname(data)
	end
end

local function quitMP(reason)
	local text = reason~="" and ("Reason: ".. reason) or ""
	log('M','quitMP',"Quit MP Called! reason: "..tostring(reason))

	UI.showMdDialog({
		dialogtype="alert", title="You have been disconnected from the server", text=text, okText="Return to menu",
		okLua="MPCoreNetwork.leaveServer(true)" -- return to main menu when clicking OK
	})
end

-------------------------------------------------------------------------------
-- Events System
-------------------------------------------------------------------------------

local function handleEvents(p)  --- code=E  p=:<NAME>:<DATA>
	local eventName, eventData = string.match(p,"^%:([^%:]+)%:(.*)")
	if not eventName then quitMP(p) return end
	for i=1,#eventTriggers do
		if eventTriggers[i].name == eventName then
			if type(eventTriggers[i].func) == "function" then eventTriggers[i].func(eventData) end
		end
	end
end

function TriggerServerEvent(name, data)
	sendData('E:'..name..':'..data)
end

function TriggerClientEvent(name, data)
	handleEvents(':'..name..':'..data)
end

function AddEventHandler(n, f)
	log('M', 'AddEventHandler', "Adding Event Handler: Name = "..tostring(n))
	if type(f) ~= "function" or f == nop then
		log('W', 'AddEventHandler', "Event handler function can not be nil")
	else
		table.insert(eventTriggers, {name = n, func = f})
	end
end

-------------------------------------------------------------------------------
-- Keypress handling
-------------------------------------------------------------------------------
function onKeyPressed(keyname, f)
	addKeyEventListener(keyname, f, 'down')
end
function onKeyReleased(keyname, f)
	addKeyEventListener(keyname, f, 'up')
end

function addKeyEventListener(keyname, f, type)
	f = f or function() end
	log('W','AddKeyEventListener', "Adding a key event listener for key '"..keyname.."'")
	table.insert(keypressTriggers, {key = keyname, func = f, type = type or 'both'})
	table.insert(keysToPoll, keyname)

	be:queueAllObjectLua("if true then addKeyEventListener(".. serialize(keysToPoll) ..") end")
end

local function onKeyStateChanged(key, state)
	keyStates[key] = state
	--dump(keyStates)
	--dump(keypressTriggers)
	for i=1,#keypressTriggers do
		if keypressTriggers[i].key == key and (keypressTriggers[i].type == 'both' or keypressTriggers[i].type == (state and 'down' or 'up')) then
			keypressTriggers[i].func(state)
		end
	end
end

function getKeyState(key)
	return keyStates[key] or false
end

local function onVehicleReady(gameVehicleID)
	local veh = be:getObjectByID(gameVehicleID)
	if not veh then
		log('R', 'onVehicleReady', 'Vehicle does not exist!')
		return
	end
	veh:queueLuaCommand("addKeyEventListener(".. serialize(keysToPoll) ..")")
end

-------------------------------------------------------------------------------

local HandleNetwork = {
	['V'] = function(params) MPInputsGE.handle(params) end, -- inputs and gears
	['W'] = function(params) MPElectricsGE.handle(params) end,
	['X'] = function(params) nodesGE.handle(params) end, -- currently disabled
	['Y'] = function(params) MPPowertrainGE.handle(params) end, -- powertrain related things like diff locks and transfercases
	['Z'] = function(params) positionGE.handle(params) end, -- position and velocity
	['O'] = function(params) MPVehicleGE.handle(params) end, -- all vehicle spawn, modification and delete events, couplers
	['P'] = function(params) MPConfig.setPlayerServerID(params) end,
	['J'] = function(params) MPUpdatesGE.onPlayerConnect() UI.showNotification(params) end, -- A player joined
	['L'] = function(params) UI.showNotification(params) end, -- Display custom notification
	['S'] = function(params) sessionData(params) end, -- Update Session Data
	['E'] = function(params) handleEvents(params) end, -- Event For another Resource
	['T'] = function(params) quitMP(params) end, -- Player Kicked Event (old, doesn't contain reason)
	['K'] = function(params) quitMP(params) end, -- Player Kicked Event (new, contains reason)
	['C'] = function(params) UI.chatMessage(params) end, -- Chat Message Event
}


local heartbeatTimer = 0
local function onUpdate(dt)
	--====================================================== DATA RECEIVE ======================================================
	if launcherConnected and useSocket then
		while(true) do
			local received, status, partial = TCPSocket:receive() -- Receive data
			if received == nil or received == "" then break end

			if settings.getValue("showDebugOutput") == true then
				log('M', 'onUpdate', 'Receiving Data ('..#received..'): '..received)
			end

			-- break it up into code + data
			local code = string.sub(received, 1, 1)
			local data = string.sub(received, 2)
			HandleNetwork[code](data)

			if MPDebug then MPDebug.packetReceived(#received) end
		end
	end
	if heartbeatTimer >= 1 and MPCoreNetwork.isMPSession() then --TODO: something
		heartbeatTimer = 0
		sendData('A')
	end
end

local function onExtensionLoaded()
	if MP then
		useSocket = false
	end
end

local function isLauncherConnected()
	if useSocket then
		return launcherConnected
	else
		return true
	end
end

local function connectionStatus() --legacy, here because some mods use it
	return launcherConnected and 1 or 0
end

M.receiveIPCGameData = function(code, data)
	HandleNetwork[code](data)
end

detectGlobalWrites() -- reenable global write notifications


--events
M.onUpdate = onUpdate
M.onKeyStateChanged = onKeyStateChanged

--functions
M.onExtensionLoaded    = onExtensionLoaded
M.launcherConnected   = isLauncherConnected
M.connectionStatus    = connectionStatus --legacy
M.connectToLauncher   = connectToLauncher
M.disconnectLauncher  = disconnectLauncher
M.send                = sendData
M.CallEvent           = handleEvents
M.quitMP              = quitMP

M.addKeyEventListener = addKeyEventListener -- takes: string keyName, function listenerFunction
M.getKeyState         = getKeyState         -- takes: string keyName
M.onVehicleReady      = onVehicleReady

return M
