-- lsp.lua - Language Server Protocol configuration

local display = require('plugins.prelude.list_files.init')

local function get_root_dir(root_files)
    local buf_path = vim.api.nvim_buf_get_name(0)
    local buf_dir = vim.fn.fnamemodify(buf_path, ':h')
    local found = vim.fs.find(root_files, { path = buf_dir, upward = true })[1]
    return found and vim.fs.dirname(found) or vim.fn.getcwd()
end

local function setup_go_lsp()
    local capabilities = vim.lsp.protocol.make_client_capabilities()
    capabilities.textDocument.completion.completionItem.snippetSupport = false
    vim.api.nvim_create_autocmd('FileType', {
        pattern = 'go',
        callback = function()
            -- Find project root starting from the buffer's directory
            local root_dir = get_root_dir({ 'go.mod', '.git' })

            -- Start LSP client with correct root_dir
            local client = vim.lsp.start({
                name = 'gopls',
                cmd = { 'gopls' },
                root_dir = root_dir,
                capabilities = capabilities,
            })
        end,
    })
end

local function setup_lua_lsp()
    vim.api.nvim_create_autocmd('FileType', {
        pattern = 'lua',
        callback = function()
            local root_dir = get_root_dir({'.git', 'stylua.toml'})
            local client = vim.lsp.start({
                name = 'lua_ls',
                cmd = { 'lua-language-server' },
                root_dir = root_dir,
                settings = {
                    Lua = {
                        runtime = { version = 'LuaJIT' },
                        workspace = { library = vim.api.nvim_get_runtime_file("", true) },
                        diagnostics = { globals = { 'vim' } },
                        telemetry = { enable = false },
                    },
                },
            })
        end,
    })
end

-- Convert LSP locations to file list format for display
local function locations_to_file_list(locations)
    if not locations or vim.tbl_isempty(locations) then
        return nil
    end

    local cwd = vim.fn.getcwd()

    local files = {}
    for _, location in ipairs(locations) do
        local uri = location.uri or location.targetUri
        local range = location.range or location.targetSelectionRange
        if uri and range then
            local path = vim.uri_to_fname(uri)
            local relative_path = path:sub(#cwd + 2)
            local line = range.start.line + 1
            table.insert(files, { path = relative_path, line = line })
        end
    end

    return files
end

local M = {}

function M.setup()
    setup_go_lsp()
    setup_lua_lsp()
end

-- Go to definition
function M.definition()
    local params = vim.lsp.util.make_position_params(0, "utf-8")
    
    vim.lsp.buf_request(0, 'textDocument/definition', params, function(err, result, ctx, config)
        if err then
            vim.notify("LSP Error: " .. vim.inspect(err), vim.log.levels.ERROR)
            return
        end

        if not result or vim.tbl_isempty(result) then
            vim.notify("No definition found", vim.log.levels.WARN)
            return
        end
        
        -- If only one result, go directly to it
        if #result == 1 then
            vim.lsp.util.jump_to_location(result[1], "utf-8")
            return
        end
        
        -- Convert locations to file list
        local files = locations_to_file_list(result)
        if files and #files > 0 then
            display.open(files, vim.fn.getcwd())
        else
            -- Fallback if processing failed
            vim.lsp.buf.definition()
        end
    end)
end

-- Find references
function M.references()
    local params = vim.lsp.util.make_position_params(0, "utf-8")
    params.context = { includeDeclaration = true }
    
    vim.lsp.buf_request(0, 'textDocument/references', params, function(err, result, ctx, config)
        if err then
            vim.notify("LSP Error: " .. vim.inspect(err), vim.log.levels.ERROR)
            return
        end

        if not result or vim.tbl_isempty(result) then
            vim.notify("No references found", vim.log.levels.WARN)
            return
        end
        
        -- Convert locations to file list
        local files = locations_to_file_list(result)
        if files and #files > 0 then
            display.open(files, vim.fn.getcwd())
        end
    end)
end

-- Go to implementation
function M.implementation()
    local params = vim.lsp.util.make_position_params(0, "utf-8")
    
    vim.lsp.buf_request(0, 'textDocument/implementation', params, function(err, result, ctx, config)
        if err then
            vim.notify("LSP Error: " .. vim.inspect(err), vim.log.levels.ERROR)
            return
        end

        if not result or vim.tbl_isempty(result) then
            vim.notify("No implementation found", vim.log.levels.WARN)
            return
        end
        
        -- If only one result, go directly to it
        if #result == 1 then
            vim.lsp.util.jump_to_location(result[1], "utf-8")
            return
        end
        
        -- Convert locations to file list
        local files = locations_to_file_list(result)
        if files and #files > 0 then
            display.open(files, vim.fn.getcwd())
        end
    end)
end

function M.diagnostics()
    local diagnostics = vim.diagnostic.get(nil, { severity = nil })
    
    if not diagnostics or vim.tbl_isempty(diagnostics) then
        vim.notify("No diagnostics found", vim.log.levels.INFO)
        return
    end
    
    local files = {}
    local cwd = vim.fn.getcwd()
    
    -- Process and format diagnostics
    for _, diagnostic in ipairs(diagnostics) do
        local bufnr = diagnostic.bufnr
        local filename = vim.api.nvim_buf_get_name(bufnr)
        local relative_path = filename:sub(#cwd + 2)
        local line = diagnostic.lnum + 1
        local severity = diagnostic.severity
        local message = diagnostic.message:gsub("\n", " ")
        
        local severity_name = ({ "ERROR", "WARN", "INFO", "HINT" })[severity] or "UNKNOWN"
        local entry = {
            path = relative_path,
            line = line,
            description = '[' .. severity_name .. '] ' .. message
        }
        
        table.insert(files, entry)
    end
    
    if #files > 0 then
        display.open(files, vim.fn.getcwd())
    end
end

-- Show hover documentation
function M.hover()
    vim.lsp.buf.hover()
end

return M
