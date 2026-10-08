local Pairing = {}

local function baseName(path)
    local name = path:match('([^/\\]+)$') or path
    return (name:gsub('%.[^.]+$', '')):lower()
end

local function kind(item)
    return item.format == 'JPEG' and 'JPEG' or 'RAW'
end

local function sourceKey(source)
    return source.folder .. '\n' .. baseName(source.path) .. '\n' .. kind(source)
end

function Pairing.build(sources, candidatesByFolder, mode)
    mode = mode or 'auto'
    local plan = { pairs = {}, skipped = {}, mode = mode, jpegCount = 0, rawCount = 0 }
    local sourcesByKey, selectedByPath = {}, {}
    local indexByFolder = {}
    for path, folder in pairs(candidatesByFolder) do
        local index = {}
        for _, candidate in ipairs(folder.photos) do
            if not candidate.virtual and candidate.folder == path
                and (candidate.format == 'JPEG' or candidate.format == 'RAW' or candidate.format == 'DNG') then
                local base = baseName(candidate.path) .. '\n' .. kind(candidate)
                index[base] = index[base] or {}
                index[base][#index[base] + 1] = candidate
            end
        end
        indexByFolder[path] = index
    end
    for _, source in ipairs(sources) do
        local key = sourceKey(source)
        sourcesByKey[key] = (sourcesByKey[key] or 0) + 1
        selectedByPath[source.path] = source
        if kind(source) == 'JPEG' then plan.jpegCount = plan.jpegCount + 1
        else plan.rawCount = plan.rawCount + 1 end
    end

    local proposals, bySource, incoming = {}, {}, {}
    for _, source in ipairs(sources) do
        local folder = candidatesByFolder[source.folder]
        local reason, code
        local matches = {}
        local targetKind = kind(source) == 'JPEG' and 'RAW' or 'JPEG'
        local targetName = targetKind == 'RAW' and 'RAW/DNG' or 'JPEG'
        if sourcesByKey[sourceKey(source)] > 1 then
            reason = '同目录选中多个同名 ' .. kind(source) .. ' 来源，无法确定应使用哪个标记'
            code = 'ambiguous'
        elseif not folder or folder.error then
            reason = '无法读取同目录候选：' .. tostring(folder and folder.error or '文件夹不在目录中')
            code = 'error'
        else
            matches = indexByFolder[source.folder][baseName(source.path) .. '\n' .. targetKind] or {}
            if #matches == 0 then
                reason = '未找到已导入 Lightroom 的同目录同名 ' .. targetName
                code = 'missing'
            elseif #matches > 1 then
                local timedMatches = {}
                if type(source.time) == 'number' then
                    for _, candidate in ipairs(matches) do
                        if candidate.time == source.time then
                            timedMatches[#timedMatches + 1] = candidate
                        end
                    end
                end
                if #timedMatches == 1 then
                    matches = timedMatches
                else
                    reason = '多个 ' .. targetName .. ' 候选，拍摄时间未能确定唯一目标'
                    code = 'ambiguous'
                end
            end
        end

        if reason then
            plan.skipped[#plan.skipped + 1] = { source = source, reason = reason, code = code }
        else
            local pair = { source = source, target = matches[1] }
            proposals[#proposals + 1] = pair
            bySource[source.path] = pair
            local targetId = pair.target.path
            incoming[targetId] = (incoming[targetId] or 0) + 1
        end
    end

    local used = {}
    for _, pair in ipairs(proposals) do
        local sourceId = pair.source.path
        local targetId = pair.target.path
        local reverse = bySource[targetId]
        local both = mode == 'auto' and selectedByPath[targetId] ~= nil
        if incoming[targetId] > 1 or (both and (not reverse
            or reverse.target.path ~= sourceId or incoming[sourceId] > 1)) then
            plan.skipped[#plan.skipped + 1] = {
                source = pair.source, code = 'ambiguous',
                reason = '配对涉及多个来源或双向匹配不一致，无法安全同步',
            }
        elseif not used[sourceId] then
            pair.bothSelected = both
            plan.pairs[#plan.pairs + 1] = pair
            used[sourceId] = true
            if both then used[targetId] = true end
        end
    end
    return plan
end

return Pairing
