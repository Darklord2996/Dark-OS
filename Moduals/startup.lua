-- GLOBALS
local PING_INTERVAL = 10 -- seconds
local relayPingTimer = os.startTimer(PING_INTERVAL)
local CONFIG_FILE = "tellraw_config.txt"
local FLOPPY_PATH = "/disk/" .. CONFIG_FILE
local LOCAL_PATH = CONFIG_FILE
local DISCS_FILE = "player_discs.json"
local DISCS_FILE_PATH = "/disk/" .. DISCS_FILE
local PLAYER_DETECTION_RANGE = 35
local UI_ACTIVATION_RANGE = 7
local FALLBACK_DISCS = { "furniture:cphs_pride", "cataclysm:music_disc_netherite_monstrosity" }
local RELAY_CHANNEL = 1337
local MUSIC_CHANNEL = 1338 -- NEW: Channel for the music computer
local RELAY_DATA_FILE = "relay_data.json"
local RELAY_DATA_PATH = "/disk/" .. RELAY_DATA_FILE
local PING_TIMEOUT = 10 -- 10 seconds to receive a response from a ping

terminalui = require("terminal_ui")
local function findWirelessModem()
  local peripheralNames = peripheral.getNames()
  local foundModems = {}

  print("Scanning for modems...")

  for _, name in ipairs(peripheralNames) do
    if peripheral.getType(name) == "modem" then
      local modem = peripheral.wrap(name)
      if modem then
        local isWireless = modem.isWireless and modem.isWireless()
        table.insert(foundModems, { name = name, wireless = isWireless })

        if isWireless then
          print("Found WIRELESS modem: " .. name)
          return modem, name -- Return the first wireless modem found
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
modem.open(MUSIC_CHANNEL) -- NEW: Open music channel

-- Basalt UI installer because I won't have this by default on some computers
if not fs.exists("basalt.lua") then
  shell.run("wget run https://raw.githubusercontent.com/Pyroxenium/Basalt2/main/install.lua")
  sleep(1)
end
local basalt = require("basalt")
if not basalt then
  error("Failed to load Basalt")
end

-- Load and SHOW terminal UI FIRST
local terminalUI = require("terminal_ui")
local computerTerminalFrame = terminalUI.createTerminalUI()

-- Make sure the terminal UI is visible
basalt.setActiveFrame(computerTerminalFrame)

-- NOW continue with the rest of the initialization
local relays = {} -- { [label] = {online=true, dim="Overworld", message="Relay Active", lastSeen=time, lastPing=time} }

local monitor = peripheral.find("monitor")
if not monitor then
  error("Error: No monitor connected!")
end
local monitorWidth, monitorHeight = monitor.getSize()
local playerDetector = peripheral.find("playerDetector")
if not playerDetector then
  print("Warning: No Advanced Peripherals Player Detector found!")
end

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
  playerDiscPreferences = nil,
  isWarningVisible = true,
  lastSentDisc = nil -- NEW: Track the last disc command sent
}

-- Helpers
local function trim(str)
  if not str then
    return ""
  end
  return str:match("^%s*(.-)%s*$")
end
local function clearFrame(frame)
  pcall(
    function()
      frame:clear()
    end
  )
end

local function prettyJSON(tbl, indent)
  indent = indent or 0
  local indentStr = string.rep("  ", indent)
  local nextIndentStr = string.rep("  ", indent + 1)

  if type(tbl) ~= "table" then
    return textutils.serializeJSON(tbl)
  end

  local isArray = #tbl > 0
  local lines = {}

  if isArray then
    table.insert(lines, "[")
    for i, v in ipairs(tbl) do
      local comma = i < #tbl and "," or ""
      if type(v) == "table" then
        table.insert(lines, nextIndentStr .. prettyJSON(v, indent + 1) .. comma)
      else
        table.insert(lines, nextIndentStr .. textutils.serializeJSON(v) .. comma)
      end
    end
    table.insert(lines, indentStr .. "]")
  else
    table.insert(lines, "{")
    local keys = {}
    for k in pairs(tbl) do
      table.insert(keys, k)
    end
    table.sort(keys)

    for i, k in ipairs(keys) do
      local v = tbl[k]
      local comma = i < #keys and "," or ""
      local key = textutils.serializeJSON(tostring(k))

      if type(v) == "table" then
        table.insert(lines, nextIndentStr .. key .. ": " .. prettyJSON(v, indent + 1) .. comma)
      else
        table.insert(lines, nextIndentStr .. key .. ": " .. textutils.serializeJSON(v) .. comma)
      end
    end
    table.insert(lines, indentStr .. "}")
  end

  return table.concat(lines, "\n")
end

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

local function saveRelayData()
  if not fs.exists("/disk") then
    terminalui.uiprint("Error: No floppy disk found to save relay data.")
    return
  end

  local file = fs.open(RELAY_DATA_PATH, "w")
  if file then
    file.write(prettyJSON(relays))
    file.close()
    terminalui.uiprint("Relay data saved to " .. RELAY_DATA_PATH)
  else
    terminalui.uiprint("Error: Could not write to " .. RELAY_DATA_PATH)
  end
end

local function loadRelayData()
  if not fs.exists("/disk") then
    terminalui.uiprint("Warning: No floppy disk found. Relay data will not be persistent.")
    relays = {}
    return
  end

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
      else
        terminalui.uiprint("Warning: Could not parse relay data JSON, starting fresh")
        relays = {}
      end
    else
      relays = {}
    end
  else
    terminalui.uiprint("Warning: Could not read relay data file")
    relays = {}
  end
end
local function getHighestPriorityPlayer()
  local detectedPlayers = {}
  if playerDetector then
    local ok, players =
        pcall(
          function()
            return playerDetector.getPlayersInRange(PLAYER_DETECTION_RANGE)
          end
        )
    if ok and players then
      detectedPlayers = players
    end
  end

  local highestPriority = math.huge
  local selectedPlayer = nil

  for _, p in ipairs(detectedPlayers) do
    local rawName = p.name or tostring(p)
    local info = State.playerDiscPreferences[rawName]
    if info and info.priority < highestPriority then
      highestPriority = info.priority
      selectedPlayer = { name = rawName, displayName = replacePlayerName(rawName), disc = info.disc }
    end
  end

  return selectedPlayer
end

-- === CONFIG LOADING ===
local function getConfigPath()
  if fs.exists(FLOPPY_PATH) then
    return FLOPPY_PATH
  end
  return LOCAL_PATH
end

local function loadConfig(path)
  if not fs.exists(path) then
    return nil
  end
  local file = fs.open(path, "r")
  if not file then
    return nil
  end

  local config = { title = "Advanced Tellraw System", elements = {} }
  local line = file.readLine()

  while line do
    line = trim(line)
    if line ~= "" and not line:match("^#") then
      if line:match("^title:") then
        config.title = trim(line:match("^title:%s*(.+)")) or config.title
      else
        local parts = {}
        for part in line:gmatch("[^|]+") do
          table.insert(parts, trim(part))
        end

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
  if not relayList then
    return
  end

  relayList:clear()

  for label, info in pairs(relays) do
    if type(info) == "table" then
      local status, fgColor

      if info.online then
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

      relayList:addItem(
        {
          text = string.format("[%s] %s", label, status),
          foreground = fgColor
        }
      )

      if info.online and (info.dim or info.message) then
        local details = string.format("  Dim: %s | %s", info.dim or "?", info.message or "")
        relayList:addItem(
          {
            text = details,
            foreground = colors.lightGray
          }
        )
      end

      relayList:addItem({ text = "", foreground = colors.black }) -- spacer
    end
  end
  basalt.update(os.pullEvent())
end

local function pingRelays()
  if not modem then
    return
  end
  for label, data in pairs(relays) do
    if type(data) == "table" then
      modem.transmit(
        os.getComputerID(),
        RELAY_CHANNEL,
        {
          type = "ping_request",
          target = label
        }
      )
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
  term.setCursorPos(1, 1)
  terminalui.uiprint("Offline relays cleared.")
  sleep(1)
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
      terminalui.uiprint("Relay '" .. label .. "' has timed out.")
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

-- === NEW: MUSIC COMMUNICATION (FIXED) ===
local function sendMusicCommand(command, data)
  if not modem then
    return
  end
  local message = { type = command }

  if type(data) == "table" then
    for k, v in pairs(data) do
      message[k] = v
    end
  end

  terminalui.uiprint("[Main DEBUG] Sending on channel " .. MUSIC_CHANNEL .. ": " .. textutils.serialize(message))
  modem.transmit(MUSIC_CHANNEL, os.getComputerID(), message)
end

local function pingMusicPlayer()
  sendMusicCommand("ping")
end

-- FIXED: Changed command name to match what music player expects
local function saveDiscsFromBarrel()
  terminalui.uiprint("Requesting barrel contents from music player...")
  sendMusicCommand("barrel_request") -- Changed from "listBarrelContents"
end

-- === PLAYER DISC PREFERENCES ===
local function loadPlayerDiscPreferences()
  local players = {}

  -- Ensure the JSON file exists
  if not fs.exists(DISCS_FILE_PATH) then
    if fs.exists("/disk") then
      local file = fs.open(DISCS_FILE_PATH, "w")
      if file then
        file.write(textutils.serializeJSON({}))
        file.close()
        terminalui.uiprint("Created new player disc preferences file: " .. DISCS_FILE_PATH)
      end
    end
    return players
  end

  -- Load and parse JSON
  local file = fs.open(DISCS_FILE_PATH, "r")
  if not file then
    return players
  end

  local data = file.readAll()
  file.close()

  if data and data ~= "" then
    local success, decoded = pcall(textutils.unserializeJSON, data)
    if success and type(decoded) == "table" then
      for player_name, info in pairs(decoded) do
        players[trim(player_name)] = {
          disc = info.disc or "",
          priority = tonumber(info.priority) or 999
        }
      end
    else
      terminalui.uiprint("Warning: Could not parse player disc preferences JSON, starting fresh")
    end
  end

  return players
end
local function savePlayerDiscPreferences(players)
  local data = {}

  for player_name, info in pairs(players) do
    if type(info) == "table" and info.disc then
      data[player_name] = {
        disc = info.disc,
        priority = tonumber(info.priority) or 999
      }
    end
  end

  local file = fs.open(DISCS_FILE_PATH, "w")
  if file then
    file.write(prettyJSON(data))
    file.close()
    terminalui.uiprint("Player disc preferences saved.")
  else
    terminalui.uiprint("Error: Could not save disc preferences.")
  end
end
local function handleBarrelContents(message)
  terminalui.uiprint("Received barrel contents: " .. textutils.serialize(message))

  if not message.items or type(message.items) ~= "table" then
    terminalui.uiprint("Error: Invalid barrel contents received")
    return
  end

  local existingPrefs = loadPlayerDiscPreferences()
  local newDiscsAdded = false
  local discsCount = #message.items

  terminalui.uiprint("Processing " .. discsCount .. " discs from barrel...")

  for _, disc in ipairs(message.items) do
    local found = false
    -- Check if this disc is already assigned to a player
    for player, info in pairs(existingPrefs) do
      if info.disc == disc then
        found = true
        terminalui.uiprint("  " .. disc .. " -> already assigned to " .. player)
        break
      end
    end

    -- If not found, add as fallback entry
    if not found then
      local fallbackKey = "unassigned_" .. math.random(1000, 9999)
      existingPrefs[fallbackKey] = { disc = disc, priority = 999 }
      newDiscsAdded = true
      terminalui.uiprint("  " .. disc .. " -> added as " .. fallbackKey)
    end
  end

  if newDiscsAdded then
    savePlayerDiscPreferences(existingPrefs)
    terminalui.uiprint("Saved " .. discsCount .. " discs to preferences file")
  else
    terminalui.uiprint("All discs were already in the preferences file")
  end

  -- Reload preferences to ensure they're current
  State.playerDiscPreferences = loadPlayerDiscPreferences()
end

local function getClosestPlayerForUI()
  if not playerDetector then
    return nil
  end
  local ok, players =
      pcall(
        function()
          return playerDetector.getPlayersInRange(UI_ACTIVATION_RANGE)
        end
      )
  if not ok or not players or #players == 0 then
    return nil
  end
  local p = players[1]
  local playerName = type(p) == "string" and p or (p.name or p.displayName or tostring(p))
  return replacePlayerName(playerName)
end

-- === REFACTORED MUSIC SYSTEM ===

local function handleMusic()
  if not playerDetector then
    return
  end

  local ok, detectedPlayers =
      pcall(
        function()
          return playerDetector.getPlayersInRange(PLAYER_DETECTION_RANGE)
        end
      )
  if not ok or not detectedPlayers or #detectedPlayers == 0 then
    if State.lastSentDisc ~= nil then
      terminalui.uiprint("Music stopped (no player nearby)")
      sendMusicCommand("stop")
      State.lastSentDisc = nil
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

  -- Only send a command if the desired disc has changed
  if State.lastSentDisc ~= desiredDisc then
    terminalui.uiprint("Requesting to play disc: " .. desiredDisc)
    sendMusicCommand("play", { disc = desiredDisc })
    State.lastSentDisc = desiredDisc
  end
end
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
  clearFrame(contentFrame)
  contentFrame:setBackground(colors.black)

  local headerText = (State.config and State.config.title) or "Chaos Array Monitoring System Version 21"
  local headerLabel = contentFrame:addLabel()
  headerLabel:setText(headerText)
  headerLabel:setPosition(math.floor(monitorWidth / 2 - #headerText / 2) + 1, 1)
  headerLabel:setForeground(colors.white)
  headerLabel:setBackground(colors.black)

  local tabs =
      contentFrame:addTabControl(
        {
          x = 1,
          y = 2,
          width = monitorWidth,
          height = monitorHeight - 1,
          headerBackground = colors.black,
          foreground = colors.white,
          headerHeight = 1,
          background = colors.black,
          headerAlign = "center"
        }
      )

  local tabWidth = monitorWidth

  -- === MAIN TAB ===
  local mainTab = tabs:newTab("Main")
  local yMain = 1
  if State.config and State.config.elements then
    for _, element in ipairs(State.config.elements) do
      if yMain > monitorHeight - 2 then
        break
      end

      if element.type == "label" then
        local txt = element.text
        if State.currentPlayer and string.find(txt, "{player_name}") then
          txt = string.gsub(txt, "{player_name}", State.currentPlayer)
        end
        if element.bold then
          txt = ">> " .. txt .. " <<"
        end

        local wrappedLines = wordWrap(txt, tabWidth - 2)
        for _, line in ipairs(wrappedLines) do
          if yMain > monitorHeight - 2 then
            break
          end
          local x = element.center and math.floor(tabWidth / 2 - #line / 2) + 1 or 1
          mainTab:addLabel({ x = x, y = yMain, width = #line }):setText(line):setForeground(
            colorMap[element.color] or colors.white
          ):setBackground(element.background and colorMap[element.background] or colors.black)
          yMain = yMain + 1
        end
      elseif element.type == "separator" then
        local sepChar = element.text ~= "" and element.text:sub(1, 1) or "-"
        mainTab:addLabel({ x = 1, y = yMain, width = tabWidth }):setText(string.rep(sepChar, tabWidth)):setForeground(
          colorMap[element.color] or colors.gray
        ):setBackground(element.background and colorMap[element.background] or colors.black)
        yMain = yMain + (element.height or 1)
      elseif element.type == "spacer" then
        yMain = yMain + (element.height or 1)
      end
    end
  else
    local txt = "No valid configuration loaded"
    mainTab:addLabel({ x = math.floor(tabWidth / 2 - #txt / 2) + 1, y = 1, width = #txt }):setText(txt):setForeground(
      colors.red
    ):setBackground(colors.black)
  end

  -- === RELAYS TAB ===
  local relaysTab = tabs:newTab("Relays")
  relayList = relaysTab:addList({ x = 1, y = 1, width = tabWidth, height = monitorHeight - 2 })
  relayList:setBackground(colors.black)
  relayList:setForeground(colors.white)
  relayList:setSelectedBackground(colors.blue)
  relayList:setSelectedForeground(colors.white)
  updateRelayList()

  -- === ACTIONS TAB ===
  local actionsTab = tabs:newTab("Actions")
  local yActions = 2
  actionsTab:addLabel({ x = 2, y = 1, foreground = colors.lightGray, text = "Music Controls:" })

  actionsTab:addButton({ x = 2, y = yActions, width = 20, background = colors.red, text = "Stop music" }):onClick(
    function()
      sendMusicCommand("stop")
    end
  )
  yActions = yActions + 3
  actionsTab:addButton({ x = 2, y = yActions, width = 20, text = "Play Default Disc" }):onClick(
    function()
      sendMusicCommand("play", { disc = FALLBACK_DISCS[1] })
    end
  )
  yActions = yActions + 3
  local player = getHighestPriorityPlayer()
  local buttonText = "Play " .. (player and player.displayName or "Fallback") .. "'s music"
  actionsTab:addButton({ x = 2, y = yActions, width = 30, text = buttonText }):onClick(
    function()
      local p = getHighestPriorityPlayer()
      if p and p.disc then
        sendMusicCommand("play", { disc = p.disc })
        terminalui.uiprint("Playing " .. p.displayName .. "'s music: " .. p.disc)
      else
        sendMusicCommand("play", { disc = FALLBACK_DISCS[1] })
        terminalui.uiprint("Playing fallback music: " .. FALLBACK_DISCS[1])
      end
    end
  )
  yActions = yActions + 2

  actionsTab:addLabel({ x = 2, y = yActions, foreground = colors.lightGray, text = "File Management:" })
  yActions = yActions + 1

  actionsTab:addButton({ x = 2, y = yActions, width = 20, text = "Save Discs to File" }):onClick(
    function()
      saveDiscsFromBarrel()
      terminalui.uiprint("Requested barrel contents for saving discs.")
    end
  )

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
  pcall(
    function()
      currentProgressBar:setProgressColor(colors.white)
    end
  )
  currentProgressBar:setDirection("right")

  basalt.setActiveFrame(bootFrame)
  State.currentFrame = "boot"
end

local function updateBootSequence()
  if not State.isBooting then
    return
  end

  State.bootProgress = math.min((State.bootProgress or 0) + 2.5, 100)

  if currentProgressBar then
    pcall(
      function()
        currentProgressBar:setProgress(State.bootProgress)
      end
    )
  end

  if State.bootProgress >= 100 then
    State.isBooting = false
    currentProgressBar = nil
    showContentScreen()
  end
end

local LastLog = { player = nil }

local function logPlayerChange(newPlayer)
  if LastLog.player ~= newPlayer then
    if newPlayer then
      terminalui.uiprint("Player detected: " .. newPlayer)
    else
      terminalui.uiprint("Player left -> Idle")
      showIdleScreen()
    end
    LastLog.player = newPlayer
  end
end

local function eventHandler()
  while true do
    local event = { os.pullEvent() }
    local eventType = event[1]

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
        terminalui.uiprint("=== System Information ===")
        terminalui.uiprint("Monitor: " .. monitorWidth .. "x" .. monitorHeight)
        terminalui.uiprint("Speakers: " .. #speakers)
        terminalui.uiprint("Current Player: " .. (State.currentPlayer or "None"))
        terminalui.uiprint("Current Frame: " .. (State.currentFrame or "None"))
        terminalui.uiprint("Active Relays: " .. tostring(next(relays) ~= nil and 1 or 0))
        terminalui.uiprint("==========================")
      elseif key == keys.f3 then
        sendMusicCommand("save_discs")
        terminalui.uiprint("Sent command to save discs to file.")
      elseif key == keys.f4 then
        terminalUI.updateDriveDropdown()
        terminalui.uiprint("Drive list refreshed")
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
          relays[message.label].flag = message.flag or 0
          relays[message.label].lastSeen = os.epoch("utc")
          relays[message.label].lastPing = os.epoch("utc")
          saveRelayData()
          if State.currentFrame == "content" then
            updateRelayList()
          end
        end
      elseif channel == MUSIC_CHANNEL and type(message) == "table" then
        terminalui.uiprint("[Main] Received on MUSIC_CHANNEL: " .. textutils.serialize(message))

        if message.type == "player_status" then
          terminalui.uiprint("Music player status: " .. (message.disc or "none"))
        elseif message.type == "ping_response" then
          terminalui.uiprint("Music player is online")
        elseif message.type == "barrel_list" then
          terminalui.uiprint("Received barrel list from music player")
          handleBarrelContents(message)
        end
      end
    elseif eventType == "timer" then
      local timerId = event[2]
      if timerId == relayPingTimer then
        pingRelays()
        local now = os.epoch("utc")
        local updated = false
        for label, info in pairs(relays) do
          if type(info) == "table" and info.online and info.lastPing then
            if now - info.lastPing > (PING_TIMEOUT * 1000) then
              info.online = false
              updated = true
              terminalui.uiprint("Relay '" .. label .. "' timed out -> OFFLINE")
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

    basalt.update(table.unpack(event))
  end
end

local lastConfigCheck = 0
local CONFIG_CHECK_INTERVAL = 0.5 -- Check every half second

local function mainLoop()
  while true do
    checkRelayTimeouts()
    if os.epoch("utc") - (State.lastMusicPing or 0) > (PING_INTERVAL * 1000) then
      pingMusicPlayer()
      State.lastMusicPing = os.epoch("utc")
    end

    -- Check config more frequently
    local currentTime = os.epoch("utc")
    if currentTime - lastConfigCheck >= (CONFIG_CHECK_INTERVAL * 1000) then
      lastConfigCheck = currentTime
      local path = getConfigPath()
      local modTime = fs.exists(path) and fs.attributes(path).modified or 0

      -- Check both config and disc preferences files
      local discPath = DISCS_FILE_PATH
      local discModTime = fs.exists(discPath) and fs.attributes(discPath).modified or 0

      if modTime ~= State.lastModTime or discModTime ~= (State.lastDiscModTime or 0) then
        State.lastModTime = modTime
        State.lastDiscModTime = discModTime
        State.config = loadConfig(path)
        State.playerDiscPreferences = loadPlayerDiscPreferences()
        terminalui.uiprint("Config and disc preferences reloaded.")

        -- Only refresh the Main tab content, not the entire frame
        if State.currentFrame == "content" then
          local mainTab = contentFrame:getActiveFrame()
          if mainTab and mainTab:getName() == "Main" then
            mainTab:clear()
            local yMain = 1
            local tabWidth = monitorWidth -- Use monitor width for tab width
            if State.config and State.config.elements then
              for _, element in ipairs(State.config.elements) do
                if element.type == "label" then
                  local txt = element.text
                  if State.currentPlayer and string.find(txt, "{player_name}") then
                    txt = string.gsub(txt, "{player_name}", State.currentPlayer)
                  end
                  if element.bold then
                    txt = ">> " .. txt .. " <<"
                  end
                  local wrappedLines = wordWrap(txt, tabWidth - 2)
                  for _, line in ipairs(wrappedLines) do
                    if yMain > monitorHeight - 2 then
                      break
                    end
                    local x = element.center and math.floor(tabWidth / 2 - #line / 2) + 1 or 1
                    mainTab:addLabel({ x = x, y = yMain, width = #line }):setText(line):setForeground(
                      colorMap[element.color] or colors.white
                    ):setBackground(
                      element.background and colorMap[element.background] or colors.black
                    )
                    yMain = yMain + 1
                  end
                elseif element.type == "separator" then
                  local sepChar = element.text ~= "" and element.text:sub(1, 1) or "-"
                  mainTab:addLabel({ x = 1, y = yMain, width = tabWidth }):setText(
                    string.rep(sepChar, tabWidth)
                  ):setForeground(colorMap[element.color] or colors.gray):setBackground(
                    element.background and colorMap[element.background] or colors.black
                  )
                  yMain = yMain + (element.height or 1)
                elseif element.type == "spacer" then
                  yMain = yMain + (element.height or 1)
                end
              end
            end
            basalt.update()
          end
        end
      end
    end

    local closestPlayer = getClosestPlayerForUI()
    logPlayerChange(closestPlayer)

    if closestPlayer then
      if State.isIdle then
        State.currentPlayer = closestPlayer
        State.isIdle = false
        State.isBooting = true
        State.bootProgress = 0
        currentProgressBar = nil
        showBootScreen(closestPlayer)
      end
    elseif not closestPlayer and not State.isIdle then
      State.currentPlayer = nil
      State.isIdle = true
      State.idleBuilt = false
      showIdleScreen()
    end

    if State.isBooting then
      updateBootSequence()
    end

    handleMusic()

    sleep(0.05)
  end
end

-- System startup messages
terminalui.uiprint("Initializing display...")
loadRelayData()
State.config = loadConfig(getConfigPath())
State.playerDiscPreferences = loadPlayerDiscPreferences()

terminalui.uiprint("Starting Tellraw Music Monitor System...")
terminalui.uiprint("Monitor size: " .. monitorWidth .. "x" .. monitorHeight)
terminalui.uiprint("Found speakers: " .. #speakers)
terminalui.uiprint("Controls:")
terminalui.uiprint("F1 - Shell | F2 - System Info | F3 - Save discs (Remote)")
terminalui.uiprint("F4 - Refresh drives | F5 - Toggle Warning | F6 - Clear Offline Relays")
terminalui.uiprint("Use the terminal UI for drive selection and log viewing")
terminalui.uiprint("")

showIdleScreen()
parallel.waitForAny(mainLoop, eventHandler)
