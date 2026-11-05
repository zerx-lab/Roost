--!strict
-- Whether a relayed GitHub event (the agent's normalized `info`) fires a github trigger.

local M = {}

-- Who may write the content of user-content events by default.
M.DEFAULT_ASSOCIATIONS = { "OWNER", "MEMBER", "COLLABORATOR" }

-- Events about CI on some commit: gated on the code's origin (forks) instead of an author.
M.CODE_EVENTS = { workflow_run = true, check_suite = true, check_run = true }

-- Events whose payload carries content written by the sender (issue text, comments, PR code).
M.USER_CONTENT = {
	issues = true,
	issue_comment = true,
	pull_request = true,
	pull_request_review = true,
	pull_request_review_comment = true,
	discussion = true,
	discussion_comment = true,
}

export type GithubTrigger = {
	event: string,
	actions: { string },
	labels: { string },
	branches: { string },
	comment: string?,
	senders: { string },
	associations: { string }?,
	workflows: { string },
	conclusions: { string },
	forks: boolean?,
}

-- `*` matches any run of characters; everything else is literal.
function M.glob(pattern: string, s: string): boolean
	if not string.find(pattern, "*", 1, true) then
		return pattern == s
	end
	local parts = string.split(pattern, "*")
	local pos = 1
	for i, part in parts do
		if i == 1 then
			if string.sub(s, 1, #part) ~= part then
				return false
			end
			pos = #part + 1
		elseif i == #parts then
			return part == "" or (#s - #part + 1 >= pos and string.sub(s, -#part) == part)
		else
			local a, b = string.find(s, part, pos, true)
			if not a then
				return false
			end
			pos = (b :: number) + 1
		end
	end
	return true
end

local function has(list: { string }, v: string?): boolean
	if v == nil then
		return false
	end
	for _, x in list do
		if x == v then
			return true
		end
	end
	return false
end

-- Why `t` doesn't fire for `info`, or nil when it does.
function M.mismatch(t: GithubTrigger, info: { [string]: any }): string?
	if t.event ~= info.event then
		return "事件不同"
	end
	if #t.actions > 0 and not has(t.actions, info.action) then
		return `action {info.action or "—"} 不在 {table.concat(t.actions, ",")}`
	end
	if #t.labels > 0 then
		local hit = false
		if info.label and (info.action == "labeled" or info.action == "unlabeled") then
			-- A labeled/unlabeled action is about the one label that changed.
			hit = has(t.labels, info.label)
		else
			for _, l in info.labels or {} do
				if has(t.labels, l) then
					hit = true
					break
				end
			end
		end
		if not hit then
			return "标签不匹配"
		end
	end
	if #t.branches > 0 then
		local b = info.branch
		local ok = false
		if type(b) == "string" then
			for _, p in t.branches do
				if M.glob(p, b) then
					ok = true
					break
				end
			end
		end
		if not ok then
			return `分支 {b or "—"} 不匹配`
		end
	end
	if t.comment then
		local body = string.match(info.comment or "", "^%s*(.*)$") or ""
		if string.sub(body, 1, #t.comment) ~= t.comment then
			return `评论不以 {t.comment} 开头`
		end
	end
	if #t.senders > 0 then
		local s = string.lower(info.sender or "")
		local ok = false
		for _, x in t.senders do
			if string.lower(x) == s then
				ok = true
				break
			end
		end
		if not ok then
			return `发送者 {info.sender or "—"} 不在名单`
		end
	end
	local allowed = t.associations
	if allowed == nil and M.USER_CONTENT[t.event] then
		allowed = M.DEFAULT_ASSOCIATIONS
	end
	if allowed and not has(allowed, "*") and not has(allowed, info.association) then
		return `作者关系 {info.association or "未知"} 不在 {table.concat(allowed, ",")}`
	end
	if M.CODE_EVENTS[t.event] and not t.forks then
		-- CI events carry no author association; the code they point at may come from a fork.
		if info.from_fork then
			return `代码来自 fork {info.head_repo or "?"}(设置 forks = true 才接受)`
		elseif info.head_repo == nil then
			return "无法确认代码来源仓库(设置 forks = true 才接受)"
		end
	end
	if #t.workflows > 0 and not has(t.workflows, info.workflow_name) then
		return "workflow 名称不匹配"
	end
	if #t.conclusions > 0 and not has(t.conclusions, info.conclusion) then
		return "conclusion 不匹配"
	end
	return nil
end

-- `issues.opened #12 Title`.
function M.summary(info: { [string]: any }): string
	local out = info.event or "?"
	if info.action then
		out ..= "." .. info.action
	end
	if info.number then
		out ..= ` #{info.number}`
	elseif info.branch then
		out ..= " " .. info.branch
	end
	if type(info.title) == "string" then
		local t = string.match(info.title, "^[^\r\n]*") or ""
		if utf8.len(t) and (utf8.len(t) :: number) > 80 then
			t = string.sub(t, 1, (utf8.offset(t, 81) or (#t + 1)) - 1) .. "…"
		end
		out ..= " " .. t
	end
	return out
end

return M
