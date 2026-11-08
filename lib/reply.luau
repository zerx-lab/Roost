--!strict
-- Answering where a run was asked (workflow `reply = true`, for runs started by an issue or PR
-- event): an `ack` step comments on that issue/PR that the run started, a `report` step (which runs
-- even when the run failed or was cancelled, like cleanup) edits that comment into how it ended
-- and the final answer. Both run `gh api` with the run's identity (the App, or the local gh).

local util = require("./util")

local M = {}

-- Longest answer quoted in the comment (GitHub takes 65536 characters).
M.MAX_ANSWER = 60000

-- `sh -c ACK roost TEXT`: the comment, its id kept for the report.
M.ACK = [[
set -e
id=$(gh api "repos/$ROOST_REPO/issues/$ROOST_NUMBER/comments" -f body="$1" --jq .id)
printf '%s\n' "$id" >"$ROOST_RUN_DIR/reply.id"
echo "[roost] 已在 #$ROOST_NUMBER 回复(评论 $id)"
]]

-- `sh -c REPORT roost FILE`: the ack comment edited to FILE's text, or a new comment without one.
M.REPORT = [[
id=$(cat "$ROOST_RUN_DIR/reply.id" 2>/dev/null)
if [ -n "$id" ] && gh api -X PATCH "repos/$ROOST_REPO/issues/comments/$id" -F body=@"$1" >/dev/null; then
	echo "[roost] 已更新评论 $id"
	exit 0
fi
gh api "repos/$ROOST_REPO/issues/$ROOST_NUMBER/comments" -F body=@"$1" >/dev/null || exit 1
echo "[roost] 已在 #$ROOST_NUMBER 回复结果"
]]

function M.ack_text(run: string): string
	return `Roost 收到,正在处理…(运行 \`{run}\`)`
end

local STATE_TEXT: { [string]: string } = {
	success = "已完成",
	failed = "失败",
	cancelled = "已取消",
	timed_out = "超时",
	interrupted = "中断",
	skipped = "已跳过",
}

-- The report comment: how the run ended, then its final answer. Mentions are defused (a zero-width
-- space after `@`), so the answer pings nobody and never triggers a mention workflow again. The
-- answer is cut after defusing, on a UTF-8 boundary: MAX_ANSWER bytes are at most as many characters.
function M.body(state: string, reason: string?, answer: string?, run: string): string
	local head = `**Roost {STATE_TEXT[state] or state}**(运行 \`{run}\`)`
	if reason and reason ~= "" and state ~= "success" then
		head ..= `:{util.clip(reason, 500)}`
	end
	local text = (string.gsub(head, "@", "@\u{200B}"))
	if answer and util.trim(answer) ~= "" then
		local a = string.gsub(answer, "@", "@\u{200B}")
		if #a > M.MAX_ANSWER then
			local n = M.MAX_ANSWER
			-- Back off continuation bytes so the cut never splits a character.
			while n > 0 and string.byte(a, n + 1) and (string.byte(a, n + 1) :: number) >= 0x80 and (string.byte(a, n + 1) :: number) < 0xC0 do
				n -= 1
			end
			a = string.sub(a, 1, n) .. "\n\n…(已截断,完整内容见 Roost 运行日志)"
		end
		text ..= "\n\n" .. a
	end
	return text
end

return M
