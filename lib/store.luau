--!strict
-- Run history: `runs.json` (all records, newest last, bounded by keep_runs) plus one directory
-- per run under `runs/<id>/` (log, event payload, step pid/exit files).
--
-- tern.fs has no rename, so a save writes `runs.json.bak` first, then `runs.json`: a crash in
-- either write leaves the other file whole, and load falls back to the backup.

local M = {}

export type StepRec = {
	name: string,
	kind: string, -- prepare | omp | run | cleanup
	state: string, -- pending | running | success | failed | skipped
	exit_code: number?,
	started_at: number?,
	finished_at: number?,
}

export type Run = {
	id: string,
	workflow: string,
	workflow_name: string,
	title: string,
	trigger: { kind: string, detail: string, delivery: string? },
	repo: string?,
	ref: string?,
	-- queued | running | success | failed | cancelled | timed_out | interrupted | skipped
	state: string,
	reason: string?,
	created_at: number,
	started_at: number?,
	finished_at: number?,
	inputs: { [string]: string },
	steps: { StepRec },
	step: number, -- index of the current step (0 before start)
	deadline: number?,
	step_deadline: number?,
	stop: string?, -- cancel | timeout, while stopping
	final: string?, -- terminal state decided while cleanup still runs
	workspace: string?, -- worktree | repo | temp
	cwd: string?,
	repo_path: string?,
	fetch_ref: string?,
	event: { [string]: any }?,
	rerun_of: string?,
}

export type Store = {
	dir: string,
	keep: number,
	runs: { Run },
	by_id: { [string]: Run },
}

local MAX_INDEX_BYTES = 16 * 1024 * 1024

M.TERMINAL = {
	success = true,
	failed = true,
	cancelled = true,
	timed_out = true,
	interrupted = true,
	skipped = true,
}

function M.new(dir: string, keep: number): Store
	return { dir = dir, keep = keep, runs = {}, by_id = {} }
end

function M.run_dir(s: Store, id: string): string
	return `{s.dir}/runs/{id}`
end

-- The decoded list, or nil plus the raw text when the file exists but can't be used.
local function decode(path: string): ({ Run }?, string?)
	local ok, text = pcall(tern.fs.read, path, MAX_INDEX_BYTES)
	if not ok then
		return nil, nil
	end
	local ok2, v = pcall(tern.json.decode, text :: string)
	if not ok2 or type(v) ~= "table" then
		return nil, text :: string
	end
	return v :: any, nil
end

-- Loads history in its saved order (oldest first). A history file that exists but can't be
-- decoded is copied aside before the next save replaces it.
function M.load(s: Store)
	local main, bad_main = decode(`{s.dir}/runs.json`)
	local list = main
	if list == nil then
		local bak, bad_bak = decode(`{s.dir}/runs.json.bak`)
		list = bak
		local bad = bad_main or bad_bak
		if list == nil and bad then
			pcall(tern.fs.write, `{s.dir}/runs.json.unreadable`, bad)
			tern.log.warn("roost: runs.json unreadable; kept a copy as runs.json.unreadable")
		end
	end
	s.runs, s.by_id = {}, {}
	local rows: { Run } = list or {}
	for _, r in rows do
		if type(r) == "table" and type(r.id) == "string" and s.by_id[r.id] == nil then
			r.inputs = r.inputs or {}
			r.steps = r.steps or {}
			table.insert(s.runs, r)
			s.by_id[r.id] = r
		end
	end
end

function M.save(s: Store): string?
	-- json.array tags its argument in place (a protected metatable): tag a copy, not s.runs.
	local text = tern.json.encode(tern.json.array(table.move(s.runs, 1, #s.runs, 1, {})))
	local ok, err = pcall(function(): string?
		tern.fs.write(`{s.dir}/runs.json.bak`, text)
		tern.fs.write(`{s.dir}/runs.json`, text)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot save runs", err)
		return tostring(err)
	end
	return nil
end

function M.add(s: Store, r: Run)
	table.insert(s.runs, r)
	s.by_id[r.id] = r
end

-- Drops the oldest finished runs past `keep` and their directories.
function M.prune(s: Store)
	local excess = #s.runs - s.keep
	if excess <= 0 then
		return
	end
	local kept: { Run } = {}
	for _, r in s.runs do
		if excess > 0 and M.TERMINAL[r.state] then
			excess -= 1
			s.by_id[r.id] = nil
			pcall(tern.fs.remove, M.run_dir(s, r.id))
		else
			table.insert(kept, r)
		end
	end
	s.runs = kept
end

-- Newest first, optionally only one workflow's, at most `limit`.
function M.list(s: Store, limit: number, workflow: string?): { Run }
	local out = {}
	for i = #s.runs, 1, -1 do
		local r = s.runs[i]
		if workflow == nil or r.workflow == workflow then
			table.insert(out, r)
			if #out >= limit then
				break
			end
		end
	end
	return out
end

-- The newest run of each workflow.
function M.latest(s: Store): { [string]: Run }
	local out: { [string]: Run } = {}
	for i = #s.runs, 1, -1 do
		local r = s.runs[i]
		if out[r.workflow] == nil then
			out[r.workflow] = r
		end
	end
	return out
end

return M
