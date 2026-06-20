local obs = obslua

-- User-configurable settings
local capture_source_name = ""
local fullscreen_scene = ""
local normal_scene = ""
local poll_interval = 200        -- milliseconds
local bounds_mode = "scale_outer" -- stretch | scale_inner | scale_outer

-- Internal state
local is_fullscreen_active = false
local last_window_id = nil

----------------------------------------------------------------------
-- Helper: run a shell command and capture trimmed stdout
----------------------------------------------------------------------
local function run_command(cmd)
    local handle = io.popen(cmd)
    if not handle then return nil end
    local result = handle:read("*a")
    handle:close()
    if result then
        result = result:gsub("^%s+", ""):gsub("%s+$", "")
    end
    return result
end

----------------------------------------------------------------------
-- Detect the currently active window and whether it's fullscreen
-- Returns: is_fullscreen (bool), window_id (string), window_name (string)
----------------------------------------------------------------------
local function get_active_fullscreen_window()
    local win_id = run_command("xdotool getactivewindow 2>/dev/null")
    if not win_id or win_id == "" then
        return false, nil, nil
    end

    local props = run_command("xprop -id " .. win_id .. " 2>/dev/null")
    if not props or props == "" then
        return false, win_id, nil
    end

    -- Ignore desktop / dock / panel windows
    if props:find("_NET_WM_WINDOW_TYPE_DESKTOP") or
       props:find("_NET_WM_WINDOW_TYPE_DOCK") then
        return false, win_id, nil
    end

    local win_name = run_command(
        "xdotool getwindowname " .. win_id .. " 2>/dev/null")

    -- Method 1: the proper fullscreen state atom
    if props:find("_NET_WM_STATE_FULLSCREEN") then
        return true, win_id, win_name
    end

    -- Method 2: geometry fallback (window covers whole screen)
    local geo = run_command(
        "xdotool getwindowgeometry --shell " .. win_id .. " 2>/dev/null")
    if geo then
        local w = tonumber(geo:match("WIDTH=(%d+)"))
        local h = tonumber(geo:match("HEIGHT=(%d+)"))
        local screen = run_command("xdotool getdisplaygeometry 2>/dev/null")
        if screen and w and h then
            local sw = tonumber(screen:match("^(%d+)"))
            local sh = tonumber(screen:match("(%d+)$"))
            if sw and sh and w >= sw and h >= sh then
                return true, win_id, win_name
            end
        end
    end

    return false, win_id, win_name
end

----------------------------------------------------------------------
-- Switch the OBS program scene by name
----------------------------------------------------------------------
local function switch_to_scene(scene_name)
    if not scene_name or scene_name == "" then return end

    local scenes = obs.obs_frontend_get_scenes()
    if scenes ~= nil then
        for _, scene_source in ipairs(scenes) do
            if obs.obs_source_get_name(scene_source) == scene_name then
                obs.obs_frontend_set_current_scene(scene_source)
                break
            end
        end
        obs.source_list_release(scenes)
    end
end

----------------------------------------------------------------------
-- Translate the chosen bounds_mode string into an OBS bounds enum
----------------------------------------------------------------------
local function get_bounds_type()
    if bounds_mode == "stretch" then
        return obs.OBS_BOUNDS_STRETCH
    elseif bounds_mode == "scale_inner" then
        return obs.OBS_BOUNDS_SCALE_INNER
    else
        return obs.OBS_BOUNDS_SCALE_OUTER
    end
end

----------------------------------------------------------------------
-- Force the scene item's bounds so the source fills the canvas
-- regardless of the captured window's aspect ratio.
----------------------------------------------------------------------
local function fit_source_in_scene(scene_name, source_name)
    if not scene_name or scene_name == "" then return end
    if not source_name or source_name == "" then return end

    local scenes = obs.obs_frontend_get_scenes()
    if scenes == nil then return end

    for _, scene_source in ipairs(scenes) do
        if obs.obs_source_get_name(scene_source) == scene_name then
            local scene = obs.obs_scene_from_source(scene_source)
            local item = obs.obs_scene_find_source(scene, source_name)
            if item ~= nil then
                local video_info = obs.obs_video_info()
                obs.obs_get_video_info(video_info)
                local cw = video_info.base_width
                local ch = video_info.base_height

                -- Reset scale/rotation/crop so bounds behave predictably
                obs.obs_sceneitem_set_rot(item, 0.0)

                local crop = obs.obs_sceneitem_crop()
                crop.left = 0; crop.top = 0; crop.right = 0; crop.bottom = 0
                obs.obs_sceneitem_set_crop(item, crop)

                -- Position the bounding box at the top-left of the canvas
                local pos = obs.vec2()
                pos.x = 0
                pos.y = 0
                obs.obs_sceneitem_set_pos(item, pos)

                -- Bounding box = full canvas size
                local bounds = obs.vec2()
                bounds.x = cw
                bounds.y = ch
                obs.obs_sceneitem_set_bounds_type(item, get_bounds_type())
                obs.obs_sceneitem_set_bounds(item, bounds)

                -- Center the content inside the bounding box
                obs.obs_sceneitem_set_bounds_alignment(item, 0) -- OBS_ALIGN_CENTER
                obs.obs_sceneitem_set_alignment(item, 5)        -- TOP|LEFT for pos anchor
            end
            break
        end
    end

    obs.source_list_release(scenes)
end

----------------------------------------------------------------------
-- Update the capture source to grab the given window
----------------------------------------------------------------------
local function update_capture_source(win_id, win_name)
    if not capture_source_name or capture_source_name == "" then return end
    if not win_id or win_id == "" then return end

    local source = obs.obs_get_source_by_name(capture_source_name)
    if source == nil then return end

    local source_id = obs.obs_source_get_id(source)
    local settings = obs.obs_source_get_settings(source)

    if source_id == "xcomposite_input" then
        local win_dec = tonumber(win_id)
        if win_dec then
            local capture_str = tostring(win_dec)
            if win_name and win_name ~= "" then
                capture_str = capture_str .. "\r\n\r\n" .. win_name
            end
            obs.obs_data_set_string(settings, "capture_window", capture_str)
            obs.obs_source_update(source, settings)
        end
    elseif source_id == "xshm_input" or
           source_id == "pipewire-screen-capture-source" then
        obs.obs_source_update(source, settings)
    end

    obs.obs_data_release(settings)
    obs.obs_source_release(source)
end

----------------------------------------------------------------------
-- Main polling callback
----------------------------------------------------------------------
local function check_fullscreen()
    local fs, win_id, win_name = get_active_fullscreen_window()

    if fs then
        if not is_fullscreen_active or win_id ~= last_window_id then
            update_capture_source(win_id, win_name)
            switch_to_scene(fullscreen_scene)
            fit_source_in_scene(fullscreen_scene, capture_source_name)
            is_fullscreen_active = true
            last_window_id = win_id
        end
    else
        if is_fullscreen_active then
            switch_to_scene(normal_scene)
            is_fullscreen_active = false
            last_window_id = nil
        end
    end
end

----------------------------------------------------------------------
-- Populate dropdown lists
----------------------------------------------------------------------
local function populate_source_list(prop)
    obs.obs_property_list_clear(prop)
    obs.obs_property_list_add_string(prop, "", "")

    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        for _, source in ipairs(sources) do
            local sid = obs.obs_source_get_id(source)
            if sid == "xcomposite_input" or
               sid == "xshm_input" or
               sid == "pipewire-screen-capture-source" then
                local name = obs.obs_source_get_name(source)
                obs.obs_property_list_add_string(prop, name, name)
            end
        end
        obs.source_list_release(sources)
    end
end

local function populate_scene_list(prop)
    obs.obs_property_list_clear(prop)
    obs.obs_property_list_add_string(prop, "", "")

    local scenes = obs.obs_frontend_get_scenes()
    if scenes ~= nil then
        for _, scene_source in ipairs(scenes) do
            local name = obs.obs_source_get_name(scene_source)
            obs.obs_property_list_add_string(prop, name, name)
        end
        obs.source_list_release(scenes)
    end
end

----------------------------------------------------------------------
-- OBS script interface
----------------------------------------------------------------------
function script_description()
    return [[
<div style='color: green; text-align: center; font-weight: bold'>Fullscreen Window Auto-Switcher<br/>v 1.0</div>
Detects when a fullscreen window is opened, updates a capture source to
grab it, forces the source to fill the canvas (no black bars), and
switches scenes. Returns to a chosen scene when the fullscreen window is
closed or minimized.<br/><br/>
<i>Requires <code>xdotool</code> and <code>xprop</code> (X11 only).</i>
<div style='color:yellow;'>Created by Claude, prompted by Yair Mohr</div>]]
end

function script_properties()
    local props = obs.obs_properties_create()

    local src = obs.obs_properties_add_list(
        props, "capture_source", "OBS source name",
        obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
    populate_source_list(src)

    local fs_scene = obs.obs_properties_add_list(
        props, "fullscreen_scene", "Scene when fullscreen opens",
        obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
    populate_scene_list(fs_scene)

    local nm_scene = obs.obs_properties_add_list(
        props, "normal_scene", "Scene when fullscreen closes",
        obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
    populate_scene_list(nm_scene)

    -- Bounds behaviour selector
    local bm = obs.obs_properties_add_list(
        props, "bounds_mode", "Source fit mode",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(bm, "Fit outside (no bars, might crop)", "scale_outer")
    obs.obs_property_list_add_string(bm, "Stretch (no bars, distorts ratio)", "stretch")
    obs.obs_property_list_add_string(bm, "Fit inside (keeps bars)", "scale_inner")

    -- Poll interval: slider 50..2000 step 10, with manual entry allowed
    obs.obs_properties_add_int(
        props, "poll_interval", "Poll interval (ms)", 50, 5000, 10)

    obs.obs_properties_add_button(props, "refresh_btn", "Refresh lists",
        function() return true end)

    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_int(settings, "poll_interval", 200)
    obs.obs_data_set_default_string(settings, "bounds_mode", "scale_outer")
end

function script_update(settings)
    capture_source_name = obs.obs_data_get_string(settings, "capture_source")
    fullscreen_scene    = obs.obs_data_get_string(settings, "fullscreen_scene")
    normal_scene        = obs.obs_data_get_string(settings, "normal_scene")
    poll_interval       = obs.obs_data_get_int(settings, "poll_interval")
    bounds_mode         = obs.obs_data_get_string(settings, "bounds_mode")

    if poll_interval < 50 then poll_interval = 50 end
    if bounds_mode == "" then bounds_mode = "scale_outer" end

    obs.timer_remove(check_fullscreen)
    obs.timer_add(check_fullscreen, poll_interval)
end

function script_load(settings)
    obs.timer_add(check_fullscreen, poll_interval)
end

function script_unload()
    obs.timer_remove(check_fullscreen)
end
