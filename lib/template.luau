--!strict
-- `{{ name }}` templates for omp prompts. Shell steps never see templates: they read `ROOST_*`
-- environment variables, so event text can't be injected into a command line.

local M = {}

-- Plain variables every run has (empty when the trigger doesn't set them). `request`: a mention's
-- text without the mentions. `evolve_*`: runs of a workflow with `evolve` (lib/evolve.luau): its
-- material directory, and the workflow and run that triggered it (empty for scheduled or manual runs).
M.VARS = {
	"repo", "event", "action", "number", "title", "body", "url", "ref", "sha", "branch",
	"sender", "comment", "request", "label", "workflow", "run_id", "trigger", "evolve_dir", "evolve_target", "evolve_run",
}

local KNOWN: { [string]: boolean } = {}
for _, v in M.VARS do
	KNOWN[v] = true
end

-- Largest rendered prompt; a payload field can't blow up an argv past this.
M.MAX_RENDERED = 256 * 1024

export type Part = { lit: string?, path: { string }? }
export type Template = { parts: { Part } }

function M.parse(src: string): (Template?, string?)
	local parts: { Part } = {}
	local pos = 1
	while true do
		local open = string.find(src, "{{", pos, true)
		if not open then
			break
		end
		if open > pos then
			table.insert(parts, { lit = string.sub(src, pos, open - 1) })
		end
		local close = string.find(src, "}}", open + 2, true)
		if not close then
			return nil, "模板中 {{ 没有闭合"
		end
		local name = string.match(string.sub(src, open + 2, close - 1), "^%s*(.-)%s*$") or ""
		if name == "" then
			return nil, "模板中有空的 {{ }}"
		end
		local path = {}
		for seg in string.gmatch(name .. ".", "([^.]*)%.") do
			local s = string.match(seg, "^%s*(.-)%s*$") or ""
			if s == "" then
				return nil, `模板变量 {name} 无效`
			end
			table.insert(path, s)
		end
		table.insert(parts, { path = path })
		pos = close + 2
	end
	if pos <= #src then
		table.insert(parts, { lit = string.sub(src, pos) })
	end
	return { parts = parts }, nil
end

-- Rejects unknown variables and undeclared inputs.
function M.check(t: Template, inputs: { [string]: boolean }): string?
	for _, p in t.parts do
		local path = p.path
		if path then
			local head = path[1]
			if head == "payload" then
				continue
			elseif head == "input" then
				if #path ~= 2 or not inputs[path[2]] then
					return `{table.concat(path, ".")} 不是已声明的 [[workflow.input]]`
				end
			elseif head == "out" then
				-- Step outputs only exist at run time: any well-formed name is accepted.
				if #path ~= 2 or #path[2] > 64 or not string.match(path[2], "^[%a_][%w_]*$") then
					return `{table.concat(path, ".")} 无效:输出名为字母、数字、下划线`
				end
			elseif not (KNOWN[head] and #path == 1) then
				return `未知变量 {table.concat(path, ".")}(可用:{table.concat(M.VARS, ", ")}, input.<名>, out.<名>, payload.<路径>)`
			end
		end
	end
	return nil
end

-- Renders against `ctx`; missing values render empty.
function M.render(t: Template, ctx: { [string]: any }): string
	local out: { string } = {}
	local size = 0
	for _, p in t.parts do
		local piece = p.lit
		local path = p.path
		if path then
			local v: any = ctx
			for _, seg in path do
				if type(v) ~= "table" then
					v = nil
					break
				end
				local nv = v[seg]
				if nv == nil then
					local i = tonumber(seg)
					-- `labels.0` is the first element, as in JSON paths.
					nv = if i then v[i + 1] else nil
				end
				v = nv
			end
			if v == nil or type(v) == "table" or type(v) == "userdata" then
				piece = if type(v) == "table" then tern.json.encode(v) else ""
			else
				piece = tostring(v)
			end
		end
		local s = piece or ""
		if size + #s > M.MAX_RENDERED then
			table.insert(out, string.sub(s, 1, M.MAX_RENDERED - size))
			table.insert(out, "\n…[truncated]")
			break
		end
		size += #s
		table.insert(out, s)
	end
	return table.concat(out)
end

return M
