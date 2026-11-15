--[[
        Specification according to Cowgod's guide:

        Memory:
        4KB of RAM
        Program starts at 0x200

        Registers:
        16 general-purpose 8-bit registers referred to as Vx (x goes from 0x0 through 0xF)
        A 16-bit register called I
        Two special 8-bit registers: delay and sound timers
        Program counter (PC) is 16-bit and stores the address of the next instruction
        Stack pointer (SP) is 8-bit and points to the top of the stack
        There is a stack with 16 16-bit entries that works as an array

        Keyboard:
        1 2 3 C
        4 5 6 D
        7 8 9 E
        A 0 B F

        Display:
        64x32 display with monochrome pixels
        There is also a group of 5-byte-long sprites that represent a digit from 0x0 to 0xF

        Instructions:
        It has 36 instructions, all of them 2 bytes long and stored big-endian
        Each instruction may have the following variables:
                nnn     -> lowest 12 bits
                n       -> lowest 4 bits 
                x       -> lower 4 bits of the high byte
                y       -> upper 4 bits of the low byte
                kk      -> low byte
]]--

local Chip8 = {}
Chip8.__index = Chip8

Chip8.DISPLAY_WIDTH = 64
Chip8.DISPLAY_HEIGHT = 32

local FONT = {
        0xF0, 0x90, 0x90, 0x90, 0xF0, -- 0
        0x20, 0x60, 0x20, 0x20, 0x70, -- 1
        0xF0, 0x10, 0xF0, 0x80, 0xF0, -- 2
        0xF0, 0x10, 0xF0, 0x10, 0xF0, -- 3
        0x90, 0x90, 0xF0, 0x10, 0x10, -- 4
        0xF0, 0x80, 0xF0, 0x10, 0xF0, -- 5
        0xF0, 0x80, 0xF0, 0x90, 0xF0, -- 6
        0xF0, 0x10, 0x20, 0x40, 0x40, -- 7
        0xF0, 0x90, 0xF0, 0x90, 0xF0, -- 8
        0xF0, 0x90, 0xF0, 0x10, 0xF0, -- 9
        0xF0, 0x90, 0xF0, 0x90, 0x90, -- A
        0xE0, 0x90, 0xE0, 0x90, 0xE0, -- B
        0xF0, 0x80, 0x80, 0x80, 0xF0, -- C
        0xE0, 0x90, 0x90, 0x90, 0xE0, -- D
        0xF0, 0x80, 0xF0, 0x80, 0xF0, -- E
        0xF0, 0x80, 0xF0, 0x80, 0x80  -- F
}

-- Creates an array with N elements (starting at index 0)
local function nelem(n)
        local arr = {}

        for i = 0, n - 1 do
                arr[i] = 0
        end

        return arr
end

function Chip8:new(rand)
        local o = {}
        setmetatable(o, self)

        o.memory = nelem(4096)
        o.v = nelem(16)
        o.i = 0x0000
        o.delay_timer = 0x00
        o.sound_timer = 0x00
        o.pc = 0x0000
        o.sp = 0x00
        o.stack = {}

        o.keypad = {}
        o.last_key_pressed = nil

        for i = 0x0, 0xF do
                o.keypad[i] = false
        end

        o.display = nelem(Chip8.DISPLAY_WIDTH * Chip8.DISPLAY_HEIGHT)

        o.rand = rand -- Generates a random byte

        o.waiting_vblank = true -- Flag that simulates the display interrupt (DXYN waits until it is cleared)

        return o
end

function Chip8:init()
        self.pc = 0x200

        for offset = 1, 5 * 16 do
                self.memory[0x000 + offset - 1] = FONT[offset]
        end
end

function Chip8:load(rom, size)
        for offset = 0, size - 1 do
                self.memory[0x200 + offset] = string.byte(rom, offset + 1)
        end
end

-- Clear the display
function Chip8:instr_00e0(args)
        for i = 0, (Chip8.DISPLAY_WIDTH * Chip8.DISPLAY_HEIGHT) - 1 do
                self.display[i] = 0x00
        end
end

-- Return from a subroutine
function Chip8:instr_00ee(args)
        self.pc = self.stack[self.sp]
        self.sp = self.sp - 1
end

-- Jump to location nnn
function Chip8:instr_1nnn(args)
        self.pc = args.nnn
end

-- Call subroutine at nnn
function Chip8:instr_2nnn(args)
        self.sp = self.sp + 1
        self.stack[self.sp] = self.pc
        self.pc = args.nnn
end

-- Used by 3XKK, 4XKK, 5XY0, EX9E, EXA1, 9XY0
function Chip8:SkipIf(cond)
        if cond then
                self.pc = self.pc + 2
        end
end

-- Set Vx = kk
function Chip8:instr_6xkk(args)
        self.v[args.x] = args.kk
end

-- Set Vx = Vx + kk
function Chip8:instr_7xkk(args)
        self.v[args.x] = bit.band(self.v[args.x] + args.kk, 0xFF)
end

-- Set Vx = Vy
function Chip8:instr_8xy0(args)
        self.v[args.x] = self.v[args.y]
end

-- Set Vx = Vx OR Vy
function Chip8:instr_8xy1(args)
        self.v[args.x] = bit.bor(self.v[args.x], self.v[args.y])
        self:set_flag(false)
end

-- Set Vx = Vx AND Vy
function Chip8:instr_8xy2(args)
        self.v[args.x] = bit.band(self.v[args.x], self.v[args.y])
        self:set_flag(false)
end

-- Set Vx = Vx XOR Vy
function Chip8:instr_8xy3(args)
        self.v[args.x] = bit.bxor(self.v[args.x], self.v[args.y])
        self:set_flag(false)
end

function Chip8:set_flag(cond)
        self.v[0xF] = cond and 0x01 or 0x00
end

-- Set Vx = Vx + Vy, set VF = carry
function Chip8:instr_8xy4(args)
        local result = self.v[args.x] + self.v[args.y]

        self.v[args.x] = bit.band(result, 0xFF)
        self:set_flag(result > 0xFF)
end

-- Set Vx = Vx - Vy, set VF = NOT borrow
function Chip8:instr_8xy5(args)
        local x, y = args.x, args.y
        local vx, vy = self.v[x], self.v[y]
        local result = vx - vy

        self.v[x] = bit.band(result, 0xFF)
        self:set_flag(not (vx < vy))
end

-- Set VF = 1 if LSB(Vx) is set, then right shift Vx by 1
function Chip8:instr_8xy6(args)
        local x = args.x
        self.v[x] = self.v[args.y]
        local vx = self.v[x]
        local lsb = bit.band(vx, 0x01)

        self.v[x] = bit.rshift(vx, 1)
        self:set_flag(lsb == 0x01)
end

-- Set Vx = Vy - Vx, set VF = NOT borrow
function Chip8:instr_8xy7(args)
        local x, y = args.x, args.y
        local vx, vy = self.v[x], self.v[y]
        local result = vy - vx

        self.v[x] = bit.band(result, 0xFF)
        self:set_flag(not (vy < vx))
end

-- Set VF = 1 if MSB(Vx) is set, then left shift Vx by 1
function Chip8:instr_8xye(args)
        local x = args.x
        self.v[x] = self.v[args.y]
        local vx = self.v[x]
        local msb = bit.band(bit.rshift(vx, 7), 0x01)

        self.v[x] = bit.band(bit.lshift(vx, 1), 0xFF)
        self:set_flag(msb == 0x01)
end

-- Set I = nnn
function Chip8:instr_annn(args)
        self.i = args.nnn
end

-- Jump to location nnn + V0
function Chip8:instr_bnnn(args)
        self.pc = args.nnn + self.v[0x0]
end

-- Set Vx = random byte AND kk
function Chip8:instr_cxkk(args)
        self.v[args.x] = bit.band(self.rand(), args.kk)
end

function Chip8:get_coord_addr(x, y)
        local row_size = 64
        local row_offset = row_size * y
        local col = x
        local addr = row_offset + col

        return addr
end

function Chip8:get_pixel(x, y)
        return self.display[self:get_coord_addr(x, y)]
end

function Chip8:put_pixel(x, y, state)
        self.display[self:get_coord_addr(x, y)] = state and 0x01 or 0x00
end

-- Display n-byte sprite starting at memory location I at (Vx, Vy), set VF = collision
function Chip8:instr_dxyn(args)
        if self.waiting_vblank then
                self.pc = self.pc - 2
                return
        end

        local n = args.n
        local vx, vy = self.v[args.x], self.v[args.y]
        local y = vy % Chip8.DISPLAY_HEIGHT

        self:set_flag(false)

        for i = 0, n - 1 do
                if y >= Chip8.DISPLAY_HEIGHT then
                        break
                end

                local x = vx % Chip8.DISPLAY_WIDTH
                local byte = self.memory[self.i + i]

                for j = 0, 7 do
                        if x >= Chip8.DISPLAY_WIDTH then
                                break
                        end

                        local old_pixel = self:get_pixel(x, y)
                        local new_pixel = bit.band(bit.rshift(byte, 7 - j), 0x01)

                        if new_pixel == 0x01 then
                                self:put_pixel(x, y, old_pixel == 0x00)

                                if old_pixel == 0x01 then
                                        self:set_flag(true)
                                end
                        end

                        x = x + 1
                end

                y = y + 1
        end

        self.waiting_vblank = true
end

-- Set Vx = delay timer value
function Chip8:instr_fx07(args)
        self.v[args.x] = self.delay_timer
end

-- Wait for a key to be pressed and released, then put its value in Vx
function Chip8:instr_fx0a(args)
        local key = nil

        if not self.last_key_pressed then
                for i = 0x0, 0xF do
                        local pressed  = self.keypad[i]

                        if pressed then
                                self.last_key_pressed = i
                                break
                        end
                end
        else
                local last = self.last_key_pressed
                local released = not self.keypad[last]

                if released then
                        key = last
                        self.last_key_pressed = nil
                end
        end

        if key then
                self.v[args.x] = key
        else
                self.pc = self.pc - 2
        end
end

-- Set delay timer = Vx
function Chip8:instr_fx15(args)
        self.delay_timer = self.v[args.x]
end

-- Set sound timer = Vx
function Chip8:instr_fx18(args)
        self.sound_timer = self.v[args.x]
end

-- Set I = I + Vx
function Chip8:instr_fx1e(args)
        self.i = self.i + self.v[args.x]
end

-- Set I = location of sprite for digit Vx
function Chip8:instr_fx29(args)
        local d = bit.band(self.v[args.x], 0xF)

        self.i = 0x000 + 5 * d
end

-- Store BCD representation of Vx in memory locations I, I+1 and I+2
function Chip8:instr_fx33(args)
        local value = self.v[args.x]

        -- Integer division by 10 works like a binary right shift
        -- Modulo by 10 gets the digit in the ones place
        local ones = value % 10
        value = math.floor(value / 10)
        local tens = value % 10
        value = math.floor(value / 10)
        local hundreds = value % 10

        local i = self.i

        self.memory[i] = hundreds
        self.memory[i + 1] = tens
        self.memory[i + 2] = ones
end

-- Store registers V0 through Vx in memory starting at location I
function Chip8:instr_fx55(args)
        for i = 0, args.x do
                self.memory[self.i] = self.v[i]
                self.i = self.i + 1
        end
end

-- Read registers V0 through Vx from memory starting at location I
function Chip8:instr_fx65(args)
        for i = 0, args.x do
                self.v[i] = self.memory[self.i]
                self.i = self.i + 1
        end
end

local EIGHT_FAMILY = {
        [0x0] = function(self, args) self:instr_8xy0(args) end,
        [0x1] = function(self, args) self:instr_8xy1(args) end,
        [0x2] = function(self, args) self:instr_8xy2(args) end,
        [0x3] = function(self, args) self:instr_8xy3(args) end,
        [0x4] = function(self, args) self:instr_8xy4(args) end,
        [0x5] = function(self, args) self:instr_8xy5(args) end,
        [0x6] = function(self, args) self:instr_8xy6(args) end,
        [0x7] = function(self, args) self:instr_8xy7(args) end,
        [0xE] = function(self, args) self:instr_8xye(args) end
}

local F_FAMILY = {
        [0x07] = function(self, args) self:instr_fx07(args) end,
        [0x0A] = function(self, args) self:instr_fx0a(args) end,
        [0x15] = function(self, args) self:instr_fx15(args) end,
        [0x18] = function(self, args) self:instr_fx18(args) end,
        [0x1E] = function(self, args) self:instr_fx1e(args) end,
        [0x29] = function(self, args) self:instr_fx29(args) end,
        [0x33] = function(self, args) self:instr_fx33(args) end,
        [0x55] = function(self, args) self:instr_fx55(args) end,
        [0x65] = function(self, args) self:instr_fx65(args) end
}

local OPCODES = {
        [0x0] = function(self, args)
                        local nnn = args.nnn

                        if nnn == 0xE0 then
                                self:instr_00e0(args)
                        elseif nnn == 0xEE then
                                self:instr_00ee(args)
                        end
                end,

        [0x1] = function(self, args) self:instr_1nnn(args) end,
        [0x2] = function(self, args) self:instr_2nnn(args) end,

        [0x3] = function(self, args) self:SkipIf(self.v[args.x] == args.kk) end,
        [0x4] = function(self, args) self:SkipIf(self.v[args.x] ~= args.kk) end,
        [0x5] = function(self, args)
                        if args.n == 0x00 then
                                self:SkipIf(self.v[args.x] == self.v[args.y])
                        end
                end,

        [0x6] = function(self, args) self:instr_6xkk(args) end,
        [0x7] = function(self, args) self:instr_7xkk(args) end,

        [0x8] = function(self, args)
                        local fn = EIGHT_FAMILY[args.n]

                        if fn then
                                fn(self, args)
                        end
                end,

        [0x9] = function(self, args)
                        if args.n == 0x00 then
                                self:SkipIf(self.v[args.x] ~= self.v[args.y])
                        end
                end,

        [0xA] = function(self, args) self:instr_annn(args) end,
        [0xB] = function(self, args) self:instr_bnnn(args) end,
        [0xC] = function(self, args) self:instr_cxkk(args) end,
        [0xD] = function(self, args) self:instr_dxyn(args) end,

        [0xE] = function(self, args)
                        local cond = false
                        local kk = args.kk
                        local vx = bit.band(self.v[args.x], 0xF) -- The valid values are between 0x0 and 0xF

                        if kk == 0x9E then
                                cond = self.keypad[vx]
                        elseif kk == 0xA1 then
                                cond = not self.keypad[vx]
                        end

                        self:SkipIf(cond)
                end,

        [0xF] = function(self, args)
                        local fn = F_FAMILY[args.kk]

                        if fn then
                                fn(self, args)
                        end
                end
}

function Chip8:fetch()
        local hi = self.memory[self.pc]
        local lo = self.memory[self.pc + 1]

        self.pc = self.pc + 2

        return bit.band(bit.bor(bit.lshift(hi, 8), lo), 0xFFFF)
end

function Chip8:decode(instruction)
        local op = bit.band(bit.rshift(instruction, 12), 0xF)
        local nnn = bit.band(instruction, 0xFFF)
        local n = bit.band(instruction, 0xF)
        local x = bit.band(bit.rshift(instruction, 8), 0xF)
        local y = bit.band(bit.rshift(instruction, 4), 0xF)
        local kk = bit.band(instruction, 0xFF)

        return { op = op, nnn = nnn, n = n, x = x, y = y, kk = kk }
end

function Chip8:execute(args)
        local fn = OPCODES[args.op]

        if fn then
                fn(self, args)
        end
end

function Chip8:cycle()
        self:execute(self:decode(self:fetch()))
end

return Chip8

