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
--
-- While the agent works, the host reads the session file omp writes there and logs what it does
-- (M.progress), so the run log follows the conversation instead of waiting for the end.

local util = require("./util")

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

-- `command` started through sh after sourcing `envfile`: cx.agents:start passes no environment,
-- so the variables an omp step needs (the GitHub App identity) reach omp this way.
function M.with_env(envfile: string, command: string): string
	return join({ "/bin/sh", "-c", '. "$1" || exit 97; shift; exec "$@"', "roost", envfile }) .. " " .. command
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

-- Links the console hands to the window (`cx:open` → `tern.route.link`).
function M.session_url(run: string, step: number): string
	return `{M.SCHEME}session/{run}/{step}`
end

export type Route = { run: string, step: number }

function M.parse_url(url: string): Route?
	local run, step = string.match(url, "^roost://session/([%x]+)/(%d+)$")
	if run and step then
		return { run = run, step = tonumber(step) :: number }
	end
	return nil
end

-- Session file → run log. The tail of a growing JSONL file: complete lines only, so an entry is
-- read once whole. Tool results are skipped unless they failed (they can be huge); assistant
-- entries become their text and one dim line per tool call.

-- Most characters of an assistant message kept while the turn goes on; the final answer keeps
-- up to MAX_REPLY bytes.
M.MAX_NOTE = 600
-- Most characters of a tool call's one-line summary.
M.MAX_TOOL = 120

export type Progress = {
	lines: { string },
	used: number, -- bytes of the chunk consumed (whole lines, or the dropped piece of one too long)
	final: string?, -- the turn's final answer, when the chunk held it
}

local function one_line(s: string, n: number): string
	return util.clip(util.trim((string.gsub(util.trim(s), "%s*[\r\n]+%s*", " ⏎ "))), n)
end

local TOOL_KEYS = { "i", "path", "command", "pattern", "query", "url", "file", "name" }

local function tool_line(call: { [string]: any }): string
	local name = if type(call.name) == "string" then call.name else "tool"
	local args = if type(call.arguments) == "table" then call.arguments else {}
	local what = ""
	for _, k in TOOL_KEYS do
		if type(args[k]) == "string" and args[k] ~= "" then
			what = args[k]
			break
		end
	end
	return `\27[2m  › {name}{if what ~= "" then "  " .. one_line(what, M.MAX_TOOL) else ""}\27[0m`
end

local function assistant(msg: { [string]: any }, out: { string }): string?
	local final = msg.stopReason ~= "toolUse"
	local texts: { string } = {}
	local content = if type(msg.content) == "table" then msg.content else {}
	for _, c in content do
		if type(c) == "table" and c.type == "text" and type(c.text) == "string" and util.trim(c.text) ~= "" then
			table.insert(texts, util.trim(c.text))
		end
	end
	local text = table.concat(texts, "\n")
	if final then
		if text ~= "" then
			table.insert(out, string.sub(text, 1, M.MAX_REPLY))
		end
		if msg.stopReason == "error" or msg.stopReason == "aborted" then
			local why = if type(msg.errorMessage) == "string" then one_line(msg.errorMessage, M.MAX_NOTE) else msg.stopReason
			table.insert(out, `\27[31m[omp] 本轮中止:{why}\27[0m`)
		end
		return if text ~= "" then text else nil
	end
	if text ~= "" then
		table.insert(out, util.clip(text, M.MAX_NOTE))
	end
	for _, c in content do
		if type(c) == "table" and c.type == "toolCall" then
			table.insert(out, tool_line(c))
		end
	end
	return nil
end

local function failed_tool(msg: { [string]: any }, out: { string })
	local name = if type(msg.toolName) == "string" then msg.toolName else "tool"
	local first = ""
	local content = if type(msg.content) == "table" then msg.content else {}
	for _, c in content do
		if type(c) == "table" and type(c.text) == "string" and util.trim(c.text) ~= "" then
			first = one_line(util.first_line(util.trim(c.text)), M.MAX_TOOL)
			break
		end
	end
	table.insert(out, `\27[31m  ✗ {name}{if first ~= "" then "  " .. first else ""}\27[0m`)
end

-- What the complete lines at the start of `chunk` (read from a session file) add to the log.
-- `full` says the chunk filled the read limit: a chunk without any newline is then one line too
-- long to keep, and is dropped (the rest of that line fails to decode and is skipped next time).
function M.progress(chunk: string, full: boolean): Progress
	local last = 0
	local pos = string.find(chunk, "\n", 1, true)
	while pos do
		last = pos
		pos = string.find(chunk, "\n", pos + 1, true)
	end
	local out: Progress = { lines = {}, used = if last == 0 and full then #chunk else last, final = nil }
	if last == 0 then
		return out
	end
	for line in string.gmatch(string.sub(chunk, 1, last), "([^\n]*)\n") do
		local is_assistant = string.find(line, '"role":"assistant"', 1, true) ~= nil
		local is_error = not is_assistant
			and string.find(line, '"role":"toolResult"', 1, true) ~= nil
			and string.find(line, '"isError":true', 1, true) ~= nil
		if not (is_assistant or is_error) then
			continue
		end
		local ok, v = pcall(tern.json.decode, line)
		if not ok or type(v) ~= "table" or v.type ~= "message" or type(v.message) ~= "table" then
			continue
		end
		local msg = v.message
		if msg.role == "assistant" then
			local final = assistant(msg, out.lines)
			if final then
				out.final = final
			end
		elseif msg.role == "toolResult" and msg.isError == true then
			failed_tool(msg, out.lines)
		end
	end
	return out
end

return M
