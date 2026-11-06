--!strict
-- Tern tabs that workflows open and close (`tab` steps). Only a window can touch tabs, so the host
-- queues operations as files and lists them in kv; a window claims each with `mkdir`, carries it
-- out and writes the result. Every tab a workflow opens is recorded in a registry the windows keep,
-- and "close" only ever closes a recorded tab whose pane is still the one Roost opened: a user's own
-- tabs are never touched.
--
--   tabs/ops/<op>.json          host: the operation (Op)
--   tabs/ops/<op>.claim/        window: made with mkdir, so exactly one window carries it out
--   tabs/ops/<op>.done          window: the Result
--   tabs/open/<wf>.<key>.json   window: the tab open under that workflow's key (Entry)
--   kv `tab_ops`                host → windows: ids of the operations not yet done
--
-- Keys belong to a workflow (`.` can't occur in an id), so one workflow can't close another's tab.

local M = {}

M.KV = "tab_ops"
-- Most registry entries: an open beyond this fails instead of growing the directory.
M.MAX_ENTRIES = 200
-- Most bytes read from an op, result or entry file.
local MAX_FILE = 64 * 1024

export type Op = {
	id: string,
	action: "open" | "close",
	workflow: string,
	key: string,
	run: string,
	-- close: only when the tab was opened by `run` (the run-end close of a tab a later run took over
	-- stays open)
	only_run: boolean?,
	cwd: string?,
	command: string?,
	title: string?,
	focus: boolean?,
	keep: boolean?,
	session: string,
	created: number,
}

export type Result = { ok: boolean, message: string, pane: number? }

-- A tab Roost opened. `kind` is the pane's kind when it opened: a pane id that later names something
-- else is never closed.
export type Entry = { workflow: string, key: string, pane: number, kind: string, run: string, keep: boolean, at: number }

export type Paths = { op: string, claim: string, done: string }

function M.ops_dir(data: string): string
	return `{data}/tabs/ops`
end

function M.open_dir(data: string): string
	return `{data}/tabs/open`
end

-- An op id: letters, digits and `-` only (run ids are hex).
function M.valid_id(id: string): boolean
	return #id > 0 and #id <= 80 and string.match(id, "^[%w%-]+$") ~= nil
end

function M.step_id(run: string, step: number): string
	return `{run}-s{step}`
end

function M.end_id(run: string, step: number): string
	return `{run}-end{step}`
end

function M.paths(data: string, id: string): Paths
	local base = `{M.ops_dir(data)}/{id}`
	return { op = `{base}.json`, claim = `{base}.claim`, done = `{base}.done` }
end

function M.entry_path(data: string, workflow: string, key: string): string
	return `{M.open_dir(data)}/{workflow}.{key}.json`
end

local function read_json(path: string): any
	local ok, text = pcall(tern.fs.read, path, MAX_FILE)
	if not ok then
		return nil
	end
	local ok2, v = pcall(tern.json.decode, text :: string)
	return if ok2 and type(v) == "table" then v else nil
end

local function write_json(path: string, v: any): string?
	local ok, err = pcall(function(): string?
		tern.fs.write(path, tern.json.encode(v))
		return nil
	end)
	return if ok then nil else tostring(err)
end

local function str(v: any): string?
	return if type(v) == "string" then v else nil
end

function M.read_op(path: string): Op?
	local v = read_json(path)
	if v == nil then
		return nil
	end
	for _, k in { "id", "workflow", "key", "run", "session" } do
		if type(v[k]) ~= "string" then
			return nil
		end
	end
	if (v.action ~= "open" and v.action ~= "close") or type(v.created) ~= "number" then
		return nil
	end
	return {
		id = v.id,
		action = v.action,
		workflow = v.workflow,
		key = v.key,
		run = v.run,
		only_run = v.only_run == true,
		cwd = str(v.cwd),
		command = str(v.command),
		title = str(v.title),
		focus = v.focus == true,
		keep = v.keep == true,
		session = v.session,
		created = v.created,
	}
end

-- Writes `op` (its directory first); nil when written.
function M.write_op(data: string, op: Op): string?
	pcall(tern.fs.mkdir, M.ops_dir(data))
	local p = M.paths(data, op.id)
	pcall(tern.fs.remove, p.done)
	pcall(tern.fs.remove, p.claim)
	return write_json(p.op, op)
end

function M.read_result(path: string): Result?
	local v = read_json(path)
	if v == nil or type(v.ok) ~= "boolean" then
		return nil
	end
	return {
		ok = v.ok,
		message = if type(v.message) == "string" then string.sub(v.message, 1, 2000) else "",
		pane = if type(v.pane) == "number" then v.pane else nil,
	}
end

function M.write_result(path: string, res: Result)
	local err = write_json(path, res)
	if err then
		tern.log.warn("roost: cannot write tab result", path, err)
	end
end

-- Removes an op's files (claim directory included).
function M.remove(data: string, id: string)
	local p = M.paths(data, id)
	pcall(tern.fs.remove, p.op)
	pcall(tern.fs.remove, p.done)
	pcall(tern.fs.remove, p.claim)
end

-- The ops on disk (and whether each has its result), and leftovers (a result or claim without its
-- op) to remove.
function M.scan(data: string): ({ { id: string, done: boolean } }, { string })
	local ok, names = pcall(tern.fs.list, M.ops_dir(data))
	local found: { { id: string, done: boolean } } = {}
	local leftover: { string } = {}
	if not ok or type(names) ~= "table" then
		return found, leftover
	end
	local ops: { [string]: boolean } = {}
	local other: { [string]: boolean } = {}
	for _, n in names :: { string } do
		local id = string.match(n, "^([%w%-]+)%.json$")
		if id then
			ops[id] = true
		else
			local o = string.match(n, "^([%w%-]+)%.done$") or string.match(n, "^([%w%-]+)%.claim$")
			if o then
				other[o] = true
			end
		end
	end
	for id in ops do
		table.insert(found, { id = id, done = tern.fs.exists(M.paths(data, id).done) })
	end
	for id in other do
		if not ops[id] then
			table.insert(leftover, id)
		end
	end
	table.sort(found, function(a, b)
		return a.id < b.id
	end)
	table.sort(leftover)
	return found, leftover
end

function M.read_entry(path: string): Entry?
	local v = read_json(path)
	if v == nil then
		return nil
	end
	if type(v.workflow) ~= "string" or type(v.key) ~= "string" or type(v.pane) ~= "number" or type(v.kind) ~= "string" then
		return nil
	end
	return {
		workflow = v.workflow,
		key = v.key,
		pane = v.pane,
		kind = v.kind,
		run = if type(v.run) == "string" then v.run else "",
		keep = v.keep == true,
		at = if type(v.at) == "number" then v.at else 0,
	}
end

function M.write_entry(data: string, e: Entry): string?
	pcall(tern.fs.mkdir, M.open_dir(data))
	return write_json(M.entry_path(data, e.workflow, e.key), e)
end

-- Registry file paths, at most MAX_ENTRIES + 1 of them (enough to tell "full").
function M.entries(data: string): { string }
	local ok, names = pcall(tern.fs.list, M.open_dir(data))
	local out: { string } = {}
	if ok and type(names) == "table" then
		for _, n in names :: { string } do
			if string.match(n, "^[%w_%-]+%.[%w_%-]+%.json$") then
				table.insert(out, `{M.open_dir(data)}/{n}`)
				if #out > M.MAX_ENTRIES then
					break
				end
			end
		end
	end
	return out
end

return M
