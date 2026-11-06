--!strict
-- One-line field editing: codepoint caret, UTF-16 offsets for the input node, edits and paste.

local field = require("../lib/field")

local function eq(a: any, b: any, msg: string?)
	if a ~= b then
		error(`{msg or "eq"}: expected {tostring(b)}, got {tostring(a)}`, 2)
	end
end

local function key(name: string, text: string?, mods: { [string]: boolean }?): Key
	local m: { [string]: boolean } = mods or {}
	return { name = name, text = text, ctrl = m.ctrl == true, alt = m.alt == true, shift = m.shift == true, meta = m.meta == true }
end

do -- typing, moving and deleting across multibyte characters
	local f: field.Field = { text = "", cursor = 0 }
	for _, ch in { "a", "你", "b" } do
		eq(field.key(f, key(ch, ch)), true)
	end
	eq(f.text, "a你b")
	eq(f.cursor, 3)
	eq(field.key(f, key("left")), true)
	eq(field.key(f, key("backspace")), true)
	eq(f.text, "ab", "backspace removes the whole CJK character")
	eq(f.cursor, 1)
	eq(field.key(f, key("delete")), true)
	eq(f.text, "a")
	eq(field.key(f, key("delete")), false, "nothing after the caret")
	eq(field.key(f, key("home")), true)
	eq(field.key(f, key("left")), false, "already at the start")
	eq(field.key(f, key("x", "x", { ctrl = true })), false, "chords type nothing")
end

do -- UTF-16 offsets: BMP characters count 1, emoji count 2
	local f: field.Field = { text = "a你😀b", cursor = 4 }
	eq(field.utf16_cursor(f), 5)
	f.cursor = 3
	eq(field.utf16_cursor(f), 4)
	f.cursor = 2
	eq(field.utf16_cursor(f), 2)
end

do -- paste drops newlines; meta+backspace clears to the start
	local f: field.Field = { text = "tail", cursor = 0 }
	eq(field.key(f, key("paste", "line1\nline2")), true)
	eq(f.text, "line1line2tail")
	eq(f.cursor, 10)
	eq(field.key(f, key("backspace", nil, { meta = true })), true)
	eq(f.text, "tail")
	eq(f.cursor, 0)
	eq(field.key(f, key("e", nil, { ctrl = true })), true, "ctrl+e to end")
	eq(f.cursor, 4)
end

do -- multi-line prompts: Enter breaks the line, Up/Down keep a sticky column, Home/End per line
	local f: field.Field = { text = "你好吗\n\nab", cursor = 2, lines = true }
	eq(field.key(f, key("down")), true)
	eq(f.cursor, 4, "empty middle line: column clamps to 0")
	eq(field.key(f, key("down")), true)
	eq(f.cursor, 7, "sticky column 2 restored on the last line")
	eq(field.key(f, key("down")), false, "no line below")
	eq(field.key(f, key("up")), true)
	eq(field.key(f, key("up")), true)
	eq(f.cursor, 2, "back to column 2 of the first line")
	eq(field.key(f, key("end")), true)
	eq(f.cursor, 3)
	eq(field.key(f, key("enter")), true)
	eq(f.text, "你好吗\n\n\nab")
	eq(field.key(f, key("paste", "x\r\ny")), true)
	eq(f.text, "你好吗\nx\ny\n\nab", "pasted CRLF becomes newlines")
end

print("ok")
