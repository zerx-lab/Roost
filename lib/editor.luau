--!strict
-- Automation editor ("新建/编辑自动化"). ui.luau owns the block; this module owns the overlay.
-- Text fields are program-owned (lib/field.luau). Selects, switches, menus and dates are pointer-only.
-- Node ids under layer.editor are the contract the key handler and tests share:
--   body.triggers.tN.sentence.*, body.triggers.tN.card.*, body.prompt.stack.input,
--   body.prompt.bar.pmodel, body.steps.sN.*, body.files.*, body.prompt.when.input,
--   body.notify.row.sw, body.notify.row.reply, body.advanced.*, foot.save, foot.del, layer.discard.

local field = require("./field")
local model = require("./model")
local util = require("./util")
local core = require("./core")

local M = {}

local ROOT = "layer.editor"
local NAME_ID = ROOT .. ".body.head.name.input"
local PROMPT_ID = ROOT .. ".body.prompt.stack.input"
local DESC_ID = ROOT .. ".body.advanced.desc.input"
local ID_ID = ROOT .. ".body.advanced.id.input"
local TIMEOUT_ID = ROOT .. ".body.advanced.timeout.input"
local PROMPT_WHEN_ID = ROOT .. ".body.prompt.when.input"
local BUDGET_ID = ROOT .. ".body.advanced.budget.input"
local STATE_ID = ROOT .. ".body.advanced.state.input"
local LIBS_ADD_ID = ROOT .. ".body.advanced.libs.add"
local EVOLVE_ADD_ID = ROOT .. ".body.advanced.evolve.add"
local FILE_ADD_ID = ROOT .. ".body.files.add.input"
local FILE_REN_ID = ROOT .. ".body.files.ren.input"
local FILE_EDIT_ID = ROOT .. ".body.files.edit.input"
local FILE_MAX_LINES = 24
local CHECK_MS = 300

type Issue = model.Issue
type Buf = { [string]: field.Field }

type Editor = {
	mode: string,
	raw: { [string]: any },
	old_id: string?,
	focus: string?,
	buf: Buf,
	slots: { string },
	opens: { [string]: boolean },
	dirty: boolean,
	issues: { Issue },
	confirm_delete: boolean,
	-- Path of the workflow file whose delete button is armed (two clicks).
	confirm_file: string?,
	discard: boolean,
	advanced: boolean,
	custom_id: boolean,
	prompt_inserted: boolean,
	-- The step the 指令 box edits, by identity: switching another step to 指令 never makes it
	-- the prompt step.
	prompt: any,
	timer: any,
	suggest: { [string]: { string } },
	busy: boolean,
	-- Workflow's own files (path → text); new/renamed/deleted stay here until save.
	files: { [string]: string },
	-- The files as they were loaded: what save may remove, and the change check against the disk.
	files_base: { [string]: string },
	-- Why they could not be loaded; saving is refused rather than writing an empty set.
	files_error: string?,
	-- Currently selected own-file path, or nil.
	file_sel: string?,
	-- Which path FILE_EDIT_ID / FILE_REN_ID currently hold (so a reselect reseeds them).
	file_edit_for: string?,
	file_ren_for: string?,
	-- library name → sorted paths, refreshed when libs change.
	lib_cache: { [string]: { string } },
	-- Trigger index → a freshly made API token, shown once (only its SHA-256 goes into the file).
	api_tokens: { [number]: string },
}

local function N(kind: string, props: { [string]: any }, children: { any }?): any
	return tern.ui.node(kind, props, children)
end

local function join(parts: { string }): string
	return table.concat(parts, ".")
end

local function tid(i: number, ...: string): string
	return join({ ROOT, "body", "triggers", `t{i}`, ... })
end

local function sid(i: number, ...: string): string
	return join({ ROOT, "body", "steps", `s{i}`, ... })
end

local function ref_id(i: number): string
	return join({ ROOT, "body", "advanced", `ref{i}`, "input" })
end

local function pad(n: number): string
	return string.format("%02d", n)
end

local function deep_copy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out: { [any]: any } = {}
	for k, x in v do
		out[k] = deep_copy(x)
	end
	return out
end

local function today(): string
	local s = os.date("%Y-%m-%d")
	return if type(s) == "string" then s else "2026-01-01"
end

local function utf8_len(s: string): number
	return utf8.len(s) or #s
end

local function list_of(raw: { [string]: any }, key: string): { any }
	local v = raw[key]
	if type(v) ~= "table" then
		v = {}
		raw[key] = v
	end
	return v
end

local function steps_of(raw: { [string]: any }): { any }
	return list_of(raw, "step")
end

local function triggers_of(raw: { [string]: any }): { any }
	return list_of(raw, "trigger")
end

local TAB_KEYS = { "tab", "key", "command", "title", "keep", "focus" }

local function step_kind(step: any): string
	if type(step) ~= "table" then
		return "omp"
	end
	if type(step.tab) == "string" then
		return "tab"
	end
	if step.upgrade == true then
		return "upgrade"
	end
	if type(step.file) == "string" and type(step.omp) ~= "string" and type(step.run) ~= "string" then
		return "file"
	end
	if type(step.run) == "string" and type(step.omp) ~= "string" then
		return "run"
	end
	return "omp"
end

local function is_prompt_step(step: any): boolean
	return type(step) == "table" and type(step.omp) == "string"
end

-- Index of the editor's prompt step, or nil when it has none.
local function prompt_index(ed: Editor): number?
	if ed.prompt == nil then
		return nil
	end
	for i, step in steps_of(ed.raw) do
		if step == ed.prompt then
			return i
		end
	end
	return nil
end

local function prompt_step(ed: Editor): any?
	return if prompt_index(ed) then ed.prompt else nil
end

local function step_text(step: any): string
	if type(step) ~= "table" then
		return ""
	end
	local kind = step_kind(step)
	if kind == "run" then
		return if type(step.run) == "string" then step.run else ""
	elseif kind == "file" or kind == "tab" or kind == "upgrade" then
		return ""
	end
	return if type(step.omp) == "string" then step.omp else ""
end

local function args_text(step: any): string
	if type(step) ~= "table" or type(step.args) ~= "table" then
		return ""
	end
	local parts: { string } = {}
	for _, item in step.args do
		if type(item) == "string" then
			table.insert(parts, item)
		end
	end
	return table.concat(parts, " ")
end

local function parse_args(text: string): { string }?
	local out: { string } = {}
	for token in string.gmatch(text, "%S+") do
		table.insert(out, token)
	end
	return if #out == 0 then nil else out
end

local function file_lang(path: string): string
	local ext = string.match(path, "%.([%w]+)$")
	if ext == nil then
		return "text"
	end
	local low = string.lower(ext)
	if low == "py" then
		return "python"
	elseif low == "sh" or low == "bash" then
		return "bash"
	elseif low == "js" or low == "mjs" or low == "cjs" then
		return "javascript"
	end
	return "text"
end

local function sorted_file_paths(files: { [string]: string }): { string }
	local paths: { string } = {}
	for path in files do
		table.insert(paths, path)
	end
	table.sort(paths)
	return paths
end

local function str_list(v: any): { string }
	if type(v) ~= "table" then
		return {}
	end
	local out: { string } = {}
	for _, item in v do
		if type(item) == "string" then
			table.insert(out, item)
		end
	end
	return out
end

local function load_own_files(st: any, ed: Editor)
	ed.files = {}
	ed.files_base = {}
	ed.files_error = nil
	ed.file_sel = nil
	if ed.mode ~= "edit" or type(ed.old_id) ~= "string" then
		return
	end
	local tree, err = core.workflow_files(st.core, ed.old_id)
	if tree == nil then
		ed.files_error = err or "无法读取工作流文件"
		return
	end
	for path, text in tree.text do
		if type(path) == "string" and type(text) == "string" then
			ed.files[path] = text
			ed.files_base[path] = text
		end
	end
	local paths = sorted_file_paths(ed.files)
	ed.file_sel = paths[1]
end

-- Drop library path lists that are no longer in raw.libs; load any missing ones.
local function refresh_lib_cache(st: any, ed: Editor)
	local want: { [string]: boolean } = {}
	for _, name in str_list(ed.raw.libs) do
		want[name] = true
	end
	for name in ed.lib_cache do
		if not want[name] then
			ed.lib_cache[name] = nil
		end
	end
	for name in want do
		if ed.lib_cache[name] == nil then
			local tree = core.library_files(st.core, name)
			local paths: { string } = {}
			if tree and type(tree.paths) == "table" then
				for _, p in tree.paths do
					if type(p) == "string" then
						table.insert(paths, p)
					end
				end
			end
			ed.lib_cache[name] = paths
		end
	end
end

local function file_options(ed: Editor): { any }
	local opts: { any } = {}
	for _, path in sorted_file_paths(ed.files) do
		table.insert(opts, { value = path, label = path })
	end
	local libs = str_list(ed.raw.libs)
	table.sort(libs)
	for _, lib in libs do
		local paths: { string } = ed.lib_cache[lib] or {}
		for _, path in paths do
			local ref = `@{lib}/{path}`
			table.insert(opts, { value = ref, label = ref })
		end
	end
	return opts
end

local function ed_of(st: any): Editor?
	local ed = st.editor
	if type(ed) ~= "table" then
		return nil
	end
	return ed :: Editor
end

local function render(st: any)
	local cx = st.cx
	if type(cx) == "table" and type(cx.render) == "function" then
		cx:render()
	end
end

local function cancel_timer(ed: Editor)
	local timer = ed.timer
	if type(timer) == "table" and type(timer.cancel) == "function" then
		timer:cancel()
	end
	ed.timer = nil
end

local function touch(ed: Editor)
	ed.dirty = true
	ed.confirm_delete = false
	ed.confirm_file = nil
end

local function buf(ed: Editor, id: string): field.Field
	local f = ed.buf[id]
	if f then
		return f
	end
	local created: field.Field = { text = "", cursor = 0 }
	ed.buf[id] = created
	return created
end

local function seed(ed: Editor, id: string, text: string, lines: boolean?)
	local f = ed.buf[id]
	if f then
		return
	end
	ed.buf[id] = { text = text, cursor = utf8_len(text), lines = lines }
end

local function drop_prefix(ed: Editor, prefix: string)
	local dead: { string } = {}
	for id in ed.buf do
		if string.sub(id, 1, #prefix) == prefix then
			table.insert(dead, id)
		end
	end
	for _, id in dead do
		ed.buf[id] = nil
		ed.opens[id] = nil
	end
end

local function note_slot(ed: Editor, id: string)
	table.insert(ed.slots, id)
end

local function field_error(ed: Editor, pred: (string) -> boolean): string?
	for _, issue in ed.issues do
		if pred(issue.path) then
			return issue.message
		end
	end
	return nil
end

local function first_issue(ed: Editor): string?
	local issue = ed.issues[1]
	return if issue then issue.message else nil
end

local function needs_filter(tr: any): boolean
	if type(tr) ~= "table" or type(tr.github) ~= "string" then
		return false
	end
	local meta = model.kind(tr.github)
	if not meta then
		return false
	end
	for _, key in meta.filters do
		local f = model.FILTERS[key]
		if f and f.kind ~= "toggle" then
			local v = tr[key]
			if type(v) == "string" and v ~= "" then
				return false
			end
			if type(v) == "table" and #v > 0 then
				return false
			end
		end
	end
	return true
end

-- ---------------------------------------------------------------------------------------------
-- Sync. Buffers win over raw for fields the user can be typing in. Structural controls write
-- raw directly and never go through a buffer.

local function sync_name(ed: Editor)
	local f = ed.buf[NAME_ID]
	if f then
		ed.raw.name = f.text
	end
end

local function sync_id(ed: Editor)
	local f = ed.buf[ID_ID]
	if not f or not ed.custom_id then
		return
	end
	local id = util.trim(f.text)
	if ed.mode == "edit" and id == "" then
		ed.raw.id = ed.old_id
		return
	end
	ed.raw.id = if id == "" then nil else id
end

local function sync_text_field(ed: Editor, id: string, key: string)
	local f = ed.buf[id]
	if not f then
		return
	end
	local text = util.trim(f.text)
	ed.raw[key] = if text == "" then nil else text
end

local function when_text_of(step: any): string
	local w = step.when
	if type(w) == "string" then
		return w
	end
	return ""
end

-- Empty clears the condition; a missing buffer leaves a hand-written `when` alone.
local function apply_when(ed: Editor, step: any, id: string)
	if type(step) ~= "table" then
		return
	end
	local f = ed.buf[id]
	if not f then
		return
	end
	local text = util.trim(f.text)
	step.when = if text == "" then nil else text
end

local function budget_text(raw: any): string
	local v = raw.daily_budget
	if type(v) == "number" then
		return tostring(v)
	elseif type(v) == "string" then
		return v
	end
	return ""
end

-- A non-number stays a string so parse_workflows reports it; empty is "no budget".
local function sync_budget(ed: Editor)
	local f = ed.buf[BUDGET_ID]
	if not f then
		return
	end
	local text = util.trim(f.text)
	if text == "" then
		ed.raw.daily_budget = nil
		return
	end
	local n = tonumber(text)
	ed.raw.daily_budget = if n ~= nil then n else text
end

local function sync_steps(ed: Editor)
	local steps = steps_of(ed.raw)
	local prompt_at = prompt_index(ed)
	for i, step in steps do
		if i ~= prompt_at and type(step) == "table" then
			local name_f = ed.buf[sid(i, "name", "input")]
			if name_f then
				local name = util.trim(name_f.text)
				step.name = if name == "" then nil else name
			end
			local kind = step_kind(step)
			if kind == "file" then
				local args_f = ed.buf[sid(i, "args", "input")]
				-- Only a changed field is parsed: an argument holding a space would be split by the
				-- round trip through the one-line field even when nobody touched it.
				if args_f and args_f.text ~= args_text(step) then
					step.args = parse_args(args_f.text)
				end
			elseif kind == "tab" then
				local key_f = ed.buf[sid(i, "key", "input")]
				if key_f then
					step.key = util.trim(key_f.text)
				end
				if step.tab == "open" then
					local title_f = ed.buf[sid(i, "title", "input")]
					if title_f then
						local title = util.trim(title_f.text)
						step.title = if title == "" then nil else title
					end
					local cmd_f = ed.buf[sid(i, "command", "input")]
					if cmd_f then
						local command = util.trim(cmd_f.text)
						step.command = if command == "" then nil else command
					end
				else
					step.title, step.command, step.keep, step.focus = nil, nil, nil, nil
				end
			elseif kind == "run" or kind == "omp" then
				local text_f = ed.buf[sid(i, "text", "input")]
				if text_f then
					if kind == "run" then
						step.run = text_f.text
						step.omp = nil
					else
						step.omp = text_f.text
						step.run = nil
					end
				end
			end
			apply_when(ed, step, sid(i, "when", "input"))
		end
	end
end

local function sync_files(ed: Editor)
	local sel = ed.file_sel
	-- Only while the buffer holds this very file: after a delete or a switch it still holds
	-- the previous one's text.
	if type(sel) == "string" and ed.file_edit_for == sel and ed.files[sel] ~= nil then
		local f = ed.buf[FILE_EDIT_ID]
		if f then
			ed.files[sel] = f.text
		end
	end
end

local function sync_libs_state(ed: Editor)
	local state_f = ed.buf[STATE_ID]
	if state_f then
		local text = util.trim(state_f.text)
		ed.raw.state = if text == "" then nil else text
	end
end

local function sync_prompt(ed: Editor)
	local f = ed.buf[PROMPT_ID]
	local steps = steps_of(ed.raw)
	local idx = prompt_index(ed)
	if not f then
		if idx then
			apply_when(ed, steps[idx], PROMPT_WHEN_ID)
		end
		return
	end
	if f.text == "" then
		local step = if idx then steps[idx] else nil
		if idx and ed.prompt_inserted and step.model == nil then
			-- A prompt step the editor added and nothing else uses: take it back out.
			table.remove(steps, idx)
			ed.prompt, ed.prompt_inserted = nil, false
			drop_prefix(ed, ROOT .. ".body.steps.")
		elseif step then
			step.omp = ""
			apply_when(ed, step, PROMPT_WHEN_ID)
		end
		return
	end
	if not idx then
		local step = { name = "指令", omp = f.text }
		table.insert(steps, 1, step)
		ed.prompt, ed.prompt_inserted = step, true
		drop_prefix(ed, ROOT .. ".body.steps.")
		apply_when(ed, step, PROMPT_WHEN_ID)
		return
	end
	local step = steps[idx]
	step.omp = f.text
	step.run = nil
	apply_when(ed, step, PROMPT_WHEN_ID)
end

local function sync_triggers(ed: Editor)
	local triggers = triggers_of(ed.raw)
	for i, tr in triggers do
		if type(tr) == "table" then
			if tr.schedule == "cron" then
				local f = ed.buf[tid(i, "sentence", "cron", "input")]
				if f then
					tr.cron = f.text
				end
			end
			local meta = if type(tr.github) == "string" then model.kind(tr.github) else nil
			local keys: { string } = if meta then meta.filters else {}
			for _, key in keys do
				local fm = model.FILTERS[key]
				local f = ed.buf[tid(i, "card", key, "text", "input")]
				if fm and fm.kind == "text" and f then
					local text = util.trim(f.text)
					tr[key] = if text == "" then nil else text
				end
			end
			local ref = ed.buf[ref_id(i)]
			if ref then
				local text = util.trim(ref.text)
				tr.ref = if text == "" then nil else text
			end
		end
	end
end

local function sync_all(ed: Editor)
	sync_name(ed)
	sync_steps(ed)
	sync_prompt(ed)
	sync_files(ed)
	sync_libs_state(ed)
	sync_text_field(ed, DESC_ID, "description")
	sync_text_field(ed, TIMEOUT_ID, "timeout")
	sync_budget(ed)
	sync_id(ed)
	sync_triggers(ed)
end

local function check_now(st: any)
	local ed = ed_of(st)
	if not ed then
		return
	end
	cancel_timer(ed)
	sync_all(ed)
	refresh_lib_cache(st, ed)
	ed.issues = core.check_workflow(st.core, ed.old_id, ed.raw, ed.files)
	render(st)
end

local function schedule_check(st: any, ed: Editor)
	if ed.timer then
		return
	end
	ed.timer = tern.timer(CHECK_MS, function()
		ed.timer = nil
		if st.editor ~= ed then
			return
		end
		check_now(st)
	end)
end

-- ---------------------------------------------------------------------------------------------
-- Mutations.

-- Switching frequency keeps what the new kind also uses (time, days, …) and drops the rest, so
-- no key the new kind doesn't accept is left behind.
local function set_schedule(ed: Editor, i: number, kind: string)
	local triggers = triggers_of(ed.raw)
	local cur = triggers[i]
	local meta = model.schedule(kind)
	if type(cur) ~= "table" or not meta then
		return
	end
	local fresh = model.trigger_defaults(kind, os.time())
	for _, key in meta.keys do
		if cur[key] ~= nil then
			fresh[key] = cur[key]
		end
	end
	if kind == "once" and type(cur.time) == "string" and type(fresh.at) == "string" then
		fresh.at = string.sub(fresh.at, 1, 10) .. " " .. cur.time
	elseif type(cur.at) == "string" and table.find(meta.keys, "time") then
		fresh.time = string.match(cur.at, "(%d%d?:%d%d)$") or fresh.time
	end
	fresh.tz = cur.tz
	fresh.repo = cur.repo
	fresh.ref = cur.ref
	triggers[i] = fresh
	drop_prefix(ed, tid(i, ""))
	touch(ed)
end

local function add_trigger(ed: Editor, kind: string)
	local fresh = model.trigger_defaults(kind, os.time())
	if type(fresh.schedule) ~= "string" and type(fresh.github) ~= "string" then
		return
	end
	table.insert(triggers_of(ed.raw), fresh)
	touch(ed)
end

local function delete_trigger(ed: Editor, i: number)
	local triggers = triggers_of(ed.raw)
	if not triggers[i] then
		return
	end
	sync_all(ed)
	table.remove(triggers, i)
	drop_prefix(ed, ROOT .. ".body.triggers.")
	drop_prefix(ed, ROOT .. ".body.advanced.ref")
	touch(ed)
end

local function toggle_member(list: { string }, value: string): { string }
	local out: { string } = {}
	local had = false
	for _, item in list do
		if item == value then
			had = true
		else
			table.insert(out, item)
		end
	end
	if not had then
		table.insert(out, value)
	end
	return out
end

local function toggle_day(tr: any, did: string)
	local next_days = toggle_member(str_list(tr.days), did)
	tr.days = if #next_days == 0 then nil else next_days
end

local function add_chip(tr: any, key: string, value: string): boolean
	local text = util.trim(value)
	if text == "" then
		return false
	end
	local cur = str_list(tr[key])
	for _, item in cur do
		if string.lower(item) == string.lower(text) then
			return false
		end
	end
	table.insert(cur, text)
	tr[key] = cur
	return true
end

local function remove_chip(tr: any, key: string, index: number)
	local cur = str_list(tr[key])
	if not cur[index] then
		return
	end
	table.remove(cur, index)
	tr[key] = if #cur == 0 then nil else cur
end

local function toggle_choice(tr: any, key: string, value: string)
	local next_list = toggle_member(str_list(tr[key]), value)
	tr[key] = if #next_list == 0 then nil else next_list
end

local function ensure_prompt(ed: Editor): any
	local cur = prompt_step(ed)
	if cur then
		return cur
	end
	sync_all(ed)
	local synced = prompt_step(ed)
	if synced then
		return synced
	end
	local step = { name = "指令", omp = "" }
	table.insert(steps_of(ed.raw), 1, step)
	ed.prompt, ed.prompt_inserted = step, true
	drop_prefix(ed, ROOT .. ".body.steps.")
	return step
end

local function clear_named(step: any, keys: { string })
	for _, key in keys do
		step[key] = nil
	end
end

local function set_step_kind(ed: Editor, i: number, kind: string)
	local step = steps_of(ed.raw)[i]
	if type(step) ~= "table" or (kind ~= "omp" and kind ~= "run" and kind ~= "file" and kind ~= "tab" and kind ~= "upgrade") then
		return
	end
	local prev = step_kind(step)
	local text = step_text(step)
	step.kind = nil
	if kind == "tab" then
		step.tab = "open"
		step.key = if type(step.key) == "string" and step.key ~= "" then step.key else "main"
		step.upgrade = nil
		step.omp, step.run, step.file, step.model, step.args = nil, nil, nil, nil, nil
	elseif kind == "upgrade" then
		step.upgrade = true
		step.omp, step.run, step.file, step.model, step.args = nil, nil, nil, nil, nil
		clear_named(step, TAB_KEYS)
	elseif kind == "file" then
		clear_named(step, TAB_KEYS)
		step.upgrade = nil
		step.file = if type(step.file) == "string" then step.file else ""
		step.omp = nil
		step.run = nil
		step.model = nil
	elseif kind == "omp" then
		clear_named(step, TAB_KEYS)
		step.upgrade = nil
		step.omp = if prev == "file" or prev == "tab" or prev == "upgrade" then "" else text
		step.run = nil
		step.file = nil
		step.args = nil
	else
		clear_named(step, TAB_KEYS)
		step.upgrade = nil
		step.run = if prev == "file" or prev == "tab" or prev == "upgrade" then "" else text
		step.omp = nil
		step.file = nil
		step.model = nil
		step.args = nil
	end
	local f = ed.buf[sid(i, "text", "input")]
	if f then
		local blank = kind == "file" or kind == "tab" or kind == "upgrade" or prev == "file" or prev == "tab" or prev == "upgrade"
		f.text = if blank then "" else text
		f.lines = kind == "omp" or kind == "run"
	end
	if kind ~= "file" then
		ed.buf[sid(i, "args", "input")] = nil
	end
	local key_f = ed.buf[sid(i, "key", "input")]
	if key_f and kind == "tab" then
		key_f.text = if type(step.key) == "string" then step.key else "main"
	end
	touch(ed)
end

local function add_step(ed: Editor)
	table.insert(steps_of(ed.raw), { run = "", name = "命令" })
	touch(ed)
end

local function delete_step(ed: Editor, i: number)
	local target = steps_of(ed.raw)[i]
	if target == nil or target == ed.prompt then
		return
	end
	-- Syncing may insert or drop the prompt step at the top: find the clicked step again.
	sync_all(ed)
	local steps = steps_of(ed.raw)
	local j = table.find(steps, target)
	if j == nil or target == ed.prompt then
		return
	end
	table.remove(steps, j)
	drop_prefix(ed, ROOT .. ".body.steps.")
	touch(ed)
end

local function swap_steps(ed: Editor, i: number, j: number)
	local steps = steps_of(ed.raw)
	local prompt_at = prompt_index(ed)
	if not steps[i] or not steps[j] or i == prompt_at or j == prompt_at then
		return
	end
	steps[i], steps[j] = steps[j], steps[i]
	local function swap_buf(a: string, b: string)
		ed.buf[a], ed.buf[b] = ed.buf[b], ed.buf[a]
	end
	swap_buf(sid(i, "name", "input"), sid(j, "name", "input"))
	swap_buf(sid(i, "text", "input"), sid(j, "text", "input"))
	swap_buf(sid(i, "args", "input"), sid(j, "args", "input"))
	swap_buf(sid(i, "when", "input"), sid(j, "when", "input"))
	touch(ed)
end

-- ---------------------------------------------------------------------------------------------
-- Open / save / delete.

local function seed_open(ed: Editor)
	local raw = ed.raw
	seed(ed, NAME_ID, if type(raw.name) == "string" then raw.name else "")
	-- The 指令 box edits the first agent step; other steps stay in 更多步骤 whatever they become.
	for _, step in steps_of(raw) do
		if is_prompt_step(step) then
			ed.prompt = step
			break
		end
	end
	local prompt = prompt_step(ed)
	seed(ed, PROMPT_ID, if prompt then step_text(prompt) else "", true)
	-- A hand-written schedule from before `schedule` existed: show it as the cron it is.
	for _, tr in triggers_of(raw) do
		if type(tr) == "table" and tr.schedule == nil and tr.github == nil and tr.roost == nil and type(tr.cron) == "string" then
			tr.schedule = "cron"
		end
	end
	if ed.mode == "edit" then
		seed(ed, ID_ID, if type(raw.id) == "string" then raw.id else "")
	end
	seed(ed, DESC_ID, if type(raw.description) == "string" then raw.description else "")
	local timeout = raw.timeout
	seed(ed, TIMEOUT_ID, if type(timeout) == "string" then timeout elseif type(timeout) == "number" then tostring(timeout) else "")
	seed(ed, BUDGET_ID, budget_text(raw))
	seed(ed, PROMPT_WHEN_ID, if prompt then when_text_of(prompt) else "")
	seed(ed, STATE_ID, if type(raw.state) == "string" then raw.state else "")
	seed(ed, FILE_ADD_ID, "script.py")
	seed(ed, FILE_REN_ID, "")
	seed(ed, LIBS_ADD_ID, "")
end

function M.close(st: any)
	local ed = ed_of(st)
	if ed then
		cancel_timer(ed)
	end
	st.editor = nil
end

-- `draft`: a workflow table to start a new automation from (mode "draft", e.g. one generated from a
-- description); it opens like a template.
function M.open(st: any, mode: string, arg: string?, draft: { [string]: any }?)
	local prev = ed_of(st)
	if prev then
		cancel_timer(prev)
	end
	local raw: any = nil
	local old_id: string? = nil
	if mode == "edit" then
		raw = if arg then core.workflow_raw(st.core, arg) else nil
		if type(raw) ~= "table" then
			st.cx:toast("error", "没有这个工作流")
			return
		end
		old_id = arg
	elseif mode == "template" then
		for _, tpl in model.TEMPLATES do
			if tpl.id == arg then
				raw = deep_copy(tpl.raw)
				raw.id = nil
				break
			end
		end
		if type(raw) ~= "table" then
			st.cx:toast("error", "没有这个模板")
			return
		end
	elseif mode == "draft" and type(draft) == "table" then
		raw = deep_copy(draft)
		raw.id = nil
		mode = "template"
	else
		mode = "new"
		raw = model.new_raw(os.time())
	end
	local ed: Editor = {
		mode = mode,
		raw = raw,
		old_id = old_id,
		focus = NAME_ID,
		buf = {},
		slots = {},
		opens = {},
		dirty = false,
		issues = {},
		confirm_delete = false,
		confirm_file = nil,
		discard = false,
		advanced = false,
		custom_id = false,
		prompt_inserted = false,
		prompt = nil,
		timer = nil,
		suggest = {},
		busy = false,
		files = {},
		files_base = {},
		files_error = nil,
		file_sel = nil,
		file_edit_for = nil,
		file_ren_for = nil,
		lib_cache = {},
		api_tokens = {},
	}
	st.editor = ed
	load_own_files(st, ed)
	seed_open(ed)
	check_now(st)
	ed.focus = NAME_ID
	st.cx:frame({ { "focus", NAME_ID } })
end

local function save(st: any)
	local ed = ed_of(st)
	if not ed or ed.busy then
		return
	end
	sync_all(ed)
	if ed.files_error then
		ed.issues = { { file = "workflows.toml", path = "files", message = `工作流文件没有读出来,为避免覆盖已关闭保存:{ed.files_error}` } }
		render(st)
		return
	end
	ed.issues = core.check_workflow(st.core, ed.old_id, ed.raw, ed.files)
	if #ed.issues > 0 then
		render(st)
		return
	end
	ed.busy = true
	local issues = core.save_workflow(st.core, ed.old_id, ed.raw, ed.files, ed.files_base)
	ed.busy = false
	if issues == nil then
		M.close(st)
		st.cx:toast("success", "已保存")
		render(st)
		return
	end
	ed.issues = issues
	render(st)
end

local function delete_workflow(st: any)
	local ed = ed_of(st)
	if not ed or ed.mode ~= "edit" or type(ed.old_id) ~= "string" then
		return
	end
	if not ed.confirm_delete then
		ed.confirm_delete = true
		render(st)
		return
	end
	local err = core.delete_workflow(st.core, ed.old_id)
	if err then
		ed.confirm_delete = false
		st.cx:toast("error", "删除失败", err)
		render(st)
		return
	end
	M.close(st)
	st.cx:toast("success", "已删除")
	render(st)
end

-- ---------------------------------------------------------------------------------------------
-- View.

local function txt(text: string, key: string, tone: string?): any
	return N("text", { key = key, spans = { tern.ui.span(text, tone) } })
end

local function input_node(ed: Editor, id: string, props: { [string]: any }): any
	local f = buf(ed, id)
	note_slot(ed, id)
	props.text = f.text
	props.cursor = field.utf16_cursor(f)
	props.variant = props.variant or "field"
	return N("input", props)
end

local function editor_node(ed: Editor, id: string, props: { [string]: any }): any
	local f = buf(ed, id)
	f.lines = true
	note_slot(ed, id)
	props.text = f.text
	props.cursor = field.utf16_cursor(f)
	return N("editor", props)
end

local function select_node(ed: Editor, id: string, value: string, options: { any }): any
	local open = ed.opens[id] == true
	return N("select", { key = "sel", value = value, options = options, open = open })
end

local function with_current(options: { any }, value: string, label: string?): { any }
	for _, opt in options do
		if opt.value == value then
			return options
		end
	end
	local copy = { { value = value, label = label or value } }
	for _, opt in options do
		table.insert(copy, opt)
	end
	return copy
end

local function hour_options(current: string?): { any }
	local opts: { any } = {}
	for h = 0, 23 do
		local v = pad(h)
		table.insert(opts, { value = v, label = v })
	end
	return with_current(opts, if type(current) == "string" and current ~= "" then current else "09")
end

local function minute_options(current: string?): { any }
	local opts: { any } = {}
	for m = 0, 55, 5 do
		local v = pad(m)
		table.insert(opts, { value = v, label = v })
	end
	return with_current(opts, if type(current) == "string" and current ~= "" then current else "00")
end

-- Hour and minute of a schedule: `time`, or the clock part of a once trigger's `at`.
local function clock_parts(tr: any): (string, string)
	local time = if tr.schedule == "once" and type(tr.at) == "string" then string.match(tr.at, "(%d%d?:%d%d)$") else tr.time
	if type(time) ~= "string" then
		return "09", "00"
	end
	local h, m = string.match(time, "^(%d%d?):(%d%d?)")
	if not h or not m then
		return "09", "00"
	end
	return pad(tonumber(h) or 9), pad(tonumber(m) or 0)
end

-- The 日 一 … 六 toggle strip of a schedule's `days`.
local function days_strip(i: number, tr: any): any
	local on: { [string]: boolean } = {}
	for _, d in str_list(tr.days) do
		on[d] = true
	end
	local buttons: { any } = {}
	for _, day in model.DAYS do
		table.insert(buttons, N("button", {
			key = day.id,
			text = day.label,
			size = "sm",
			on = on[day.id] == true,
			actions = { click = `day:{i}:{day.id}` },
		}))
	end
	return N("buttons", { key = "days", label = "星期", size = "sm" }, buttons)
end

local function schedule_sentence(ed: Editor, i: number, tr: any): (any, string?)
	local kind = if type(tr.schedule) == "string" then tr.schedule else "daily"
	local freq: { any } = {}
	for _, sch in model.SCHEDULES do
		table.insert(freq, { value = sch.id, label = sch.label })
	end
	freq = with_current(freq, kind, kind)
	local children: { any } = {
		N("select", { key = "freq", value = kind, options = freq, open = ed.opens[tid(i, "sentence", "freq")] == true }),
	}
	local hour, minute = clock_parts(tr)
	local function time_selects()
		table.insert(children, txt("于", "at"))
		table.insert(children, N("select", {
			key = "hour",
			value = hour,
			options = hour_options(hour),
			open = ed.opens[tid(i, "sentence", "hour")] == true,
		}))
		table.insert(children, txt(":", "colon"))
		table.insert(children, N("select", {
			key = "minute",
			value = minute,
			options = minute_options(minute),
			open = ed.opens[tid(i, "sentence", "minute")] == true,
		}))
	end
	if kind == "hourly" then
		local between = tr.between
		local mode = if type(between) == "table" then "range" else "all"
		table.insert(children, txt("在", "zai"))
		table.insert(children, days_strip(i, tr))
		table.insert(children, N("select", {
			key = "span",
			value = mode,
			options = { { value = "all", label = "全天" }, { value = "range", label = "时段之间" } },
			open = ed.opens[tid(i, "sentence", "span")] == true,
		}))
		if mode == "range" then
			local function hour_of(v: any, default: string): string
				local h = if type(v) == "string" then tonumber(string.match(v, "^(%d%d?)")) else nil
				return if h then pad(h) else default
			end
			local sh = hour_of(between[1], "09")
			local eh = hour_of(between[2], "18")
			table.insert(children, N("select", {
				key = "sh",
				value = sh,
				options = hour_options(sh),
				open = ed.opens[tid(i, "sentence", "sh")] == true,
			}))
			table.insert(children, txt("–", "dash"))
			table.insert(children, N("select", {
				key = "eh",
				value = eh,
				options = hour_options(eh),
				open = ed.opens[tid(i, "sentence", "eh")] == true,
			}))
		end
	elseif kind == "weekly" then
		table.insert(children, txt("在", "zai"))
		table.insert(children, days_strip(i, tr))
		time_selects()
	elseif kind == "monthly" then
		table.insert(children, txt("在", "zai"))
		local day = tr.day
		local cur = if type(day) == "number" then tostring(day) else "1"
		local opts: { any } = {}
		for n = 1, 31 do
			table.insert(opts, { value = tostring(n), label = `第 {n} 天` })
		end
		table.insert(children, N("select", {
			key = "day",
			value = cur,
			options = with_current(opts, cur, `第 {cur} 天`),
			open = ed.opens[tid(i, "sentence", "day")] == true,
		}))
		time_selects()
	elseif kind == "yearly" or kind == "once" then
		table.insert(children, txt("在", "zai"))
		local stored = if kind == "once" then tr.at else tr.date
		local shown = if kind == "once" then string.sub(if type(stored) == "string" then stored else today(), 1, 10) else stored
		if kind == "yearly" then
			local md = if type(stored) == "string" then stored else "01-01"
			local m, d = string.match(md, "^(%d%d)%-(%d%d)$")
			shown = if m and d then `{string.sub(today(), 1, 4)}-{m}-{d}` else today()
		end
		table.insert(children, N("date", { key = "date", value = shown }))
		time_selects()
	elseif kind == "cron" then
		local cron_id = tid(i, "sentence", "cron", "input")
		seed(ed, cron_id, if type(tr.cron) == "string" then tr.cron else "")
		local err = field_error(ed, function(path)
			return string.find(path, `.trigger[{i}]`, 1, true) ~= nil
		end)
		table.insert(children, N("field", { key = "cron", error = err }, {
			input_node(ed, cron_id, { key = "input", placeholder = "0 9 * * 1-5", variant = "field" }),
		}))
	else
		time_selects()
	end
	table.insert(children, N("button", {
		key = "del",
		icon = "trash",
		text = "删除",
		title = "删除触发器",
		size = "sm",
		variant = "quiet",
		actions = { click = `trig-del:{i}` },
	}))
	local err = if kind ~= "cron"
		then field_error(ed, function(path)
			return string.find(path, `.trigger[{i}]`, 1, true) ~= nil
		end)
		else nil
	-- The error is the row's sibling, so the row (and its selects' ids) never moves.
	return N("row", { key = "sentence", role = "roost.trigger", gap = "sm", align = "center" }, children), err
end

local PEOPLE = { people = true, labels = true, branches = true, workflows = true }

local function first_repo(tr: any): string?
	local repos = tr.repos
	if type(repos) ~= "table" then
		return nil
	end
	local repo = repos[1]
	return if type(repo) == "string" and repo ~= "" then repo else nil
end

type KeyedFilter = {
	key: string,
	label: string,
	kind: "list" | "choice" | "text" | "toggle",
	suggest: string?,
	options: { model.Option }?,
	hint: string?,
	default: boolean?,
}

local function keyed_filter(key: string): KeyedFilter?
	local src = model.FILTERS[key]
	if not src then
		return nil
	end
	return {
		key = key,
		label = src.label,
		kind = src.kind,
		suggest = src.suggest,
		options = src.options,
		hint = src.hint,
		default = src.default,
	}
end

local function chip_row(st: any, ed: Editor, i: number, tr: any, f: KeyedFilter): any
	local values = str_list(tr[f.key])
	local chips: { any } = {}
	for j, item in values do
		table.insert(chips, N("button", {
			key = `c{j}`,
			text = `{item} ×`,
			size = "sm",
			tone = "accent",
			role = "roost.chip",
			title = `移除 {item}`,
			actions = { click = `cdel:{i}:{f.key}:{j}` },
		}))
	end
	local input_id = tid(i, "card", f.key, "add")
	seed(ed, input_id, "")
	local repo = first_repo(tr)
	local want_repo = PEOPLE[f.suggest or ""] == true
	local sug_key = `{i}:{f.key}`
	local items: { string } = {}
	local hint: string? = nil
	local err: string? = nil
	local loading = false
	if f.suggest and not (want_repo and not repo) then
		local gh = core.gh(st.core, f.suggest, repo)
		loading = gh.loading
		err = gh.error
		local query = buf(ed, input_id).text
		local q = string.lower(query)
		local seen: { [string]: boolean } = {}
		for _, item in values do
			seen[string.lower(item)] = true
		end
		for _, item in gh.items do
			local low = string.lower(item)
			if not seen[low] and (q == "" or string.find(low, q, 1, true)) then
				table.insert(items, item)
				if #items >= 8 then
					break
				end
			end
		end
	elseif want_repo and not repo then
		hint = "选择一个仓库以查看建议"
	end
	ed.suggest[sug_key] = items
	local status: any = nil
	if hint then
		status = txt(hint, "hint", "muted")
	elseif err then
		status = txt(err, "err", "warning")
	elseif loading and #items == 0 then
		status = txt("加载中…", "loading", "muted")
	end
	local sug: { any } = {}
	for j, item in items do
		table.insert(sug, N("button", {
			key = `b{j}`,
			text = `+ {item}`,
			size = "sm",
			variant = "quiet",
			role = "roost.suggest",
			title = `添加 {item}`,
			actions = { click = `sug:{i}:{f.key}:{j}` },
		}))
	end
	local filter_err = field_error(ed, function(path)
		return string.find(path, `.trigger[{i}].{f.key}`, 1, true) ~= nil
	end)
	local children: { any } = {
		txt(f.label, "lab", "muted"),
		N("row", { key = "chips", gap = "xs", wrap = true, role = "roost.chips" }, chips),
		input_node(ed, input_id, { key = "add", placeholder = f.hint or "输入后回车添加" }),
	}
	if status then
		table.insert(children, status)
	end
	if #sug > 0 then
		table.insert(children, N("row", { key = "sug", gap = "xs", wrap = true, align = "center" }, {
			txt("建议", "sl", "muted"),
			N("row", { key = "items", gap = "xs", wrap = true }, sug),
		}))
	end
	if filter_err then
		table.insert(children, txt(filter_err, "ferr", "warning"))
	end
	return N("col", { key = f.key, gap = "xs" }, children)
end

local function choice_row(i: number, tr: any, f: KeyedFilter): any
	local selected: { [string]: boolean } = {}
	for _, item in str_list(tr[f.key]) do
		selected[item] = true
	end
	local buttons: { any } = {}
	local opts: { model.Option } = f.options or {}
	for j, opt in opts do
		table.insert(buttons, N("button", {
			key = `o{j}`,
			text = opt.label,
			size = "sm",
			on = selected[opt.value] == true,
			actions = { click = `choice:{i}:{f.key}:{j}` },
		}))
	end
	return N("row", { key = f.key, gap = "xs", align = "center", wrap = true }, {
		txt(f.label, "lab", "muted"),
		N("row", { key = "opts", gap = "sm", wrap = true }, buttons),
	})
end

local function toggle_row(i: number, f: KeyedFilter, on: boolean): any
	return N("switch", {
		key = f.key,
		variant = "compact",
		label = f.label,
		hint = f.hint,
		on = on,
	})
end

-- A text filter (the comment prefix): one value, typed in place.
local function text_row(ed: Editor, i: number, tr: any, f: KeyedFilter): any
	local id = tid(i, "card", f.key, "text", "input")
	seed(ed, id, if type(tr[f.key]) == "string" then tr[f.key] else "")
	return N("field", { key = f.key, label = f.label, hint = f.hint, variant = "row" }, {
		N("col", { key = "text", gap = "none" }, {
			input_node(ed, id, { key = "input", placeholder = "任意" }),
		}),
	})
end

local function github_card(st: any, ed: Editor, i: number, tr: any): any
	local kind = if type(tr.github) == "string" then tr.github else ""
	local meta = if kind ~= "" then model.kind(kind) else nil
	local label = if meta then meta.label else if kind ~= "" then kind else "未知事件"
	local icon = if meta then meta.icon else "bolt"
	local head = N("row", { key = "h", gap = "sm", align = "center" }, {
		N("button", { key = "ic", icon = icon, text = "", title = label, size = "sm", variant = "quiet" }),
		txt(label, "lab"),
		N("button", {
			key = "del",
			icon = "trash",
			text = "",
			title = "删除触发器",
			size = "sm",
			variant = "quiet",
			actions = { click = `trig-del:{i}` },
		}),
	})
	local body: { any } = { head }
	if kind == "event" then
		-- Only events the relay's GitHub App subscribes to can arrive.
		local cur = if type(tr.event) == "string" then tr.event else ""
		local opts: { any } = {}
		for _, ev in model.APP_EVENTS do
			table.insert(opts, { value = ev, label = ev })
		end
		table.insert(body, N("field", { key = "event", label = "事件", variant = "row" }, {
			N("select", {
				key = "sel",
				value = cur,
				placeholder = "选择事件",
				options = opts,
				open = ed.opens[tid(i, "card", "event", "sel")] == true,
			}),
		}))
	end
	if meta then
		for _, key in meta.filters do
			local f = keyed_filter(key)
			if f then
				if f.kind == "list" then
					table.insert(body, chip_row(st, ed, i, tr, f))
				elseif f.kind == "text" then
					table.insert(body, text_row(ed, i, tr, f))
				elseif f.kind == "choice" then
					table.insert(body, choice_row(i, tr, f))
				elseif f.kind == "toggle" then
					-- Unset means the filter's default, the same one the model applies.
					local on = if tr[key] == nil then f.default == true else tr[key] == true
					table.insert(body, toggle_row(i, f, on))
				end
			end
		end
	end
	if needs_filter(tr) then
		table.insert(body, N("text", { key = "warn", role = "roost.warn", tone = "warning", spans = { tern.ui.span("至少添加一个筛选器", "warning") } }))
	end
	local err: string? = nil
	for _, issue in ed.issues do
		if string.find(issue.path, `.trigger[{i}]`, 1, true) and not string.find(issue.message, "筛选器", 1, true) then
			err = issue.message
			break
		end
	end
	if err then
		table.insert(body, txt(err, "err", "warning"))
	end
	return N("col", { key = "card", role = "roost.trigger", gap = "sm" }, body)
end

local function catalogue_ids(st: any): { string }
	local ids: { string } = {}
	local cat = if type(st) == "table" and type(st.core) == "table" then st.core.workflows else nil
	if type(cat) == "table" and type(cat.list) == "table" then
		for _, wf in cat.list do
			if type(wf) == "table" and type(wf.id) == "string" then
				table.insert(ids, wf.id)
			end
		end
	end
	return ids
end

local function roost_meta(on: string): (string, string)
	for _, kind in model.ROOST_KINDS do
		if kind.id == on then
			return kind.label, kind.detail
		end
	end
	return if on ~= "" then on else "未知触发器", ""
end

-- Chips for a roost trigger's `workflows`, suggesting other workflow ids from the catalogue.
local function roost_workflows(st: any, ed: Editor, i: number, tr: any): any
	local values = str_list(tr.workflows)
	local chips: { any } = {}
	for j, item in values do
		table.insert(chips, N("button", {
			key = `c{j}`,
			text = `{item} ×`,
			size = "sm",
			tone = "accent",
			role = "roost.chip",
			title = `移除 {item}`,
			actions = { click = `cdel:{i}:workflows:{j}` },
		}))
	end
	local input_id = tid(i, "card", "workflows", "add")
	seed(ed, input_id, "")
	local seen: { [string]: boolean } = {}
	for _, item in values do
		seen[string.lower(item)] = true
	end
	local self_id = if type(ed.raw.id) == "string" then ed.raw.id else ed.old_id
	if type(self_id) == "string" then
		seen[string.lower(self_id)] = true
	end
	local q = string.lower(buf(ed, input_id).text)
	local items: { string } = {}
	for _, id in catalogue_ids(st) do
		local low = string.lower(id)
		if not seen[low] and (q == "" or string.find(low, q, 1, true)) then
			table.insert(items, id)
			if #items >= 8 then
				break
			end
		end
	end
	ed.suggest[`{i}:workflows`] = items
	local sug: { any } = {}
	for j, item in items do
		table.insert(sug, N("button", {
			key = `b{j}`,
			text = `+ {item}`,
			size = "sm",
			variant = "quiet",
			role = "roost.suggest",
			title = `添加 {item}`,
			actions = { click = `sug:{i}:workflows:{j}` },
		}))
	end
	local filter_err = field_error(ed, function(path)
		return string.find(path, `.trigger[{i}].workflows`, 1, true) ~= nil
	end)
	local children: { any } = {
		txt("工作流", "lab", "muted"),
		N("row", { key = "chips", gap = "xs", wrap = true, role = "roost.chips" }, chips),
		input_node(ed, input_id, { key = "add", placeholder = "工作流 id,回车添加" }),
	}
	if #sug > 0 then
		table.insert(children, N("row", { key = "sug", gap = "xs", wrap = true, align = "center" }, {
			txt("建议", "sl", "muted"),
			N("row", { key = "items", gap = "xs", wrap = true }, sug),
		}))
	end
	if filter_err then
		table.insert(children, txt(filter_err, "ferr", "warning"))
	end
	return N("col", { key = "workflows", gap = "xs" }, children)
end

local function roost_card(st: any, ed: Editor, i: number, tr: any): any
	local on = if type(tr.roost) == "string" then tr.roost else ""
	local label, detail = roost_meta(on)
	local streak = if type(tr.streak) == "number" then tostring(tr.streak) else "1"
	local opts: { any } = {}
	for n = 1, 10 do
		local v = tostring(n)
		table.insert(opts, { value = v, label = v })
	end
	local body: { any } = {
		N("row", { key = "h", gap = "sm", align = "center" }, {
			N("button", { key = "ic", icon = "activity", text = "", title = label, size = "sm", variant = "quiet" }),
			txt(label, "lab"),
			N("button", {
				key = "del",
				icon = "trash",
				text = "",
				title = "删除触发器",
				size = "sm",
				variant = "quiet",
				actions = { click = `trig-del:{i}` },
			}),
		}),
		txt(detail, "detail", "muted"),
		roost_workflows(st, ed, i, tr),
		N("field", { key = "streak", label = "连续失败次数", variant = "row" }, {
			N("select", {
				key = "sel",
				value = streak,
				options = with_current(opts, streak, streak),
				open = ed.opens[tid(i, "card", "streak", "sel")] == true,
			}),
		}),
	}
	local err: string? = nil
	for _, issue in ed.issues do
		if string.find(issue.path, `.trigger[{i}]`, 1, true) and not string.find(issue.path, ".workflows", 1, true) then
			err = issue.message
			break
		end
	end
	if err then
		table.insert(body, txt(err, "err", "warning"))
	end
	return N("col", { key = "card", role = "roost.trigger", gap = "sm" }, body)
end

-- An API trigger: the token (only its SHA-256 is saved; a new one shows once) and how to call it.
local function api_card(st: any, ed: Editor, i: number, tr: any): any
	local set = type(tr.api) == "string" and #tr.api == 64
	local token = ed.api_tokens[i]
	local id = if type(ed.raw.id) == "string" and ed.raw.id ~= "" then ed.raw.id else (ed.old_id or "<工作流 id>")
	local relay = string.gsub(st.core.config.relay.url or "https://<中继地址>", "/+$", "")
	local body: { any } = {
		N("row", { key = "h", gap = "sm", align = "center" }, {
			N("button", { key = "ic", icon = "plug", text = "", title = "API 调用", size = "sm", variant = "quiet" }),
			txt("API 调用", "lab"),
			N("button", {
				key = "del",
				icon = "trash",
				text = "",
				title = "删除触发器",
				size = "sm",
				variant = "quiet",
				actions = { click = `trig-del:{i}` },
			}),
		}),
		txt("外部系统(CI、脚本、其他服务)经中继启动这个工作流;令牌只能启动它,输入只接受声明过的。", "detail", "muted"),
	}
	if token then
		table.insert(body, txt("新令牌只显示这一次,保存工作流后旧令牌失效:", "tokh", "warning"))
		table.insert(body, N("row", { key = "tok", gap = "sm", align = "center" }, {
			N("text", { key = "v", spans = { tern.ui.span(token, "mono") } }),
			N("button", { key = "copy", text = "复制", icon = "copy", size = "sm", actions = { click = `api-copy:{i}` } }),
		}))
	end
	table.insert(body, N("row", { key = "gen", gap = "sm", align = "center" }, {
		txt(if set then "令牌已设置(文件里只有它的 SHA-256)" else "还没有令牌", "state", if set then "muted" else "warning"),
		N("button", { key = "go", text = if set then "重新生成" else "生成令牌", icon = "repeat", size = "sm", actions = { click = `api-gen:{i}` } }),
	}))
	table.insert(body, N("code", {
		key = "curl",
		lang = "sh",
		text = `curl -X POST {relay}/hooks/dispatch/{id} \\\n  -H "Authorization: Bearer <令牌>" \\\n  -H "Content-Type: application/json" \\\n  -d '\{"inputs":\{\}\}'`,
	}))
	local err: string? = nil
	for _, issue in ed.issues do
		if string.find(issue.path, `.trigger[{i}]`, 1, true) then
			err = issue.message
			break
		end
	end
	if err then
		table.insert(body, txt(err, "err", "warning"))
	end
	return N("col", { key = "card", role = "roost.trigger", gap = "sm" }, body)
end

local function trigger_node(st: any, ed: Editor, i: number, tr: any): any
	if type(tr) == "table" and type(tr.github) == "string" then
		return N("col", { key = `t{i}`, gap = "xs" }, { github_card(st, ed, i, tr) })
	end
	if type(tr) == "table" and type(tr.roost) == "string" then
		return N("col", { key = `t{i}`, gap = "xs" }, { roost_card(st, ed, i, tr) })
	end
	if type(tr) == "table" and tr.api ~= nil then
		return N("col", { key = `t{i}`, gap = "xs" }, { api_card(st, ed, i, tr) })
	end
	local row, err = schedule_sentence(ed, i, if type(tr) == "table" then tr else {})
	local parts: { any } = { row }
	if err then
		table.insert(parts, txt(err, "err", "warning"))
	end
	return N("col", { key = `t{i}`, gap = "xs" }, parts)
end

local function add_menu(ed: Editor): any
	local items: { any } = { { header = "定时" } }
	for _, sch in model.SCHEDULES do
		table.insert(items, { id = `sched:{sch.id}`, label = sch.label, detail = sch.detail, icon = "clock" })
	end
	table.insert(items, { header = "GitHub" })
	for _, kind in model.GITHUB_KINDS do
		table.insert(items, { id = `gh:{kind.id}`, label = kind.label, detail = kind.detail, icon = kind.icon })
	end
	table.insert(items, { header = "Roost" })
	for _, kind in model.ROOST_KINDS do
		table.insert(items, { id = `roost:{kind.id}`, label = kind.label, detail = kind.detail, icon = "activity" })
	end
	table.insert(items, { header = "其他" })
	table.insert(items, { id = "api:new", label = "API 调用", detail = "外部系统用令牌经中继启动", icon = "plug" })
	return N("menu", { key = "add", text = "添加触发器", icon = "plus", items = items, open = ed.opens[ROOT .. ".body.triggers.add"] == true })
end

local function icon_menu(ed: Editor): any
	local cur = ed.raw.icon
	local current = if type(cur) == "string" and cur ~= "" then cur else "sparkle"
	local items: { any } = {}
	local seen: { [string]: boolean } = {}
	local function push(name: string)
		if name ~= "" and not seen[name] then
			seen[name] = true
			table.insert(items, { id = `icon:{name}`, icon = name, label = "", title = name })
		end
	end
	push(current)
	for _, name in model.ICONS do
		push(name)
	end
	return N("menu", {
		key = "icon",
		icon = current,
		text = "",
		title = "更换图标",
		items = items,
		open = ed.opens[ROOT .. ".body.head.icon"] == true,
	})
end

-- Auto (omp's default role), then omp's roles (`@<role>`, resolved by `--model`) and its chat
-- models, read from the local omp; a value from the file that neither lists stays first.
local function model_options(st: any, current: string): { any }
	local cat = core.omp_models(st.core)
	local default: string? = nil
	for _, r in cat.roles do
		if r.name == "default" then
			default = r.model
		end
	end
	local opts: { any } = { { value = "auto", label = "Auto", detail = default } }
	for _, r in cat.roles do
		if r.name ~= "default" then
			table.insert(opts, { value = `@{r.name}`, label = `@{r.name}`, detail = r.model, group = "角色" })
		end
	end
	for _, m in cat.models do
		table.insert(opts, { value = m.selector, label = m.selector, group = m.provider })
	end
	if cat.loading and #cat.roles == 0 and #cat.models == 0 then
		table.insert(opts, { value = "\0loading", label = "正在读取 omp 的角色与模型…", disabled = true })
	elseif cat.error then
		table.insert(opts, { value = "\0error", label = cat.error, disabled = true })
	end
	if current ~= "" and current ~= "auto" then
		return with_current(opts, current, current)
	end
	return opts
end
M.model_options = model_options

local function prompt_section(st: any, ed: Editor): any
	local step = prompt_step(ed)
	local model_id = if step and type(step.model) == "string" then step.model else "auto"
	seed(ed, PROMPT_ID, if step then step_text(step) else "", true)
	seed(ed, PROMPT_WHEN_ID, if step then when_text_of(step) else "")
	local idx = prompt_index(ed)
	local err = field_error(ed, function(path)
		return idx ~= nil and string.find(path, `.step[{idx}]`, 1, true) ~= nil and string.find(path, ".when", 1, true) == nil
	end)
	local when_err = field_error(ed, function(path)
		return idx ~= nil and string.find(path, `.step[{idx}].when`, 1, true) ~= nil
	end)
	return N("col", { key = "prompt", gap = "xs" }, {
		txt("指令", "h"),
		N("field", { key = "stack", error = err }, {
			editor_node(ed, PROMPT_ID, { key = "input", placeholder = "让 Roost 做什么", lines = true }),
		}),
		N("row", { key = "bar", gap = "sm" }, {
			N("select", {
				key = "pmodel",
				value = model_id,
				options = model_options(st, model_id),
				title = "模型",
				disabled = if step then false else "先写指令,再选模型",
				open = ed.opens[ROOT .. ".body.prompt.bar.pmodel"] == true,
			}),
		}),
		N("field", {
			key = "when",
			label = "条件(when)",
			hint = "out.<输出名> 或 input.<输入名>,可加 ! 取反;为空则总是运行",
			error = when_err,
		}, {
			input_node(ed, PROMPT_WHEN_ID, { key = "input", placeholder = "out.verify" }),
		}),
	})
end

local function steps_section(ed: Editor): any
	local steps = steps_of(ed.raw)
	local prompt_at = prompt_index(ed)
	local rows: { any } = { txt("更多步骤", "h") }
	local any_extra = false
	local file_opts = file_options(ed)
	for i, step in steps do
		if i ~= prompt_at and type(step) == "table" then
			any_extra = true
			local kind = step_kind(step)
			local name_id = sid(i, "name", "input")
			local text_id = sid(i, "text", "input")
			local args_id = sid(i, "args", "input")
			local when_id = sid(i, "when", "input")
			seed(ed, name_id, if type(step.name) == "string" then step.name else "")
			seed(ed, when_id, when_text_of(step))
			local err = field_error(ed, function(path)
				return string.find(path, `.step[{i}]`, 1, true) ~= nil
					and string.find(path, ".when", 1, true) == nil
					and string.find(path, ".file", 1, true) == nil
			end)
			local file_err = field_error(ed, function(path)
				return string.find(path, `.step[{i}].file`, 1, true) ~= nil
			end)
			local when_err = field_error(ed, function(path)
				return string.find(path, `.step[{i}].when`, 1, true) ~= nil
			end)
			local body: { any } = {
				N("row", { key = "bar", gap = "sm", align = "center" }, {
					N("select", {
						key = "kind",
						value = kind,
						options = {
							{ value = "omp", label = "指令" },
							{ value = "run", label = "命令" },
							{ value = "file", label = "文件" },
							{ value = "tab", label = "标签页" },
							{ value = "upgrade", label = "升级 Roost" },
						},
						open = ed.opens[sid(i, "bar", "kind")] == true,
					}),
					N("button", { key = "up", text = "↑", title = "上移", size = "sm", variant = "quiet", actions = { click = `step-up:{i}` } }),
					N("button", { key = "down", text = "↓", title = "下移", size = "sm", variant = "quiet", actions = { click = `step-down:{i}` } }),
					N("button", { key = "del", text = "删除", title = "删除步骤", size = "sm", variant = "quiet", actions = { click = `step-del:{i}` } }),
				}),
				N("field", { key = "name", label = "名称", error = if err and string.find(err, "名", 1, true) then err else nil }, {
					input_node(ed, name_id, { key = "input", placeholder = "步骤名称" }),
				}),
			}
			if kind == "file" then
				local cur = if type(step.file) == "string" then step.file else ""
				local opts = with_current(file_opts, cur, if cur == "" then "选择文件" else cur)
				seed(ed, args_id, args_text(step))
				table.insert(body, N("field", { key = "file", label = "脚本", error = file_err }, {
					N("select", {
						key = "sel",
						value = cur,
						placeholder = "选择文件",
						options = opts,
						open = ed.opens[sid(i, "file", "sel")] == true,
					}),
				}))
				table.insert(body, N("field", { key = "args", label = "参数", hint = "空格分隔,写入 args 数组" }, {
					input_node(ed, args_id, { key = "input", placeholder = "--flag value" }),
				}))
			elseif kind == "tab" then
				local action = if step.tab == "close" then "close" else "open"
				table.insert(body, N("field", { key = "tabact", label = "动作" }, {
					N("select", {
						key = "sel",
						value = action,
						options = {
							{ value = "open", label = "打开" },
							{ value = "close", label = "关闭" },
						},
						open = ed.opens[sid(i, "tabact", "sel")] == true,
					}),
				}))
				local key_id = sid(i, "key", "input")
				seed(ed, key_id, if type(step.key) == "string" then step.key else "")
				table.insert(body, N("field", { key = "key", label = "键" }, {
					input_node(ed, key_id, { key = "input", placeholder = "main" }),
				}))
				if action == "open" then
					local title_id = sid(i, "title", "input")
					local cmd_id = sid(i, "command", "input")
					seed(ed, title_id, if type(step.title) == "string" then step.title else "")
					seed(ed, cmd_id, if type(step.command) == "string" then step.command else "")
					table.insert(body, N("field", { key = "title", label = "标题" }, {
						input_node(ed, title_id, { key = "input", placeholder = "标签页标题" }),
					}))
					table.insert(body, N("field", { key = "command", label = "命令", hint = "可用 $ROOST_RUN_DIR 等变量;留空则打开 shell" }, {
						input_node(ed, cmd_id, { key = "input", placeholder = "shell 命令" }),
					}))
					table.insert(body, N("switch", {
						key = "keep",
						variant = "compact",
						label = "运行结束后保留",
						on = step.keep == true,
					}))
					table.insert(body, N("switch", {
						key = "focus",
						variant = "compact",
						label = "打开后切换过去",
						on = step.focus == true,
					}))
				end
			elseif kind == "upgrade" then
				table.insert(body, txt("检查本运行 worktree 里的新提交(须是 Roost 源码克隆的仓库),scripts/check.sh 通过后由后台脚本应用到插件目录;加载失败自动回退。", "note", "muted"))
			else
				seed(ed, text_id, step_text(step), true)
				local f = ed.buf[text_id]
				if f then
					f.lines = true
				end
				table.insert(body, N("field", { key = "text", error = err }, {
					editor_node(ed, text_id, {
						key = "input",
						placeholder = if kind == "run" then "shell 脚本" else "提示词",
						lines = true,
						maxLines = FILE_MAX_LINES,
					}),
				}))
			end
			table.insert(body, N("field", {
				key = "when",
				label = "条件(when)",
				hint = "out.<输出名> 或 input.<输入名>,可加 ! 取反;为空则总是运行",
				error = when_err,
			}, {
				input_node(ed, when_id, { key = "input", placeholder = "out.verify" }),
			}))
			table.insert(rows, N("col", { key = `s{i}`, gap = "xs", role = "roost.steps" }, body))
		end
	end
	if not any_extra then
		table.insert(rows, txt("只有指令一步。需要 shell、文件或更多指令时再添加。", "empty", "muted"))
	end
	table.insert(rows, N("button", {
		key = "add",
		text = "添加步骤",
		icon = "plus",
		size = "sm",
		actions = { click = "step-add" },
	}))
	return N("col", { key = "steps", gap = "sm" }, rows)
end

local function files_section(ed: Editor): any
	local paths = sorted_file_paths(ed.files)
	local sel = ed.file_sel
	if type(sel) == "string" and ed.files[sel] == nil then
		sel = paths[1]
		ed.file_sel = sel
	elseif sel == nil and paths[1] then
		sel = paths[1]
		ed.file_sel = sel
	end
	local list: { any } = {}
	for i, path in paths do
		local text = ed.files[path] or ""
		local armed = ed.confirm_file == path
		table.insert(list, N("row", { key = `f{i}`, gap = "sm", align = "center" }, {
			N("button", {
				key = "pick",
				text = path,
				size = "sm",
				variant = if sel == path then "primary" else "quiet",
				on = sel == path,
				actions = { click = `file-sel:{path}` },
			}),
			txt(`{#text} 字节`, "sz", "muted"),
			N("button", {
				key = "del",
				text = if armed then "确认删除" else "删除",
				size = "sm",
				variant = if armed then "danger" else "quiet",
				actions = { click = `file-del:{path}` },
			}),
		}))
	end
	if #list == 0 then
		table.insert(list, txt("还没有文件。添加后可在步骤里以「文件」运行。", "empty", "muted"))
	end
	seed(ed, FILE_ADD_ID, if ed.buf[FILE_ADD_ID] then ed.buf[FILE_ADD_ID].text else "script.py")
	local children: { any } = {
		txt("文件", "h"),
		N("col", { key = "list", gap = "xs" }, list),
		N("row", { key = "add", gap = "sm", align = "center" }, {
			N("field", { key = "path", label = "添加", hint = "相对路径,默认 .py" }, {
				input_node(ed, FILE_ADD_ID, { key = "input", placeholder = "script.py" }),
			}),
			N("button", {
				key = "go",
				text = "添加",
				icon = "plus",
				size = "sm",
				actions = { click = "file-add" },
			}),
		}),
	}
	if type(sel) == "string" and ed.files[sel] ~= nil then
		if ed.file_edit_for ~= sel then
			ed.buf[FILE_EDIT_ID] = {
				text = ed.files[sel],
				cursor = utf8_len(ed.files[sel]),
				lines = true,
			}
			ed.file_edit_for = sel
		end
		if ed.file_ren_for ~= sel then
			ed.buf[FILE_REN_ID] = { text = sel, cursor = utf8_len(sel) }
			ed.file_ren_for = sel
		end
		table.insert(children, N("row", { key = "ren", gap = "sm", align = "center" }, {
			N("field", { key = "path", label = "重命名" }, {
				input_node(ed, FILE_REN_ID, { key = "input", placeholder = sel }),
			}),
			N("button", {
				key = "go",
				text = "重命名",
				size = "sm",
				actions = { click = "file-ren" },
			}),
		}))
		local files_err = field_error(ed, function(path)
			return string.find(path, ".files", 1, true) ~= nil
		end)
		table.insert(children, N("field", {
			key = "edit",
			label = sel,
			error = files_err,
		}, {
			editor_node(ed, FILE_EDIT_ID, {
				key = "input",
				lang = file_lang(sel),
				maxLines = FILE_MAX_LINES,
			}),
		}))
	end
	return N("col", { key = "files", gap = "sm", role = "roost.files" }, children)
end

local function repo_options(st: any, current: string?): { any }
	local opts = { { value = "", label = "本机无" } }
	local wfs = st.core.workflows
	local repos = if wfs then wfs.repos else nil
	if type(repos) == "table" then
		local names: { string } = {}
		for name in repos do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			table.insert(opts, { value = name, label = name })
		end
	end
	if type(current) == "string" and current ~= "" then
		return with_current(opts, current, current)
	end
	return opts
end

local function advanced_section(st: any, ed: Editor): any
	local raw = ed.raw
	local children: { any } = {
		N("button", {
			key = "toggle",
			text = "高级",
			icon = if ed.advanced then "chev" else "chev-r",
			variant = "quiet",
			size = "sm",
			actions = { click = "advanced" },
		}),
	}
	if not ed.advanced then
		return N("col", { key = "advanced", gap = "sm" }, children)
	end
	local id_err = field_error(ed, function(path)
		return path == "id" or string.sub(path, -3) == ".id"
	end)
	local shown_id = if ed.mode == "edit" then (if type(raw.id) == "string" then raw.id else "") else ""
	seed(ed, ID_ID, if ed.buf[ID_ID] then ed.buf[ID_ID].text else shown_id)
	seed(ed, DESC_ID, if type(raw.description) == "string" then raw.description else "")
	local timeout = raw.timeout
	seed(ed, TIMEOUT_ID, if type(timeout) == "string" then timeout elseif type(timeout) == "number" then tostring(timeout) else "")
	seed(ed, BUDGET_ID, budget_text(raw))
	table.insert(children, N("field", {
		key = "id",
		label = "id",
		hint = "留空则按名称生成",
		error = id_err,
	}, {
		input_node(ed, ID_ID, { key = "input", placeholder = "保存时自动生成" }),
	}))
	table.insert(children, N("field", { key = "desc", label = "描述" }, {
		input_node(ed, DESC_ID, { key = "input", placeholder = "一句话说明" }),
	}))
	table.insert(children, N("switch", { key = "enabled", variant = "compact", label = "启用", on = raw.enabled ~= false }))
	table.insert(children, N("switch", { key = "manual", variant = "compact", label = "允许手动运行", on = raw.manual ~= false }))
	local ws = if type(raw.workspace) == "string" then raw.workspace else "auto"
	table.insert(children, N("field", { key = "ws", label = "工作区" }, {
		N("select", {
			key = "sel",
			value = ws,
			options = with_current({
				{ value = "auto", label = "自动" },
				{ value = "worktree", label = "worktree" },
				{ value = "repo", label = "仓库目录" },
				{ value = "temp", label = "临时目录" },
			}, ws, ws),
			open = ed.opens[ROOT .. ".body.advanced.ws.sel"] == true,
		}),
	}))
	local who = if raw.identity == "app" or raw.identity == "local" then raw.identity else ""
	table.insert(children, N("field", { key = "who", label = "GitHub 身份", hint = "评论、审查、推送以谁的身份进行" }, {
		N("select", {
			key = "sel",
			value = who,
			options = with_current({
				{ value = "", label = "跟随 roost.toml" },
				{ value = "app", label = "GitHub App" },
				{ value = "local", label = "本机 gh" },
			}, who, who),
			open = ed.opens[ROOT .. ".body.advanced.who.sel"] == true,
		}),
	}))
	local envname = if type(raw.environment) == "string" then raw.environment else ""
	local env_opts: { any } = { { value = "", label = "不使用" } }
	for _, name in util.keys(st.core.config.environments) do
		table.insert(env_opts, { value = name, label = name })
	end
	table.insert(children, N("field", { key = "env", label = "环境", hint = "roost.toml [environments.<名>]:变量(shell 与 omp 步骤都拿得到)、PATH 与 setup" }, {
		N("select", {
			key = "sel",
			value = envname,
			options = with_current(env_opts, envname, envname),
			open = ed.opens[ROOT .. ".body.advanced.env.sel"] == true,
		}),
	}))
	local conc = if type(raw.concurrency) == "string" then raw.concurrency else "queue"
	table.insert(children, N("field", { key = "conc", label = "并发" }, {
		N("select", {
			key = "sel",
			value = conc,
			options = with_current({
				{ value = "queue", label = "排队" },
				{ value = "skip", label = "跳过" },
				{ value = "replace", label = "替换" },
			}, conc, conc),
			open = ed.opens[ROOT .. ".body.advanced.conc.sel"] == true,
		}),
	}))
	table.insert(children, N("field", { key = "timeout", label = "超时", hint = "如 20m" }, {
		input_node(ed, TIMEOUT_ID, { key = "input", placeholder = "20m" }),
	}))
	local budget_err = field_error(ed, function(path)
		return path == "daily_budget" or string.sub(path, -13) == ".daily_budget"
	end)
	table.insert(children, N("field", {
		key = "budget",
		label = "每日预算(美元)",
		hint = "达到后今日不再启动 omp 步骤",
		error = budget_err,
	}, {
		input_node(ed, BUDGET_ID, { key = "input", placeholder = "5" }),
	}))
	local libs = str_list(raw.libs)
	local lib_chips: { any } = {}
	for j, name in libs do
		table.insert(lib_chips, N("button", {
			key = `l{j}`,
			text = `{name} ×`,
			size = "sm",
			tone = "accent",
			role = "roost.chip",
			title = `移除 {name}`,
			actions = { click = `lib-del:{j}` },
		}))
	end
	seed(ed, LIBS_ADD_ID, if ed.buf[LIBS_ADD_ID] then ed.buf[LIBS_ADD_ID].text else "")
	local libs_err = field_error(ed, function(path)
		return path == "libs" or string.sub(path, -5) == ".libs"
	end)
	local libs_kids: { any } = {
		txt("文件库(libs)", "lab", "muted"),
		txt("在「自动化 › 文件库」管理共享库;此处只引用名称。", "hint", "muted"),
		N("row", { key = "chips", gap = "xs", wrap = true, role = "roost.chips" }, lib_chips),
		N("row", { key = "addrow", gap = "sm", align = "center" }, {
			input_node(ed, LIBS_ADD_ID, { key = "add", placeholder = "库名,回车添加" }),
			N("button", {
				key = "go",
				text = "添加",
				size = "sm",
				actions = { click = "lib-add" },
			}),
		}),
	}
	if libs_err then
		table.insert(libs_kids, txt(libs_err, "ferr", "warning"))
	end
	table.insert(children, N("col", { key = "libs", gap = "xs" }, libs_kids))
	local state_err = field_error(ed, function(path)
		return path == "state" or string.sub(path, -6) == ".state"
	end)
	seed(ed, STATE_ID, if type(raw.state) == "string" then raw.state else "")
	table.insert(children, N("field", {
		key = "state",
		label = "状态组(state)",
		hint = "留空则用工作流 id;跨运行持久目录 $ROOST_STATE",
		error = state_err,
	}, {
		input_node(ed, STATE_ID, { key = "input", placeholder = "默认:工作流 id" }),
	}))
	local evolve = str_list(raw.evolve)
	local evolve_all = false
	for _, item in evolve do
		if item == "*" then
			evolve_all = true
			break
		end
	end
	table.insert(children, N("switch", {
		key = "evolveall",
		variant = "compact",
		label = "全部工作流",
		hint = "迭代除自身以外、且自己不迭代别人的工作流",
		on = evolve_all,
	}))
	if not evolve_all then
		local ev_chips: { any } = {}
		local shown: { string } = {}
		for _, name in evolve do
			if name ~= "*" then
				table.insert(shown, name)
			end
		end
		for j, name in shown do
			table.insert(ev_chips, N("button", {
				key = `e{j}`,
				text = `{name} ×`,
				size = "sm",
				tone = "accent",
				role = "roost.chip",
				title = `移除 {name}`,
				actions = { click = `evolve-del:{j}` },
			}))
		end
		seed(ed, EVOLVE_ADD_ID, if ed.buf[EVOLVE_ADD_ID] then ed.buf[EVOLVE_ADD_ID].text else "")
		local self_id = if type(raw.id) == "string" then raw.id else ed.old_id
		local seen: { [string]: boolean } = {}
		for _, name in shown do
			seen[string.lower(name)] = true
		end
		if type(self_id) == "string" then
			seen[string.lower(self_id)] = true
		end
		local q = string.lower(buf(ed, EVOLVE_ADD_ID).text)
		local sug_ids: { string } = {}
		for _, id in catalogue_ids(st) do
			local low = string.lower(id)
			if not seen[low] and (q == "" or string.find(low, q, 1, true)) then
				table.insert(sug_ids, id)
				if #sug_ids >= 8 then
					break
				end
			end
		end
		ed.suggest.evolve = sug_ids
		local sug: { any } = {}
		for j, id in sug_ids do
			table.insert(sug, N("button", {
				key = `b{j}`,
				text = `+ {id}`,
				size = "sm",
				variant = "quiet",
				role = "roost.suggest",
				title = `添加 {id}`,
				actions = { click = `evolve-sug:{j}` },
			}))
		end
		local evolve_err = field_error(ed, function(path)
			return path == "evolve" or string.find(path, ".evolve", 1, true) ~= nil
		end)
		local ev_kids: { any } = {
			txt("迭代的工作流", "lab", "muted"),
			N("row", { key = "chips", gap = "xs", wrap = true, role = "roost.chips" }, ev_chips),
			input_node(ed, EVOLVE_ADD_ID, { key = "add", placeholder = "工作流 id,回车添加" }),
		}
		if #sug > 0 then
			table.insert(ev_kids, N("row", { key = "sug", gap = "xs", wrap = true, align = "center" }, {
				txt("建议", "sl", "muted"),
				N("row", { key = "items", gap = "xs", wrap = true }, sug),
			}))
		end
		if evolve_err then
			table.insert(ev_kids, txt(evolve_err, "ferr", "warning"))
		end
		table.insert(children, N("col", { key = "evolve", gap = "xs" }, ev_kids))
	end
	local tz_opts = {
		{ value = "", label = "本机时区" },
		{ value = "UTC", label = "UTC" },
	}
	for i, tr in triggers_of(raw) do
		if type(tr) == "table" and type(tr.schedule) == "string" then
			local tz = if type(tr.tz) == "string" then tr.tz else ""
			table.insert(children, N("field", { key = `tz{i}`, label = `触发器 {i} 时区` }, {
				N("select", {
					key = "sel",
					value = tz,
					options = with_current(tz_opts, tz, tz),
					open = ed.opens[join({ ROOT, "body", "advanced", `tz{i}`, "sel" })] == true,
				}),
			}))
			local repo = if type(tr.repo) == "string" then tr.repo else ""
			table.insert(children, N("field", { key = `repo{i}`, label = `触发器 {i} 仓库` }, {
				N("select", {
					key = "sel",
					value = repo,
					options = repo_options(st, repo),
					open = ed.opens[join({ ROOT, "body", "advanced", `repo{i}`, "sel" })] == true,
				}),
			}))
			seed(ed, ref_id(i), if type(tr.ref) == "string" then tr.ref else "")
			table.insert(children, N("field", { key = `ref{i}`, label = `触发器 {i} ref` }, {
				input_node(ed, ref_id(i), { key = "input", placeholder = "分支或 tag,可留空" }),
			}))
		elseif type(tr) == "table" and type(tr.github) == "string" then
			local assoc = tr.associations
			local external = type(assoc) == "table" and #assoc == 1 and assoc[1] == "*"
			table.insert(children, N("switch", {
				key = `assoc{i}`,
				variant = "compact",
				label = `触发器 {i} 允许外部贡献者`,
				on = external == true,
			}))
		end
	end
	return N("col", { key = "advanced", gap = "sm" }, children)
end

local function templates_groups(): { string }
	local seen: { [string]: boolean } = {}
	local out = { "全部" }
	seen["全部"] = true
	for _, tpl in model.TEMPLATES do
		local g = tpl.group or "其他"
		if not seen[g] then
			seen[g] = true
			table.insert(out, g)
		end
	end
	return out
end

function M.templates(st: any): any
	local groups = templates_groups()
	local active = st.tpl
	if type(active) ~= "string" then
		active = "全部"
	end
	local items: { any } = {}
	for _, g in groups do
		table.insert(items, { id = g, label = g })
	end
	local cards: { any } = {}
	for _, tpl in model.TEMPLATES do
		if active == "全部" or tpl.group == active then
			table.insert(cards, N("col", { key = tpl.id, gap = "xs", role = "roost.templates" }, {
				N("row", { key = "h", gap = "xs", align = "center" }, {
					N("button", { key = "ic", icon = tpl.icon or "sparkle", text = "", title = tpl.name, size = "sm", variant = "quiet" }),
					txt(tpl.name, "name"),
				}),
				txt(tpl.description or "", "desc", "muted"),
				N("button", {
					key = "add",
					text = "添加",
					icon = "plus",
					size = "sm",
					variant = "primary",
					actions = { click = `template={tpl.id}` },
				}),
			}))
		end
	end
	return N("col", { key = "templates", gap = "sm", role = "roost.templates" }, {
		N("tabs", { key = "tpl", variant = "segmented", active = active, items = items }),
		N("row", { key = "gallery", gap = "sm" }, cards),
	})
end

-- The workflows page's 「从模板」 dropdown: one rich row per template, grouped. Choosing one
-- sends `act = "tpl:<id>"`.
function M.template_menu(): any
	local items: { any } = {}
	for gi, g in templates_groups() do
		if g == "全部" then
			continue
		end
		if gi > 2 then
			table.insert(items, "-")
		end
		table.insert(items, { header = g })
		for _, tpl in model.TEMPLATES do
			if (tpl.group or "其他") == g then
				table.insert(items, {
					id = `tpl:{tpl.id}`,
					label = tpl.name,
					detail = tpl.description,
					icon = tpl.icon or "sparkle",
				})
			end
		end
	end
	-- The trigger sits near the toolbar's right edge: hang the menu leftward so it is not clipped.
	return N("menu", { key = "templates", text = "从模板", icon = "sparkle", caret = true, align = "end", items = items })
end

local function discard_overlay(): any
	return N("overlay", {
		key = "discard",
		modal = true,
		size = "sm",
		head = "放弃未保存的更改?",
		foot = "layer.discard.foot",
	}, {
		txt("关闭后,这次编辑不会写入 workflows.toml。", "msg", "muted"),
		N("row", { key = "foot", gap = "sm", justify = "end" }, {
			N("button", { key = "stay", text = "继续编辑", actions = { click = "discard-stay" } }),
			N("button", { key = "go", text = "放弃", variant = "danger", actions = { click = "discard-go" } }),
		}),
	})
end

function M.view(st: any): any?
	local ed = ed_of(st)
	if not ed then
		return nil
	end
	ed.slots = {}
	ed.suggest = {}
	local raw = ed.raw
	seed(ed, NAME_ID, if ed.buf[NAME_ID] then ed.buf[NAME_ID].text else "")
	local name_err = field_error(ed, function(path)
		return path == "name" or (string.sub(path, -5) == ".name" and string.find(path, ".step[", 1, true) == nil)
	end)
	local triggers: { any } = {}
	for i, tr in triggers_of(raw) do
		table.insert(triggers, trigger_node(st, ed, i, tr))
	end
	table.insert(triggers, add_menu(ed))
	local reason = first_issue(ed)
	local title = if ed.mode == "edit" then "编辑自动化" else "新建自动化"
	local foot: { any } = {
		N("button", { key = "cancel", text = "取消", actions = { click = "cancel" } }),
		N("button", {
			key = "save",
			text = "保存",
			variant = "primary",
			keys = { "cmd", "enter" },
			disabled = if reason then reason else false,
			busy = ed.busy,
			actions = { click = "save" },
		}),
	}
	if ed.mode == "edit" then
		table.insert(foot, 1, N("button", {
			key = "del",
			text = if ed.confirm_delete then "确认删除" else "删除",
			variant = "danger",
			actions = { click = "delete" },
		}))
	end
	local body = N("col", { key = "body", gap = "md", role = "roost.editor" }, {
		N("row", { key = "head", gap = "sm", align = "center" }, {
			icon_menu(ed),
			N("field", { key = "name", error = name_err }, {
				input_node(ed, NAME_ID, { key = "input", placeholder = "我的自动化任务" }),
			}),
		}),
		N("col", { key = "triggers", gap = "sm" }, triggers),
		prompt_section(st, ed),
		files_section(ed),
		steps_section(ed),
		N("field", { key = "notify", label = "通知" }, {
			N("row", { key = "row", gap = "md", align = "center", wrap = true }, {
				N("switch", { key = "sw", variant = "compact", label = "应用通知", on = raw.notify ~= false }),
				N("switch", {
					key = "reply",
					variant = "compact",
					label = "在评论中回复",
					on = raw.reply == true,
					title = "由议题/PR 事件触发的运行:开始时在原处评论,结束后改成结果和最终回复",
				}),
			}),
		}),
		advanced_section(st, ed),
		N("text", {
			key = "summary",
			role = "roost.summary",
			spans = { tern.ui.span(reason or "可以保存", if reason then "warning" else "muted") },
		}),
	})
	-- A keyless col like the run form's: ids stay layer.editor.*; the discard question is a
	-- sibling overlay (layer.discard), stacked over the editor.
	local layer: { any } = {
		N("overlay", {
			key = "editor",
			role = "roost.form",
			modal = true,
			size = "lg",
			head = title,
			icon = if type(raw.icon) == "string" then raw.icon else "sparkle",
			foot = ROOT .. ".foot",
		}, {
			body,
			N("row", { key = "foot", gap = "sm", justify = "end" }, foot),
		}),
	}
	if ed.discard then
		table.insert(layer, discard_overlay())
	end
	return N("col", {}, layer)
end

-- ---------------------------------------------------------------------------------------------
-- Events and keys.

local function focus_at(st: any, ed: Editor, id: string)
	ed.focus = id
	ed.discard = false
	st.cx:frame({ { "focus", id } })
end

local function cycle(st: any, ed: Editor, delta: number)
	local slots = ed.slots
	if #slots == 0 then
		return
	end
	local cur = ed.focus
	local idx = 1
	for i, id in slots do
		if id == cur then
			idx = i
			break
		end
	end
	local next_i = ((idx - 1 + delta) % #slots) + 1
	focus_at(st, ed, slots[next_i])
end

local function trig_at(ed: Editor, i: number?): any?
	if not i then
		return nil
	end
	local tr = triggers_of(ed.raw)[i]
	return if type(tr) == "table" then tr else nil
end

local function index_in(id: string, mark: string): number?
	local n = string.match(id, mark .. "(%d+)")
	return if n then tonumber(n) else nil
end

local function on_select(st: any, ed: Editor, id: string, value: string)
	local i = index_in(id, "%.t")
	local tr = trig_at(ed, i)
	ed.opens[id] = false
	if tr and string.sub(id, -5) == ".freq" then
		set_schedule(ed, i :: number, value)
	elseif tr and string.sub(id, -5) == ".span" then
		if value == "all" then
			tr.between = nil
		else
			tr.between = tr.between or { "09:00", "18:00" }
		end
		touch(ed)
	elseif tr and (string.sub(id, -3) == ".sh" or string.sub(id, -3) == ".eh") then
		local between = tr.between
		if type(between) ~= "table" then
			between = { "09:00", "18:00" }
			tr.between = between
		end
		local which = if string.sub(id, -3) == ".sh" then 1 else 2
		between[which] = `{value}:00`
		touch(ed)
	elseif tr and (string.sub(id, -5) == ".hour" or string.sub(id, -7) == ".minute") then
		local hour, minute = clock_parts(tr)
		if string.sub(id, -5) == ".hour" then
			hour = value
		else
			minute = value
		end
		if tr.schedule == "once" then
			-- A once trigger keeps its clock in `at`; it has no `time` key.
			local date = if type(tr.at) == "string" then string.match(tr.at, "^(%d%d%d%d%-%d%d%-%d%d)") else nil
			tr.at = `{date or today()} {hour}:{minute}`
		else
			tr.time = `{hour}:{minute}`
		end
		touch(ed)
	elseif tr and string.sub(id, -4) == ".day" then
		tr.day = tonumber(value) or tr.day
		touch(ed)
	elseif tr and string.find(id, ".event.sel", 1, true) then
		tr.event = value
		touch(ed)
	elseif string.find(id, ".pmodel", 1, true) then
		local step = ensure_prompt(ed)
		step.model = if value == "auto" or value == "" then nil else value
		touch(ed)
	elseif string.find(id, ".bar.kind", 1, true) then
		local si = index_in(id, "%.s")
		if si then
			set_step_kind(ed, si, value)
		end
	elseif string.find(id, ".tabact.sel", 1, true) then
		local si = index_in(id, "%.s")
		local step = if si then steps_of(ed.raw)[si] else nil
		if type(step) == "table" and step_kind(step) == "tab" then
			if value == "close" then
				step.tab = "close"
				step.title, step.command, step.keep, step.focus = nil, nil, nil, nil
			else
				step.tab = "open"
			end
			touch(ed)
		end
	elseif tr and string.find(id, ".streak.sel", 1, true) then
		local n = tonumber(value)
		if n and n >= 1 and n <= 10 then
			tr.streak = if n == 1 then nil else n
		end
		touch(ed)
	elseif string.find(id, ".file.sel", 1, true) then
		local si = index_in(id, "%.s")
		local step = if si then steps_of(ed.raw)[si] else nil
		if type(step) == "table" and step_kind(step) == "file" then
			step.file = value
			touch(ed)
		end
	elseif string.find(id, ".advanced.ws", 1, true) then
		ed.raw.workspace = value
		touch(ed)
	elseif string.find(id, ".advanced.env.sel", 1, true) then
		ed.raw.environment = if value == "" then nil else value
		touch(ed)
	elseif string.find(id, ".advanced.who", 1, true) then
		ed.raw.identity = if value == "" then nil else value
		touch(ed)
	elseif string.find(id, ".advanced.conc", 1, true) then
		ed.raw.concurrency = value
		touch(ed)
	elseif string.find(id, ".advanced.tz", 1, true) then
		local ti = index_in(id, "tz")
		local target = trig_at(ed, ti)
		if target then
			target.tz = if value == "" then nil else value
			touch(ed)
		end
	elseif string.find(id, ".advanced.repo", 1, true) then
		local ti = index_in(id, "repo")
		local target = trig_at(ed, ti)
		if target then
			target.repo = if value == "" then nil else value
			touch(ed)
		end
	end
	check_now(st)
end

local function on_menu(st: any, ed: Editor, act: string)
	ed.opens[ROOT .. ".body.triggers.add"] = false
	ed.opens[ROOT .. ".body.head.icon"] = false
	local sched = string.match(act, "^sched:(.+)$")
	local gh = string.match(act, "^gh:(.+)$")
	local icon = string.match(act, "^icon:(.+)$")
	local roost = string.match(act, "^roost:(.+)$")
	if sched then
		add_trigger(ed, sched)
	elseif gh then
		add_trigger(ed, gh)
	elseif act == "api:new" then
		table.insert(triggers_of(ed.raw), { api = "" })
		touch(ed)
	elseif roost then
		table.insert(triggers_of(ed.raw), { roost = roost })
		touch(ed)
	elseif icon then
		ed.raw.icon = icon
		touch(ed)
	else
		return
	end
	check_now(st)
end

local function on_action(st: any, ed: Editor, act: string)
	if act == "save" then
		save(st)
		return
	end
	if act == "cancel" or act == "discard-stay" then
		if act == "cancel" and ed.dirty then
			ed.discard = true
			render(st)
			return
		end
		ed.discard = false
		if act == "cancel" then
			M.close(st)
		end
		render(st)
		return
	end
	if act == "discard-go" then
		M.close(st)
		render(st)
		return
	end
	if act == "delete" then
		delete_workflow(st)
		return
	end
	if act == "file-add" then
		sync_files(ed)
		local f = ed.buf[FILE_ADD_ID]
		local path = util.trim(if f then f.text else "")
		if path == "" then
			path = "script.py"
		elseif string.find(path, ".", 1, true) == nil then
			path = path .. ".py"
		end
		if not model.valid_file_path(path) then
			st.cx:toast("error", "文件路径无效")
			render(st)
			return
		end
		if ed.files[path] ~= nil then
			st.cx:toast("error", "文件已存在")
			render(st)
			return
		end
		ed.files[path] = ""
		ed.file_sel = path
		ed.buf[FILE_EDIT_ID] = { text = "", cursor = 0, lines = true }
		ed.file_edit_for = path
		ed.buf[FILE_REN_ID] = { text = path, cursor = utf8_len(path) }
		ed.file_ren_for = path
		if f then
			f.text = "script.py"
			f.cursor = utf8_len(f.text)
		end
		touch(ed)
		check_now(st)
		return
	end
	if act == "file-ren" then
		sync_files(ed)
		local sel = ed.file_sel
		local f = ed.buf[FILE_REN_ID]
		local path = util.trim(if f then f.text else "")
		if type(sel) ~= "string" or ed.files[sel] == nil then
			return
		end
		if path == "" or path == sel then
			return
		end
		if not model.valid_file_path(path) then
			st.cx:toast("error", "文件路径无效")
			render(st)
			return
		end
		if ed.files[path] ~= nil then
			st.cx:toast("error", "文件已存在")
			render(st)
			return
		end
		local body = ed.files[sel]
		ed.files[path] = body
		ed.files[sel] = nil
		ed.file_sel = path
		ed.buf[FILE_EDIT_ID] = { text = body, cursor = utf8_len(body), lines = true }
		ed.file_edit_for = path
		ed.buf[FILE_REN_ID] = { text = path, cursor = utf8_len(path) }
		ed.file_ren_for = path
		touch(ed)
		check_now(st)
		return
	end
	local file_sel = string.match(act, "^file%-sel:(.+)$")
	if file_sel then
		sync_files(ed)
		if ed.files[file_sel] ~= nil then
			ed.file_sel = file_sel
			local body = ed.files[file_sel]
			ed.buf[FILE_EDIT_ID] = { text = body, cursor = utf8_len(body), lines = true }
			ed.file_edit_for = file_sel
			ed.buf[FILE_REN_ID] = { text = file_sel, cursor = utf8_len(file_sel) }
			ed.file_ren_for = file_sel
			touch(ed)
			render(st)
		end
		return
	end
	local file_del = string.match(act, "^file%-del:(.+)$")
	if file_del then
		sync_files(ed)
		if ed.files[file_del] == nil then
			return
		end
		if ed.confirm_file ~= file_del then
			ed.confirm_file = file_del
			render(st)
			return
		end
		ed.files[file_del] = nil
		ed.confirm_file = nil
		if ed.file_sel == file_del then
			ed.file_sel = sorted_file_paths(ed.files)[1]
			ed.file_edit_for = nil
			ed.file_ren_for = nil
			ed.buf[FILE_EDIT_ID] = nil
			ed.buf[FILE_REN_ID] = nil
		end
		touch(ed)
		check_now(st)
		return
	end
	if act == "lib-add" then
		local f = ed.buf[LIBS_ADD_ID]
		local name = util.trim(if f then f.text else "")
		if name == "" then
			return
		end
		if not model.valid_lib(name) then
			st.cx:toast("error", "文件库名无效")
			render(st)
			return
		end
		local cur = str_list(ed.raw.libs)
		for _, item in cur do
			if item == name then
				if f then
					f.text = ""
					f.cursor = 0
				end
				return
			end
		end
		table.insert(cur, name)
		ed.raw.libs = cur
		ed.lib_cache[name] = nil
		if f then
			f.text = ""
			f.cursor = 0
		end
		touch(ed)
		check_now(st)
		return
	end
	local lib_del = string.match(act, "^lib%-del:(%d+)$")
	if lib_del then
		local cur = str_list(ed.raw.libs)
		local idx = tonumber(lib_del) :: number
		if cur[idx] then
			local gone = cur[idx]
			table.remove(cur, idx)
			ed.raw.libs = if #cur == 0 then nil else cur
			ed.lib_cache[gone] = nil
			touch(ed)
			check_now(st)
		end
		return
	end
	if act == "advanced" then
		ed.advanced = not ed.advanced
		if ed.advanced and not ed.buf[ID_ID] then
			local raw_id = ed.raw.id
			seed(ed, ID_ID, if type(raw_id) == "string" then raw_id else "")
		end
		render(st)
		return
	end
	if act == "step-add" then
		add_step(ed)
		check_now(st)
		return
	end
	local up = string.match(act, "^step%-up:(%d+)$")
	local down = string.match(act, "^step%-down:(%d+)$")
	local del = string.match(act, "^step%-del:(%d+)$")
	if up then
		swap_steps(ed, tonumber(up) :: number, (tonumber(up) :: number) - 1)
		check_now(st)
		return
	end
	if down then
		swap_steps(ed, tonumber(down) :: number, (tonumber(down) :: number) + 1)
		check_now(st)
		return
	end
	if del then
		delete_step(ed, tonumber(del) :: number)
		check_now(st)
		return
	end
	local trig = string.match(act, "^trig%-del:(%d+)$")
	if trig then
		delete_trigger(ed, tonumber(trig) :: number)
		-- Shown tokens are keyed by position: after a delete they would sit on the wrong card.
		ed.api_tokens = {}
		check_now(st)
		return
	end
	local api_i = string.match(act, "^api%-gen:(%d+)$")
	if api_i then
		local n = tonumber(api_i) :: number
		core.new_api_token(st.core, function(token, hash, err)
			local cur = ed_of(st)
			local tr = if cur == ed then trig_at(ed, n) else nil
			if not tr or tr.api == nil then
				return
			end
			if token and hash then
				tr.api = hash
				ed.api_tokens[n] = token
				touch(ed)
				check_now(st)
			else
				st.cx:toast("error", err or "无法生成令牌")
			end
			render(st)
		end)
		return
	end
	local copy_i = string.match(act, "^api%-copy:(%d+)$")
	if copy_i then
		local token = ed.api_tokens[tonumber(copy_i) :: number]
		if token then
			st.cx:copy(token)
			st.cx:toast("info", "已复制令牌")
		end
		return
	end
	local day_i, day_id = string.match(act, "^day:(%d+):([%w_]+)$")
	if day_i and day_id then
		local tr = trig_at(ed, tonumber(day_i))
		if tr then
			toggle_day(tr, day_id)
			touch(ed)
			check_now(st)
		end
		return
	end
	local ci, fkey, cj = string.match(act, "^cdel:(%d+):([%w_]+):(%d+)$")
	if ci and fkey and cj then
		local tr = trig_at(ed, tonumber(ci))
		if tr then
			remove_chip(tr, fkey, tonumber(cj) :: number)
			touch(ed)
			check_now(st)
		end
		return
	end
	local si, skey, sj = string.match(act, "^sug:(%d+):([%w_]+):(%d+)$")
	if si and skey and sj then
		local tr = trig_at(ed, tonumber(si))
		local items = ed.suggest[`{si}:{skey}`]
		local value = items and items[tonumber(sj) :: number]
		if tr and type(value) == "string" and add_chip(tr, skey, value) then
			local input_id = tid(tonumber(si) :: number, "card", skey, "add")
			local f = ed.buf[input_id]
			if f then
				f.text = ""
				f.cursor = 0
			end
			touch(ed)
			check_now(st)
		end
		return
	end
	local chi, chkey, chj = string.match(act, "^choice:(%d+):([%w_]+):(%d+)$")
	if chi and chkey and chj then
		local tr = trig_at(ed, tonumber(chi))
		local value: string? = nil
		local f = keyed_filter(chkey)
		if f and f.options then
			local opt = f.options[tonumber(chj) :: number]
			value = if opt then opt.value else nil
		end
		if tr and value then
			toggle_choice(tr, chkey, value)
			touch(ed)
			check_now(st)
		end
		return
	end
	local evolve_del = string.match(act, "^evolve%-del:(%d+)$")
	if evolve_del then
		local shown: { string } = {}
		for _, item in str_list(ed.raw.evolve) do
			if item ~= "*" then
				table.insert(shown, item)
			end
		end
		table.remove(shown, tonumber(evolve_del) :: number)
		ed.raw.evolve = if #shown == 0 then nil else shown
		touch(ed)
		check_now(st)
		return
	end
	local evolve_sug = string.match(act, "^evolve%-sug:(%d+)$")
	if evolve_sug then
		local items = ed.suggest.evolve
		local value = items and items[tonumber(evolve_sug) :: number]
		if type(value) == "string" then
			local cur: { string } = {}
			for _, item in str_list(ed.raw.evolve) do
				if item ~= "*" then
					table.insert(cur, item)
				end
			end
			if add_chip({ ids = cur }, "ids", value) then
				ed.raw.evolve = cur
				local f = ed.buf[EVOLVE_ADD_ID]
				if f then
					f.text = ""
					f.cursor = 0
				end
				touch(ed)
				check_now(st)
			end
		end
		return
	end
	if act == "evolve-add" then
		local f = ed.buf[EVOLVE_ADD_ID]
		local name = util.trim(if f then f.text else "")
		if name == "" then
			return
		end
		if name == "*" then
			ed.raw.evolve = { "*" }
		else
			local cur: { string } = {}
			for _, item in str_list(ed.raw.evolve) do
				if item ~= "*" then
					table.insert(cur, item)
				end
			end
			if add_chip({ ids = cur }, "ids", name) then
				ed.raw.evolve = cur
			end
		end
		if f then
			f.text = ""
			f.cursor = 0
		end
		touch(ed)
		check_now(st)
		return
	end
	if string.sub(act, 1, 5) == "icon:" or string.sub(act, 1, 6) == "sched:" or string.sub(act, 1, 3) == "gh:" or string.sub(act, 1, 6) == "roost:" or act == "api:new" then
		on_menu(st, ed, act)
	end
end

local function on_switch(st: any, ed: Editor, id: string, value: boolean)
	local i = index_in(id, "%.t")
	local tr = trig_at(ed, i)
	if tr and string.find(id, ".card.", 1, true) then
		local key = string.match(id, "%.([%w_]+)$")
		if key then
			tr[key] = value
			touch(ed)
			check_now(st)
		end
		return
	end
	if string.sub(id, -17) == ".notify.row.reply" then
		ed.raw.reply = if value then true else nil
		touch(ed)
		check_now(st)
		return
	end
	if string.sub(id, -3) == ".sw" then
		ed.raw.notify = value
		touch(ed)
		check_now(st)
		return
	end
	if string.find(id, ".advanced.enabled", 1, true) then
		ed.raw.enabled = value
		touch(ed)
		check_now(st)
		return
	end
	if string.find(id, ".advanced.manual", 1, true) then
		ed.raw.manual = value
		touch(ed)
		check_now(st)
		return
	end
	if string.find(id, ".advanced.evolveall", 1, true) then
		if value then
			ed.raw.evolve = { "*" }
		else
			local cur: { string } = {}
			for _, item in str_list(ed.raw.evolve) do
				if item ~= "*" then
					table.insert(cur, item)
				end
			end
			ed.raw.evolve = if #cur == 0 then nil else cur
		end
		touch(ed)
		check_now(st)
		return
	end
	local step_i = index_in(id, "%.s")
	if step_i and (string.sub(id, -5) == ".keep" or string.sub(id, -6) == ".focus") then
		local step = steps_of(ed.raw)[step_i]
		if type(step) == "table" and step_kind(step) == "tab" and step.tab ~= "close" then
			local key = if string.sub(id, -5) == ".keep" then "keep" else "focus"
			step[key] = if value then true else nil
			touch(ed)
			check_now(st)
		end
		return
	end
	local assoc = string.match(id, "assoc(%d+)$")
	if assoc then
		local target = trig_at(ed, tonumber(assoc))
		if target then
			target.associations = if value then { "*" } else nil
			touch(ed)
			check_now(st)
		end
	end
end

local function on_date(st: any, ed: Editor, id: string, value: string)
	local i = index_in(id, "%.t")
	local tr = trig_at(ed, i)
	if not tr or type(value) ~= "string" then
		return
	end
	if tr.schedule == "once" then
		local date = string.match(value, "^(%d%d%d%d%-%d%d%-%d%d)")
		local hour, minute = clock_parts(tr)
		tr.at = if date then `{date} {hour}:{minute}` else value
	elseif tr.schedule == "yearly" then
		local md = string.match(value, "%d%d%d%d%-(%d%d%-%d%d)")
		if md then
			tr.date = md
		end
	end
	touch(ed)
	check_now(st)
end

-- After a key or a native edit changed field `id`: keep the raw table and file buffers in step.
local function edited(st: any, ed: Editor, id: string, f: field.Field)
	touch(ed)
	if id == NAME_ID then
		ed.raw.name = f.text
	end
	if id == FILE_EDIT_ID and type(ed.file_sel) == "string" and ed.files[ed.file_sel] ~= nil then
		ed.files[ed.file_sel] = f.text
	end
	schedule_check(st, ed)
	render(st)
end

function M.event(st: any, ev: any): boolean
	local ed = ed_of(st)
	if not ed then
		return false
	end
	local id = if type(ev.id) == "string" then ev.id else ""
	if ev.ev == "focus" then
		if ed.buf[id] then
			focus_at(st, ed, id)
		end
		return true
	end
	if ev.ev == "edit" then
		local f = ed.buf[id]
		if f and field.edit(f, ev) then
			if id == ID_ID then
				ed.custom_id = true
			end
			edited(st, ed, id, f)
		end
		return true
	end
	if ev.ev == "change" then
		local sid_open = id
		if type(ev.value) == "boolean" then
			on_switch(st, ed, sid_open, ev.value)
		elseif type(ev.value) == "string" and string.find(id, ".date", 1, true) then
			on_date(st, ed, id, ev.value)
		elseif type(ev.value) == "string" then
			on_select(st, ed, id, ev.value)
		end
		return true
	end
	if ev.ev == "toggle" then
		ed.opens[id] = ev.open == true
		render(st)
		return true
	end
	if ev.ev == "action" then
		local act = ev.act or ev.item
		if type(act) == "string" then
			on_action(st, ed, act)
		end
		return true
	end
	return true
end

local function commit_chip(st: any, ed: Editor, id: string): boolean
	if id == LIBS_ADD_ID or id == EVOLVE_ADD_ID then
		on_action(st, ed, if id == LIBS_ADD_ID then "lib-add" else "evolve-add")
		return true
	end
	if id == FILE_ADD_ID then
		on_action(st, ed, "file-add")
		return true
	end
	local i = index_in(id, "%.t")
	local key = string.match(id, "%.card%.([%w_]+)%.add$")
	local tr = trig_at(ed, i)
	local f = ed.buf[id]
	if not tr or not key or not f then
		return false
	end
	if add_chip(tr, key, f.text) then
		f.text = ""
		f.cursor = 0
		touch(ed)
		check_now(st)
	end
	return true
end

function M.key(st: any, key: any): boolean
	local ed = ed_of(st)
	if not ed then
		return false
	end
	if key.name == "escape" then
		for id, open in ed.opens do
			if open then
				ed.opens[id] = false
				render(st)
				return true
			end
		end
		if ed.discard then
			ed.discard = false
			render(st)
			return true
		end
		if ed.dirty then
			ed.discard = true
			render(st)
			return true
		end
		M.close(st)
		render(st)
		return true
	end
	if key.name == "enter" and key.meta then
		save(st)
		return true
	end
	if key.name == "tab" then
		cycle(st, ed, if key.shift then -1 else 1)
		render(st)
		return true
	end
	local id = ed.focus
	local f = if id then ed.buf[id] else nil
	if not f or not id then
		return true
	end
	if key.name == "enter" and not key.meta and not key.ctrl and not f.lines then
		if id == FILE_ADD_ID or id == LIBS_ADD_ID or string.sub(id, -4) == ".add" then
			commit_chip(st, ed, id)
		else
			check_now(st)
		end
		return true
	end
	if id == ID_ID then
		ed.custom_id = true
		if key.name == "backspace" or key.name == "delete" then
			if f.text == "" then
				ed.custom_id = false
				if ed.mode ~= "edit" then
					ed.raw.id = nil
				end
			end
		end
	end
	if field.key(f, key) then
		edited(st, ed, id, f)
	end
	return true
end

return M
