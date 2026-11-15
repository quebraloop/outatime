local Chip8 = require("chip8")

local emu = {}
local beep
local SCALE = 20

local KEYPAD_MAP = {
        ['1'] = 0x1, ['2'] = 0x2, ['3'] = 0x3, ['4'] = 0xC,
        ['q'] = 0x4, ['w'] = 0x5, ['e'] = 0x6, ['r'] = 0xD,
        ['a'] = 0x7, ['s'] = 0x8, ['d'] = 0x9, ['f'] = 0xE,
        ['z'] = 0xA, ['x'] = 0x0, ['c'] = 0xB, ['v'] = 0xF
}

local function rand()
        return math.random(0x00, 0xFF)
end

function love.load(args)
        local path = args[1]
        assert(path, "No path to the ROM")

        love.window.setTitle("CHIP-8")
        love.window.setMode(Chip8.DISPLAY_WIDTH * SCALE, Chip8.DISPLAY_HEIGHT * SCALE)
        love.graphics.setColor(1, 1, 1)
        love.graphics.setBackgroundColor(0, 0, 0)

        math.randomseed(os.time())

        beep = love.audio.newSource("beep.wav", "static")

        emu = Chip8:new(rand)

        emu:init()

        local rom, size = love.filesystem.read(path)

        emu:load(rom, size)
end

local dtotal = 0
local FPS = 60
local FRAMETIME = 1 / FPS
local CYCLES_PER_SECOND = 720
local CYCLES_PER_FRAME = CYCLES_PER_SECOND / FPS

function love.update(dt)
        dtotal = dtotal + dt

        while dtotal >= FRAMETIME do
                dtotal = dtotal - FRAMETIME

                for i = 1, CYCLES_PER_FRAME do
                        emu:cycle()
                end

                if emu.waiting_vblank then
                        emu.waiting_vblank = false
                end

                if emu.delay_timer > 0 then
                        emu.delay_timer = emu.delay_timer - 1
                end

                if emu.sound_timer > 0 then
                        -- Beep
                        beep:stop()
                        beep:play()

                        emu.sound_timer = emu.sound_timer - 1
                end
        end
end

function love.draw()
        for y = 0, Chip8.DISPLAY_HEIGHT - 1 do
                for x = 0, Chip8.DISPLAY_WIDTH - 1 do
                        if emu:get_pixel(x, y) == 0x01 then
                                love.graphics.rectangle("fill", x * SCALE, y * SCALE, SCALE, SCALE)
                        end
                end
        end
end

function love.keypressed(key, scancode, isrepeat)
        local k = KEYPAD_MAP[scancode]

        if k then
                emu.keypad[k] = true
        end

        if key == "escape" then
                love.event.quit()
        end
end

function love.keyreleased(key, scancode)
        local k = KEYPAD_MAP[scancode]

        if k then
                emu.keypad[k] = false
        end
end

