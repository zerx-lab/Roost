--!strict
-- Pure modules: trigger matching, prompt templates, config validation and subscriptions.

local F = require("./fake_tern")
local harness = require("./harness")
harness.fresh(F.new())

local match = require("../lib/match")
local template = require("../lib/template")
local model = require("../lib/model")
local util = require("../lib/util")

local function eq(a: any, b: any, msg: string?)
	if a ~= b then
		error(`{msg or "eq"}: expected {tostring(b)}, got {tostring(a)}`, 2)
	end
end

-- The first trigger of a one-workflow file whose trigger table is `body`.
local function trigger(body: string): model.Trigger
	local w, issues = model.parse_workflows(`[[workflow]]\nid = "w"\n[[workflow.trigger]]\n{body}\n[[workflow.step]]\nrun = "true"\n`)
	if w == nil then
		error(`trigger rejected: {issues[1].path}: {issues[1].message}`, 2)
	end
	return w.list[1].triggers[1]
end

local function gh(body: string): model.GithubTrigger
	return trigger(body) :: model.GithubTrigger
end

local ME: match.Ctx = { me = "zero" }

do -- each GitHub kind adds its own condition on the action and the PR state
	local opened = gh('github = "pr_opened"\nrepos = ["acme/web"]')
	local pr = { event = "pull_request", action = "opened", repo = "acme/web", association = "MEMBER" }
	eq(match.mismatch(opened, pr, ME), nil, "PR opened")
	assert(match.mismatch(opened, { event = "pull_request", action = "opened", repo = "acme/web", association = "MEMBER", draft = true }, ME), "draft is not pr_opened")
	local draft = gh('github = "pr_draft"\nrepos = ["acme/web"]')
	eq(match.mismatch(draft, { event = "pull_request", action = "converted_to_draft", repo = "acme/web", association = "MEMBER" }, ME), nil)

	local merged = gh('github = "pr_merged"\nrepos = ["acme/web"]')
	local closed = { event = "pull_request", action = "closed", repo = "acme/web", association = "MEMBER", merged = false }
	assert(match.mismatch(merged, closed, ME), "closed without merge")
	eq(match.mismatch(gh('github = "pr_merged"\nrepos = ["acme/web"]\ninclude_closed = true'), closed, ME), nil, "include_closed")

	local pushed = gh('github = "pr_pushed"\nrepos = ["acme/web"]')
	local sync = { event = "pull_request", action = "synchronize", repo = "acme/web", association = "MEMBER", draft = true }
	assert(match.mismatch(pushed, sync, ME), "drafts skipped by default")
	eq(match.mismatch(gh('github = "pr_pushed"\nrepos = ["acme/web"]\nskip_drafts = false'), sync, ME), nil)

	local issue_comment = gh('github = "issue_comment"\nrepos = ["acme/web"]')
	local on_pr = { event = "issue_comment", action = "created", repo = "acme/web", association = "MEMBER", is_pr = true }
	assert(match.mismatch(issue_comment, on_pr, ME), "issue_comment skips PR comments")
	eq(match.mismatch(gh('github = "comment"\nrepos = ["acme/web"]'), on_pr, ME), nil, "comment takes both")

	local label = gh('github = "label"\nlabel_actions = ["removed"]\nlabels = ["bug"]')
	local labeled = { event = "issues", action = "labeled", label = "bug", labels = { "bug" }, association = "OWNER" }
	assert(match.mismatch(label, labeled, ME), "added is not removed")
	eq(match.mismatch(label, { event = "pull_request", action = "unlabeled", label = "bug", association = "OWNER" }, ME), nil, "label kind listens to PRs too")

	local review = gh('github = "review"\nreview_states = ["approved"]')
	eq(match.mismatch(review, { event = "pull_request_review", action = "submitted", review_state = "approved", association = "MEMBER" }, ME), nil)
	assert(match.mismatch(review, { event = "pull_request_review", action = "submitted", review_state = "commented", association = "MEMBER" }, ME), "review state filtered")

	local push = gh('github = "push"\nbranches = ["release/*"]')
	eq(match.mismatch(push, { event = "push", branch = "release/1.2" }, ME), nil, "push not gated by association")
	assert(match.mismatch(push, { event = "push", branch = "release/1.2", deleted = true }, ME), "deleted branch")
	assert(match.mismatch(push, { event = "push", branch = "main" }, ME), "branch filtered")
	assert(match.glob("a*b*c", "a-b-c") and not match.glob("a*c", "ab") and match.glob("*", ""), "glob")
end

do -- people filters: case-insensitive, @me, and naming yourself lets your own activity through
	local t = gh('github = "comment"\nrepos = ["acme/*"]')
	local mine = { event = "issue_comment", action = "created", repo = "Acme/Web", sender = "Zero", author = "Zero", association = "OWNER" }
	assert(string.find(match.mismatch(t, mine, ME) or "", "自己", 1, true), "own comment ignored by default")
	eq(match.mismatch(t, mine, {}), nil, "unknown login: nothing to ignore")
	eq(match.mismatch(gh('github = "comment"\nauthors = ["@me"]'), mine, ME), nil, "@me as author opts in")
	local bot = { event = "issue_comment", action = "created", repo = "acme/web", sender = "ci[bot]", author = "ci[bot]", sender_is_bot = true, association = "MEMBER" }
	assert(match.mismatch(t, bot, ME), "bots ignored")
	eq(match.mismatch(gh('github = "comment"\nrepos = ["acme/web"]\nignore_bots = false'), bot, ME), nil)
	assert(match.mismatch(t, { event = "issue_comment", action = "created", repo = "other/web", association = "MEMBER" }, ME), "owner/* pattern")
	local assigned = gh('github = "comment"\nassignees = ["@me"]')
	eq(match.mismatch(assigned, { event = "issue_comment", action = "created", assignees = { "ZERO" }, association = "MEMBER" }, ME), nil)
end

do -- user-content events default to trusted authors; "*" opens them up; CI refuses fork code
	local t = gh('github = "comment"\ncomment = "/roost"')
	local outsider = { event = "issue_comment", action = "created", comment = "/roost go", association = "NONE" }
	assert(string.find(match.mismatch(t, outsider, ME) or "", "NONE", 1, true), "outsider blocked")
	eq(match.mismatch(gh('github = "comment"\ncomment = "/roost"\nassociations = ["*"]'), outsider, ME), nil, "* allows anyone")
	assert(match.mismatch(t, { event = "issue_comment", action = "created", comment = "hi", association = "OWNER" }, ME), "prefix required")

	local ci = gh('github = "workflow_run"\nconclusions = ["failure"]')
	local run = { event = "workflow_run", action = "completed", conclusion = "failure" }
	local own = table.clone(run)
	own.head_repo, own.from_fork = "acme/web", false
	local fork = table.clone(run)
	fork.head_repo, fork.from_fork = "evil/web", true
	eq(match.mismatch(ci, own, ME), nil, "same-repo CI passes")
	assert(string.find(match.mismatch(ci, fork, ME) or "", "fork", 1, true), "fork refused")
	assert(match.mismatch(ci, run, ME), "unknown origin refused")
	eq(match.mismatch(gh('github = "workflow_run"\nconclusions = ["failure"]\nforks = true'), fork, ME), nil)
end

do -- schedules compile to cron; once fires at its minute
	local function expr(body: string): string
		return (trigger(body) :: model.CronTrigger).expr
	end
	eq(expr('schedule = "weekly"\ndays = ["fri", "mon"]\ntime = "08:30"'), "30 8 * * 1,5")
	eq(expr('schedule = "hourly"\nbetween = ["09:00", "18:00"]'), "0 9-18 * * *")
	eq(expr('schedule = "hourly"\ndays = ["sun","mon","tue","wed","thu","fri","sat"]'), "0 * * * *", "all days is every day")
	eq(expr('schedule = "monthly"\nday = 31\ntime = "23:59"'), "59 23 31 * *")
	eq(expr('schedule = "yearly"\ndate = "02-29"\ntime = "07:00"'), "0 7 29 2 *")
	local once = trigger('schedule = "once"\nat = "2026-11-06 08:30"\ntz = "UTC"') :: model.CronTrigger
	eq(once.at, 1793953800)
	eq(model.describe_trigger(trigger('schedule = "weekly"\ndays = ["mon","tue","wed","thu","fri"]\ntime = "09:00"')), "每周 工作日 09:00")
end

do -- workflows validation reports every problem with its line
	local text = table.concat({
		'[repos."acme/web"]',
		'path = "~/w"',
		"",
		"[[workflow]]",
		'id = "Bad Id"',
		"",
		"[[workflow.trigger]]",
		'schedule = "weekly"',
		'time = "25:00"',
		"",
		"[[workflow.trigger]]",
		'github = "pr_opened"',
		'labels = ["x"]',
		"",
		"[[workflow.trigger]]",
		'github = "push"',
		"",
		"[[workflow.trigger]]",
		'cron = "0 9 * * *"',
		"",
		"[[workflow.step]]",
		'omp = "{{nosuch}}"',
		'bogus = 1',
	}, "\n")
	local w, issues = model.parse_workflows(text)
	eq(w, nil, "invalid file rejected")
	local function at(pat: string, line: number): boolean
		for _, i in issues do
			if i.line == line and string.find(i.message, pat, 1, true) then
				return true
			end
		end
		return false
	end
	assert(at("无效:1-64", 5), "bad id line")
	assert(at("25:00", 9), "bad time")
	assert(at("至少选择一天", 7), "weekly needs days")
	assert(at("未知字段 labels", 13), "filter not offered by the kind")
	assert(at("至少添加一个筛选器", 11) and at("至少添加一个筛选器", 15), "GitHub triggers need a filter")
	assert(at("schedule = \"cron\"", 18), "old cron key explained")
	assert(at("未知变量", 22), "template variable")
	assert(at("未知字段 bogus", 23), "unknown key")
end

do -- subscriptions: named repos lower-cased, "*" for any repo, enabled workflows only
	local w = model.parse_workflows(table.concat({
		"[[workflow]]",
		'id = "x"',
		"[[workflow.trigger]]",
		'github = "push"',
		'repos = ["A/One"]',
		"[[workflow.trigger]]",
		'github = "label"',
		'labels = ["bug"]',
		"[[workflow.step]]",
		'run = "true"',
		"[[workflow]]",
		'id = "y"',
		"enabled = false",
		"[[workflow.trigger]]",
		'github = "event"',
		'event = "release"',
		'repos = ["a/two"]',
		"[[workflow.step]]",
		'run = "true"',
	}, "\n")) :: model.Workflows
	local subs = model.subscriptions(w)
	eq(table.concat(subs["a/one"].events, ","), "push")
	eq(table.concat(subs["*"].events, ","), "issues,pull_request", "label listens to issues and PRs anywhere")
	eq(subs["a/two"], nil, "disabled workflow contributes nothing")
	local text = model.subscriptions_toml(subs)
	assert(string.find(text, '[repos."a/one"]\nevents = ["push"]', 1, true), text)
end

do -- templates: variables, inputs, payload paths with 0-based indexes, bounded output
	local t = template.parse("#{{ number }} {{title}} {{payload.issue.labels.0.name}}/{{input.x}}{{missing}}") :: template.Template
	eq(
		template.render(t, { number = 7, title = "Bug", input = { x = "X" }, payload = { issue = { labels = { { name = "roost" } } } } }),
		"#7 Bug roost/X"
	)
	assert(template.check(t, { x = true }), "unknown variable rejected")
	eq(template.check(template.parse("{{repo}} {{input.x}}") :: template.Template, { x = true }), nil)
	assert(template.check(template.parse("{{input.y}}") :: template.Template, { x = true }), "undeclared input rejected")
	assert(select(2, template.parse("{{open")), "unclosed rejected")
	local big = template.render(template.parse("{{body}}") :: template.Template, { body = string.rep("x", template.MAX_RENDERED + 10) })
	assert(#big <= template.MAX_RENDERED + 20, "rendered output bounded")
end

do -- the editor's write-back: encode a raw workflow, splice it in, keep everything else
	local text = table.concat({
		"# header comment",
		"",
		"[[workflow]]",
		'id = "a"',
		'env = { K = "v" }',
		"",
		"[[workflow.step]]",
		'run = "echo a"',
		"",
		"# about b",
		"[[workflow]]",
		'id = "b"',
		"[[workflow.step]]",
		'run = "echo b"',
		"",
		'[repos."acme/web"]',
		'path = "~/w"',
		"",
	}, "\n")
	local raw = model.raw_workflow(text, "a") :: { [string]: any }
	eq(raw.env.K, "v", "raw keeps keys the editor doesn't show")
	raw.name = "第一行\n第二行 \"引号\""
	raw.trigger = { model.trigger_defaults("weekly", 1793880000) }
	local out = model.splice_workflow(text, "a", model.encode_workflow(raw)) :: string
	local w = model.parse_workflows(out) :: model.Workflows
	eq(#w.list, 2)
	eq(w.by_id.a.name, "第一行\n第二行 \"引号\"", "strings round-trip through quoting")
	eq((w.by_id.a.triggers[1] :: model.CronTrigger).expr, "0 9 * * 1")
	eq(w.by_id.a.env.K, "v")
	eq(w.repos["acme/web"].path, "~/w", "tables after the workflows survive")
	assert(string.find(out, "# header comment", 1, true) and string.find(out, "# about b\n[[workflow]]\nid = \"b\"", 1, true), out)

	local gone = model.splice_workflow(out, "a", nil) :: string
	local w2 = model.parse_workflows(gone) :: model.Workflows
	eq(#w2.list, 1)
	eq(w2.list[1].id, "b")
	assert(string.find(gone, "# about b", 1, true), "the next block's comment stays")

	local added = model.splice_workflow(gone, nil, model.encode_workflow({ id = "c", step = { { run = "true" } } })) :: string
	eq(#(model.parse_workflows(added) :: model.Workflows).list, 2)
	eq(select(2, model.splice_workflow(gone, "nope", "")), "workflows.toml 中找不到工作流 nope")
	eq(model.slug("PR Review!", { ["pr-review"] = true }), "pr-review-2")
	eq(model.slug("每日摘要", {}), "automation")
	local _, ev_issues = model.parse_workflows('[[workflow]]\nid = "e"\n[[workflow.trigger]]\ngithub = "event"\nevent = "discussion"\nrepos = ["a/b"]\n[[workflow.step]]\nrun = "true"\n')
	assert(string.find(ev_issues[1].message, "GitHub App 订阅的事件只有", 1, true), "events the App never receives are refused")

	-- Prompts are written as multi-line strings; lines in them that look like headers, comments
	-- or blank runs are content, not structure.
	local prompt = "第一段\n\n\n[注意]\n# 不是注释\n结尾 \"\"\" 引号 \\ 反斜杠\n"
	local two = model.splice_workflow(added, "c", model.encode_workflow({ id = "c", step = { { omp = prompt } } })) :: string
	assert(string.find(two, 'omp = """\n第一段', 1, true), two)
	local w3 = model.parse_workflows(two) :: model.Workflows
	eq(require("../lib/template").render(w3.by_id.c.steps[1].prompt :: any, {}), prompt, "prompt round-trips")
	local again = model.splice_workflow(two, "c", model.encode_workflow({ id = "c", step = { { omp = "短" } } })) :: string
	eq(#(model.parse_workflows(again) :: model.Workflows).list, 2, "a quoted [注意] line didn't end the block early")
	assert(not string.find(again, "注意", 1, true), "the whole old prompt was replaced")
end

do -- roost.toml: relay URL trimmed and checked, runner bounds enforced, Roost-managed omp flags refused
	local cfg = model.parse_config('[relay]\nurl = "https://r.dev/"\ntoken = "t"\n[runner]\nmax_concurrent = 3\n') :: model.Config
	eq(cfg.relay.url, "https://r.dev")
	eq(cfg.runner.max_concurrent, 3)
	local bad, issues = model.parse_config('[relay]\nurl = "ftp://x"\n[runner]\nmax_concurrent = 0\n')
	eq(bad, nil)
	eq(#issues, 2)
	local managed, why = model.parse_config('[runner]\nomp_args = ["-p", "--session-dir=/tmp/x", "--thinking", "high"]\nsession = ""\n')
	eq(managed, nil)
	eq(#why, 3, "-p, --session-dir=… and the empty session name")
	local _, step_issues = model.parse_workflows('[[workflow]]\nid = "w"\n[[workflow.step]]\nomp = "hi"\nargs = ["--resume", "abc"]\n')
	eq(#step_issues, 1, "step args can't resume a session either")
	eq(step_issues[1].path, "workflow.w.step[1].args")
end

do -- agent command lines survive spaces and quotes; roost:// links round-trip
	local agent = require("../lib/agent")
	local dir = "/Users/me/Library/Application Support/Tern/plugin-data/roost/runs/ab12/s1.session"
	eq(agent.command("omp", dir, { "--model", "it's" }), `omp --session-dir '{dir}' --model 'it'\\''s'`)
	eq(agent.quote(""), "''", "an empty argument stays an argument")
	local r = agent.parse_url(agent.session_url("ab12", 3)) :: any
	eq(r.kind, "session")
	eq(r.run, "ab12")
	eq(r.step, 3)
	eq(agent.parse_url("roost://session/../../x/1"), nil, "only hex run ids")
	eq((agent.parse_url(agent.SIDEBAR_URL) :: any).kind, "sidebar")
end

do -- util
	eq(util.duration("1h30m"), 5400)
	eq(util.duration("90"), 90)
	eq((util.duration("5x")), nil)
	eq(util.fmt_duration(5400), "1h30m")
	eq(util.clip("你好世界", 2), "你好…")
	eq(util.shq("it's"), "'it'\\''s'")
end

print("ok")
