--!strict
-- TOML 1.0 subset. Dates are rejected. Integers and floats are Luau numbers.
-- `positions[tbl][key]` is the 1-based line where that key was defined.
-- Array-of-tables elements record the header line at `positions[arr][i]`.

local M = {}

export type Err = { line: number, col: number, message: string }
export type Positions = { [any]: { [any]: number } }

local MAX_BYTES = 1024 * 1024
local MAX_DEPTH = 32
local MAX_NUM_DIGITS = 64
local MAX_EXACT = 9007199254740992 -- 2^53; larger integers are not exact Luau numbers

local DATE_MSG = "dates are not supported; quote the value"

type Meta = {
	kind: string,
	explicit: boolean,
	pending: boolean,
	inline: boolean,
	static: boolean,
}

type Parser = {
	src: string,
	n: number,
	i: number,
	line: number,
	col: number,
	err: Err?,
	root: { [any]: any },
	current: { [any]: any },
	positions: Positions,
	meta: { [any]: Meta },
	pending: { any },
}

local function is_ws(b: number): boolean
	return b == 32 or b == 9
end

local function is_digit(b: number): boolean
	return b >= 48 and b <= 57
end

local function is_bare(b: number): boolean
	return (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or is_digit(b) or b == 95 or b == 45
end

local function is_hex(b: number): boolean
	return is_digit(b) or (b >= 65 and b <= 70) or (b >= 97 and b <= 102)
end

local function hex_value(b: number): number
	if b >= 48 and b <= 57 then
		return b - 48
	elseif b >= 65 and b <= 70 then
		return b - 55
	elseif b >= 97 and b <= 102 then
		return b - 87
	end
	return -1
end

local function peek(p: Parser): number
	local b = string.byte(p.src, p.i)
	if b == nil then
		return -1
	end
	return b
end

local function bump(p: Parser)
	local b = string.byte(p.src, p.i)
	if b == nil then
		return
	end
	if b == 13 and string.byte(p.src, p.i + 1) == 10 then
		p.i += 2
		p.line += 1
		p.col = 1
		return
	end
	if b == 10 then
		p.i += 1
		p.line += 1
		p.col = 1
		return
	end
	p.i += 1
	p.col += 1
end

local function fail(p: Parser, line: number, col: number, message: string)
	if p.err == nil then
		p.err = { line = line, col = col, message = message }
	end
end

local function skip_ws(p: Parser)
	while is_ws(peek(p)) do
		bump(p)
	end
end

local function skip_comment(p: Parser): boolean
	if peek(p) ~= 35 then
		return true
	end
	bump(p)
	while true do
		local b = peek(p)
		if b < 0 or b == 10 then
			return true
		end
		if b == 13 then
			if string.byte(p.src, p.i + 1) == 10 then
				return true
			end
			fail(p, p.line, p.col, "control character in comment")
			return false
		end
		if (b < 32 and b ~= 9) or b == 127 then
			fail(p, p.line, p.col, "control character in comment")
			return false
		end
		bump(p)
	end
end

-- Whitespace, newlines, and comments. Used between array values.
local function skip_gap(p: Parser): boolean
	while true do
		local b = peek(p)
		if is_ws(b) or b == 10 or b == 13 then
			bump(p)
		elseif b == 35 then
			if not skip_comment(p) then
				return false
			end
		else
			return true
		end
	end
end

local function set_pos(p: Parser, tbl: any, key: any, line: number)
	local row = p.positions[tbl]
	if row == nil then
		local created: { [any]: number } = {}
		p.positions[tbl] = created
		row = created
	end
	if row[key] == nil then
		row[key] = line
	end
end

local function seal(value: any, meta: { [any]: Meta })
	if type(value) ~= "table" then
		return
	end
	local m = meta[value]
	if m == nil or m.inline then
		return
	end
	m.inline = true
	if m.kind == "array" then
		m.static = true
	end
	for _, child in value do
		if type(child) == "table" then
			seal(child, meta)
		end
	end
end

local function read_string(p: Parser, quote: number, multiline: boolean, open_line: number, open_col: number): string?
	local parts: { string } = {}
	local span = p.i
	while true do
		local b = peek(p)
		if b < 0 then
			fail(p, open_line, open_col, "unterminated string")
			return nil
		end
		if b == quote then
			if p.i > span then
				table.insert(parts, string.sub(p.src, span, p.i - 1))
			end
			if not multiline then
				bump(p)
				return table.concat(parts)
			end
			local run = 0
			local j = p.i
			while string.byte(p.src, j) == quote and run < 3 do
				run += 1
				j += 1
			end
			if run == 3 then
				bump(p)
				bump(p)
				bump(p)
				local extra = 0
				if peek(p) == quote then
					bump(p)
					extra = 1
					if peek(p) == quote then
						bump(p)
						extra = 2
					end
				end
				if extra > 0 then
					table.insert(parts, string.sub(if quote == 34 then '""' else "''", 1, extra))
				end
				return table.concat(parts)
			end
			span = p.i
			bump(p)
			continue
		end
		if b == 92 and quote == 34 then
			if p.i > span then
				table.insert(parts, string.sub(p.src, span, p.i - 1))
			end
			local bs_line, bs_col = p.line, p.col
			bump(p)
			local e = peek(p)
			if e < 0 then
				fail(p, open_line, open_col, "unterminated string")
				return nil
			end
			if multiline and (e == 32 or e == 9 or e == 10 or e == 13) then
				while is_ws(peek(p)) do
					bump(p)
				end
				local nl = peek(p)
				if nl ~= 10 and nl ~= 13 then
					fail(p, bs_line, bs_col, "invalid escape")
					return nil
				end
				bump(p)
				while true do
					local c = peek(p)
					if is_ws(c) or c == 10 or c == 13 then
						bump(p)
					else
						break
					end
				end
				span = p.i
				continue
			end
			local simple: string? = nil
			if e == 98 then
				simple = "\b"
			elseif e == 116 then
				simple = "\t"
			elseif e == 110 then
				simple = "\n"
			elseif e == 102 then
				simple = "\f"
			elseif e == 114 then
				simple = "\r"
			elseif e == 34 then
				simple = '"'
			elseif e == 92 then
				simple = "\\"
			end
			if simple ~= nil then
				bump(p)
				table.insert(parts, simple)
				span = p.i
				continue
			end
			local hexn = 0
			if e == 117 then
				hexn = 4
			elseif e == 85 then
				hexn = 8
			end
			if hexn == 0 then
				fail(p, bs_line, bs_col, "invalid escape")
				return nil
			end
			bump(p)
			local cp = 0
			for _ = 1, hexn do
				local h = peek(p)
				local hv = hex_value(h)
				if hv < 0 then
					fail(p, bs_line, bs_col, "invalid escape")
					return nil
				end
				cp = cp * 16 + hv
				bump(p)
			end
			if cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
				fail(p, bs_line, bs_col, "invalid escape")
				return nil
			end
			local ok, ch = pcall(utf8.char, cp)
			if not ok or type(ch) ~= "string" then
				fail(p, bs_line, bs_col, "invalid escape")
				return nil
			end
			table.insert(parts, ch)
			span = p.i
			continue
		end
		if b == 10 or b == 13 then
			if not multiline then
				fail(p, p.line, p.col, "newline in string")
				return nil
			end
			if p.i > span then
				table.insert(parts, string.sub(p.src, span, p.i - 1))
			end
			bump(p)
			table.insert(parts, "\n")
			span = p.i
			continue
		end
		if (b < 32 and b ~= 9) or b == 127 then
			fail(p, p.line, p.col, "control character in string")
			return nil
		end
		bump(p)
	end
end

local function parse_string(p: Parser): string?
	local quote = peek(p)
	local open_line, open_col = p.line, p.col
	local multiline = string.byte(p.src, p.i + 1) == quote and string.byte(p.src, p.i + 2) == quote
	if multiline then
		bump(p)
		bump(p)
		bump(p)
		if peek(p) == 10 or peek(p) == 13 then
			bump(p)
		end
	else
		bump(p)
	end
	return read_string(p, quote, multiline, open_line, open_col)
end

local function match_word(p: Parser, word: string): boolean
	if string.sub(p.src, p.i, p.i + #word - 1) ~= word then
		return false
	end
	local after = string.byte(p.src, p.i + #word)
	if after ~= nil and is_bare(after) then
		return false
	end
	return true
end

local function consume(p: Parser, n: number)
	for _ = 1, n do
		bump(p)
	end
end

local function looks_like_date(p: Parser): boolean
	local i = p.i
	local s = p.src
	local function dig(k: number): boolean
		local b = string.byte(s, i + k)
		return b ~= nil and b >= 48 and b <= 57
	end
	if dig(0) and dig(1) and dig(2) and dig(3) and string.byte(s, i + 4) == 45 then
		return true
	end
	if dig(0) and dig(1) and string.byte(s, i + 2) == 58 then
		return true
	end
	return false
end

local function read_digit_string(p: Parser, allow_leading_zero: boolean, line: number, col: number): string?
	local b = peek(p)
	if not is_digit(b) then
		fail(p, line, col, "invalid number")
		return nil
	end
	if not allow_leading_zero and b == 48 then
		local n = string.byte(p.src, p.i + 1) or -1
		if is_digit(n) or n == 95 then
			fail(p, line, col, "invalid number")
			return nil
		end
		bump(p)
		return "0"
	end
	local parts: { string } = {}
	local count = 0
	local last_us = false
	while true do
		b = peek(p)
		if is_digit(b) then
			count += 1
			if count > MAX_NUM_DIGITS then
				fail(p, line, col, "invalid number")
				return nil
			end
			table.insert(parts, string.char(b))
			last_us = false
			bump(p)
		elseif b == 95 then
			if count == 0 or last_us then
				fail(p, line, col, "invalid number")
				return nil
			end
			last_us = true
			bump(p)
		else
			break
		end
	end
	if count == 0 or last_us then
		fail(p, line, col, "invalid number")
		return nil
	end
	return table.concat(parts)
end

local function decode_int(digits: string, base: number): number?
	local n = 0
	for i = 1, #digits do
		local d = hex_value(string.byte(digits, i))
		if d < 0 or d >= base then
			return nil
		end
		if n > math.floor((MAX_EXACT - d) / base) then
			return nil
		end
		n = n * base + d
	end
	return n
end

local function read_radix(p: Parser, base: number, line: number, col: number): number?
	local parts: { string } = {}
	local count = 0
	local last_us = false
	while true do
		local b = peek(p)
		local d = hex_value(b)
		if d >= 0 and d < base then
			count += 1
			if count > MAX_NUM_DIGITS then
				fail(p, line, col, "invalid number")
				return nil
			end
			table.insert(parts, string.char(b))
			last_us = false
			bump(p)
		elseif b == 95 then
			if count == 0 or last_us then
				fail(p, line, col, "invalid number")
				return nil
			end
			last_us = true
			bump(p)
		else
			break
		end
	end
	if count == 0 or last_us then
		fail(p, line, col, "invalid number")
		return nil
	end
	local after = peek(p)
	if after >= 0 and is_bare(after) then
		fail(p, line, col, "invalid number")
		return nil
	end
	local n = decode_int(table.concat(parts), base)
	if n == nil then
		fail(p, line, col, "invalid number")
		return nil
	end
	return n
end

local function parse_number(p: Parser): number?
	local line, col = p.line, p.col
	if match_word(p, "inf") then
		consume(p, 3)
		return math.huge
	end
	if match_word(p, "nan") then
		consume(p, 3)
		return 0 / 0
	end
	if match_word(p, "+inf") or match_word(p, "-inf") then
		local neg = peek(p) == 45
		consume(p, 4)
		return if neg then -math.huge else math.huge
	end
	if match_word(p, "+nan") or match_word(p, "-nan") then
		consume(p, 4)
		return 0 / 0
	end
	if looks_like_date(p) then
		fail(p, line, col, DATE_MSG)
		return nil
	end

	local sign = 1
	local had_sign = false
	local b = peek(p)
	if b == 43 or b == 45 then
		had_sign = true
		if b == 45 then
			sign = -1
		end
		bump(p)
	end
	b = peek(p)
	if not is_digit(b) then
		fail(p, line, col, "invalid number")
		return nil
	end
	if b == 48 then
		local n = string.byte(p.src, p.i + 1) or -1
		local base = 0
		if n == 120 or n == 88 then
			base = 16
		elseif n == 111 or n == 79 then
			base = 8
		elseif n == 98 or n == 66 then
			base = 2
		end
		if base ~= 0 then
			if had_sign then
				fail(p, line, col, "invalid number")
				return nil
			end
			bump(p)
			bump(p)
			local radix = read_radix(p, base, line, col)
			if radix == nil then
				return nil
			end
			return sign * radix
		end
	end

	local int_digits = read_digit_string(p, false, line, col)
	if int_digits == nil then
		return nil
	end
	local frac: string? = nil
	local exp_sign = 1
	local exp: string? = nil
	local is_float = false
	b = peek(p)
	if b == 46 then
		local n = string.byte(p.src, p.i + 1) or -1
		if not is_digit(n) then
			fail(p, line, col, "invalid number")
			return nil
		end
		is_float = true
		bump(p)
		frac = read_digit_string(p, true, line, col)
		if frac == nil then
			return nil
		end
		b = peek(p)
	end
	if b == 101 or b == 69 then
		is_float = true
		bump(p)
		local sb = peek(p)
		if sb == 43 or sb == 45 then
			if sb == 45 then
				exp_sign = -1
			end
			bump(p)
		end
		exp = read_digit_string(p, true, line, col)
		if exp == nil then
			return nil
		end
	end
	local after = peek(p)
	if after >= 0 and is_bare(after) then
		fail(p, line, col, "invalid number")
		return nil
	end
	if not is_float then
		local n = decode_int(int_digits, 10)
		if n == nil then
			fail(p, line, col, "invalid number")
			return nil
		end
		return sign * n
	end
	local clean: { string } = {}
	if sign < 0 then
		table.insert(clean, "-")
	end
	table.insert(clean, int_digits)
	if frac ~= nil then
		table.insert(clean, ".")
		table.insert(clean, frac)
	end
	if exp ~= nil then
		table.insert(clean, "e")
		if exp_sign < 0 then
			table.insert(clean, "-")
		end
		table.insert(clean, exp)
	end
	local num = tonumber(table.concat(clean))
	if num == nil or num ~= num or num == math.huge or num == -math.huge then
		fail(p, line, col, "invalid number")
		return nil
	end
	return num
end

local function parse_key_part(p: Parser): string?
	local b = peek(p)
	if b == 34 or b == 39 then
		if string.byte(p.src, p.i + 1) == b and string.byte(p.src, p.i + 2) == b then
			fail(p, p.line, p.col, "invalid key")
			return nil
		end
		return parse_string(p)
	end
	if is_bare(b) then
		local start = p.i
		while is_bare(peek(p)) do
			bump(p)
		end
		return string.sub(p.src, start, p.i - 1)
	end
	fail(p, p.line, p.col, "invalid key")
	return nil
end

local function parse_key(p: Parser): { string }?
	local parts: { string } = {}
	while true do
		skip_ws(p)
		local part_line, part_col = p.line, p.col
		local part = parse_key_part(p)
		if part == nil then
			return nil
		end
		table.insert(parts, part)
		if #parts > MAX_DEPTH then
			fail(p, part_line, part_col, "nesting is too deep")
			return nil
		end
		skip_ws(p)
		if peek(p) ~= 46 then
			break
		end
		bump(p)
	end
	return parts
end

local function new_table(p: Parser): { [any]: any }
	local t: { [any]: any } = {}
	p.meta[t] = { kind = "table", explicit = false, pending = false, inline = false, static = false }
	return t
end

local function new_array(p: Parser, static: boolean): { any }
	local t: { any } = {}
	p.meta[t] = { kind = "array", explicit = true, pending = false, inline = false, static = static }
	return t
end

local function mark_pending(p: Parser, tbl: any)
	local m = p.meta[tbl]
	if m ~= nil and not m.pending and not m.explicit then
		m.pending = true
		table.insert(p.pending, tbl)
	end
end

local function finalize_pending(p: Parser)
	for _, tbl in p.pending do
		local m = p.meta[tbl]
		if m ~= nil then
			m.pending = false
			m.explicit = true
		end
	end
	p.pending = {}
end

-- Dotted assignment. Intermediates that were defined by a previous `[table]`
-- cannot be reopened; intermediates created here stay pending until the next header.
local function assign_dotted(p: Parser, base: any, parts: { string }, value: any, key_line: number, key_col: number): boolean
	local current = base
	for i = 1, #parts - 1 do
		local part = parts[i]
		local child = current[part]
		if child == nil then
			local created = new_table(p)
			mark_pending(p, created)
			current[part] = created
			set_pos(p, current, part, key_line)
			current = created
		else
			local m = p.meta[child]
			if m == nil or m.kind ~= "table" then
				fail(p, key_line, key_col, "duplicate key")
				return false
			end
			if m.inline then
				fail(p, key_line, key_col, "cannot extend an inline table")
				return false
			end
			if m.explicit then
				fail(p, key_line, key_col, "redefining a table")
				return false
			end
			mark_pending(p, child)
			current = child
		end
	end
	local parent_meta = p.meta[current]
	if parent_meta ~= nil and parent_meta.inline then
		fail(p, key_line, key_col, "cannot extend an inline table")
		return false
	end
	local last = parts[#parts]
	if current[last] ~= nil then
		fail(p, key_line, key_col, "duplicate key")
		return false
	end
	current[last] = value
	set_pos(p, current, last, key_line)
	return true
end

-- Walk header parents. Array-of-tables parents descend into the last element.
local function walk_header(p: Parser, parts: { string }, line: number, col: number): any
	local current: any = p.root
	for i = 1, #parts - 1 do
		local part = parts[i]
		local child = current[part]
		if child == nil then
			local created = new_table(p)
			current[part] = created
			set_pos(p, current, part, line)
			current = created
		else
			local m = p.meta[child]
			if m ~= nil and m.kind == "array" then
				if m.static or m.inline then
					fail(p, line, col, "cannot extend a static array")
					return nil
				end
				if #child == 0 then
					fail(p, line, col, "redefining a table")
					return nil
				end
				current = child[#child]
			elseif m ~= nil and m.kind == "table" then
				if m.inline then
					fail(p, line, col, "cannot extend an inline table")
					return nil
				end
				current = child
			else
				fail(p, line, col, "duplicate key")
				return nil
			end
		end
	end
	return current
end

local function open_table(p: Parser, parts: { string }, line: number, col: number): any
	local parent = walk_header(p, parts, line, col)
	if parent == nil or p.err ~= nil then
		return nil
	end
	local last = parts[#parts]
	local existing = parent[last]
	if existing == nil then
		local created = new_table(p)
		local m = p.meta[created]
		m.explicit = true
		parent[last] = created
		set_pos(p, parent, last, line)
		return created
	end
	local m = p.meta[existing]
	if m ~= nil and m.kind == "table" and not m.explicit and not m.inline and not m.pending then
		m.explicit = true
		return existing
	end
	if m ~= nil and m.inline then
		fail(p, line, col, "cannot extend an inline table")
		return nil
	end
	fail(p, line, col, "redefining a table")
	return nil
end

local function open_aot(p: Parser, parts: { string }, line: number, col: number): any
	local parent = walk_header(p, parts, line, col)
	if parent == nil or p.err ~= nil then
		return nil
	end
	local last = parts[#parts]
	local existing = parent[last]
	local arr: { any }
	if existing == nil then
		arr = new_array(p, false)
		parent[last] = arr
		set_pos(p, parent, last, line)
	else
		local m = p.meta[existing]
		if m == nil or m.kind ~= "array" then
			fail(p, line, col, "redefining a table")
			return nil
		end
		if m.static or m.inline then
			fail(p, line, col, "cannot extend a static array")
			return nil
		end
		arr = existing
	end
	local elem = new_table(p)
	local em = p.meta[elem]
	em.explicit = true
	table.insert(arr, elem)
	set_pos(p, arr, #arr, line)
	return elem
end

local parse_value: (Parser, number) -> any

local function parse_array(p: Parser, depth: number): any
	local open_line, open_col = p.line, p.col
	if depth + 1 > MAX_DEPTH then
		fail(p, open_line, open_col, "nesting is too deep")
		return nil
	end
	bump(p)
	local arr = new_array(p, true)
	while p.err == nil do
		if not skip_gap(p) then
			return nil
		end
		if peek(p) == 93 then
			bump(p)
			seal(arr, p.meta)
			return arr
		end
		if peek(p) < 0 then
			fail(p, open_line, open_col, "unterminated array")
			return nil
		end
		local value = parse_value(p, depth + 1)
		if p.err ~= nil then
			return nil
		end
		table.insert(arr, value)
		if not skip_gap(p) then
			return nil
		end
		local b = peek(p)
		if b == 44 then
			bump(p)
		elseif b == 93 then
			bump(p)
			seal(arr, p.meta)
			return arr
		else
			fail(p, p.line, p.col, "unterminated array")
			return nil
		end
	end
	return nil
end

local function parse_inline_table(p: Parser, depth: number): any
	local open_line, open_col = p.line, p.col
	if depth + 1 > MAX_DEPTH then
		fail(p, open_line, open_col, "nesting is too deep")
		return nil
	end
	bump(p)
	local tbl = new_table(p)
	skip_ws(p)
	if peek(p) == 125 then
		bump(p)
		seal(tbl, p.meta)
		return tbl
	end
	while p.err == nil do
		local b = peek(p)
		if b == 10 or b == 13 then
			fail(p, p.line, p.col, "newline in inline table")
			return nil
		end
		if b < 0 then
			fail(p, open_line, open_col, "unterminated inline table")
			return nil
		end
		local key_line, key_col = p.line, p.col
		local parts = parse_key(p)
		if parts == nil then
			return nil
		end
		skip_ws(p)
		if peek(p) ~= 61 then
			fail(p, p.line, p.col, "missing '='")
			return nil
		end
		bump(p)
		skip_ws(p)
		if peek(p) == 10 or peek(p) == 13 or peek(p) < 0 then
			fail(p, p.line, p.col, "expected value")
			return nil
		end
		local value = parse_value(p, depth + 1)
		if p.err ~= nil then
			return nil
		end
		if not assign_dotted(p, tbl, parts, value, key_line, key_col) then
			return nil
		end
		skip_ws(p)
		b = peek(p)
		if b == 125 then
			bump(p)
			seal(tbl, p.meta)
			return tbl
		end
		if b ~= 44 then
			fail(p, if b < 0 then open_line else p.line, if b < 0 then open_col else p.col, "unterminated inline table")
			return nil
		end
		bump(p)
		skip_ws(p)
		if peek(p) == 125 then
			fail(p, p.line, p.col, "trailing comma in inline table")
			return nil
		end
	end
	return nil
end

parse_value = function(p: Parser, depth: number): any
	local b = peek(p)
	if b == 34 or b == 39 then
		return parse_string(p)
	end
	if b == 116 or b == 102 then
		if match_word(p, "true") then
			consume(p, 4)
			return true
		end
		if match_word(p, "false") then
			consume(p, 5)
			return false
		end
		fail(p, p.line, p.col, "expected value")
		return nil
	end
	if b == 91 then
		return parse_array(p, depth)
	end
	if b == 123 then
		return parse_inline_table(p, depth)
	end
	if b == 43 or b == 45 or b == 105 or b == 110 or is_digit(b) then
		return parse_number(p)
	end
	fail(p, p.line, p.col, "expected value")
	return nil
end

local function finish_statement(p: Parser): boolean
	skip_ws(p)
	if peek(p) == 35 then
		if not skip_comment(p) then
			return false
		end
		skip_ws(p)
	end
	local b = peek(p)
	if b < 0 then
		return true
	end
	if b == 10 or b == 13 then
		bump(p)
		return true
	end
	fail(p, p.line, p.col, "trailing garbage")
	return false
end

local function parse_header(p: Parser): any
	local line, col = p.line, p.col
	local array = string.byte(p.src, p.i + 1) == 91
	bump(p)
	if array then
		bump(p)
	end
	skip_ws(p)
	local parts = parse_key(p)
	if parts == nil then
		return nil
	end
	skip_ws(p)
	if peek(p) ~= 93 then
		fail(p, p.line, p.col, if array then "expected ']]'" else "expected ']'")
		return nil
	end
	bump(p)
	if array then
		if peek(p) ~= 93 then
			fail(p, p.line, p.col, "expected ']]'")
			return nil
		end
		bump(p)
	end
	if array then
		return open_aot(p, parts, line, col)
	end
	return open_table(p, parts, line, col)
end

function M.parse(text: string): (any?, Positions | Err)
	if type(text) ~= "string" then
		return nil, { line = 1, col = 1, message = "expected a string" }
	end
	if #text > MAX_BYTES then
		return nil, { line = 1, col = 1, message = "input exceeds 1 MiB" }
	end
	local root: { [any]: any } = {}
	local p: Parser = {
		src = text,
		n = #text,
		i = 1,
		line = 1,
		col = 1,
		err = nil,
		root = root,
		current = root,
		positions = {},
		meta = {},
		pending = {},
	}
	p.meta[root] = { kind = "table", explicit = false, pending = false, inline = false, static = false }

	local steps = 0
	while p.i <= p.n and p.err == nil do
		steps += 1
		if steps > p.n + 8 then
			fail(p, p.line, p.col, "nesting is too deep")
			break
		end
		local before = p.i
		skip_ws(p)
		local b = peek(p)
		if b < 0 then
			break
		end
		if b == 10 or b == 13 then
			bump(p)
			continue
		end
		if b == 35 then
			if skip_comment(p) then
				finish_statement(p)
			end
			continue
		end
		if b == 91 then
			finalize_pending(p)
			local nxt = parse_header(p)
			if p.err ~= nil then
				break
			end
			p.current = nxt
			finish_statement(p)
		else
			local key_line, key_col = p.line, p.col
			local parts = parse_key(p)
			if parts == nil then
				break
			end
			skip_ws(p)
			if peek(p) ~= 61 then
				fail(p, p.line, p.col, "missing '='")
				break
			end
			bump(p)
			skip_ws(p)
			if peek(p) < 0 or peek(p) == 10 or peek(p) == 13 or peek(p) == 35 then
				fail(p, p.line, p.col, "expected value")
				break
			end
			local value = parse_value(p, 0)
			if p.err == nil then
				assign_dotted(p, p.current, parts, value, key_line, key_col)
			end
			if p.err == nil then
				finish_statement(p)
			end
		end
		if p.err == nil and p.i == before then
			fail(p, p.line, p.col, "trailing garbage")
			break
		end
	end
	if p.err ~= nil then
		return nil, p.err
	end
	return root, p.positions
end

-- TOML basic string literal. Controls use short escapes or `\u00XX`; other text is raw UTF-8.
function M.quote(s: string): string
	local parts: { string } = { '"' }
	local i = 1
	local n = #s
	while i <= n do
		local b = string.byte(s, i)
		if b == 34 or b == 92 then
			table.insert(parts, "\\")
			table.insert(parts, string.char(b))
			i += 1
		elseif b == 8 then
			table.insert(parts, "\\b")
			i += 1
		elseif b == 9 then
			table.insert(parts, "\\t")
			i += 1
		elseif b == 10 then
			table.insert(parts, "\\n")
			i += 1
		elseif b == 12 then
			table.insert(parts, "\\f")
			i += 1
		elseif b == 13 then
			table.insert(parts, "\\r")
			i += 1
		elseif b < 32 or b == 127 then
			table.insert(parts, string.format("\\u%04X", b))
			i += 1
		else
			local j = i + 1
			while j <= n do
				local c = string.byte(s, j)
				if c < 32 or c == 127 or c == 34 or c == 92 then
					break
				end
				j += 1
			end
			table.insert(parts, string.sub(s, i, j - 1))
			i = j
		end
	end
	table.insert(parts, '"')
	return table.concat(parts)
end

local function bare_key(s: string): boolean
	if s == "" then
		return false
	end
	for i = 1, #s do
		if not is_bare(string.byte(s, i)) then
			return false
		end
	end
	return true
end

local function encode_key(s: string): string
	if bare_key(s) then
		return s
	end
	return M.quote(s)
end

local function encode_number(n: number): string
	if n ~= n then
		return "nan"
	end
	if n == math.huge then
		return "inf"
	end
	if n == -math.huge then
		return "-inf"
	end
	if n == 0 then
		return "0"
	end
	if n == math.floor(n) and math.abs(n) <= MAX_EXACT then
		return string.format("%.0f", n)
	end
	for prec = 1, 17 do
		local s = string.format("%." .. prec .. "g", n)
		if tonumber(s) == n then
			return s
		end
	end
	return string.format("%.17g", n)
end

local function is_array(t: any): boolean
	if type(t) ~= "table" then
		return false
	end
	local n = #t
	if n == 0 then
		return false
	end
	local count = 0
	for k, v in t do
		if v == nil or type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then
			return false
		end
		count += 1
	end
	return count == n
end

local function is_aot(t: any): boolean
	if not is_array(t) then
		return false
	end
	for i = 1, #t do
		local v = t[i]
		if type(v) ~= "table" or is_array(v) then
			return false
		end
	end
	return true
end

local function needs_header(t: any): boolean
	local seen: { [any]: boolean } = {}
	local function walk(node: any): boolean
		if type(node) ~= "table" or seen[node] then
			return false
		end
		seen[node] = true
		if is_aot(node) then
			return true
		end
		for _, v in node do
			if walk(v) then
				return true
			end
		end
		return false
	end
	seen[t] = true
	for _, v in t do
		if walk(v) then
			return true
		end
	end
	return false
end

local function sorted_keys(t: any): { string }
	local keys: { string } = {}
	for k, _ in t do
		if type(k) == "string" then
			table.insert(keys, k)
		end
	end
	table.sort(keys)
	return keys
end

local function encode_inline(v: any, seen: { [any]: boolean }): string
	local t = type(v)
	if t == "string" then
		return M.quote(v :: string)
	elseif t == "number" then
		return encode_number(v :: number)
	elseif t == "boolean" then
		return if v then "true" else "false"
	elseif t ~= "table" then
		return '""'
	end
	if seen[v] then
		return '""'
	end
	seen[v] = true
	local text: string
	if is_array(v) then
		local parts: { string } = {}
		for i = 1, #v do
			parts[i] = encode_inline(v[i], seen)
		end
		text = "[" .. table.concat(parts, ", ") .. "]"
	else
		local keys = sorted_keys(v)
		if #keys == 0 then
			text = "{}"
		else
			local parts: { string } = {}
			for _, k in keys do
				table.insert(parts, encode_key(k) .. " = " .. encode_inline(v[k], seen))
			end
			text = "{ " .. table.concat(parts, ", ") .. " }"
		end
	end
	seen[v] = nil
	return text
end

local function classify(v: any): string
	local t = type(v)
	if t == "string" or t == "number" or t == "boolean" then
		return "assign"
	end
	if t ~= "table" then
		return "skip"
	end
	if is_aot(v) then
		return "aot"
	end
	if is_array(v) or next(v) == nil then
		return "assign"
	end
	if needs_header(v) then
		return "table"
	end
	return "assign"
end

local function path_with(path: { string }, key: string): { string }
	local nextp: { string } = {}
	for i, part in path do
		nextp[i] = part
	end
	nextp[#path + 1] = key
	return nextp
end

local function encode_path(path: { string }): string
	local parts: { string } = {}
	for _, part in path do
		table.insert(parts, encode_key(part))
	end
	return table.concat(parts, ".")
end

local function encode_table(path: { string }, tbl: any, out: { string }, seen: { [any]: boolean })
	if type(tbl) ~= "table" or seen[tbl] or #path > MAX_DEPTH then
		return
	end
	seen[tbl] = true
	local assigns: { string } = {}
	local tables: { string } = {}
	local aots: { string } = {}
	for _, k in sorted_keys(tbl) do
		local kind = classify(tbl[k])
		if kind == "assign" then
			table.insert(assigns, k)
		elseif kind == "table" then
			table.insert(tables, k)
		elseif kind == "aot" then
			table.insert(aots, k)
		end
	end
	for _, k in assigns do
		table.insert(out, encode_key(k) .. " = " .. encode_inline(tbl[k], seen) .. "\n")
	end
	for _, k in tables do
		local sub = path_with(path, k)
		if #out > 0 then
			table.insert(out, "\n")
		end
		table.insert(out, "[" .. encode_path(sub) .. "]\n")
		encode_table(sub, tbl[k], out, seen)
	end
	for _, k in aots do
		local sub = path_with(path, k)
		local arr = tbl[k]
		for i = 1, #arr do
			if #out > 0 then
				table.insert(out, "\n")
			end
			table.insert(out, "[[" .. encode_path(sub) .. "]]\n")
			encode_table(sub, arr[i], out, seen)
		end
	end
	seen[tbl] = nil
end

-- Scalars, arrays of scalars, and inline-able tables first (keys sorted), then
-- `[tables]`, then `[[arrays of tables]]`. A table is inline-able when it does
-- not contain an array of tables anywhere under it. Keys that are not bare are quoted.
function M.encode(root: { [string]: any }): string
	if type(root) ~= "table" then
		return ""
	end
	local out: { string } = {}
	encode_table({}, root, out, {})
	return table.concat(out)
end

return M
