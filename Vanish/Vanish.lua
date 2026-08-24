--[[
Copyright © 2026 Broguypal

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
]]

_addon.name = 'Vanish'
_addon.author = 'Broguypal'
_addon.version = '2.1.2'
_addon.commands = {'vanish', 'van'}

require('logger')
require('strings')

local config = require('config')
local files = require('files')

local addon_path = windower.addon_path:gsub('\\', '/')
if addon_path:sub(-1) ~= '/' then addon_path = addon_path .. '/' end

package.cpath = package.cpath .. ';' .. addon_path .. 'libs/?.dll'

local loaded, load_error = pcall(require, '_Vanish')

local DEFAULTS = {
    mode      = 'vanish',
    blacklist = '',
    whitelist = '',
    keybind   = '',
}

local SETTINGS_DIR = 'Settings/'
local DEFAULTS_PATH = SETTINGS_DIR .. 'Defaults.xml'
local LEGACY_PATH = 'data/settings.xml'

local MODE_ID = {vanish = 1, vanishga = 2}
local CYCLE = {vanish = 'vanishga', vanishga = 'vanish'}
local REFRESH_INTERVAL = 0.25

local blacklist = {}
local whitelist = {}
local mode = 'vanish'
local keybind = ''
local settings = nil
local settings_file = nil
local last_refresh = 0

local started = false
local start_failed = false

local function available()
    return loaded and _Vanish ~= nil
end

local function attached()
    return settings ~= nil
end

local function ensure_started()
    if started then return true end
    if start_failed then return false end
    if not available() then return false end

    local info = windower.ffxi.get_info()
    if not (info and info.logged_in) then return false end

    local status = _Vanish.start()

    if type(status) == 'string' and not status:match('^loaded') then
        start_failed = true
        error('The native module did not start: ' .. status)
        error('Reload the addon once the game is running: //lua r vanish')
        return false
    end

    started = true
    return true
end

local function titlecase(name)
    return (name:gsub('^%l', string.upper))
end

local function parse_list(raw)
    if type(raw) == 'table' then raw = table.concat(raw, ',') end
    if type(raw) ~= 'string' then raw = '' end

    local set = {}
    for entry in raw:gmatch('[^,]+') do
        local key = entry:trim():lower()
        if key ~= '' then set[key] = true end
    end

    return set
end

local function sorted(set)
    local list = {}
    for name in pairs(set) do list[#list + 1] = name end
    table.sort(list)
    return list
end

local function list_for(which)
    if which == 'blacklist' then return blacklist, 'blacklist', 'vanish' end
    if which == 'whitelist' then return whitelist, 'whitelist', 'vanishga' end
    if mode == 'vanish' then return blacklist, 'blacklist', 'vanish' end
    return whitelist, 'whitelist', 'vanishga'
end

local function tidy_settings_file()
    if not settings_file or not settings_file:exists() then return end

    local content = settings_file:read()
    if type(content) ~= 'string' then return end

    local lines = {}
    local width = 0

    for line in (content .. '\n'):gmatch('(.-)\n') do
        line = line:gsub('<(%a[%w_]*)%s*/>', '<%1></%1>'):gsub('%s+$', '')
        lines[#lines + 1] = line

        local element = line:match('^%s*(<[^!].-)%s+<!%-%-')
        if element and #element > width then
            width = #element
        end
    end

    for index, line in ipairs(lines) do
        local indent, element, comment = line:match('^(%s*)(<[^!].-)%s+(<!%-%-.*)$')
        if element then
            lines[index] = indent .. element
                .. (' '):rep(width - #element + 1) .. comment
        end
    end

    local tidied = table.concat(lines, '\n')
    if tidied ~= content then
        settings_file:write(tidied)
    end
end

local function persist()
    if not attached() then return end

    settings.mode = mode
    settings.blacklist = table.concat(sorted(blacklist), ',')
    settings.whitelist = table.concat(sorted(whitelist), ',')
    settings.keybind = keybind

    config.save(settings, 'all')
    tidy_settings_file()
end

-- Native module -------------------------------------------------------------

local function push_policy()
    if not available() then return end

    local set = mode == 'vanish' and blacklist or whitelist
    _Vanish.names(table.concat(sorted(set), ','))
    _Vanish.mode(MODE_ID[mode])
end

local function push_exempt()
    if not available() then return end

    local indices = {}
    local self_index = 0

    local me = windower.ffxi.get_player()
    if me and me.index then
        self_index = me.index
        indices[#indices + 1] = tostring(me.index)
    end

    local party = windower.ffxi.get_party()
    if party then
        for key, member in pairs(party) do
            if type(member) == 'table' and type(key) == 'string'
               and (key:match('^p%d$') or key:match('^a%d%d$')) then
                local index = member.mob and member.mob.index
                if index and index > 0 then
                    indices[#indices + 1] = tostring(index)
                end
            end
        end
    end

    _Vanish.exempt(table.concat(indices, ','), self_index)
end

-- Character sessions --------------------------------------------------------

local function describe_mode()
    if mode == 'vanish' then
        return 'Vanish mode: the blacklist is hidden.'
    end

    return 'Vanishga mode: only the whitelist, your party and your alliance are drawn.'
end

local function bind_key()
    if keybind ~= '' then
        windower.send_command('bind ' .. keybind .. ' vanish cycle')
    end
end

local function unbind_key()
    if keybind ~= '' then
        windower.send_command('unbind ' .. keybind)
    end
end

local function apply(source)
    blacklist = parse_list(source.blacklist)
    whitelist = parse_list(source.whitelist)

    mode = tostring(source.mode or 'vanish'):lower()
    if not MODE_ID[mode] then mode = 'vanish' end

    keybind = type(source.keybind) == 'string' and source.keybind:trim() or ''
end

local DEFAULT_SETTINGS = table.concat({
    '<?xml version="1.1" ?>',
    '<settings>',
    '    <!--',
    '        Vanish settings.',
    '',
    '        Settings/Defaults.xml is the starting point for new characters. The',
    '        first time a character logs in it is copied to',
    '        Settings/<Name>_settings.xml, and that copy is what the character uses',
    '        from then on.',
    '        keybind is the key that cycles Vanish and Vanishga. Leave it empty',
    '        for no keybind at all.',
    '',
    '        Keybind Notes:',
    '',
    '        Modifiers:  ^ Ctrl   ! Alt   ~ Shift',
    '',
    '        Keys: a to z, 0 to 9, f1 to f12, numpad0 to numpad9, numpad+,',
    '        numpad-, numpad*, numpad/, numpad., numpadenter, space, tab, enter,',
    '        backspace, escape, insert, delete, home, end, pageup, pagedown,',
    '        up, down, left, right',
    '',
    '        Examples:  !space is Alt + Spacebar.  ^v is Ctrl + V.',
    '        ~f12 is Shift + F12.  f9 is F9 on its own.',
    '        ^!numpad0 is Ctrl + Alt + Numpad 0.',
    '    -->',
    '    <global>',
    '        <blacklist></blacklist> <!-- Hidden in Vanish mode. Comma separated: alice,bob -->',
    '        <keybind></keybind>     <!-- Cycles the modes. See the notes above. -->',
    '        <mode>vanish</mode>     <!-- vanish or vanishga -->',
    '        <whitelist></whitelist> <!-- Drawn in Vanishga mode, with your party and alliance. -->',
    '    </global>',
    '</settings>',
}, '\n') .. '\n'

local function ensure_defaults()
    local template = files.new(DEFAULTS_PATH)

    if template:exists() then
        local content = template:read()
        if type(content) == 'string' and content:trim() ~= '' then
            return content
        end
    end

    template:create()
    template:write(DEFAULT_SETTINGS)

    return DEFAULT_SETTINGS
end

local function attach(name)
    if not ensure_started() then return end
    if not available() or name == nil or name == '' then return end

    local path = SETTINGS_DIR .. name:gsub('[^%w]', '') .. '_settings.xml'
    settings_file = files.new(path)

    local defaults = ensure_defaults()
    local created = not settings_file:exists()
    local imported = nil

    if created then
        settings_file:create()
        settings_file:write(defaults)

        if files.new(LEGACY_PATH):exists() then
            imported = config.load(LEGACY_PATH, DEFAULTS)
        end
    end

    settings = config.load(path, DEFAULTS)

    apply(imported or settings)

    push_policy()
    push_exempt()
    bind_key()

    if created then
        persist()

        if imported then
            log('Imported the shared settings from Vanish 2.0. ' .. name
                .. ' now uses ' .. path)
        end
    end

    log(name .. ': ' .. describe_mode())
end

local function detach()
    unbind_key()

    settings = nil
    settings_file = nil
    keybind = ''
    blacklist = {}
    whitelist = {}
    mode = 'vanish'

    push_policy()
end

-- Commands ------------------------------------------------------------------

local function set_mode(next_mode)
    mode = next_mode
    push_policy()
    push_exempt()
    persist()
    log(describe_mode())
end

local function add_name(which, name)
    if name == '' then
        error('Usage: //vanish add <name>')
        return
    end

    local set, label, owner = list_for(which)
    local key = name:lower()
    local me = windower.ffxi.get_player()

    if me and me.name and me.name:lower() == key then
        error('Refusing to blacklist yourself.')
        return
    end

    if set[key] then
        log(titlecase(name) .. ' is already on the ' .. label .. '.')
        return
    end

    set[key] = true
    push_policy()
    persist()

    if mode == owner then
        log('Added ' .. titlecase(name) .. ' to the ' .. label
            .. (owner == 'vanish' and '. Hidden now.' or '. Visible now.'))
    else
        log('Added ' .. titlecase(name) .. ' to the ' .. label
            .. '. Takes effect in ' .. owner .. ' mode.')
    end
end

local function remove_name(which, name)
    if name == '' then
        error('Usage: //vanish remove <name>')
        return
    end

    local set, label = list_for(which)
    local key = name:lower()

    if not set[key] then
        log(titlecase(name) .. ' is not on the ' .. label .. '.')
        return
    end

    set[key] = nil
    push_policy()
    persist()
    log('Removed ' .. titlecase(name) .. ' from the ' .. label .. '.')
end

local function show_lists()
    log(describe_mode())

    local black = sorted(blacklist)
    local white = sorted(whitelist)

    log('Blacklist (' .. #black .. ')' .. (mode == 'vanish' and ' <- active' or '') .. ':')
    if #black == 0 then
        log('  empty')
    else
        for _, name in ipairs(black) do log('  ' .. titlecase(name)) end
    end

    log('Whitelist (' .. #white .. ')' .. (mode == 'vanishga' and ' <- active' or '') .. ':')
    if #white == 0 then
        log('  empty')
    else
        for _, name in ipairs(white) do log('  ' .. titlecase(name)) end
    end
end

local function initialise()
    if not available() then
        log('The native module failed to load: ' .. tostring(load_error))
        log('Check that libs/_Vanish.dll sits beside Vanish.lua.')
        return
    end

    log('Vanish v' .. _addon.version .. ' loaded.')

    local me = windower.ffxi.get_player()
    if me and me.name then
        attach(me.name)
    end
end

windower.register_event('unload', function()
    unbind_key()

    if available() and started then
        _Vanish.stop()
    end
end)

windower.register_event('login', function(name)
    if available() and not attached() then
        attach(name)
    end
end)

windower.register_event('logout', function()
    if attached() then
        detach()
    end
end)

windower.register_event('prerender', function()
    if not available() then return end

    local now = os.clock()
    if now - last_refresh < REFRESH_INTERVAL then return end
    last_refresh = now

    if not attached() then
        local me = windower.ffxi.get_player()
        if me and me.name then attach(me.name) end
        return
    end

    push_exempt()
end)

windower.register_event('zone change', function()
    if available() and attached() then
        push_exempt()
    end
end)

windower.register_event('addon command', function(cmd, ...)
    if not available() then
        error('The native module is not loaded: ' .. tostring(load_error))
        return
    end

    if not attached() then
        error('Log in first. Vanish keeps its settings per character.')
        return
    end

    cmd = (cmd or 'list'):lower()
    local args = {...}
    local rest = table.concat(args, ' '):trim()

    if MODE_ID[cmd] then
        set_mode(cmd)

    elseif cmd == 'cycle' then
        set_mode(CYCLE[mode])

    elseif cmd == 'add' then
        add_name(nil, rest)

    elseif cmd == 'remove' then
        remove_name(nil, rest)

    elseif cmd == 'blacklist' or cmd == 'whitelist' then
        local action = (args[1] or ''):lower()
        local name = table.concat(args, ' ', 2):trim()

        if action == 'add' then
            add_name(cmd, name)
        elseif action == 'remove' then
            remove_name(cmd, name)
        else
            error('Usage: //vanish ' .. cmd .. ' add|remove <name>')
        end

    elseif cmd == 'clear' then
        local set, label = list_for(nil)
        for key in pairs(set) do set[key] = nil end
        push_policy()
        persist()
        log('Cleared the ' .. label .. '.')

    elseif cmd == 'list' then
        show_lists()

    else
        log('//vanish vanish | vanishga | cycle')
        log('//vanish add <name> | remove <name>')
        log('//vanish blacklist add|remove <name>')
        log('//vanish whitelist add|remove <name>')
        log('//vanish list | clear')
    end
end)

initialise()
