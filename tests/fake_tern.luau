--!strict
-- A scripted stand-in for the `tern` global, enough to drive Roost's host half under the
-- standalone `luau` CLI: JSON, an in-memory fs and kv, queued process/fetch callbacks answered by
-- test handlers, a manual clock for timers, and tree-building ui builders that check shapes.

local F = {}

local NULL = setmetatable({}, { __tostring = function()
	return "null"
end })
local ARRAYS = setmetatable({}, { __mode = "k" })

local function encode(v: any, out: { string })
	local t = type(v)
	if v == nil or v == NULL then
		table.insert(out, "null")
	elseif t == "boolean" then
		table.insert(out, tostring(v))
	elseif t == "number" then
		if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
			table.insert(out, string.format("%d", v))
		else
			table.insert(out, string.format("%.17g", v))
		end
	elseif t == "string" then
		table.insert(out, '"' .. string.gsub(v, '[%c"\\]', function(c)
			local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
			return map[c] or string.format("\\u%04x", string.byte(c))
		end) .. '"')
	elseif t == "table" then
		local n = #v
		if ARRAYS[v] or n > 0 then
			table.insert(out, "[")
			for i = 1, n do
				if i > 1 then
					table.insert(out, ",")
				end
				encode(v[i], out)
			end
			table.insert(out, "]")
		else
			local keys = {}
			for k in v do
				table.insert(keys, tostring(k))
			end
			table.sort(keys)
			table.insert(out, "{")
			for i, k in keys do
				if i > 1 then
					table.insert(out, ",")
				end
				encode(k, out)
				table.insert(out, ":")
				encode(v[k], out)
			end
			table.insert(out, "}")
		end
	else
		error("json encode: " .. t)
	end
end

local function decode(text: string): any
	local pos = 1
	local function ws()
		pos = string.find(text, "[^ \t\r\n]", pos) or #text + 1
	end
	local value
	local function str(): string
		pos += 1
		local out = {}
		while true do
			local c = string.sub(text, pos, pos)
			if c == '"' then
				pos += 1
				return table.concat(out)
			elseif c == "\\" then
				local e = string.sub(text, pos + 1, pos + 1)
				local map = { n = "\n", r = "\r", t = "\t", b = "\b", f = "\f", ["/"] = "/", ["\\"] = "\\", ['"'] = '"' }
				if e == "u" then
					table.insert(out, utf8.char(tonumber(string.sub(text, pos + 2, pos + 5), 16) :: number))
					pos += 6
				else
					table.insert(out, map[e])
					pos += 2
				end
			elseif c == "" then
				error("json decode: unterminated string")
			else
				table.insert(out, c)
				pos += 1
			end
		end
	end
	function value(): any
		ws()
		local c = string.sub(text, pos, pos)
		if c == "{" then
			pos += 1
			local obj = {}
			ws()
			if string.sub(text, pos, pos) == "}" then
				pos += 1
				return obj
			end
			while true do
				ws()
				local k = str()
				ws()
				pos += 1
				local v = value()
				if v ~= NULL then
					obj[k] = v
				end
				ws()
				local d = string.sub(text, pos, pos)
				pos += 1
				if d == "}" then
					return obj
				end
			end
		elseif c == "[" then
			pos += 1
			local arr: { any } = {}
			ARRAYS[arr] = true
			-- Like Tern: decoded arrays carry a protected metatable (table.clone refuses them).
			setmetatable(arr :: any, { __metatable = "json array" })
			ws()
			if string.sub(text, pos, pos) == "]" then
				pos += 1
				return arr
			end
			while true do
				table.insert(arr, value())
				ws()
				local d = string.sub(text, pos, pos)
				pos += 1
				if d == "]" then
					return arr
				end
			end
		elseif c == '"' then
			return str()
		elseif string.sub(text, pos, pos + 3) == "true" then
			pos += 4
			return true
		elseif string.sub(text, pos, pos + 4) == "false" then
			pos += 5
			return false
		elseif string.sub(text, pos, pos + 3) == "null" then
			pos += 4
			return NULL
		else
			local num = string.match(text, "^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
			if not num then
				error("json decode: unexpected " .. c .. " at " .. pos)
			end
			pos += #num
			return tonumber(num)
		end
	end
	local v = value()
	ws()
	if pos <= #text then
		error("json decode: trailing data")
	end
	return v
end

-- ── ui builders ─────────────────────────────────────────────────────────────

local function is_node(n: any): boolean
	return type(n) == "table" and type(n.k) == "string"
end

local function node(k: string, p: any?, c: any?): any
	if c ~= nil then
		assert(type(c) == "table" and c.k == nil, "children must be a list of nodes for " .. k)
		for i, child in c do
			assert(type(i) == "number", k .. ": non-array children")
			assert(is_node(child), k .. ": child " .. tostring(i) .. " is not a node")
		end
	end
	local t: any = { k = k }
	if p and next(p) then
		t.p = p
	end
	if c and #c > 0 then
		t.c = c
	end
	return t
end

local function spans(s: any): any
	if s == nil then
		return {}
	elseif type(s) == "string" or type(s) == "number" then
		return { { t = tostring(s) } }
	elseif type(s) == "table" and s.t then
		assert(type(s.t) == "string", "span t must be a string")
		return { s }
	end
	assert(type(s) == "table", "spans must be a table, string or nil")
	for i, v in s do
		assert(
			type(v) == "string" or (type(v) == "table" and type(v.t) == "string"),
			"span " .. tostring(i) .. " is not a span"
		)
	end
	return s
end

local function merge(base: { [string]: any }, extra: any): { [string]: any }
	for k, v in extra or {} do
		base[k] = v
	end
	return base
end

local ui = {
	span = function(t: string, s: string?)
		assert(type(t) == "string", "span text must be a string")
		return { t = t, s = if s and s ~= "" then s else nil }
	end,
	link = function(t: string, href: string, s: string?)
		assert(type(t) == "string" and type(href) == "string", "link")
		return { t = t, href = href, s = s }
	end,
	path = function(p: string, _cwd: string?)
		assert(type(p) == "string", "path")
		return { t = p, s = "path", href = "file://" .. p }
	end,
	text = function(s: any)
		return node("text", { spans = spans(s) })
	end,
	col = function(c: any)
		return node("col", { gap = "sm" }, c)
	end,
	lines = function(c: any)
		return node("col", { gap = "none" }, c)
	end,
	row = function(c: any)
		return node("row", { gap = "sm" }, c)
	end,
	card = function(head: any, c: any, props: any?)
		return node("card", merge({ head = spans(head) }, props), c)
	end,
	section = function(head: any, c: any)
		return node("section", { head = spans(head) }, c)
	end,
	rule = function(label: any)
		return node("rule", { label = spans(label) })
	end,
	badge = function(t: string, tone: string?)
		assert(type(t) == "string", "badge text")
		return node("badge", { text = t, tone = tone })
	end,
	button = function(t: string?, props: any?)
		assert(t == nil or type(t) == "string", "button text")
		if props and props.variant then
			local ok = { default = true, primary = true, quiet = true, danger = true }
			assert(ok[props.variant], "button variant " .. tostring(props.variant))
		end
		return node("button", merge({ text = t }, props))
	end,
	kv = function(items: any)
		for _, pair in items do
			spans(pair[1])
			spans(pair[2])
		end
		return node("kv", { items = items })
	end,
	stats = function(items: any)
		for _, it in items do
			spans(it.label)
			spans(it.value)
		end
		return node("stats", { items = items })
	end,
	meter = function(v: number, label: any)
		assert(type(v) == "number", "meter value")
		return node("meter", { value = v, label = spans(label) })
	end,
	progress = function(v: number?, label: any)
		return node("progress", { value = v, label = spans(label) })
	end,
	table = function(cols: any, rows: any, opts: any?)
		local seen = {}
		for _, col in cols do
			assert(type(col.id) == "string" and type(col.head) == "string", "table col needs id and head")
			seen[col.id] = true
		end
		local ids = {}
		for i, r in rows do
			if r.id ~= nil then
				assert(type(r.id) == "string", "row id must be a string")
				assert(not ids[r.id], "duplicate row id " .. r.id)
				ids[r.id] = true
				assert(type(r.cells) == "table", "row cells")
			else
				assert(type(r) == "table", "row " .. tostring(i))
			end
		end
		return node("table", merge({ cols = cols, rows = rows }, opts))
	end,
	meter_cell = function(v: number, th: any?)
		return { meter = { value = v, thresholds = th } }
	end,
	list = function(items: any)
		local c = {}
		for _, it in items do
			spans(it.label)
			table.insert(c, node("item", it))
		end
		return node("list", nil, c)
	end,
	tree = function(nodes: any)
		return node("tree", { nodes = nodes })
	end,
	code = function(t: string, lang: string?, start: number?)
		assert(type(t) == "string", "code text")
		return node("code", { text = t, lang = lang, start = start })
	end,
	diff = function(t: string, path: string?)
		assert(type(t) == "string", "diff text")
		return node("diff", { text = t, path = path })
	end,
	md = function(t: string)
		assert(type(t) == "string", "md text")
		return node("md", { text = t })
	end,
	ansi = function(t: string)
		assert(type(t) == "string", "ansi text")
		return node("ansi", { text = t })
	end,
	diagnostic = function(d: any, _cwd: string?)
		assert(type(d.message) == "string", "diagnostic message")
		return node("card", { head = spans(d.message), diag = d })
	end,
	bars = function(series: any)
		return node("chart", { kind = "bars", series = series })
	end,
	spark = function(series: any)
		return node("chart", { kind = "spark", series = series })
	end,
	overflow = function(n: number)
		return node("text", { spans = { { t = `… {n} more` } } })
	end,
	node = function(k: string, p: any?, c: any?)
		assert(type(k) == "string", "node kind")
		return node(k, p, c)
	end,
	el = function(tag: string, p: any?, c: any?)
		local props = table.clone(p or {})
		props.tag = tag
		return node("el", props, c)
	end,
}

-- ── runtime ─────────────────────────────────────────────────────────────────

function F.new(opts: { [string]: any }?)
	local o = opts or {}
	local env: any = {
		files = {} :: { [string]: string },
		dirs = {} :: { [string]: boolean },
		kv = {} :: { [string]: any },
		queue = {} :: { () -> () },
		timers = {} :: { { at: number, fn: (any) -> (), cancelled: boolean } },
		clock = 0,
		process = function(_argv: { string }, _opts: any): any
			return { status = 127, stdout = "", stderr = "not scripted", timed_out = false }
		end,
		fetch = function(_url: string, _opts: any): any
			return { status = 0, headers = {}, body = "", error = "not scripted", timed_out = false }
		end,
		calls = {} :: { { argv: { string }, opts: any } },
		fetches = {} :: { { url: string, opts: any } },
		deferred = {} :: { { url: string, opts: any, cb: (any) -> () } },
		panes = { 1 } :: { number },
		blocks = {} :: { [string]: any },
		commands = {} :: { [string]: any },
		css = {} :: { [string]: string },
		envvars = (o :: any).env or { HOME = "/home/test", PATH = "/usr/bin:/bin" },
		logs = {} :: { string },
	}

	local function prefix_exists(path: string): boolean
		local p = path .. "/"
		for k in env.files do
			if string.sub(k, 1, #p) == p then
				return true
			end
		end
		return env.dirs[path] == true
	end

	local tern: any = {
		json = {
			encode = function(v: any, _pretty: boolean?)
				local out = {}
				encode(v, out)
				return table.concat(out)
			end,
			decode = decode,
			array = function(t: any?)
				local a = t or {}
				ARRAYS[a] = true
				-- Tags in place with a protected metatable, as Tern does.
				if getmetatable(a) == nil then
					setmetatable(a, { __metatable = "json array" })
				end
				return a
			end,
			null = NULL,
		},
		fs = {
			read = function(path: string, max: number?)
				local v = env.files[path]
				if v == nil then
					error("tern.fs.read " .. path .. ": No such file or directory")
				end
				if max and #v > max then
					error("tern.fs.read " .. path .. ": file larger than max_bytes")
				end
				return v
			end,
			write = function(path: string, text: string)
				assert(type(text) == "string", "fs.write text")
				env.files[path] = text
			end,
			exists = function(path: string)
				return env.files[path] ~= nil or prefix_exists(path)
			end,
			mkdir = function(path: string)
				env.dirs[path] = true
			end,
			remove = function(path: string)
				env.files[path] = nil
				env.dirs[path] = nil
				local p = path .. "/"
				for k: string in table.clone(env.files) :: { [string]: string } do
					if string.sub(k, 1, #p) == p then
						env.files[k] = nil
					end
				end
				for k: string in table.clone(env.dirs) :: { [string]: boolean } do
					if string.sub(k, 1, #p) == p then
						env.dirs[k] = nil
					end
				end
			end,
			list = function(path: string)
				local out, seen = {}, {}
				local p = path .. "/"
				for k in env.files do
					if string.sub(k, 1, #p) == p then
						local name = string.match(string.sub(k, #p + 1), "^[^/]+") :: string
						if not seen[name] then
							seen[name] = true
							table.insert(out, name)
						end
					end
				end
				table.sort(out)
				return out
			end,
		},
		kv = {
			get = function(key: string)
				return env.kv[key]
			end,
			set = function(key: string, v: any)
				-- Round-trip through JSON like the real store.
				env.kv[key] = if v == nil then nil else decode(table.concat((function()
					local out = {}
					encode(v, out)
					return out
				end)()))
			end,
		},
		process = {
			run = function(argv: { string }, opts: any, cb: ((any, any) -> ())?)
				assert(type(opts) == "table" and type(opts.timeout_ms) == "number", "process.run needs timeout_ms")
				table.insert(env.calls, { argv = argv, opts = opts })
				local r = env.process(argv, opts)
				if cb then
					table.insert(env.queue, function()
						if r ~= false then
							-- Window-context callbacks get a fresh cx: the fake window's, when one exists.
							cb(r, env.wcx)
						end
					end)
				end
			end,
		},
		fetch = function(url: string, opts: any, cb: (any) -> ())
			table.insert(env.fetches, { url = url, opts = opts })
			local r = env.fetch(url, opts or {})
			if r == false then
				-- Unanswered for now: the test may answer it later through env.deferred.
				table.insert(env.deferred, { url = url, opts = opts, cb = cb })
			else
				table.insert(env.queue, function()
					cb(r)
				end)
			end
		end,
		timer = function(ms: number, fn: (any) -> ())
			local t = { at = env.clock + ms, fn = fn, cancelled = false }
			table.insert(env.timers, t)
			return {
				cancel = function(self: any)
					assert(type(self) == "table", "bad argument 'self' to 'Handle.cancel'")
					t.cancelled = true
				end,
			}
		end,
		now = function()
			return env.clock
		end,
		getenv = function(name: string)
			return env.envvars[name]
		end,
		log = {
			debug = function(...) end,
			info = function(...) end,
			warn = function(...)
				table.insert(env.logs, table.concat({ ... } :: any, "\t"))
			end,
			error = function(...)
				table.insert(env.logs, table.concat({ ... } :: any, "\t"))
			end,
		},
		runtime = { os = "macos", jit = false },
		plugin = { id = "roost", name = "Roost", dir = "/plugin", data = "/data" },
		pane = {
			list = function()
				local out = {}
				for _, p in env.panes do
					table.insert(out, { pane = p, title = "" })
				end
				return out
			end,
		},
		block = {
			define = function(id: string, def: any)
				env.blocks[id] = def
			end,
		},
		command = function(def: any)
			env.commands[def.id] = def
		end,
		css = function(name: string, src: string)
			env.css[name] = src
		end,
		ui = ui,
	}
	env.tern = tern

	-- Runs queued callbacks until none are left.
	function env.drain()
		local guard = 0
		while #env.queue > 0 do
			guard += 1
			assert(guard < 10000, "callback storm")
			local fn = table.remove(env.queue, 1) :: () -> ()
			fn()
		end
	end

	-- Moves the clock (ms) and fires due timers, draining callbacks after each.
	function env.advance(ms: number)
		local target = env.clock + ms
		local guard = 0
		while true do
			env.drain()
			local best, idx = nil, nil
			for i, t in env.timers do
				if not t.cancelled and t.at <= target and (best == nil or t.at < best.at) then
					best, idx = t, i
				end
			end
			if not best then
				break
			end
			guard += 1
			assert(guard < 100000, "timer storm")
			table.remove(env.timers, idx)
			env.clock = best.at
			best.fn(nil)
		end
		env.clock = target
		env.drain()
	end

	-- A block cx that counts renders and records frames and opens.
	function env.cx(pane: number): any
		local cx: any = { pane = pane, cols = 120, rows = 40, cwd = nil, renders = 0, frames = {}, opened = {}, copied = {}, toasts = {} }
		function cx:frame(ops: any)
			assert(type(ops) == "table" and type(ops[1]) == "table", "cx:frame: ops must be a list")
			table.insert(cx.frames, ops)
		end
		function cx:render()
			cx.renders += 1
		end
		function cx:save() end
		function cx:blob(bytes: string, _mime: string): string
			return "blob" .. tostring(#bytes)
		end
		function cx:toast(level: string, text: string, _sub: string?)
			table.insert(cx.toasts, { level = level, text = text })
		end
		function cx:open(target: string)
			table.insert(cx.opened, target)
		end
		function cx:copy(text: string)
			table.insert(cx.copied, text)
		end
		return cx
	end

	-- The runner's log append (`printf … >>"$f"`, then the tail file): applied to env.files.
	function env.append(argv: { string }): any
		local script = argv[3] or ""
		if not string.find(script, 'printf "%s\\n" "$@" >>"$f"', 1, true) then
			return nil
		end
		local out = { env.files[argv[5]] or "" }
		for i = 7, #argv do
			table.insert(out, argv[i] .. "\n")
		end
		local tail = argv[6]
		if tail ~= "" and env.files[tail] then
			table.insert(out, env.files[tail] .. "\n")
		end
		env.files[argv[5]] = table.concat(out)
		return { status = 0, stdout = "", stderr = "", timed_out = false }
	end

	-- A window cx with agents, sessions, tabs and layout, enough for lib/launcher.luau. Agents
	-- start "working" with the prompt as their first message; `w.reply(pane, text)` ends a turn.
	function env.window(): any
		local w: any = {
			agents = {} :: { [number]: any },
			sessions = { { id = 1, name = "Default", host = 1, tabs = { 10 } } } :: { any },
			shown = 1,
			panes = { [1] = { tab = 10 } } :: { [number]: any },
			focused = 1,
			next_id = 100,
			started = {} :: { any },
			stopped = {} :: { number },
			moved = {} :: { any },
			named = {} :: { [number]: string },
			opened = {} :: { any },
			blocks = {} :: { any },
			closed = {} :: { number },
			toasts = {} :: { any },
			host_kind = "local",
		}
		local function new_id(): number
			w.next_id += 1
			return w.next_id
		end
		local function session(id: number): any
			for _, s in w.sessions do
				if s.id == id then
					return s
				end
			end
			return nil
		end
		local function new_tab(sid: number, pane: number): number
			local tab = new_id()
			table.insert(session(sid).tabs, tab)
			w.panes[pane] = w.panes[pane] or {}
			w.panes[pane].tab = tab
			return tab
		end
		local function managed(s: any): any
			return { id = s.id, name = s.name, host = s.host, current = s.id == w.shown, locked = false, note = nil, tabs = #s.tabs }
		end
		function w.reply(pane: number, text: string)
			local a = w.agents[pane]
			table.insert(a.messages, { role = "assistant", text = text, tools = {} })
			a.state = "idle"
		end
		local cx: any = {}
		cx.agents = {
			start = function(_self: any, o: any): number
				assert(type(o.prompt) == "string" and type(o.cwd) == "string", "agents:start prompt/cwd")
				local pane = new_id()
				new_tab(w.shown, pane)
				w.focused = pane
				w.agents[pane] = { state = "working", cwd = o.cwd, command = o.command, messages = { { role = "user", text = o.prompt, tools = {} } } }
				table.insert(w.started, { pane = pane, opts = o })
				return pane
			end,
			list = function(_self: any): any
				local out = {}
				for pane, a in w.agents do
					table.insert(out, { pane = pane, command = a.command, model = NULL, cwd = a.cwd, state = a.state, last_message = NULL })
				end
				return out
			end,
			transcript = function(_self: any, pane: number, o: any): any
				local a = w.agents[pane]
				assert(a, "transcript: no agent " .. tostring(pane))
				local n = (o and o.last) or 50
				local out = {}
				for i = math.max(1, #a.messages - n + 1), #a.messages do
					table.insert(out, a.messages[i])
				end
				return out
			end,
			stop = function(_self: any, pane: number)
				assert(w.agents[pane], "stop: no agent " .. tostring(pane))
				w.agents[pane] = nil
				w.panes[pane] = nil
				table.insert(w.stopped, pane)
			end,
		}
		cx.sessions = {
			list = function(_self: any): any
				local out = {}
				for _, s in w.sessions do
					table.insert(out, managed(s))
				end
				return out
			end,
			current = function(_self: any): any
				return managed(session(w.shown))
			end,
			create = function(_self: any, o: any): any
				local s = { id = new_id(), name = o.name, host = 1, tabs = {} }
				table.insert(w.sessions, s)
				new_tab(s.id, new_id())
				w.shown = s.id
				return managed(s)
			end,
			switch = function(_self: any, id: number)
				assert(session(id), "switch: no session")
				w.shown = id
			end,
		}
		cx.hosts = {
			list = function(_self: any): any
				return { { id = 1, name = "local", kind = w.host_kind, state = "connected", current = true, sessions = {}, panes = {} } }
			end,
			current = function(_self: any): any
				return { id = 1, name = "local", kind = w.host_kind, state = "connected", current = true, sessions = {}, panes = {} }
			end,
		}
		cx.session = {
			focused = function(_self: any): number?
				return w.focused
			end,
			tab_of = function(_self: any, pane: number): number?
				return w.panes[pane] and w.panes[pane].tab
			end,
			sessions = function(_self: any): any
				local out = {}
				for _, s in w.sessions do
					table.insert(out, { id = s.id, name = s.name, current = s.id == w.shown, locked = false, tabs = s.tabs })
				end
				return out
			end,
			panes = function(_self: any): any
				local out = {}
				for pane, p in w.panes do
					table.insert(out, { pane = pane, tab = p.tab, block = p.block, cwd = "" })
				end
				return out
			end,
		}
		cx.layout = {
			move_to_new_tab = function(_self: any, pane: number, sid: number, reveal: any): number
				table.insert(w.moved, { pane = pane, session = sid, reveal = reveal })
				return new_tab(sid, pane)
			end,
			name_tab = function(_self: any, tab: number, name: string?)
				w.named[tab] = name
			end,
			focus = function(_self: any, pane: number)
				w.focused = pane
			end,
			close = function(_self: any, pane: number)
				w.panes[pane] = nil
				table.insert(w.closed, pane)
			end,
			new_tab = function(_self: any, launch: any, _reveal: any): number
				local pane = new_id()
				new_tab(w.shown, pane)
				table.insert(w.opened, launch)
				return pane
			end,
		}
		function cx:new_block(kind: string, args: any, how: string, opts: any): number
			local pane = new_id()
			w.panes[pane] = { tab = w.panes[w.focused] and w.panes[w.focused].tab, block = kind }
			table.insert(w.blocks, { kind = kind, args = args, how = how, opts = opts, pane = pane })
			return pane
		end
		function cx:toast(level: string, text: string, sub: string?)
			table.insert(w.toasts, { level = level, text = text, sub = sub })
		end
		w.cx = cx
		return w
	end

	return env
end

-- Walks a view tree, calling `fn(node)` on every node (blocks' region roots included).
function F.walk(n: any, fn: (any) -> ())
	if type(n) ~= "table" then
		return
	end
	fn(n)
	for _, c in n.c or {} do
		F.walk(c, fn)
	end
end

-- Every sibling key must be unique (Tern rejects duplicate child keys).
function F.check_keys(n: any, path: string?)
	local here = path or n.k
	local seen = {}
	for i, c in n.c or {} do
		local key = c.p and c.p.key
		if key ~= nil then
			assert(not seen[key], `duplicate child key {key} under {here}`)
			seen[key] = true
		end
		F.check_keys(c, `{here}/{key or i}`)
	end
end

-- All text of a tree joined (spans, text props, button labels), for content assertions.
function F.text(n: any): string
	local out = {}
	F.walk(n, function(x)
		local p = x.p or {}
		for _, k in { "text", "label", "head", "spans", "meta" } do
			local v = p[k]
			if type(v) == "string" then
				table.insert(out, v)
			elseif type(v) == "table" then
				for _, s in v do
					if type(s) == "string" then
						table.insert(out, s)
					elseif type(s) == "table" and type(s.t) == "string" then
						table.insert(out, s.t)
					end
				end
				if type(v.t) == "string" then
					table.insert(out, v.t)
				end
			end
		end
	end)
	return table.concat(out, " ")
end

F.NULL = NULL
F.decode = decode
F.encode = function(v: any): string
	local out = {}
	encode(v, out)
	return table.concat(out)
end
return F
