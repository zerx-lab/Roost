--!strict
-- One-line text field for Tern `input` nodes. The host owns the string; this module owns the caret.
-- `cursor` is a 0-based Unicode codepoint index (not a byte index, and not a UTF-16 offset).

local M = {}

export type Field = {
	text: string,
	cursor: number,
	name: string?,
}

-- Codepoints in `s`. Invalid UTF-8 is counted byte by byte so a bad paste cannot move the caret
-- past the end or trap a later edit.
local function cps(s: string): number
	local n = utf8.len(s)
	if n == nil then
		return #s
	end
	return n
end

local function clamp(n: number, lo: number, hi: number): number
	if n < lo then
		return lo
	end
	if n > hi then
		return hi
	end
	return n
end

-- Byte index of codepoint `i` (0-based). `i == cps` returns the byte just past the end.
local function at(text: string, i: number): number?
	if utf8.len(text) == nil then
		return i + 1
	end
	return utf8.offset(text, i + 1)
end

-- How many UTF-16 code units a codepoint occupies. Non-BMP (emoji) takes a surrogate pair.
local function units(cp: number): number
	if cp > 0xFFFF then
		return 2
	end
	return 1
end

-- UTF-16 offset of `cursor` from the start of `text`. This is what an `input` node's `cursor`
-- prop wants. Invalid UTF-8 falls back to the byte length so the caret still lands.
function M.utf16_cursor(f: Field): number
	local n = utf8.len(f.text)
	if n == nil then
		return clamp(f.cursor, 0, #f.text)
	end
	local off = 0
	local i = 0
	for _, cp in utf8.codes(f.text) do
		if i >= f.cursor then
			break
		end
		off += units(cp)
		i += 1
	end
	return off
end

-- UTF-8 length of the codepoint starting at byte `b`, or 1 when the sequence is invalid.
-- The last codepoint has no following offset, so the remainder of the string is its length.
local function cp_len(text: string, b: number): number
	if utf8.len(text, b, b) ~= 1 then
		return 1
	end
	local nxt = utf8.offset(text, 2, b)
	if nxt then
		return nxt - b
	end
	return #text - b + 1
end

local function insert(f: Field, chunk: string): boolean
	if chunk == "" then
		return false
	end
	local b = at(f.text, f.cursor)
	if b == nil then
		f.cursor = cps(f.text)
	end
	local pos: number = b or (#f.text + 1)
	f.text = string.sub(f.text, 1, pos - 1) .. chunk .. string.sub(f.text, pos)
	f.cursor += cps(chunk)
	return true
end

local function delete_before(f: Field): boolean
	if f.cursor <= 0 then
		return false
	end
	local b = at(f.text, f.cursor)
	if b == nil then
		return false
	end
	local prev = at(f.text, f.cursor - 1)
	if prev == nil then
		return false
	end
	f.text = string.sub(f.text, 1, prev - 1) .. string.sub(f.text, b)
	f.cursor -= 1
	return true
end

local function delete_after(f: Field): boolean
	local n = cps(f.text)
	if f.cursor >= n then
		return false
	end
	local b = at(f.text, f.cursor)
	if b == nil then
		return false
	end
	local nxt = b + cp_len(f.text, b)
	f.text = string.sub(f.text, 1, b - 1) .. string.sub(f.text, nxt)
	return true
end

-- Delete back to the start, leaving whatever follows the caret. Meta+Backspace.
local function delete_to_start(f: Field): boolean
	if f.cursor <= 0 then
		return false
	end
	local b = at(f.text, f.cursor)
	if b == nil then
		f.cursor = 0
		f.text = ""
		return true
	end
	f.text = string.sub(f.text, b)
	f.cursor = 0
	return true
end

local function move(f: Field, delta: number): boolean
	local n = cps(f.text)
	local next_ = clamp(f.cursor + delta, 0, n)
	if next_ == f.cursor then
		return false
	end
	f.cursor = next_
	return true
end

-- Strip CR/LF. A field is one line; a pasted block must not smuggle a newline into dispatch.
local function one_line(s: string): string
	return (string.gsub(s, "[\r\n]+", ""))
end

-- Apply one key. Returns false when the text and caret are unchanged, so the caller can skip
-- a re-render. Printable text is inserted only when Ctrl/Alt/Meta are up; those chords are
-- shortcuts (Ctrl+A/E, Meta+Backspace) or belong to the block.
function M.key(f: Field, key: Key): boolean
	if key.name == "paste" then
		local raw = key.text
		if type(raw) ~= "string" or raw == "" then
			return false
		end
		return insert(f, one_line(raw))
	end
	if key.meta and key.name == "backspace" then
		return delete_to_start(f)
	end
	if key.ctrl and (key.name == "a" or key.name == "e") then
		return move(f, if key.name == "a" then -cps(f.text) else cps(f.text))
	end
	if key.name == "backspace" then
		return delete_before(f)
	end
	if key.name == "delete" then
		return delete_after(f)
	end
	if key.name == "left" then
		return move(f, -1)
	end
	if key.name == "right" then
		return move(f, 1)
	end
	if key.name == "home" then
		return move(f, -cps(f.text))
	end
	if key.name == "end" then
		return move(f, cps(f.text))
	end
	-- Shortcuts and dead chords must not leak a character into the field.
	if key.ctrl or key.alt or key.meta then
		return false
	end
	local raw = key.text
	if type(raw) ~= "string" or raw == "" then
		return false
	end
	return insert(f, one_line(raw))
end

return M
