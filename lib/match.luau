--!strict
-- Whether a relayed GitHub event (the agent's normalized `info`) fires a GitHub trigger.

local model = require("./model")

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
	pull_request_review_thread = true,
	discussion = true,
	discussion_comment = true,
}

-- What a match needs besides the event: `me` is the user's GitHub login (`@me`, ignore_self).
export type Ctx = { me: string? }

local PR_OPEN = { opened = true, reopened = true, ready_for_review = true }

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

-- Whether `login` is in a people filter (case-insensitive; `@me` is the user).
local function person_in(list: { string }, login: string?, ctx: Ctx): boolean
	if login == nil then
		return false
	end
	local low = string.lower(login)
	for _, x in list do
		local who = if x == "@me" then ctx.me else x
		if who and string.lower(who) == low then
			return true
		end
	end
	return false
end

-- Why the kind's own condition (action, draft, merged, …) rejects `info`, or nil.
local function kind_mismatch(t: model.GithubTrigger, info: { [string]: any }): string?
	local a = info.action
	local on = t.on
	local function want(what: string): string
		return `action {a or "—"} 不是{what}`
	end
	if on == "pr_opened" then
		if not (a and PR_OPEN[a]) then
			return want("打开")
		elseif info.draft then
			return "草稿 PR"
		end
	elseif on == "pr_draft" then
		if not (((a == "opened" or a == "reopened") and info.draft) or a == "converted_to_draft") then
			return "不是草稿打开"
		end
	elseif on == "pr_pushed" then
		if a ~= "synchronize" then
			return want(" synchronize")
		elseif t.skip_drafts and info.draft then
			return "草稿 PR(跳过草稿)"
		end
	elseif on == "pr_merged" then
		if a ~= "closed" then
			return want("关闭")
		elseif not info.merged and not t.include_closed then
			return "关闭但未合并"
		end
	elseif on == "comment" or on == "review_comment" then
		if a ~= "created" then
			return want("新建")
		end
	elseif on == "issue_comment" then
		if a ~= "created" then
			return want("新建")
		elseif info.is_pr then
			return "评论在 PR 上"
		end
	elseif on == "push" then
		if type(info.branch) ~= "string" then
			return "不是分支推送"
		elseif info.deleted then
			return "分支被删除"
		end
	elseif on == "label" then
		if a ~= "labeled" and a ~= "unlabeled" then
			return want("标签变更")
		end
		local op = if a == "labeled" then "added" else "removed"
		if #t.label_actions > 0 and not has(t.label_actions, op) then
			return `标签操作 {op} 不在 {table.concat(t.label_actions, ",")}`
		end
	elseif on == "check_completed" or on == "workflow_run" then
		if a ~= "completed" then
			return want("完成")
		end
	elseif on == "review" then
		if a ~= "submitted" then
			return want("提交")
		elseif #t.review_states > 0 and not has(t.review_states, info.review_state) then
			return `审阅状态 {info.review_state or "—"} 不匹配`
		end
	elseif on == "review_thread" then
		if a ~= "resolved" and a ~= "unresolved" then
			return want("解决/未解决")
		elseif #t.thread_actions > 0 and not has(t.thread_actions, a) then
			return `线程操作 {a} 不匹配`
		end
	elseif on == "issue_opened" then
		if a ~= "opened" then
			return want("打开")
		end
	elseif on == "event" then
		if #t.actions > 0 and not has(t.actions, a) then
			return `action {a or "—"} 不在 {table.concat(t.actions, ",")}`
		end
	end
	return nil
end

-- Why `t` doesn't fire for `info`, or nil when it does.
function M.mismatch(t: model.GithubTrigger, info: { [string]: any }, ctx: Ctx): string?
	if not has(t.events, info.event) then
		return "事件不同"
	end
	local why = kind_mismatch(t, info)
	if why then
		return why
	end
	if #t.repos > 0 then
		local r = string.lower(info.repo or "")
		local ok = false
		for _, p in t.repos do
			ok = ok or M.glob(string.lower(p), r)
		end
		if not ok then
			return `仓库 {info.repo or "—"} 不匹配`
		end
	end
	if #t.authors > 0 and not person_in(t.authors, info.author, ctx) then
		return `作者 {info.author or "—"} 不在名单`
	end
	if #t.assignees > 0 then
		local ok = false
		for _, a in info.assignees or {} do
			ok = ok or person_in(t.assignees, a, ctx)
		end
		if not ok then
			return "负责人不匹配"
		end
	end
	if #t.labels > 0 then
		local hit = false
		if info.label and (info.action == "labeled" or info.action == "unlabeled") then
			-- A labeled/unlabeled action is about the one label that changed.
			hit = has(t.labels, info.label)
		else
			for _, l in info.labels or {} do
				hit = hit or has(t.labels, l)
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
				ok = ok or M.glob(p, b)
			end
		end
		if not ok then
			return `分支 {b or "—"} 不匹配`
		end
	end
	if #t.workflows > 0 and not has(t.workflows, info.workflow_name) then
		return "工作流名称不匹配"
	end
	if #t.conclusions > 0 and not has(t.conclusions, info.conclusion) then
		return `结论 {info.conclusion or "—"} 不匹配`
	end
	if t.comment then
		local body = string.match(info.comment or "", "^%s*(.*)$") or ""
		if string.sub(body, 1, #t.comment) ~= t.comment then
			return `评论不以 {t.comment} 开头`
		end
	end
	-- Naming someone as an author lets their activity through the bot/self filters.
	if t.ignore_bots and info.sender_is_bot and not person_in(t.authors, info.sender, ctx) then
		return `机器人 {info.sender or "?"} 的活动`
	end
	if t.ignore_self and ctx.me and info.sender and string.lower(info.sender) == string.lower(ctx.me) and not person_in(t.authors, info.sender, ctx) then
		return "你自己的活动"
	end
	local allowed = t.associations
	if allowed == nil and M.USER_CONTENT[info.event] then
		allowed = M.DEFAULT_ASSOCIATIONS
	end
	if allowed and not has(allowed, "*") and not has(allowed, info.association) then
		return `作者关系 {info.association or "未知"} 不在 {table.concat(allowed, ",")}(高级设置可允许外部贡献者)`
	end
	if M.CODE_EVENTS[info.event] and not t.forks then
		-- CI events carry no author association; the code they point at may come from a fork.
		if info.from_fork then
			return `代码来自 fork {info.head_repo or "?"}(高级设置可接受 fork 代码)`
		elseif info.head_repo == nil then
			return "无法确认代码来源仓库(高级设置可接受 fork 代码)"
		end
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
