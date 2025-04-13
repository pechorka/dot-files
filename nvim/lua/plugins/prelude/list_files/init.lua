-- display.lua - A modular file display plugin for Neovim
-- This plugin provides a two-pane interface for displaying and previewing a list of files
-- It's designed to be used as a building block for other plugins

local util = require('plugins.prelude.list_files.util')

local M = {}

-- Configuration with default values
local config = {
    height = 0.8, -- 80% of the screen height
    width = 1.0,  -- 80% of the screen width
    list_width = 0.4, -- 30% of the window width for the list pane
    border = "rounded",
}

-- State variables
local state = {
    files = {},         -- List of file paths to display
    filtered_files = {}, -- List of files filtered by search term
    current_index = 1,   -- Currently selected file index (in filtered_files)
    search_term = "",   -- Current search term
    buffers = {          -- Buffer ids for the panes
        list = nil,
        preview = nil,
        description = nil, -- Buffer for the description pane
    },
    windows = {          -- Window ids for the panes
        main = nil,
        list = nil,
        preview = nil,
        description = nil,
    },
    root_dir = nil,     -- Root directory for relative paths
}

-- Forward declarations
local create_ui, update_list, update_preview, setup_keymaps, close_display, filter_files

-- Main function to open the display window with a list of files
function M.open(files, root_dir)
    -- Validate input
    if not files or #files == 0 then
        vim.notify("No files provided to display", vim.log.levels.ERROR)
        return
    end
    
    -- Initialize state
    state.files = files
    state.current_index = 1
    state.root_dir = root_dir or vim.fn.getcwd()
    state.search_term = "" -- Initialize search term
    
    -- Create UI elements
    create_ui()
    
    -- Initial filter and display
    filter_files()
    update_list()
    update_preview()
    
    -- Set up keymaps
    setup_keymaps()
end

-- Function to create the UI windows and buffers
function create_ui()
    -- Calculate dimensions based on config
    local dimensions = util.calculate_dimensions(config.width, config.height)
    local width = dimensions.width
    local height = dimensions.height
    local row = dimensions.row
    local col = dimensions.col
    
    -- Create main floating window
    local main_buf = vim.api.nvim_create_buf(false, true)
    state.windows.main = vim.api.nvim_open_win(main_buf, true, {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = config.border,
    })
    
    -- Set window options
    vim.api.nvim_win_set_option(state.windows.main, "winhl", "Normal:Normal")
    
    -- Calculate dimensions for the list and preview panes
    local list_width = math.floor(width * config.list_width)
    local preview_width = width - list_width - 2  -- -2 for the separator
    
    -- Create list buffer and window
    state.buffers.list = vim.api.nvim_create_buf(false, true)
    state.windows.list = vim.api.nvim_open_win(state.buffers.list, true, {
        relative = "win",
        win = state.windows.main,
        row = 1,
        col = 0,
        width = list_width,
        height = height - 2,
        style = "minimal",
    })
    
    -- Set list window options
    vim.api.nvim_win_set_option(state.windows.list, "winhl", "Normal:Normal")
    vim.api.nvim_win_set_option(state.windows.list, "number", false)
    vim.api.nvim_win_set_option(state.windows.list, "relativenumber", false)
    vim.api.nvim_win_set_option(state.windows.list, "cursorline", true)
    
    -- Create vertical separator
    vim.api.nvim_win_set_option(state.windows.list, "signcolumn", "no")
    
    -- Create preview buffer and window
    state.buffers.preview = vim.api.nvim_create_buf(false, true)
    state.windows.preview = vim.api.nvim_open_win(state.buffers.preview, false, {
        relative = "win",
        win = state.windows.main,
        row = 1,
        col = list_width + 1,  -- +1 for the separator
        width = preview_width,
        height = height - 2,
        style = "minimal",
    })
    
    -- Set preview window options
    vim.api.nvim_win_set_option(state.windows.preview, "winhl", "Normal:Normal")
    vim.api.nvim_win_set_option(state.windows.preview, "number", true)
    vim.api.nvim_win_set_option(state.windows.preview, "relativenumber", false)
    vim.api.nvim_win_set_option(state.windows.preview, "wrap", false)
    vim.api.nvim_win_set_option(state.windows.preview, "cursorline", true)
    
    -- Create description buffer (will be shown only when needed)
    state.buffers.description = vim.api.nvim_create_buf(false, true)
    
    -- Focus on the list window
    vim.api.nvim_set_current_win(state.windows.list)
end

-- Function to update the list view with filtered files
function update_list()
    local lines = {}
    local list_buf = state.buffers.list

    -- Clear previous highlighting (optional, but good practice)
    vim.api.nvim_buf_clear_namespace(list_buf, -1, 0, -1)

    -- Add filtered files to the list
    if #state.filtered_files == 0 then
        table.insert(lines, "  No matching files")
        vim.api.nvim_win_set_cursor(state.windows.list, {1, 0}) -- Set cursor to first line
    else
        -- Ensure current_index is valid
        if state.current_index > #state.filtered_files then
            state.current_index = #state.filtered_files
        elseif state.current_index < 1 then
            state.current_index = 1
        end

        for i, file in ipairs(state.filtered_files) do
            -- Highlight the current selection
            if i == state.current_index then
                table.insert(lines, "> " .. file.path)
            else
                table.insert(lines, "  " .. file.path)
            end
        end
    end

    -- Update the buffer content
    vim.api.nvim_buf_set_option(list_buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(list_buf, 'modifiable', false)

    -- Update the cursor position only if there are files
    if #state.filtered_files > 0 then
        vim.api.nvim_win_set_cursor(state.windows.list, {state.current_index, 0})
    end

    -- Update window title with search term (optional)
    local title = "Files"
    if state.search_term ~= "" then
        title = title .. " [Search: " .. state.search_term .. "]"
    end
    vim.api.nvim_win_set_config(state.windows.main, { title = title })
end

-- Function to filter files based on search term
function filter_files()
    state.filtered_files = {}
    if state.search_term == "" then
        state.filtered_files = state.files -- Show all if search is empty
    else
        local pattern = state.search_term:lower() -- Case-insensitive search
        for _, file in ipairs(state.files) do
            if file.path:lower():find(pattern, 1, true) then -- Simple substring matching
                table.insert(state.filtered_files, file)
            end
        end
    end
    -- Reset index when filter changes, only if results exist
    if #state.filtered_files > 0 then
       state.current_index = 1
    else
       state.current_index = 0 -- Or 1, depending on desired behavior for empty list
    end
end

-- Function to update the preview pane with the content of the selected file
function update_preview()
    -- Get the currently selected file from the filtered list
    if #state.filtered_files == 0 or state.current_index == 0 then
        vim.api.nvim_buf_set_option(state.buffers.preview, 'modifiable', true)
        vim.api.nvim_buf_set_lines(state.buffers.preview, 0, -1, false, {"No file selected or no matching files"})
        vim.api.nvim_buf_set_option(state.buffers.preview, 'modifiable', false)
        -- Hide description window if it exists
        if util.is_valid_win(state.windows.description) then
            vim.api.nvim_win_close(state.windows.description, true)
            state.windows.description = nil
        end
        return
    end
    
    local file = state.filtered_files[state.current_index]
    local path, line_num = file.path, file.line
    
    -- Handle description window
    if file.description and #file.description > 0 then
        -- If we have a description, show the description window
        local desc_lines = type(file.description) == "table" and file.description or {file.description}
        
        -- Calculate dimensions for the description window
        local dimensions = util.calculate_dimensions(config.width, config.height)
        local width = dimensions.width
        local row = dimensions.row
        local col = dimensions.col
        local desc_height = math.min(#desc_lines + 1, 5)  -- Limit height to 5 lines max
        
        -- Set description buffer content
        vim.api.nvim_buf_set_lines(state.buffers.description, 0, -1, false, desc_lines)
        
        -- Create or update description window
        if not util.is_valid_win(state.windows.description) then
            state.windows.description = vim.api.nvim_open_win(state.buffers.description, false, {
                relative = "editor",
                row = row - desc_height - 1,  -- Position above main window
                col = col,
                width = width,
                height = desc_height,
                style = "minimal",
                border = config.border,
            })
            
            -- Set window options
            vim.api.nvim_win_set_option(state.windows.description, "winhl", "Normal:Normal")
            vim.api.nvim_win_set_option(state.windows.description, "wrap", true)
        else
            -- Update existing window
            vim.api.nvim_win_set_config(state.windows.description, {
                relative = "editor",
                row = row - desc_height - 1,
                col = col,
                width = width,
                height = desc_height,
            })
        end
    else
        -- No description for this file, hide the description window if it exists
        if util.is_valid_win(state.windows.description) then
            vim.api.nvim_win_close(state.windows.description, true)
            state.windows.description = nil
        end
    end
    
    -- Resolve relative path against root directory
    if not vim.fn.filereadable(path) == 1 and state.root_dir then
        path = state.root_dir .. '/' .. path
    end
    
    -- Check if file exists and is readable
    if not util.file_exists(path) then
        vim.api.nvim_buf_set_option(state.buffers.preview, 'modifiable', true)
        vim.api.nvim_buf_set_lines(state.buffers.preview, 0, -1, false, {"File not found: " .. path})
        vim.api.nvim_buf_set_option(state.buffers.preview, 'modifiable', false)
        return
    end
    
    -- Read file content
    local content = util.read_file_lines(path)
    
    -- Set file content to preview buffer
    vim.api.nvim_buf_set_option(state.buffers.preview, 'modifiable', true)
    vim.api.nvim_buf_set_lines(state.buffers.preview, 0, -1, false, content)
    vim.api.nvim_buf_set_option(state.buffers.preview, 'modifiable', false)
    
    -- Set filetype for syntax highlighting
    util.apply_syntax_highlighting(state.buffers.preview, path)
    
    -- Scroll to line number if present
    if line_num and line_num > 0 and line_num <= #content then
        vim.api.nvim_win_set_cursor(state.windows.preview, {line_num, 0})
        -- Center the view on the line
        util.center_cursor(state.windows.preview)
    end
end

-- Function to open the currently selected file
local function open_selected_file()
    if #state.filtered_files > 0 and state.current_index > 0 then
        local file = state.filtered_files[state.current_index]
        local path = file.path
        local line_num = file.line

        -- Resolve relative path
        if not vim.loop.fs_stat(path) and state.root_dir then
            path = state.root_dir .. '/' .. path
        end

        close_display() -- Close the display first

        -- Open the file in the previous window
        -- vim.cmd('edit ' .. vim.fn.fnameescape(path))
        -- Edit in current window or find a better way to return to original window/split
        local current_win = vim.api.nvim_get_current_win()
        local target_win = vim.fn.win_getid(vim.fn.winnr('#')) -- Get ID of the previous window
        if target_win > 0 and vim.api.nvim_win_is_valid(target_win) then
            vim.api.nvim_set_current_win(target_win)
        else
            -- Fallback if previous window is not valid (e.g., was the only window)
             target_win = current_win -- Use the window Neovim switches to after closing the floa
        end
        vim.api.nvim_command('edit ' .. vim.fn.fnameescape(path))

        -- Go to line number if specified
        if line_num and line_num > 0 then
            vim.api.nvim_win_set_cursor(0, {tonumber(line_num), 0})
            vim.cmd('normal! zz') -- Center the line
        end
    end
end

-- Function to set up keymaps for the list window
function setup_keymaps()
    local list_buf = state.buffers.list
    local opts = { noremap = true, silent = true, buffer = list_buf }

    -- Navigation
    vim.keymap.set('n', '<Down>', function()
        if #state.filtered_files > 0 and state.current_index < #state.filtered_files then
            state.current_index = state.current_index + 1
            update_list()
            update_preview()
        end
    end, opts)

    vim.keymap.set('n', '<Up>', function()
        if state.current_index > 1 then
            state.current_index = state.current_index - 1
            update_list()
            update_preview()
        end
    end, opts)

    -- Selection
    vim.keymap.set('n', '<CR>', open_selected_file, opts)

    -- Close
    vim.keymap.set('n', 'q', close_display, opts)
    vim.keymap.set('n', '<Esc>', close_display, opts)

    -- Search input handling
    vim.keymap.set('n', '<BS>', function()
        state.search_term = state.search_term:sub(1, -2) -- Remove last character
        filter_files()
        update_list()
        update_preview()
    end, opts)

    -- Handle printable characters for search
    for i = 32, 126 do -- ASCII printable characters
        local char = string.char(i)
        vim.keymap.set('n', char, function()
            state.search_term = state.search_term .. char
            filter_files()
            update_list()
            update_preview()
        end, opts)
    end
end

-- Function to close the display windows and clean up
function close_display()
    -- Clean up buffers and windows
    if util.is_valid_win(state.windows.main) then
        vim.api.nvim_win_close(state.windows.main, true)
    end
    
    if util.is_valid_win(state.windows.description) then
        vim.api.nvim_win_close(state.windows.description, true)
    end
    
    if util.is_valid_buf(state.buffers.list) then
        vim.api.nvim_buf_delete(state.buffers.list, {force = true})
    end
    
    if util.is_valid_buf(state.buffers.preview) then
        vim.api.nvim_buf_delete(state.buffers.preview, {force = true})
    end
    
    if util.is_valid_buf(state.buffers.description) then
        vim.api.nvim_buf_delete(state.buffers.description, {force = true})
    end
    
    -- Reset state
    state = {
        files = {},
        filtered_files = {},
        current_index = 1,
        search_term = "",
        buffers = {
            list = nil,
            preview = nil,
            description = nil,
        },
        windows = {
            main = nil,
            list = nil,
            preview = nil,
            description = nil,
        },
        root_dir = nil,
    }
end

-- Function to configure the plugin with user settings
function M.setup(user_config)
    config = vim.tbl_deep_extend("force", config, user_config or {})
    return M
end

return M 