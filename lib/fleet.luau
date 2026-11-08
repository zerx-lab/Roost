--!strict
-- Devices sharing one relay (agent/src/fleet.rs): which device runs which workflow, each device's
-- runs and the shared configuration. Pure helpers for lib/core.luau:
--
--   owner         the device that runs a workflow: its own assignment, else the default device;
--                 for an event, the assignment that held when the relay received it
--   summaries     a device's recent runs as uploaded for the others (no inputs, payloads or
--                 local paths; log tails for the newest few), bounded by MAX_BODY
--   decode_runs   an uploaded list back into run records the runs page can show (read-only)
--   mirror_text   this machine's workflows.toml from the shared configuration (export format):
--                 its workflows and repos, with this machine's repo paths and env values (the
--                 upload carries neither)

local toml = require("./toml")
local model = require("./model")
local util = require("./util")
local bundle = require("./bundle")
local store = require("./store")
local inbox = require("./inbox")

local M = {}

-- Runs uploaded, newest first; the newest TAILS of them carry their log's last TAIL_BYTES.
M.MAX_RUNS = 100
M.TAILS = 20
M.TAIL_BYTES = 4096
-- The relay takes up to 512 KiB per device (fleet::MAX_RUNS); stay under it.
M.MAX_BODY = 480 * 1024
M.FORMAT = 1
-- The `owners` key of the default device (fleet::DEFAULT).
M.DEFAULT = "*"

-- The default device as the relay's record names it.
export type Executor = { id: string, name: string?, since: string? }
-- One entry of an assignment's history: events after `seq` are `client`'s (nil: a workflow
-- follows the default device; the default itself: every device runs).
export type Owner = { client: string?, name: string?, seq: number }

-- The default device in a device record, when one is assigned.
function M.executor(f: any): Executor?
	if type(f) ~= "table" or type(f.executor) ~= "table" or type(f.executor.id) ~= "string" then
		return nil
	end
	local ex = f.executor
	return {
		id = ex.id,
		name = if type(ex.name) == "string" and ex.name ~= "" then ex.name else nil,
		since = if type(ex.since) == "string" then ex.since else nil,
	}
end

-- Why the relay can't say who runs what (its device record is unreadable), or nil.
function M.error(f: any): string?
	return if type(f) == "table" and type(f.error) == "string" then f.error else nil
end

-- The history of `key` (a workflow id or DEFAULT), oldest first; malformed entries dropped. A
-- relay from before per-workflow assignments has no `owners`: its executor is the default device
-- for every event (so this machine runs nothing there unless it is that executor).
function M.owners(f: any, key: string): { Owner }
	local out: { Owner } = {}
	if type(f) == "table" and f.owners == nil then
		local ex = M.executor(f)
		if ex and key == M.DEFAULT then
			table.insert(out, { client = ex.id, name = ex.name, seq = 0 })
		end
		return out
	end
	local list = if type(f) == "table" and type(f.owners) == "table" then f.owners[key] else nil
	if type(list) ~= "table" then
		return out
	end
	for _, o in list do
		if type(o) == "table" and type(o.seq) == "number" then
			table.insert(out, {
				client = if type(o.client) == "string" then o.client else nil,
				name = if type(o.name) == "string" and o.name ~= "" then o.name else nil,
				seq = o.seq,
			})
		end
	end
	return out
end

-- The entry that held for event `seq` (the last one assigned before it), or now when nil.
local function holding(list: { Owner }, seq: number?): Owner?
	if seq == nil then
		return list[#list]
	end
	local best: Owner? = nil
	for _, o in list do
		if o.seq < seq then
			best = o
		end
	end
	return best
end

-- The device workflow `wf` has of its own now (nil: it follows the default device).
function M.assigned(f: any, wf: string): string?
	local o = holding(M.owners(f, wf), nil)
	return if o then o.client else nil
end

-- The device that runs `wf`, for event `seq` or else now: its own assignment, else the default
-- device. Nil: every device runs it (nothing assigned).
function M.owner(f: any, wf: string, seq: number?): string?
	local o = holding(M.owners(f, wf), seq)
	if o and o.client then
		return o.client
	end
	local d = holding(M.owners(f, M.DEFAULT), seq)
	return if d then d.client else nil
end

-- Whether device `me` runs `wf` (for event `seq`, else now). Nobody does while the record is
-- unreadable.
function M.runs_here(f: any, me: string, wf: string, seq: number?): boolean
	if M.error(f) then
		return false
	end
	local o = M.owner(f, wf, seq)
	return o == nil or o == me
end

-- The workflows with a device of their own now: workflow id → client id.
function M.assignments(f: any): { [string]: string }
	local out: { [string]: string } = {}
	if type(f) == "table" and type(f.owners) == "table" then
		for key in f.owners do
			if type(key) == "string" and key ~= M.DEFAULT then
				local c = M.assigned(f, key)
				if c then
					out[key] = c
				end
			end
		end
	end
	return out
end

-- The name the record has for device `id` (from its assignments), or nil.
function M.name_of(f: any, id: string): string?
	local ex = M.executor(f)
	if ex and ex.id == id and ex.name then
		return ex.name
	end
	if type(f) == "table" and type(f.owners) == "table" then
		for key in f.owners do
			if type(key) == "string" then
				for _, o in M.owners(f, key) do
					if o.client == id and o.name then
						return o.name
					end
				end
			end
		end
	end
	return nil
end

-- How a device is called: its client_name, else its id.
function M.label(ex: Executor?): string
	if ex == nil then
		return "未指定"
	end
	return ex.name or ex.id
end

-- Most model uses a step summary carries (the runner keeps as many).
local MAX_USES = 32

local function step_summary(s: store.StepRec): { [string]: any }
	local uses: { any }? = nil
	if s.models then
		uses = {}
		for _, u in s.models do
			table.insert(uses :: { any }, { model = u.model, agent = u.agent, role = u.role })
		end
	end
	return {
		name = s.name,
		kind = s.kind,
		state = s.state,
		exit_code = s.exit_code,
		started_at = s.started_at,
		finished_at = s.finished_at,
		agent = s.agent,
		cost = s.cost,
		tokens = s.tokens,
		model = s.model,
		models = if uses then tern.json.array(uses) else nil,
	}
end

local function run_summary(r: store.Run, tail: string?): { [string]: any }
	local steps = {}
	for _, s in r.steps do
		table.insert(steps, step_summary(s))
	end
	return {
		id = r.id,
		workflow = r.workflow,
		workflow_name = r.workflow_name,
		title = r.title,
		trigger = { kind = r.trigger.kind, detail = r.trigger.detail },
		repo = r.repo,
		ref = r.ref,
		state = r.state,
		reason = r.reason,
		created_at = r.created_at,
		started_at = r.started_at,
		finished_at = r.finished_at,
		workspace = r.workspace,
		rerun_of = r.rerun_of,
		-- Built-in runs: only the kind (a task's text stays on its device) and how they relate.
		task = if r.task then { kind = r.task.kind } else nil,
		parent = r.parent,
		changes = r.changes,
		branch = r.branch,
		pr = r.pr,
		steps = tern.json.array(steps),
		log = tail,
	}
end

-- The upload body: `runs` newest first (at most MAX_RUNS), tails from `tails` for the newest
-- TAILS, and the inbox's `boxes`. Over MAX_BODY, tails go first, then the inbox, then older runs.
-- Returns the encoded body; unchanged runs give the same text (the relay records when it arrived).
function M.summaries(runs: { store.Run }, tails: { [string]: string }, boxes: { [string]: inbox.Box }?): string
	local box_data = if boxes and next(boxes) then inbox.encode_boxes(boxes) else nil
	local function encode(n: number, with_tails: boolean): string
		local list = {}
		for i = 1, math.min(n, #runs) do
			local r = runs[i]
			table.insert(list, run_summary(r, if with_tails and i <= M.TAILS then tails[r.id] else nil))
		end
		return tern.json.encode({ format = M.FORMAT, runs = tern.json.array(list), inbox = box_data })
	end
	local n = math.min(M.MAX_RUNS, #runs)
	local body = encode(n, true)
	if #body <= M.MAX_BODY then
		return body
	end
	body = encode(n, false)
	if #body > M.MAX_BODY and box_data then
		box_data = nil
		body = encode(n, false)
	end
	while #body > M.MAX_BODY and n > 1 do
		n = n // 2
		body = encode(n, false)
	end
	return body
end

-- A log's last bytes as read by `tail -c`: starts after the first newline (the cut may land
-- inside a line or a UTF-8 sequence) unless that would leave nothing.
function M.clean_tail(raw: string, full: boolean): string
	if full then
		return raw
	end
	local nl = string.find(raw, "\n", 1, true)
	if nl and nl < #raw then
		return string.sub(raw, nl + 1)
	end
	-- One long line: drop UTF-8 continuation bytes the cut left at the front.
	return (string.gsub(raw, "^[\128-\191]+", ""))
end

local function str(v: any): string?
	return if type(v) == "string" then v else nil
end

local function num(v: any): number?
	return if type(v) == "number" then v else nil
end

-- A string no longer than `n` bytes, else nil.
local function short(v: any, n: number): string?
	return if type(v) == "string" and #v <= n then v else nil
end

local function uses_of(v: any): { store.ModelUse }?
	if type(v) ~= "table" then
		return nil
	end
	local out: { store.ModelUse } = {}
	for _, u in v do
		if #out >= MAX_USES then
			break
		end
		local m = if type(u) == "table" then short(u.model, 200) else nil
		if m then
			table.insert(out, { model = m, agent = short(u.agent, 100), role = short(u.role, 64) })
		end
	end
	return if #out > 0 then out else nil
end

-- An uploaded run list back into run records (only what the runs page shows), each run's log
-- tail, and the uploading device's inbox. Malformed entries are dropped.
function M.decode_runs(body: any): ({ store.Run }, { [string]: string }, { [string]: inbox.Box })
	local out: { store.Run } = {}
	local tails: { [string]: string } = {}
	if type(body) ~= "table" or type(body.runs) ~= "table" then
		return out, tails, {}
	end
	for _, v in body.runs do
		if #out >= M.MAX_RUNS then
			break
		end
		-- Ids are hex on every device; anything else (a path, say) is not a run of Roost's.
		local okid = type(v) == "table" and type(v.id) == "string" and #v.id <= 64 and string.match(v.id, "^%x+$") ~= nil
		if not okid or type(v.state) ~= "string" then
			continue
		end
		local steps: { store.StepRec } = {}
		if type(v.steps) == "table" then
			for _, s in v.steps do
				if type(s) == "table" and type(s.name) == "string" and type(s.kind) == "string" and type(s.state) == "string" then
					table.insert(steps, {
						name = s.name,
						kind = s.kind,
						state = s.state,
						exit_code = num(s.exit_code),
						started_at = num(s.started_at),
						finished_at = num(s.finished_at),
						agent = if s.agent == true then true else nil,
						cost = num(s.cost),
						tokens = num(s.tokens),
						model = short(s.model, 200),
						models = uses_of(s.models),
					})
				end
			end
		end
		local trig = if type(v.trigger) == "table" then v.trigger else {}
		table.insert(out, {
			id = v.id,
			workflow = str(v.workflow) or "?",
			workflow_name = str(v.workflow_name) or str(v.workflow) or "?",
			title = str(v.title) or "",
			trigger = { kind = str(trig.kind) or "manual", detail = str(trig.detail) or "" },
			repo = str(v.repo),
			ref = str(v.ref),
			state = v.state,
			reason = str(v.reason),
			created_at = num(v.created_at) or 0,
			started_at = num(v.started_at),
			finished_at = num(v.finished_at),
			workspace = str(v.workspace),
			rerun_of = str(v.rerun_of),
			task = if type(v.task) == "table" and (v.task.kind == "task" or v.task.kind == "pr")
				then { kind = v.task.kind :: string, prompt = "", workspace = "" }
				else nil,
			parent = if type(v.parent) == "string" and string.match(v.parent, "^%x+$") then v.parent else nil,
			changes = if type(v.changes) == "table" and num(v.changes.files) and num(v.changes.add) and num(v.changes.del)
				then { files = v.changes.files, add = v.changes.add, del = v.changes.del, too_big = if v.changes.too_big == true then true else nil }
				else nil,
			branch = short(v.branch, 200),
			pr = if type(v.pr) == "string" and #v.pr <= 500 and string.match(v.pr, "^https://") then v.pr else nil,
			inputs = {},
			steps = steps,
			step = 0,
		})
		if type(v.log) == "string" then
			tails[v.id] = v.log
		end
	end
	return out, tails, inbox.decode_boxes(body.inbox)
end

-- The repositories and workflows of the local workflows.toml text (unparsable: none).
local function local_parts(old: string): ({ [string]: any }, { [string]: { [string]: any } })
	local root = toml.parse(old)
	local repos: { [string]: any } = {}
	local wfs: { [string]: { [string]: any } } = {}
	if type(root) == "table" then
		if type(root.repos) == "table" then
			repos = root.repos
		end
		if type(root.workflow) == "table" then
			for _, w in root.workflow do
				if type(w) == "table" and type(w.id) == "string" then
					wfs[w.id] = w
				end
			end
		end
	end
	return repos, wfs
end

-- This machine's workflows.toml from the shared configuration `b`: its repos and workflows,
-- keeping from the local text `old` each repo's path and each env value the upload left blank.
-- Repos the configuration no longer has go (it is the truth everywhere). Returns the text and
-- the repos without a path here.
function M.mirror_text(b: bundle.Bundle, old: string): (string, { string })
	local lrepos, lwfs = local_parts(old)
	local out: { string } = {
		"# 由 Roost 设备同步写入:工作流配置在共用同一中继的设备间同步,本机的修改也会同步给其他设备。",
		"# 只留在本机的内容:各仓库的本机路径 path、工作流 env 的值(同步不上传这两项)。",
	}
	local missing: { string } = {}
	for _, name in util.keys(b.repos) do
		local lr = if type(lrepos[name]) == "table" then lrepos[name] else {}
		local br = b.repos[name]
		table.insert(out, "")
		table.insert(out, `[repos.{toml.quote(name)}]`)
		if type(lr.path) == "string" and lr.path ~= "" then
			table.insert(out, `path = {toml.quote(lr.path)}`)
		else
			table.insert(missing, name)
		end
		if br.branch then
			table.insert(out, `branch = {toml.quote(br.branch)}`)
		end
		if br.worktree ~= nil then
			table.insert(out, `worktree = {if br.worktree then "true" else "false"}`)
		end
	end
	for _, raw in b.workflows do
		local mine = lwfs[tostring(raw.id)]
		if type(raw.env) == "table" and mine and type(mine.env) == "table" then
			local have = mine.env :: { [string]: any }
			for k, v in raw.env :: { [string]: any } do
				if v == "" and type(have[k]) == "string" then
					(raw.env :: { [string]: any })[k] = have[k]
				end
			end
		end
		table.insert(out, "")
		table.insert(out, (string.gsub(model.encode_workflow(raw), "\n$", "")))
	end
	return table.concat(out, "\n") .. "\n", missing
end

return M
