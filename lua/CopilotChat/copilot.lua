---@class CopilotChat.copilot.embed
---@field filename string
---@field filetype string
---@field prompt string?
---@field content string?

---@class CopilotChat.copilot.ask.opts
---@field selection string?
---@field embeddings table<CopilotChat.copilot.embed>?
---@field filename string?
---@field filetype string?
---@field start_row number?
---@field end_row number?
---@field system_prompt string?
---@field model string?
---@field temperature number?
---@field on_progress nil|fun(response: string):nil

---@class CopilotChat.copilot.embed.opts
---@field model string?
---@field chunk_size number?

---@class CopilotChat.Copilot
---@field ask fun(self: CopilotChat.Copilot, prompt: string, opts: CopilotChat.copilot.ask.opts):string,number,number
---@field embed fun(self: CopilotChat.Copilot, inputs: table, opts: CopilotChat.copilot.embed.opts?):table<CopilotChat.copilot.embed>
---@field stop fun(self: CopilotChat.Copilot):boolean
---@field reset fun(self: CopilotChat.Copilot):boolean
---@field save fun(self: CopilotChat.Copilot, name: string, path: string):nil
---@field load fun(self: CopilotChat.Copilot, name: string, path: string):table
---@field running fun(self: CopilotChat.Copilot):boolean
---@field list_models fun(self: CopilotChat.Copilot):table

local async = require('plenary.async')
local log = require('plenary.log')
local curl = require('plenary.curl')
local prompts = require('CopilotChat.prompts')
local tiktoken = require('CopilotChat.tiktoken')
local utils = require('CopilotChat.utils')
local class = utils.class
local temp_file = utils.temp_file
local timeout = 30000
local version_headers = {
  ['editor-version'] = 'Neovim/'
    .. vim.version().major
    .. '.'
    .. vim.version().minor
    .. '.'
    .. vim.version().patch,
  ['editor-plugin-version'] = 'CopilotChat.nvim/2.0.0',
  ['user-agent'] = 'CopilotChat.nvim/2.0.0',
}

local curl_get = async.wrap(function(url, opts, callback)
  opts = vim.tbl_deep_extend('force', opts, { callback = callback })
  curl.get(url, opts)
end, 3)

local curl_post = async.wrap(function(url, opts, callback)
  opts = vim.tbl_deep_extend('force', opts, { callback = callback })
  curl.post(url, opts)
end, 3)

local tiktoken_load = async.wrap(function(tokenizer, callback)
  tiktoken.load(tokenizer, callback)
end, 2)

local function uuid()
  local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
  return (
    string.gsub(template, '[xy]', function(c)
      local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
      return string.format('%x', v)
    end)
  )
end

local function machine_id()
  local length = 65
  local hex_chars = '0123456789abcdef'
  local hex = ''
  for _ = 1, length do
    hex = hex .. hex_chars:sub(math.random(1, #hex_chars), math.random(1, #hex_chars))
  end
  return hex
end

local function find_config_path()
  local config = vim.fn.expand('$XDG_CONFIG_HOME')
  if config and vim.fn.isdirectory(config) > 0 then
    return config
  end
  if vim.fn.has('win32') > 0 then
    config = vim.fn.expand('$LOCALAPPDATA')
    if not config or vim.fn.isdirectory(config) == 0 then
      config = vim.fn.expand('$HOME/AppData/Local')
    end
  else
    config = vim.fn.expand('$HOME/.config')
  end
  if config and vim.fn.isdirectory(config) > 0 then
    return config
  end
end

local function get_cached_token()
  -- loading token from the environment only in GitHub Codespaces
  local token = os.getenv('GITHUB_TOKEN')
  local codespaces = os.getenv('CODESPACES')
  if token and codespaces then
    return token
  end

  -- loading token from the file
  local config_path = find_config_path()
  if not config_path then
    return nil
  end

  -- token can be sometimes in apps.json sometimes in hosts.json
  local file_paths = {
    config_path .. '/github-copilot/hosts.json',
    config_path .. '/github-copilot/apps.json',
  }

  for _, file_path in ipairs(file_paths) do
    if vim.fn.filereadable(file_path) == 1 then
      local userdata = vim.fn.json_decode(vim.fn.readfile(file_path))
      for key, value in pairs(userdata) do
        if string.find(key, 'github.com') then
          return value.oauth_token
        end
      end
    end
  end

  return nil
end

local function generate_selection_message(filename, filetype, start_row, end_row, selection)
  if not selection or selection == '' then
    return ''
  end

  local content = selection
  if start_row > 0 then
    local lines = vim.split(selection, '\n')
    local total_lines = #lines
    local max_length = #tostring(total_lines)
    for i, line in ipairs(lines) do
      local formatted_line_number = string.format('%' .. max_length .. 'd', i - 1 + start_row)
      lines[i] = formatted_line_number .. ': ' .. line
    end
    content = table.concat(lines, '\n')
  end

  return string.format('Active selection: `%s`\n```%s\n%s\n```', filename, filetype, content)
end

local function generate_embeddings_message(embeddings)
  local files = {}
  for _, embedding in ipairs(embeddings) do
    local filename = embedding.filename
    if not files[filename] then
      files[filename] = {}
    end
    table.insert(files[filename], embedding)
  end

  local out = {
    header = 'Open files:\n',
    files = {},
  }

  for filename, group in pairs(files) do
    table.insert(
      out.files,
      string.format(
        'File: `%s`\n```%s\n%s\n```\n',
        filename,
        group[1].filetype,
        table.concat(
          vim.tbl_map(function(e)
            return vim.trim(e.content)
          end, group),
          '\n'
        )
      )
    )
  end
  return out
end

local function generate_ask_request(
  history,
  prompt,
  embeddings,
  selection,
  system_prompt,
  model,
  temperature,
  stream
)
  local messages = {}
  local system_role = stream and 'system' or 'user'

  if system_prompt ~= '' then
    table.insert(messages, {
      content = system_prompt,
      role = system_role,
    })
  end

  for _, message in ipairs(history) do
    table.insert(messages, message)
  end

  if embeddings and #embeddings.files > 0 then
    table.insert(messages, {
      content = embeddings.header .. table.concat(embeddings.files, ''),
      role = system_role,
    })
  end

  if selection ~= '' then
    table.insert(messages, {
      content = selection,
      role = system_role,
    })
  end

  table.insert(messages, {
    content = prompt,
    role = 'user',
  })

  if stream then
    return {
      intent = true,
      model = model,
      n = 1,
      stream = true,
      temperature = temperature,
      top_p = 1,
      messages = messages,
    }
  else
    return {
      messages = messages,
      stream = false,
      model = model,
    }
  end
end

local function generate_embedding_request(inputs, model)
  return {
    input = vim.tbl_map(function(input)
      local out = ''
      if input.prompt then
        out = input.prompt .. '\n'
      end
      if input.content then
        out = out
          .. string.format(
            'File: `%s`\n```%s\n%s\n```',
            input.filename,
            input.filetype,
            input.content
          )
      end
      return out
    end, inputs),
    model = model,
  }
end

local function count_history_tokens(history)
  local count = 0
  for _, msg in ipairs(history) do
    count = count + tiktoken.count(msg.content)
  end
  return count
end

local Copilot = class(function(self, proxy, allow_insecure)
  self.proxy = proxy
  self.allow_insecure = allow_insecure
  self.github_token = get_cached_token()
  self.history = {}
  self.token = nil
  self.sessionid = nil
  self.machineid = machine_id()
  self.models = nil
  self.claude_enabled = false
  self.current_job = nil
end)

function Copilot:authenticate()
  if not self.github_token then
    error(
      'No GitHub token found, please use `:Copilot auth` to set it up from copilot.lua or `:Copilot setup` for copilot.vim'
    )
  end

  if
    not self.token or (self.token.expires_at and self.token.expires_at <= math.floor(os.time()))
  then
    local sessionid = uuid() .. tostring(math.floor(os.time() * 1000))
    local headers = {
      ['authorization'] = 'token ' .. self.github_token,
      ['accept'] = 'application/json',
    }
    for key, value in pairs(version_headers) do
      headers[key] = value
    end

    local response = curl_get('https://api.github.com/copilot_internal/v2/token', {
      timeout = timeout,
      headers = headers,
      proxy = self.proxy,
      insecure = self.allow_insecure,
    })

    if response.status ~= 200 then
      error('Failed to authenticate: ' .. tostring(response.status))
    end

    self.sessionid = sessionid
    self.token = vim.json.decode(response.body)
  end

  local headers = {
    ['authorization'] = 'Bearer ' .. self.token.token,
    ['x-request-id'] = uuid(),
    ['vscode-sessionid'] = self.sessionid,
    ['vscode-machineid'] = self.machineid,
    ['copilot-integration-id'] = 'vscode-chat',
    ['openai-organization'] = 'github-copilot',
    ['openai-intent'] = 'conversation-panel',
    ['content-type'] = 'application/json',
  }
  for key, value in pairs(version_headers) do
    headers[key] = value
  end

  return headers
end

function Copilot:fetch_models()
  if self.models then
    return self.models
  end

  local response = curl_get('https://api.githubcopilot.com/models', {
    timeout = timeout,
    headers = self:authenticate(),
    proxy = self.proxy,
    insecure = self.allow_insecure,
  })

  if response.status ~= 200 then
    error('Failed to fetch models: ' .. tostring(response.status))
  end

  -- Find chat models
  local models = vim.json.decode(response.body)['data']
  local out = {}
  for _, model in ipairs(models) do
    if model['capabilities']['type'] == 'chat' then
      out[model['id']] = model
    end
  end

  log.info('Models fetched')
  self.models = out
  return out
end

function Copilot:enable_claude()
  if self.claude_enabled then
    return true
  end

  local business_check = 'cannot enable policy inline for business users'
  local business_msg =
    'Claude is probably enabled (for business users needs to be enabled manually).'

  local response = curl_post('https://api.githubcopilot.com/models/claude-3.5-sonnet/policy', {
    timeout = timeout,
    headers = self:authenticate(),
    proxy = self.proxy,
    insecure = self.allow_insecure,
    body = temp_file('{"state": "enabled"}'),
  })

  -- Handle business user case
  if response.status ~= 200 and string.find(tostring(response.body), business_check) then
    self.claude_enabled = true
    log.info(business_msg)
    return true
  end

  -- Handle errors
  if response.status ~= 200 then
    error('Failed to enable Claude: ' .. tostring(response.status))
  end

  self.claude_enabled = true
  log.info('Claude enabled')
  return true
end

--- Ask a question to Copilot
---@param prompt string: The prompt to send to Copilot
---@param opts CopilotChat.copilot.ask.opts: Options for the request
function Copilot:ask(prompt, opts)
  opts = opts or {}
  local embeddings = opts.embeddings or {}
  local filename = opts.filename or ''
  local filetype = opts.filetype or ''
  local selection = opts.selection or ''
  local start_row = opts.start_row or 0
  local end_row = opts.end_row or 0
  local system_prompt = opts.system_prompt or prompts.COPILOT_INSTRUCTIONS
  local model = opts.model or 'gpt-4o-2024-05-13'
  local temperature = opts.temperature or 0.1
  local on_progress = opts.on_progress
  local job_id = uuid()
  self.current_job = job_id

  log.trace('System prompt: ' .. system_prompt)
  log.trace('Selection: ' .. selection)
  log.debug('Prompt: ' .. prompt)
  log.debug('Embeddings: ' .. #embeddings)
  log.debug('Filename: ' .. filename)
  log.debug('Filetype: ' .. filetype)
  log.debug('Model: ' .. model)
  log.debug('Temperature: ' .. temperature)

  local models = self:fetch_models()
  local capabilities = models[model] and models[model].capabilities
    or { limits = { max_prompt_tokens = 8192 }, tokenizer = 'cl100k_base' }
  local max_tokens = capabilities.limits.max_prompt_tokens -- FIXME: Is max_prompt_tokens the right limit?
  local tokenizer = capabilities.tokenizer
  log.debug('Max tokens: ' .. max_tokens)
  log.debug('Tokenizer: ' .. tokenizer)
  tiktoken_load(tokenizer)

  local selection_message =
    generate_selection_message(filename, filetype, start_row, end_row, selection)
  local embeddings_message = generate_embeddings_message(embeddings)

  -- Count required tokens that we cannot reduce
  local prompt_tokens = tiktoken.count(prompt)
  local system_tokens = tiktoken.count(system_prompt)
  local selection_tokens = tiktoken.count(selection_message)
  local required_tokens = prompt_tokens + system_tokens + selection_tokens

  -- Reserve space for first embedding if its smaller than half of max tokens
  local reserved_tokens = 0
  if #embeddings_message.files > 0 then
    local file_tokens = tiktoken.count(embeddings_message.files[1])
    if file_tokens < max_tokens / 2 then
      reserved_tokens = tiktoken.count(embeddings_message.header) + file_tokens
    end
  end

  -- Calculate how many tokens we can use for history
  local history_limit = max_tokens - required_tokens - reserved_tokens
  local history_tokens = count_history_tokens(self.history)

  -- If we're over history limit, truncate history from the beginning
  while history_tokens > history_limit and #self.history > 0 do
    local removed = table.remove(self.history, 1)
    history_tokens = history_tokens - tiktoken.count(removed.content)
  end

  -- Now add as many files as possible with remaining token budget
  local remaining_tokens = max_tokens - required_tokens - history_tokens
  if #embeddings_message.files > 0 then
    remaining_tokens = remaining_tokens - tiktoken.count(embeddings_message.header)
    local filtered_files = {}
    for _, file in ipairs(embeddings_message.files) do
      local file_tokens = tiktoken.count(file)
      if remaining_tokens - file_tokens >= 0 then
        remaining_tokens = remaining_tokens - file_tokens
        table.insert(filtered_files, file)
      else
        break
      end
    end
    embeddings_message.files = filtered_files
  end

  local last_message = nil
  local errored = false
  local full_response = ''

  local function handle_error(err)
    errored = true
    full_response = err
  end

  local function stream_func(err, line)
    if not line or errored then
      return
    end

    if self.current_job ~= job_id then
      return
    end

    if err or vim.startswith(line, '{"error"') then
      handle_error('Failed to get response: ' .. (err and vim.inspect(err) or line))
      return
    end

    line = line:gsub('^%s*data: ', '')
    if line == '' or line == '[DONE]' then
      return
    end

    local ok, content = pcall(vim.json.decode, line, {
      luanil = {
        object = true,
        array = true,
      },
    })

    if not ok then
      handle_error('Failed to parse response: ' .. vim.inspect(content) .. '\n' .. line)
      return
    end

    if not content.choices or #content.choices == 0 then
      return
    end

    last_message = content
    local choice = content.choices[1]
    local is_full = choice.message ~= nil
    content = is_full and choice.message.content or choice.delta.content

    if not content then
      return
    end

    if on_progress then
      on_progress(content)
    end

    full_response = full_response .. content
  end

  local body = vim.json.encode(
    generate_ask_request(
      self.history,
      prompt,
      embeddings_message,
      selection_message,
      system_prompt,
      model,
      temperature,
      not vim.startswith(model, 'o1')
    )
  )

  if vim.startswith(model, 'claude') then
    self:enable_claude()
  end

  local response = curl_post('https://api.githubcopilot.com/chat/completions', {
    timeout = timeout,
    headers = self:authenticate(),
    body = temp_file(body),
    proxy = self.proxy,
    insecure = self.allow_insecure,
    stream = stream_func,
  })

  if self.current_job ~= job_id then
    return nil, nil, nil
  end

  self.current_job = nil

  if not response then
    error('Failed to get response')
    return
  end

  if response.status ~= 200 then
    error('Failed to get response: ' .. tostring(response.status) .. '\n' .. response.body)
    return
  end

  if errored then
    error(full_response)
    return
  end

  if full_response == '' then
    error('Failed to get response: empty response')
    return
  end

  log.trace('Full response: ' .. full_response)
  log.debug('Last message: ' .. vim.inspect(last_message))

  table.insert(self.history, {
    content = prompt,
    role = 'user',
  })

  table.insert(self.history, {
    content = full_response,
    role = 'assistant',
  })

  return full_response,
    last_message and last_message.usage and last_message.usage.total_tokens,
    max_tokens
end

--- List available models
function Copilot:list_models()
  local models = self:fetch_models()

  -- Group models by version and shortest ID
  local version_map = {}
  for id, model in pairs(models) do
    local version = model.version
    if not version_map[version] or #id < #version_map[version] then
      version_map[version] = id
    end
  end

  -- Map to IDs and sort
  local result = vim.tbl_values(version_map)
  table.sort(result)

  return result
end

--- Generate embeddings for the given inputs
---@param inputs table<CopilotChat.copilot.embed>: The inputs to embed
---@param opts CopilotChat.copilot.embed.opts: Options for the request
function Copilot:embed(inputs, opts)
  opts = opts or {}
  local model = opts.model or 'copilot-text-embedding-ada-002'
  local chunk_size = opts.chunk_size or 15

  if not inputs or #inputs == 0 then
    return {}
  end

  local chunks = {}
  for i = 1, #inputs, chunk_size do
    table.insert(chunks, vim.list_slice(inputs, i, i + chunk_size - 1))
  end

  local out = {}

  for _, chunk in ipairs(chunks) do
    local response = curl_post('https://api.githubcopilot.com/embeddings', {
      timeout = timeout,
      headers = self:authenticate(),
      body = temp_file(vim.json.encode(generate_embedding_request(chunk, model))),
      proxy = self.proxy,
      insecure = self.allow_insecure,
    })

    if not response then
      error('Failed to get response')
      return
    end

    if response.status ~= 200 then
      error('Failed to get response: ' .. tostring(response.status) .. '\n' .. response.body)
      return
    end

    local ok, content = pcall(vim.json.decode, response.body, {
      luanil = {
        object = true,
        array = true,
      },
    })

    if not ok then
      error('Failed to parse response: ' .. vim.inspect(content) .. '\n' .. response.body)
      return
    end

    for _, embedding in ipairs(content.data) do
      table.insert(out, vim.tbl_extend('keep', chunk[embedding.index + 1], embedding))
    end
  end

  return out
end

--- Stop the running job
function Copilot:stop()
  if self.current_job ~= nil then
    self.current_job = nil
    return true
  end

  return false
end

--- Reset the history and stop any running job
function Copilot:reset()
  local stopped = self:stop()
  self.history = {}
  return stopped
end

--- Save the history to a file
---@param name string: The name to save the history to
---@param path string: The path to save the history to
function Copilot:save(name, path)
  local history = vim.json.encode(self.history)
  path = vim.fn.expand(path)
  vim.fn.mkdir(path, 'p')
  path = path .. '/' .. name .. '.json'
  local file = io.open(path, 'w')
  if not file then
    log.error('Failed to save history to ' .. path)
    return
  end

  file:write(history)
  file:close()
  log.info('Saved Copilot history to ' .. path)
end

--- Load the history from a file
---@param name string: The name to load the history from
---@param path string: The path to load the history from
---@return table
function Copilot:load(name, path)
  path = vim.fn.expand(path) .. '/' .. name .. '.json'
  local file = io.open(path, 'r')
  if not file then
    return {}
  end

  local history = file:read('*a')
  file:close()
  self.history = vim.json.decode(history, {
    luanil = {
      object = true,
      array = true,
    },
  })

  log.info('Loaded Copilot history from ' .. path)
  return self.history
end

--- Check if there is a running job
---@return boolean
function Copilot:running()
  return self.current_job ~= nil
end

return Copilot
