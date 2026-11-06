--!strict
-- The agent step protocol shared by the host's runner and the window's launcher. An omp step runs
-- as a native agent block, which only a window can open, so the two halves meet in one kv key and
-- a few files in the run directory:
--
--   kv `agent_jobs`   host → windows: the agent steps now active, `{run, step, stop}`
--   s<i>.job.json     host: what to start (cwd, command, prompt, title, session name)
--   s<i>.claim/       window: made with `mkdir`, so exactly one window starts the agent
--   s<i>.pane         window: the agent block's pane id
--   s<i>.reply.txt    window: the agent's last message
--   s<i>.exit         window (host for an unclaimed or abandoned step): the step's exit code
--   s<i>.session/     omp's --session-dir: the conversation, kept and pruned with the run

local M = {}

M.KV = "agent_jobs"
M.SCHEME = "roost://"

-- Exit codes a finished agent step records.
M.CODE = {
	done = 0,
	failed = 1, -- the turn reported failure, or omp exited on its own
	launch = 127, -- the window could not open the agent block
	closed = 130, -- the block was closed by hand
	lost = 137, -- claimed but never started, or the block vanished
	stopped = 143, -- cancelled or timed out
}

-- Most bytes of the last message kept in s<i>.reply.txt.
M.MAX_REPLY = 64 * 1024

export type Files = {
	job: string,
	claim: string,
	pane: string,
	reply: string,
	exit: string,
	session: string,
}

export type Job = {
	run: string,
	step: number,
	cwd: string,
	omp: string, -- the omp program, for resuming the conversation later
	command: string,
	prompt: string,
	title: string,
	session: string,
}

-- What kv `agent_jobs` lists.
export type Active = { run: string, step: number, stop: boolean }

-- A run's directory under the plugin data directory (store.run_dir uses the same layout).
function M.run_dir(data: string, id: string): string
	return `{data}/runs/{id}`
end

function M.files(dir: string, i: number): Files
	local base = `{dir}/s{i}`
	return {
		job = `{base}.job.json`,
		claim = `{base}.claim`,
		pane = `{base}.pane`,
		reply = `{base}.reply.txt`,
		exit = `{base}.exit`,
		session = `{base}.session`,
	}
end

-- One shell word: bare when it is plain, else single-quoted.
function M.quote(s: string): string
	if s ~= "" and string.match(s, "^[%w%-_./=:@,+%%]+$") then
		return s
	end
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function join(words: { string }): string
	local out = table.create(#words)
	for i, w in words do
		out[i] = M.quote(w)
	end
	return table.concat(out, " ")
end

-- The agent block's command line: omp with Roost's session directory first, then the args.
function M.command(omp: string, session_dir: string, args: { string }): string
	local words = { omp, "--session-dir", session_dir }
	for _, a in args do
		table.insert(words, a)
	end
	return join(words)
end

-- The command line that reopens a finished step's conversation.
function M.resume_command(omp: string, session_dir: string, file: string): string
	return join({ omp, "--session-dir", session_dir, "--resume", file })
end

-- The step's session file: the newest `*.jsonl` omp wrote straight into its --session-dir (names
-- start with the start time); nil when it saved none.
function M.session_file(dir: string): string?
	local ok, names = pcall(tern.fs.list, dir)
	if not ok then
		return nil
	end
	local best: string? = nil
	for _, name in names :: { string } do
		if string.sub(name, 1, 1) ~= "." and string.sub(name, -6) == ".jsonl" and (best == nil or name > best) then
			best = name
		end
	end
	return if best then `{dir}/{best}` else nil
end

function M.read_job(path: string): Job?
	local ok, text = pcall(tern.fs.read, path, 4 * 1024 * 1024)
	if not ok then
		return nil
	end
	local ok2, v = pcall(tern.json.decode, text :: string)
	if not ok2 or type(v) ~= "table" then
		return nil
	end
	for _, k in { "run", "cwd", "omp", "command", "prompt", "title", "session" } do
		if type(v[k]) ~= "string" then
			return nil
		end
	end
	if type(v.step) ~= "number" then
		return nil
	end
	return v :: any
end

-- Reads a number file (exit code, pane id); nil when absent or unreadable.
function M.read_number(path: string): number?
	local ok, text = pcall(tern.fs.read, path, 64)
	if not ok then
		return nil
	end
	local n = tonumber((string.gsub(text :: string, "%s+", "")))
	return if n then math.floor(n) else nil
end

local DESCRIBE: { [number]: string } = {
	[M.CODE.done] = "完成",
	[M.CODE.failed] = "agent 报告失败或自行退出",
	[M.CODE.launch] = "窗口无法打开 agent",
	[M.CODE.closed] = "agent 标签页被手动关闭",
	[M.CODE.lost] = "agent 丢失(认领后未启动或已消失)",
	[M.CODE.stopped] = "已停止",
}

-- What an agent step's exit code means, for logs and run reasons.
function M.describe(code: number): string
	return DESCRIBE[code] or `退出码 {code}`
end

-- Links the console and the sidebar hand to the window (`cx:open` → `tern.route.link`).
function M.session_url(run: string, step: number): string
	return `{M.SCHEME}session/{run}/{step}`
end

M.SIDEBAR_URL = `{M.SCHEME}sidebar`

export type Route = { kind: "sidebar" } | { kind: "session", run: string, step: number }

function M.parse_url(url: string): Route?
	if url == M.SIDEBAR_URL then
		return { kind = "sidebar" }
	end
	local run, step = string.match(url, "^roost://session/([%x]+)/(%d+)$")
	if run and step then
		return { kind = "session", run = run, step = tonumber(step) :: number }
	end
	return nil
end

return M
