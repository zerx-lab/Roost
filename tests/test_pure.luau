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
	-- What Roost did as the App is your own activity too, even with bots let through.
	local as_app = { event = "issue_comment", action = "created", repo = "acme/web", sender = "Roost-X[bot]", author = "Roost-X[bot]", sender_is_bot = true, association = "NONE" }
	local open = gh('github = "comment"\nrepos = ["acme/web"]\nignore_bots = false\nassociations = ["*"]')
	assert(string.find(match.mismatch(open, as_app, { me = "zero", bot = "roost-x[bot]" }) or "", "App 身份", 1, true), "the App's own comment ignored")
	eq(match.mismatch(open, as_app, ME), nil, "another bot passes when bots are let through")
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
	eq(cfg.github.identity, "app", "runs act as the GitHub App unless told otherwise")
	local _, who = model.parse_config('[github]\nidentity = "me"\n')
	eq(who[1].path, "github.identity")
	local w = model.parse_workflows('[[workflow]]\nid = "w"\nidentity = "local"\n[[workflow.step]]\nrun = "true"\n') :: model.Workflows
	eq(w.list[1].identity, "local", "a workflow can override it")
	local _, wbad = model.parse_workflows('[[workflow]]\nid = "w"\nidentity = "bot"\n[[workflow.step]]\nrun = "true"\n')
	eq(wbad[1].path, "workflow.w.identity")
end

do -- `when`, `daily_budget` and `{{out.x}}`: parsed, validated, round-tripped by the encoder
	local text = table.concat({
		"[[workflow]]",
		'id = "w"',
		"daily_budget = 2.5",
		"[[workflow.input]]",
		'name = "dry"',
		"[[workflow.step]]",
		'run = "true"',
		"[[workflow.step]]",
		'when = "!input.dry"',
		'omp = "处理 {{out.count}} 条"',
		"[[workflow.step]]",
		'when = "out.go"',
		'run = "true"',
	}, "\n")
	local w = model.parse_workflows(text) :: model.Workflows
	local wf = w.by_id.w
	eq(wf.daily_budget, 2.5)
	eq(wf.steps[1].when, nil)
	local w2 = wf.steps[2].when :: model.When
	eq(w2.source, "input")
	eq(w2.key, "dry")
	eq(w2.negate, true)
	eq((wf.steps[3].when :: model.When).source, "out")
	local raw = assert(model.raw_workflow(text, "w"))
	local again = model.parse_workflows(model.encode_workflow(raw)) :: model.Workflows
	eq(again.by_id.w.daily_budget, 2.5, "budget survives the editor's encoder")
	eq((again.by_id.w.steps[2].when :: model.When).key, "dry", "when survives too")

	local function bad(body: string): { model.Issue }
		local _, issues = model.parse_workflows(`[[workflow]]\nid = "b"\n{body}`)
		return issues
	end
	local i1 = bad('daily_budget = 0\n[[workflow.step]]\nrun = "true"\n')
	eq(i1[1].path, "workflow.b.daily_budget", "a zero budget is refused")
	local i2 = bad('[[workflow.step]]\nwhen = "input.nope"\nrun = "true"\n')
	eq(i2[1].path, "workflow.b.step[1].when", "undeclared input")
	local i3 = bad('[[workflow.step]]\nwhen = "out.a-b"\nrun = "true"\n')
	eq(i3[1].path, "workflow.b.step[1].when", "malformed output name")
	local i4 = bad('[[workflow.step]]\nomp = "{{out.x.y}}"\n')
	eq(i4[1].path, "workflow.b.step[1].omp", "out takes exactly one name")
	eq(model.truthy(" 0 "), false)
	eq(model.truthy("no"), false)
	eq(model.truthy("2"), true)
end

do -- agent command lines survive spaces and quotes; roost:// links round-trip
	local agent = require("../lib/agent")
	local dir = "/Users/me/Library/Application Support/Tern/plugin-data/roost/runs/ab12/s1.session"
	eq(agent.command("omp", dir, { "--model", "it's" }), `omp --session-dir '{dir}' --model 'it'\\''s'`)
	eq(agent.quote(""), "''", "an empty argument stays an argument")
	local r = agent.parse_url(agent.session_url("ab12", 3, "tab")) :: any
	eq(r.run, "ab12")
	eq(r.step, 3)
	eq(r.how, "tab", "the way to open it travels with the link")
	eq(agent.parse_url("roost://session/ab12/3/float"), nil, "only known ways")
	eq(agent.parse_url("roost://session/../../x/1/split"), nil, "only hex run ids")
	local lr = agent.parse_url(agent.log_url("ab12")) :: any
	eq(lr.run, "ab12")
	eq(lr.step, nil, "a log link names no step")
	eq(agent.parse_url("roost://log/../x"), nil, "only hex run ids")
end

do -- session progress: whole lines only; a line longer than a read is dropped, its rest skipped
	local agent = require("../lib/agent")
	local line = '{"type":"message","message":{"role":"assistant","stopReason":"aborted","errorMessage":"503\\nbusy","content":[]}}\n'
	local p = agent.progress(line .. '{"type":"mess', false)
	eq(p.used, #line, "the partial second line is left for the next read")
	eq(p.final, nil, "no text means no final answer")
	assert(string.find(p.lines[1], "本轮中止:503 ⏎ busy", 1, true), "an aborted turn says why, on one line")
	local big = agent.progress(string.rep("x", 64), true)
	eq(big.used, 64, "a full chunk without a newline is dropped")
	eq(#big.lines, 0)
	local rest = agent.progress('xx","role":"assistant"}\n' .. line, false)
	eq(#rest.lines, 1, "the cut line's rest fails to decode and is skipped")
end

do -- stats: runs land on their local day; rates skip cancelled runs; percentiles by nearest rank
	local stats = require("../lib/stats")
	local now = os.time({ year = 2026, month = 11, day = 6, hour = 9, min = 0, sec = 0 })
	local yesterday_late = os.time({ year = 2026, month = 11, day = 5, hour = 23, min = 59, sec = 0 })
	local function run(wf: string, state: string, at: number, took: number?): any
		return { workflow = wf, state = state, created_at = at, started_at = at, finished_at = if took then at + took else nil }
	end
	local runs = {
		run("a", "success", now - 60, 10),
		run("a", "failed", now - 120, 30),
		run("a", "cancelled", now - 180, 5),
		run("a", "success", yesterday_late, 20),
		run("b", "running", now - 10, nil),
		run("a", "success", now - 30 * 86400, 1), -- outside the window
	}
	local days = stats.days(runs, now, 3)
	eq(#days, 3)
	eq(days[3].label, "11-06", "today is last")
	eq(days[3].ok, 1)
	eq(days[3].bad, 1)
	eq(days[3].other, 2, "cancelled and running count as other")
	eq(days[2].ok, 1, "23:59 local is still yesterday")
	eq(days[3].p50, 10, "nearest-rank median of 5, 10, 30")
	eq(days[3].p95, 30)
	local h = stats.health(runs, now, 3)
	eq(h.a.runs, 4)
	eq(h.a.rate, 2 / 3, "cancelled runs don't count against the rate")
	eq(h.a.daily[2], 1)
	eq(h.a.daily[3], 3)
	eq(h.b.rate, nil, "no finished runs: no rate")
	eq(stats.percent(h.b.rate), "—")
	eq(stats.percent(2 / 3), "67%")
end

do -- util
	eq(util.duration("1h30m"), 5400)
	eq(util.duration("90"), 90)
	eq((util.duration("5x")), nil)
	eq(util.fmt_duration(5400), "1h30m")
	eq(util.clip("你好世界", 2), "你好…")
	eq(util.shq("it's"), "'it'\\''s'")
	-- Terminal cells of a log line: escapes take none, CJK two, \r restarts (widest pass), tabs align.
	eq(util.cells("\27[1;36m▶ build\27[0m"), 7, "SGR codes take no cells")
	eq(util.cells("\27]8;;https://x.dev\7link\27]8;;\27\\"), 4, "OSC 8 links count their text")
	eq(util.cells("先读 tr"), 7, "wide characters take two cells")
	eq(util.cells("progress 100%\rdone"), 13, "a carriage return keeps the widest pass")
	eq(util.cells("a\tb"), 9, "a tab moves to the next multiple of 8")
	eq(util.cells("ok\255\128"), 2, "bytes that aren't UTF-8 take none")
end

do -- PR references for a manual PR run; which workflows can take one
	local function ref(s: string): string
		local repo, n = match.pr_ref(s)
		return `{repo or "-"} {n or "-"}`
	end
	eq(ref("https://github.com/acme/web/pull/12"), "acme/web 12")
	eq(ref(" github.com/acme/web.js/pull/12/files#diff "), "acme/web.js 12", "no scheme, trailing path")
	eq(ref("acme/web#12"), "acme/web 12")
	eq(ref("#12"), "- 12", "a bare number leaves the repo to the caller")
	eq(ref("12"), "- 12")
	eq(ref("0"), "- -", "PR numbers start at 1")
	eq(ref("acme/web#12x"), "- -")
	eq(ref("https://github.com/acme/web/issues/12"), "- -", "an issue is not a PR")
	eq(ref(""), "- -")
	local long = string.rep("a", 16 * 1024 - 1) .. "é" .. "tail"
	local info = match.pr_info("acme/web", { number = 3, body = long, base = {}, head = {} }, "manual")
	eq(info.repo, "acme/web", "the asked repo when the PR lacks base.repo")
	eq(info.from_fork, false, "unknown head repo is not a fork")
	eq(string.sub(info.body, -3), "…", "long body clipped")
	assert(utf8.len(info.body), "clipped on a character boundary")
	local function kinds(src: string): string?
		local w = model.parse_workflows(`[[workflow]]\nid = "x"\n{src}[[workflow.step]]\nrun = "true"\n`) :: model.Workflows
		return model.pr_target(w.by_id.x)
	end
	eq(kinds('[[workflow.trigger]]\ngithub = "pr_pushed"\nrepos = ["a/b"]\n'), "only")
	eq(kinds('[[workflow.trigger]]\ngithub = "review"\nrepos = ["a/b"]\n[[workflow.trigger]]\nschedule = "daily"\ntime = "06:00"\n'), "some")
	eq(kinds('[[workflow.trigger]]\ngithub = "comment"\nrepos = ["a/b"]\n'), nil, "comments may be on issues")
	eq(kinds(""), nil)
end

do -- file steps: own files or @library/path, run by extension; libraries they name join `libs`
	local function parse(steps: string, extra: string?): (model.Workflow?, string?)
		local w, issues = model.parse_workflows(`[[workflow]]\nid = "w"\n{extra or ""}\n{steps}`)
		if w == nil then
			return nil, `{issues[1].path}: {issues[1].message}`
		end
		return w.list[1], nil
	end
	local wf = parse(
		'[[workflow.step]]\nfile = "@tools/bin/scan.py"\nargs = ["scan", "--all"]\n[[workflow.step]]\nfile = "local.sh"\n',
		'libs = ["zeta"]'
	) :: model.Workflow
	eq(wf.steps[1].kind, "file")
	eq((wf.steps[1].file :: model.FileRef).lib, "tools")
	eq((wf.steps[1].file :: model.FileRef).path, "bin/scan.py")
	eq(table.concat(wf.steps[1].args, " "), "scan --all", "file steps take args")
	eq((wf.steps[2].file :: model.FileRef).lib, nil, "no @: the workflow's own file")
	eq(table.concat(wf.libs, ","), "tools,zeta", "declared and referenced libraries, sorted")
	eq(wf.state, "w", "state group defaults to the id")
	eq((parse('[[workflow.step]]\nrun = "true"\n', 'state = "shared"') :: model.Workflow).state, "shared")

	for _, case in {
		{ '[[workflow.step]]\nfile = "../x.py"\n', "file" },
		{ '[[workflow.step]]\nfile = ".hidden.py"\n', "file" },
		{ '[[workflow.step]]\nfile = "@Bad/x.py"\n', "file" },
		{ '[[workflow.step]]\nfile = "notes.md"\n', "不支持的脚本类型" },
		{ '[[workflow.step]]\nfile = "a.py"\nrun = "true"\n', "只能选一个" },
		{ '[[workflow.step]]\nfile = "a.py"\nmodel = "x"\n', "model 只用于 omp" },
		{ '[[workflow.step]]\nrun = "true"\nargs = ["x"]\n', "run 步骤不接受" },
	} do
		local got, err = parse(case[1])
		eq(got, nil, case[1])
		assert(string.find(err or "", case[2], 1, true), `{case[1]} → {err}`)
	end
	local _, bad_state = parse('[[workflow.step]]\nrun = "true"\n', 'state = "../x"')
	assert(string.find(bad_state or "", "状态组", 1, true), tostring(bad_state))

	eq(model.valid_file_path("a/b/c.py"), true)
	eq(model.valid_file_path("a//b"), false)
	eq(model.valid_file_path("/abs"), false)
	eq(model.valid_file_path("a/../b"), false)
	eq(model.valid_file_path("1/2/3/4/5/6/7/8/9"), false, "at most 8 parts")
	eq((model.interpreter("x.PY") :: { string })[1], "python3", "extension case-insensitive")

	-- Encoding keeps the new keys.
	local raw = model.raw_workflow('[[workflow]]\nid = "w"\nstate = "s"\nlibs = ["l"]\n[[workflow.step]]\nfile = "@l/a.py"\nargs = ["x"]\n', "w")
	local again = model.raw_workflow(model.encode_workflow(raw :: any), "w") :: any
	eq(again.state, "s")
	eq(again.libs[1], "l")
	eq(again.step[1].file, "@l/a.py")
	eq(again.step[1].args[1], "x")
end

do -- tab / upgrade steps, evolve scopes and roost triggers
	local function first(text: string): string?
		local _, issues = model.parse_workflows(text)
		return if issues[1] then `{issues[1].path}: {issues[1].message}` else nil
	end
	local tabwf = '[[workflow]]\nid = "t"\n[[workflow.step]]\ntab = "open"\nkey = "logs"\ncommand = "tail -f x"\nkeep = true\n'
		.. '[[workflow.step]]\ntab = "close"\nkey = "logs"\n'
	local w = model.parse_workflows(tabwf) :: model.Workflows
	local open = w.by_id.t.steps[1]
	eq(open.kind, "tab")
	eq((open.tab :: model.TabStep).action, "open")
	eq((open.tab :: model.TabStep).keep, true)
	eq((open.tab :: model.TabStep).focus, false, "background by default")
	eq((w.by_id.t.steps[2].tab :: model.TabStep).action, "close")
	local again = model.parse_workflows(model.encode_workflow(model.raw_workflow(tabwf, "t") :: any)) :: model.Workflows
	eq((again.by_id.t.steps[1].tab :: model.TabStep).command, "tail -f x", "tab steps survive the encoder")
	assert(string.find(first('[[workflow]]\nid = "t"\n[[workflow.step]]\ntab = "close"\nkey = "a"\nkeep = true\n') or "", "只用于 tab = \"open\"", 1, true))
	assert(string.find(first('[[workflow]]\nid = "t"\n[[workflow.step]]\ntab = "open"\nkey = "a b"\n') or "", "标签页键", 1, true))
	assert(string.find(first('[[workflow]]\nid = "t"\n[[workflow.step]]\nrun = "x"\nkey = "a"\n') or "", "只用于 tab 步骤", 1, true))
	assert(string.find(first('[[workflow]]\nid = "t"\n[[workflow.step]]\nrun = "x"\ntab = "open"\nkey = "a"\n') or "", "只能选一个", 1, true))
	assert(string.find(first('[[workflow]]\nid = "u"\nworkspace = "temp"\n[[workflow.step]]\nupgrade = true\n') or "", "worktree", 1, true))
	eq((model.parse_workflows('[[workflow]]\nid = "u"\n[[workflow.step]]\nupgrade = true\n') :: model.Workflows).by_id.u.steps[1].kind, "upgrade")

	local base = '[[workflow]]\nid = "a"\n[[workflow.step]]\nrun = "true"\n[[workflow]]\nid = "b"\n[[workflow.step]]\nrun = "true"\n'
	local ev = model.parse_workflows(base .. '[[workflow]]\nid = "d"\nevolve = ["*"]\n[[workflow.trigger]]\nroost = "run_failed"\nstreak = 2\n[[workflow.step]]\nrun = "true"\n') :: model.Workflows
	local targets = model.evolve_targets(ev, ev.by_id.d)
	eq(table.concat(targets, ","), "a,b", "* is every workflow that evolves none itself")
	eq((ev.by_id.d.triggers[1] :: model.RoostTrigger).streak, 2)
	eq(model.describe_trigger(ev.by_id.d.triggers[1]), "被迭代的工作流连续 2 次失败")
	assert(string.find(first(base .. '[[workflow]]\nid = "d"\nevolve = ["d"]\n[[workflow.step]]\nrun = "true"\n') or "", "不能迭代自己", 1, true))
	assert(string.find(first(base .. '[[workflow]]\nid = "d"\nevolve = ["zz"]\n[[workflow.step]]\nrun = "true"\n') or "", "没有工作流", 1, true))
	assert(string.find(first(base .. '[[workflow]]\nid = "d"\nevolve = ["*"]\n[[workflow.step]]\nrun = "true"\n[[workflow]]\nid = "e"\nevolve = ["d"]\n[[workflow.step]]\nrun = "true"\n') or "", "不能被迭代", 1, true))
	assert(string.find(first(base .. '[[workflow]]\nid = "d"\n[[workflow.trigger]]\nroost = "run_failed"\n[[workflow.step]]\nrun = "true"\n') or "", "evolve", 1, true))
	assert(string.find(first(base .. '[[workflow]]\nid = "d"\nevolve = ["a"]\n[[workflow.trigger]]\nroost = "run_failed"\nworkflows = ["b"]\n[[workflow.step]]\nrun = "true"\n') or "", "不在 evolve 范围内", 1, true))
	local evraw = model.raw_workflow(base .. '[[workflow]]\nid = "d"\nevolve = ["a"]\n[[workflow.trigger]]\nroost = "run_failed"\n[[workflow.step]]\nrun = "true"\n', "d") :: any
	local enc = model.encode_workflow(evraw)
	assert(string.find(enc, 'evolve = ["a"]', 1, true) and string.find(enc, 'roost = "run_failed"', 1, true), enc)
end

do -- workflow groups: ids, names, order, sections and tolerant decoding
	local groups = require("../lib/groups")
	local g = groups.empty()
	local a = groups.create(g, "A") :: string
	local b = groups.create(g, "B") :: string
	eq(select(2, groups.create(g, "A")) ~= nil, true, "duplicate name refused")
	eq(select(2, groups.create(g, "")) ~= nil, true, "empty name refused")
	eq(select(2, groups.create(g, string.rep("名", groups.NAME_MAX + 1))) ~= nil, true, "too long (counted in characters)")
	eq(groups.rename(g, a, "B") ~= nil, true, "rename onto another group's name refused")
	eq(groups.rename(g, a, "A"), nil, "renaming to its own name is fine")
	-- A deleted group's workflows don't land in a later group that gets the same id.
	groups.assign(g, "v", b)
	eq(groups.remove(g, b), nil)
	local c = groups.create(g, "C") :: string
	eq(groups.group_of(g, "v"), nil, "v stays ungrouped")
	eq(groups.move(g, a, -1), false, "first can't move up")
	eq(groups.move(g, a, 1), true)
	eq(g.list[1].id, c)
	eq(groups.move(g, a, 1), false, "last can't move down")
	eq(groups.assign(g, "x", "g999") ~= nil, true, "unknown group refused")
	groups.assign(g, "x", a)
	groups.assign(g, "y", c)
	-- Sections: every group in order (empty ones too), then the ungrouped; file order inside.
	local d = groups.create(g, "D") :: string
	local secs = groups.sections(g, { "z", "y", "x", "w" }, function(s: string): string
		return s
	end)
	eq(#secs, 4)
	eq((secs[1].group :: any).id, c)
	eq(secs[1].items[1], "y")
	eq((secs[2].group :: any).id, a)
	eq((secs[3].group :: any).id, d)
	eq(#secs[3].items, 0, "an empty group still shows")
	eq(secs[4].group, nil)
	eq(table.concat(secs[4].items, ","), "z,w")
	-- Removing a group ungroups its workflows.
	groups.remove(g, a)
	eq(groups.group_of(g, "x"), nil)
	-- Decoding drops malformed entries and memberships of unknown groups.
	local back = groups.decode({
		groups = { { id = "g1", name = "ok" }, { id = "bad", name = "x" }, { id = "g1", name = "dup" }, { id = "g2", name = "" } },
		of = { a = "g1", b = "g7", c = 3 },
	})
	eq(#back.list, 1)
	eq(back.of.a, "g1")
	eq(back.of.b, nil)
	eq(back.of.c, nil)
end

do -- device sync: run summaries stay under the relay's limit, tails first, and read back
	local fleet = require("../lib/fleet")
	local runs = {}
	local tails: { [string]: string } = {}
	for i = 1, 120 do
		local id = string.format("%04x", i)
		table.insert(runs, {
			id = id,
			workflow = "w",
			workflow_name = "W",
			title = "t",
			trigger = { kind = "cron", detail = "每天" },
			state = if i == 1 then "running" else "success",
			created_at = 1000 + i,
			inputs = { SECRET = "x" },
			steps = {
				{ name = "s", kind = "run", state = "success", exit_code = 0 },
				{ name = "a", kind = "omp", state = "success", model = "@smol", models = { { model = "x/m", agent = "Sub" }, { role = "judge" } :: any } } :: any,
			},
			step = 1,
		})
		tails[id] = string.rep("y", fleet.TAIL_BYTES)
	end
	local small = F.decode(fleet.summaries(runs, tails))
	eq(#small.runs, fleet.MAX_RUNS, "at most MAX_RUNS")
	eq(small.runs[1].inputs, nil, "inputs never leave the machine")
	local back, back_tails = fleet.decode_runs(small)
	eq(#back, fleet.MAX_RUNS)
	eq(back[1].steps[1].exit_code, 0)
	local a = back[1].steps[2]
	eq(a.model, "@smol", "an agent step's model setting reaches observers")
	eq(a.models and #a.models, 1, "and the models it used, malformed ones dropped")
	eq(a.models and a.models[1].agent, "Sub")
	eq(#back_tails["0001"], fleet.TAIL_BYTES, "the newest carry tails")
	eq(back_tails[string.format("%04x", fleet.TAILS + 1)], nil, "older ones don't")

	-- Too big with tails: they go first, the runs stay.
	local big = string.rep("z", 30 * 1024)
	for id in tails do
		tails[id] = big
	end
	local body = fleet.summaries(runs, tails)
	eq(#body <= fleet.MAX_BODY, true, "under the limit")
	local dropped = F.decode(body)
	eq(#dropped.runs, fleet.MAX_RUNS, "every run kept")
	eq(dropped.runs[1].log, nil, "tails dropped")

	eq(fleet.clean_tail("ial line\nnext\n", false), "next\n", "a cut line is dropped")
	eq(fleet.clean_tail("\128\129abc", false), "abc", "a cut UTF-8 sequence is dropped")
	eq(fleet.clean_tail("whole\n", true), "whole\n")
end

print("ok")
