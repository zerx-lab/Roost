--!strict
-- Parser, encoder, and position tests for the TOML 1.0 subset.

local M = require("../lib/toml")

local function eq(a: any, b: any, what: string)
	if a ~= b then
		error(string.format("%s: expected %s, got %s", what, tostring(b), tostring(a)), 2)
	end
end

local function deep_eq(a: any, b: any, path: string)
	if a ~= a and b ~= b then
		return
	end
	if type(a) ~= type(b) then
		error(path .. ": type " .. type(a) .. " vs " .. type(b), 2)
	end
	if type(a) ~= "table" then
		if a ~= b then
			error(path .. ": " .. tostring(a) .. " vs " .. tostring(b), 2)
		end
		return
	end
	for k, v in a do
		deep_eq(v, b[k], path .. "." .. tostring(k))
	end
	for k, v in b do
		if a[k] == nil then
			error(path .. ": missing " .. tostring(k), 2)
		end
		if v == nil then
			error(path .. ": extra nil " .. tostring(k), 2)
		end
	end
end

local function loc_at(src: string, index: number): (number, number)
	local line, col = 1, 1
	local i = 1
	while i < index do
		local b = string.byte(src, i)
		if b == 13 and string.byte(src, i + 1) == 10 then
			i += 2
			line += 1
			col = 1
		elseif b == 10 then
			i += 1
			line += 1
			col = 1
		else
			i += 1
			col += 1
		end
	end
	return line, col
end

local function doc(lines: { string }): string
	return table.concat(lines, "\n") .. "\n"
end

local function parse_ok(src: string, what: string): (any, any)
	local value, second = M.parse(src)
	if value == nil then
		local e = second :: any
		error(string.format("%s: %s:%s: %s", what, tostring(e.line), tostring(e.col), tostring(e.message)), 2)
	end
	return value, second
end

local function find_at(src: string, needle: string, n: number?): number
	local from = 1
	local hit = 0
	local want = if n == nil then 1 else n
	while from <= #src + 1 do
		local i = string.find(src, needle, from, true)
		if i == nil then
			error("needle not found: " .. needle, 2)
		end
		hit += 1
		if hit == want then
			return i
		end
		from = i + 1
	end
	error("needle not found: " .. needle, 2)
end

local function expect_at(src: string, index: number, fragment: string, what: string)
	local line, col = loc_at(src, index)
	local value, err = M.parse(src)
	if value ~= nil then
		error(what .. ": expected error, got a value", 2)
	end
	local e = err :: any
	eq(e.line, line, what .. " line")
	eq(e.col, col, what .. " col")
	if string.find(tostring(e.message), fragment, 1, true) == nil then
		error(what .. ": message '" .. tostring(e.message) .. "' missing '" .. fragment .. "'", 2)
	end
end

local function before(s: string, a: string, b: string, what: string)
	local ia = string.find(s, a, 1, true)
	local ib = string.find(s, b, 1, true)
	if ia == nil or ib == nil or ia >= ib then
		error(what .. ": expected '" .. a .. "' before '" .. b .. "' in:\n" .. s, 2)
	end
end

-- -- values -------------------------------------------------------------------

local src = doc({
	"# full-line comment",
	"title = \"röost\"",
	"bare_key = \"value\"",
	"bare-key = \"dash\"",
	"1234 = \"digits\"",
	"\"127.0.0.1\" = \"v4\"",
	"\"character encoding\" = \"ok\"",
	"'key2' = \"lit-key\"",
	"'' = \"blank\"",
	"site.\"google.com\" = true",
	"esc = \"\\b\\t\\n\\f\\r\\\"\\\\\"",
	"uni = \"\\u00E9\\U0001F600\"",
	"lit = 'C:\\Users\\nodejs'",
	"quoted = 'Tom \"Dubs\" Preston-Werner'",
	"int1 = +99",
	"int2 = 42",
	"int3 = 0",
	"int4 = -17",
	"int5 = 1_000",
	"hex1 = 0xDEAD",
	"hex2 = 0xdead_beef",
	"oct1 = 0o755",
	"bin1 = 0b11010110",
	"big = 9007199254740992",
	"flt1 = +1.0",
	"flt2 = 3.1415",
	"flt3 = -0.01",
	"flt4 = 5e+22",
	"flt5 = 1e06",
	"flt6 = -2E-2",
	"flt7 = 6.626e-34",
	"flt8 = 224_617.445_991",
	"pos_inf = inf",
	"neg_inf = -inf",
	"pos_nan = nan",
	"signed_nan = +nan",
	"bool1 = true",
	"bool2 = false",
	"arr = [ 1, 2, 3 ]",
	"mixed = [ 0.1, \"a\", true, { z = 1 } ]",
	"nested = [ [ 1, 2 ], [ 3, 4, 5 ] ]",
	"empty_arr = []",
	"empty_tbl = {}",
	"inline = { x = 1, y = 2, z.w = 3 }",
	"fruit.apple.color = \"red\"",
	"fruit.orange = 2",
	"3.14159 = \"pi\"",
	"a = 1 # trailing comment",
})

local root, positions = parse_ok(src, "values")
eq(root.title, "röost", "unicode string")
eq(root.bare_key, "value", "bare key")
eq(root["bare-key"], "dash", "dash key")
eq(root["1234"], "digits", "digit key")
eq(root["127.0.0.1"], "v4", "quoted key")
eq(root["character encoding"], "ok", "spaced key")
eq(root.key2, "lit-key", "literal key")
eq(root[""], "blank", "empty key")
eq(root.site["google.com"], true, "dotted quoted key")
eq(root.esc, "\b\t\n\f\r\"\\", "escapes")
eq(root.uni, utf8.char(0xE9) .. utf8.char(0x1F600), "unicode escapes")
eq(root.lit, "C:\\Users\\nodejs", "literal string")
eq(root.quoted, "Tom \"Dubs\" Preston-Werner", "literal quotes")
eq(root.int1, 99, "+99")
eq(root.int2, 42, "42")
eq(root.int3, 0, "0")
eq(root.int4, -17, "-17")
eq(root.int5, 1000, "underscores")
eq(root.hex1, 0xDEAD, "hex")
eq(root.hex2, 0xDEADBEEF, "hex underscores")
eq(root.oct1, 493, "octal")
eq(root.bin1, 214, "binary")
eq(root.big, 9007199254740992, "2^53")
eq(root.flt1, 1, "+1.0")
eq(root.flt2, tonumber("3.1415"), "fraction")
eq(root.flt3, tonumber("-0.01"), "signed fraction")
eq(root.flt4, tonumber("5e+22"), "exponent")
eq(root.flt5, 1000000, "1e06")
eq(root.flt6, tonumber("-2E-2"), "signed exponent")
eq(root.flt7, tonumber("6.626e-34"), "sci")
eq(root.flt8, tonumber("224617.445991"), "float underscores")
eq(root.pos_inf, math.huge, "inf")
eq(root.neg_inf, -math.huge, "-inf")
assert(root.pos_nan ~= root.pos_nan, "nan")
assert(root.signed_nan ~= root.signed_nan, "+nan")
eq(root.bool1, true, "true")
eq(root.bool2, false, "false")
eq(root.arr[1], 1, "array 1")
eq(root.arr[3], 3, "array 3")
eq(root.mixed[1], 0.1, "mixed number")
eq(root.mixed[2], "a", "mixed string")
eq(root.mixed[3], true, "mixed bool")
eq(root.mixed[4].z, 1, "mixed inline")
eq(root.nested[1][2], 2, "nested array")
eq(root.nested[2][3], 5, "nested array 2")
eq(#root.empty_arr, 0, "empty array")
eq(next(root.empty_tbl), nil, "empty inline")
eq(root.inline.x, 1, "inline x")
eq(root.inline.y, 2, "inline y")
eq(root.inline.z.w, 3, "inline dotted")
eq(root.fruit.apple.color, "red", "dotted table")
eq(root.fruit.orange, 2, "dotted sibling")
eq(root["3"]["14159"], "pi", "dotted numeric key")
eq(root.a, 1, "trailing comment")
eq((positions :: any)[root].title, 2, "title line")
eq((positions :: any)[root].a, 48, "commented key line")

local ml = parse_ok(doc({
	"s = \"\"\"",
	"Roses are red",
	"Violets are blue\"\"\"",
}), "multiline basic")
eq(ml.s, "Roses are red\nViolets are blue", "trimmed first newline")

local cont = parse_ok(doc({
	"s = \"\"\"",
	"The quick brown \\",
	"",
	"  fox jumps over \\",
	"    the lazy dog.\"\"\"",
}), "line-ending backslash")
eq(cont.s, "The quick brown fox jumps over the lazy dog.", "backslash trim")

local opened = parse_ok(doc({
	"s = \"\"\"\\",
	"       The quick brown \\",
	"       fox.\"\"\"",
}), "opening backslash")
eq(opened.s, "The quick brown fox.", "opening trim")

local twoq = parse_ok('s = """Here are two quotation marks: "". Simple enough."""\n', "two quotes")
eq(twoq.s, "Here are two quotation marks: \"\". Simple enough.", "embedded quotes")

local litml = parse_ok(doc({
	"s = '''",
	"The first newline is",
	"trimmed in raw strings.",
	"   All other whitespace",
	"   is preserved.",
	"'''",
}), "multiline literal")
eq(litml.s, "The first newline is\ntrimmed in raw strings.\n   All other whitespace\n   is preserved.\n", "literal ml")

local apos = parse_ok("s = ''''That,' she said, 'is still pointless.''''\n", "literal quotes")
eq(apos.s, "'That,' she said, 'is still pointless.'", "apostrophe run")

local crlf, crlf_pos = parse_ok("a = 1\r\nb = 2\r\n# comment\r\nc = \"x\"\r\n", "crlf")
eq(crlf.a, 1, "crlf a")
eq(crlf.b, 2, "crlf b")
eq(crlf.c, "x", "crlf c")
eq((crlf_pos :: any)[crlf].b, 2, "crlf line")

local mlcrlf = parse_ok("s = \"\"\"\r\nhello\r\nthere\"\"\"\r\n", "multiline crlf")
eq(mlcrlf.s, "hello\nthere", "crlf normalized")

local trail = parse_ok(doc({
	"nums = [",
	"  1,",
	"  2, # inside",
	"]",
}), "array comments")
eq(trail.nums[1], 1, "trailing comma 1")
eq(trail.nums[2], 2, "trailing comma 2")

local headers = parse_ok(doc({
	"[server]",
	"host = \"localhost\"",
	"port = 8080",
	"",
	"[server.tls]",
	"enabled = false",
	"",
	"[dog.\"tater.man\"]",
	"type.name = \"pug\"",
	"",
	"[[products]]",
	"name = \"Hammer\"",
	"",
	"[[products]]",
	"name = \"Nail\"",
	"",
	"[[products.variety]]",
	"name = \"common\"",
	"",
	"[fruit.physical]",
	"color = \"red\"",
	"",
	"[fruit]",
	"name = \"apple\"",
}), "headers")
eq(headers.server.host, "localhost", "server host")
eq(headers.server.port, 8080, "server port")
eq(headers.server.tls.enabled, false, "nested header")
eq(headers.dog["tater.man"].type.name, "pug", "quoted header")
eq(headers.products[1].name, "Hammer", "aot 1")
eq(headers.products[2].name, "Nail", "aot 2")
eq(headers.products[2].variety[1].name, "common", "nested aot")
eq(headers.fruit.name, "apple", "super-table")
eq(headers.fruit.physical.color, "red", "subtable before parent")

local dotted = parse_ok(doc({
	"apple.color = \"red\"",
	"apple.skin = \"thin\"",
	"orange.type = \"fruit\"",
}), "same-section dotted")
eq(dotted.apple.color, "red", "apple color")
eq(dotted.apple.skin, "thin", "apple skin")
eq(dotted.orange.type, "fruit", "orange")

local deep_ok = "a = " .. string.rep("[", 32) .. string.rep("]", 32)
local deep = parse_ok(deep_ok, "depth 32")
local cursor = deep.a
for _ = 1, 31 do
	cursor = cursor[1]
end
eq(#cursor, 0, "innermost array")

local key_parts: { string } = {}
for i = 1, 32 do
	key_parts[i] = "k"
end
local deep_key = parse_ok(table.concat(key_parts, ".") .. " = 1\n", "key depth 32")
local node = deep_key
for _ = 1, 31 do
	node = node.k
end
eq(node.k, 1, "deep dotted value")

local empty = parse_ok("", "empty")
eq(next(empty), nil, "empty root")
local comments = parse_ok("# only\n\n  \n", "comment only")
eq(next(comments), nil, "comment root")

-- -- errors -------------------------------------------------------------------

local dup = doc({ "a = 1", "a = 2" })
expect_at(dup, find_at(dup, "a = 2"), "duplicate key", "duplicate key")

local quoted_dup = doc({ 'spelling = "favorite"', '"spelling" = "favourite"' })
expect_at(quoted_dup, find_at(quoted_dup, '"spelling"'), "duplicate key", "quoted duplicate")

local redef = doc({ "[fruit]", 'apple = "red"', "", "[fruit]" })
expect_at(redef, find_at(redef, "[fruit]", 2), "redefining a table", "redefine header")

local redef_sub = doc({ "[fruit]", 'apple = "red"', "", "[fruit.apple]" })
expect_at(redef_sub, find_at(redef_sub, "[fruit.apple]"), "redefining a table", "redefine value")

local dotted_header = doc({ "fruit.apple = 1", "", "[fruit]" })
expect_at(dotted_header, find_at(dotted_header, "[fruit]"), "redefining a table", "dotted then header")

local int_table = doc({ "fruit.apple = 1", "fruit.apple.smooth = true" })
expect_at(int_table, find_at(int_table, "fruit.apple.smooth"), "duplicate key", "integer as table")

local ext_inline = doc({ "x = { a = 1 }", "x.b = 2" })
expect_at(ext_inline, find_at(ext_inline, "x.b"), "cannot extend an inline table", "extend inline")

local ext_inline_h = doc({ "x = { a = 1 }", "", "[x.b]" })
expect_at(ext_inline_h, find_at(ext_inline_h, "[x.b]"), "cannot extend an inline table", "header on inline")

local ext_arr = doc({ "a = [1, 2]", "", "[[a]]" })
expect_at(ext_arr, find_at(ext_arr, "[[a]]"), "cannot extend a static array", "static array")

local unterminated = 's = "abc'
expect_at(unterminated, find_at(unterminated, '"'), "unterminated string", "unterminated")

local bad_esc = 's = "\\q"'
expect_at(bad_esc, find_at(bad_esc, "\\"), "invalid escape", "bad escape")

local surr = 's = "\\uD800"'
expect_at(surr, find_at(surr, "\\"), "invalid escape", "surrogate")

local overflow = "n = 9007199254740993\n"
expect_at(overflow, find_at(overflow, "9007199254740993"), "invalid number", "overflow")

local lead0 = "n = 01\n"
expect_at(lead0, find_at(lead0, "01"), "invalid number", "leading zero")

local trail_us = "n = 1_\n"
expect_at(trail_us, find_at(trail_us, "1_"), "invalid number", "trailing underscore")

local bad_hex = "n = 0x\n"
expect_at(bad_hex, find_at(bad_hex, "0x"), "invalid number", "empty hex")

local dot_float = "a = 7.\n"
expect_at(dot_float, find_at(dot_float, "7."), "invalid number", "trailing dot")

local lead_dot = "a = .7\n"
expect_at(lead_dot, find_at(lead_dot, "."), "expected value", "leading dot")

local missing = "key 1\n"
expect_at(missing, find_at(missing, "1"), "missing '='", "missing equals")

local garbage = "a = 1 2\n"
expect_at(garbage, find_at(garbage, "2"), "trailing garbage", "trailing garbage")

local header_junk = "[a] junk\n"
expect_at(header_junk, find_at(header_junk, "junk"), "trailing garbage", "header junk")

local control = "s = \"a\001b\""
expect_at(control, find_at(control, "\001"), "control character in string", "control")

local nl_str = "s = \"a\nb\""
expect_at(nl_str, find_at(nl_str, "\n"), "newline in string", "newline in string")

local date = "d = 1979-05-27\n"
expect_at(date, find_at(date, "1979-05-27"), "dates are not supported; quote the value", "date")

local datetime = "d = 1979-05-27T07:32:00Z\n"
expect_at(datetime, find_at(datetime, "1979-05-27T07:32:00Z"), "dates are not supported; quote the value", "datetime")

local spaced = "d = 1979-05-27 07:32:00Z\n"
expect_at(spaced, find_at(spaced, "1979-05-27"), "dates are not supported; quote the value", "offset datetime")

local time = "d = 07:32:00\n"
expect_at(time, find_at(time, "07:32:00"), "dates are not supported; quote the value", "time")

local too_deep = "a = " .. string.rep("[", 33) .. string.rep("]", 33)
expect_at(too_deep, #"a = " + 33, "nesting is too deep", "array depth")

local inline_prefix = "a = " .. string.rep("{k=", 32)
local inline_deep = inline_prefix .. "{}" .. string.rep("}", 32)
expect_at(inline_deep, #inline_prefix + 1, "nesting is too deep", "inline depth")

local many: { string } = {}
for i = 1, 33 do
	many[i] = "k"
end
local key_deep = table.concat(many, ".") .. " = 1\n"
expect_at(key_deep, 65, "nesting is too deep", "key depth")

local huge = string.rep(" ", 1024 * 1024 + 1)
expect_at(huge, 1, "1 MiB", "size")
local exact = parse_ok(string.rep(" ", 1024 * 1024), "exact mebibyte")
eq(next(exact), nil, "exact mebibyte empty")

local inline_nl = "a = {\nb = 1\n}\n"
expect_at(inline_nl, find_at(inline_nl, "\n"), "newline in inline table", "inline newline")

local inline_comma = "a = { b = 1, }\n"
expect_at(inline_comma, find_at(inline_comma, "}"), "trailing comma", "inline comma")

local truefoo = "a = truefoo\n"
expect_at(truefoo, find_at(truefoo, "truefoo"), "expected value", "keyword boundary")

-- -- positions ----------------------------------------------------------------

local flow = doc({
	'title = "demo"',
	"",
	"[[workflow]]",
	'name = "build"',
	"opts.retries = 3",
	"",
	"[[workflow.steps]]",
	'run = "echo hi"',
	"",
	"[[workflow]]",
	'name = "test"',
	"",
	"[[workflow.steps]]",
	'run = "echo 子"',
})
local flow_root, flow_pos = parse_ok(flow, "workflow")
local pos = flow_pos :: any
eq(flow_root.title, "demo", "flow title")
eq(#flow_root.workflow, 2, "two workflows")
eq(flow_root.workflow[1].name, "build", "wf1 name")
eq(flow_root.workflow[1].opts.retries, 3, "wf1 opts")
eq(flow_root.workflow[1].steps[1].run, "echo hi", "wf1 step")
eq(flow_root.workflow[2].name, "test", "wf2 name")
eq(flow_root.workflow[2].steps[1].run, "echo 子", "wf2 step")
eq(pos[flow_root].title, 1, "title pos")
eq(pos[flow_root].workflow, 3, "array key pos")
eq(pos[flow_root.workflow][1], 3, "first header")
eq(pos[flow_root.workflow][2], 10, "second header")
eq(pos[flow_root.workflow[1]].name, 4, "name inside first")
eq(pos[flow_root.workflow[1]].opts, 5, "dotted inside first")
eq(pos[flow_root.workflow[1].opts].retries, 5, "dotted leaf")
eq(pos[flow_root.workflow[1]].steps, 7, "nested aot key")
eq(pos[flow_root.workflow[1].steps][1], 7, "nested header")
eq(pos[flow_root.workflow[1].steps[1]].run, 8, "key inside nested")
eq(pos[flow_root.workflow[2]].name, 11, "name inside second")
eq(pos[flow_root.workflow[2]].steps, 13, "second nested key")
eq(pos[flow_root.workflow[2].steps][1], 13, "second nested header")
eq(pos[flow_root.workflow[2].steps[1]].run, 14, "second nested run")

-- -- quote and encode ---------------------------------------------------------

eq(M.quote("plain"), '"plain"', "quote plain")
eq(M.quote("a\"b\\c"), '"a\\"b\\\\c"', "quote escapes")
eq(M.quote("\b\t\n\f\r"), '"\\b\\t\\n\\f\\r"', "quote controls")
eq(M.quote("\0"), '"\\u0000"', "quote null")
eq(M.quote("你好😀"), '"你好😀"', "quote unicode")
local quoted_src = "k = " .. M.quote("hi\0\t\"\\") .. "\n"
local quoted_val = parse_ok(quoted_src, "quote round-trip")
eq(quoted_val.k, "hi\0\t\"\\", "quote parsed")

local encoded = M.encode({
	z = 1,
	a = "x",
	["a b"] = 2,
	m = { q = 1 },
	t = { host = "h", opts = { a = 1 }, jobs = { { id = 9 } } },
	w = { { name = "b" }, { name = "a" } },
})
before(encoded, 'a = "x"', "m = { q = 1 }", "scalar before inline")
before(encoded, "m = { q = 1 }", "z = 1", "inline before later scalar")
before(encoded, "z = 1", "[t]", "assigns before table")
before(encoded, "[t]", "[[t.jobs]]", "table before its aot")
before(encoded, "[[t.jobs]]", "[[w]]", "nested aot before sibling aot")
assert(string.find(encoded, '"a b" = 2', 1, true) ~= nil, "quoted key")
assert(string.find(encoded, '"z"', 1, true) == nil, "bare key stays bare")
assert(string.find(encoded, "host = \"h\"", 1, true) ~= nil, "table body")
assert(string.find(encoded, "opts = { a = 1 }", 1, true) ~= nil, "inline nested")
eq(M.encode({ z = 1, a = "x" }), M.encode({ a = "x", z = 1 }), "deterministic")

local data: { [string]: any } = {
	title = "röost 子",
	count = 3,
	ratio = 1 / 3,
	on = false,
	flags = { true, false, true },
	note = "line\n\"quote\"\\",
	["weird key"] = "x",
	opts = { retries = 2, path = "C:\\tmp" },
	server = {
		host = "localhost",
		jobs = { { id = 1, run = "echo 你好" } },
	},
	workflow = {
		{
			name = "build",
			steps = {
				{ run = "echo 你好" },
				{ run = "echo 😀" },
			},
		},
		{
			name = "test",
			steps = { { run = "echo ok" } },
		},
	},
}
local again = parse_ok(M.encode(data), "round-trip")
deep_eq(again, data, "round-trip")
eq(M.encode(data), M.encode(data), "round-trip stable")

print("toml ok")
