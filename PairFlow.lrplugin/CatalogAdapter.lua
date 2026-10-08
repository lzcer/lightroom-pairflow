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

function Adapter.collect(catalog, selected, progress, mode)
    local sources, folders = {}, {}
    local ignored = 0
    for i, photo in ipairs(selected) do
        local item = describe(photo)
        local jpeg = item.format == 'JPEG'
        local raw = item.format == 'RAW' or item.format == 'DNG'
        local accepted = (mode == 'jpegToRaw' and jpeg) or (mode == 'rawToJpeg' and raw)
            or ((not mode or mode == 'auto') and (jpeg or raw))
        if accepted and not item.virtual then
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
                if format == 'JPG' or format == 'JPEG' or format == 'RAW' or format == 'DNG' then
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

local function resolve(pair, fields)
    local resolution = { writes = {}, conflicts = {} }
    local readFields = {}
    local includesRating = false
    for _, field in ipairs(fields) do
        readFields[#readFields + 1] = field
        if field == 'rating' then includesRating = true end
    end
    if pair.bothSelected and not includesRating then readFields[#readFields + 1] = 'rating' end
    local source = readValues(pair.source.photo, readFields)
    local target = readValues(pair.target.photo, readFields)
    if pair.bothSelected and source.rating > 0 and target.rating > 0 then
        resolution.blocked = true
        resolution.conflicts[1] = { field = 'rating', source = source.rating, target = target.rating }
        return resolution
    end
    for _, field in ipairs(fields) do
        if source[field] ~= target[field] then
            if not pair.bothSelected then
                resolution.writes[#resolution.writes + 1] = {
                    item = pair.target, field = field, old = target[field], value = source[field],
                }
            elseif field == 'rating' then
                local useSource = source.rating > target.rating
                resolution.writes[#resolution.writes + 1] = {
                    item = useSource and pair.target or pair.source, field = field,
                    old = useSource and target[field] or source[field],
                    value = useSource and source[field] or target[field],
                }
            else
                resolution.conflicts[#resolution.conflicts + 1] = {
                    field = field, source = source[field], target = target[field],
                }
            end
        end
    end
    return resolution
end

function Adapter.inspect(pair, fields)
    local ok, resolution = LrTasks.pcall(function() return resolve(pair, fields) end)
    if ok then return resolution end
    return { writes = {}, conflicts = {}, error = tostring(resolution) }
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
            local resolution = resolve(pair, fields)
            result.resolution = resolution
            if resolution.blocked then
                result.ok, result.blocked = true, true
                return
            end
            local changed = {}
            local wrote, writeError = LrTasks.pcall(function()
                for _, change in ipairs(resolution.writes) do
                    changed[#changed + 1] = change
                    change.item.photo:setRawMetadata(change.field, change.value)
                end
            end)
            if not wrote then
                local restoreErrors = {}
                for _, change in ipairs(changed) do
                    local restored, restoreError = LrTasks.pcall(function()
                        change.item.photo:setRawMetadata(change.field, change.old)
                    end)
                    if not restored then
                        restoreErrors[#restoreErrors + 1] = change.item.path .. ' / '
                            .. change.field .. ': ' .. tostring(restoreError)
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
