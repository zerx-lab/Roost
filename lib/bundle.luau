--!strict
-- The export file (`exports/<时间>-<名>.roost.toml`): workflows, their own files and the libraries
-- they use, in one TOML document that `decode` reads back for import:
--
--   [roost]                       format = 1, exported_at, workflows = [ids]
--   [repos."owner/name"]          branch / worktree only (local paths stay on this machine)
--   [[workflow]] …                each workflow as workflows.toml holds it
--   [[file]]                      workflow = "<id>" or library = "<库>", path, text
--   [[group]]                     name, workflows = [ids in this file]: the workflows page's groups
--                                 (lib/groups.luau), in page order; an export of every workflow
--                                 also lists empty groups. Older Roost ignores the table.
--
-- Text is written as a multi-line literal string when it can be (scripts stay readable).

local toml = require("./toml")
local model = require("./model")
local util = require("./util")
local groups = require("./groups")

local M = {}

M.FORMAT = 1
-- toml.parse reads at most this much.
M.MAX_BYTES = 1024 * 1024
M.SUFFIX = ".roost.toml"

export type File = { workflow: string?, library: string?, path: string, text: string }
export type Repo = { branch: string?, worktree: boolean? }
export type Group = { name: string, workflows: { string } }
export type Bundle = {
	exported_at: number,
	repos: { [string]: Repo },
	workflows: { { [string]: any } }, -- TOML-shaped, as model.raw_workflow returns them
	files: { File },
	groups: { Group },
}

-- `'''…'''` unless the text holds what a literal string can't (`'''`, a trailing quote, controls
-- other than tab and newline); then a basic string.
local function text_value(s: string): string
	local literal = string.find(s, "'''", 1, true) == nil
		and string.sub(s, -1) ~= "'"
		and string.find(s, "[%z\1-\8\11-\31\127]") == nil
	if literal then
		return "'''\n" .. s .. "'''"
	end
	return toml.quote(s)
end

function M.encode(b: Bundle, header: string): string
	local out: { string } = {}
	for line in string.gmatch(header, "[^\n]+") do
		table.insert(out, "# " .. line)
	end
	local ids: { string } = {}
	for _, raw in b.workflows do
		table.insert(ids, toml.quote(tostring(raw.id)))
	end
	table.insert(out, "")
	table.insert(out, "[roost]")
	table.insert(out, `format = {M.FORMAT}`)
	table.insert(out, `exported_at = {math.floor(b.exported_at)}`)
	table.insert(out, `workflows = [{table.concat(ids, ", ")}]`)
	for _, name in util.keys(b.repos) do
		local r = b.repos[name]
		table.insert(out, "")
		table.insert(out, `[repos.{toml.quote(name)}]`)
		if r.branch then
			table.insert(out, `branch = {toml.quote(r.branch)}`)
		end
		if r.worktree ~= nil then
			table.insert(out, `worktree = {if r.worktree then "true" else "false"}`)
		end
	end
	for _, raw in b.workflows do
		table.insert(out, "")
		table.insert(out, (string.gsub(model.encode_workflow(raw), "\n$", "")))
	end
	for _, f in b.files do
		table.insert(out, "")
		table.insert(out, "[[file]]")
		if f.workflow then
			table.insert(out, `workflow = {toml.quote(f.workflow)}`)
		else
			table.insert(out, `library = {toml.quote(f.library or "")}`)
		end
		table.insert(out, `path = {toml.quote(f.path)}`)
		table.insert(out, `text = {text_value(f.text)}`)
	end
	for _, g in b.groups do
		local quoted: { string } = {}
		for _, id in g.workflows do
			table.insert(quoted, toml.quote(id))
		end
		table.insert(out, "")
		table.insert(out, "[[group]]")
		table.insert(out, `name = {toml.quote(g.name)}`)
		table.insert(out, `workflows = [{table.concat(quoted, ", ")}]`)
	end
	return table.concat(out, "\n") .. "\n"
end

-- Reads an export back. Checks the shape only; whether the workflows are valid is the importer's
-- question (they are checked together with the workflows already here).
function M.decode(text: string): (Bundle?, string?)
	if #text > M.MAX_BYTES then
		return nil, `文件超过 {M.MAX_BYTES // (1024 * 1024)} MiB`
	end
	local root, extra = toml.parse(text)
	if root == nil then
		local e = extra :: toml.Err
		return nil, `第 {e.line} 行:{e.message}`
	end
	local meta = root.roost
	if type(meta) ~= "table" or meta.format ~= M.FORMAT then
		return nil, `不是 Roost 导出文件(缺少 [roost] format = {M.FORMAT})`
	end
	local b: Bundle = {
		exported_at = if type(meta.exported_at) == "number" then meta.exported_at else 0,
		repos = {},
		workflows = {},
		files = {},
		groups = {},
	}
	if root.repos ~= nil and type(root.repos) ~= "table" then
		return nil, "repos 应为表"
	end
	for name, r in root.repos or {} do
		if type(name) ~= "string" or not model.valid_repo(name) or type(r) ~= "table" then
			return nil, `repos 中的 "{tostring(name)}" 无效`
		end
		local branch, worktree = r.branch, r.worktree
		if (branch ~= nil and type(branch) ~= "string") or (worktree ~= nil and type(worktree) ~= "boolean") then
			return nil, `repos."{name}" 的 branch / worktree 无效`
		end
		b.repos[name] = { branch = branch, worktree = worktree }
	end
	local wfs = root.workflow
	if type(wfs) ~= "table" or #wfs == 0 then
		return nil, "文件中没有 [[workflow]]"
	end
	local ids: { [string]: boolean } = {}
	for _, w in wfs do
		if type(w) ~= "table" or type(w.id) ~= "string" or w.id == "" then
			return nil, "每个 [[workflow]] 都需要 id"
		elseif ids[w.id] then
			return nil, `重复的 workflow id "{w.id}"`
		end
		ids[w.id] = true
		table.insert(b.workflows, w)
	end
	if root.file ~= nil and type(root.file) ~= "table" then
		return nil, "file 应为 [[file]] 表数组"
	end
	local seen: { [string]: boolean } = {}
	for i, f in root.file or {} do
		local where = `第 {i} 个 [[file]]`
		if type(f) ~= "table" or type(f.path) ~= "string" or type(f.text) ~= "string" then
			return nil, `{where}:需要 path 与 text`
		end
		local wf, lib = f.workflow, f.library
		if (wf == nil) == (lib == nil) then
			return nil, `{where}:workflow 与 library 必须且只能有一个`
		elseif wf ~= nil and (type(wf) ~= "string" or not ids[wf]) then
			return nil, `{where}:workflow "{tostring(wf)}" 不在本文件中`
		elseif lib ~= nil and (type(lib) ~= "string" or not model.valid_lib(lib)) then
			return nil, `{where}:文件库名 "{tostring(lib)}" 无效`
		elseif not model.valid_file_path(f.path) then
			return nil, `{where}:路径 "{f.path}" 无效`
		end
		local key = string.lower(`{if wf then "w:" .. wf else "l:" .. lib}/{f.path}`)
		if seen[key] then
			return nil, `{where}:重复的文件 {f.path}(文件系统不区分大小写)`
		end
		seen[key] = true
		table.insert(b.files, { workflow = wf, library = lib, path = f.path, text = f.text })
	end
	if root.group ~= nil and type(root.group) ~= "table" then
		return nil, "group 应为 [[group]] 表数组"
	end
	local named = groups.empty()
	local placed: { [string]: boolean } = {}
	for i, g in root.group or {} do
		local where = `第 {i} 个 [[group]]`
		if type(g) ~= "table" or type(g.name) ~= "string" then
			return nil, `{where}:需要 name`
		end
		local nerr = groups.check_name(named, g.name, nil)
		if nerr then
			return nil, `{where}:{nerr}`
		end
		groups.create(named, g.name)
		if g.workflows ~= nil and type(g.workflows) ~= "table" then
			return nil, `{where}:workflows 应为数组`
		end
		local members: { string } = {}
		for _, id in g.workflows or {} do
			if type(id) ~= "string" or not ids[id] then
				return nil, `{where}:workflow "{tostring(id)}" 不在本文件中`
			elseif placed[id] then
				return nil, `{where}:工作流 {id} 出现在多个分组里`
			end
			placed[id] = true
			table.insert(members, id)
		end
		table.insert(b.groups, { name = g.name, workflows = members })
	end
	return b, nil
end

return M
