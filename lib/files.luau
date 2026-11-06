--!strict
-- Files Roost manages for workflows, under the plugin data directory:
--   workflows/<id>/files/<路径>   a workflow's own files, edited and saved with the workflow
--   library/<库>/<路径>           the file library: shared files workflows use by name (`libs`)
--   state/<组>/                   kept across runs ($ROOST_STATE); never removed automatically
--   runs/<运行>/files/            the run's copy of the workflow's files ($ROOST_FILES)
--   runs/<运行>/lib/<库>/         the run's copy of each library it uses ($ROOST_LIB)
--   runs/<运行>/tmp/              scratch ($ROOST_TMP), removed when the run ends
-- A run works on copies taken when it starts, so editing a script never changes a running one.
-- Listing skips hidden names and `__pycache__`; each tree is bounded (MAX_FILE, MAX_FILES, MAX_TOTAL).

local model = require("./model")

local M = {}

M.MAX_FILE = 512 * 1024
M.MAX_FILES = 200
M.MAX_TOTAL = 4 * 1024 * 1024
local MAX_DEPTH = 8

-- A tree's files: sorted relative paths and their contents.
export type Tree = { paths: { string }, text: { [string]: string } }

function M.workflow_home(data: string, id: string): string
	return `{data}/workflows/{id}`
end

function M.workflow_root(data: string, id: string): string
	return `{data}/workflows/{id}/files`
end

function M.lib_root(data: string, name: string): string
	return `{data}/library/{name}`
end

function M.state_dir(data: string, group: string): string
	return `{data}/state/{group}`
end

function M.exports_dir(data: string): string
	return `{data}/exports`
end

-- Where run `run_dir`'s copy of `ref` is.
function M.staged(run_dir: string, ref: model.FileRef): string
	return if ref.lib then `{run_dir}/lib/{ref.lib}/{ref.path}` else `{run_dir}/files/{ref.path}`
end

local function exists(path: string): boolean
	local ok, yes = pcall(tern.fs.exists, path)
	return ok and yes == true
end

-- A name listing shows: what valid_file_path accepts for one part, minus Python's caches.
local function listed(name: string): boolean
	return name ~= "__pycache__" and string.match(name, "^[%w_][%w_%.%-]*$") ~= nil
end

-- Reads every file under `root` (missing root: empty). Fails on anything it can't read as a
-- bounded regular file, so a copy is never silently partial.
function M.load(root: string): (Tree?, string?)
	local tree: Tree = { paths = {}, text = {} }
	if not exists(root) then
		return tree, nil
	end
	local total = 0
	local function walk(dir: string, prefix: string, depth: number): string?
		local ok, names = pcall(tern.fs.list, dir)
		if not ok or type(names) ~= "table" then
			return `无法列出目录 {if prefix == "" then "." else prefix}`
		end
		for _, name in names :: { string } do
			if not listed(name) then
				continue
			end
			local rel = if prefix == "" then name else `{prefix}/{name}`
			local path = `{dir}/{name}`
			local okr, text = pcall(tern.fs.read, path, M.MAX_FILE)
			if okr and type(text) == "string" then
				total += #text
				table.insert(tree.paths, rel)
				tree.text[rel] = text
				if #tree.paths > M.MAX_FILES then
					return `文件超过 {M.MAX_FILES} 个`
				elseif total > M.MAX_TOTAL then
					return `文件总大小超过 {M.MAX_TOTAL // (1024 * 1024)} MiB`
				end
			else
				-- Not a readable file: a directory, or something to refuse (too large, a symlink to a file, a FIFO).
				local okl = pcall(tern.fs.list, path)
				if not okl then
					return `{rel}:无法读取(超过 {M.MAX_FILE // 1024} KiB、符号链接或不是普通文件)`
				elseif depth >= MAX_DEPTH then
					return `{rel}:目录层级超过 {MAX_DEPTH}`
				end
				local err = walk(path, rel, depth + 1)
				if err then
					return err
				end
			end
		end
		return nil
	end
	local err = walk(root, "", 1)
	if err then
		return nil, err
	end
	table.sort(tree.paths)
	return tree, nil
end

-- Why `files` (path → text) can't be saved as a tree, or nil.
function M.check(files: { [string]: string }): string?
	local n, total = 0, 0
	for rel, text in files do
		if not model.valid_file_path(rel) then
			return `文件名 "{rel}" 无效:各段以字母、数字或 _ 开头,只含字母、数字、_ . -,最多 8 层`
		elseif #text > M.MAX_FILE then
			return `{rel} 超过 {M.MAX_FILE // 1024} KiB`
		end
		n += 1
		total += #text
	end
	if n > M.MAX_FILES then
		return `文件超过 {M.MAX_FILES} 个`
	elseif total > M.MAX_TOTAL then
		return `文件总大小超过 {M.MAX_TOTAL // (1024 * 1024)} MiB`
	end
	-- A file can't also be a directory (`a` and `a/b`), and the default macOS filesystem ignores
	-- case: `Run.py` and `run.py` would be one file.
	local lower: { [string]: string } = {}
	for rel in files do
		local key = string.lower(rel)
		if lower[key] then
			return `{lower[key]} 与 {rel} 只有大小写不同(文件系统不区分大小写)`
		end
		lower[key] = rel
	end
	for rel in files do
		local dir = string.match(string.lower(rel), "^(.*)/[^/]+$")
		while dir do
			if lower[dir] then
				return `{lower[dir]} 既是文件又是目录`
			end
			dir = string.match(dir, "^(.*)/[^/]+$")
		end
	end
	return nil
end

local function parent(path: string): string?
	return string.match(path, "^(.*)/[^/]+$")
end

-- Writes one file below `root`, creating its directories.
function M.write(root: string, rel: string, text: string): string?
	local bad = M.check({ [rel] = text })
	if bad then
		return bad
	end
	local path = `{root}/{rel}`
	local ok, err = pcall(function(): string?
		tern.fs.mkdir(parent(path) or root)
		tern.fs.write(path, text)
		return nil
	end)
	return if ok then nil else `写入 {rel} 失败:{err}`
end

-- Removes one file below `root`, then the directories it leaves empty (up to `root`).
function M.remove(root: string, rel: string): string?
	if not model.valid_file_path(rel) then
		return `文件名 "{rel}" 无效`
	end
	local ok, err = pcall(function(): string?
		tern.fs.remove(`{root}/{rel}`)
		return nil
	end)
	if not ok then
		return `删除 {rel} 失败:{err}`
	end
	local dir = parent(rel)
	while dir do
		local okl, names = pcall(tern.fs.list, `{root}/{dir}`)
		if not okl or type(names) ~= "table" or #(names :: { string }) > 0 then
			break
		end
		pcall(tern.fs.remove, `{root}/{dir}`)
		dir = parent(dir)
	end
	return nil
end

-- Makes the tree under `root` hold exactly `files`: writes them all first, then removes what is
-- left over, so a failure part way never loses a file that should stay.
--
-- `base` (path → text) is what the caller loaded before editing. With it, only files that were in
-- `base` and are gone from `files` are removed (a file that appeared meanwhile stays), and a file
-- that changed on disk since `base` is not overwritten or removed: the caller reloads first.
function M.replace(root: string, files: { [string]: string }, base: { [string]: string }?): string?
	local bad = M.check(files)
	if bad then
		return bad
	end
	local cur, err = M.load(root)
	if cur == nil then
		return err
	end
	if base then
		for rel, was in base do
			local now_ = cur.text[rel]
			if now_ ~= nil and now_ ~= was and files[rel] ~= was then
				return `{rel} 在打开编辑器之后被改动过,先重新打开再保存`
			end
		end
	end
	local ok, werr = pcall(function(): string?
		tern.fs.mkdir(root)
		return nil
	end)
	if not ok then
		return `无法创建目录:{werr}`
	end
	-- Files that are going away but sit where a wanted path needs a directory (or the reverse), or
	-- that differ from a wanted path only by case (one file on a case-insensitive disk, so writing
	-- the wanted name would overwrite it and the removal after would delete the result), must go
	-- first. Their content is in `files`: nothing is lost.
	local function leaving(rel: string): boolean
		return files[rel] == nil and (base == nil or base[rel] ~= nil)
	end
	local folded: { [string]: boolean } = {}
	for want in files do
		folded[string.lower(want)] = true
	end
	local removed: { [string]: boolean } = {}
	for _, rel in cur.paths do
		if leaving(rel) then
			local clash = folded[string.lower(rel)] == true
			if not clash then
				for want in files do
					if string.sub(want, 1, #rel + 1) == rel .. "/" or string.sub(rel, 1, #want + 1) == want .. "/" then
						clash = true
						break
					end
				end
			end
			if clash then
				local e = M.remove(root, rel)
				if e then
					return e
				end
				removed[rel] = true
			end
		end
	end
	for rel, text in files do
		-- A file the editor did not change stays as the disk has it (an edit made elsewhere is
		-- not reverted); one gone from the disk is put back, since the editor lists it.
		local untouched = base ~= nil and base[rel] == text and cur.text[rel] ~= nil
		if cur.text[rel] ~= text and not untouched then
			local e = M.write(root, rel, text)
			if e then
				return e
			end
		end
	end
	-- Not the ones already gone: that path may be a directory with new files in it by now.
	for _, rel in cur.paths do
		if leaving(rel) and not removed[rel] then
			local e = M.remove(root, rel)
			if e then
				return e
			end
		end
	end
	return nil
end

-- Copies the tree at `src` to `dst` (which should not exist yet); a missing `src` copies nothing.
function M.copy(src: string, dst: string): string?
	local tree, err = M.load(src)
	if tree == nil then
		return err
	end
	local ok, merr = pcall(function(): string?
		tern.fs.mkdir(dst)
		return nil
	end)
	if not ok then
		return `无法创建目录:{merr}`
	end
	for _, rel in tree.paths do
		local e = M.write(dst, rel, tree.text[rel])
		if e then
			return e
		end
	end
	return nil
end

-- Names under `dir` that could be Roost's (workflow ids, library and state names), sorted.
function M.names(dir: string): { string }
	local ok, names = pcall(tern.fs.list, dir)
	local out: { string } = {}
	if ok and type(names) == "table" then
		for _, n in names :: { string } do
			if model.valid_lib(n) then
				table.insert(out, n)
			end
		end
	end
	return out
end

-- The library names that exist.
function M.libs(data: string): { string }
	return M.names(`{data}/library`)
end

-- Gives run directory `run_dir` its copies of `wf`'s files and libraries, its scratch directory and
-- the workflow's state directory. Returns why it couldn't.
function M.stage(data: string, wf: model.Workflow, run_dir: string): string?
	local ok, err = pcall(function(): string?
		tern.fs.mkdir(`{run_dir}/tmp`)
		tern.fs.mkdir(M.state_dir(data, wf.state))
		return nil
	end)
	if not ok then
		return `无法创建目录:{err}`
	end
	local e = M.copy(M.workflow_root(data, wf.id), `{run_dir}/files`)
	if e then
		return `工作流文件:{e}`
	end
	for _, lib in wf.libs do
		local root = M.lib_root(data, lib)
		if not exists(root) then
			return `文件库 "{lib}" 不存在`
		end
		local le = M.copy(root, `{run_dir}/lib/{lib}`)
		if le then
			return `文件库 "{lib}":{le}`
		end
	end
	return nil
end

return M
