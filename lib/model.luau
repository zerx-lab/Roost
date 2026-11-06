--!strict
-- The two local config files, parsed and validated:
--   roost.toml      binding: relay URL/token, runner settings
--   workflows.toml  repos (local paths), workflows, cron/github triggers, steps
-- Problems come back as issues with 1-based lines where known; callers keep the last good model.

local toml = require("./toml")
local cron = require("./cron")
local template = require("./template")
local util = require("./util")

local M = {}

export type Issue = { file: string, path: string, message: string, line: number? }

export type Relay = { url: string?, token: string?, token_env: string?, client_name: string? }
export type Runner = {
	omp: string,
	omp_args: { string },
	session: string, -- the Tern session agent steps open their tabs in
	shell: string,
	git: string,
	max_concurrent: number,
	default_timeout: number,
	keep_runs: number,
	extra_path: { string },
	env: { [string]: string },
}
export type Config = { relay: Relay, runner: Runner }

export type Repo = { name: string, path: string?, branch: string?, worktree: boolean, hook: boolean }
export type Input = { name: string, description: string?, default: string?, required: boolean }
export type CronTrigger = {
	kind: "cron",
	expr: string,
	cron: cron.Cron,
	utc: boolean,
	repo: string?,
	ref: string?,
	line: number?,
}
export type Trigger = CronTrigger | GithubTrigger
export type GithubTrigger = {
	kind: "github",
	event: string,
	actions: { string },
	labels: { string },
	branches: { string },
	comment: string?,
	senders: { string },
	associations: { string }?,
	workflows: { string },
	conclusions: { string },
	forks: boolean,
	line: number?,
}
export type Step = {
	name: string,
	kind: "omp" | "run",
	prompt: template.Template?,
	script: string?,
	model: string?,
	args: { string },
	timeout: number?,
	continue_on_error: boolean,
}
export type Workflow = {
	id: string,
	name: string,
	description: string?,
	enabled: boolean,
	manual: boolean,
	repos: { string },
	timeout: number?,
	concurrency: "queue" | "skip" | "replace",
	workspace: "auto" | "worktree" | "repo" | "temp",
	env: { [string]: string },
	inputs: { Input },
	triggers: { Trigger },
	steps: { Step },
	line: number?,
}
export type Workflows = {
	text: string,
	repos: { [string]: Repo },
	list: { Workflow },
	by_id: { [string]: Workflow },
}

M.DEFAULT_OMP_ARGS = { "--approval-mode", "yolo" }
M.DEFAULT_SESSION = "Roost"
-- omp flags Roost sets itself: agent steps are interactive and keep their conversation in the run.
local RESERVED_OMP_FLAGS = {
	["-p"] = true,
	["--print"] = true,
	["--session-dir"] = true,
	["--no-session"] = true,
	["-r"] = true,
	["--resume"] = true,
	["-c"] = true,
	["--continue"] = true,
	["--restore"] = true,
}
M.DEFAULT_EXTRA_PATH = { "~/.local/bin", "~/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin" }

local function valid_id(s: string): boolean
	return #s <= 64 and string.match(s, "^[a-z0-9][a-z0-9_%-]*$") ~= nil
end

function M.valid_repo(s: string): boolean
	local owner, name = string.match(s, "^([%w%-_%.]+)/([%w%-_%.]+)$")
	return owner ~= nil and name ~= nil and owner ~= "." and owner ~= ".." and name ~= "." and name ~= ".."
end

-- A small checker over one table: typed getters that record issues and unknown-key detection.
type Ctx = {
	file: string,
	issues: { Issue },
	pos: toml.Positions,
}

local function issue(c: Ctx, path: string, message: string, line: number?)
	table.insert(c.issues, { file = c.file, path = path, message = message, line = line })
end

local function line_of(c: Ctx, t: any, key: any): number?
	local p = c.pos[t]
	return if p then p[key] else nil
end

local function check_keys(c: Ctx, t: { [string]: any }, path: string, allowed: { string })
	local ok: { [string]: boolean } = {}
	for _, k in allowed do
		ok[k] = true
	end
	for k in t do
		if not ok[k] then
			issue(c, path, `未知字段 {k}(可用:{table.concat(allowed, ", ")})`, line_of(c, t, k))
		end
	end
end

local function get_string(c: Ctx, t: { [string]: any }, key: string, path: string): string?
	local v = t[key]
	if v == nil then
		return nil
	end
	if type(v) ~= "string" then
		issue(c, `{path}.{key}`, "应为字符串", line_of(c, t, key))
		return nil
	end
	return v
end

local function get_bool(c: Ctx, t: { [string]: any }, key: string, path: string, default: boolean): boolean
	local v = t[key]
	if v == nil then
		return default
	end
	if type(v) ~= "boolean" then
		issue(c, `{path}.{key}`, "应为 true 或 false", line_of(c, t, key))
		return default
	end
	return v
end

local function get_int(
	c: Ctx,
	t: { [string]: any },
	key: string,
	path: string,
	default: number,
	lo: number,
	hi: number
): number
	local v = t[key]
	if v == nil then
		return default
	end
	if type(v) ~= "number" or v ~= math.floor(v) or v < lo or v > hi then
		issue(c, `{path}.{key}`, `应为 {lo}..{hi} 的整数`, line_of(c, t, key))
		return default
	end
	return v
end

local function get_strings(c: Ctx, t: { [string]: any }, key: string, path: string): { string }
	local v = t[key]
	if v == nil then
		return {}
	end
	local out = {}
	if type(v) ~= "table" then
		issue(c, `{path}.{key}`, "应为字符串数组", line_of(c, t, key))
		return out
	end
	for _, x in v do
		if type(x) ~= "string" then
			issue(c, `{path}.{key}`, "应为字符串数组", line_of(c, t, key))
			return {}
		end
		table.insert(out, x)
	end
	return out
end

-- Flags in `args` that Roost manages itself, as an issue.
local function check_omp_args(c: Ctx, args: { string }, path: string, line: number?)
	for _, a in args do
		local flag = string.match(a, "^([^=]+)=") or a
		if RESERVED_OMP_FLAGS[flag] then
			issue(c, path, `{flag} 由 Roost 管理(omp 步骤以交互式 agent 运行,会话保存在运行目录),请删除`, line)
		end
	end
end

local function get_map(c: Ctx, t: { [string]: any }, key: string, path: string): { [string]: string }
	local v = t[key]
	local out: { [string]: string } = {}
	if v == nil then
		return out
	end
	if type(v) ~= "table" then
		issue(c, `{path}.{key}`, "应为表 { KEY = \"值\" }", line_of(c, t, key))
		return out
	end
	for k, x in v do
		if type(k) ~= "string" or type(x) ~= "string" then
			issue(c, `{path}.{key}`, "键和值都应为字符串", line_of(c, t, key))
		else
			out[k] = x
		end
	end
	return out
end

local function get_table(c: Ctx, t: { [string]: any }, key: string, path: string): { [string]: any }
	local v = t[key]
	if v == nil then
		return {}
	end
	if type(v) ~= "table" then
		issue(c, `{path}.{key}`, "应为表", line_of(c, t, key))
		return {}
	end
	return v
end

local function get_list(c: Ctx, t: { [string]: any }, key: string, path: string): { any }
	local v = t[key]
	if v == nil then
		return {}
	end
	if type(v) ~= "table" or (next(v) ~= nil and v[1] == nil) then
		issue(c, `{path}.{key}`, `应为 [[{path}.{key}]] 表数组`, line_of(c, t, key))
		return {}
	end
	return v
end

local function get_duration(c: Ctx, t: { [string]: any }, key: string, path: string): number?
	local s = get_string(c, t, key, path)
	if s == nil then
		return nil
	end
	local d, err = util.duration(s)
	if not d then
		issue(c, `{path}.{key}`, err or "时长无效", line_of(c, t, key))
	end
	return d
end

local function parse_toml(file: string, text: string): ({ [string]: any }?, toml.Positions?, { Issue })
	local root, extra = toml.parse(text)
	if root == nil then
		local e = extra :: toml.Err
		return nil, nil, { { file = file, path = file, message = e.message, line = e.line } }
	end
	return root, extra :: toml.Positions, {}
end

-- ---------------------------------------------------------------------------------------------
-- roost.toml

function M.parse_config(text: string): (Config?, { Issue })
	local root, pos, errs = parse_toml("roost.toml", text)
	if root == nil or pos == nil then
		return nil, errs
	end
	local c: Ctx = { file = "roost.toml", issues = {}, pos = pos }
	check_keys(c, root, "roost", { "relay", "runner" })
	local r = get_table(c, root, "relay", "relay")
	check_keys(c, r, "relay", { "url", "token", "token_env", "client_name" })
	local url = get_string(c, r, "url", "relay")
	if url == "" then
		url = nil
	end
	if url then
		url = string.gsub(url, "/+$", "")
		if not string.match(url :: string, "^https?://[^/]") then
			issue(c, "relay.url", "应以 https:// 或 http:// 开头", line_of(c, r, "url"))
		end
	end
	local token = get_string(c, r, "token", "relay")
	local relay: Relay = {
		url = url,
		token = if token == "" then nil else token,
		token_env = get_string(c, r, "token_env", "relay"),
		client_name = get_string(c, r, "client_name", "relay"),
	}

	local u = get_table(c, root, "runner", "runner")
	check_keys(c, u, "runner", {
		"omp", "omp_args", "session", "shell", "git", "max_concurrent", "default_timeout", "keep_runs", "extra_path", "env",
	})
	local runner: Runner = {
		omp = get_string(c, u, "omp", "runner") or "omp",
		omp_args = if u.omp_args ~= nil then get_strings(c, u, "omp_args", "runner") else table.clone(M.DEFAULT_OMP_ARGS),
		session = get_string(c, u, "session", "runner") or M.DEFAULT_SESSION,
		shell = get_string(c, u, "shell", "runner") or "/bin/sh",
		git = get_string(c, u, "git", "runner") or "git",
		max_concurrent = get_int(c, u, "max_concurrent", "runner", 2, 1, 16),
		default_timeout = get_duration(c, u, "default_timeout", "runner") or 1800,
		keep_runs = get_int(c, u, "keep_runs", "runner", 200, 10, 2000),
		extra_path = if u.extra_path ~= nil
			then get_strings(c, u, "extra_path", "runner")
			else table.clone(M.DEFAULT_EXTRA_PATH),
		env = get_map(c, u, "env", "runner"),
	}
	check_omp_args(c, runner.omp_args, "runner.omp_args", line_of(c, u, "omp_args"))
	if runner.session == "" or #runner.session > 64 then
		issue(c, "runner.session", "应为 1..64 个字符的会话名", line_of(c, u, "session"))
	end
	if #c.issues > 0 then
		return nil, c.issues
	end
	return { relay = relay, runner = runner }, {}
end

-- The token to send: literal, else the named environment variable.
function M.token(relay: Relay): string?
	if relay.token then
		return relay.token
	end
	if relay.token_env and tern then
		local v = tern.getenv(relay.token_env)
		if v and v ~= "" then
			return v
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------------------------
-- workflows.toml

local function compile_trigger(c: Ctx, t: { [string]: any }, path: string, line: number?, wf_repos: { string }, repos: { [string]: Repo }): Trigger?
	check_keys(c, t, path, {
		"github", "cron", "tz", "repo", "ref", "actions", "labels", "branches", "comment", "senders",
		"associations", "workflows", "conclusions", "forks",
	})
	local gh = get_string(c, t, "github", path)
	local expr = get_string(c, t, "cron", path)
	if gh and expr then
		issue(c, path, "github 与 cron 只能二选一", line)
		return nil
	elseif gh == nil and expr == nil then
		issue(c, path, "触发器需要 github = \"<事件>\" 或 cron = \"<表达式>\"", line)
		return nil
	end
	if gh then
		for _, k in { "tz", "repo", "ref" } do
			if t[k] ~= nil then
				issue(c, `{path}.{k}`, `{k} 只用于 cron 触发器`, line_of(c, t, k))
			end
		end
		if not string.match(gh, "^[a-z_]+$") then
			issue(c, `{path}.github`, `{gh} 不是 GitHub 事件名(如 issues、pull_request、push)`, line_of(c, t, "github"))
		end
		local assoc: { string }? = nil
		if t.associations ~= nil then
			assoc = get_strings(c, t, "associations", path)
			local valid = {
				OWNER = true, MEMBER = true, COLLABORATOR = true, CONTRIBUTOR = true,
				FIRST_TIME_CONTRIBUTOR = true, FIRST_TIMER = true, MANNEQUIN = true, NONE = true,
			}
			for _, a in assoc :: { string } do
				if a ~= "*" and not valid[a] then
					issue(c, `{path}.associations`, `{a} 不是有效的 author_association`, line_of(c, t, "associations"))
				end
			end
		end
		local comment = get_string(c, t, "comment", path)
		local trig: GithubTrigger = {
			kind = "github",
			event = gh,
			actions = get_strings(c, t, "actions", path),
			labels = get_strings(c, t, "labels", path),
			branches = get_strings(c, t, "branches", path),
			comment = if comment and util.trim(comment) ~= "" then comment else nil,
			senders = get_strings(c, t, "senders", path),
			associations = assoc,
			workflows = get_strings(c, t, "workflows", path),
			conclusions = get_strings(c, t, "conclusions", path),
			forks = get_bool(c, t, "forks", path, false),
			line = line,
		}
		return trig
	end
	for _, k in { "actions", "labels", "branches", "comment", "senders", "associations", "workflows", "conclusions", "forks" } do
		if t[k] ~= nil then
			issue(c, `{path}.{k}`, "事件过滤只用于 github 触发器", line_of(c, t, k))
		end
	end
	local parsed, err = cron.parse(expr :: string)
	if not parsed then
		issue(c, `{path}.cron`, err or "cron 无效", line_of(c, t, "cron"))
		return nil
	end
	local tz = get_string(c, t, "tz", path) or "local"
	if tz ~= "local" and tz ~= "UTC" then
		issue(c, `{path}.tz`, "tz 只能是 \"local\"(本机时区)或 \"UTC\"", line_of(c, t, "tz"))
	end
	local repo = get_string(c, t, "repo", path)
	if repo then
		local key = util.ifind(repos, repo)
		if not key then
			issue(c, `{path}.repo`, `{repo} 未在 [repos] 中声明`, line_of(c, t, "repo"))
		end
		repo = key
	elseif #wf_repos == 1 then
		repo = wf_repos[1]
	end
	local trig: CronTrigger = {
		kind = "cron",
		expr = expr :: string,
		cron = parsed,
		utc = tz == "UTC",
		repo = repo,
		ref = get_string(c, t, "ref", path),
		line = line,
	}
	return trig
end

function M.parse_workflows(text: string): (Workflows?, { Issue })
	local root, pos, errs = parse_toml("workflows.toml", text)
	if root == nil or pos == nil then
		return nil, errs
	end
	local c: Ctx = { file = "workflows.toml", issues = {}, pos = pos }
	check_keys(c, root, "workflows", { "repos", "workflow" })

	local repos: { [string]: Repo } = {}
	local rawrepos = get_table(c, root, "repos", "repos")
	for name, r in rawrepos do
		local path = `repos."{name}"`
		local line = line_of(c, rawrepos, name)
		if not M.valid_repo(name) then
			issue(c, path, "仓库名应为 \"owner/name\"", line)
			continue
		end
		if type(r) ~= "table" then
			issue(c, path, "应为表", line)
			continue
		end
		check_keys(c, r, path, { "path", "branch", "worktree", "hook" })
		repos[name] = {
			name = name,
			path = get_string(c, r, "path", path),
			branch = get_string(c, r, "branch", path),
			worktree = get_bool(c, r, "worktree", path, true),
			hook = get_bool(c, r, "hook", path, true),
		}
	end

	local list: { Workflow } = {}
	local by_id: { [string]: Workflow } = {}
	local wfs = get_list(c, root, "workflow", "workflow")
	for wi, w in wfs do
		local wline = line_of(c, wfs, wi)
		if type(w) ~= "table" then
			continue
		end
		local id = get_string(c, w, "id", `workflow[{wi}]`) or ""
		local base = `workflow.{if id ~= "" then id else tostring(wi)}`
		check_keys(c, w, base, {
			"id", "name", "description", "enabled", "manual", "repos", "timeout", "concurrency", "workspace",
			"env", "input", "trigger", "step",
		})
		if not valid_id(id) then
			issue(c, `{base}.id`, `id "{id}" 无效:1-64 位 a-z 0-9 _ -,以字母或数字开头`, line_of(c, w, "id") or wline)
		elseif by_id[id] then
			issue(c, `{base}.id`, `重复的 workflow id "{id}"`, line_of(c, w, "id") or wline)
		end

		local wrepos: { string } = {}
		for _, r in get_strings(c, w, "repos", base) do
			local key = util.ifind(repos, r)
			if key then
				table.insert(wrepos, key)
			else
				issue(c, `{base}.repos`, `{r} 未在 [repos] 中声明`, line_of(c, w, "repos"))
			end
		end

		local conc = get_string(c, w, "concurrency", base) or "queue"
		if conc ~= "queue" and conc ~= "skip" and conc ~= "replace" then
			issue(c, `{base}.concurrency`, "应为 queue、skip 或 replace", line_of(c, w, "concurrency"))
			conc = "queue"
		end
		local ws = get_string(c, w, "workspace", base) or "auto"
		if ws ~= "auto" and ws ~= "worktree" and ws ~= "repo" and ws ~= "temp" then
			issue(c, `{base}.workspace`, "应为 auto、worktree、repo 或 temp", line_of(c, w, "workspace"))
			ws = "auto"
		end

		local inputs: { Input } = {}
		local input_names: { [string]: boolean } = {}
		local rawinputs = get_list(c, w, "input", base)
		for ii, i in rawinputs do
			local ipath = `{base}.input[{ii}]`
			local iline = line_of(c, rawinputs, ii)
			check_keys(c, i, ipath, { "name", "description", "default", "required" })
			local name = get_string(c, i, "name", ipath) or ""
			if not valid_id(name) then
				issue(c, ipath, `输入名 "{name}" 无效`, iline)
			elseif input_names[name] then
				issue(c, ipath, `重复的输入 "{name}"`, iline)
			end
			input_names[name] = true
			table.insert(inputs, {
				name = name,
				description = get_string(c, i, "description", ipath),
				default = get_string(c, i, "default", ipath),
				required = get_bool(c, i, "required", ipath, false),
			})
		end

		local triggers: { Trigger } = {}
		local rawtrig = get_list(c, w, "trigger", base)
		for ti, t in rawtrig do
			local tr = compile_trigger(c, t, `{base}.trigger[{ti}]`, line_of(c, rawtrig, ti), wrepos, repos)
			if tr then
				table.insert(triggers, tr)
			end
		end

		local steps: { Step } = {}
		local rawsteps = get_list(c, w, "step", base)
		for si, s in rawsteps do
			local spath = `{base}.step[{si}]`
			local sline = line_of(c, rawsteps, si)
			check_keys(c, s, spath, { "name", "omp", "run", "model", "args", "timeout", "continue_on_error" })
			local prompt = get_string(c, s, "omp", spath)
			local script = get_string(c, s, "run", spath)
			local step: Step = {
				name = get_string(c, s, "name", spath) or "",
				kind = "run",
				prompt = nil,
				script = nil,
				model = get_string(c, s, "model", spath),
				args = get_strings(c, s, "args", spath),
				timeout = get_duration(c, s, "timeout", spath),
				continue_on_error = get_bool(c, s, "continue_on_error", spath, false),
			}
			if prompt and script then
				issue(c, spath, "omp 与 run 只能二选一", sline)
			elseif prompt then
				local tpl, err = template.parse(prompt)
				if not tpl then
					issue(c, `{spath}.omp`, err or "模板无效", line_of(c, s, "omp"))
				else
					local bad = template.check(tpl, input_names)
					if bad then
						issue(c, `{spath}.omp`, bad, line_of(c, s, "omp"))
					end
				end
				step.kind = "omp"
				step.prompt = tpl
				check_omp_args(c, step.args, `{spath}.args`, line_of(c, s, "args"))
			elseif script then
				if step.model or #step.args > 0 then
					issue(c, spath, "model 与 args 只用于 omp 步骤", sline)
				end
				step.script = script
			else
				issue(c, spath, "步骤需要 omp = \"<提示词>\" 或 run = \"<shell 脚本>\"", sline)
			end
			if step.name == "" then
				step.name = `{step.kind} #{si}`
			end
			table.insert(steps, step)
		end
		if #steps == 0 then
			issue(c, base, "工作流至少需要一个 [[workflow.step]]", wline)
		end

		local name = get_string(c, w, "name", base)
		local wf: Workflow = {
			id = id,
			name = if name and name ~= "" then name else id,
			description = get_string(c, w, "description", base),
			enabled = get_bool(c, w, "enabled", base, true),
			manual = get_bool(c, w, "manual", base, true),
			repos = wrepos,
			timeout = get_duration(c, w, "timeout", base),
			concurrency = conc :: any,
			workspace = ws :: any,
			env = get_map(c, w, "env", base),
			inputs = inputs,
			triggers = triggers,
			steps = steps,
			line = wline,
		}
		table.insert(list, wf)
		if id ~= "" and by_id[id] == nil then
			by_id[id] = wf
		end
	end
	if #c.issues > 0 then
		table.sort(c.issues, function(a, b)
			return (a.line or 0) < (b.line or 0)
		end)
		return nil, c.issues
	end
	return { text = text, repos = repos, list = list, by_id = by_id }, {}
end

-- Whether `wf` serves `repo` (an empty repos list serves every declared repo).
function M.serves(wf: Workflow, repo: string): boolean
	if #wf.repos == 0 then
		return true
	end
	local low = string.lower(repo)
	for _, r in wf.repos do
		if string.lower(r) == low then
			return true
		end
	end
	return false
end

export type Subscription = { events: { string }, hook: boolean }

-- What the relay must accept: per declared repo, the events of enabled workflows serving it.
function M.subscriptions(w: Workflows): { [string]: Subscription }
	local out: { [string]: Subscription } = {}
	for name, repo in w.repos do
		local set: { [string]: boolean } = {}
		for _, wf in w.list do
			if wf.enabled and M.serves(wf, name) then
				for _, t in wf.triggers do
					if t.kind == "github" then
						set[(t :: GithubTrigger).event] = true
					end
				end
			end
		end
		local events = util.keys(set)
		out[name] = { events = events, hook = repo.hook }
	end
	return out
end

-- The `subscriptions.toml` text the agent would hold, for the manual fallback.
function M.subscriptions_toml(subs: { [string]: Subscription }): string
	local lines = {
		"# Roost relay subscriptions (manual copy). Save as the agent's subscriptions.toml,",
		"# then press 重新加载 in Roost (or send SIGHUP / POST /api/v1/reload).",
		"",
	}
	for _, name in util.keys(subs) do
		local s = subs[name]
		table.insert(lines, `[repos.{toml.quote(name)}]`)
		local evs = {}
		for _, e in s.events do
			table.insert(evs, toml.quote(e))
		end
		table.insert(lines, `events = [{table.concat(evs, ", ")}]`)
		table.insert(lines, `hook = {if s.hook then "true" else "false"}`)
		table.insert(lines, "")
	end
	return table.concat(lines, "\n")
end

return M
