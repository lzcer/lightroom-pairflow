local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'

local Adapter = {}

local function describe(photo)
    local path = photo:getRawMetadata('path')
    local format = photo:getRawMetadata('fileFormat')
    if format == 'JPG' then format = 'JPEG' end
    return {
        photo = photo,
        path = path,
        folder = LrPathUtils.parent(path),
        format = format,
        virtual = photo:getRawMetadata('isVirtualCopy'),
        time = photo:getRawMetadata('dateTimeOriginal'),
    }
end

function Adapter.collect(catalog, selected, progress)
    local sources, folders = {}, {}
    local ignored = 0
    for i, photo in ipairs(selected) do
        local item = describe(photo)
        if item.format == 'JPEG' and not item.virtual then
            sources[#sources + 1] = item
            if not folders[item.folder] then
                folders[item.folder] = { photos = {} }
            end
        else
            ignored = ignored + 1
        end
        if i % 50 == 0 then LrTasks.yield() end
        if progress:isCanceled() then return nil, nil, ignored end
    end

    for path, data in pairs(folders) do
        progress:setCaption('读取候选：' .. path)
        local ok, err = LrTasks.pcall(function()
            local folder = catalog:getFolderByPath(path)
            if not folder then error('文件夹不在 Lightroom 目录中') end
            for i, photo in ipairs(folder:getPhotos(false)) do
                local format = photo:getRawMetadata('fileFormat')
                if format == 'RAW' or format == 'DNG' then
                    data.photos[#data.photos + 1] = describe(photo)
                end
                if i % 50 == 0 then LrTasks.yield() end
                if progress:isCanceled() then return end
            end
        end)
        if not ok then data.error = tostring(err) end
        if progress:isCanceled() then return nil, nil, ignored end
        LrTasks.yield()
    end
    return sources, folders, ignored
end

local function readValues(photo, fields)
    local values = {}
    for _, field in ipairs(fields) do
        local value
        if field == 'label' then
            value = photo:getFormattedMetadata('label') or ''
        else
            value = photo:getRawMetadata(field)
        end
        if field == 'rating' then
            value = value or 0
            if type(value) ~= 'number' or value < 0 or value > 5 or value % 1 ~= 0 then
                error('星级值无效：' .. tostring(value))
            end
        elseif field == 'pickStatus' then
            value = value or 0
            if value ~= -1 and value ~= 0 and value ~= 1 then
                error('选取状态无效：' .. tostring(value))
            end
        elseif field == 'label' then
            if type(value) ~= 'string' then error('颜色标签值无效') end
        end
        values[field] = value
    end
    return values
end

function Adapter.apply(catalog, pair, fields)
    local result = { pair = pair }
    local ok, err = LrTasks.pcall(function()
        local status = catalog:withWriteAccessDo('PairFlow：同步选片标记', function()
            for _, item in ipairs({ pair.source, pair.target }) do
                if item.photo:getRawMetadata('path') ~= item.path
                    or item.photo:getRawMetadata('isVirtualCopy') then
                    error('照片路径或原片状态已变化，请重新预览')
                end
            end
            local sourceValues = readValues(pair.source.photo, fields)
            local oldValues = readValues(pair.target.photo, fields)
            local changed = {}
            local wrote, writeError = LrTasks.pcall(function()
                for _, field in ipairs(fields) do
                    if oldValues[field] ~= sourceValues[field] then
                        changed[#changed + 1] = field
                        pair.target.photo:setRawMetadata(field, sourceValues[field])
                    end
                end
            end)
            if not wrote then
                local restoreErrors = {}
                for _, field in ipairs(changed) do
                    local restored, restoreError = LrTasks.pcall(function()
                        pair.target.photo:setRawMetadata(field, oldValues[field])
                    end)
                    if not restored then
                        restoreErrors[#restoreErrors + 1] = field .. ': ' .. tostring(restoreError)
                    end
                end
                result.error = tostring(writeError)
                result.restored = #restoreErrors == 0
                if #restoreErrors > 0 then
                    result.error = result.error .. '\n恢复失败：' .. table.concat(restoreErrors, '; ')
                end
            else
                result.unchanged = #changed == 0
                result.ok = true
            end
        end, { timeout = 15 })
        if status == 'aborted' or status == 'queued' then
            error('未取得目录写入权限：' .. status)
        end
        if not result.ok and not result.error then error('目录写入未执行') end
    end)
    if not ok then result.ok = false; result.error = tostring(err) end
    return result
end

return Adapter
