local PrimeUI = require("primeui.lua")
local version = "1.0"
local github_url = "https://raw.githubusercontent.com/Darklord2996/Dark-OS/refs/heads/main/index.json"
local modules = {}

if not term.isColor() then
    print("This program requires an advanced computer.")
    return
end

-- Fetch the index from GitHub
local function fetchIndex()
    local response = http.get(github_url)
    if not response then
        error("Failed to fetch the index from GitHub.")
    end

    local data = response.readAll()
    response.close()

    modules = textutils.unserialiseJSON(data)
    if not modules then
        error("Failed to parse the index JSON.")
    end
end

-- Display startup loading bar using PrimeUI
local function startupScreen()
    term.clear()
    term.setCursorPos(1, 1)
    print("Starting up...")
    local win = window.create(term.current(), 1, 2, term.getSize(), 1)
    local progressBar = PrimeUI.progressBar(win, 1, 1, term.getSize(), colors.white, colors.black, true)
    for i = 1, 30 do
        sleep(0.05)
        progressBar(i / 30)
    end

    print("Startup complete!")
    sleep(1)
end

local function downloadProgram(programUrl, programName)
    local response = http.get(programUrl)
    if not response then
        error("Failed to download the program from GitHub.")
    end

    local file = fs.open(programName, "w")
    file.write(response.readAll())
    file.close()
    response.close()
end

local function uninstallProgram(programName)
    if fs.exists(programName) then
        fs.delete(programName)
        print("Program uninstalled successfully: " .. programName)
    else
        print("Program not found: " .. programName)
    end
end

local shellIds = {}

local function launchProgram(programName)
    local shellId = multishell.launch({}, programName)
    shellIds[programName] = shellId
end

local function quitProgram(programName)
    local shellId = shellIds[programName]
    if shellId then
        multishell.terminate(shellId)
        shellIds[programName] = nil
    end
end

-- Main UI function
local function mainUI()
    term.clear()
    term.setCursorPos(1, 1)
    print("Dark OS v" .. version)
    print("Available Modules:")

    -- Create a window for the UI
    local win = window.create(term.current(), 1, 1, term.getSize())

    -- Draw a border around the window
    PrimeUI.borderBox(win, 1, 1, win.getSize(), win.getSize(), colors.white, colors.black)

    -- Draw the title
    PrimeUI.centerLabel(win, 1, 1, win.getSize(), "Dark OS v" .. version, colors.white, colors.black)

    -- Draw the description area
    local function drawDescription()
        for y = 4, 10 do
            win.setCursorPos(20, y)
            win.write(string.rep(" ", 50))
        end

        -- Display the description of the selected module
        if modules[selectedModule] then
            win.setCursorPos(20, 4)
            win.write("Description:")
            win.setCursorPos(20, 5)
            win.write(modules[selectedModule].description)
        end
    end

    -- Create buttons for each module
    local buttons = {}
    local yOffset = 4
    for i, module in ipairs(modules) do
        PrimeUI.button(win, 2, yOffset, module.name, function()
            selectedModule = i
            drawDescription()
        end)
        yOffset = yOffset + 3
    end

    -- Draw the footer buttons
    PrimeUI.button(win, 2, yOffset + 2, "Install", function()
        local selected = modules[selectedModule]
        if selected then
            print("Downloading " .. selected.name .. "...")
            downloadProgram(selected.url, selected.name .. ".lua")
            print("Download complete!")
        end
    end)

    PrimeUI.button(win, 14, yOffset + 2, "Uninstall", function()
        local selected = modules[selectedModule]
        if selected then
            print("Uninstalling " .. selected.name .. "...")
            uninstallProgram(selected.name .. ".lua")
            print("Uninstall complete!")
        end
    end)

    PrimeUI.button(win, 26, yOffset + 2, "Launch", function()
        local selected = modules[selectedModule]
        if selected then
            print("Launching " .. selected.name .. "...")
            launchProgram(selected.name .. ".lua")
        end
    end)

    PrimeUI.button(win, 38, yOffset + 2, "Quit", function()
        local selected = modules[selectedModule]
        if selected then
            print("Quitting " .. selected.name .. "...")
            quitProgram(selected.name .. ".lua")
        end
    end)

    PrimeUI.run()
end

local function main()
    startupScreen()
    fetchIndex()
    mainUI()
end

main()
