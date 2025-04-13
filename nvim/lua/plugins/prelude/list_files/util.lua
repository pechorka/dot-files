-- util.lua - Utility functions for the display plugin

local M = {}

-- Check if a file exists and is readable
function M.file_exists(file_path)
    local file = io.open(file_path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

-- Read all lines from a file
function M.read_file_lines(file_path)
    local lines = {}
    local file = io.open(file_path, "r")
    
    if not file then
        return lines
    end
    
    for line in file:lines() do
        table.insert(lines, line)
    end
    file:close()
    
    return lines
end

-- Center cursor on line in window
function M.center_cursor(win_id)
    local current_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(win_id)
    vim.cmd("normal! zz")
    vim.api.nvim_set_current_win(current_win)
end

-- Apply basic highlighting to a buffer based on file extension
function M.apply_syntax_highlighting(buf_id, file_path)
    local filetype = vim.filetype.match({ filename = file_path })
    if filetype then
        vim.api.nvim_buf_set_option(buf_id, "filetype", filetype)
        return true
    end
    return false
end

-- Case-insensitive string search
function M.contains(str, pattern)
    return string.find(string.lower(str), string.lower(pattern)) ~= nil
end

-- Helper to safely check if a window ID exists and is valid
function M.is_valid_win(win_id)
    return win_id and vim.api.nvim_win_is_valid(win_id)
end

-- Helper to safely check if a buffer ID exists and is valid
function M.is_valid_buf(buf_id)
    return buf_id and vim.api.nvim_buf_is_valid(buf_id)
end

-- Calculate window dimensions based on a percentage of the screen size
function M.calculate_dimensions(width_percent, height_percent)
    local ui = vim.api.nvim_list_uis()[1]
    
    local width = math.floor(ui.width * width_percent)
    local height = math.floor(ui.height * height_percent)
    local row = math.floor((ui.height - height) / 2)
    local col = math.floor((ui.width - width) / 2)
    
    return {
        width = width,
        height = height,
        row = row,
        col = col
    }
end

return M 