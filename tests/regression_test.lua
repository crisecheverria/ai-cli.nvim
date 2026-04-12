local helpers = dofile("tests/helpers.lua")

local config = require("ai-cli.config")
local providers = require("ai-cli.providers")
local diff = require("ai-cli.diff")

-- Initialize diff module with split mode (the new default)
diff.setup({ diff = { mode = "split", accept_key = "ga", reject_key = "gr" } })

local function with_clean_buffer()
  vim.cmd("enew")
end

local function test_config_and_provider()
  local merged = config.apply({
    terminal = {
      split_width_percentage = 0.55,
    },
  })

  helpers.assert_eq(merged.provider, "gemini", "Default provider should remain gemini")
  helpers.assert_eq(merged.terminal.split_width_percentage, 0.55, "Terminal width override should merge deeply")
  helpers.assert_eq(merged.diff.mode, "split", "Default diff mode should be split")

  local ok = pcall(config.apply, {
    terminal = {
      split_width_percentage = 2,
    },
  })
  assert(not ok, "Invalid terminal width should fail validation")

  local bad_mode = pcall(config.apply, {
    diff = { mode = "invalid" },
  })
  assert(not bad_mode, "Invalid diff mode should fail validation")

  local provider = providers.get("gemini")
  helpers.assert_eq(provider.name, "gemini", "Gemini provider should be resolved from registry")
  helpers.assert_eq(
    provider.build_command({ terminal_cmd = "my-gemini" }),
    "my-gemini",
    "Provider should respect terminal_cmd"
  )

  local prepared = provider.prepare_launch({
    env = { EXISTING = "1" },
  }, {
    bridge_port = 7777,
    auth_token = "secret",
    pid = 1234,
  })
  local env = prepared.env
  helpers.assert_eq(env.EXISTING, "1", "Provider env merge should preserve existing keys")
  helpers.assert_eq(env.GEMINI_CLI_IDE_SERVER_PORT, "7777", "Provider should set bridge port env")
  helpers.assert_eq(env.GEMINI_CLI_IDE_PID, "1234", "Provider should set pid env")
  assert(type(prepared.defaults_path) == "string" and prepared.defaults_path ~= "", "Gemini defaults path should be set")
  helpers.assert_eq(env.GEMINI_CLI_SYSTEM_DEFAULTS_PATH, prepared.defaults_path, "Provider should set defaults path env")

  local codex = providers.get("codex")
  helpers.assert_eq(codex.name, "codex", "Codex provider should be resolved from registry")
  helpers.assert_eq(codex.build_command({ terminal_cmd = "my-codex" }), "my-codex", "Codex should respect terminal_cmd")

  local codex_prepared = codex.prepare_launch({
    env = { EXISTING = "1" },
  }, {
    bridge_port = 8123,
    auth_token = "codex-token",
    pid = 4321,
  })
  helpers.assert_eq(codex_prepared.env.EXISTING, "1", "Codex env merge should preserve existing keys")
  helpers.assert_eq(
    codex_prepared.env.AI_CLI_MCP_SERVER_URL,
    "http://127.0.0.1:8123/mcp",
    "Codex provider should expose the local MCP server URL"
  )
  helpers.assert_eq(
    codex_prepared.env.AI_CLI_MCP_AUTH_TOKEN,
    "codex-token",
    "Codex provider should expose the MCP bearer token"
  )
  helpers.assert_eq(codex_prepared.defaults_path, nil, "Codex provider should not write provider defaults")
  assert(
    type(codex_prepared.instructions_path) == "string" and codex_prepared.instructions_path ~= "",
    "Codex provider should create a model instructions file"
  )

  local codex_argv = codex.build_argv({ terminal_cmd = "my-codex" }, codex_prepared)
  helpers.assert_eq(codex_argv[1], "my-codex", "Codex argv should start with the configured command")
  local argv_joined = table.concat(codex_argv, "\n")
  assert(argv_joined:match("hide_agent_reasonings=true"), "Codex argv should hide agent reasonings")
  assert(argv_joined:match("show_raw_agent_reasoning=false"), "Codex argv should disable raw reasoning output")
  assert(argv_joined:match('model_verbosity="low"'), "Codex argv should lower verbosity")
  assert(argv_joined:match('mcp_servers%.ai_cli_nvim%.url="http://127%.0%.0%.1:8123/mcp"'), "Codex argv should register the MCP bridge URL")
  assert(
    argv_joined:match('mcp_servers%.ai_cli_nvim%.bearer_token_env_var="AI_CLI_MCP_AUTH_TOKEN"'),
    "Codex argv should register the bearer token env var"
  )
  assert(
    argv_joined:match('model_instructions_file="'),
    "Codex argv should pass the Codex model instructions file"
  )

  local claude = providers.get("claude")
  helpers.assert_eq(claude.name, "claude", "Claude provider should be resolved from registry")
  helpers.assert_eq(claude.build_command({ terminal_cmd = "my-claude" }), "my-claude", "Claude should respect terminal_cmd")

  local claude_prepared = claude.prepare_launch({
    env = { EXISTING = "1" },
  }, {
    bridge_port = 9234,
    auth_token = "claude-token",
    pid = 5678,
  })
  helpers.assert_eq(claude_prepared.env.EXISTING, "1", "Claude env merge should preserve existing keys")
  helpers.assert_eq(
    claude_prepared.env.AI_CLI_MCP_SERVER_URL,
    "http://127.0.0.1:9234/mcp",
    "Claude provider should expose the local MCP server URL"
  )
  helpers.assert_eq(
    claude_prepared.env.AI_CLI_MCP_AUTH_TOKEN,
    "claude-token",
    "Claude provider should expose the MCP auth token"
  )
  assert(
    type(claude_prepared.instructions_path) == "string" and claude_prepared.instructions_path ~= "",
    "Claude provider should create a system prompt file"
  )
  assert(
    type(claude_prepared.mcp_config_path) == "string" and claude_prepared.mcp_config_path ~= "",
    "Claude provider should create an MCP config file"
  )

  local claude_argv = claude.build_argv({ terminal_cmd = "my-claude" }, claude_prepared)
  helpers.assert_eq(claude_argv[1], "my-claude", "Claude argv should start with the configured command")
  local claude_joined = table.concat(claude_argv, "\n")
  assert(claude_joined:match("%-%-strict%-mcp%-config"), "Claude argv should use strict MCP config")
  assert(claude_joined:match("%-%-mcp%-config"), "Claude argv should pass an MCP config file")
  assert(claude_joined:match("%-%-append%-system%-prompt"), "Claude argv should append a system prompt")
  assert(
    claude_joined:match("%-%-disallowedTools"),
    "Claude argv should disallow built-in edit tools so MCP diff review is used"
  )
  assert(
    claude_joined:match("Edit,MultiEdit,Write,NotebookEdit"),
    "Claude argv should disable the built-in Claude edit tools"
  )
end

local function test_split_diff_accept_flow()
  with_clean_buffer()
  local path = helpers.make_temp_file("before\n")

  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local result = diff.open_diff({
    filePath = path,
    newContent = "after\n",
  })

  helpers.assert_eq(result.status, "opened", "Visible files should open a review immediately")
  assert(vim.wo.diff, "Split review window should be in diff mode")

  -- Verify the buffer is the original side (has the file's filetype, not "diff")
  local buf_name = vim.api.nvim_buf_get_name(0)
  assert(buf_name:match("ai%-cli://original/"), "Current buffer should be the original side: " .. buf_name)

  local keymaps = vim.api.nvim_buf_get_keymap(0, "n")
  local has_accept = false
  local has_reject = false
  for _, map in ipairs(keymaps) do
    if map.lhs == "ga" then
      has_accept = true
    elseif map.lhs == "gr" then
      has_reject = true
    end
  end
  assert(has_accept, "Original buffer should expose the apply mapping")
  assert(has_reject, "Original buffer should expose the reject mapping")

  -- Count windows before accept (should be 2: original + proposed)
  local win_count_before = #vim.api.nvim_tabpage_list_wins(0)
  assert(win_count_before >= 2, "Split mode should create at least two windows")

  vim.cmd("normal ga")

  helpers.wait(200, function()
    return helpers.read_file(path) == "after\n"
  end, "Accepted diff should write the proposed content to disk")

  helpers.assert_eq(
    vim.api.nvim_buf_get_name(0),
    vim.fs.normalize(path),
    "Original file buffer should be restored after apply"
  )

  -- Verify diff mode is off after accept
  assert(not vim.wo.diff, "Diff mode should be off after accepting changes")

  local closed = diff.close_diff(path)
  helpers.assert_eq(closed.status, "accepted", "Accepted diff should be remembered as accepted")
  helpers.assert_eq(closed.acceptedInEditor, true, "Accepted diff should report editor acceptance")
  helpers.assert_eq(closed.finalContent, "after\n", "Accepted diff should return final content")
end

local function test_split_diff_reject_flow()
  with_clean_buffer()
  local path = helpers.make_temp_file("original\n")

  vim.cmd("edit " .. vim.fn.fnameescape(path))
  diff.open_diff({
    filePath = path,
    newContent = "modified\n",
  })

  assert(vim.wo.diff, "Review window should be in diff mode")
  vim.cmd("normal gr")

  helpers.assert_eq(helpers.read_file(path), "original\n", "Rejected diff should not modify the file")
  helpers.assert_eq(
    vim.api.nvim_buf_get_name(0),
    vim.fs.normalize(path),
    "Original file buffer should be restored after reject"
  )
  assert(not vim.wo.diff, "Diff mode should be off after rejecting changes")
end

local function test_diff_opens_for_unloaded_file()
  with_clean_buffer()
  local unrelated = helpers.make_temp_file("unrelated\n")
  local target = helpers.make_temp_file("old\n")

  vim.cmd("edit " .. vim.fn.fnameescape(unrelated))
  local result = diff.open_diff({
    filePath = target,
    newContent = "new\n",
  })

  -- The diff opens in the best available window even when the target file
  -- isn't loaded, as long as a normal editor window is available.
  helpers.assert_eq(result.status, "opened", "Diff should open in available editor window")
  assert(vim.wo.diff, "Review should activate diff mode")

  local closed = diff.close_diff(target)
  helpers.assert_eq(closed.status, "closed", "Closing an active diff should report closed status")
  helpers.assert_eq(closed.finalContent, "new\n", "Closed review should return proposed content")
end

local function test_get_diff_status_is_non_destructive()
  with_clean_buffer()
  local target = helpers.make_temp_file("before\n")

  vim.cmd("edit " .. vim.fn.fnameescape(target))
  local result = diff.open_diff({
    filePath = target,
    newContent = "after\n",
  })

  helpers.assert_eq(result.status, "opened", "Visible file should open review immediately")

  local status = diff.get_diff_status(target)
  helpers.assert_eq(status.status, "opened", "Status check should report an open review")
  helpers.assert_eq(status.finalContent, "after\n", "Status check should preserve proposed content")
  assert(vim.wo.diff, "Status check should not close the review (diff mode still active)")

  local closed = diff.close_diff(target)
  helpers.assert_eq(closed.status, "closed", "Explicit close should still close the review")
end

local function test_pending_external_resolution()
  with_clean_buffer()
  local unrelated = helpers.make_temp_file("unrelated\n")
  local target = helpers.make_temp_file("before\n")

  vim.cmd("edit " .. vim.fn.fnameescape(unrelated))
  local result = diff.open_diff({
    filePath = target,
    newContent = "accepted externally\n",
  })

  -- Close the active diff without accepting so we can test external resolution
  diff.close_diff(target)

  -- Simulate external tool writing the proposed content to disk
  helpers.write_file(target, "accepted externally\n")

  -- Re-open the diff (it was closed, not pending)
  diff.open_diff({
    filePath = target,
    newContent = "accepted externally\n",
  })
  diff.sync_external_resolution()

  local closed = diff.close_diff(target)
  helpers.assert_eq(closed.status, "accepted", "Externally applied diff should resolve as accepted")
  helpers.assert_eq(closed.acceptedInEditor, true, "External resolution should be reported as accepted")
  helpers.assert_eq(closed.finalContent, "accepted externally\n", "External resolution should preserve final content")
end

local function test_active_external_resolution()
  with_clean_buffer()
  local target = helpers.make_temp_file("before\n")

  vim.cmd("edit " .. vim.fn.fnameescape(target))
  local result = diff.open_diff({
    filePath = target,
    newContent = "active external apply\n",
  })

  helpers.assert_eq(result.status, "opened", "Visible file should open review before external apply")
  helpers.write_file(target, "active external apply\n")
  diff.sync_external_resolution()

  local closed = diff.close_diff(target)
  helpers.assert_eq(closed.status, "accepted", "Externally applied active diff should resolve as accepted")
  helpers.assert_eq(closed.acceptedInEditor, true, "Resolved active diff should be marked accepted")
  helpers.assert_eq(closed.finalContent, "active external apply\n", "Resolved active diff should keep final content")
end

local function test_unified_mode_backward_compat()
  -- Switch to unified mode
  diff.setup({ diff = { mode = "unified", accept_key = "ga", reject_key = "gr" } })

  with_clean_buffer()
  local path = helpers.make_temp_file("before\n")

  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local result = diff.open_diff({
    filePath = path,
    newContent = "after\n",
  })

  helpers.assert_eq(result.status, "opened", "Unified mode should open review")
  helpers.assert_eq(vim.bo.filetype, "diff", "Unified review buffer should use diff filetype")

  vim.cmd("normal ga")

  helpers.wait(200, function()
    return helpers.read_file(path) == "after\n"
  end, "Unified mode accept should write proposed content to disk")

  helpers.assert_eq(
    vim.api.nvim_buf_get_name(0),
    vim.fs.normalize(path),
    "Unified mode should restore original buffer after apply"
  )

  -- Restore split mode for any subsequent tests
  diff.setup({ diff = { mode = "split", accept_key = "ga", reject_key = "gr" } })
end

test_config_and_provider()
test_split_diff_accept_flow()
test_split_diff_reject_flow()
test_diff_opens_for_unloaded_file()
test_get_diff_status_is_non_destructive()
test_pending_external_resolution()
test_active_external_resolution()
test_unified_mode_backward_compat()

print("All regression tests passed!")
