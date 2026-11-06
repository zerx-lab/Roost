--!strict
-- Run history: `runs.json` (all records, newest last, bounded by retention count and age) plus
-- one directory per run under `runs/<id>/` (log, event payload, step pid/exit files, omp
-- sessions) and, for worktree runs, `worktrees/<id>/`.
--
-- Dropping runs is two-phase: the index forgets them at once (cheap, saved with runs.json) and
-- their directories go to `trash`, which `drain` empties a few at a time so a large cleanup never
-- blows a call's budget. Directories the index doesn't know (a reload mid-drain, older bugs) are
-- found by `sweep`.
--
-- tern.fs has no rename, so a save writes `runs.json.bak` first, then `runs.json`: a crash in
-- either write leaves the other file whole, and load falls back to the backup.

local agent = require("./agent")

local M = {}

export type StepRec = {
	name: string,
	kind: string, -- auth | prepare | evolve | omp | run | file | tab | upgrade | cleanup
	state: string, -- pending | running | success | failed | skipped
	exit_code: number?,
	started_at: number?,
	finished_at: number?,
	agent: boolean?, -- ran as an agent block (lib/agent.luau); older omp steps ran headless
	opened: boolean?, -- agent step: "the tab is open" was logged
	tail_file: string?, -- agent step: the session file being followed into the log
	tail: number?, -- agent step: bytes of tail_file already logged
	replied: boolean?, -- agent step: the log already holds the final answer
	cost: number?, -- agent step: estimated USD from its session files (subagents included), once it ended
	tokens: number?, -- agent step: total tokens from the same files
	tab_op: string?, -- tab step: its queued operation (lib/tabs.luau)
	-- tab step: the key whose tab the run's end may close (nil once no window ever took the
	-- operation), and whether it outlives the run (close steps: always)
	tab_key: string?,
	tab_keep: boolean?,
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
	identity: string?, -- "app" when the run acts on GitHub as the relay's App
	-- While identity is "app": the bot account and when the run's token expires (renewed while it runs).
	app: { login: string, email: string, expires: number }?,
	-- `key=value` lines steps appended to $ROOST_OUTPUT (later steps see them as out.<key>).
	outputs: { [string]: string }?,
	-- A run an evolver started because a target failed (lib/evolve.luau): that workflow and its run.
	evolve_target: string?,
	evolve_run: string?,
}

export type Store = {
	dir: string,
	keep: number,
	max_age: number, -- seconds a finished run is kept; 0 keeps them regardless of age
	runs: { Run },
	by_id: { [string]: Run },
	trash: { string }, -- directories waiting for `drain`
	indexed: boolean, -- runs.json was read (or never existed): `sweep` may trust the index
	policy: boolean, -- keep/max_age come from a valid roost.toml: nothing expires before that
	tries: { [string]: number }, -- failed removals per queued path (bounded by MAX_TRIES)
	inflight: { [string]: boolean }, -- paths an `rm` is deleting right now
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

function M.new(dir: string, keep: number, max_age: number): Store
	return {
		dir = dir,
		keep = keep,
		max_age = max_age,
		runs = {},
		by_id = {},
		trash = {},
		indexed = false,
		policy = false,
		tries = {},
		inflight = {},
	}
end

function M.run_dir(s: Store, id: string): string
	return agent.run_dir(s.dir, id)
end

-- Where a worktree run checks out; Roost owns it (never the user's own checkout).
function M.worktree_dir(s: Store, id: string): string
	return `{s.dir}/worktrees/{id}`
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
	-- Only an index that was read (or never existed) says which directories are orphans: with an
	-- unreadable runs.json every run directory would look unowned. That stays true while the
	-- unreadable copy is kept, even after a save writes a fresh (smaller) runs.json.
	local function there(name: string): boolean
		local ok, yes = pcall(tern.fs.exists, `{s.dir}/{name}`)
		return ok and yes == true
	end
	s.indexed = not there("runs.json.unreadable") and (list ~= nil or not (there("runs.json") or there("runs.json.bak")))
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

-- Finished runs past the retention policy, oldest first: beyond `keep` finished runs, or
-- finished longer than `max_age` ago. Nothing until a valid roost.toml set the policy.
function M.expired(s: Store, now: number): { string }
	local out: { string } = {}
	if not s.policy then
		return out
	end
	local excess = -s.keep
	for _, r in s.runs do
		if M.TERMINAL[r.state] then
			excess += 1
		end
	end
	local cutoff = if s.max_age > 0 then now - s.max_age else nil
	for _, r in s.runs do
		if M.TERMINAL[r.state] then
			local old = cutoff ~= nil and (r.finished_at or r.created_at) < cutoff
			if excess > 0 or old then
				table.insert(out, r.id)
				excess -= 1
			end
		end
	end
	return out
end

-- Forgets the finished runs among `ids` and queues their directories; active runs are kept.
-- Returns how many were dropped.
function M.drop(s: Store, ids: { string }): number
	local gone: { [string]: boolean } = {}
	for _, id in ids do
		local r = s.by_id[id]
		if r and M.TERMINAL[r.state] then
			gone[id] = true
		end
	end
	if next(gone) == nil then
		return 0
	end
	local kept: { Run } = {}
	local n = 0
	for _, r in s.runs do
		if gone[r.id] then
			n += 1
			s.by_id[r.id] = nil
			table.insert(s.trash, M.run_dir(s, r.id))
			table.insert(s.trash, M.worktree_dir(s, r.id))
		else
			table.insert(kept, r)
		end
	end
	s.runs = kept
	return n
end

-- Drops runs past the retention policy; their directories go to `trash`.
function M.prune(s: Store, now: number): number
	return M.drop(s, M.expired(s, now))
end

-- Every finished run, for "delete all finished runs".
function M.finished(s: Store): { string }
	local out: { string } = {}
	for _, r in s.runs do
		if M.TERMINAL[r.state] then
			table.insert(out, r.id)
		end
	end
	return out
end

local function list_dir(path: string): { string }
	local ok, names = pcall(tern.fs.list, path)
	return if ok and type(names) == "table" then names :: { string } else {}
end

-- A name Roost would have created under runs/ or worktrees/ (run ids, plus a little slack).
local function plain_name(name: string): boolean
	return string.match(name, "^[%w%-_%.]+$") ~= nil and name ~= "." and name ~= ".."
end

-- Top-level directories whose entries Roost may delete (one plain name below them).
local OWNED = { "runs", "worktrees", "workflows", "library", "state", "exports", "revisions" }

-- A path Roost may delete: exactly `<sub>/<name>` for a sub in OWNED, or a run's scratch
-- directory `runs/<name>/tmp`, under an absolute data dir.
local function owned(s: Store, path: string): boolean
	if string.sub(s.dir, 1, 1) ~= "/" or #s.dir < 2 then
		return false
	end
	for _, sub in OWNED do
		local base = `{s.dir}/{sub}/`
		if string.sub(path, 1, #base) == base then
			local rest = string.sub(path, #base + 1)
			local name, tail = string.match(rest, "^([^/]+)/(.*)$")
			if name and tail then
				return sub == "runs" and tail == "tmp" and plain_name(name)
			end
			return plain_name(rest)
		end
	end
	return false
end

local MAX_TRIES = 3

local function exists(path: string): boolean
	local ok, yes = pcall(tern.fs.exists, path)
	return ok and yes == true
end

-- Queues directories no run owns: `runs/<id>` the index doesn't know, `worktrees/<id>` of a run
-- that is unknown or over. At most `cap` per call; returns how many were queued.
function M.sweep(s: Store, cap: number): number
	if not s.indexed then
		return 0
	end
	local queued: { [string]: boolean } = {}
	for _, p in s.trash do
		queued[p] = true
	end
	local n = 0
	local function take(path: string)
		if n < cap and not queued[path] then
			queued[path] = true
			table.insert(s.trash, path)
			n += 1
		end
	end
	-- Entries with other names aren't Roost's: left alone (and not counted).
	for _, name in list_dir(`{s.dir}/runs`) do
		if plain_name(name) and s.by_id[name] == nil then
			take(M.run_dir(s, name))
		end
	end
	for _, name in list_dir(`{s.dir}/worktrees`) do
		local r = s.by_id[name]
		if plain_name(name) and (r == nil or M.TERMINAL[r.state]) then
			take(M.worktree_dir(s, name))
		end
	end
	-- A finished run's scratch directory (normally queued by the runner when the run ended).
	for _, r in s.runs do
		local tmp = `{M.run_dir(s, r.id)}/tmp`
		if M.TERMINAL[r.state] and plain_name(r.id) and exists(tmp) then
			take(tmp)
		end
	end
	return n
end

-- Queues a directory Roost owns (see `owned`) for `drain`; anything else is ignored.
function M.discard(s: Store, path: string)
	if owned(s, path) then
		for _, p in s.trash do
			if p == path then
				return
			end
		end
		table.insert(s.trash, path)
	end
end

-- Whether `path` (or a directory above it) is waiting to be deleted or being deleted. Creating
-- anything there now would be removed by the pending `rm`: callers wait or refuse.
function M.pending(s: Store, path: string): boolean
	local function covers(p: string): boolean
		return p == path or string.sub(path, 1, #p + 1) == p .. "/"
	end
	for p in s.inflight do
		if covers(p) then
			return true
		end
	end
	for _, p in s.trash do
		if covers(p) then
			return true
		end
	end
	return false
end

-- Requeues what is still there after a removal, up to MAX_TRIES attempts per path.
local function settle(s: Store, batch: { string })
	for _, p in batch do
		if exists(p) then
			local n = (s.tries[p] or 0) + 1
			if n < MAX_TRIES then
				s.tries[p] = n
				table.insert(s.trash, p)
			else
				s.tries[p] = nil
				tern.log.warn("roost: giving up removing", p)
			end
		else
			s.tries[p] = nil
		end
	end
end

-- Deletes up to `n` queued directories with one `rm -rf` (out of process: no call budget, and rm
-- never follows a symlink out of a worktree), then `done(left)` with how many are still queued.
function M.drain(s: Store, n: number, done: (number) -> ())
	local batch: { string } = {}
	while #batch < n and #s.trash > 0 do
		local path = table.remove(s.trash, 1) :: string
		if owned(s, path) and exists(path) then
			table.insert(batch, path)
		end
	end
	if #batch == 0 then
		done(#s.trash)
		return
	end
	local argv = { "/bin/rm", "-rf", "--" }
	table.move(batch, 1, #batch, #argv + 1, argv)
	for _, p in batch do
		s.inflight[p] = true
	end
	local function finished()
		for _, p in batch do
			s.inflight[p] = nil
		end
		-- Whatever is still there goes back in the queue (settle), however rm ended.
		settle(s, batch)
		done(#s.trash)
	end
	local ok, err = pcall(function(): string?
		tern.process.run(argv, { timeout_ms = 120000 }, function(res: ProcessResult)
			if res.timed_out or res.status ~= 0 then
				tern.log.warn("roost: rm failed", res.status, string.sub(res.stderr or "", 1, 500))
			end
			finished()
		end)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot start rm", err)
		finished()
	end
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
