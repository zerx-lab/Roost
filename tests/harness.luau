--!strict
-- Typed stand-in for the fresh helper `tests/run.py` injects.
-- The runner replaces this module with `{ fresh = __fresh }` before the chunk runs, so the
-- function below is what `luau-lsp` sees and never what the tests call. `__fresh` itself cannot
-- appear in an analyzed file: it is a local the bundler splices in, unknown to the language server.

local M = {}

function M.fresh(_env: any) end

return M
