--!strict
-- The local run engine. A run is a list of steps. A shell step is one child process started
-- through a small sh wrapper that puts the command in its own process group and records pids and
-- the exit code in files. An omp step is a native agent block that a window opens (see
-- lib/agent.luau): the host writes a job file and lists it in kv, the window records the pane and
-- the exit code. Either way progress is read from files, so a run survives a plugin reload: the
-- new VM finds the step still running (or finished) and carries on.
--
-- Concurrency: at most `max_concurrent` runs at once, one per workflow; per-workflow policy
-- queue | skip | replace. Every transition is saved to runs.json (a step start before its
-- process is spawned; other changes coalesced).

local model = require("./model")
local store = require("./store")
local template = require("./template")
local util = require("./util")
local match = require("./match")
local agent = require("./agent")
local stats = require("./stats")
local loginenv = require("./loginenv")
local files = require("./files")
local tabs = require("./tabs")
local upgrade = require("./upgrade")
local tasks = require("./tasks")
local reply = require("./reply")
local inbox = require("./inbox")

local M = {}

type Run = store.Run
type Workflow = model.Workflow

-- The wrapper: `sh -c WRAPPER roost LOG PIDFILE EXITFILE CWD PROG ARGS...`. `set -m` gives the
-- command its own process group, so cancel can signal everything it started. The wrapper's own
-- pid goes to PIDFILE.w so a later VM can tell whether anyone is left to write the exit file.
-- Anything but a regular file at $ROOST_OUTPUT or $ROOST_INBOX is removed before the exit file
-- appears, so the host's read of them can't block on a FIFO or device.
M.WRAPPER = [[
log=$1; pidf=$2; exitf=$3; cwd=$4; shift 4
echo "$$" >"$pidf.w"
[ -n "$ROOST_BANNER" ] && printf '%s\n' "$ROOST_BANNER" >>"$log"
cd "$cwd" 2>>"$log" || { echo "[roost] cannot enter $cwd" >>"$log"; echo 97 >"$exitf"; exit 97; }
set -m
"$@" </dev/null >>"$log" 2>&1 &
child=$!
echo "$child" >"$pidf"
wait "$child"
code=$?
for f in "$ROOST_OUTPUT" "$ROOST_INBOX"; do
	if [ -n "$f" ] && { [ -e "$f" ] || [ -L "$f" ]; } && { [ -L "$f" ] || [ ! -f "$f" ]; }; then
		rm -rf -- "$f"
		echo "[roost] $f is not a regular file: ignored" >>"$log"
	fi
done
echo "$code" >"$exitf.tmp" && mv "$exitf.tmp" "$exitf"
exit "$code"
]]

-- A follow-up starts at its parent's base commit (already in the repository; fetched when not)
-- with the parent's changes applied. Every worktree run records the commit it started at.
M.PREPARE_WORKTREE = [[
set -e
if [ -n "$ROOST_BASE_SHA" ]; then
	git -C "$ROOST_REPO_PATH" cat-file -e "$ROOST_BASE_SHA^{commit}" 2>/dev/null || git -C "$ROOST_REPO_PATH" fetch --quiet origin "$ROOST_BASE_SHA"
	git -C "$ROOST_REPO_PATH" worktree add --quiet --detach "$ROOST_WORKSPACE" "$ROOST_BASE_SHA"
else
	echo "[roost] fetch origin $ROOST_FETCH_REF in $ROOST_REPO_PATH"
	git -C "$ROOST_REPO_PATH" fetch --quiet origin "$ROOST_FETCH_REF"
	git -C "$ROOST_REPO_PATH" worktree add --quiet --detach "$ROOST_WORKSPACE" FETCH_HEAD
fi
git -C "$ROOST_WORKSPACE" rev-parse HEAD >"$ROOST_RUN_DIR/base.txt"
echo "[roost] worktree $ROOST_WORKSPACE at $(git -C "$ROOST_WORKSPACE" rev-parse --short HEAD)"
if [ -n "$ROOST_BASE_PATCH" ] && [ -s "$ROOST_BASE_PATCH" ]; then
	git -C "$ROOST_WORKSPACE" apply --index "$ROOST_BASE_PATCH"
	echo "[roost] 已应用上一次运行的改动"
fi
]]

-- Before the worktree goes: everything staged and diffed against the commit it started at
-- (lib/tasks.luau), the patch dropped past tasks.MAX_PATCH. `changes.numstat` keeps at most
-- tasks.MAX_FILES rows and tasks.MAX_NUMSTAT bytes; `changes.total` has "files add del" of the whole
-- diff. Both appear only after a complete capture. The worktree is removed whatever happened.
M.CLEANUP_WORKTREE = string.gsub(
	string.gsub(
		string.gsub(
			[[
d=$ROOST_RUN_DIR
if [ -d "$ROOST_WORKSPACE" ] && [ -s "$d/base.txt" ]; then
	base=$(cat "$d/base.txt")
	rm -f "$d/changes.patch" "$d/changes.numstat" "$d/changes.total" "$d/changes.too_big"
	if git -C "$ROOST_WORKSPACE" add -A >/dev/null 2>&1 &&
		git -C "$ROOST_WORKSPACE" diff --cached --numstat "$base" >"$d/changes.all.tmp" &&
		: >"$d/changes.numstat.tmp" &&
		LC_ALL=C awk -F '\t' -v rows="$d/changes.numstat.tmp" -v maxr=@MAX_FILES@ -v maxb=@MAX_NUMSTAT@ '
			{ f++; if ($1 != "-") a += $1; if ($2 != "-") x += $2
			  if (f <= maxr && n + length($0) + 1 <= maxb) { print > rows; n += length($0) + 1 } }
			END { printf "%d %d %d\n", f, a, x }' "$d/changes.all.tmp" >"$d/changes.total.tmp" &&
		git -C "$ROOST_WORKSPACE" diff --cached --binary "$base" >"$d/changes.patch.tmp"; then
		if [ "$(wc -c <"$d/changes.patch.tmp")" -gt @MAX_PATCH@ ]; then
			rm -f "$d/changes.patch.tmp"
			: >"$d/changes.too_big"
		elif [ -s "$d/changes.patch.tmp" ]; then
			mv -f "$d/changes.patch.tmp" "$d/changes.patch"
		else
			rm -f "$d/changes.patch.tmp"
		fi
		mv -f "$d/changes.numstat.tmp" "$d/changes.numstat"
		mv -f "$d/changes.total.tmp" "$d/changes.total"
		echo "[roost] 改动:$(cut -d ' ' -f 1 <"$d/changes.total") 个文件"
	else
		rm -f "$d/changes.patch.tmp" "$d/changes.numstat.tmp" "$d/changes.total.tmp"
		echo "[roost] 无法收集 worktree 的改动"
	fi
	rm -f "$d/changes.all.tmp"
fi
git -C "$ROOST_REPO_PATH" worktree remove --force "$ROOST_WORKSPACE" 2>/dev/null || rm -rf "$ROOST_WORKSPACE"
git -C "$ROOST_REPO_PATH" worktree prune
echo "[roost] worktree removed"
]],
			"@MAX_PATCH@",
			tostring(tasks.MAX_PATCH)
		),
		"@MAX_FILES@",
		tostring(tasks.MAX_FILES)
	),
	"@MAX_NUMSTAT@",
	tostring(tasks.MAX_NUMSTAT)
)

-- A run's environment (roost.toml [environments.<name>], runner.environment_of), before its other
-- steps: `sh -c ENV_SCRIPT roost NAME...` writes the named variables (already in this step's
-- environment) and the PATH prefix ($ROOST_ENV_PATH) to runs/<id>/environment.sh, owner-only, for
-- omp steps to source, then runs the environment's setup ($ROOST_ENV_SETUP) in the workspace with
-- the default umask. Names are validated identifiers.
M.ENV_SCRIPT = [[
f="$ROOST_RUN_DIR/environment.sh"
(umask 077 && : >"$f") || exit 1
for _roost_n in "$@"; do
	eval "_roost_v=\${$_roost_n-}"
	_roost_q=$(printf '%s' "$_roost_v" | sed "s/'/'\\\\''/g")
	printf "export %s='%s'\n" "$_roost_n" "$_roost_q" >>"$f" || exit 1
done
if [ -n "$ROOST_ENV_PATH" ]; then
	_roost_q=$(printf '%s' "$ROOST_ENV_PATH" | sed "s/'/'\\\\''/g")
	printf "export PATH='%s':\"\$PATH\"\n" "$_roost_q" >>"$f" || exit 1
fi
echo "[roost] 环境「${ROOST_ENV_NAME}」:$# 个变量"
if [ -n "$ROOST_ENV_SETUP" ]; then
	echo "[roost] 运行环境的 setup"
	/bin/sh -c "$ROOST_ENV_SETUP" || exit $?
fi
]]

-- A follow-up's first step (`resume`), before its worktree is prepared: `sh -c RESUME_SESSION roost
-- SRC DST NOTE TALLY MAX PSRC PDST`. Copies the parent's patch PSRC to PDST (prepare applies it),
-- and the parent step's session directory SRC into the new step's DST (lock files left behind),
-- then writes NOTE: the newest session file's name and size (logging starts past them) and what
-- the copy already cost (M.TALLY, subtracted from the step's own tally). Empty SRC/PSRC: none.
M.RESUME_SESSION = [[
src=$1; dst=$2; note=$3; tally=$4; max=$5; psrc=$6; pdst=$7
if [ -n "$psrc" ]; then
	if [ ! -f "$psrc" ]; then
		echo "[roost] 找不到上一次运行的改动($psrc),无法接续" >&2
		exit 1
	fi
	cp "$psrc" "$pdst" || exit 1
fi
if [ -n "$src" ]; then
	if [ ! -d "$src" ]; then
		echo "[roost] 找不到上一次运行的会话($src),无法接续" >&2
		exit 1
	fi
	mkdir -p "$dst" && cp -R "$src/." "$dst/" || exit 1
	find "$dst" -name '.*.lock*' -exec rm -f {} + 2>/dev/null
	f=$(ls "$dst"/*.jsonl 2>/dev/null | sort | tail -n 1)
	if [ -z "$f" ]; then
		echo "[roost] 上一次运行没有留下会话记录,无法接续" >&2
		exit 1
	fi
	{ basename "$f"; wc -c <"$f" | tr -d ' '; /bin/sh -c "$tally" roost "$dst" "$max"; } >"$note" 2>/dev/null || exit 1
fi
echo "[roost] 已接续上一次运行"
]]

local MAX_QUEUE = 100
-- Between SIGTERM and SIGKILL for a stopping step.
local KILL_GRACE = 8
-- After the wrapper ended (or was found dead), how long we wait for its exit file.
local EXIT_GRACE = 3
-- How often a step nobody in this VM is waiting on is probed for liveness.
local PROBE_EVERY = 5
-- Extra process.run timeout beyond our own deadline (a backstop; our deadline kills first).
local BACKSTOP_MS = 120000
local MAX_PAYLOAD = 8 * 1024 * 1024
local SAVE_DELAY_MS = 250
-- How long a window may hold an agent step's claim without recording a pane.
local CLAIM_GRACE = 30
-- How often a working agent's session file is read into the run log, and how much at a time.
local TAIL_EVERY = 2
local TAIL_CHUNK = 512 * 1024
-- How long the relay gets to hand out a run's App token, and when a held one is renewed
-- (installation tokens live an hour).
local AUTH_TIMEOUT = 90
local TOKEN_RENEW = 900
local RENEW_RETRY = 60
-- How long a tab operation may wait for a window to claim it, and how long a run-end close waits
-- for one at all.
local TAB_WAIT = 120
local TAB_END_TTL = 86400

-- What an agent step cost and which models it used: every *.jsonl under its session dir
-- (subagents are files one level down, named after the agent), summing each usage record's
-- `cost.total` and `totalTokens`, and listing each distinct (agent, role, provider/model) of its
-- assistant messages and side calls (`model_usage` records name their role, e.g. judge). Text
-- inside JSON strings has its quotes escaped, so the patterns only meet real records. The step's
-- own session files go first, so the cap never drops its turns. Prints "COST TOKENS", then one
-- "m<TAB>AGENT<TAB>ROLE<TAB>MODEL" line per use (AGENT empty for the step's own agent, ROLE empty
-- for its turns), at most MAX_USES of them.
M.TALLY = [[
p='"cost":\{[^}]*\}|"totalTokens":[0-9]+|("role":"[^"]*",)?"api":"[^"]*","provider":"[^"]*","model":"[^"]*"'
{ find "$1" -maxdepth 1 -type f -name '*.jsonl' -exec grep -oHE "$p" {} +
	find "$1" -mindepth 2 -type f -name '*.jsonl' -exec grep -oHE "$p" {} +; } 2>/dev/null |
	awk -v root="$1" -v max="$2" '
		{ i = index($0, ":\""); f = substr($0, 1, i - 1); m = substr($0, i + 1) }
		m ~ /^"totalTokens"/ { t += substr(m, 15); next }
		m ~ /^"cost"/ { if (match(m, /"total":[-0-9.eE+]+/)) c += substr(m, RSTART + 8, RLENGTH - 8); next }
		{
			role = ""
			if (m ~ /^"role"/) { role = substr(m, 9); role = substr(role, 1, index(role, "\"") - 1) }
			match(m, /"provider":"[^"]*"/); p = substr(m, RSTART + 12, RLENGTH - 13)
			match(m, /"model":"[^"]*"/); id = substr(m, RSTART + 9, RLENGTH - 10)
			who = ""
			if (index(substr(f, length(root) + 2), "/") > 0) { who = f; sub(/^.*\//, "", who); sub(/\.jsonl$/, "", who) }
			k = who "\t" role "\t" (p == "" ? id : p "/" id)
			if (!(k in seen) && n < max + 0) { seen[k] = 1; keys[++n] = k }
		}
		END { printf "%.6f %d\n", c, t; for (j = 1; j <= n; j++) print "m\t" keys[j] }'
]]
local MAX_USES = 32
local TALLY_TIMEOUT_MS = 20000
-- Most of $ROOST_OUTPUT read after a shell step, and most outputs a run keeps.
local MAX_OUTPUT_FILE = 64 * 1024
local MAX_OUTPUTS = 64
local MAX_OUTPUT_VALUE = 4096

-- `gh` for runs acting as the GitHub App, installed as <data>/bin/gh, which such runs put first on
-- PATH: reads the run's current token (renewed while the run lasts), then runs the next gh.
M.GH_SHIM = [[
#!/bin/sh
# Roost: gh as the GitHub App. Reads the run's current token, then runs the next gh on PATH.
if [ -n "$ROOST_GH_TOKEN_FILE" ]; then
	GH_TOKEN=$(cat "$ROOST_GH_TOKEN_FILE") || exit 4
	export GH_TOKEN
fi
self=$(dirname "$0")
set -f
IFS=:
for d in $PATH; do
	[ "$d" = "$self" ] && continue
	[ -x "$d/gh" ] && exec "$d/gh" "$@"
done
echo "roost: gh not found on PATH" >&2
exit 127
]]

-- `sh -c SAVE_TOKEN roost FILE SHIM SHIM_TEXT`, the token on stdin: owner-only, replaced whole.
-- The shim (shared by every App run) is replaced through a rename too, and only when it changed,
-- so a gh started meanwhile never runs a half-written script.
M.SAVE_TOKEN = [[
umask 077
cat >"$1.tmp" && mv "$1.tmp" "$1" || exit 1
mkdir -p "${2%/*}" || exit 1
if [ ! -x "$2" ] || [ "$(cat "$2" 2>/dev/null)" != "$(printf '%s' "$3")" ]; then
	printf '%s' "$3" >"$2.$$" && chmod 755 "$2.$$" && mv "$2.$$" "$2"
fi
]]

-- git's credential helper for github.com while acting as the App: the run's current token.
M.GIT_CREDENTIAL = '!f() { test "$1" = get || exit 0; echo username=x-access-token; echo "password=$(cat "$ROOST_GH_TOKEN_FILE")"; }; f'

export type Request = {
	trigger: { kind: string, detail: string, delivery: string? },
	repo: string?,
	ref: string?,
	inputs: { [string]: string },
	event: { [string]: any }?,
	payload: string?, -- raw JSON text of the webhook payload
	rerun_of: string?,
	-- An evolver started by a target's failure (lib/evolve.luau).
	evolve: { target: string, run: string }?,
	task: store.Task?, -- a built-in run (lib/tasks.luau); the workflow passed is tasks.workflow's
	-- A follow-up (store.Run fields of the same names): the run it continues, the commit its worktree
	-- starts at, the patch applied on it, and the session directory its omp step resumes.
	parent: string?,
	base: string?,
	patch: string?,
	resume: string?,
}

-- Copies the tails of run logs into an evolver's material: `sh -c EVOLVE_LOGS roost DST SRC ...`.
M.EVOLVE_LOGS = [[
n=0
while [ $# -ge 2 ]; do
	tail -c 49152 "$2" >"$1" 2>/dev/null && n=$((n + 1))
	shift 2
done
echo "[roost] 迭代材料已写入 $ROOST_RUN_DIR/evolve($n 份日志)"
]]

-- An installation token the relay handed out for one run (POST /api/v1/github/token).
export type AppToken = {
	token: string,
	expires_in: number,
	login: string,
	email: string,
	branch: string?,
	protection: string?,
	permissions: { [string]: any }?,
}

export type Env = {
	data: string,
	home: string?,
	path: string?, -- the daemon's PATH (used while no login environment is known)
	-- The login-shell environment (lib/loginenv.luau). Shell steps inherit it; nothing advances
	-- or starts while the first capture is pending.
	login: () -> loginenv.State,
	store: store.Store,
	config: () -> model.Config,
	workflows: () -> model.Workflows?,
	changed: () -> (),
	now: () -> number,
	-- Asks the relay for an App token for one repository (core.app_token).
	app_token: (repo: string, cb: (AppToken?, string?) -> ()) -> (),
	-- Roost's own checkout (tern.plugin.dir), which `upgrade` steps move forward.
	plugin_dir: string,
	-- Writes an evolver run's material (lib/evolve.luau prepare): log tails still to copy, as
	-- destination/source pairs, or why it couldn't.
	evolve_prepare: (run: store.Run, wf: model.Workflow) -> ({ string }, string?),
	-- Told once a run has finished (after its record is final), outside the runner's own call.
	finished: (run: store.Run) -> (),
	-- What a step wrote to $ROOST_INBOX (lib/inbox.luau), for core to apply; returns a line for the
	-- run's log when part or all of it couldn't be used.
	inbox: (run: store.Run, raw: string) -> string?,
}

-- Per-run state that isn't persisted.
type Live = {
	spawned: { [number]: boolean }, -- step index -> started by this VM (a callback will come)
	exited: { [number]: number }, -- step index -> when the wrapper was known to be gone
	killed: { [number]: string }, -- step index -> last signal sent
	kill_at: { [number]: number }, -- step index -> when SIGTERM went out
	probe_at: { [number]: number }, -- step index -> last liveness probe
	claim_at: { [number]: number }, -- step index -> when a claim without a pane was first seen
	exit_bad: { [number]: number }, -- step index -> when its exit file was first found unreadable
	tail_at: { [number]: number }, -- agent step -> last read of its session file
	tailing: { [number]: boolean }, -- agent step -> a read or its log append is in flight
	tail_done: { [number]: boolean }, -- agent step -> read to the end after its exit file appeared
	tally: { [number]: string }, -- agent step -> "running" | "done": its cost read from the session files
	peek_at: { [number]: number }, -- agent step -> when the models it uses may be read again
	peeking: { [number]: boolean }, -- agent step -> that read is in flight
	note: { [number]: string }, -- step index -> why it failed, for the run's reason (auth steps)
	renewing: boolean?, -- the run's App token is being renewed
	renew_at: number?, -- last renewal attempt
	renew_failed: boolean?, -- a renewal failure was logged (said once until one succeeds)
	settling: { [number]: boolean }, -- tab step -> its result is being logged before the exit file
	queued_at: { [number]: number }, -- tab step -> when its op was first seen unclaimed in this VM
}

-- A queued tab operation (lib/tabs.luau): a step's, or a run-end close (no step).
-- `claimed`: when a run-end close was first seen claimed with no answer.
type TabOp = { run: string, step: number?, created: number, claimed: number? }

export type Runner = {
	env: Env,
	live: { [string]: Live },
	seq: number,
	timer: any?,
	save_timer: any?,
	jobs_json: string?, -- what kv `agent_jobs` was last set to
	tab_ops: { [string]: TabOp },
	tabs_json: string?, -- what kv `tab_ops` was last set to
	filled: { [string]: boolean }, -- ended runs whose missing models were read (fill_models)
	filled_n: number,
}

local function now(r: Runner): number
	return r.env.now()
end

local function dir_of(r: Runner, id: string): string
	return store.run_dir(r.env.store, id)
end

local function token_path(r: Runner, id: string): string
	return `{dir_of(r, id)}/app-token`
end

local function bin_dir(r: Runner): string
	return `{r.env.data}/bin`
end

-- Lists the running agent steps for the windows (kv `agent_jobs`), when that list changed.
local function publish_jobs(r: Runner)
	local list: { agent.Active } = {}
	for _, run in r.env.store.runs do
		local s = if run.state == "running" then run.steps[run.step] else nil
		if s and s.agent and s.state == "running" then
			table.insert(list, { run = run.id, step = run.step, stop = run.stop ~= nil })
		end
	end
	local enc = tern.json.encode(tern.json.array(list))
	if enc ~= r.jobs_json then
		local ok, err = pcall(function(): string?
			tern.kv.set(agent.KV, list)
			return nil
		end)
		if ok then
			r.jobs_json = enc
		else
			tern.log.warn("roost: cannot publish agent jobs", err)
		end
	end
end

-- Lists the tab operations not yet done for the windows (kv `tab_ops`), when that list changed.
local function publish_tabs(r: Runner)
	local ids: { string } = {}
	for id in r.tab_ops do
		table.insert(ids, id)
	end
	table.sort(ids)
	local enc = tern.json.encode(tern.json.array(table.move(ids, 1, #ids, 1, {})))
	if enc ~= r.tabs_json then
		local ok, err = pcall(function(): string?
			tern.kv.set(tabs.KV, ids)
			return nil
		end)
		if ok then
			r.tabs_json = enc
		else
			tern.log.warn("roost: cannot publish tab operations", err)
		end
	end
end

-- Saves runs.json: at once when `now_` (before spawning a step), else coalesced.
local function persist(r: Runner, now_: boolean?)
	if now_ then
		if r.save_timer then
			r.save_timer:cancel()
			r.save_timer = nil
		end
		store.save(r.env.store)
	elseif not r.save_timer then
		r.save_timer = tern.timer(SAVE_DELAY_MS, function()
			r.save_timer = nil
			store.save(r.env.store)
		end)
	end
	publish_jobs(r)
	publish_tabs(r)
	r.env.changed()
end

-- Saves runs.json now (after the index changed outside a run, e.g. a cleanup).
function M.save(r: Runner)
	persist(r, true)
end

-- Appends `lines` (then the file at `tail`, when given) to a run's log; `done` runs once the
-- append finished (or could not start), so later appends keep their order.
local function append_log(r: Runner, id: string, lines: { string }, tail: string?, done: (() -> ())?)
	local argv = {
		"/bin/sh",
		"-c",
		'f=$1; t=$2; shift 2; printf "%s\\n" "$@" >>"$f"; if [ -n "$t" ] && [ -f "$t" ]; then cat "$t" >>"$f"; printf "\\n" >>"$f"; fi; exit 0',
		"roost",
		`{dir_of(r, id)}/log.txt`,
		tail or "",
	}
	for _, l in lines do
		table.insert(argv, l)
	end
	local ok, err = pcall(function(): string?
		tern.process.run(argv, { timeout_ms = 5000 }, function(_res)
			if done then
				done()
			end
		end)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot append to log", err)
		if done then
			done()
		end
	end
end

-- Appends `lines` to run `id`'s log (core: what applying an evolver's changes did).
function M.log(r: Runner, id: string, lines: { string })
	if r.env.store.by_id[id] then
		append_log(r, id, lines)
	end
end

-- Reads up to `limit` bytes of `path` from `offset` (0-based) without loading the whole file;
-- nil when the read failed.
local function read_chunk(path: string, offset: number, limit: number, cb: (string?) -> ())
	local ok, err = pcall(function(): string?
		tern.process.run({
			"/bin/sh",
			"-c",
			'tail -c +"$1" "$2" | head -c "$3"',
			"roost",
			tostring(math.floor(offset) + 1),
			path,
			tostring(math.floor(limit)),
		}, { timeout_ms = 10000 }, function(res)
			if res.status ~= 0 or res.timed_out then
				cb(nil)
			else
				cb(res.stdout)
			end
		end)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot read", path, err)
		cb(nil)
	end
end

local function live(r: Runner, id: string): Live
	local l = r.live[id]
	if not l then
		l = {
			spawned = {},
			exited = {},
			killed = {},
			kill_at = {},
			probe_at = {},
			claim_at = {},
			exit_bad = {},
			tail_at = {},
			tailing = {},
			tail_done = {},
			tally = {},
			peek_at = {},
			peeking = {},
			note = {},
			settling = {},
			queued_at = {},
		}
		r.live[id] = l
	end
	return l
end

function M.new(env: Env): Runner
	return {
		env = env,
		live = {},
		seq = 0,
		timer = nil,
		save_timer = nil,
		jobs_json = nil,
		tab_ops = {},
		tabs_json = nil,
		filled = {},
		filled_n = 0,
	}
end

local function new_id(r: Runner): string
	while true do
		r.seq = (r.seq + 1) % 0x10000
		local id = string.format("%010x%04x", math.floor(now(r)), (r.seq + math.random(0, 0xfff)) % 0x10000)
		if r.env.store.by_id[id] == nil then
			return id
		end
	end
end

local function busy(r: Runner, workflow: string): { Run }
	local out = {}
	for _, run in r.env.store.runs do
		if run.workflow == workflow and (run.state == "queued" or run.state == "running") then
			table.insert(out, run)
		end
	end
	return out
end

local function count(r: Runner, state: string): number
	local n = 0
	for _, run in r.env.store.runs do
		if run.state == state then
			n += 1
		end
	end
	return n
end

function M.active(r: Runner): (number, number)
	return count(r, "running"), count(r, "queued")
end

-- The run's workflow: the current definition (built-in runs: rebuilt from the run record), a
-- stand-in when it was deleted (so cleanup can still run), or nil when no valid workflows.toml has
-- loaded yet (hold everything).
local function resolve(r: Runner, run: Run): (Workflow?, boolean)
	if run.task then
		return tasks.workflow(run.workflow, run.task, run.repo), false
	end
	local wfs = r.env.workflows()
	if wfs == nil then
		return nil, false
	end
	local wf = wfs.by_id[run.workflow]
	if wf then
		return wf, false
	end
	local stub: Workflow = {
		id = run.workflow,
		name = run.workflow_name,
		enabled = false,
		manual = false,
		notify = false,
		reply = false,
		concurrency = "queue",
		workspace = "temp",
		env = {},
		inputs = {},
		triggers = {},
		steps = {},
		libs = {},
		state = run.workflow,
	}
	return stub, true
end

-- Where the run works: worktree (event ref in a temporary git worktree), repo (the checkout as
-- is), or temp (an empty directory).
local function workspace(r: Runner, wf: Workflow, req: Request, id: string): (string, string?, string?, string?)
	local wfs = r.env.workflows()
	local repo = if req.repo and wfs then wfs.repos[req.repo] else nil
	local path = if repo and repo.path then util.expand(repo.path, r.env.home) else nil
	local mode = wf.workspace
	if mode == "auto" then
		mode = if path and repo and repo.worktree then "worktree" elseif path then "repo" else "temp"
	end
	if (mode == "worktree" or mode == "repo") and not path then
		mode = "temp"
	end
	if mode == "worktree" then
		local ref = req.ref or (repo and repo.branch) or "HEAD"
		return "worktree", store.worktree_dir(r.env.store, id), path, ref
	elseif mode == "repo" then
		return "repo", path :: string, path, nil
	end
	return "temp", `{dir_of(r, id)}/work`, nil, nil
end

local function title_for(wf: Workflow, req: Request): string
	if req.task then
		local t = tasks.title(req.task.prompt)
		return if req.task.kind == "pr" then `开 PR:{t}` elseif req.parent then `追问:{t}` else t
	elseif req.event then
		return match.summary(req.event)
	elseif req.trigger.kind == "cron" then
		return `定时 {req.trigger.detail}`
	elseif req.trigger.kind == "roost" then
		return `迭代 {req.trigger.detail}`
	end
	return `{if req.trigger.kind == "rerun" then "重跑" else "手动"} {wf.name}`
end

-- The event without its long text fields; those stay in the run's info.json.
local function slim(e: { [string]: any }?): { [string]: any }?
	if e == nil then
		return nil
	end
	local out = table.clone(e)
	out.body = nil
	out.comment = nil
	out.request = nil
	return out
end

local function full_event(r: Runner, run: Run): { [string]: any }
	local ok, text = pcall(tern.fs.read, `{dir_of(r, run.id)}/info.json`, 1024 * 1024)
	if ok then
		local ok2, v = pcall(tern.json.decode, text :: string)
		if ok2 and type(v) == "table" then
			return v
		end
	end
	return run.event or {}
end

-- Queues a run of `wf` (or records it skipped, per the workflow's concurrency).
function M.submit(r: Runner, wf: Workflow, req: Request): (Run?, string?)
	if count(r, "queued") >= MAX_QUEUE then
		return nil, "队列已满"
	end
	local id = new_id(r)
	local mode, cwd, repo_path, fetch_ref = workspace(r, wf, req, id)
	local identity = wf.identity or r.env.config().github.identity
	local as_app = identity == "app" and req.repo ~= nil
	local steps: { store.StepRec } = {}
	if as_app then
		table.insert(steps, { name = "获取 App 令牌", kind = "auth", state = "pending" })
	end
	if req.resume or req.patch then
		table.insert(steps, { name = "接续上一次运行", kind = "resume", state = "pending" })
	end
	if mode == "worktree" then
		table.insert(steps, { name = "准备 worktree", kind = "prepare", state = "pending" })
	end
	if wf.evolve then
		table.insert(steps, { name = "准备迭代材料", kind = "evolve", state = "pending" })
	end
	-- The roost.toml environment it names: variables for omp steps, then its setup.
	if wf.environment then
		table.insert(steps, { name = "准备环境", kind = "env", state = "pending" })
	end
	-- Answering on the issue/PR that started the run (lib/reply.luau).
	local replying = wf.reply and req.repo ~= nil and req.event ~= nil and tonumber(req.event.number) ~= nil
	if replying then
		table.insert(steps, { name = "回复:已收到", kind = "ack", state = "pending" })
	end
	for _, s in wf.steps do
		local kind = s.kind :: string
		table.insert(steps, { name = s.name, kind = kind, state = "pending", model = if kind == "omp" then s.model else nil })
	end
	if replying then
		table.insert(steps, { name = "回复:结果", kind = "report", state = "pending" })
	end
	if mode == "worktree" then
		table.insert(steps, { name = "清理 worktree", kind = "cleanup", state = "pending" })
	end
	local run: Run = {
		id = id,
		workflow = wf.id,
		workflow_name = wf.name,
		title = title_for(wf, req),
		trigger = req.trigger,
		repo = req.repo,
		ref = req.ref,
		state = "queued",
		created_at = now(r),
		inputs = req.inputs,
		steps = steps,
		step = 0,
		workspace = mode,
		cwd = cwd,
		repo_path = repo_path,
		fetch_ref = fetch_ref,
		event = slim(req.event),
		rerun_of = req.rerun_of,
		identity = if as_app then "app" else nil,
		evolve_target = if req.evolve then req.evolve.target else nil,
		evolve_run = if req.evolve then req.evolve.run else nil,
		task = req.task,
		parent = req.parent,
		base = req.base,
		patch = req.patch,
		resume = req.resume,
	}
	local others = busy(r, wf.id)
	if #others > 0 and wf.concurrency == "skip" then
		run.state = "skipped"
		run.reason = "已有同一工作流的运行在排队或执行"
		run.finished_at = now(r)
	elseif #others > 0 and wf.concurrency == "replace" then
		for _, o in others do
			M.cancel(r, o.id, `被运行 {id} 取代`)
		end
	end
	store.add(r.env.store, run)
	do
		local d = dir_of(r, id)
		pcall(tern.fs.mkdir, d)
		if req.payload then
			pcall(tern.fs.write, `{d}/event.json`, req.payload)
		end
		if req.event then
			pcall(tern.fs.write, `{d}/info.json`, tern.json.encode(req.event))
		end
		if identity == "app" and not as_app and run.state ~= "skipped" then
			append_log(r, id, { "[roost] 这次运行没有关联仓库,GitHub 操作使用本机 gh 身份" })
		end
	end
	store.prune(r.env.store, now(r))
	-- Saved at once: the relay cursor moves past this event as soon as we return.
	persist(r, true)
	M.pump(r)
	return run, nil
end

-- The request a run was made from, for re-running it.
function M.request_of(r: Runner, run: Run): Request
	local payload: string? = nil
	local ok, text = pcall(tern.fs.read, `{dir_of(r, run.id)}/event.json`, MAX_PAYLOAD)
	if ok then
		payload = text
	end
	return {
		trigger = { kind = "rerun", detail = run.id },
		repo = run.repo,
		ref = run.ref,
		inputs = table.clone(run.inputs),
		event = if run.event then full_event(r, run) else nil,
		payload = payload,
		rerun_of = run.id,
		evolve = if run.evolve_target and run.evolve_run then { target = run.evolve_target, run = run.evolve_run } else nil,
		task = run.task,
		parent = run.parent,
		base = run.base,
		patch = run.patch,
		resume = run.resume,
	}
end

local function finish(r: Runner, run: Run, state: string, reason: string?)
	run.state = state
	run.reason = reason
	run.finished_at = now(r)
	run.stop = nil
	run.final = nil
	for _, s in run.steps do
		if s.state == "pending" or s.state == "running" then
			s.state = "skipped"
		end
	end
	if run.workspace == "temp" and run.cwd then
		pcall(tern.fs.remove, run.cwd)
	end
	if run.identity == "app" then
		pcall(tern.fs.remove, token_path(r, run.id))
	end
	-- Scratch ($ROOST_TMP) goes out of process; the run's file copies stay with its directory.
	store.discard(r.env.store, `{dir_of(r, run.id)}/tmp`)
	-- The environment's values for omp steps (environment.sh) go with the run's end.
	pcall(tern.fs.remove, `{dir_of(r, run.id)}/environment.sh`)
	-- Tabs this run opened for itself (`keep` off) close now, unless a later run took the key over.
	-- Any open step that got as far as queuing its operation: a failed or lost one may still have
	-- opened its tab, and `only_run` keeps a tab another run took over.
	for i, s in run.steps do
		if s.kind == "tab" and s.tab_op and s.tab_keep == false and s.tab_key then
			local id = tabs.end_id(run.id, i)
			local err = tabs.write_op(r.env.data, {
				id = id,
				action = "close",
				workflow = run.workflow,
				key = s.tab_key :: string,
				run = run.id,
				only_run = true,
				session = r.env.config().runner.session,
				created = now(r),
			})
			if err then
				tern.log.warn("roost: cannot queue tab close", err)
			else
				r.tab_ops[id] = { run = run.id, created = now(r) }
			end
		end
	end
	r.live[run.id] = nil
	local ok, err = pcall(function(): string?
		r.env.finished(run)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: finished hook failed", err)
	end
end

local function read_pid(path: string): number?
	local ok, text = pcall(tern.fs.read, path, 64)
	local n = if ok then tonumber(util.trim(text :: string)) else nil
	return if n then math.floor(n) else nil
end

-- Signals the process group of `run`'s current step.
local function signal(r: Runner, run: Run, sig: string)
	local l = live(r, run.id)
	l.killed[run.step] = sig
	if sig == "TERM" then
		l.kill_at[run.step] = now(r)
	end
	local n = read_pid(`{dir_of(r, run.id)}/s{run.step}.pid`)
	if not n then
		return
	end
	local ok, err = pcall(function(): string?
		tern.process.run({
			"/bin/sh",
			"-c",
			'kill -s "$1" -- "-$2" 2>/dev/null; kill -s "$1" "$2" 2>/dev/null; exit 0',
			"roost",
			sig,
			tostring(n),
		}, { timeout_ms = 5000 }, function(_res) end)
		return nil
	end)
	if not ok then
		-- Retried on a later check.
		l.killed[run.step] = nil
		tern.log.warn("roost: cannot signal step", err)
	end
end

-- Cancels a queued or running run. Returns false when it isn't active.
function M.cancel(r: Runner, id: string, reason: string?): boolean
	local run = r.env.store.by_id[id]
	if not run then
		return false
	end
	if run.state == "queued" then
		finish(r, run, "cancelled", reason or "开始前被取消")
		persist(r, true)
		return true
	end
	local cur = run.steps[run.step]
	-- Past the user's steps (cleanup, the reply on how it ended) there is nothing left to cancel.
	if run.state ~= "running" or run.stop or run.final or (cur and (cur.kind == "cleanup" or cur.kind == "report")) then
		return false
	end
	run.stop = "cancel"
	run.reason = reason or "已取消"
	if cur and not cur.agent and cur.state == "running" then
		signal(r, run, "TERM")
	end
	persist(r, true)
	M.schedule(r, 200)
	return true
end

local function uses_payload(t: template.Template): boolean
	for _, p in t.parts do
		if p.path and p.path[1] == "payload" then
			return true
		end
	end
	return false
end

local function template_ctx(r: Runner, run: Run, wf: Workflow, needs_payload: boolean): { [string]: any }
	local e = full_event(r, run)
	local payload: any = {}
	if needs_payload then
		local ok, text = pcall(tern.fs.read, `{dir_of(r, run.id)}/event.json`, MAX_PAYLOAD)
		if ok then
			local ok2, v = pcall(tern.json.decode, text :: string)
			if ok2 and type(v) == "table" then
				payload = v
			end
		end
	end
	return {
		repo = run.repo,
		event = e.event,
		action = e.action,
		number = e.number,
		title = e.title,
		body = e.body,
		url = e.url,
		ref = run.ref or run.fetch_ref,
		sha = e.sha,
		branch = e.branch,
		sender = e.sender,
		comment = e.comment,
		request = e.request,
		label = e.label,
		workflow = wf.id,
		run_id = run.id,
		tmp = `{dir_of(r, run.id)}/tmp`,
		trigger = run.trigger.kind,
		input = run.inputs,
		out = run.outputs or {},
		payload = payload,
		evolve_dir = if wf.evolve then `{dir_of(r, run.id)}/evolve` else nil,
		evolve_target = run.evolve_target,
		evolve_run = run.evolve_run,
	}
end

-- GitHub tokens a login shell may export: they would act as you in a run acting as the App.
local GITHUB_TOKENS = { "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN" }

-- The roost.toml environment `wf` names, or why it can't be had.
local function environment_of(r: Runner, wf: Workflow): (model.Environment?, string?)
	local name = wf.environment
	if name == nil then
		return nil, nil
	end
	local e = r.env.config().environments[name]
	if e == nil then
		return nil, `roost.toml 中没有环境「{name}」([environments.{name}])`
	end
	return e, nil
end

-- `app`: the step acts as the App, so the login shell's GitHub tokens are left out (tokens you set
-- in `[runner] env`, the environment or workflow `env` stay).
local function step_env(r: Runner, run: Run, wf: Workflow, app: boolean): { [string]: string }
	local cfg = r.env.config().runner
	local profile = environment_of(r, wf)
	local paths = {}
	local extra: { string } = if profile then profile.path else {}
	for _, p in extra do
		table.insert(paths, util.expand(p, r.env.home))
	end
	for _, p in cfg.extra_path do
		table.insert(paths, util.expand(p, r.env.home))
	end
	local drop = if app then GITHUB_TOKENS else nil
	local env = loginenv.compose(r.env.login(), { cfg.env, if profile then profile.vars else {}, wf.env }, paths, r.env.path, drop)
	local e: { [string]: any } = run.event or {}
	local function put(k: string, v: any)
		env[k] = if v == nil then "" else tostring(v)
	end
	put("ROOST_RUN_ID", run.id)
	put("ROOST_WORKFLOW", wf.id)
	put("ROOST_TRIGGER", run.trigger.kind)
	put("ROOST_REPO", run.repo)
	put("ROOST_REF", run.ref or run.fetch_ref)
	put("ROOST_FETCH_REF", run.fetch_ref)
	put("ROOST_REPO_PATH", run.repo_path)
	put("ROOST_WORKSPACE", run.cwd)
	put("ROOST_RUN_DIR", dir_of(r, run.id))
	-- A follow-up's worktree: the parent's start, and the copy of its patch the resume step made.
	put("ROOST_BASE_SHA", run.base)
	put("ROOST_BASE_PATCH", if run.patch then `{dir_of(r, run.id)}/parent.patch` else nil)
	-- Copies taken when the run started (lib/files.luau), the state kept across runs, and scratch.
	put("ROOST_FILES", `{dir_of(r, run.id)}/files`)
	put("ROOST_LIB", `{dir_of(r, run.id)}/lib`)
	put("ROOST_STATE", files.state_dir(r.env.data, wf.state))
	put("ROOST_TMP", `{dir_of(r, run.id)}/tmp`)
	put("PYTHONPYCACHEPREFIX", `{dir_of(r, run.id)}/tmp/pycache`)
	put("ROOST_EVENT_PATH", `{dir_of(r, run.id)}/event.json`)
	put("ROOST_INFO_PATH", `{dir_of(r, run.id)}/info.json`)
	put("ROOST_EVENT", e.event)
	put("ROOST_ACTION", e.action)
	put("ROOST_NUMBER", e.number)
	put("ROOST_SHA", e.sha)
	put("ROOST_BRANCH", e.branch)
	put("ROOST_SENDER", e.sender)
	put("ROOST_URL", e.url)
	for k, v in run.inputs do
		env["ROOST_INPUT_" .. string.upper((string.gsub(k, "[^%w]", "_")))] = v
	end
	for k, v in run.outputs or ({} :: { [string]: string }) do
		env["ROOST_OUT_" .. string.upper(k)] = v
	end
	return env
end

-- What a step acting as the App runs with besides PATH and GH_TOKEN: the token file, git's
-- credentials for github.com (ssh remotes go over https) and the bot as commit author.
local function app_vars(r: Runner, run: Run): { [string]: string }
	local a = run.app :: { login: string, email: string, expires: number }
	local v: { [string]: string } = {
		ROOST_IDENTITY = "app",
		ROOST_GH_TOKEN_FILE = token_path(r, run.id),
		GIT_TERMINAL_PROMPT = "0",
		GIT_AUTHOR_NAME = a.login,
		GIT_AUTHOR_EMAIL = a.email,
		GIT_COMMITTER_NAME = a.login,
		GIT_COMMITTER_EMAIL = a.email,
	}
	local git = {
		-- The empty helper first drops the user's own (osxkeychain, gh) for github.com.
		{ "credential.https://github.com.helper", "" },
		{ "credential.https://github.com.helper", M.GIT_CREDENTIAL },
		{ "url.https://github.com/.insteadOf", "git@github.com:" },
		{ "url.https://github.com/.insteadOf", "ssh://git@github.com/" },
	}
	v.GIT_CONFIG_COUNT = tostring(#git)
	for i, kv in git do
		v[`GIT_CONFIG_KEY_{i - 1}`] = kv[1]
		v[`GIT_CONFIG_VALUE_{i - 1}`] = kv[2]
	end
	return v
end

-- Adds the App identity to a shell step's environment.
local function with_app(r: Runner, run: Run, env: { [string]: string })
	for k, v in app_vars(r, run) do
		env[k] = v
	end
	env.PATH = if env.PATH and env.PATH ~= "" then `{bin_dir(r)}:{env.PATH}` else bin_dir(r)
	local ok, tok = pcall(tern.fs.read, token_path(r, run.id), 8192)
	if ok then
		env.GH_TOKEN = util.trim(tok :: string)
	end
end

-- The file an omp step acting as the App sources (agent.with_env); the token stays in its own file.
local function app_script(r: Runner, run: Run): string
	local v = app_vars(r, run)
	local lines = { "# Roost: this step's GitHub App identity (the token itself stays in ROOST_GH_TOKEN_FILE)." }
	for _, k in util.keys(v) do
		table.insert(lines, `export {k}={util.shq(v[k])}`)
	end
	table.insert(lines, `export PATH={util.shq(bin_dir(r))}:"$PATH"`)
	-- No token, no start: an inherited GH_TOKEN would otherwise act as someone else; the other
	-- GitHub tokens of Tern's login environment go too.
	table.insert(lines, "unset GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN")
	table.insert(lines, 'GH_TOKEN=$(cat "$ROOST_GH_TOKEN_FILE") || exit 97')
	table.insert(lines, "export GH_TOKEN")
	return table.concat(lines, "\n") .. "\n"
end

-- A run meant to act as the App whose identity or token is gone (a reload at the wrong moment, a
-- deleted file): its steps must fail rather than run as you.
local function app_missing(r: Runner, run: Run): boolean
	return run.identity == "app" and (run.app == nil or not tern.fs.exists(token_path(r, run.id)))
end

-- Asks the relay for an App token for `repo`; `cb` gets it or why not.
local function request_token(r: Runner, repo: string, cb: (AppToken?, string?) -> ())
	local ok, err = pcall(function(): string?
		r.env.app_token(repo, cb)
		return nil
	end)
	if not ok then
		cb(nil, tostring(err))
	end
end

-- Saves run `id`'s token (owner-only) and the gh shim; `cb` gets nil or what went wrong.
local function save_token(r: Runner, id: string, token: string, cb: (string?) -> ())
	local bin = bin_dir(r)
	local ok, err = pcall(function(): string?
		tern.process.run(
			{ "/bin/sh", "-c", M.SAVE_TOKEN, "roost", token_path(r, id), `{bin}/gh`, M.GH_SHIM },
			{ stdin = token, timeout_ms = 10000 },
			function(res)
				if res.status == 0 and not res.timed_out then
					cb(nil)
				else
					cb(`无法保存 App 令牌:{util.trim(res.stderr or "")}`)
				end
			end
		)
		return nil
	end)
	if not ok then
		cb(`无法保存 App 令牌:{err}`)
	end
end

local function token_lines(run: Run, tok: AppToken): { string }
	local perms: { string } = {}
	local p = tok.permissions or {}
	for _, k in util.keys(p) do
		table.insert(perms, `{k}:{tostring(p[k])}`)
	end
	local guard = if tok.protection == "created"
		then "中继刚为它加上了规则集"
		elseif tok.protection == "updated" then "中继重新启用了它的规则集"
		else "已有规则"
	return {
		`[roost] 以 GitHub App {tok.login} 的身份操作 {run.repo or "?"},令牌 {util.fmt_duration(tok.expires_in)} 后到期,运行期间自动续期`,
		`[roost] 默认分支 {tok.branch or "?"} 禁止强推与删除({guard})`,
		`[roost] 令牌权限:{if #perms > 0 then table.concat(perms, " ") else "—"}`,
	}
end

-- Renews a running App run's token shortly before it expires; failures are logged and retried.
local function renew(r: Runner, run: Run)
	local a = run.app
	local repo = run.repo
	if a == nil or repo == nil or now(r) < a.expires - TOKEN_RENEW then
		return
	end
	local l = live(r, run.id)
	if l.renewing or now(r) - (l.renew_at or -math.huge) < RENEW_RETRY then
		return
	end
	l.renewing, l.renew_at = true, now(r)
	local id = run.id
	local function still(): Run?
		local cur = r.env.store.by_id[id]
		return if cur and cur.state == "running" then cur else nil
	end
	request_token(r, repo, function(tok, err)
		if still() == nil then
			l.renewing = nil
			return
		end
		if tok == nil then
			l.renewing = nil
			-- Said once; retried every RENEW_RETRY until it works or the token runs out.
			if not l.renew_failed then
				l.renew_failed = true
				append_log(r, id, { `[roost] App 令牌续期失败,稍后重试:{err or "?"}` })
			end
			return
		end
		save_token(r, id, tok.token, function(serr)
			l.renewing = nil
			local cur = still()
			if cur == nil then
				pcall(tern.fs.remove, token_path(r, id))
				return
			end
			if serr then
				if not l.renew_failed then
					l.renew_failed = true
					append_log(r, id, { `[roost] App 令牌续期失败,稍后重试:{serr}` })
				end
				return
			end
			l.renew_failed = nil
			if cur.app then
				cur.app.expires = now(r) + tok.expires_in
			end
			persist(r)
			append_log(r, id, { `[roost] App 令牌已续期,{util.fmt_duration(tok.expires_in)} 后到期` })
		end)
	end)
end

local check: (Runner, Run) -> ()
local next_step: (Runner, Run, Workflow) -> ()

-- The definition of user step `i` (auth/resume/prepare/evolve/cleanup have none), matched by name and kind.
local function definition(run: Run, wf: Workflow, i: number): model.Step?
	local offset = 0
	local function internal(s: store.StepRec?): boolean
		return s ~= nil
			and (s.kind == "auth" or s.kind == "resume" or s.kind == "prepare" or s.kind == "evolve" or s.kind == "env" or s.kind == "ack")
	end
	while internal(run.steps[offset + 1]) do
		offset += 1
	end
	local def = wf.steps[i - offset]
	if def and def.name == run.steps[i].name and def.kind == run.steps[i].kind then
		return def
	end
	return nil
end

-- What a follow-up's resume step left for step `i` (M.RESUME_SESSION): the copied conversation's
-- newest session file and its size, and what the copy already cost.
type Resumed = { file: string, size: number, cost: number?, tokens: number? }
local function read_resumed(d: string, i: number): Resumed?
	local ok, text = pcall(tern.fs.read, `{d}/s{i}.resume`, 16 * 1024)
	if not ok then
		return nil
	end
	local name, size, rest = string.match(text :: string, "^([^\n]+)\n(%d+)\n?(.*)$")
	if not name or not size or not string.match(name, "^[^/]+%.jsonl$") then
		return nil
	end
	local c, t = M.parse_tally(rest or "")
	return { file = name, size = tonumber(size) :: number, cost = c, tokens = t }
end

-- The final answer of the run's last omp step that gave one (the session file's, else the
-- window's copy), at most reply.MAX_ANSWER bytes and a little: for the reply comment.
local function last_answer(r: Runner, run: Run): string?
	local d = dir_of(r, run.id)
	for i = #run.steps, 1, -1 do
		local s = run.steps[i]
		if s.kind == "omp" and s.agent then
			local f = agent.files(d, i)
			for _, p in { f.answer, f.reply } do
				local ok, text = pcall(tern.fs.read, p, agent.MAX_REPLY)
				if ok and util.trim(text :: string) ~= "" then
					return text :: string
				end
			end
		end
	end
	return nil
end

-- The first omp step of a run: the one a follow-up's conversation continues in.
local function first_omp(run: Run): number?
	for i, s in run.steps do
		if s.kind == "omp" then
			return i
		end
	end
	return nil
end

-- Hands an omp step to the windows: the job file first, then kv `agent_jobs` (through persist).
-- `from`: the conversation it resumes, whose earlier entries are not logged again.
local function start_agent(r: Runner, run: Run, i: number, job: agent.Job, from: Resumed?)
	local f = agent.files(dir_of(r, run.id), i)
	for _, p in { f.claim, f.pane, f.reply, f.answer, f.job } do
		pcall(tern.fs.remove, p)
	end
	pcall(tern.fs.mkdir, f.session)
	run.steps[i].agent = true
	run.steps[i].opened, run.steps[i].tail_file, run.steps[i].tail, run.steps[i].replied = nil, nil, nil, nil
	if from then
		run.steps[i].tail_file, run.steps[i].tail = from.file, from.size
	end
	local ok, err = pcall(function(): string?
		tern.fs.write(f.job, tern.json.encode(job))
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot write agent job", err)
		pcall(tern.fs.write, f.exit, tostring(agent.CODE.launch))
	end
	persist(r, true)
	append_log(r, run.id, {
		`\27[1;36m▶ {run.steps[i].name}\27[0m`,
		`[roost] 等待 Tern 窗口在会话「{job.session}」中打开 agent 标签页`,
	})
	M.schedule(r, 1000)
end

-- Logs what the agent did since the last look: "the tab is open" once, then each new entry of
-- its session file (agent.progress). One read and its append at a time, so lines keep their
-- order. `final` (the exit file is there) reads to the end, then checks the run again, so the
-- outcome line comes after the agent's last words.
local tail_agent: (Runner, Run, number, boolean) -> ()
function tail_agent(r: Runner, run: Run, i: number, final: boolean)
	local l = live(r, run.id)
	if l.tailing[i] then
		return
	end
	local t = now(r)
	if not final and t - (l.tail_at[i] or -math.huge) < TAIL_EVERY then
		return
	end
	l.tail_at[i] = t
	local s = run.steps[i]
	local id = run.id
	local f = agent.files(dir_of(r, id), i)
	local function done()
		l.tailing[i] = nil
		if final then
			l.tail_done[i] = true
			local cur = r.env.store.by_id[id]
			if cur and cur.state == "running" and cur.step == i then
				check(r, cur)
			end
		end
	end
	local head: { string } = {}
	if not s.opened and tern.fs.exists(f.pane) then
		s.opened = true
		table.insert(head, `[roost] agent 已在 Tern 标签页中运行(会话「{r.env.config().runner.session}」)`)
	end
	local file = agent.session_file(f.session)
	l.tailing[i] = true
	if not file then
		if #head > 0 then
			persist(r)
			append_log(r, id, head, nil, done)
		else
			done()
		end
		return
	end
	local name = string.match(file, "([^/]+)$")
	if s.tail_file ~= name then
		s.tail_file, s.tail = name, 0
	end
	read_chunk(file, s.tail or 0, TAIL_CHUNK, function(chunk)
		local cur = r.env.store.by_id[id]
		if not cur or cur.state ~= "running" or cur.step ~= i or chunk == nil then
			if #head > 0 then
				-- Not logged: say it with the next read.
				s.opened = nil
			end
			done()
			return
		end
		local text = chunk :: string
		local full = #text >= TAIL_CHUNK
		local p = agent.progress(text, full)
		s.tail = (s.tail or 0) + p.used
		if p.final then
			s.replied = true
			pcall(tern.fs.write, f.answer, string.sub(p.final, 1, agent.MAX_REPLY))
		end
		for _, line in p.lines do
			table.insert(head, line)
		end
		if p.used > 0 or #head > 0 then
			persist(r)
		end
		local more = full and p.used > 0
		local function after()
			if final and more then
				l.tailing[i] = nil
				tail_agent(r, cur, i, true)
			else
				done()
			end
		end
		if #head > 0 then
			append_log(r, id, head, nil, after)
		else
			after()
		end
	end)
end

-- M.TALLY's answer: what the step cost, its tokens and the models it used (cost nil when the
-- answer isn't one).
function M.parse_tally(text: string): (number?, number?, { store.ModelUse })
	local c, t = string.match(text, "^%s*([%d%.]+)%s+(%d+)")
	local uses: { store.ModelUse } = {}
	for line in string.gmatch(text, "[^\n]+") do
		local who, role, m = string.match(line, "^m\t([^\t]*)\t([^\t]*)\t([^\t]+)$")
		if who and role and m and #uses < MAX_USES then
			table.insert(uses, {
				model = util.clip(m, 120),
				agent = if who ~= "" then util.clip(who, 64) else nil,
				role = if role ~= "" then util.clip(role, 32) else nil,
			})
		end
	end
	return tonumber(c), tonumber(t), uses
end

-- Runs M.TALLY over step `i`'s session dir; `done` hears its answer (cost nil when the read
-- failed). False when the read couldn't start (`done` is never called then).
local function read_usage(r: Runner, id: string, i: number, done: (number?, number?, { store.ModelUse }) -> ()): boolean
	local session = agent.files(dir_of(r, id), i).session
	local ok, err = pcall(function(): string?
		local argv = { "/bin/sh", "-c", M.TALLY, "roost", session, tostring(MAX_USES) }
		tern.process.run(argv, { timeout_ms = TALLY_TIMEOUT_MS }, function(res)
			if res.status == 0 and not res.timed_out then
				done(M.parse_tally(res.stdout or ""))
			else
				done(nil, nil, {})
			end
		end)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot read agent usage", err)
	end
	return ok
end

local function same_uses(a: { store.ModelUse }?, b: { store.ModelUse }): boolean
	if a == nil or #a ~= #b then
		return false
	end
	for k, u in b do
		local o = a[k]
		if o.model ~= u.model or o.agent ~= u.agent or o.role ~= u.role then
			return false
		end
	end
	return true
end

-- Reads what an ended agent step cost and which models it used (M.TALLY over its session dir)
-- into the step record, then checks the run again. A failed read leaves the step without a cost.
local function tally_agent(r: Runner, run: Run, i: number)
	local l = live(r, run.id)
	if l.tally[i] == "running" then
		return
	end
	l.tally[i] = "running"
	local id = run.id
	local function done()
		l.tally[i] = "done"
		local cur = r.env.store.by_id[id]
		if cur and cur.state == "running" and cur.step == i then
			check(r, cur)
		end
	end
	local started = read_usage(r, id, i, function(c, t, uses)
		local cur = r.env.store.by_id[id]
		local s = if cur then cur.steps[i] else nil
		if s and c and t then
			-- A resumed conversation's copied history is the parent's spend, not this step's.
			s.cost, s.tokens = math.max(0, c - (s.cost_base or 0)), math.max(0, t - (s.tokens_base or 0))
			if #uses > 0 then
				s.models = uses
			end
			persist(r)
		end
		done()
	end)
	if not started then
		done()
	end
end

-- How often a working agent step's models are read again at most, and how many times longer than
-- the last read took the next one waits (a huge session isn't rescanned back to back).
local PEEK_EVERY = 20
local PEEK_SPAN = 20

-- Which models a working agent step (its subagents and side calls included) has used so far, for
-- the run's details; the ended step's tally has the last word.
local function peek_agent(r: Runner, run: Run, i: number)
	local l = live(r, run.id)
	local t = now(r)
	local due = l.peek_at[i]
	if l.peeking[i] or l.tally[i] ~= nil or (due and t < due) then
		return
	end
	l.peeking[i] = true
	local id = run.id
	local started = read_usage(r, id, i, function(_, _, uses)
		local done_at = now(r)
		l.peeking[i] = nil
		l.peek_at[i] = done_at + math.max(PEEK_EVERY, (done_at - t) * PEEK_SPAN)
		local cur = r.env.store.by_id[id]
		local s = if cur then cur.steps[i] else nil
		if s and l.tally[i] == nil and #uses > 0 and not same_uses(s.models, uses) then
			s.models = uses
			persist(r)
		end
	end)
	if not started then
		l.peeking[i] = nil
		l.peek_at[i] = t + PEEK_EVERY
	end
end

-- Most ended runs fill_models remembers before it starts over.
local MAX_FILLED = 1000

-- Reads the models of an ended run's agent steps that have none recorded (they ended before
-- steps kept them, or their tally failed), once per run in this VM.
function M.fill_models(r: Runner, id: string)
	local run = r.env.store.by_id[id]
	if r.filled[id] or run == nil or not store.TERMINAL[run.state] then
		return
	end
	if r.filled_n >= MAX_FILLED then
		r.filled, r.filled_n = {}, 0
	end
	r.filled[id] = true
	r.filled_n += 1
	for i, s in run.steps do
		if s.agent and s.models == nil then
			read_usage(r, id, i, function(_, _, uses)
				local cur = r.env.store.by_id[id]
				local cs = if cur then cur.steps[i] else nil
				if cs and cs.models == nil and #uses > 0 then
					cs.models = uses
					persist(r)
				end
			end)
		end
	end
end

-- An agent step nobody else will finish: unclaimed when stopping, or claimed but never started.
-- Once its tab is open, follows the conversation into the log.
local function watch_agent(r: Runner, run: Run, i: number)
	local f = agent.files(dir_of(r, run.id), i)
	local l = live(r, run.id)
	if not tern.fs.exists(f.claim) then
		l.claim_at[i] = nil
		if run.stop then
			pcall(tern.fs.write, f.exit, tostring(agent.CODE.stopped))
		end
		return
	end
	if tern.fs.exists(f.pane) then
		-- The window that opened it stops it, and records how it ended.
		l.claim_at[i] = nil
		peek_agent(r, run, i)
		tail_agent(r, run, i, false)
		return
	end
	local t = now(r)
	local since = l.claim_at[i] or t
	l.claim_at[i] = since
	if t - since >= CLAIM_GRACE then
		pcall(tern.fs.write, f.exit, tostring(agent.CODE.lost))
	end
end

-- What a tab step's command sources: the run's ROOST_* variables (no login environment, no
-- tokens: the tab runs in Tern's own login shell).
local function tab_script(r: Runner, run: Run, wf: Workflow): string
	local d = dir_of(r, run.id)
	local v: { [string]: string } = {
		ROOST_RUN_ID = run.id,
		ROOST_WORKFLOW = wf.id,
		ROOST_RUN_DIR = d,
		ROOST_WORKSPACE = run.cwd or "",
		ROOST_REPO = run.repo or "",
		ROOST_REF = run.ref or run.fetch_ref or "",
		ROOST_FILES = `{d}/files`,
		ROOST_LIB = `{d}/lib`,
		ROOST_STATE = files.state_dir(r.env.data, wf.state),
	}
	for k, x in run.inputs do
		v["ROOST_INPUT_" .. string.upper((string.gsub(k, "[^%w]", "_")))] = x
	end
	for k, x in run.outputs or ({} :: { [string]: string }) do
		v["ROOST_OUT_" .. string.upper(k)] = x
	end
	local lines = { "# Roost: this tab's run variables." }
	for _, k in util.keys(v) do
		table.insert(lines, `export {k}={util.shq(v[k])}`)
	end
	return table.concat(lines, "\n") .. "\n"
end

-- Queues step `i`'s tab operation for the windows; the window's result ends the step (watch_tab).
local function start_tab(r: Runner, run: Run, wf: Workflow, i: number, ts: model.TabStep)
	local s = run.steps[i]
	local d = dir_of(r, run.id)
	local cfg = r.env.config().runner
	local id = tabs.step_id(run.id, i)
	local exitf = `{d}/s{i}.exit`
	local function fail(why: string)
		append_log(r, run.id, { `\27[1;36m▶ {s.name}\27[0m`, `[roost] {why}` }, nil, function()
			pcall(tern.fs.write, exitf, "1")
			M.schedule(r, 200)
		end)
	end
	local command: string? = nil
	if ts.action == "open" and ts.command then
		local envf = `{d}/s{i}.env`
		local ok = pcall(tern.fs.write, envf, tab_script(r, run, wf))
		if not ok then
			persist(r, true)
			fail("无法写入标签页的环境文件")
			return
		end
		command = agent.with_env(envf, `{agent.quote(cfg.shell)} -c {agent.quote(ts.command :: string)}`)
	end
	s.tab_op = id
	s.tab_key = ts.key
	-- A close step leaves nothing for the run's end to close.
	s.tab_keep = ts.action ~= "open" or ts.keep
	live(r, run.id).queued_at[i] = nil
	local err = tabs.write_op(r.env.data, {
		id = id,
		action = ts.action,
		workflow = wf.id,
		key = ts.key,
		run = run.id,
		-- A kept tab outlives the run's temporary directories.
		cwd = if ts.keep then (run.repo_path or r.env.home or d) else (run.cwd or d),
		command = command,
		title = ts.title or s.name,
		focus = ts.focus,
		keep = ts.keep,
		session = cfg.session,
		created = now(r),
	})
	if err then
		persist(r, true)
		fail(`无法写入标签页操作:{err}`)
		return
	end
	r.tab_ops[id] = { run = run.id, step = i, created = now(r) }
	persist(r, true)
	append_log(r, run.id, {
		`\27[1;36m▶ {s.name}\27[0m`,
		`[roost] 等待 Tern 窗口{if ts.action == "open" then "打开" else "关闭"}标签页「{ts.key}」`,
	})
	M.schedule(r, 500)
end

-- A tab step's operation: the window's result (or none in time) becomes the step's exit file,
-- after the log says how it went.
local function watch_tab(r: Runner, run: Run, i: number)
	local l = live(r, run.id)
	if l.settling[i] then
		return
	end
	local s = run.steps[i]
	local d = dir_of(r, run.id)
	local id = s.tab_op
	local runid = run.id
	-- `withdraw`: no window carried it out; its op goes at once so none starts it now. A result's op
	-- stays until the exit file is written, so a reload in between reads the result again.
	local function settle(code: number, line: string, withdraw: boolean?)
		l.settling[i] = true
		local function drop()
			if id then
				tabs.remove(r.env.data, id)
				r.tab_ops[id] = nil
			end
		end
		if withdraw then
			drop()
		end
		append_log(r, runid, { line }, nil, function()
			l.settling[i] = nil
			pcall(tern.fs.write, `{d}/s{i}.exit`, tostring(code))
			drop()
			persist(r)
			local cur = r.env.store.by_id[runid]
			if cur and cur.state == "running" and cur.step == i then
				check(r, cur)
			end
		end)
		persist(r)
	end
	if id == nil then
		settle(1, "[roost] 标签页操作丢失(插件重载前没有记录)")
		return
	end
	local p = tabs.paths(r.env.data, id)
	if tern.fs.exists(p.done) then
		local res = tabs.read_result(p.done)
		if res == nil then
			settle(1, "[roost] 窗口写入的标签页结果读不出")
		else
			settle(if res.ok then 0 else 1, `[roost] {res.message}`)
		end
		return
	end
	if not tern.fs.exists(p.op) then
		settle(1, "[roost] 标签页操作文件不见了")
		return
	end
	local t = now(r)
	if tern.fs.exists(p.claim) then
		-- A window is on it: let it finish, unless it never does.
		local since = l.claim_at[i] or t
		l.claim_at[i] = since
		if t - since >= CLAIM_GRACE then
			settle(agent.CODE.lost, "[roost] 窗口认领了标签页操作但没有完成", true)
		end
		return
	end
	l.claim_at[i] = nil
	-- Unclaimed, so no window opened anything: nothing for the run's end to close either.
	if run.stop then
		s.tab_key = nil
		settle(agent.CODE.stopped, "[roost] 已停止,标签页操作没有执行", true)
		return
	end
	local since = l.queued_at[i] or t
	l.queued_at[i] = since
	if t - since >= TAB_WAIT then
		s.tab_key = nil
		settle(1, `[roost] {TAB_WAIT} 秒内没有 Tern 窗口处理标签页操作(需要打开一个本机窗口)`, true)
	end
end

-- Run-end closes and ops left behind: a close is dropped once a window answered it (or after a
-- day without a window); a step's op whose step is no longer current is removed. Returns whether
-- any are still waiting.
local function sweep_tabs(r: Runner): boolean
	local changed = false
	for id, op in table.clone(r.tab_ops) do
		local drop = false
		if op.step == nil then
			local p = tabs.paths(r.env.data, id)
			drop = tern.fs.exists(p.done) or now(r) - op.created >= TAB_END_TTL
			if not drop and tern.fs.exists(p.claim) then
				-- A window that claimed it and never answered (closed meanwhile): let another take it.
				op.claimed = op.claimed or now(r)
				if now(r) - (op.claimed :: number) >= CLAIM_GRACE then
					pcall(tern.fs.remove, p.claim)
					op.claimed = nil
				end
			else
				op.claimed = nil
			end
		else
			local run = r.env.store.by_id[op.run]
			drop = run == nil or run.state ~= "running" or run.step ~= op.step
		end
		if drop then
			tabs.remove(r.env.data, id)
			r.tab_ops[id] = nil
			changed = true
		end
	end
	if changed then
		publish_tabs(r)
	end
	return next(r.tab_ops) ~= nil
end

-- Gets the run's App token from the relay and saves it for the steps after it; the exit file
-- (written once the log says how it went) ends the step.
local function start_auth(r: Runner, run: Run, i: number)
	local s = run.steps[i]
	local d = dir_of(r, run.id)
	local id = run.id
	run.step_deadline = now(r) + AUTH_TIMEOUT
	s.state = "running"
	s.started_at = now(r)
	s.exit_code = nil
	pcall(tern.fs.mkdir, d)
	pcall(tern.fs.remove, `{d}/s{i}.exit`)
	persist(r, true)
	local l = live(r, id)
	l.spawned[i] = true
	l.note[i] = nil
	-- Nil once the run stopped or moved on (check then ends the step).
	local function current(): Run?
		local cur = r.env.store.by_id[id]
		return if cur and cur.state == "running" and cur.step == i and cur.stop == nil then cur else nil
	end
	local function done(code: number, lines: { string }, note: string?)
		if note then
			l.note[i] = note
		end
		table.insert(lines, 1, `\27[1;36m▶ {s.name}\27[0m`)
		append_log(r, id, lines, nil, function()
			pcall(tern.fs.write, `{d}/s{i}.exit`, tostring(code))
			local cur = r.env.store.by_id[id]
			if cur then
				check(r, cur)
			end
		end)
	end
	request_token(r, run.repo or "", function(tok, err)
		if current() == nil then
			return
		end
		if tok == nil then
			local why = err or "中继没有给出令牌"
			done(1, { `[roost] 无法获取 GitHub App 令牌:{why}` }, why)
			return
		end
		save_token(r, id, tok.token, function(serr)
			local cur = current()
			if cur == nil then
				pcall(tern.fs.remove, token_path(r, id))
				return
			end
			if serr then
				done(1, { `[roost] {serr}` }, serr)
				return
			end
			cur.app = { login = tok.login, email = tok.email, expires = now(r) + tok.expires_in }
			-- Saved before the exit file: after a reload the next step must still see the identity.
			persist(r, true)
			done(0, token_lines(cur, tok))
		end)
	end)
	M.schedule(r, 1000)
end

-- Why user step `step` doesn't start: its `when` is off (the run goes on), or it is an omp step
-- and the workflow already spent its daily budget today (true: the run ends as skipped).
local function held(r: Runner, run: Run, wf: Workflow, step: model.Step): (string?, boolean)
	local w = step.when
	if w then
		local v = if w.source == "out" then (run.outputs or {})[w.key] else run.inputs[w.key]
		if model.truthy(v) == w.negate then
			return `条件 when = "{if w.negate then "!" else ""}{w.source}.{w.key}" 不满足,跳过`, false
		end
	end
	local budget = wf.daily_budget
	if step.kind == "omp" and budget then
		local spent = stats.cost_since(r.env.store.runs, wf.id, stats.day_start(now(r)))
		if spent >= budget then
			return string.format("今日费用约 $%.2f,已达预算 $%.2f,不再运行 omp 步骤", spent, budget), true
		end
	end
	return nil, false
end

-- Merges the `key=value` lines step `i` appended to $ROOST_OUTPUT into the run's outputs;
-- returns the step's `stop` value (end the run as skipped) when it set one.
local function take_outputs(r: Runner, run: Run, i: number): string?
	local path = `{dir_of(r, run.id)}/s{i}.out`
	local ok, text = pcall(tern.fs.read, path, MAX_OUTPUT_FILE)
	if not ok or type(text) ~= "string" then
		if tern.fs.exists(path) then
			append_log(r, run.id, { `[roost] $ROOST_OUTPUT 读不出(超过 {MAX_OUTPUT_FILE // 1024} KiB?),本步骤的输出已忽略` })
		end
		return nil
	end
	local outs = run.outputs or {}
	local count = 0
	for _ in outs :: { [string]: string } do
		count += 1
	end
	local stop: string? = nil
	for line in string.gmatch(text, "[^\n]+") do
		local k, v = string.match(line, "^%s*([%w_]+)=(.*)$")
		if k and v and model.valid_output_key(k) then
			v = string.sub((string.gsub(v, "\r$", "")), 1, MAX_OUTPUT_VALUE)
			if outs[k] == nil then
				if count >= MAX_OUTPUTS then
					continue
				end
				count += 1
			end
			outs[k] = v
			if k == "stop" then
				stop = if model.truthy(v) then util.clip(util.trim(v), 200) else nil
			end
		end
	end
	run.outputs = if next(outs) then outs else nil
	return stop
end

local function start_step(r: Runner, run: Run, wf: Workflow, i: number)
	local s = run.steps[i]
	local d = dir_of(r, run.id)
	local cfg = r.env.config().runner
	run.step = i
	if s.kind == "auth" then
		start_auth(r, run, i)
		return
	end
	local argv: { string } = {}
	local job: agent.Job? = nil
	local from: Resumed? = nil
	local tabstep: model.TabStep? = nil
	local cwd = run.cwd or d
	local def: model.Step? = nil
	local function refuse(msg: string): { string }
		return { "/bin/sh", "-c", 'echo "$1" >&2; exit 1', "roost", `[roost] {msg}` }
	end
	if s.kind == "prepare" then
		argv = { cfg.shell, "-c", M.PREPARE_WORKTREE }
		cwd = run.repo_path or d
	elseif s.kind == "cleanup" then
		argv = { cfg.shell, "-c", M.CLEANUP_WORKTREE }
		cwd = run.repo_path or d
	elseif s.kind == "env" then
		cwd = run.cwd or d
		local profile, why = environment_of(r, wf)
		if profile then
			argv = { cfg.shell, "-c", M.ENV_SCRIPT, "roost" }
			for _, k in util.keys(profile.vars) do
				table.insert(argv, k)
			end
		else
			argv = refuse(why or "工作流没有指定环境")
		end
	elseif s.kind == "ack" or s.kind == "report" then
		cwd = d
		if app_missing(r, run) then
			-- Never as you: without the App's token the reply isn't sent at all.
			argv = refuse("没有可用的 App 令牌,不在评论中回复")
		elseif s.kind == "ack" then
			argv = { cfg.shell, "-c", reply.ACK, "roost", reply.ack_text(run.id) }
		else
			local body = `{d}/reply.md`
			argv = if pcall(tern.fs.write, body, reply.body(run.final or "success", run.reason, last_answer(r, run), run.id))
				then { cfg.shell, "-c", reply.REPORT, "roost", body }
				else refuse("无法写入回复内容")
		end
	elseif s.kind == "resume" then
		cwd = d
		local j = first_omp(run)
		argv = {
			cfg.shell,
			"-c",
			M.RESUME_SESSION,
			"roost",
			if j then run.resume or "" else "",
			if j then agent.files(d, j).session else "",
			if j then `{d}/s{j}.resume` else "",
			M.TALLY,
			tostring(MAX_USES),
			run.patch or "",
			`{d}/parent.patch`,
		}
	elseif s.kind == "evolve" then
		-- The material is written now; only the log tails are copied by the step's process.
		cwd = d
		local ok, pairs_, perr = pcall(function(): ({ string }, string?)
			return r.env.evolve_prepare(run, wf)
		end)
		if not ok then
			argv = refuse(`准备迭代材料失败:{pairs_}`)
		elseif perr then
			argv = refuse(perr)
		else
			argv = { cfg.shell, "-c", M.EVOLVE_LOGS, "roost" }
			table.move(pairs_ :: { string }, 1, #(pairs_ :: { string }), #argv + 1, argv)
		end
	else
		def = definition(run, wf, i)
		if def == nil then
			-- The workflow changed under this run: stop here, but still clean up.
			s.state = "failed"
			s.finished_at = now(r)
			run.final = run.final or "interrupted"
			run.reason = "工作流定义已变化,无法继续此运行"
			next_step(r, run, wf)
			return
		end
		local step = def :: model.Step
		local why, stop = held(r, run, wf, step)
		if why then
			s.state = "skipped"
			if stop then
				run.final = run.final or "skipped"
				run.reason = why
			end
			append_log(r, run.id, { `\27[2m▷ {s.name}:{why}\27[0m` })
			persist(r)
			next_step(r, run, wf)
			return
		end
		if step.kind == "tab" and step.tab then
			-- Tabs act in Tern, not on GitHub: no App identity needed.
			tabstep = step.tab
		elseif step.kind == "upgrade" then
			if run.workspace ~= "worktree" then
				argv = refuse("upgrade 步骤需要在 Roost 源码克隆的 worktree 里运行(给工作流配置该仓库,workspace = \"worktree\")")
			else
				local apply, aerr = upgrade.install(r.env.data, run.id)
				argv = if apply
					then { cfg.shell, "-c", upgrade.CHECK, "roost", r.env.plugin_dir, r.env.data, run.id, apply }
					else refuse(`无法写入升级脚本:{aerr or "?"}`)
			end
		elseif step.kind == "omp" and step.prompt then
			local args = table.clone(cfg.omp_args)
			for _, a in step.args do
				table.insert(args, a)
			end
			if step.model then
				table.insert(args, "--model")
				table.insert(args, step.model)
			end
			-- A follow-up continues the conversation its resume step copied in.
			local resuming = run.resume ~= nil and i == first_omp(run)
			if resuming then
				from = read_resumed(d, i)
				if from then
					local got = from :: Resumed
					table.insert(args, "--resume")
					table.insert(args, `{agent.files(d, i).session}/{got.file}`)
					s.cost_base, s.tokens_base = got.cost, got.tokens
				end
			end
			-- A view-only collab host: the console's split joins it (`omp join`) as a viewer, which
			-- closes without touching the step.
			local collab = `{d}/s{i}.collab.yml`
			if pcall(tern.fs.write, collab, agent.COLLAB_CONFIG) then
				table.insert(args, "--config")
				table.insert(args, collab)
			end
			local command: string? = if app_missing(r, run) then nil else agent.command(cfg.omp, agent.files(d, i).session, args)
			if command then
				-- cx.agents:start passes no environment: the App identity and the environment's
				-- values go through a sourced file (neither holds a token or a value itself). The
				-- environment comes first, so the App's gh shim leads PATH and its token handling wins.
				local parts: { string } = {}
				-- Keyed on this run's own steps: a queued run whose workflow gained an environment has none.
				local has_env = false
				for _, x in run.steps do
					has_env = has_env or x.kind == "env"
				end
				if has_env then
					local envsh = util.shq(`{d}/environment.sh`)
					table.insert(parts, `[ ! -f {envsh} ] || . {envsh}\n`)
				end
				if run.app then
					table.insert(parts, app_script(r, run))
				end
				if #parts > 0 then
					local envf = `{d}/s{i}.env`
					local ok = pcall(tern.fs.write, envf, table.concat(parts))
					command = if ok then agent.with_env(envf, command :: string) else nil
				end
			end
			if command and resuming and from == nil then
				command = nil
			end
			if command then
				job = {
					run = run.id,
					step = i,
					cwd = cwd,
					omp = cfg.omp,
					command = command,
					prompt = template.render(step.prompt, template_ctx(r, run, wf, uses_payload(step.prompt))),
					title = `{run.workflow_name} · {s.name}`,
					session = cfg.session,
				}
			else
				argv = refuse(if resuming and from == nil then "没有可接续的会话,omp 步骤未启动" else "没有可用的 App 令牌或身份文件,omp 步骤未启动")
			end
		elseif app_missing(r, run) then
			argv = { "/bin/sh", "-c", "echo '[roost] 没有可用的 App 令牌,步骤未以 App 身份启动' >&2; exit 1" }
		elseif step.kind == "file" and step.file then
			-- The run's copy (taken when it started), run by the interpreter for its extension.
			local ref = step.file :: model.FileRef
			local path = files.staged(d, ref)
			local interp = model.interpreter(ref.path)
			local okx, there = pcall(tern.fs.exists, path)
			if interp and okx and there == true then
				argv = table.clone(interp)
				table.insert(argv, path)
				table.move(step.args, 1, #step.args, #argv + 1, argv)
			else
				local missing = `[roost] 本次运行的文件副本里没有 {model.file_ref_text(ref)}(运行开始后才加入的文件不会出现在副本中)`
				argv = { "/bin/sh", "-c", 'echo "$1" >&2; exit 1', "roost", missing }
			end
		else
			argv = { cfg.shell, "-c", step.script or "true" }
		end
	end
	local deadline = run.deadline or (now(r) + cfg.default_timeout)
	if def and def.timeout then
		deadline = math.min(deadline, now(r) + def.timeout)
	end
	if s.kind == "report" then
		deadline = now(r) + 120
	elseif s.kind == "cleanup" then
		-- Never signalled (the worktree must go): this only bounds process.run's own backstop.
		deadline = now(r) + 600
	end
	run.step_deadline = deadline
	s.state = "running"
	s.started_at = now(r)
	s.exit_code = nil

	pcall(tern.fs.mkdir, d)
	if run.workspace == "temp" and run.cwd then
		pcall(tern.fs.mkdir, run.cwd)
	end
	pcall(tern.fs.remove, `{d}/s{i}.exit`)
	if job then
		start_agent(r, run, i, job, from)
		return
	end
	if tabstep then
		start_tab(r, run, wf, i, tabstep :: model.TabStep)
		return
	end
	pcall(tern.fs.remove, `{d}/s{i}.pid`)
	pcall(tern.fs.remove, `{d}/s{i}.pid.w`)
	local log = `{d}/log.txt`
	local app = run.app ~= nil and s.kind ~= "prepare" and s.kind ~= "cleanup" and s.kind ~= "evolve" and s.kind ~= "resume" and s.kind ~= "env"
	local env = step_env(r, run, wf, app)
	if def then
		env.ROOST_OUTPUT = `{d}/s{i}.out`
		env.ROOST_INBOX = `{d}/s{i}.inbox.json`
		pcall(tern.fs.remove, env.ROOST_OUTPUT)
		pcall(tern.fs.remove, env.ROOST_INBOX)
	end
	if app then
		with_app(r, run, env)
	end
	if s.kind == "env" then
		local profile = environment_of(r, wf)
		env.ROOST_ENV_NAME = wf.environment or ""
		env.ROOST_ENV_SETUP = if profile then profile.setup or "" else ""
		-- Before PATH for omp steps too (shell steps get it through step_env).
		local paths: { string } = {}
		local extra: { string } = if profile then profile.path else {}
		for _, p in extra do
			table.insert(paths, util.expand(p, r.env.home))
		end
		env.ROOST_ENV_PATH = table.concat(paths, ":")
	end
	env.ROOST_BANNER = `\27[1;36m▶ {s.name}\27[0m`
	local full = { cfg.shell, "-c", M.WRAPPER, "roost", log, `{d}/s{i}.pid`, `{d}/s{i}.exit`, cwd }
	for _, a in argv do
		table.insert(full, a)
	end
	-- Saved before the process exists, so a reload never restarts a step that already began.
	persist(r, true)
	local id = run.id
	live(r, id).spawned[i] = true
	local ok, err = pcall(function(): string?
		tern.process.run(full, {
			env = env,
			timeout_ms = math.max(1, deadline - now(r)) * 1000 + BACKSTOP_MS,
		}, function(_res)
			local cur = r.env.store.by_id[id]
			if cur and cur.state == "running" and cur.step == i then
				live(r, id).exited[i] = now(r)
				check(r, cur)
			end
		end)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot start step", err)
		pcall(tern.fs.write, `{d}/s{i}.exit`, "127")
	end
	M.schedule(r, 1000)
end

function next_step(r: Runner, run: Run, wf: Workflow)
	local i = run.step + 1
	if run.final then
		-- Stopped or failed: only the reply about it and the cleanup step still run.
		while run.steps[i] and run.steps[i].kind ~= "cleanup" and run.steps[i].kind ~= "report" do
			run.steps[i].state = "skipped"
			i += 1
		end
	end
	if run.steps[i] then
		start_step(r, run, wf, i)
		return
	end
	local final = run.final
	local last = run.steps[#run.steps]
	finish(r, run, final or "success", if final then run.reason else nil)
	if last and last.kind == "cleanup" and last.state == "failed" and run.state == "success" then
		run.reason = "清理 worktree 失败"
	end
	persist(r)
	M.pump(r)
end

-- What the cleanup step found the worktree changed (M.CLEANUP_WORKTREE): totals from its numstat.
local function read_changes(r: Runner, run: Run)
	local d = dir_of(r, run.id)
	local ok, text = pcall(tern.fs.read, `{d}/changes.total`, 256)
	if not ok then
		return
	end
	local files, add, del = string.match(text :: string, "^(%d+) (%d+) (%d+)")
	local n = tonumber(files) or 0
	if n > 0 then
		run.changes = {
			files = n,
			add = tonumber(add) or 0,
			del = tonumber(del) or 0,
			too_big = if tern.fs.exists(`{d}/changes.too_big`) then true else nil,
		}
	end
end

local function step_done(r: Runner, run: Run, wf: Workflow, code: number)
	local s = run.steps[run.step]
	s.exit_code = code
	s.finished_at = now(r)
	s.state = if code == 0 then "success" else "failed"
	local def = if s.kind == "prepare" or s.kind == "cleanup" or s.kind == "auth" then nil else definition(run, wf, run.step)
	if s.kind == "cleanup" then
		read_changes(r, run)
	end
	if run.stop == "cancel" then
		run.final = run.final or "cancelled"
	elseif run.stop == "timeout" then
		run.final = run.final or "timed_out"
		run.reason = "超时"
	elseif code ~= 0 and s.kind ~= "cleanup" and s.kind ~= "report" and s.kind ~= "ack" and not (def and def.continue_on_error) then
		if run.final == nil then
			run.final = "failed"
			run.reason = if s.agent
				then `{s.name}:{agent.describe(code)}`
				elseif s.kind == "auth" then `{s.name}:{live(r, run.id).note[run.step] or `退出码 {code}`}`
				else `{s.name} 退出码 {code}`
		end
	end
	if def and def.kind ~= "omp" and code >= 0 then
		-- The wrapper wrote the exit file, so $ROOST_OUTPUT is a regular file or gone.
		local stop = take_outputs(r, run, run.step)
		if stop and code == 0 and run.final == nil then
			run.final = "skipped"
			run.reason = stop
			append_log(r, run.id, { `[roost] {s.name} 结束了这次运行:{stop}` })
		end
		-- What the step reported for the inbox (the wrapper left only a regular file there).
		local ib = `{dir_of(r, run.id)}/s{run.step}.inbox.json`
		if tern.fs.exists(ib) then
			local ok, raw = pcall(tern.fs.read, ib, inbox.MAX_FILE)
			pcall(tern.fs.remove, ib)
			local note: string?
			if not ok then
				-- An oversize file is refused by the read itself.
				note = `$ROOST_INBOX 读不出(超过 {inbox.MAX_FILE // 1024} KiB?),已忽略`
			else
				local okh, res = pcall(r.env.inbox, run, raw :: string)
				note = if okh then res else `收件箱更新失败:{res}`
			end
			if note then
				append_log(r, run.id, { `[roost] 收件箱:{note}` })
			end
		end
	end
	if s.agent then
		-- The final answer is already in the log when the session file held it.
		local reply = if s.replied then nil else agent.files(dir_of(r, run.id), run.step).reply
		local spent = if s.tokens and s.tokens > 0
			then string.format("(约 $%.4f,%d tokens)", s.cost or 0, s.tokens)
			else ""
		append_log(r, run.id, { `[roost] agent 结束:{agent.describe(code)}{spent}` }, reply)
	end
	run.stop = nil
	next_step(r, run, wf)
end

-- Liveness of a step's wrapper and process group; marks the step exited when both are gone.
local function probe(r: Runner, run: Run, i: number)
	local l = live(r, run.id)
	local t = now(r)
	if t - (l.probe_at[i] or -math.huge) < PROBE_EVERY then
		return
	end
	l.probe_at[i] = t
	local d = dir_of(r, run.id)
	local child = read_pid(`{d}/s{i}.pid`)
	local wrapper = read_pid(`{d}/s{i}.pid.w`)
	if child == nil and wrapper == nil then
		l.exited[i] = l.exited[i] or (t - EXIT_GRACE)
		return
	end
	local id = run.id
	local ok, err = pcall(function(): string?
		tern.process.run({
			"/bin/sh",
			"-c",
			'{ [ -n "$1" ] && kill -0 "$1" 2>/dev/null; } || { [ -n "$2" ] && kill -0 -- "-$2" 2>/dev/null; }',
			"roost",
			if wrapper then tostring(wrapper) else "",
			if child then tostring(child) else "",
		}, { timeout_ms = 5000 }, function(res)
			local cur = r.env.store.by_id[id]
			if not cur or cur.state ~= "running" or cur.step ~= i then
				return
			end
			if res.status ~= 0 and not res.timed_out then
				local lv = live(r, id)
				lv.exited[i] = lv.exited[i] or (now(r) - EXIT_GRACE)
			end
			check(r, cur)
		end)
		return nil
	end)
	if not ok then
		l.probe_at[i] = nil
		tern.log.warn("roost: cannot probe step", err)
	end
end

function check(r: Runner, run: Run)
	if run.state ~= "running" or run.step < 1 or r.env.login().pending then
		return
	end
	-- Without a valid workflows.toml, deadlines and signals still apply; only advancing to the
	-- next step waits.
	local wf, deleted = resolve(r, run)
	local i = run.step
	local cur = run.steps[i]
	local d = dir_of(r, run.id)
	local l = live(r, run.id)
	local t = now(r)
	if deleted and run.final == nil then
		run.final = "interrupted"
		run.reason = "工作流已被删除"
		if cur.kind ~= "cleanup" and cur.kind ~= "report" then
			run.stop = "cancel"
		end
		persist(r)
	end
	local exitf = `{d}/s{i}.exit`
	if tern.fs.exists(exitf) then
		if wf then
			if cur.agent and not l.tail_done[i] then
				-- Log the agent's last entries first; the read's end checks again.
				tail_agent(r, run, i, true)
				return
			end
			if cur.agent and l.tally[i] ~= "done" then
				-- Then what it cost; the tally's end checks again.
				tally_agent(r, run, i)
				return
			end
			local code = agent.read_number(exitf)
			if code == nil then
				-- Still being written (agent exit files are written in place): give it a moment.
				local since = l.exit_bad[i] or t
				l.exit_bad[i] = since
				if t - since < EXIT_GRACE then
					return
				end
			end
			step_done(r, run, wf, code or -1)
		end
		return
	end
	-- Cleanup and the reply come after the run's outcome: their deadline never changes it.
	if run.stop == nil and run.step_deadline and t >= run.step_deadline and cur.kind ~= "cleanup" and cur.kind ~= "report" then
		run.stop = "timeout"
		persist(r)
	end
	if cur.kind == "tab" then
		watch_tab(r, run, i)
		return
	end
	if cur.kind == "auth" then
		if run.stop or not l.spawned[i] then
			-- Stopped, or begun by an earlier VM: its relay request died with it.
			if not run.stop then
				l.note[i] = "插件重载打断了令牌获取"
			end
			pcall(tern.fs.write, exitf, if run.stop then "130" else "1")
		end
		return
	end
	if cur.agent then
		watch_agent(r, run, i)
		return
	end
	-- Cleanup finishes even when the run was stopped; the reply on how it ended too, but only until
	-- its own deadline.
	local overdue = cur.kind == "report" and run.step_deadline ~= nil and t >= run.step_deadline
	if (run.stop and cur.kind ~= "cleanup" and cur.kind ~= "report") or overdue then
		local sent = l.killed[i]
		if sent == nil then
			signal(r, run, "TERM")
		elseif sent == "TERM" and t - (l.kill_at[i] or t) >= KILL_GRACE then
			signal(r, run, "KILL")
		elseif sent == "KILL" then
			probe(r, run, i)
		end
	end
	if not l.spawned[i] then
		-- Started by an earlier VM: nobody calls back, so look for ourselves.
		probe(r, run, i)
	end
	local exited = l.exited[i]
	if wf and exited and t - exited >= EXIT_GRACE then
		-- The wrapper is gone without writing its exit file.
		step_done(r, run, wf, -1)
	end
end

-- Starts queued runs while capacity allows, oldest first, one per workflow.
function M.pump(r: Runner)
	if r.env.workflows() == nil or r.env.login().pending then
		return
	end
	local max = r.env.config().runner.max_concurrent
	local running: { [string]: boolean } = {}
	local n = 0
	for _, run in r.env.store.runs do
		if run.state == "running" then
			running[run.workflow] = true
			n += 1
		end
	end
	for _, run in table.clone(r.env.store.runs) do
		if n >= max then
			break
		end
		if run.state == "queued" and not running[run.workflow] then
			local wf, deleted = resolve(r, run)
			if not wf then
				return
			end
			if deleted then
				finish(r, run, "interrupted", "工作流已被删除")
				persist(r)
				continue
			end
			local w = wf :: Workflow
			-- A directory this run uses that is queued for deletion would be removed under it: wait
			-- for the removal to finish (tick pumps again every second).
			local data = r.env.data
			local waits = { files.state_dir(data, w.state), files.workflow_home(data, w.id) }
			for _, lib in w.libs do
				table.insert(waits, files.lib_root(data, lib))
			end
			local blocked = false
			for _, p in waits do
				blocked = blocked or store.pending(r.env.store, p)
			end
			if blocked then
				M.schedule(r, 1000)
				continue
			end
			run.started_at = now(r)
			-- The run's copies of its files, taken now: later edits never change a run in progress.
			local staged = files.stage(r.env.data, w, dir_of(r, run.id))
			if staged then
				append_log(r, run.id, { `[roost] 准备文件失败:{staged}` })
				finish(r, run, "failed", `准备文件失败:{staged}`)
				persist(r)
				continue
			end
			running[run.workflow] = true
			n += 1
			run.state = "running"
			run.deadline = now(r) + (w.timeout or r.env.config().runner.default_timeout)
			next_step(r, run, w)
		end
	end
end

-- Checks every running run; reschedules itself while any is active.
function M.tick(r: Runner)
	r.timer = nil
	local active = false
	for _, run in table.clone(r.env.store.runs) do
		if run.state == "running" then
			renew(r, run)
			check(r, run)
		end
	end
	for _, run in r.env.store.runs do
		if run.state == "running" or run.state == "queued" then
			active = true
			break
		end
	end
	local waiting = sweep_tabs(r)
	if active then
		M.pump(r)
		M.schedule(r, 1000)
	elseif waiting then
		-- Only run-end closes are left: look again now and then until a window answers them.
		M.schedule(r, 5000)
	end
end

function M.schedule(r: Runner, ms: number)
	if r.timer then
		return
	end
	r.timer = tern.timer(ms, function()
		M.tick(r)
	end)
end

-- After a reload: runs that were running are adopted; `check` probes their step's processes
-- (nobody in this VM gets their callback) and carries on or ends them.
function M.recover(r: Runner)
	-- Tab operations on disk: a step's while its step is current (watch_tab follows it), a
	-- run-end close until answered; anything else is left over from an earlier VM.
	local found, leftover = tabs.scan(r.env.data)
	for _, id in leftover do
		tabs.remove(r.env.data, id)
	end
	for _, f in found do
		local run, step = string.match(f.id, "^(%x+)%-s(%d+)$")
		local erun = string.match(f.id, "^(%x+)%-end%d+$")
		local cur = if run then r.env.store.by_id[run] else nil
		if cur and cur.state == "running" and cur.step == tonumber(step) then
			if not f.done then
				r.tab_ops[f.id] = { run = cur.id, step = cur.step, created = now(r) }
			end
		elseif erun and not f.done then
			local op = tabs.read_op(tabs.paths(r.env.data, f.id).op)
			r.tab_ops[f.id] = { run = erun, created = if op then op.created else now(r) }
		else
			tabs.remove(r.env.data, f.id)
		end
	end
	for _, run in r.env.store.runs do
		if run.state == "running" and run.step < 1 then
			finish(r, run, "interrupted", "插件重载时尚未开始")
		end
	end
	persist(r)
	M.schedule(r, 500)
end

-- Reads up to `limit` bytes of a run's log from `offset` (0-based) without loading the whole file.
function M.read_log(r: Runner, id: string, offset: number, limit: number, cb: (string?, boolean) -> ())
	local path = `{dir_of(r, id)}/log.txt`
	if not tern.fs.exists(path) then
		cb("", true)
		return
	end
	read_chunk(path, offset, limit, function(text)
		if text == nil then
			cb(nil, false)
		else
			cb(text, #text < limit)
		end
	end)
end

return M
