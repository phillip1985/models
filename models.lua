-- -*- coding: utf-8 -*-
local obs = obslua

local model_max_count = 5
local default_model_count = 2
-- OBS stores colors as 0xAAEEDDCC (Alpha-Blue-Green-Red).
local default_background_color = 0xffeaf0
-- OBS keeps the current form values in this pending settings object.
-- It is intentionally separate from writing models.json.
local pending_settings = nil

local function get_images_from_folder()
    local images = {}
    local folder_path = script_path() .. "images"
    local command = package.config:sub(1, 1) == "\\" and
        'dir "' .. folder_path .. '" /b' or
        'ls "' .. folder_path .. '"'
    local process = io.popen(command)

    if not process then
        return images
    end

    for file in process:lines() do
        local lower_file = string.lower(file)
        if lower_file:match("%.png$") or lower_file:match("%.jpg$") or
           lower_file:match("%.jpeg$") or lower_file:match("%.webp$") or
           lower_file:match("%.gif$") then
            table.insert(images, file)
        end
    end
    process:close()
    return images
end

local function text_to_json_array(value)
    if not value or value == "" then
        return "[]"
    end

    local lines = {}
    for line in string.gmatch(value, "[^\r\n]+") do
        line = string.gsub(line, "^%s+", "")
        line = string.gsub(line, "%s+$", "")
        if line ~= "" then
            line = string.gsub(line, "\\", "\\\\")
            line = string.gsub(line, '"', '\\"')
            table.insert(lines, '"' .. line .. '"')
        end
    end
    return "[" .. table.concat(lines, ", ") .. "]"
end

-- Keep the original models.json output format unchanged.
local function save_scoreboard_data(settings)
    local file = io.open(script_path() .. "models.json", "wb")
    if not file then
        return
    end

    local model_count = obs.obs_data_get_int(settings, "model_count")
    if model_count < 2 then model_count = 2 end
    local on_stage_title = obs.obs_data_get_string(settings, "on_stage_title")
    local current_stage_model = obs.obs_data_get_int(settings, "current_model_on_stage")

    local models_json = {}

    for i = 1, model_count do
        local setting_name = "model_background_" .. i
        local m_background = nil

        local saved_str = obs.obs_data_get_string(settings, setting_name)
        if saved_str and string.sub(saved_str, 1, 1) == "#" then
            local clean_hex = string.gsub(saved_str, "#", "")
            local hex_num = tonumber(clean_hex, 16)
            if hex_num then
                local r = bit.band(bit.rshift(hex_num, 16), 0xFF)
                local g = bit.band(bit.rshift(hex_num, 8), 0xFF)
                local b = bit.band(hex_num, 0xFF)
                m_background = r + bit.lshift(g, 8) + bit.lshift(b, 16)
                obs.obs_data_set_int(settings, setting_name, m_background)
            end
        end

        if not m_background then
            m_background = obs.obs_data_get_int(settings, setting_name)
        end
        if m_background == 0 or m_background == nil then
            m_background = default_background_color
            obs.obs_data_set_int(settings, setting_name, default_background_color)
        end

        local r = bit.band(m_background, 0xFF)
        local g = bit.band(bit.rshift(m_background, 8), 0xFF)
        local b = bit.band(bit.rshift(m_background, 16), 0xFF)
        local hex_color = string.format("#%02x%02x%02x", r, g, b)

        local m_name = obs.obs_data_get_string(settings, "model_name_" .. i) or ""
        m_name = string.gsub(m_name, "\\", "\\\\")
        m_name = string.gsub(m_name, '"', '\\"')
        local m_active = obs.obs_data_get_bool(settings, "model_active_" .. i)
        local m_text_array = text_to_json_array(obs.obs_data_get_string(settings, "model_text_" .. i))

        local raw_image_name = obs.obs_data_get_string(settings, "model_image_" .. i) or ""
        local local_image_link = raw_image_name == "" and "" or "./images/" .. raw_image_name
        local m_image = string.gsub(local_image_link, "\\", "\\\\")
        m_image = string.gsub(m_image, '"', '\\"')

        table.insert(models_json, string.format([[    {
      "bg_glow": "#%02x%02x%02x",
      "name": "%s",
      "active": %s,
      "text": %s,
      "image_path": "%s"
    }]],
            r, g, b, m_name, tostring(m_active), m_text_array, m_image))
    end

    local json = string.format([[
{
  "current_model_on_stage": %d,
  "model_count": %d,
  "on_stage_title": "%s",
  "models": [
%s
  ]
}]],
        current_stage_model, model_count, (function(t)
            t = string.gsub(t, "\\", "\\\\")
            t = string.gsub(t, '"', '\\"')
            return t
        end)(on_stage_title), table.concat(models_json, ",\n"))

    file:write("\239\187\191", json)
    file:close()
end

function script_description()
    return "Dynamic models controller for OBS. Press Update to write models.json."
end

function script_defaults(settings)
    obs.obs_data_set_default_int(settings, "model_count", default_model_count)
    obs.obs_data_set_default_string(settings, "on_stage_title", "On Stage")
    obs.obs_data_set_default_int(settings, "current_model_on_stage", -1)

    for i = 1, model_max_count do
        obs.obs_data_set_default_string(settings, "model_name_" .. i, "Model " .. i)
        obs.obs_data_set_default_bool(settings, "model_active_" .. i, true)
        obs.obs_data_set_default_string(settings, "model_text_" .. i, "")
        obs.obs_data_set_default_int(settings, "model_background_" .. i, default_background_color)
        obs.obs_data_set_default_string(settings, "model_image_" .. i, "")
    end
end

-- OBS calls this whenever a form value changes.  Keep the pending values in
-- memory, but do not write the output file here.
function script_update(settings)
    pending_settings = settings
end

local function update_stage_dropdown_options(props, settings)
    local stage_property = obs.obs_properties_get(props, "current_model_on_stage")
    if not stage_property then
        return
    end

    obs.obs_property_list_clear(stage_property)
    local stage_title = obs.obs_data_get_string(settings, "on_stage_title")
    if stage_title == "" then
        stage_title = "On Stage"
    end
    obs.obs_property_list_add_int(stage_property, "None (" .. stage_title .. ")", -1)

    local model_count = math.max(2, obs.obs_data_get_int(settings, "model_count"))
    for i = 1, model_count do
        if obs.obs_data_get_bool(settings, "model_active_" .. i) then
            local name = obs.obs_data_get_string(settings, "model_name_" .. i)
            obs.obs_property_list_add_int(stage_property, name ~= "" and name or "Model " .. i, i - 1)
        end
    end
end

local function update_visibility(props, settings)
    local model_count = math.max(2, obs.obs_data_get_int(settings, "model_count"))
    for i = 1, model_max_count do
        local visible = i <= model_count
        for _, prefix in ipairs({ "model_background_", "model_name_", "model_image_", "model_active_", "model_text_" }) do
            local property = obs.obs_properties_get(props, prefix .. i)
            if property then
                obs.obs_property_set_visible(property, visible)
            end
        end
    end
    update_stage_dropdown_options(props, settings)
end

local function model_count_changed(props, property, settings)
    -- Only the structural selector refreshes the panel so newly selected model slots appear.
    update_visibility(props, settings)
    return true
end

local function save_button_clicked(props, property, settings)
    -- The button is the only place that writes the pending form object to disk.
    save_scoreboard_data(settings or pending_settings)
    return false
end

function script_properties(settings)
    pending_settings = settings
    local props = obs.obs_properties_create()

    obs.obs_properties_add_text(props, "on_stage_title", "On Stage Title", obs.OBS_TEXT_DEFAULT)

    local count_property = obs.obs_properties_add_list(
        props, "model_count", "Number of Models", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)
    for i = 2, model_max_count do
        obs.obs_property_list_add_int(count_property, i .. " Models", i)
    end
    obs.obs_property_set_modified_callback(count_property, model_count_changed)

    obs.obs_properties_add_list(
        props, "current_model_on_stage", "Current Model On Stage", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_INT)

    local avatar_files = get_images_from_folder()
    for i = 1, model_max_count do
        obs.obs_properties_add_color(props, "model_background_" .. i, "Model " .. i .. " Background Color")

        -- Text properties intentionally have no modification callback, so typing is uninterrupted.
        obs.obs_properties_add_text(props, "model_name_" .. i, "Model " .. i .. " Name", obs.OBS_TEXT_DEFAULT)

        local image_property = obs.obs_properties_add_list(
            props, "model_image_" .. i, "Model " .. i .. " Avatar",
            obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
        obs.obs_property_list_add_string(image_property, "None selected", "")
        for _, filename in ipairs(avatar_files) do
            obs.obs_property_list_add_string(image_property, filename, filename)
        end

        obs.obs_properties_add_bool(props, "model_active_" .. i, "Model " .. i .. " Active")

        -- No modification callback: typing never rebuilds the properties UI.
        obs.obs_properties_add_text(props, "model_text_" .. i, "Model " .. i .. " Message", obs.OBS_TEXT_MULTILINE)
    end

    obs.obs_properties_add_button(props, "update_models", "Update", save_button_clicked)
    update_visibility(props, settings)
    return props
end
