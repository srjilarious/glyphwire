-- task_journal: a todo list and a dated journal in Markdown files, after
-- vim-wiki. A port of the Task Journal VS Code extension; both read and
-- write the same files, so one journal can be kept from either editor.
--
-- Turn it on in zoe.conf.lua, every option shown at its default:
--
--   config = {
--       extensions = {
--           task_journal = {
--               data_directory  = "~/.task-journal",
--               -- $date (yyyy/mm/dd), $yyyy, $mm, $dd
--               entry_template  = "# $date\n",
--               -- `$` is where the progress state goes.
--               task_pattern    = "- [$] ",
--               progress_states = { " ", "◔", "◑", "◕", "✓" },
--               -- `$` is where the tag list goes, right after the task.
--               tag_pattern     = "($) ",
--               tag_separator   = ", ",
--               -- Up to ten; taskTag0 .. taskTag9 toggle them.
--               tags            = {},
--               -- The VS Code extension's chords (ctrl+meta+alt there).
--               default_keys    = true,
--               -- Carry unfinished work into a new entry or backlog.
--               carry_forward   = true,
--               -- "move" takes it out of the old file, "copy" leaves it.
--               carry_mode      = "move",
--               -- The line that opens and closes the tracking section.
--               tracking_marker = "#-------",
--               -- $yyyy, $mm
--               backlog_template = "# Backlog $yyyy/$mm\n",
--           },
--       },
--   }
--
-- Commands (Ctrl+Shift+P lists them; `keys` can bind them):
--   journalToday, journalTomorrow  open (creating) that day's entry
--   journalPrevious, journalNext   step through the entries, wrapping;
--                                  from outside the journal, the latest
--   journalBacklog                 open (creating) this month's backlog,
--                                  <data_directory>/backlog/YYYY-MM.md
--   taskIncrease, taskDecrease     step the cursor line's progress state,
--                                  making it a task first if it isn't one
--   taskToggle                     done <-> not started
--   taskTag0 .. taskTag9           toggle tags[1] .. tags[10] on the line
--
-- Carrying forward: a new entry for today or later starts with what the
-- latest earlier entry left open, and a new month's backlog with what the
-- latest earlier backlog left open. That is the tracking section (from
-- one `tracking_marker` line to the next, whatever is in it) and every
-- top-level task not in the last progress state, with the more indented
-- lines under it. "move" rewrites the old file without them, so it
-- refuses while that file has unsaved edits in zoe.
--
-- docs/zoe-extensions.md describes the `zoe` API this is written against.

local opts = ... or {}

local function opt(key, default, kind)
    local v = opts[key]
    if v == nil then return default end
    if type(v) ~= kind then
        error(("task_journal.%s must be a %s"):format(key, kind), 0)
    end
    return v
end

local data_directory = opt("data_directory", "~/.task-journal", "string")
local entry_template = opt("entry_template", "# $date\n", "string")
local task_pattern = opt("task_pattern", "- [$] ", "string")
local states = opt("progress_states", { " ", "◔", "◑", "◕", "✓" }, "table")
local tag_pattern = opt("tag_pattern", "($) ", "string")
local tag_separator = opt("tag_separator", ", ", "string")
local tags = opt("tags", {}, "table")
local default_keys = opt("default_keys", true, "boolean")
local carry_forward = opt("carry_forward", true, "boolean")
local carry_mode = opt("carry_mode", "move", "string")
local tracking_marker = opt("tracking_marker", "#-------", "string")
local backlog_template = opt("backlog_template", "# Backlog $yyyy/$mm\n", "string")

if carry_mode ~= "move" and carry_mode ~= "copy" then
    error('task_journal.carry_mode must be "move" or "copy"', 0)
end
if tracking_marker:match("^%s*$") then error("task_journal.tracking_marker is empty", 0) end

if #states == 0 then error("task_journal.progress_states is empty", 0) end

-- A pattern is split at its `$`: what comes before the state (or tag
-- list) and what comes after.
local function split_pattern(p, key)
    local at = p:find("$", 1, true)
    if not at then error(("task_journal.%s has no `$`"):format(key), 0) end
    return p:sub(1, at - 1), p:sub(at + 1)
end

local task_start, task_end = split_pattern(task_pattern, "task_pattern")
local tag_start, tag_end = split_pattern(tag_pattern, "tag_pattern")

local function starts_with(s, prefix, at)
    at = at or 1
    return s:sub(at, at + #prefix - 1) == prefix
end

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- `s` with every `from` replaced by `to`, matched as plain text.
local function replace_all(s, from, to)
    local out, at = {}, 1
    while true do
        local i, j = s:find(from, at, true)
        if not i then break end
        out[#out + 1] = s:sub(at, i - 1)
        out[#out + 1] = to
        at = j + 1
    end
    out[#out + 1] = s:sub(at)
    return table.concat(out)
end

local function split_plain(s, sep)
    local out, at = {}, 1
    while true do
        local i, j = s:find(sep, at, true)
        if not i then break end
        out[#out + 1] = s:sub(at, i - 1)
        at = j + 1
    end
    out[#out + 1] = s:sub(at)
    return out
end

---- Tasks -------------------------------------------------------------

-- A line read as a task: its indent, its state's index into `states`
-- (0 when the state is none of them) and the text after the pattern.
-- `valid` is false when the line isn't a task, with `text` the line
-- after its indent.
local function parse_task(line)
    local indent = line:match("^%s*")
    local rest = line:sub(#indent + 1)
    if starts_with(rest, task_start) then
        local after = rest:sub(#task_start + 1)
        local i, j = after:find(task_end, 1, true)
        if i then
            local current = 0
            for n, s in ipairs(states) do
                if starts_with(after, s) then
                    current = n
                    break
                end
            end
            return { valid = true, indent = indent, current = current, text = after:sub(j + 1) }
        end
    end
    return { valid = false, indent = indent, text = rest }
end

-- Rewrites the cursor line with the state `step(current)` picks, or as
-- a fresh task in the first state when it isn't one.
local function restate(step)
    local t = parse_task(zoe.line())
    local next_state = t.valid and step(t.current) or 1
    zoe.set_line(t.indent .. task_start .. states[next_state] .. task_end .. t.text)
end

zoe.command("taskIncrease", function()
    restate(function(cur) return cur % #states + 1 end)
end, "Task Journal: Increase Task Progress")

zoe.command("taskDecrease", function()
    restate(function(cur)
        if cur <= 1 then return #states end
        return cur - 1
    end)
end, "Task Journal: Decrease Task Progress")

zoe.command("taskToggle", function()
    restate(function(cur)
        if cur == #states then return 1 end
        return #states
    end)
end, "Task Journal: Toggle Task")

---- Tags --------------------------------------------------------------

-- `line` with `tag` toggled in its tag list, or nil when the line starts
-- a task or a tag list it never finishes. A line that isn't a task
-- becomes one.
local function toggle_tag(line, tag)
    local indent = line:match("^%s*")
    local rest = line:sub(#indent + 1)
    if not starts_with(rest, task_start) then
        return indent .. task_start .. states[1] .. task_end .. tag_start .. tag .. tag_end .. rest
    end

    local i, j = rest:find(task_end, #task_start + 1, true)
    if not i then return nil end
    local task = rest:sub(1, j)
    local after = j + 1
    if not starts_with(rest, tag_start, after) then
        return indent .. task .. tag_start .. tag .. tag_end .. rest:sub(after)
    end

    local k, l = rest:find(tag_end, after, true)
    if not k then return nil end
    local text = rest:sub(l + 1)
    local list = {}
    for _, t in ipairs(split_plain(rest:sub(after + #tag_start, k - 1), tag_separator)) do
        list[#list + 1] = trim(t)
    end

    local kept, had = {}, false
    for _, t in ipairs(list) do
        if t == tag then had = true else kept[#kept + 1] = t end
    end
    if not had then kept[#kept + 1] = tag end
    if #kept == 0 then return indent .. task .. text end
    return indent .. task .. tag_start .. table.concat(kept, tag_separator) .. tag_end .. text
end

for n = 1, math.min(#tags, 10) do
    local tag = tags[n]
    if type(tag) ~= "string" or tag == "" then
        error(("task_journal.tags[%d] must be a non-empty string"):format(n), 0)
    end
    zoe.command("taskTag" .. (n - 1), function()
        local line = toggle_tag(zoe.line(), tag)
        if line then zoe.set_line(line) end
    end, "Task Journal: Toggle Tag " .. tag)
end

---- Journal -----------------------------------------------------------

-- The entries' directory, `~` expanded and without a trailing `/`.
local function journal_dir()
    local dir = zoe.expand(data_directory):gsub("(.)/+$", "%1")
    return dir
end

local function header(t)
    local d = os.date("*t", t)
    local dd, mm, yyyy = ("%02d"):format(d.day), ("%02d"):format(d.month), tostring(d.year)
    local s = replace_all(entry_template, "$dd", dd)
    s = replace_all(s, "$mm", mm)
    s = replace_all(s, "$yyyy", yyyy)
    return replace_all(s, "$date", yyyy .. "/" .. mm .. "/" .. dd)
end

---- Carrying forward ---------------------------------------------------

local function read_lines(path)
    local f, err = io.open(path, "r")
    if not f then error(err, 0) end
    local text = f:read("a")
    f:close()
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    -- A file ending in a newline leaves one empty piece after it.
    if lines[#lines] == "" then lines[#lines] = nil end
    return lines
end

local function write_file(path, text)
    local f, err = io.open(path, "w")
    if not f then error(err, 0) end
    f:write(text)
    f:close()
end

local function is_marker(line)
    return trim(line) == trim(tracking_marker)
end

-- What `lines` leaves open: the tracking section's lines (markers
-- included) and the unfinished top-level tasks' lines, each with the more
-- indented lines under it. `taken[n]` is true for every line either one
-- holds. A tracking section without its closing marker isn't one.
local function open_items(lines)
    local tracking, tasks, taken = {}, {}, {}
    local n = 1
    while n <= #lines do
        local line = lines[n]
        if #tracking == 0 and is_marker(line) then
            local close
            for m = n + 1, #lines do
                if is_marker(lines[m]) then
                    close = m
                    break
                end
            end
            if close then
                for m = n, close do
                    tracking[#tracking + 1] = lines[m]
                    taken[m] = true
                end
                n = close + 1
                goto continue
            end
        end
        do
            local t = parse_task(line)
            if t.valid and t.indent == "" and t.current ~= #states then
                tasks[#tasks + 1] = line
                taken[n] = true
                while n + 1 <= #lines and lines[n + 1]:match("^%s+%S") do
                    n = n + 1
                    tasks[#tasks + 1] = lines[n]
                    taken[n] = true
                end
            end
        end
        n = n + 1
        ::continue::
    end
    return tracking, tasks, taken
end

-- The newest file in `dir` whose name matches `pattern` and sorts before
-- `name`, as a full path, or nil.
local function latest_before(dir, pattern, name)
    local found
    for _, f in ipairs(zoe.list_dir(dir) or {}) do
        if f:match(pattern) and f < name then found = f end
    end
    return found and (dir .. "/" .. found)
end

-- `head` followed by what `source` leaves open: tracking section first,
-- then the tasks. In "move" mode `source` is rewritten without them.
local function carried(head, source)
    if not carry_forward or not source then return head end
    if carry_mode == "move" and zoe.modified(source) then
        error(("%s has unsaved changes; save it first"):format(source:match("[^/]+$")), 0)
    end
    local lines = read_lines(source)
    local tracking, tasks, taken = open_items(lines)
    if #tracking == 0 and #tasks == 0 then return head end

    if carry_mode == "move" then
        local kept = {}
        for n, line in ipairs(lines) do
            if not taken[n] then kept[#kept + 1] = line end
        end
        write_file(source, #kept > 0 and table.concat(kept, "\n") .. "\n" or "")
    end

    local parts = {}
    if #tracking > 0 then parts[#parts + 1] = table.concat(tracking, "\n") end
    if #tasks > 0 then parts[#parts + 1] = table.concat(tasks, "\n") end
    if head ~= "" and head:sub(-1) ~= "\n" then head = head .. "\n" end
    return head .. "\n" .. table.concat(parts, "\n\n") .. "\n"
end

local function ensure_dir(dir)
    local ok, err = zoe.mkdir(dir)
    if not ok then error(("can't create %s (%s)"):format(dir, err), 0) end
end

-- Opens the entry for the day `t` falls on, writing it first when it is
-- new. One for today or later starts with what the entry before it left
-- open; a past day's never takes from an older one.
local function open_entry(t)
    local dir = journal_dir()
    ensure_dir(dir)
    local name = os.date("%Y-%m-%d", t) .. ".md"
    local path = dir .. "/" .. name
    if not zoe.exists(path) then
        local source
        if name >= os.date("%Y-%m-%d") .. ".md" then
            source = latest_before(dir, "^%d%d%d%d%-%d%d%-%d%d%.md$", name)
        end
        write_file(path, carried(header(t), source))
    end
    zoe.open(path)
end

zoe.command("journalToday", function()
    open_entry(os.time())
end, "Task Journal: Journal Entry for Today")

zoe.command("journalTomorrow", function()
    -- Noon, so a daylight-saving change can't land it on the same day
    -- or skip one.
    local d = os.date("*t")
    open_entry(os.time({ year = d.year, month = d.month, day = d.day + 1, hour = 12 }))
end, "Task Journal: Journal Entry for Tomorrow")

-- The `.md` files in the journal, in name (so date) order.
local function entries(dir)
    local out = {}
    for _, name in ipairs(zoe.list_dir(dir) or {}) do
        if name:sub(-3) == ".md" then out[#out + 1] = name end
    end
    return out
end

local function step_entry(delta)
    local dir = journal_dir()
    local files = entries(dir)
    if #files == 0 then
        zoe.message("No journal entries in " .. dir)
        return
    end
    local path = zoe.path()
    local at
    if path and path:sub(1, #dir + 1) == dir .. "/" then
        local name = path:sub(#dir + 2)
        for n, f in ipairs(files) do
            if f == name then at = n end
        end
    end
    -- From outside the journal there is nothing to step from: the latest
    -- entry is where you'd want to land.
    local target = at and ((at - 1 + delta) % #files + 1) or #files
    zoe.open(dir .. "/" .. files[target])
end

local function backlog_header(t)
    local d = os.date("*t", t)
    local s = replace_all(backlog_template, "$mm", ("%02d"):format(d.month))
    return replace_all(s, "$yyyy", tostring(d.year))
end

zoe.command("journalBacklog", function()
    local dir = journal_dir() .. "/backlog"
    ensure_dir(dir)
    local name = os.date("%Y-%m") .. ".md"
    local path = dir .. "/" .. name
    if not zoe.exists(path) then
        local source = latest_before(dir, "^%d%d%d%d%-%d%d%.md$", name)
        write_file(path, carried(backlog_header(os.time()), source))
    end
    zoe.open(path)
end, "Task Journal: Backlog for This Month")

zoe.command("journalPrevious", function() step_entry(-1) end, "Task Journal: Previous Journal Entry")
zoe.command("journalNext", function() step_entry(1) end, "Task Journal: Next Journal Entry")

if default_keys then
    zoe.bind("global", "ctrl+alt+super+t", "journalToday")
    zoe.bind("global", "ctrl+alt+super+m", "journalTomorrow")
    zoe.bind("global", "ctrl+alt+super+p", "journalPrevious")
    zoe.bind("global", "ctrl+alt+super+n", "journalNext")
    zoe.bind("global", "ctrl+alt+super+b", "journalBacklog")
    zoe.bind("global", "ctrl+alt+super+[", "taskDecrease")
    zoe.bind("global", "ctrl+alt+super+]", "taskIncrease")
    zoe.bind("global", "ctrl+alt+super+\\", "taskToggle")
end
