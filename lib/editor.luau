--!strict
-- Automation editor ("新建/编辑自动化"). ui.luau owns the block; this module owns the overlay.
-- Text fields are program-owned (lib/field.luau). Selects, switches, menus and dates are pointer-only.
-- Node ids under layer.editor are the contract the key handler and tests share:
--   body.head.name.input, body.head.icon, body.triggers.add, body.triggers.tN.sentence.*,
--   body.triggers.tN.card.*, body.prompt.stack.input, body.prompt.bar.pmodel,
--   body.steps.sN.*, body.notify.sw, body.advanced.*, foot.save, foot.del, layer.discard.

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

local function step_kind(step: any): string
	if type(step) == "table" and type(step.run) == "string" and type(step.omp) ~= "string" then
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
	if step_kind(step) == "run" then
		return if type(step.run) == "string" then step.run else ""
	end
	return if type(step.omp) == "string" then step.omp else ""
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
			local text_f = ed.buf[sid(i, "text", "input")]
			if text_f then
				if step_kind(step) == "run" then
					step.run = text_f.text
					step.omp = nil
				else
					step.omp = text_f.text
					step.run = nil
				end
			end
		end
	end
end

local function sync_prompt(ed: Editor)
	local f = ed.buf[PROMPT_ID]
	if not f then
		return
	end
	local steps = steps_of(ed.raw)
	local idx = prompt_index(ed)
	if f.text == "" then
		local step = if idx then steps[idx] else nil
		if idx and ed.prompt_inserted and step.model == nil then
			-- A prompt step the editor added and nothing else uses: take it back out.
			table.remove(steps, idx)
			ed.prompt, ed.prompt_inserted = nil, false
			drop_prefix(ed, ROOT .. ".body.steps.")
		elseif step then
			step.omp = ""
		end
		return
	end
	if not idx then
		local step = { name = "指令", omp = f.text }
		table.insert(steps, 1, step)
		ed.prompt, ed.prompt_inserted = step, true
		drop_prefix(ed, ROOT .. ".body.steps.")
		return
	end
	local step = steps[idx]
	step.omp = f.text
	step.run = nil
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
	sync_text_field(ed, DESC_ID, "description")
	sync_text_field(ed, TIMEOUT_ID, "timeout")
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
	ed.issues = core.check_workflow(st.core, ed.old_id, ed.raw)
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

local function set_step_kind(ed: Editor, i: number, kind: string)
	local step = steps_of(ed.raw)[i]
	if type(step) ~= "table" or (kind ~= "omp" and kind ~= "run") then
		return
	end
	local text = step_text(step)
	step.kind = nil
	if kind == "omp" then
		step.omp = text
		step.run = nil
	else
		step.run = text
		step.omp = nil
		-- Only omp steps take a model or omp args; leaving them would make the step unsavable.
		step.model = nil
		step.args = nil
	end
	local f = ed.buf[sid(i, "text", "input")]
	if f then
		f.text = text
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
		if type(tr) == "table" and tr.schedule == nil and tr.github == nil and type(tr.cron) == "string" then
			tr.schedule = "cron"
		end
	end
	if ed.mode == "edit" then
		seed(ed, ID_ID, if type(raw.id) == "string" then raw.id else "")
	end
	seed(ed, DESC_ID, if type(raw.description) == "string" then raw.description else "")
	local timeout = raw.timeout
	seed(ed, TIMEOUT_ID, if type(timeout) == "string" then timeout elseif type(timeout) == "number" then tostring(timeout) else "")
end

function M.close(st: any)
	local ed = ed_of(st)
	if ed then
		cancel_timer(ed)
	end
	st.editor = nil
end

function M.open(st: any, mode: string, arg: string?)
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
		discard = false,
		advanced = false,
		custom_id = false,
		prompt_inserted = false,
		prompt = nil,
		timer = nil,
		suggest = {},
		busy = false,
	}
	st.editor = ed
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
	ed.issues = core.check_workflow(st.core, ed.old_id, ed.raw)
	if #ed.issues > 0 then
		render(st)
		return
	end
	ed.busy = true
	local issues = core.save_workflow(st.core, ed.old_id, ed.raw)
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
	return N("row", { key = "sentence", role = "roost.trigger", gap = "xs", align = "center" }, children), err
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
			variant = "quiet",
			title = "移除",
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
	local sug: { any } = {}
	if hint then
		table.insert(sug, txt(hint, "hint", "muted"))
	elseif err then
		table.insert(sug, txt(err, "err", "warning"))
	elseif loading and #items == 0 then
		table.insert(sug, txt("加载中…", "loading", "muted"))
	end
	for j, item in items do
		table.insert(sug, N("button", {
			key = `b{j}`,
			text = item,
			size = "sm",
			variant = "quiet",
			actions = { click = `sug:{i}:{f.key}:{j}` },
		}))
	end
	local filter_err = field_error(ed, function(path)
		return string.find(path, `.trigger[{i}].{f.key}`, 1, true) ~= nil
	end)
	local children: { any } = {
		txt(f.label, "lab", "muted"),
		N("row", { key = "chips", gap = "xs", role = "roost.chips" }, chips),
		input_node(ed, input_id, { key = "add", placeholder = f.hint or "输入后回车添加" }),
	}
	if #sug > 0 then
		table.insert(children, N("col", { key = "sug", gap = "xs" }, sug))
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
	return N("row", { key = f.key, gap = "xs", align = "center" }, {
		txt(f.label, "lab", "muted"),
		N("row", { key = "opts", gap = "xs" }, buttons),
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

local function trigger_node(st: any, ed: Editor, i: number, tr: any): any
	if type(tr) == "table" and type(tr.github) == "string" then
		return N("col", { key = `t{i}`, gap = "xs" }, { github_card(st, ed, i, tr) })
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

local function model_options(current: string?): { any }
	local opts = {
		{ value = "auto", label = "Auto" },
		{ value = "opus", label = "opus" },
		{ value = "sonnet", label = "sonnet" },
		{ value = "haiku", label = "haiku" },
	}
	if type(current) == "string" and current ~= "" and current ~= "auto" then
		return with_current(opts, current, current)
	end
	return opts
end

local function prompt_section(ed: Editor): any
	local step = prompt_step(ed)
	local model_id = if step and type(step.model) == "string" then step.model else "auto"
	seed(ed, PROMPT_ID, if step then step_text(step) else "", true)
	local idx = prompt_index(ed)
	local err = field_error(ed, function(path)
		return idx ~= nil and string.find(path, `.step[{idx}]`, 1, true) ~= nil
	end)
	return N("col", { key = "prompt", gap = "xs" }, {
		txt("指令", "h"),
		N("field", { key = "stack", error = err }, {
			editor_node(ed, PROMPT_ID, { key = "input", placeholder = "让 Roost 做什么", lines = true }),
		}),
		N("row", { key = "bar", gap = "xs" }, {
			N("select", {
				key = "pmodel",
				value = model_id,
				options = model_options(model_id),
				title = "模型",
				disabled = if step then false else "先写指令,再选模型",
				open = ed.opens[ROOT .. ".body.prompt.bar.pmodel"] == true,
			}),
		}),
	})
end

local function steps_section(ed: Editor): any
	local steps = steps_of(ed.raw)
	local prompt_at = prompt_index(ed)
	local rows: { any } = { txt("更多步骤", "h") }
	local any_extra = false
	for i, step in steps do
		if i ~= prompt_at and type(step) == "table" then
			any_extra = true
			local kind = step_kind(step)
			local name_id = sid(i, "name", "input")
			local text_id = sid(i, "text", "input")
			seed(ed, name_id, if type(step.name) == "string" then step.name else "")
			seed(ed, text_id, step_text(step))
			local err = field_error(ed, function(path)
				return string.find(path, `.step[{i}]`, 1, true) ~= nil
			end)
			table.insert(rows, N("col", { key = `s{i}`, gap = "xs", role = "roost.steps" }, {
				N("row", { key = "bar", gap = "xs", align = "center" }, {
					N("select", {
						key = "kind",
						value = kind,
						options = { { value = "omp", label = "指令" }, { value = "run", label = "命令" } },
						open = ed.opens[sid(i, "bar", "kind")] == true,
					}),
					N("button", { key = "up", text = "↑", title = "上移", size = "sm", variant = "quiet", actions = { click = `step-up:{i}` } }),
					N("button", { key = "down", text = "↓", title = "下移", size = "sm", variant = "quiet", actions = { click = `step-down:{i}` } }),
					N("button", { key = "del", text = "删除", title = "删除步骤", size = "sm", variant = "quiet", actions = { click = `step-del:{i}` } }),
				}),
				N("field", { key = "name", label = "名称", error = if err and string.find(err, "名", 1, true) then err else nil }, {
					input_node(ed, name_id, { key = "input", placeholder = "步骤名称" }),
				}),
				N("field", { key = "text", error = err }, {
					input_node(ed, text_id, { key = "input", placeholder = if kind == "run" then "shell 脚本" else "提示词" }),
				}),
			}))
		end
	end
	if not any_extra then
		table.insert(rows, txt("只有指令一步。需要 shell 或更多指令时再添加。", "empty", "muted"))
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

local function discard_overlay(): any
	return N("overlay", {
		key = "discard",
		modal = true,
		size = "sm",
		head = "放弃未保存的更改?",
		foot = "layer.discard.foot",
	}, {
		txt("关闭后,这次编辑不会写入 workflows.toml。", "msg", "muted"),
		N("row", { key = "foot", gap = "xs", justify = "end" }, {
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
		prompt_section(ed),
		steps_section(ed),
		N("field", { key = "notify", label = "通知" }, {
			N("switch", { key = "sw", variant = "compact", label = "应用通知", on = raw.notify ~= false }),
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
			N("row", { key = "foot", gap = "xs", justify = "end" }, foot),
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
	elseif string.find(id, ".advanced.ws", 1, true) then
		ed.raw.workspace = value
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
	if sched then
		add_trigger(ed, sched)
	elseif gh then
		add_trigger(ed, gh)
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
		check_now(st)
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
	if string.sub(act, 1, 5) == "icon:" or string.sub(act, 1, 6) == "sched:" or string.sub(act, 1, 3) == "gh:" then
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
		if string.sub(id, -4) == ".add" then
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
		touch(ed)
		if id == NAME_ID then
			ed.raw.name = f.text
		end
		schedule_check(st, ed)
		render(st)
	end
	return true
end

return M
