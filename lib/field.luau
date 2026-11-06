--!strict
-- Text field for Tern `input` and `editor` nodes. The host owns the string; this module owns the caret.
-- `cursor` is a 0-based Unicode codepoint index (not a byte index, and not a UTF-16 offset).
-- `lines` enables a multi-line prompt: Enter inserts a newline, Up/Down move by line, Home/End jump
-- to the current line. Without `lines` the field stays one line and a paste drops newlines.
-- Keys arrive through `M.key`; with the block's `edit` feature on, Tern keeps the selection itself
-- (⌘A, ⇧-arrows, drag) and sends what it changes as `edit` events, applied by `M.edit`.

local M = {}

export type Field = {
	text: string,
	cursor: number,
	name: string?,
	-- Multi-line prompt. Nil or false keeps the one-line contract (paste strips newlines, Up/Down do nothing).
	lines: boolean?,
	-- Sticky column for Up/Down. Cleared by any horizontal edit so the next vertical move starts fresh.
	col: number?,
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

-- UTF-16 length of `text`; invalid UTF-8 counts bytes, matching `utf16_cursor`.
local function len16(text: string): number
	if utf8.len(text) == nil then
		return #text
	end
	local n = 0
	for _, cp in utf8.codes(text) do
		n += units(cp)
	end
	return n
end

-- Byte index (1-based) and codepoint index (0-based) of UTF-16 offset `off` in `text`. An offset
-- inside a surrogate pair rounds down to the character it splits; past the end clamps to the end.
-- Invalid UTF-8 treats offsets as bytes, matching `utf16_cursor`.
local function from16(text: string, off: number): (number, number)
	if utf8.len(text) == nil then
		local b = clamp(math.floor(off), 0, #text)
		return b + 1, b
	end
	local u = 0
	local i = 0
	for p, cp in utf8.codes(text) do
		local w = units(cp)
		if u + w > off then
			return p, i
		end
		u += w
		i += 1
	end
	return #text + 1, i
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

local function clear_col(f: Field)
	f.col = nil
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
	clear_col(f)
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
	clear_col(f)
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
	clear_col(f)
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
		clear_col(f)
		return true
	end
	f.text = string.sub(f.text, b)
	f.cursor = 0
	clear_col(f)
	return true
end

local function move(f: Field, delta: number): boolean
	local n = cps(f.text)
	local next_ = clamp(f.cursor + delta, 0, n)
	if next_ == f.cursor then
		return false
	end
	f.cursor = next_
	clear_col(f)
	return true
end

-- Codepoints in bytes `i..j` of `text` (0 when empty); invalid UTF-8 counts bytes.
local function span_len(text: string, i: number, j: number): number
	if j < i then
		return 0
	end
	return utf8.len(text, i, j) or (j - i + 1)
end

-- Line containing `cursor`: 1-based start codepoint, content length (the trailing newline is not
-- content), and the 0-based column. A caret right after a newline is at column 0 of the next line.
-- Works on bytes with string.find, so a long prompt costs one pass, not one per character.
local function line_span(text: string, cursor: number): (number, number, number)
	local c = clamp(cursor, 0, cps(text))
	local b = at(text, c) or (#text + 1)
	local s = 1
	while true do
		local nl = string.find(text, "\n", s, true)
		if nl == nil or nl >= b then
			break
		end
		s = nl + 1
	end
	local e = string.find(text, "\n", b, true) or (#text + 1)
	return span_len(text, 1, s - 1) + 1, span_len(text, s, e - 1), span_len(text, s, b - 1)
end

-- Move to the same column on the previous or next line. Returns false when there is no such line;
-- the sticky column is kept either way so a later move in the other direction still lands on it.
local function move_vert(f: Field, delta: number): boolean
	local text = f.text
	local start, content, col = line_span(text, f.cursor)
	local want = f.col or col
	f.col = want
	if delta < 0 then
		if start <= 1 then
			return false
		end
		-- The caret just before this line's leading newline sits on the previous line.
		local pstart, pcontent = line_span(text, start - 2)
		f.cursor = pstart - 1 + math.min(want, pcontent)
		return true
	end
	local before_nl = start - 1 + content
	if before_nl >= cps(text) then
		return false
	end
	local nstart, ncontent = line_span(text, before_nl + 1)
	f.cursor = nstart - 1 + math.min(want, ncontent)
	return true
end

-- Turn CR/LF and bare CR into `\n`. Single-line fields then drop the newlines.
local function normalize(s: string): string
	return (string.gsub(string.gsub(s, "\r\n", "\n"), "\r", "\n"))
end

local function one_line(s: string): string
	return (string.gsub(normalize(s), "\n", ""))
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
		return insert(f, if f.lines then normalize(raw) else one_line(raw))
	end
	if key.meta and key.name == "backspace" then
		return delete_to_start(f)
	end
	if key.ctrl and (key.name == "a" or key.name == "e") then
		return move(f, if key.name == "a" then -cps(f.text) else cps(f.text))
	end
	if f.lines and key.name == "enter" and not key.ctrl and not key.alt and not key.meta and not key.shift then
		return insert(f, "\n")
	end
	if f.lines and (key.name == "up" or key.name == "down") and not key.ctrl and not key.alt and not key.meta then
		return move_vert(f, if key.name == "up" then -1 else 1)
	end
	if f.lines and (key.name == "home" or key.name == "end") and not key.ctrl and not key.meta then
		local start, content, _col = line_span(f.text, f.cursor)
		local target = if key.name == "home" then start - 1 else start - 1 + content
		if target == f.cursor then
			return false
		end
		f.cursor = target
		clear_col(f)
		return true
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
	return insert(f, if f.lines then raw else one_line(raw))
end

-- Apply a native `edit` event (`{from, to, text, cursor, len}`, UTF-16 offsets): replace
-- `from..to` with `text` and put the caret at `cursor`. An edit computed against another text
-- (`len` differs: a key landed in between) is dropped rather than spliced in the wrong place.
-- A one-line field drops newlines from the inserted text and puts the caret after it.
-- Returns false when nothing changed.
function M.edit(f: Field, ev: { [string]: any }): boolean
	local from, to, text, cursor, len = ev.from, ev.to, ev.text, ev.cursor, ev.len
	if type(from) ~= "number" or type(to) ~= "number" or type(text) ~= "string" or type(cursor) ~= "number" then
		return false
	end
	if type(len) ~= "number" or len ~= len16(f.text) then
		return false
	end
	if to < from then
		from, to = to, from
	end
	local bfrom, cfrom = from16(f.text, from)
	local bto = from16(f.text, to)
	local chunk = if f.lines then normalize(text) else one_line(text)
	local new = string.sub(f.text, 1, bfrom - 1) .. chunk .. string.sub(f.text, bto)
	local caret: number
	if chunk == text then
		local _, c = from16(new, cursor)
		caret = c
	else
		caret = cfrom + cps(chunk)
	end
	if new == f.text and caret == f.cursor then
		return false
	end
	f.text = new
	f.cursor = caret
	clear_col(f)
	return true
end

return M
