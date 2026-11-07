--!strict
-- Workflows that evolve other workflows (`evolve = [...]`, lib/model.luau). Such a run starts with
-- an `evolve` step that writes its material under runs/<id>/evolve/ (M.prepare): a digest of the
-- targets' recent runs, the tails of failed runs' logs, and two copies of everything it may
-- change, base/ (as it was) and edit/ (for the agent). When the run succeeds, whatever edit/ changed
-- is checked and applied like an editor save (M.apply), and recorded as a revision: the state
-- before and after under revisions/<n>/, plus how the touched workflows did before. Their runs
-- after that are watched (M.observe): clearly worse, and the revision is undone; good enough for
-- long enough, and it is kept. Failures of a target can also start its evolver (M.fire), with a
-- cooldown and a daily cap so a broken workflow can't spin it.
--
-- Book (revisions.json): the revisions, newest last, and when each evolver last fired.

local model = require("./model")
local store = require("./store")
local files = require("./files")
local stats = require("./stats")
local util = require("./util")

local M = {}

type Run = store.Run
type Workflow = model.Workflow

-- Most workflows one run gets material for, how many bytes of their files at most (the first
-- target always fits; material is read and written within one host call), and how much of each.
M.MAX_TARGETS = 10
M.MAX_MATERIAL = 8 * 1024 * 1024
M.RECENT = 10
M.LOGS_PER_TARGET = 3
M.LOG_TAIL = 48 * 1024
-- An evolver fires for the same target at most once per COOLDOWN, and DAILY_FIRES times a day.
M.COOLDOWN = 1800
M.DAILY_FIRES = 20
-- A watched revision is kept after WATCH_RUNS runs of each workflow it touched, or WATCH_AGE.
M.WATCH_RUNS = 5
M.WATCH_AGE = 7 * 86400
-- Undone when a workflow failed at least ROLLBACK_BAD times since, at a rate ROLLBACK_MARGIN above
-- its rate before.
M.ROLLBACK_BAD = 2
M.ROLLBACK_MARGIN = 0.25
M.MAX_REVISIONS = 100
local BASELINE_RUNS = 10
local MAX_BOOK = 4 * 1024 * 1024
local MAX_TOML = 512 * 1024

-- Run states that count as a failure, and those that say nothing about a workflow's health
-- (interrupted: a reload or a changed definition stopped it, not the workflow itself).
M.BAD = { failed = true, timed_out = true }
local IGNORED = { cancelled = true, skipped = true, interrupted = true }

export type Count = { runs: number, bad: number }

export type Revision = {
	n: number,
	at: number,
	run: string, -- the evolver's run that made it
	reviewer: string,
	workflows: { string }, -- changed workflows
	libs: { string }, -- changed libraries
	watch: { string }, -- workflows whose runs judge it (changed ones and the users of changed libraries)
	-- applying (being written) | watching | kept | rolled_back | superseded | failed (applying it
	-- failed or was cut off, and it was undone)
	state: string,
	baseline: { [string]: Count },
	seen: { [string]: Count },
	note: string?,
	ended_at: number?,
}

export type Book = {
	path: string,
	revs: { Revision },
	next: number,
	last: { [string]: number }, -- "<evolver>/<target>" → when it last fired
	day: { [string]: { start: number, n: number } }, -- evolver → fires on that local day
}

-- What one workflow and the libraries look like, as files: the `[[workflow]]` block (normalized by
-- model.encode_workflow) and the workflow's own files; each library's files.
export type Snapshot = {
	workflows: { [string]: { toml: string, files: { [string]: string } } },
	libs: { [string]: { [string]: string } },
}

-- What lib/core.luau gives this module.
export type Host = {
	data: string,
	store: store.Store,
	workflows: () -> model.Workflows?,
	valid: () -> boolean, -- workflows.toml parses now without issues
	text: () -> string?, -- workflows.toml as on disk now
	now: () -> number,
	-- Saves one workflow like the editor (core.save_workflow): nil, or why not.
	save_workflow: (id: string, raw: { [string]: any }, wfiles: { [string]: string }, base: { [string]: string }) -> string?,
	save_library: (name: string, tree: { [string]: string }, base: { [string]: string }) -> string?,
	-- Replaces only workflow `id`'s own files (its block in workflows.toml stays as written).
	save_files: (id: string, wfiles: { [string]: string }, base: { [string]: string }) -> string?,
	-- Problems of workflow `id` as saved now (its file references, its libraries), or nil.
	check: (id: string) -> string?,
	discard: (path: string) -> (),
	notice: (level: string, text: string) -> (),
	log: (run: string, lines: { string }) -> (),
}

function M.dir(run_dir: string): string
	return `{run_dir}/evolve`
end

function M.rev_dir(data: string, n: number): string
	return `{data}/revisions/{n}`
end

-- ---------------------------------------------------------------------------------------------
-- The book

local function decode(path: string): any
	local ok, text = pcall(tern.fs.read, path, MAX_BOOK)
	if not ok then
		return nil
	end
	local ok2, v = pcall(tern.json.decode, text :: string)
	return if ok2 and type(v) == "table" then v else nil
end

local function count_of(v: any): Count
	if type(v) == "table" and type(v.runs) == "number" and type(v.bad) == "number" then
		return { runs = v.runs, bad = v.bad }
	end
	return { runs = 0, bad = 0 }
end

local function strings(v: any): { string }
	local out: { string } = {}
	if type(v) == "table" then
		for _, x in v do
			if type(x) == "string" then
				table.insert(out, x)
			end
		end
	end
	return out
end

local function counts(v: any): { [string]: Count }
	local out: { [string]: Count } = {}
	if type(v) == "table" then
		for k, x in v do
			if type(k) == "string" then
				out[k] = count_of(x)
			end
		end
	end
	return out
end

function M.load(data: string): Book
	local path = `{data}/revisions.json`
	local v = decode(path) or decode(path .. ".bak") or {}
	local b: Book = { path = path, revs = {}, next = 1, last = {}, day = {} }
	if type(v.revs) == "table" then
		for _, r in v.revs do
			if type(r) == "table" and type(r.n) == "number" and type(r.at) == "number" and type(r.state) == "string" then
				table.insert(b.revs, {
					n = r.n,
					at = r.at,
					run = if type(r.run) == "string" then r.run else "",
					reviewer = if type(r.reviewer) == "string" then r.reviewer else "",
					workflows = strings(r.workflows),
					libs = strings(r.libs),
					watch = strings(r.watch),
					state = r.state,
					baseline = counts(r.baseline),
					seen = counts(r.seen),
					note = if type(r.note) == "string" then r.note else nil,
					ended_at = if type(r.ended_at) == "number" then r.ended_at else nil,
				})
				b.next = math.max(b.next, r.n + 1)
			end
		end
	end
	if type(v.next) == "number" then
		b.next = math.max(b.next, math.floor(v.next))
	end
	if type(v.last) == "table" then
		for k, t in v.last do
			if type(k) == "string" and type(t) == "number" then
				b.last[k] = t
			end
		end
	end
	if type(v.day) == "table" then
		for k, d in v.day do
			if type(k) == "string" and type(d) == "table" and type(d.start) == "number" and type(d.n) == "number" then
				b.day[k] = { start = d.start, n = d.n }
			end
		end
	end
	return b
end

-- Writes the book: the backup first, so a failed write leaves one whole copy.
function M.save(b: Book): string?
	local text = tern.json.encode({
		revs = tern.json.array(table.move(b.revs, 1, #b.revs, 1, {})),
		next = b.next,
		last = b.last,
		day = b.day,
	})
	local ok, err = pcall(function(): string?
		if tern.fs.exists(b.path) then
			tern.fs.write(b.path .. ".bak", text)
		end
		tern.fs.write(b.path, text)
		return nil
	end)
	if not ok then
		tern.log.warn("roost: cannot save revisions.json", err)
		return tostring(err)
	end
	return nil
end

-- Newest first.
function M.list(b: Book): { Revision }
	local out: { Revision } = {}
	for i = #b.revs, 1, -1 do
		table.insert(out, b.revs[i])
	end
	return out
end

local function find(b: Book, n: number): Revision?
	for _, r in b.revs do
		if r.n == n then
			return r
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------------------------
-- Snapshots

local function same_tree(a: { [string]: string }, b: { [string]: string }): boolean
	for k, v in a do
		if b[k] ~= v then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

-- The `[[workflow]]` block of `id` in `text`, normalized; nil when there is none.
local function block_of(text: string, id: string): string?
	local raw = model.raw_workflow(text, id)
	return if raw then model.encode_workflow(raw) else nil
end

-- What workflows `ids` and libraries `libs` look like on disk now.
local function current(h: Host, ids: { string }, libs: { string }): (Snapshot?, string?)
	local text = if #ids > 0 then h.text() else ""
	if text == nil then
		return nil, "无法读取 workflows.toml"
	end
	local snap: Snapshot = { workflows = {}, libs = {} }
	for _, id in ids do
		local toml = block_of(text, id)
		if toml == nil then
			return nil, `workflows.toml 里没有工作流 {id}`
		end
		local tree, err = files.load(files.workflow_root(h.data, id))
		if tree == nil then
			return nil, `{id} 的文件:{err}`
		end
		snap.workflows[id] = { toml = toml, files = tree.text }
	end
	for _, l in libs do
		local tree, err = files.load(files.lib_root(h.data, l))
		if tree == nil then
			return nil, `文件库 {l}:{err}`
		end
		snap.libs[l] = tree.text
	end
	return snap, nil
end

local function write_tree(root: string, tree: { [string]: string }): string?
	pcall(tern.fs.mkdir, root)
	for _, rel in util.keys(tree) do
		local err = files.write(root, rel, tree[rel])
		if err then
			return err
		end
	end
	return nil
end

local function write_snapshot(dir: string, snap: Snapshot): string?
	for _, id in util.keys(snap.workflows) do
		local w = snap.workflows[id]
		local err = files.write(`{dir}/workflows/{id}`, "workflow.toml", w.toml)
			or write_tree(`{dir}/workflows/{id}/files`, w.files)
		if err then
			return `{id}:{err}`
		end
	end
	for _, l in util.keys(snap.libs) do
		local err = write_tree(`{dir}/library/{l}`, snap.libs[l])
		if err then
			return `文件库 {l}:{err}`
		end
	end
	return nil
end

-- Reads the snapshot of `ids` and `libs` under `dir`; a missing workflow.toml is an error, missing
-- files are an empty tree.
local function read_snapshot(dir: string, ids: { string }, libs: { string }): (Snapshot?, string?)
	local snap: Snapshot = { workflows = {}, libs = {} }
	for _, id in ids do
		local ok, toml = pcall(tern.fs.read, `{dir}/workflows/{id}/workflow.toml`, MAX_TOML)
		if not ok or type(toml) ~= "string" then
			return nil, `读不到 workflows/{id}/workflow.toml`
		end
		local tree, err = files.load(`{dir}/workflows/{id}/files`)
		if tree == nil then
			return nil, `workflows/{id}/files:{err}`
		end
		snap.workflows[id] = { toml = toml, files = tree.text }
	end
	for _, l in libs do
		local tree, err = files.load(`{dir}/library/{l}`)
		if tree == nil then
			return nil, `library/{l}:{err}`
		end
		snap.libs[l] = tree.text
	end
	return snap, nil
end

-- ---------------------------------------------------------------------------------------------
-- Material

-- The libraries only workflows `ids` use (editing them can't touch any other workflow).
local function owned_libs(w: model.Workflows, ids: { string }): { string }
	local inscope: { [string]: boolean } = {}
	local wanted: { [string]: boolean } = {}
	for _, id in ids do
		inscope[id] = true
		local wf = w.by_id[id]
		local used: { string } = if wf then wf.libs else {}
		for _, l in used do
			wanted[l] = true
		end
	end
	local libs: { string } = {}
	for _, l in util.keys(wanted) do
		local only = model.valid_lib(l)
		for _, x in w.list do
			if not inscope[x.id] and table.find(x.libs, l) ~= nil then
				only = false
				break
			end
		end
		if only then
			table.insert(libs, l)
		end
	end
	return libs
end

-- The workflows `wf` evolves (`first` first, at most MAX_TARGETS), and the libraries only they use.
function M.scope(w: model.Workflows, wf: Workflow, first: string?): ({ string }, { string })
	local all = model.evolve_targets(w, wf)
	local ids: { string } = {}
	if first and table.find(all, first) then
		table.insert(ids, first)
	end
	for _, id in all do
		if #ids >= M.MAX_TARGETS then
			break
		end
		if id ~= first then
			table.insert(ids, id)
		end
	end
	return ids, owned_libs(w, ids)
end

local function tree_size(t: { [string]: string }): number
	local n = 0
	for _, text in t do
		n += #text
	end
	return n
end

-- Counted runs of `id`, newest first, at most `n` (finished ones that say something about health).
local function recent(s: store.Store, id: string, n: number, before: number?): { Run }
	local out: { Run } = {}
	for i = #s.runs, 1, -1 do
		local r = s.runs[i]
		if r.workflow == id and store.TERMINAL[r.state] and not IGNORED[r.state] then
			if before == nil or (r.started_at or r.created_at) < before then
				table.insert(out, r)
				if #out >= n then
					break
				end
			end
		end
	end
	return out
end

local STATE_TEXT: { [string]: string } = {
	success = "成功",
	failed = "失败",
	timed_out = "超时",
	interrupted = "中断",
}

local function md_cell(s: string): string
	return (string.gsub(util.clip(util.trim(util.first_line(s)), 120), "|", "\\|"))
end

local README = [==[
# Roost 迭代材料

你在迭代下列工作流(按优先级排列,第一个是这次触发的工作流,如果有的话):

<目标>

## 触发方式

见 `digest.md` 第一行:

- **失败**:被迭代的工作流运行失败或超时。找根因,能在下面的文件里修就修。
- **抽查**:被迭代的工作流运行成功,抽出来复查。逐项看这次运行的结果与过程是否有可改进的地方:结论是否正确、有没有多余或重复的步骤与费用、耗时、日志与临时数据是否冗余、调试后是否清理干净、哪些人工环节可以自动化。没有值得改的就什么都不改。
- **巡检**:定时运行,没有指定运行,看所有工作流近期的整体表现。

## 目录

- `digest.md`、`digest.json`:近期运行的结果、失败原因、近 7 天健康度,以及以往的修订和回滚记录。
- `logs/<运行 id>.txt`:触发本次的运行与近期失败运行的日志末尾(每个最多 48 KiB)。
- `context/`:只读的背景资料,不会被应用。
  - `roost.toml`:本机 Roost 配置(令牌、密钥与 env 的值已隐藏)。
  - `repos.md`:仓库与本机检出路径。
  - `suggestions.md`:近期迭代运行已经提出、需要人处理的建议;不要重复提出,除非有新的证据。
- `edit/`:可以修改的副本,只改这里。
  - `edit/workflows/<id>/workflow.toml`:该工作流的 `[[workflow]]` 块。不能改 `id`,不能加 `evolve`。
  - `edit/workflows/<id>/files/…`:该工作流的私有文件(脚本、提示词)。
  - `edit/library/<库>/…`:只被上面这些工作流使用的文件库。
- `base/`:运行开始时的原样,不要改。
- `suggestions.md`(你来写,可选):`edit/` 改不了、需要人处理的改进,例如系统配置(roost.toml、omp、本机或调试机环境)、新的自动化、Roost 本身的代码。每条一段:现象与证据(运行 id、日志位置)、建议的改法、预期收益。Roost 会把它写进运行日志并通知。

## 规则

- 本次运行成功结束后,Roost 比较 `edit/` 与 `base/`,校验通过就自动应用(和编辑器保存一样);校验不通过的改动会被丢弃,原因写进运行日志。
- 应用后,被改动的工作流接下来的运行如果明显变差(至少 2 次失败,且失败率比改动前高 25% 以上),Roost 会自动回滚。
- 改动期间如果有人在编辑器里改了同一个工作流,这次的改动会被跳过。
- 找不到明确原因、或问题不在这些文件里(网络、凭据、外部服务),就不要改 `edit/`,在回复或 `suggestions.md` 里说明。
- 只做有证据支撑的最小改动;不要顺手重构,不要放宽任何安全约束。
]==]

local function find_run(s: store.Store, id: string): Run?
	for i = #s.runs, 1, -1 do
		if s.runs[i].id == id then
			return s.runs[i]
		end
	end
	return nil
end

local function digest_md(h: Host, b: Book, run: Run, ids: { string }, w: model.Workflows, logs: { [string]: { string } }): string
	local t = h.now()
	local health = stats.health(h.store.runs, t, 7)
	local out: { string } = { `# 运行摘要(生成于 {util.clock(t)})`, "" }
	if run.evolve_target then
		local src = if run.evolve_run then find_run(h.store, run.evolve_run) else nil
		local how = if src and src.state == "success" then "抽查:成功" else "失败:" .. (if src then STATE_TEXT[src.state] or src.state else "失败")
		table.insert(out, `触发:{how} · {run.evolve_target} 的运行 {run.evolve_run or "?"}`)
	else
		table.insert(out, `触发:巡检 · {run.trigger.kind} · {run.trigger.detail}`)
	end
	for _, id in ids do
		local wf = w.by_id[id]
		table.insert(out, "")
		table.insert(out, `## {wf.name}({id})`)
		local kinds: { string } = {}
		for _, s in wf.steps do
			table.insert(kinds, `{s.name}({s.kind})`)
		end
		table.insert(out, `- {if wf.enabled then "启用" else "停用"};步骤:{table.concat(kinds, "、")}`)
		local hv = health[id]
		if hv then
			local p50 = if hv.p50 then util.fmt_duration(hv.p50) else "—"
			table.insert(out, `- 近 7 天:运行 {hv.runs},成功 {hv.ok},失败 {hv.bad},成功率 {stats.percent(hv.rate)},用时中位数 {p50}`)
		else
			table.insert(out, "- 近 7 天没有运行")
		end
		local list = recent(h.store, id, M.RECENT, nil)
		if #list > 0 then
			table.insert(out, "")
			table.insert(out, "| 运行 | 结果 | 原因 | 触发 | 开始 | 用时 |")
			table.insert(out, "|---|---|---|---|---|---|")
			for _, r in list do
				local took = stats.took(r)
				table.insert(
					out,
					`| {r.id} | {STATE_TEXT[r.state] or r.state} | {md_cell(r.reason or "")} | {r.trigger.kind} | {util.clock(r.started_at)} | {if took then util.fmt_duration(took) else "—"} |`
				)
			end
		end
		local lg = logs[id]
		if lg and #lg > 0 then
			local names: { string } = {}
			for _, rid in lg do
				table.insert(names, `logs/{rid}.txt`)
			end
			table.insert(out, `- 日志:{table.concat(names, "、")}`)
		end
		local past: { string } = {}
		for i = #b.revs, 1, -1 do
			local rv = b.revs[i]
			if table.find(rv.watch, id) then
				table.insert(past, `  - #{rv.n} {util.clock(rv.at)} {rv.state}{if rv.note then ":" .. rv.note else ""}`)
				if #past >= 5 then
					break
				end
			end
		end
		if #past > 0 then
			table.insert(out, "- 以往的修订:")
			for _, l in past do
				table.insert(out, l)
			end
		end
	end
	return table.concat(out, "\n") .. "\n"
end

local function digest_json(h: Host, run: Run, ids: { string }, libs: { string }, logs: { [string]: { string } }): string
	local t = h.now()
	local health = stats.health(h.store.runs, t, 7)
	local targets: { any } = {}
	for _, id in ids do
		local runs: { any } = {}
		for _, r in recent(h.store, id, M.RECENT, nil) do
			local steps: { any } = {}
			for _, s in r.steps do
				table.insert(steps, { name = s.name, kind = s.kind, state = s.state, exit_code = s.exit_code })
			end
			table.insert(runs, {
				id = r.id,
				state = r.state,
				reason = r.reason,
				trigger = r.trigger.kind,
				started_at = r.started_at,
				took = stats.took(r),
				cost = stats.run_cost(r),
				steps = tern.json.array(steps),
			})
		end
		local hv = health[id]
		table.insert(targets, {
			id = id,
			health = if hv then { runs = hv.runs, ok = hv.ok, bad = hv.bad, rate = hv.rate, p50 = hv.p50, p95 = hv.p95 } else nil,
			runs = tern.json.array(runs),
			logs = tern.json.array(table.move(logs[id] or {}, 1, #(logs[id] or {}), 1, {})),
		})
	end
	return tern.json.encode({
		generated_at = t,
		run = run.id,
		target = run.evolve_target,
		target_run = run.evolve_run,
		workflows = tern.json.array(table.move(ids, 1, #ids, 1, {})),
		libraries = tern.json.array(table.move(libs, 1, #libs, 1, {})),
		targets = tern.json.array(targets),
	})
end

-- What an evolver's run may leave for people: improvements its edit/ can't make.
M.SUGGESTIONS = "suggestions.md"
local MAX_SUGGESTIONS = 256 * 1024
local SUGGESTION_CHARS = 8000
local PAST_SUGGESTIONS = 10

-- Keys whose values never leave roost.toml: credentials, and `env` tables (they carry tokens).
local function secret_key(key: string): boolean
	local k = string.lower(key)
	for _, word in { "token", "secret", "password", "passwd", "credential", "key", "auth", "env" } do
		if string.find(k, word, 1, true) then
			return true
		end
	end
	return false
end

-- Bracket depth after `s`, starting from `depth`: `[`/`{` open, `]`/`}` close; brackets inside
-- one-line strings and after a `#` comment don't count.
local function bracket_depth(s: string, depth: number): number
	local i, n = 1, #s
	while i <= n do
		local c = string.byte(s, i)
		if c == 34 or c == 39 then -- " '
			local j = i + 1
			while j <= n do
				local d = string.byte(s, j)
				if d == 92 and c == 34 then -- \ escapes inside "…"
					j += 2
				elseif d == c then
					break
				else
					j += 1
				end
			end
			i = j + 1
		elseif c == 35 then -- #
			break
		else
			if c == 91 or c == 123 then
				depth += 1
			elseif c == 93 or c == 125 then
				depth -= 1
			end
			i += 1
		end
	end
	return depth
end

-- roost.toml with every secret value (commented-out ones too, multi-line ones whole, all of an
-- `env` section) replaced, line by line, and credentials in URLs (`scheme://user:pw@`) masked.
function M.redact(text: string): string
	local out: { string } = {}
	local in_env = false
	local quote: string? = nil -- a hidden multi-line string still open
	local depth = 0 -- a hidden multi-line array or table still open
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		if quote then
			if string.find(line, quote, 1, true) then
				quote = nil
			end
			continue
		elseif depth > 0 then
			depth = bracket_depth(line, depth)
			continue
		end
		local header = string.match(line, "^%s*%[+%s*([^%]]+)%]")
		if header then
			in_env = secret_key(header)
			table.insert(out, line)
			continue
		end
		local lead, key, value = string.match(line, "^(%s*#?%s*)([%w_%-\"'%.]+)%s*=%s*(.*)$")
		if key and (in_env or secret_key(key)) then
			table.insert(out, `{lead}{key} = "<已隐藏>"`)
			local v = value or ""
			local q = string.sub(v, 1, 3)
			if (q == '"""' or q == "'''") and not string.find(v, q, 4, true) then
				quote = q
			else
				depth = math.max(bracket_depth(v, 0), 0)
			end
		else
			table.insert(out, (string.gsub(line, "(%a[%w+.-]*://)[^/%s\"'@]+@", "%1<已隐藏>@")))
		end
	end
	if out[#out] == "" then
		table.remove(out)
	end
	return table.concat(out, "\n") .. "\n"
end

local function repos_md(w: model.Workflows): string
	local out: { string } = { "# 仓库与本机检出", "", "| 仓库 | 本机路径 | 分支 | worktree |", "|---|---|---|---|" }
	for _, name in util.keys(w.repos) do
		local r = w.repos[name]
		table.insert(out, `| {name} | {r.path or "(临时目录)"} | {r.branch or "默认"} | {if r.worktree then "是" else "否"} |`)
	end
	if #out == 4 then
		table.insert(out, "| (没有声明仓库) | | | |")
	end
	return table.concat(out, "\n") .. "\n"
end

-- The suggestions file of finished run `id`, trimmed (and clipped), or nil when there is none (or it
-- is empty); one too big to read says so instead of vanishing.
function M.suggestions(s: store.Store, id: string): string?
	local path = `{M.dir(store.run_dir(s, id))}/{M.SUGGESTIONS}`
	local ok, text = pcall(tern.fs.read, path, MAX_SUGGESTIONS)
	if not ok or type(text) ~= "string" then
		local ok2, there = pcall(tern.fs.exists, path)
		return if ok2 and there then `{M.SUGGESTIONS} 超过 {MAX_SUGGESTIONS // 1024} KiB,没有读取:{path}` else nil
	end
	-- Trimmed by scanning, not by a `%s*$` pattern: that is quadratic on long blank runs, and the
	-- agent that writes this file reads untrusted text.
	local first = string.find(text, "%S")
	if first == nil then
		return nil
	end
	local last = #text
	while last > first do
		local b = string.byte(text, last)
		if b ~= 32 and (b < 9 or b > 13) then
			break
		end
		last -= 1
	end
	local t = string.sub(text, first, last)
	if utf8.len(t) == nil then
		return nil
	end
	return util.clip(t, SUGGESTION_CHARS)
end

local function evolved(r: Run): boolean
	for _, s in r.steps do
		if s.kind == "evolve" then
			return true
		end
	end
	return false
end

-- Suggestions earlier evolver runs (successful ones: those were reported) made, newest first.
local function past_suggestions(h: Host, run: Run): string
	local out: { string } = { "# 近期已提出的建议", "" }
	local n, scanned = 0, 0
	for i = #h.store.runs, 1, -1 do
		local r = h.store.runs[i]
		if n >= PAST_SUGGESTIONS or scanned >= 200 then
			break
		end
		if r.id ~= run.id and r.state == "success" and evolved(r) then
			scanned += 1
			local text = M.suggestions(h.store, r.id)
			if text then
				n += 1
				table.insert(out, `## 运行 {r.id}({util.clock(r.started_at or r.created_at)})`)
				table.insert(out, "")
				table.insert(out, util.clip(text, 3000))
				table.insert(out, "")
			end
		end
	end
	if n == 0 then
		table.insert(out, "(无)")
	end
	return table.concat(out, "\n") .. "\n"
end

-- Reads roost.toml (at most 256 KiB); nil when absent or unreadable.
local function roost_toml(data: string): string?
	local ok, text = pcall(tern.fs.read, `{data}/roost.toml`, 256 * 1024)
	return if ok and type(text) == "string" then text else nil
end

-- An evolver's successful run left suggestions: they go into its log and a notice.
function M.report(h: Host, run: Run, name: string)
	local text = M.suggestions(h.store, run.id)
	if text == nil then
		return
	end
	local lines: { string } = { "[roost] 改进建议(需要人处理):" }
	local count = 0
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		if count >= 200 then
			table.insert(lines, "[roost] ……(其余见 evolve/suggestions.md)")
			break
		end
		table.insert(lines, "  " .. line)
		count += 1
	end
	h.log(run.id, lines)
	h.notice("info", `{name} 提出了改进建议:{util.clip(util.first_line(text), 80)}(运行 {run.id})`)
end

-- Writes run `run`'s material (for evolver `wf`) and returns the log tails still to copy, as
-- destination/source pairs, or why it couldn't.
function M.prepare(h: Host, b: Book, run: Run, wf: Workflow): ({ string }, string?)
	local w = h.workflows()
	if w == nil or not h.valid() then
		return {}, "workflows.toml 有错误,无法准备迭代材料"
	end
	local all = M.scope(w, wf, run.evolve_target)
	if #all == 0 then
		return {}, "evolve 范围内没有可迭代的工作流"
	end
	-- Targets in order while the material stays within MAX_MATERIAL, then the libraries they alone use.
	local snap: Snapshot = { workflows = {}, libs = {} }
	local ids: { string } = {}
	local total = 0
	for _, id in all do
		local one, err = current(h, { id }, {})
		if one == nil then
			return {}, err
		end
		local entry = one.workflows[id]
		local size = #entry.toml + tree_size(entry.files)
		if #ids > 0 and total + size > M.MAX_MATERIAL then
			break
		end
		total += size
		table.insert(ids, id)
		snap.workflows[id] = entry
	end
	local libs: { string } = {}
	for _, l in owned_libs(w, ids) do
		local one, err = current(h, {}, { l })
		if one == nil then
			return {}, err
		end
		local size = tree_size(one.libs[l])
		if total + size <= M.MAX_MATERIAL then
			total += size
			table.insert(libs, l)
			snap.libs[l] = one.libs[l]
		end
	end
	local dir = M.dir(store.run_dir(h.store, run.id))
	local werr = write_snapshot(`{dir}/base`, snap) or write_snapshot(`{dir}/edit`, snap)
	if werr then
		return {}, `无法写入迭代材料:{werr}`
	end
	-- Log tails: the run that triggered this first, then each target's latest failures.
	local pairs_: { string } = {}
	local logs: { [string]: { string } } = {}
	local taken: { [string]: boolean } = {}
	local function take(id: string, rid: string)
		if taken[rid] then
			return
		end
		local src = `{store.run_dir(h.store, rid)}/log.txt`
		if not tern.fs.exists(src) then
			return
		end
		taken[rid] = true
		logs[id] = logs[id] or {}
		table.insert(logs[id], rid)
		table.insert(pairs_, `{dir}/logs/{rid}.txt`)
		table.insert(pairs_, src)
	end
	if run.evolve_target and run.evolve_run then
		take(run.evolve_target, run.evolve_run)
	end
	for _, id in ids do
		local n = 0
		for _, r in recent(h.store, id, M.RECENT, nil) do
			if n >= M.LOGS_PER_TARGET then
				break
			end
			if M.BAD[r.state] then
				take(id, r.id)
				n += 1
			end
		end
	end
	local lines: { string } = {}
	for _, id in ids do
		table.insert(lines, `- {w.by_id[id].name}(\`{id}\`)`)
	end
	local ok, ferr = pcall(function(): string?
		tern.fs.mkdir(`{dir}/logs`)
		tern.fs.mkdir(`{dir}/context`)
		local list = table.concat(lines, "\n")
		local readme = string.gsub(README, "<目标>", function(): string
			return list
		end)
		tern.fs.write(`{dir}/README.md`, readme)
		tern.fs.write(`{dir}/digest.md`, digest_md(h, b, run, ids, w, logs))
		tern.fs.write(`{dir}/digest.json`, digest_json(h, run, ids, libs, logs))
		local rt = roost_toml(h.data)
		tern.fs.write(`{dir}/context/roost.toml`, if rt then M.redact(rt) else "# 没有 roost.toml\n")
		tern.fs.write(`{dir}/context/repos.md`, repos_md(w))
		tern.fs.write(`{dir}/context/suggestions.md`, past_suggestions(h, run))
		tern.fs.write(
			`{dir}/scope.json`,
			tern.json.encode({
				workflows = tern.json.array(table.move(ids, 1, #ids, 1, {})),
				libs = tern.json.array(table.move(libs, 1, #libs, 1, {})),
			})
		)
		return nil
	end)
	if not ok then
		return {}, `无法写入迭代材料:{ferr}`
	end
	return pairs_, nil
end

-- ---------------------------------------------------------------------------------------------
-- Applying and undoing

-- `disk` restricted to the paths `a` or `b` name: the base an undo writes against, so a half
-- written item (some files already `to`, some still `from`) is put right, and a file neither
-- side knows (added meanwhile) is left alone.
local function known_base(disk: { [string]: string }, a: { [string]: string }, b: { [string]: string }): { [string]: string }
	local out: { [string]: string } = {}
	for rel, text in disk do
		if a[rel] ~= nil or b[rel] ~= nil then
			out[rel] = text
		end
	end
	return out
end

-- Saves `to` over what `from` describes, for `ids` and `libs` (libraries first: a workflow may
-- start using a new library file). Returns what it touched (the item that failed included: it
-- may be half written) and the first error. `best_effort` (undoing) writes against what is on
-- disk now instead of `from`, goes on past errors and returns them all.
local function put(
	h: Host,
	ids: { string },
	libs: { string },
	from: Snapshot,
	to: Snapshot,
	best_effort: boolean?
): ({ string }, { string }, string?)
	local done_libs: { string } = {}
	local done_wfs: { string } = {}
	local errs: { string } = {}
	for _, l in libs do
		table.insert(done_libs, l)
		local base = from.libs[l]
		if best_effort then
			local now_ = current(h, {}, { l })
			base = if now_ then known_base(now_.libs[l], from.libs[l], to.libs[l]) else base
		end
		local err = h.save_library(l, to.libs[l], base)
		if err then
			table.insert(errs, `文件库 {l}:{err}`)
			if not best_effort then
				return done_wfs, done_libs, errs[1]
			end
		end
	end
	for _, id in ids do
		local w = to.workflows[id]
		local was = from.workflows[id]
		if best_effort then
			local now_ = current(h, { id }, {})
			if now_ then
				local d = now_.workflows[id]
				was = { toml = d.toml, files = known_base(d.files, was.files, w.files) }
			end
		end
		local err: string?
		table.insert(done_wfs, id)
		if w.toml == was.toml then
			-- Only files changed: leave the block (and the comments in it) as written.
			err = h.save_files(id, w.files, was.files)
		else
			local raw = model.raw_workflow(w.toml, id)
			err = if raw then h.save_workflow(id, raw, w.files, was.files) else `workflow.toml 里没有 id = "{id}" 的 [[workflow]]`
		end
		if err then
			table.insert(errs, `{id}:{err}`)
			if not best_effort then
				return done_wfs, done_libs, errs[1]
			end
		end
	end
	return done_wfs, done_libs, if #errs > 0 then table.concat(errs, ";") else nil
end

-- Runs of each watched workflow before `at`: the rate a revision is judged against.
local function baseline(s: store.Store, watch: { string }, at: number): { [string]: Count }
	local out: { [string]: Count } = {}
	for _, id in watch do
		local c: Count = { runs = 0, bad = 0 }
		for _, r in recent(s, id, BASELINE_RUNS, at + 1) do
			c.runs += 1
			if M.BAD[r.state] then
				c.bad += 1
			end
		end
		out[id] = c
	end
	return out
end

-- Drops the oldest revisions beyond MAX_REVISIONS, with their snapshots.
local function trim(h: Host, b: Book)
	while #b.revs > M.MAX_REVISIONS do
		local old = table.remove(b.revs, 1) :: Revision
		h.discard(M.rev_dir(h.data, old.n))
	end
end

-- After evolver run `run` succeeded: applies what its edit/ changed. Returns the lines for its log.
function M.apply(h: Host, b: Book, run: Run): { string }
	local dir = M.dir(store.run_dir(h.store, run.id))
	local okr, scope_text = pcall(tern.fs.read, `{dir}/scope.json`, 64 * 1024)
	if not okr then
		return {}
	end
	local okd, scope = pcall(tern.json.decode, scope_text :: string)
	if not okd or type(scope) ~= "table" then
		return { "[roost] 迭代材料的 scope.json 读不出,没有应用任何改动" }
	end
	if not h.valid() then
		return { "[roost] workflows.toml 现在有错误,迭代改动没有应用" }
	end
	-- What the material lists is only a hint the agent could have edited: keep the workflows this
	-- evolver may change now, and the libraries only those use.
	local w0 = h.workflows() :: model.Workflows
	local self = w0.by_id[run.workflow]
	if self == nil or self.evolve == nil then
		return { "[roost] 这个工作流已不再迭代别的工作流,改动没有应用" }
	end
	local allowed: { [string]: boolean } = {}
	for _, id in model.evolve_targets(w0, self) do
		allowed[id] = true
	end
	local ids: { string } = {}
	for _, id in strings(scope.workflows) do
		if allowed[id] and table.find(ids, id) == nil then
			table.insert(ids, id)
		end
	end
	local owned: { [string]: boolean } = {}
	for _, l in owned_libs(w0, ids) do
		owned[l] = true
	end
	local libs: { string } = {}
	for _, l in strings(scope.libs) do
		if owned[l] and table.find(libs, l) == nil then
			table.insert(libs, l)
		end
	end
	local base, berr = read_snapshot(`{dir}/base`, ids, libs)
	local edit, eerr = read_snapshot(`{dir}/edit`, ids, libs)
	local cur, cerr = current(h, ids, libs)
	if base == nil or edit == nil or cur == nil then
		return { `[roost] 读不到迭代材料,没有应用:{berr or eerr or cerr or "?"}` }
	end
	local lines: { string } = {}
	local before: Snapshot = { workflows = {}, libs = {} }
	local after: Snapshot = { workflows = {}, libs = {} }
	local changed: { string } = {}
	local changed_libs: { string } = {}
	for _, id in ids do
		local bw, ew, cw = base.workflows[id], edit.workflows[id], cur.workflows[id]
		local etoml = block_of(ew.toml, id)
		if ew.toml == bw.toml and same_tree(ew.files, bw.files) then
			continue
		elseif etoml == nil then
			table.insert(lines, `[roost] 跳过 {id}:edit/workflows/{id}/workflow.toml 里没有 id = "{id}" 的 [[workflow]]`)
		elseif (model.raw_workflow(ew.toml, id) :: any).evolve ~= nil then
			table.insert(lines, `[roost] 跳过 {id}:被迭代的工作流不能加 evolve`)
		elseif cw.toml ~= bw.toml or not same_tree(cw.files, bw.files) then
			table.insert(lines, `[roost] 跳过 {id}:运行期间它被别处改动过`)
		elseif etoml == bw.toml and same_tree(ew.files, bw.files) then
			continue
		else
			local bad = files.check(ew.files)
			if bad then
				table.insert(lines, `[roost] 跳过 {id}:{bad}`)
			else
				table.insert(changed, id)
				before.workflows[id] = bw
				after.workflows[id] = { toml = etoml :: string, files = ew.files }
			end
		end
	end
	for _, l in libs do
		local bl, el, cl = base.libs[l], edit.libs[l], cur.libs[l]
		if same_tree(el, bl) then
			continue
		elseif not same_tree(cl, bl) then
			table.insert(lines, `[roost] 跳过文件库 {l}:运行期间它被别处改动过`)
		else
			local bad = files.check(el)
			if bad then
				table.insert(lines, `[roost] 跳过文件库 {l}:{bad}`)
			else
				table.insert(changed_libs, l)
				before.libs[l] = bl
				after.libs[l] = el
			end
		end
	end
	if #changed == 0 and #changed_libs == 0 then
		table.insert(lines, "[roost] 迭代没有产生可应用的改动")
		return lines
	end
	local t = h.now()
	local n = b.next
	local rdir = M.rev_dir(h.data, n)
	-- Taken before anything is written: a number whose directory is being discarded is never reused.
	b.next = n + 1
	M.save(b)
	local serr = write_snapshot(`{rdir}/before`, before) or write_snapshot(`{rdir}/after`, after)
	if serr then
		h.discard(rdir)
		table.insert(lines, `[roost] 无法保存修订快照,没有应用:{serr}`)
		return lines
	end
	-- Watched: the changed workflows, and every workflow in scope using a changed library.
	local watch: { string } = table.clone(changed)
	local w = h.workflows()
	if w then
		for _, id in ids do
			local wf = w.by_id[id]
			if wf and table.find(watch, id) == nil then
				for _, l in changed_libs do
					if table.find(wf.libs, l) then
						table.insert(watch, id)
						break
					end
				end
			end
		end
	end
	local rev: Revision = {
		n = n,
		at = t,
		run = run.id,
		reviewer = run.workflow,
		workflows = changed,
		libs = changed_libs,
		watch = watch,
		-- Recorded before the first write: a host that dies part way finds it at start (M.recover).
		state = "applying",
		baseline = baseline(h.store, watch, t),
		seen = {},
	}
	table.insert(b.revs, rev)
	local record_err = M.save(b)
	if record_err then
		-- Without the record a cut-off apply couldn't be undone: don't start.
		table.remove(b.revs)
		h.discard(rdir)
		table.insert(lines, `[roost] 无法记录修订,没有应用:{record_err}`)
		return lines
	end
	local done_wfs, done_libs, perr = put(h, changed, changed_libs, before, after)
	if perr == nil then
		-- A library change must leave every workflow using it valid (its file steps still find
		-- their files).
		for _, id in watch do
			local bad = h.check(id)
			if bad then
				perr = `{id}:{bad}`
				break
			end
		end
	end
	if perr then
		local _, _, uerr = put(h, done_wfs, done_libs, after, before, true)
		rev.state = "failed"
		rev.ended_at = t
		rev.note = `应用失败:{perr}` .. (if uerr then `;撤销时出错:{uerr}` else "")
		table.insert(lines, `[roost] 修订 #{n} {rev.note}`)
		h.notice("error", `Roost 迭代修订 #{n} {rev.note}`)
	else
		rev.state = "watching"
		-- Older revisions of the same workflows can no longer be undone on their own.
		for _, old in b.revs do
			if old ~= rev and old.state == "watching" then
				for _, id in old.watch do
					if table.find(watch, id) then
						old.state = "superseded"
						old.ended_at = t
						old.note = `被修订 #{n} 取代`
						break
					end
				end
			end
		end
		local what: { string } = table.clone(changed)
		for _, l in changed_libs do
			table.insert(what, `@{l}`)
		end
		table.insert(lines, `[roost] 已应用修订 #{n}:{table.concat(what, "、")};之后的运行会被观察,变差就自动回滚`)
		h.notice("success", `Roost 迭代已应用修订 #{n}:{table.concat(what, "、")}`)
	end
	trim(h, b)
	M.save(b)
	return lines
end

-- At start: a revision still "applying" was cut off part way (a reload or a budget abort): put
-- back what it may have written, and mark it failed.
function M.recover(h: Host, b: Book)
	local dirty = false
	for _, rev in b.revs do
		if rev.state ~= "applying" then
			continue
		end
		dirty = true
		local rdir = M.rev_dir(h.data, rev.n)
		local before = read_snapshot(`{rdir}/before`, rev.workflows, rev.libs)
		local after = read_snapshot(`{rdir}/after`, rev.workflows, rev.libs)
		local uerr: string? = "读不到修订快照"
		if before and after then
			local _, _, e = put(h, rev.workflows, rev.libs, after, before, true)
			uerr = e
		end
		rev.state = "failed"
		rev.ended_at = h.now()
		rev.note = "应用时被打断,已撤销" .. (if uerr then `(撤销时出错:{uerr})` else "")
		h.notice("error", `Roost 迭代修订 #{rev.n} {rev.note}`)
	end
	if dirty then
		M.save(b)
	end
end

-- Undoes revision `n`: what it changed goes back to its before snapshot, unless something changed
-- it again since. Returns nil, or why not.
function M.rollback(h: Host, b: Book, n: number, why: string): string?
	local rev = find(b, n)
	if rev == nil then
		return `没有修订 #{n}`
	elseif rev.state ~= "watching" and rev.state ~= "kept" then
		return `修订 #{n} 的状态是 {rev.state},不能回滚`
	elseif not h.valid() then
		return "workflows.toml 现在有错误,修好后再回滚"
	end
	local rdir = M.rev_dir(h.data, n)
	local before, berr = read_snapshot(`{rdir}/before`, rev.workflows, rev.libs)
	local after, aerr = read_snapshot(`{rdir}/after`, rev.workflows, rev.libs)
	local cur, cerr = current(h, rev.workflows, rev.libs)
	if before == nil or after == nil or cur == nil then
		return `读不到修订快照:{berr or aerr or cerr or "?"}`
	end
	for _, id in rev.workflows do
		local cw, aw = cur.workflows[id], after.workflows[id]
		if cw.toml ~= aw.toml or not same_tree(cw.files, aw.files) then
			return `{id} 在修订之后又被改动过,不能自动回滚`
		end
	end
	for _, l in rev.libs do
		if not same_tree(cur.libs[l], after.libs[l]) then
			return `文件库 {l} 在修订之后又被改动过,不能自动回滚`
		end
	end
	local done_wfs, done_libs, perr = put(h, rev.workflows, rev.libs, after, before)
	if perr then
		-- Half undone is worse than not at all: put back what was undone (the failed one included).
		local _, _, rerr = put(h, done_wfs, done_libs, before, after, true)
		return `回滚失败:{perr}` .. (if rerr then `;恢复时出错:{rerr}` else "")
	end
	rev.state = "rolled_back"
	rev.ended_at = h.now()
	rev.note = why
	M.save(b)
	return nil
end

-- A finished run of a watched workflow counts toward its revisions; returns the workflows whose
-- revision this undid.
function M.observe(h: Host, b: Book, run: Run): { string }
	if not store.TERMINAL[run.state] or IGNORED[run.state] then
		return {}
	end
	local started = run.started_at or run.created_at
	local rolled: { string } = {}
	local dirty = false
	for _, rev in table.clone(b.revs) do
		if rev.state ~= "watching" or table.find(rev.watch, run.workflow) == nil or started < rev.at then
			continue
		end
		local c = rev.seen[run.workflow] or { runs = 0, bad = 0 }
		c.runs += 1
		if M.BAD[run.state] then
			c.bad += 1
		end
		rev.seen[run.workflow] = c
		dirty = true
		local worse: string? = nil
		local settled = true
		for _, id in rev.watch do
			local s = rev.seen[id] or { runs = 0, bad = 0 }
			local base = rev.baseline[id] or { runs = 0, bad = 0 }
			local before_rate = if base.runs > 0 then base.bad / base.runs else 0
			if s.bad >= M.ROLLBACK_BAD and s.runs > 0 and s.bad / s.runs > before_rate + M.ROLLBACK_MARGIN then
				worse = id
			end
			settled = settled and s.runs >= M.WATCH_RUNS
		end
		if worse then
			local s = rev.seen[worse] :: Count
			local why = `{worse} 修订后 {s.runs} 次运行失败 {s.bad} 次,比修订前差`
			local err = M.rollback(h, b, rev.n, `自动回滚:{why}`)
			if err then
				rev.state = "kept"
				rev.ended_at = h.now()
				rev.note = `应该回滚({why}),但没有回滚:{err}`
				h.notice("error", `Roost 迭代修订 #{rev.n} {rev.note}`)
			else
				h.notice("warning", `Roost 已自动回滚迭代修订 #{rev.n}:{why}`)
				h.log(rev.run, { `[roost] 修订 #{rev.n} 已自动回滚:{why}` })
				for _, id in rev.workflows do
					table.insert(rolled, id)
				end
				for _, id in rev.watch do
					if table.find(rolled, id) == nil then
						table.insert(rolled, id)
					end
				end
			end
		elseif settled then
			rev.state = "kept"
			rev.ended_at = h.now()
			rev.note = "观察期内没有变差"
		end
	end
	if dirty then
		M.save(b)
	end
	return rolled
end

-- Revisions watched for longer than WATCH_AGE are kept.
function M.expire(h: Host, b: Book)
	local t = h.now()
	local dirty = false
	for _, rev in b.revs do
		if rev.state == "watching" and t - rev.at >= M.WATCH_AGE then
			rev.state = "kept"
			rev.ended_at = t
			rev.note = "观察期结束"
			dirty = true
		end
	end
	if dirty then
		M.save(b)
	end
end

-- ---------------------------------------------------------------------------------------------
-- Firing

local function day_start(t: number): number
	local d = os.date("*t", t) :: any
	d.hour, d.min, d.sec, d.isdst = 0, 0, 0, nil
	return os.time(d)
end

export type Fire = { workflow: Workflow, target: string, run: string, detail: string }

-- Whether run `id` falls in a `sample` percent spot check: the same run always answers the same.
function M.sampled(id: string, sample: number): boolean
	if sample >= 100 then
		return true
	end
	local h = 5381
	for i = 1, #id do
		h = (h * 33 + string.byte(id, i)) % 2147483647
	end
	return h % 100 < sample
end

-- Whether workflow `id` has a run queued or running.
local function busy(s: store.Store, id: string): boolean
	for _, r in s.runs do
		if r.workflow == id and (r.state == "queued" or r.state == "running") then
			return true
		end
	end
	return false
end

-- The evolvers a finished run of a target starts: a bad run through `run_failed` triggers (their
-- streak), a successful one through `run_succeeded` (sampled, and only while that evolver is idle:
-- a spot check is never worth a queued or skipped run). Both honour the cooldown and the daily cap
-- (recorded in the book as fired).
function M.fire(h: Host, b: Book, run: Run): { Fire }
	local out: { Fire } = {}
	local w = h.workflows()
	local bad = M.BAD[run.state] == true
	if not bad and run.state ~= "success" or w == nil then
		return out
	end
	local target = w.by_id[run.workflow]
	if target == nil or target.evolve ~= nil then
		return out
	end
	local streak = 0
	if bad then
		for _, r in recent(h.store, target.id, 20, nil) do
			if not M.BAD[r.state] then
				break
			end
			streak += 1
		end
	end
	local t = h.now()
	local today = day_start(t)
	local dirty = false
	for _, wf in w.list do
		if not wf.enabled or wf.evolve == nil or table.find(model.evolve_targets(w, wf), target.id) == nil then
			continue
		end
		for _, tr in wf.triggers do
			if tr.kind ~= "roost" then
				continue
			end
			local rt = tr :: model.RoostTrigger
			if #rt.workflows > 0 and table.find(rt.workflows, target.id) == nil then
				continue
			end
			if bad then
				if rt.on ~= "run_failed" or streak < rt.streak then
					continue
				end
			elseif rt.on ~= "run_succeeded" or not M.sampled(run.id, rt.sample) or busy(h.store, wf.id) then
				continue
			end
			-- Spot checks keep their own cooldown and cap: they never hold a failure's repair back.
			local key = if bad then `{wf.id}/{target.id}` else `{wf.id}/{target.id}/check`
			local day = if bad then wf.id else `{wf.id}/check`
			local d = b.day[day]
			if d == nil or d.start ~= today then
				d = { start = today, n = 0 }
				b.day[day] = d
			end
			local dd = d :: { start: number, n: number }
			if t - (b.last[key] or -math.huge) < M.COOLDOWN then
				if bad then
					h.log(run.id, { `[roost] {wf.name} 在冷却中({M.COOLDOWN // 60} 分钟内已为 {target.id} 触发过),这次不触发` })
				end
			elseif dd.n >= M.DAILY_FIRES then
				if bad then
					h.log(run.id, { `[roost] {wf.name} 今天已触发 {dd.n} 次,达到上限,这次不触发` })
				end
			else
				b.last[key] = t
				dd.n += 1
				dirty = true
				table.insert(out, {
					workflow = wf,
					target = target.id,
					run = run.id,
					detail = if not bad
						then `抽查 {target.id} 的成功运行`
						elseif streak > 1 then `{target.id} 连续 {streak} 次失败`
						else `{target.id} 失败`,
				})
			end
			break
		end
	end
	if dirty then
		M.save(b)
	end
	return out
end

return M
