local M = {}

local inflight = false

local config = {
  api_url = "http://desktop-porm1e3:9999/v1",
  model = "qwen/qwen3-coder-30b",
  --model = "openai/gpt-oss-20b",
  request_timeout = 30,
  connect_timeout = 5,
}

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
end

local function notify_err(msg)
  vim.notify(msg, vim.log.levels.ERROR)
end

local function extract_llm_content(decoded)
  if decoded.error then
    local err_msg = decoded.error.message or decoded.error.code or vim.inspect(decoded.error)
    return nil, "LLM error: " .. tostring(err_msg)
  end

  if type(decoded.choices) ~= "table" or #decoded.choices == 0 then
    return nil, "LLM response missing choices"
  end

  local first = decoded.choices[1]
  local content = first and first.message and first.message.content
  if not content or content == "" then
    return nil, "LLM response missing content"
  end

  return content, nil
end

local function build_prompt(user_prompt, content)
  local header = table.concat({
    "``````",
    content,
    "``````",
    "",
    "User request:",
    user_prompt,
  }, "\n")

  return header
end

local function call_llm_async(prompt, callback)
  local payload = {
    model = config.model,
    temperature = 0,
    messages = {
      {
        role = "system",
        content = table.concat({
          "You are an expert developer who edits the provided text code snippet.",
          "You edit by returning only the fully updated snippet without explanations or diffs.",
        }, "\n")
      },
      { role = "user", content = prompt },
    },
  }

  local encoded = vim.fn.json_encode(payload)
  local cmd = { "curl", "-sS", "--fail-with-body" }
  if config.request_timeout then
    vim.list_extend(cmd, { "--max-time", tostring(config.request_timeout) })
  end
  if config.connect_timeout then
    vim.list_extend(cmd, { "--connect-timeout", tostring(config.connect_timeout) })
  end
  vim.list_extend(cmd, {
    "-X",
    "POST",
    config.api_url .. "/chat/completions",
    "-H",
    "Content-Type: application/json",
    "--data-binary",
    "@-",
  })

  vim.system(cmd, { text = true, stdin = encoded }, vim.schedule_wrap(function(proc)
    if proc.code ~= 0 then
      callback(nil, string.format("curl failed (%d): %s", proc.code, proc.stderr ~= "" and proc.stderr or proc.stdout))
      return
    end

    local decoded, err = vim.json.decode(proc.stdout)
    if not decoded then
      callback(nil, "failed to decode LLM response: " .. tostring(err))
      return
    end

    local content, shape_err = extract_llm_content(decoded)
    if not content then
      callback(nil, shape_err)
      return
    end

    callback(content, nil)
  end))
end

local function extract_file_content(llm_output)
  local normalized = llm_output:gsub("\r\n", "\n")
  -- Handle ```lang\n...\n``` or just ```\n...\n```
  local body = normalized:match("^```[^\n]*\n(.-)```%s*$") or normalized
  return body
end

local function strip_trailing_new_line(lines)
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines, #lines)
  end
end

local function apply_file_content(buf, new_content)
  if not vim.api.nvim_buf_is_valid(buf) then
    notify_err("Target buffer is no longer valid")
    return
  end
  local lines = vim.split(new_content, "\n", { plain = true })
  strip_trailing_new_line(lines)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

local function is_visual_mode(mode)
  return mode == "v" or mode == "V" or mode == "\22"
end

local function capture_visual_region(buf, mode)
  if mode == "\22" then
    return nil, "Blockwise visual is not supported"
  end

  -- Use '< and '> marks (0-indexed row, 0-indexed col)
  local start_pos = vim.api.nvim_buf_get_mark(buf, "<")
  local end_pos = vim.api.nvim_buf_get_mark(buf, ">")
  local srow, scol = start_pos[1] - 1, start_pos[2]
  local erow, ecol = end_pos[1] - 1, end_pos[2]

  local text, end_col_excl
  if mode == "V" then
    local lines = vim.api.nvim_buf_get_lines(buf, srow, erow + 1, false)
    text = table.concat(lines, "\n")
    scol, end_col_excl = 0, 0 -- line-wise: full lines
  else
    local line = vim.api.nvim_buf_get_lines(buf, erow, erow + 1, false)[1] or ""
    end_col_excl = math.min(ecol + 1, #line)
    text = table.concat(
      vim.api.nvim_buf_get_text(buf, srow, scol, erow, end_col_excl, {}),
      "\n"
    )
  end

  if text == "" then
    return nil, "Visual selection is empty"
  end

  return {
    buf = buf,
    mode = mode,
    srow = srow,
    scol = scol,
    erow = erow,
    ecol = end_col_excl,
    text = text,
  }, nil
end

local function apply_captured_region(sel, new_content)
  if not vim.api.nvim_buf_is_valid(sel.buf) then
    return nil, "Target buffer is no longer valid"
  end

  local lines = vim.split(new_content, "\n", { plain = true })
  strip_trailing_new_line(lines)

  if sel.mode == "V" then
    vim.api.nvim_buf_set_lines(sel.buf, sel.srow, sel.erow + 1, false, lines)
  else
    vim.api.nvim_buf_set_text(sel.buf, sel.srow, sel.scol, sel.erow, sel.ecol, lines)
  end
  return true, nil
end

function M.apply_llm_patch()
  if inflight then
    vim.notify("LLM request already in progress", vim.log.levels.WARN)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local text, apply_fn

  local mode = vim.api.nvim_get_mode().mode

  if is_visual_mode(mode) then
    vim.cmd("normal! \27")
    local sel, err = capture_visual_region(buf, mode)
    if err or not sel then
      notify_err(err); return
    end
    text = sel.text
    apply_fn = function(new_content)
      local ok, apply_err = apply_captured_region(sel, new_content)
      if not ok and apply_err then
        notify_err(apply_err)
      end
    end
  else
    text = table.concat(
      vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      "\n"
    )
    apply_fn = function(c) apply_file_content(buf, c) end
  end


  vim.ui.input({ prompt = "LLM prompt: " }, function(user_prompt)
    if not user_prompt or user_prompt == "" then return end

    inflight = true

    vim.notify("LLM request in progress...", vim.log.levels.INFO)

    local prompt = build_prompt(user_prompt, text)
    local start_ns = vim.loop.hrtime()

    call_llm_async(prompt, function(resp, err)
      inflight = false
      if err then
        notify_err(err); return
      end

      local content = extract_file_content(resp)
      if content == "" then
        notify_err("LLM returned empty"); return
      end

      apply_fn(content)
      local elapsed = (vim.loop.hrtime() - start_ns) / 1e9
      vim.notify(string.format("LLM finished (%.2fs)", elapsed), vim.log.levels.INFO)
    end)
  end)
end

return M
