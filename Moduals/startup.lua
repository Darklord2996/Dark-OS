--[[
  Music System Setup:
  1. A dedicated disk drive for playing discs.
  2. A barrel for storing discs.
  3. A player detector.
  4. A file named "player_discs.txt" on a floppy disk.
     The file format should be:
     player_name_1=minecraft:music_disc_13
     player_name_2=minecraft:music_disc_cat
     player_3=minecraft:music_disc_wait
]]

-- GLOBALS
local PING_INTERVAL = 10 -- seconds
local relayPingTimer = os.startTimer(PING_INTERVAL)
local CONFIG_FILE = "tellraw_config.txt"
local FLOPPY_PATH = "/disk/" .. CONFIG_FILE
local LOCAL_PATH = CONFIG_FILE
local DISCS_FILE = "player_discs.txt"
local DISCS_FILE_PATH = "/disk/" .. DISCS_FILE
local barrel_side = "right"
local PLAYER_DETECTION_RANGE = 35
local UI_ACTIVATION_RANGE = 7
local FALLBACK_DISCS = { "furniture:cphs_pride", "cataclysm:music_disc_netherite_monstrosity" }
local RELAY_CHANNEL = 1337
local RELAY_DATA_FILE = "relay_data.json"
local RELAY_DATA_PATH = "/disk/" .. RELAY_DATA_FILE
local PING_TIMEOUT = 10 -- 10 seconds to receive a response from a ping

local function findWirelessModem()
    local peripheralNames = peripheral.getNames()
    local foundModems = {}
    
    print("Scanning for modems...")
    
    for _, name in ipairs(peripheralNames) do
        if peripheral.getType(name) == "modem" then
            local modem = peripheral.wrap(name)
            if modem then
                local isWireless = modem.isWireless and modem.isWireless()
                table.insert(foundModems, {name = name, wireless = isWireless})
                
                if isWireless then
                    print("Found WIRELESS modem: " .. name)
                    return modem, name  -- Return the first wireless modem found
                else
                    print("Found WIRED modem: " .. name .. " (skipping)")
                end
            end
        end
    end
    
    -- If we get here, no wireless modem was found
    print("Modem scan complete. Found " .. #foundModems .. " total modem(s):")
    for _, info in ipairs(foundModems) do
        print("  " .. info.name .. " - " .. (info.wireless and "WIRELESS" or "WIRED"))
    end
    
    return nil, nil
end

local modem, modemName = findWirelessModem()
if not modem then
    error("No wireless modem found! Please attach a wireless modem to continue.")
end

print("Using wireless modem: " .. modemName)
modem.open(RELAY_CHANNEL)

-- Basalt UI installer because I won't have this by default on some computers
if not fs.exists("basalt.lua") then
  shell.run("wget run https://raw.githubusercontent.com/Pyroxenium/Basalt2/main/install.lua")
  sleep(1)
end
local basalt = require("basalt")
if not basalt then error("Failed to load Basalt") end

-- Load and SHOW terminal UI FIRST
local terminalUI = require("terminal_ui")
local computerTerminalFrame = terminalUI.createTerminalUI()
print = terminalUI.print

-- Make sure the terminal UI is visible
basalt.setActiveFrame(computerTerminalFrame)

-- Initialize drive system (this will show drive options in terminal UI)
local driveSystem = terminalUI.initializeDriveSystemUI()

-- If no drive system, wait for user selection
if not driveSystem then
    print("=== DRIVE SELECTION REQUIRED ===")
    print("Please select a drive from the System tab above")
    print("The system will continue once a drive is selected...")
    
    -- Simple blocking wait with UI updates
    while not terminalUI.isDriveSelected() do
        basalt.update(os.pullEvent())
    end
    
    driveSystem = terminalUI.getSelectedDrive()
    print("Drive selection complete! Continuing with system startup...")
    sleep(2) -- Give user time to see the message
end

-- NOW continue with the rest of the initialization
local relays = {} -- { [label] = {online=true, dim="Overworld", message="Relay Active", lastSeen=time, lastPing=time} }

local monitor = peripheral.find("monitor")
if not monitor then error("Error: No monitor connected!") end
local monitorWidth, monitorHeight = monitor.getSize()
local playerDetector = peripheral.find("playerDetector")
if not playerDetector then
  print("Warning: No Advanced Peripherals Player Detector found!")
end

local barrel = peripheral.wrap(barrel_side)
if not barrel then print("Warning: Could not find barrel on side '" .. barrel_side .. "'. Music will be disabled.") end

-- Extra speakers redundant because speakers can't play music discs
local speakers = {}
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "speaker" then
    table.insert(speakers, name)
  end
end

-- Frames
local idleFrame, contentFrame, bootFrame, currentProgressBar
idleFrame = basalt.createFrame():setTerm(monitor):setBackground(colors.black):setSize(monitorWidth, monitorHeight)
contentFrame = basalt.createFrame():setTerm(monitor):setBackground(colors.black):setSize(monitorWidth, monitorHeight)
bootFrame = basalt.createFrame():setTerm(monitor):setBackground(colors.black):setSize(monitorWidth, monitorHeight)

-- Global references for dynamic updates
local relayList = nil 

local colorMap = {
  black = colors.black,
  dark_blue = colors.blue,
  dark_green = colors.green,
  dark_aqua = colors.cyan,
  dark_red = colors.red,
  dark_purple = colors.purple,
  gold = colors.orange,
  gray = colors.lightGray,
  dark_gray = colors.gray,
  blue = colors.lightBlue,
  green = colors.lime,
  aqua = colors.cyan,
  red = colors.red,
  light_purple = colors.magenta,
  yellow = colors.yellow,
  white = colors.white
}

local State = {
  currentPlayer = nil,
  isIdle = true,
  isBooting = false,
  bootProgress = 0,
  config = nil,
  lastModTime = 0,
  currentFrame = nil,
  idleBuilt = false,
  contentBuilt = false,
  isMusicPlaying = false,
  currentDiscPlayer = nil,
  currentDiscId = nil,
  playerDiscPreferences = nil,
  isWarningVisible = true
}

-- Helpers
local function trim(str)
  if not str then return "" end
  return str:match("^%s*(.-)%s*$")
end
local function clearFrame(frame) pcall(function() frame:clear() end) end

-- Word wrapping function to handle long labels.
local function wordWrap(str, width)
  local lines = {}
  local currentLine = ""
  for word in str:gmatch("%S+") do
    if #currentLine + #word + 1 <= width then
      currentLine = currentLine == "" and word or currentLine .. " " .. word
    else
      table.insert(lines, currentLine)
      local trimmedWord = word:match("^%S+") or ""
      currentLine = trimmedWord
    end
  end
  table.insert(lines, currentLine)
  return lines
end

-- Replace names
local function replacePlayerName(playerName)
  if playerName == "Beanfanati" then
    return "VI"
  elseif playerName == "Darklord2996" then
    return "Chaos Incarnate"
  elseif playerName == "desmano" then
    return "Druid of the Lands"
  elseif playerName == "Plokijr1" then
    return "Pillar of Fire"
  elseif playerName == "Hallowoeen" then
    return "Pillar of Aether"
  end
  return playerName
end

-- === DATA PERSISTENCE ===

-- Saves the relay data to the floppy disk as a JSON file
local function saveRelayData()
  if not fs.exists("/disk") then
    print("Error: No floppy disk found to save relay data.")
    return
  end
  
  -- Debug: Print what we're about to save
  print("DEBUG: Saving relay data:")
  for label, info in pairs(relays) do
    if type(info) == "table" then
      print("  " .. label .. ": online=" .. tostring(info.online) .. ", flag=" .. tostring(info.flag))
    end
  end
  
  local file = fs.open(RELAY_DATA_PATH, "w")
  if file then
    file.write(textutils.serializeJSON(relays))
    file.close()
    print("Relay data saved to " .. RELAY_DATA_PATH)
  else
    print("Error: Could not write to " .. RELAY_DATA_PATH)
  end
end

-- Loads the relay data from the floppy disk. Creates a new file if it doesn't exist.
local function loadRelayData()
  if not fs.exists("/disk") then
    print("Warning: No floppy disk found. Relay data will not be persistent.")
    relays = {}
    return
  end
  
  -- Create the file if it doesn't exist
  if not fs.exists(RELAY_DATA_PATH) then
    local file = fs.open(RELAY_DATA_PATH, "w")
    if file then
      file.write("{}")
      file.close()
    end
    relays = {}
    return
  end

  local file = fs.open(RELAY_DATA_PATH, "r")
  if file then
    local data = file.readAll()
    file.close()
    
    if data and data ~= "" then
      local success, decoded = pcall(textutils.unserializeJSON, data)
      if success and type(decoded) == "table" then
        relays = decoded
        
        -- Debug: Print what we loaded
        print("DEBUG: Loaded relay data:")
        for label, info in pairs(relays) do
          if type(info) == "table" then
            print("  " .. label .. ": online=" .. tostring(info.online) .. ", flag=" .. tostring(info.flag or "nil"))
          end
        end
      else
        print("Warning: Could not parse relay data JSON, starting fresh")
        relays = {}
      end
    else
      relays = {}
    end
  else
    print("Warning: Could not read relay data file")
    relays = {}
  end
end

-- === CONFIG LOADING ===
local function getConfigPath()
  if fs.exists(FLOPPY_PATH) then return FLOPPY_PATH end
  return LOCAL_PATH
end

local function loadConfig(path)
  if not fs.exists(path) then return nil end
  local file = fs.open(path, "r")
  if not file then return nil end

  local config = { title = "Advanced Tellraw System", elements = {} }
  local line = file.readLine()

  while line do
    line = trim(line)
    if line ~= "" and not line:match("^#") then
      if line:match("^title:") then
        config.title = trim(line:match("^title:%s*(.+)")) or config.title
      else
        local parts = {}
        for part in line:gmatch("[^|]+") do table.insert(parts, trim(part)) end

        if #parts > 0 then
          local element = {
            type = parts[1],
            text = "",
            color = "white",
            background = nil,
            bold = false,
            center = false,
            width = nil,
            height = 1
          }

          for i = 2, #parts do
            local key, value = parts[i]:match("([^=]+)=(.+)")
            if key and value then
              key, value = trim(key), trim(value)
              if key == "bold" or key == "center" then
                element[key] = value:lower() == "true"
              elseif key == "width" or key == "height" then
                element[key] = tonumber(value)
              else
                element[key] = value
              end
            elseif parts[i] ~= "" and element.type == "label" and element.text == "" then
              element.text = parts[i]
            end
          end

          if element.type ~= "label" or element.text ~= "" then
            table.insert(config.elements, element)
          end
        end
      end
    end
    line = file.readLine()
  end

  file.close()
  return #config.elements > 0 and config or nil
end

-- === Relays ===
local function updateRelayList()
    if not relayList then return end

    relayList:clear()

    for label, info in pairs(relays) do
        if type(info) == "table" then
            local status, fgColor
            
            if info.online then
                -- Check flag level to determine status and color
                local flag = info.flag or 0
                if flag == 2 then
                    status = "CRITICAL"
                    fgColor = colors.red
                elseif flag == 1 then
                    status = "WARNING" 
                    fgColor = colors.yellow
                else
                    status = "ONLINE"
                    fgColor = colors.green
                end
            else
                status = "OFFLINE"
                fgColor = colors.red
            end

            relayList:addItem({ 
                text = string.format("[%s] %s", label, status), 
                foreground = fgColor 
            })

            if info.online and (info.dim or info.message) then
                local details = string.format("  Dim: %s | %s", info.dim or "?", info.message or "")
                relayList:addItem({ 
                    text = details, 
                    foreground = colors.lightGray 
                })
            end

            relayList:addItem({ text = "", foreground = colors.black }) -- spacer
        end
    end

    -- Force the frame to redraw
    basalt.setActiveFrame(contentFrame)
    basalt.update(os.pullEvent())
end

-- Sends a ping message to all known relays
local function pingRelays()
  if not modem then return end
  for label, data in pairs(relays) do
    if type(data) == "table" then
      modem.transmit(os.getComputerID(), RELAY_CHANNEL, {
        type = "ping_request",
        target = label
      })
      data.lastPing = os.epoch("utc")
    end
  end
end

local function clearOfflineRelays()
  local toClear = {}
  for label, data in pairs(relays) do
    if type(data) == "table" and not data.online then
      table.insert(toClear, label)
    end
  end
  for _, label in ipairs(toClear) do
    relays[label] = nil
  end
  saveRelayData()
  term.clear()
  term.setCursorPos(1,1)
  print("Offline relays cleared.")
  sleep(1)
  -- Refresh the screen if the relay monitor is visible
  if State.currentFrame == "content" then
    updateRelayList()
  end
end

local function checkRelayTimeouts()
    local now = os.epoch("utc")
    local updated = false

    for label, info in pairs(relays) do
        if type(info) == "table" and info.online and info.lastPing and now - info.lastPing > (PING_INTERVAL * 1000) then
            info.online = false
            print("Relay '" .. label .. "' has timed out.")
            updated = true
        end
    end

    if updated then
        saveRelayData()
        if State.currentFrame == "content" then
            updateRelayList()
        end
    end
end

-- === PLAYER DISC PREFERENCES ===
local function loadPlayerDiscPreferences()
  local players = {}
  if not fs.exists(DISCS_FILE_PATH) then return players end
  local file = fs.open(DISCS_FILE_PATH, "r")
  if not file then return players end

  local line = file.readLine()
  while line do
    local player_name, rest = line:match("([^=]+)=(.+)")
    if player_name and rest then
      local disc_name, priority = rest:match("([^|]+)|?(%d*)")
      players[trim(player_name)] = {
        disc = trim(disc_name),
        priority = tonumber(priority) or 999
      }
    end
    line = file.readLine()
  end
  file.close()
  return players
end

local function getClosestPlayerForUI()
  if not playerDetector then return nil end
  local ok, players = pcall(function() return playerDetector.getPlayersInRange(UI_ACTIVATION_RANGE) end)
  if not ok or not players or #players == 0 then return nil end
  local p = players[1]
  local playerName = type(p) == "string" and p or (p.name or p.displayName or tostring(p))
  return replacePlayerName(playerName)
end

-- === MUSIC SYSTEM ===
local function ejectAndStoreDisc()
  if not driveSystem or not driveSystem.drive or not driveSystem.drive.isDiskPresent() then 
    return 
  end
  if not barrel then return end

  local moved = barrel.pullItems(driveSystem.side, 1, 1)
  if moved > 0 then
    State.currentDiscId = nil
    State.isMusicPlaying = false
    print("Disc ejected from " .. driveSystem.name .. " into barrel")
  end
end

local function playDisc(disc_id)
  if not driveSystem or not driveSystem.drive then
    return false
  end
  
  local items = barrel.list()
  for slot, item in pairs(items) do
    if item and item.name == disc_id then
      local moved = barrel.pushItems(driveSystem.side, slot, 1)
      if moved > 0 and driveSystem.drive.isDiskPresent() and driveSystem.drive.hasAudio() then
        local title = driveSystem.drive.getAudioTitle() or "Unknown"
        driveSystem.drive.playAudio()
        State.currentDiscId = disc_id
        State.isMusicPlaying = true
        print("Now playing: " .. title .. " on " .. driveSystem.name)
        return true
      end
    end
  end
  return false
end

local function findAndPlayDisc(disc_id)
  if not driveSystem or not driveSystem.drive or not barrel then 
    return 
  end

  local items = barrel.list()
  local availableDiscs = {}
  for _, item in pairs(items) do
    if item and item.name then availableDiscs[item.name] = true end
  end

  local targetDisc = nil
  if disc_id and availableDiscs[disc_id] then
    targetDisc = disc_id
  else
    for _, fallbackDisc in ipairs(FALLBACK_DISCS) do
      if availableDiscs[fallbackDisc] then
        targetDisc = fallbackDisc
        break
      end
    end
  end

  if not targetDisc then
    State.currentDiscId = nil
    State.isMusicPlaying = false
    print("No suitable disc found in barrel.")
    return
  end
  
  if State.currentDiscId ~= targetDisc then
    if driveSystem.drive.isDiskPresent() then
      driveSystem.drive.stopAudio()
      ejectAndStoreDisc()
    end
    playDisc(targetDisc)
  end
end

-- Main music handler
local function handleMusic()
  -- Check if we have a drive system, if not try to get the selected one
  if not driveSystem then
    if terminalUI.isDriveSelected() then
      driveSystem = terminalUI.getSelectedDrive()
      print("Drive system now active: " .. driveSystem.name)
    else
      return -- No drive selected yet, skip music handling
    end
  end
  
  if not driveSystem.drive or not barrel or not playerDetector then 
    return 
  end

  local ok, detectedPlayers = pcall(function() return playerDetector.getPlayersInRange(PLAYER_DETECTION_RANGE) end)
  if not ok or not detectedPlayers or #detectedPlayers == 0 then
    if State.isMusicPlaying then
      driveSystem.drive.stopAudio()
      State.isMusicPlaying = false
      State.currentDiscPlayer = nil
      ejectAndStoreDisc()
      print("Music stopped (no player nearby)")
    end
    return
  end

  -- Determine highest-priority player
  local selectedPlayer = nil
  local highestPriority = math.huge
  for _, p in ipairs(detectedPlayers) do
    local rawName = p.name or tostring(p)
    local info = State.playerDiscPreferences[rawName]
    if info and info.priority < highestPriority then
      highestPriority = info.priority
      selectedPlayer = { name = rawName, displayName = replacePlayerName(rawName), disc = info.disc }
    end
  end
  if not selectedPlayer then
    local p = detectedPlayers[1]
    local rawName = p.name or tostring(p)
    selectedPlayer = { name = rawName, displayName = replacePlayerName(rawName), disc = nil }
  end
  local desiredDisc = selectedPlayer.disc or FALLBACK_DISCS[1]
  if State.currentDiscId ~= desiredDisc then
    findAndPlayDisc(desiredDisc)
  end
  State.currentDiscPlayer = selectedPlayer.displayName
end

-- === DISC SAVING ===
local function saveDiscsToFloppy()
  if not barrel then
    print("Error: No barrel found.")
    return
  end
  if not fs.exists("/disk/") then
    print("Error: No floppy disk found.")
    return
  end

  local disc_list = {}
  local items = barrel.list()
  for _, item in pairs(items) do
    if item and item.name:find("music_disc") then
      table.insert(disc_list, item.name)
    end
  end

  if #disc_list > 0 then
    local file = fs.open(DISCS_FILE_PATH, "w")
    if file then
      for player_name, info in pairs(State.playerDiscPreferences) do
        local disc = info.disc or ""
        local priority = info.priority or 999
        file.writeLine(player_name .. "=" .. disc .. "|" .. priority)
      end
      for _, disc_name in ipairs(disc_list) do
        local found = false
        for _, info in pairs(State.playerDiscPreferences) do
          if info.disc == disc_name then
            found = true
            break
          end
        end
        if not found then
          file.writeLine("-- unassigned=" .. disc_name .. "|999")
        end
      end

      file.close()
      print("Saved " .. #disc_list .. " discs to " .. DISCS_FILE_PATH)
    else
      print("Error: Could not open file for writing")
    end
  else
    print("No music discs in barrel")
  end
end

-- Frame Definitions
local function showIdleScreen()
  if not State.idleBuilt then
    clearFrame(idleFrame)

    local centerY = math.floor(monitorHeight / 2)

    if State.isWarningVisible then
      local headerLabel = idleFrame:addLabel()
      local headerText = ">>> Warning High Alert Status <<<"
      headerLabel:setText(headerText)
      headerLabel:setPosition(math.floor(monitorWidth / 2 - #headerText / 2) + 1, 1)
      headerLabel:setForeground(colors.red)
    end

    local systemText = "Chaos Array Monitoring System Version 21"
    local systemLabel = idleFrame:addLabel()
    systemLabel:setText(systemText)
    systemLabel:setPosition(math.floor(monitorWidth / 2 - #systemText / 2) + 1, centerY - 2)
    systemLabel:setForeground(colors.white)
    
    local idleText = "SYSTEM IDLE - Approach to activate"
    local idleLabel = idleFrame:addLabel()
    idleLabel:setText(idleText)
    idleLabel:setPosition(math.floor(monitorWidth / 2 - #idleText / 2) + 1, centerY)
    idleLabel:setForeground(colors.cyan)

    State.idleBuilt = true
  end

  basalt.setActiveFrame(idleFrame)
  State.currentFrame = "idle"
end

local function showContentScreen()
    -- Clear previous frame
    clearFrame(contentFrame)
    contentFrame:setBackground(colors.black)

    -- HEADER (at the very top)
    local headerText = (State.config and State.config.title) or "Chaos Array Monitoring System Version 21"
    local headerLabel = contentFrame:addLabel()
    headerLabel:setText(headerText)
    headerLabel:setPosition(math.floor(monitorWidth / 2 - #headerText / 2) + 1, 1)
    headerLabel:setForeground(colors.white)
    headerLabel:setBackground(colors.black)

    -- TAB CONTROL: below header, spanning full width and remaining height
    local tabs = contentFrame:addTabControl({
        x = 1,
        y = 2,
        width = monitorWidth,
        height = monitorHeight - 1,
        headerBackground = colors.black,
        foreground = colors.white,
        headerHeight = 1,
        background = colors.black,
        headerAlign = "center"
    })

    local tabWidth = monitorWidth

    -- === MAIN TAB ===
    local mainTab = tabs:newTab("Main")
    local yMain = 1
    if State.config and State.config.elements then
        for _, element in ipairs(State.config.elements) do
            if yMain > monitorHeight - 2 then break end

            if element.type == "label" then
                local txt = element.text
                if State.currentPlayer and string.find(txt, "{player_name}") then
                    txt = string.gsub(txt, "{player_name}", State.currentPlayer)
                end
                if element.bold then txt = ">> " .. txt .. " <<" end

                local wrappedLines = wordWrap(txt, tabWidth - 2)
                for _, line in ipairs(wrappedLines) do
                    if yMain > monitorHeight - 2 then break end
                    local x = element.center and math.floor(tabWidth / 2 - #line / 2) + 1 or 1
                    mainTab:addLabel({x = x, y = yMain, width = #line})
                        :setText(line)
                        :setForeground(colorMap[element.color] or colors.white)
                        :setBackground(element.background and colorMap[element.background] or colors.black)
                    yMain = yMain + 1
                end
            elseif element.type == "separator" then
                local sepChar = element.text ~= "" and element.text:sub(1, 1) or "-"
                mainTab:addLabel({x = 1, y = yMain, width = tabWidth})
                    :setText(string.rep(sepChar, tabWidth))
                    :setForeground(colorMap[element.color] or colors.gray)
                    :setBackground(element.background and colorMap[element.background] or colors.black)
                yMain = yMain + (element.height or 1)
            elseif element.type == "spacer" then
                yMain = yMain + (element.height or 1)
            end
        end
    else
        local txt = "No valid configuration loaded"
        mainTab:addLabel({x = math.floor(tabWidth / 2 - #txt / 2) + 1, y = 1, width = #txt})
            :setText(txt)
            :setForeground(colors.red)
            :setBackground(colors.black)
    end

    -- === RELAYS TAB ===
    local relaysTab = tabs:newTab("Relays")
    relayList = relaysTab:addList({x = 1, y = 1, width = tabWidth, height = monitorHeight - 2})
    relayList:setBackground(colors.black)
    relayList:setForeground(colors.white)
    relayList:setSelectedBackground(colors.blue)
    relayList:setSelectedForeground(colors.white)

    -- Initial populate
    updateRelayList()

    -- === ACTIONS TAB ===
    local actionsTab = tabs:newTab("Actions")
    local actionText = "Actions placeholder"
    actionsTab:addLabel({x = math.floor(tabWidth / 2 - #actionText / 2) + 1, y = 1, width = #actionText})
        :setText(actionText)
        :setBackground(colors.black)
        :setForeground(colors.white)

    -- Activate frame
    basalt.setActiveFrame(contentFrame)
    State.currentFrame = "content"
    State.contentBuilt = true
end

local function showBootScreen(playerName)
  clearFrame(bootFrame)

  local centerY = math.floor(monitorHeight / 2)

  if State.isWarningVisible then
    local headerLabel = bootFrame:addLabel()
    local headerText = ">>> Warning High Alert Status <<<"
    headerLabel:setText(headerText)
    headerLabel:setPosition(math.floor(monitorWidth / 2 - #headerText / 2) + 1, 1)
    headerLabel:setForeground(colors.red)
  end

  local titleText = "Chaos Array Monitoring System Version 21"
  local titleLabel = bootFrame:addLabel()
  titleLabel:setText(titleText)
  titleLabel:setPosition(math.floor(monitorWidth / 2 - #titleText / 2) + 1, centerY - 2)
  titleLabel:setForeground(colors.white)

  local welcomeText = "Welcome " .. (playerName or "Player") .. " - Loading..."
  local welcomeLabel = bootFrame:addLabel()
  welcomeLabel:setText(welcomeText)
  welcomeLabel:setPosition(math.floor(monitorWidth / 2 - #welcomeText / 2) + 1, centerY)
  welcomeLabel:setForeground(colors.yellow)

  local barWidth = math.floor(monitorWidth / 3 * 2)
  local barX = math.floor(monitorWidth / 2 - barWidth / 2) + 1

  currentProgressBar = bootFrame:addProgressBar()
  currentProgressBar:setPosition(barX, centerY + 2)
  currentProgressBar:setSize(barWidth, 1)
  currentProgressBar:setProgress(State.bootProgress or 0)
  currentProgressBar:setBackground(colors.gray)
  pcall(function() currentProgressBar:setProgressColor(colors.white) end)
  currentProgressBar:setDirection("right")

  basalt.setActiveFrame(bootFrame)
  State.currentFrame = "boot"
end

local function updateBootSequence()
  if not State.isBooting then return end

  State.bootProgress = math.min((State.bootProgress or 0) + 2.5, 100)

  if currentProgressBar then
    pcall(function() currentProgressBar:setProgress(State.bootProgress) end)
  end

  if State.bootProgress >= 100 then
    State.isBooting = false
    currentProgressBar = nil
    showContentScreen()
  end
end

print("Initializing display...")
loadRelayData()
State.config = loadConfig(getConfigPath())
State.playerDiscPreferences = loadPlayerDiscPreferences()

local LastLog = { music = nil, player = nil }
local function logMusicChange(newState)
  if LastLog.music ~= newState then
    print(newState)
    LastLog.music = newState
  end
end

local function logPlayerChange(newPlayer)
  if LastLog.player ~= newPlayer then
    if newPlayer then
      print("Player detected: " .. newPlayer)
    else
      print("Player left -> Idle")
    end
    LastLog.player = newPlayer
  end
end

local function eventHandler()
  while true do
    local event = { os.pullEvent() }
    local eventType = event[1]

    -- ===== KEY EVENTS =====
    if eventType == "key" then
      local key = event[2]
      if key == keys.f1 then
        if multishell then
          local newTab = multishell.launch({ shell = shell, multishell = multishell }, "simpleshell.lua")
          if newTab then
            multishell.setTitle(newTab, "Shell")
            multishell.setFocus(newTab)
          end
        end
      elseif key == keys.f2 then
        print("=== System Information ===")
        print("Monitor: " .. monitorWidth .. "x" .. monitorHeight)
        print("Speakers: " .. #speakers)
        if driveSystem then
          print("Selected Drive: " .. driveSystem.name .. " (" .. driveSystem.side .. ")")
        else
          print("Selected Drive: None")
        end
        print("Current Player: " .. (State.currentPlayer or "None"))
        print("Music Playing: " .. tostring(State.isMusicPlaying))
        print("Current Disc: " .. (State.currentDiscId or "None"))
        print("Current Frame: " .. (State.currentFrame or "None"))
        print("Active Relays: " .. tostring(next(relays) ~= nil and 1 or 0))
        print("==========================")
      elseif key == keys.f3 then
        saveDiscsToFloppy()
      elseif key == keys.f4 then
        terminalUI.updateDriveDropdown()
        print("Drive list refreshed")
      elseif key == keys.f5 then
        State.isWarningVisible = not State.isWarningVisible
        State.idleBuilt = false
        if State.currentFrame == "idle" then
          showIdleScreen()
        elseif State.currentFrame == "boot" then
          showBootScreen(State.currentPlayer)
        end
      elseif key == keys.f6 then
        clearOfflineRelays()
      end

      -- ===== MODEM MESSAGES =====
    elseif eventType == "modem_message" then
        local side, channel, reply, message = event[2], event[3], event[4], event[5]
  
      if channel == RELAY_CHANNEL and type(message) == "table" then
        if message.type == "relay_status" or message.type == "ping_response" then
            if not relays[message.label] then
                relays[message.label] = {}
            end

        relays[message.label].online = true
        relays[message.label].dim = message.dim or relays[message.label].dim or "Unknown"
        relays[message.label].message = message.message or relays[message.label].message or ""
        relays[message.label].flag = message.flag or 0  -- Store flag value
        relays[message.label].lastSeen = os.epoch("utc")
        relays[message.label].lastPing = os.epoch("utc")
        saveRelayData()
        -- Dynamically refresh the relay list in UI
        if State.currentFrame == "content" then
            updateRelayList() 
        end
        end
    end

    -- ===== TIMER EVENTS =====
    elseif eventType == "timer" then
      local timerId = event[2]
      if timerId == relayPingTimer then
        pingRelays()

        -- Check for relays that timed out
        local now = os.epoch("utc")
        local updated = false
        for label, info in pairs(relays) do
          if type(info) == "table" and info.online and info.lastPing then
            if now - info.lastPing > (PING_TIMEOUT * 1000) then
              info.online = false
              updated = true
              print("Relay '" .. label .. "' timed out -> OFFLINE")
            end
          end
        end

        if updated then
          saveRelayData()
          if State.currentFrame == "content" then
            updateRelayList()
          end
        end

        relayPingTimer = os.startTimer(PING_INTERVAL)
      end
    end

    -- ===== PASS EVENTS TO BASALT =====
    basalt.update(table.unpack(event))
  end
end

local function mainLoop()
  while true do
    checkRelayTimeouts()
    if State.currentFrame == "content" and relayList then
        updateRelayList()
    end
    local path = getConfigPath()
    local modTime = fs.exists(path) and fs.attributes(path).modified or 0
    local configReloaded = false
    if modTime ~= State.lastModTime then
      State.lastModTime = modTime
      State.config = loadConfig(path)
      State.playerDiscPreferences = loadPlayerDiscPreferences()
      print("Config and disc preferences reloaded")
      State.contentBuilt = false -- Force a rebuild of the content screen
      configReloaded = true
    end

    local closestPlayer = getClosestPlayerForUI()
    logPlayerChange(closestPlayer)

    if closestPlayer then
      if State.isIdle then
        -- Transition from Idle to Boot
        State.currentPlayer = closestPlayer
        State.isIdle = false
        State.isBooting = true
        State.bootProgress = 0
        currentProgressBar = nil
        showBootScreen(closestPlayer)
      elseif configReloaded and State.currentFrame == "content" then
        -- Reload screen content if config file changes while user is on content screen
        showContentScreen()
      end
    elseif not closestPlayer and not State.isIdle then
      -- Transition from any active screen back to Idle
      State.currentPlayer = nil
      State.isIdle = true
      State.idleBuilt = false
      showIdleScreen()
    end

    if State.isBooting then
      updateBootSequence()
    end

    local beforeMusicState = State.isMusicPlaying
    handleMusic()
    if State.isMusicPlaying ~= beforeMusicState then
      if State.isMusicPlaying then
        logMusicChange("Music started: " .. (State.currentDiscId or "unknown"))
      else
        logMusicChange("Music stopped")
      end
    end

    sleep(0.05)
  end
end

-- System startup messages
print("Starting Tellraw Music Monitor System...")
print("Monitor size: " .. monitorWidth .. "x" .. monitorHeight)
print("Found speakers: " .. #speakers)
print("Controls:")
print("F1 - Shell | F2 - System Info | F3 - Save discs")
print("F4 - Refresh drives | F5 - Toggle Warning | F6 - Clear Offline Relays")
print("Use the terminal UI for drive selection and log viewing")
print("")

showIdleScreen()

-- Start main execution
parallel.waitForAny(mainLoop, eventHandler)