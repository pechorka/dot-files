-- lsp.lua - Language Server Protocol configuration

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
local M = {}

function M.setup()
    setup_go_lsp()
    setup_lua_lsp()
end


return M
