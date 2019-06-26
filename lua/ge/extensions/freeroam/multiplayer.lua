print("BeamNG-MP Lua system loaded.")

--=============================================================================
--== Mod Variables
--=============================================================================

local M = {}
local uiWebServer = require('utils/simpleHttpServer')
local websocket = require('libs/lua-websockets/websocket')
local mp = require('libs/lua-MessagePack/MessagePack')
local copas = require('libs/copas/copas')
local helper = require('freeroam/helpers')
local json = require('libs/lunajson/lunajson')

local listenHost = "0.0.0.0"
local httpListenPort = 3359
local chatMessage = ""
local nick = ""
local user = ""
local cid = helper.randomString(8)

-- the websocket counterpart
local ws_client
local wsServer
local InGame = false
local pause = false

--=============================================================================
--== Vehicle Monitoring
--=============================================================================

lastVehicleState = {
  steering = 0,
  throttle = 0,
  brake = 0,
  parkingbrake = 0,
  clutch = 0
}

local function getVehicleState()
  local state = {}
  state.type = "VehicleState"
  --state.client = ws_client  -- this and the user one below will be helpful for us to keep track of the vehicles and whos is whos.
  state.user = user

  state.steering = lastVehicleState.steering
  state.throttle = lastVehicleState.throttle
  state.brake = lastVehicleState.brake
  state.clutch = lastVehicleState.clutch
  state.parkingbrake = lastVehicleState.parkingbrake

  local vdata = map.objects[be:getPlayerVehicle(0):getID()]
  state.pos = vdata.pos:toTable()
  state.vel = vdata.vel:toTable()
  state.dir = vdata.dirVec:toTable()
  local dir = vdata.dirVec:normalized()
  state.rot = math.deg(math.atan2(dir:dot(vec3(1, 0, 0)), dir:dot(vec3(0, -1, 0))))

  --state.view = Engine.getColorBufferBase64(320, 240)
  return state
end

local function requestVehicleInput(key)
  local command = "obj:queueGameEngineLua('lastVehicleState." .. key .. " = ' .. input.state." .. key .. ".val)"
  local v = be:getPlayerVehicle(0)
  if v then
    be:getPlayerVehicle(0):queueLuaCommand(command)
  end
end

local function requestVehicleInputs()
  for k, v in pairs(lastVehicleState) do
    requestVehicleInput(k)
  end
end

local function issueVehicleInput(key, val)
  local command = "input.event('" .. key .. "', " .. val .. ", 1)"
  be:getPlayerVehicle(0):queueLuaCommand(command)
end

local function issueVehicleInputs(inputs)
  for k, v in pairs(inputs) do
    issueVehicleInput(k, v)
  end
end

--=============================================================================
--== Multiplayer Client and server handlers
--=============================================================================

local echo_handler = function(ws) -- Our Server
  while true do
    local message = ws:receive()
    if message then
      --print('BeamNG-MP Server > Socket Message: '..message)
      --ws:send(message)
      print(message)
			local msg = helper.split(message, '|')
			--print(helper.dump(msg))
			if msg[1] == 'JOIN' then
				-- STEP 1 a client has asked to join the server, lets check they are using the correct map.
				print('BeamNG-MP Server > A new player is trying to join')
				ws:broadcast('CHAT|'..msg[2]..' is joining the session.')
				local map = getMissionFilename()
				ws:send('MAP|'..map)
			elseif msg[1] == 'CONNECTING' then
			-- STEP 2 a client is now joining having confirmed the map, we need to send them all current vehicle data
				print('BeamNG-MP Server > The new player has confirmed the map, Send them the session data and pause all clients')
        ws:broadcast('UPDATE|PAUSE|true')
				ws:send('SETUP|DATA')
			elseif msg[1] == 'CONNECTED' then
			-- STEP 3 start sending out our game data again. We will be the point of sync for all players
				print('BeamNG-MP Server > The new player has now synced with us. Now to unpause')
				ws:broadcast('CHAT|'..msg[2]..' Has joined the game!')
        ws:broadcast('UPDATE|PAUSE|false')
			elseif msg[1] == 'UPDATE' then
			-- STEP 4 a client sendus new data about they session state, so we need to update our vehicles to match theirs
				print('BeamNG-MP Server > A new player is trying to join')
				ws:broadcast(message)
			elseif msg[1] == 'CHAT' then
				print('Attempting to broadcast chat message')
				ws:broadcast('CHAT|'..msg[2])
			elseif msg[1] == 'ERROR' then
				ws:send('ERROR|'..msg[2])
			end
    else
      ws:close()
      return
    end
  end
end

local function receive_data_job(job) -- Our Client
    while ws_client do
      local data_raw = ws_client:receive() --apparently always blocking so we need to use a coroutine
      if not data_raw then
        return
      end
      --print('Client received ' .. tostring(data_raw))
			-- now lets break up the message we received so that we can make use of it since we dont know of a way to subscribe to different channels.
			-- Maybe in a new update? Socket.io?
			local msg = helper.split(data_raw, '|')
			--print(helper.dump(msg))
			--print('BeamNG-MP Client > Socket Message: new data = '..msg[1]..' : '..msg[2])
			if msg[1] == 'MAP' then
        -- STEP 1 before spending time on syncing our games lets make sure we are using the same map
				if msg[2] == getMissionFilename() then
					ui_message('Connection Successful. Setting up Session... (Map = '..msg[2]..')', 10, 0, 0)
					ws_client:send("CONNECTING|Map=good")
          InGame = true
				else
					ui_message('Connection Failed. Please use the map '..msg[2]..'', 10, 0, 0)
				end
			elseif msg[1] == 'SETUP' then
        -- STEP 2 so our client has checked the map and we are good. now lets sync our game with the other players.
				ws_client:send("CONNECTED|"..user or "Client")
				extensions.util_richPresence.set('Playing Multiplayer'); -- Little fancy thingy :P
				--print(msg[2])
			elseif msg[1] == 'UPDATE' then
        -- STEP 3 handle updates that we receive here
        if msg[2] == 'PAUSE' then
          --print('Game requested to pause: '..msg[3])
          --helpers.togglePause()
          if msg[3] == 'true' then
            pause = true
          else
            pause = false
          end
          helper.setPauseState(pause)
        elseif msg[2] == "" then

        end
			elseif msg[1] == 'CHAT' then
				print('New Chat Message: '..msg[2])
				ui_message(msg[2], 10, 0, 0)
			end
    end
    print('receive coroutine done')
end

local function joinSession(value)
	print('BeamNG-MP Attempting to join multiplayer session.')
	if false then --if not value then
		print("Join Session port or IP are blank.")
	else
		value = {}
		value.ip = "192.168.0.1" -- Preset to the host in my case
		value.port = 3360
		if value.ip ~= "" and value.port ~= 0 then
			ui_message('Attempting to join session: '..value.ip..':'..value.port..'', 10, 0, 0)
			extensions.core_jobsystem.create(function ()
				ws_client = websocket.client.copas({timeout=0})
				ws_client:connect('ws://'..value.ip..':'..value.port..'')
				extensions.core_jobsystem.create(receive_data_job)
				local user = nick or "User"
				ws_client:send("JOIN|"..user)
			end)
		end
	end
end

local webServerRunning = false

local function hostSession(value)
	print('BeamNG-MP Attempting to host multiplayer session.')
	map.getMap()
	--local map = get
	if false then --if not value then
		print("Host Session port or IP are blank.")
	else
		value = 3359
		if value ~= 0 then
			listenHost = "0.0.0.0"
			httpListenPort = value
			uiWebServer.start(listenHost, httpListenPort, '/', nil, function(req, path)
				webServerRunning = true
				return {
					httpPort = 3359,--httpListenPort,
					wsPort = 3360,--httpListenPort + 1,
					host = listenHost,
				}
			end)
			print('BeamNG-MP Webserver hosted on '..listenHost..":"..httpListenPort)

			-- create a copas webserver and start listening
			wsServer = websocket.server.copas.listen{
				-- listen on port 8080
			  port = 3360,
			  -- the protocols field holds
			  --   key: protocol name
			  --   value: callback on new connection
			  protocols = {
			    -- this callback is called, whenever a new client connects.
			    -- ws is a new websocket instance
			    echo = echo_handler
			  },
			  default = echo_handler
			}
			extensions.core_jobsystem.create(function ()
				ws_client = websocket.client.copas({timeout=0})
				ws_client:connect('ws://localhost:3360')
				extensions.core_jobsystem.create(receive_data_job)
				user = nick or "Host"
				ws_client:send("JOIN|"..user)
			end)
			print('BeamNG-MP Websockets hosted on '..listenHost..':3360')
			ui_message('Session hosted on: '..listenHost..':3360', 10, 0, 0)
		end
	end
end

local flip = true
local counter = 0
local reset = true
local function onUpdate(dt)
	copas.step(0)
	if webServerRunning then
		uiWebServer.update()
	end
	if InGame then  -- this whole thing needs moving into a one second loop rather than every frame i think due to the C-call boundry issue thing with copas
    if reset then -- Added 1 second check
      counter = os.time() + 1
      print('Counter = '..counter)
      reset = false
    end
    if counter == os.time() then
    --if flip then -- allows us to run every other frame
      print('1 second')
		  requestVehicleInputs()
      local veh = getVehicleState()
      local vehReady = mp.pack(veh)
      print(vehReady)
      ws_client:send('UPDATE|VEHCILE|'..cid..'|'..vehReady) -- this allows us to get and send our vehicle states to the server and then to all players
      reset = true
    end
    --flip = not flip
	end
  if pause then
    helper.setPauseState(true)
  end
end

--=============================================================================
--== UI related stuff
--=============================================================================

local function ready()
	print("BeamNG-MP UI Ready!")
end

local function setNickname(value)
	nick = value.data
	--print('Chat Values (setChatMessage): '..value.data..' | '..chatMessage or "")
end

local function setChatMessage(value)
	chatMessage = value.data
	--print('Chat Values (setChatMessage): '..value.data..' | '..chatMessage or "")
end

local function chatSend(value)
	--print('Chat Values (chatSend): '..value.data..' | '..chatMessage or "")
	if not value then
		print('Chat Value not set! '..value.data..' | '..chatMessage or "")
		return
	else
		print('BeamNG-MP Chat: Message sent = '..value.data)
		ws_client:send('CHAT|'..nick..': '..value.data)
		chatMessage = ""
	end
end

--=============================================================================
--== Module things
--=============================================================================

M.onUpdate = onUpdate
M.ready = ready
M.chatSend = chatSend
M.setNickname = setNickname
M.setChatMessage = setChatMessage
M.joinSession = joinSession
M.hostSession = hostSession

return M

--=============================================================================
--==
--=============================================================================