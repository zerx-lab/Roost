--!strict
-- The user's login-shell environment: system variables plus what the shell's startup sets (fish's
-- config.fish and exported universal variables, zsh/bash profiles), so the processes Roost starts
-- from the host see what a terminal sees. The daemon itself runs with launchd's minimal
-- environment. Held in memory only: it carries whatever secrets the shell exports.

local util = require("./util")

local M = {}

-- `env`: nil until a capture succeeded (then the last good one, kept while refreshing).
-- `pending`: no capture has finished in this VM yet.
export type State = {
	env: { [string]: string }?,
	shell: string?,
	pending: boolean,
	busy: boolean, -- a capture is running
	error: string?,
	at: number?,
}

M.TIMEOUT_MS = 10000
local MARK = "__ROOST_LOGIN_ENV__"
local MAX_BYTES = 1024 * 1024 -- the capture's whole output
local MAX_VARS = 2048
-- Kept well under ARG_MAX (1 MiB on macOS), which the daemon's own variables and argv share.
local MAX_ENV_BYTES = 256 * 1024
-- Variables describing the capturing shell process, not the user's environment.
local DROP: { [string]: boolean } = { PWD = true, OLDPWD = true, SHLVL = true, _ = true }

-- The account's login shell (macOS: the directory record, else $SHELL, else /bin/sh), run as an
-- interactive login shell that prints its environment NUL-separated between two marks, so
-- whatever the startup files print around it is ignored. The shell's path goes to stderr.
M.SCRIPT = [[
sh=$(dscl . -read "/Users/$(id -un)" UserShell 2>/dev/null | sed -n 's/^UserShell: //p')
[ -x "$sh" ] || sh=$SHELL
[ -x "$sh" ] || sh=/bin/sh
printf '%s\n' "$sh" >&2
exec "$sh" -l -i -c "printf %s $1; /usr/bin/env -0; printf %s $1" </dev/null
]]

function M.new(): State
	return { env = nil, shell = nil, pending = true, busy = false, error = nil, at = nil }
end

-- The variables between the marks, or nil with why not.
function M.parse(out: string): ({ [string]: string }?, string?)
	if #out > MAX_BYTES then
		return nil, "输出过大"
	end
	local a = string.find(out, MARK, 1, true)
	local b = if a then string.find(out, MARK, a + #MARK, true) else nil
	if not a or not b then
		return nil, "没有读到环境变量"
	end
	local env: { [string]: string } = {}
	local n, size = 0, 0
	for _, entry in string.split(string.sub(out, a + #MARK, b - 1), "\0") do
		local k, v = string.match(entry, "^([%a_][%w_]*)=(.*)$")
		if k and v and not DROP[k] then
			n += 1
			size += #entry + 1
			if n > MAX_VARS or size > MAX_ENV_BYTES then
				-- A cut would drop arbitrary variables: fail and keep the last good one instead.
				return nil, "环境变量过多或过大"
			end
			env[k] = v
		end
	end
	if env.PATH == nil then
		return nil, "环境里没有 PATH"
	end
	return env, nil
end

-- Captures into `st` unless a capture is running; `done` runs when it finished (good or not).
function M.capture(st: State, now: () -> number, done: () -> ())
	if st.busy then
		return
	end
	st.busy = true
	local function finish(env: { [string]: string }?, shell: string?, err: string?)
		if env then
			st.env, st.error = env, nil
		else
			st.error = err
		end
		st.shell = shell or st.shell
		st.pending, st.busy = false, false
		st.at = now()
		done()
	end
	local ok, err = pcall(function(): string?
		tern.process.run(
			{ "/bin/sh", "-c", M.SCRIPT, "roost", MARK },
			{ timeout_ms = M.TIMEOUT_MS },
			function(res: ProcessResult)
				-- The first stderr line is the shell's path; its startup may write more after it, and
				-- anything that isn't a plain path (a startup error could echo a secret) stays out.
				local first = util.trim(util.first_line(string.sub(res.stderr or "", 1, 4096)))
				local shell = if string.match(first, "^/[^%s]*$") then first else ""
				local name = if shell ~= "" then shell else "登录 shell"
				if res.timed_out then
					finish(nil, shell, `{name} 启动超过 {M.TIMEOUT_MS // 1000} 秒`)
					return
				end
				local env, why = M.parse(res.stdout or "")
				if env == nil then
					finish(nil, shell, `{name}:{why}(退出码 {res.status})`)
					return
				end
				finish(env, shell, nil)
			end
		)
		return nil
	end)
	if not ok then
		finish(nil, nil, `无法启动 /bin/sh:{tostring(err)}`)
	end
end

-- The environment a local tool runs with: the login environment (less `drop`), then `vars`, with
-- PATH being `extra` (already expanded) before the login PATH (else `fallback`) unless `vars`
-- sets PATH.
function M.compose(
	st: State,
	vars: { { [string]: string } },
	extra: { string },
	fallback: string?,
	drop: { string }?
): { [string]: string }
	local env: { [string]: string } = {}
	if st.env then
		for k, v in st.env do
			env[k] = v
		end
		if drop then
			for _, k in drop do
				(env :: any)[k] = nil
			end
		end
	end
	local explicit: string? = nil
	for _, t in vars do
		for k, v in t do
			env[k] = v
		end
		explicit = t.PATH or explicit
	end
	if explicit == nil then
		local paths = table.clone(extra)
		local base = if st.env then st.env.PATH else fallback
		if base and base ~= "" then
			table.insert(paths, base)
		end
		env.PATH = table.concat(paths, ":")
	end
	return env
end

return M
