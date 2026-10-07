local Pairing = {}

local function baseName(path)
    local name = path:match('([^/\\]+)$') or path
    return (name:gsub('%.[^.]+$', '')):lower()
end

local function sourceKey(source)
    return source.folder .. '\n' .. baseName(source.path)
end

function Pairing.build(sources, candidatesByFolder)
    local plan = { pairs = {}, skipped = {} }
    local sourcesByKey = {}
    local indexByFolder = {}
    for path, folder in pairs(candidatesByFolder) do
        local index = {}
        for _, candidate in ipairs(folder.photos) do
            if not candidate.virtual and candidate.folder == path
                and (candidate.format == 'RAW' or candidate.format == 'DNG') then
                local base = baseName(candidate.path)
                index[base] = index[base] or {}
                index[base][#index[base] + 1] = candidate
            end
        end
        indexByFolder[path] = index
    end
    for _, source in ipairs(sources) do
        local key = sourceKey(source)
        sourcesByKey[key] = (sourcesByKey[key] or 0) + 1
    end

    for _, source in ipairs(sources) do
        local folder = candidatesByFolder[source.folder]
        local reason, code
        local matches = {}
        if sourcesByKey[sourceKey(source)] > 1 then
            reason = '同目录存在多个同名 JPEG 来源，无法确定应使用哪个标记'
            code = 'ambiguous'
        elseif not folder or folder.error then
            reason = '无法读取同目录候选：' .. tostring(folder and folder.error or '文件夹不在目录中')
            code = 'error'
        else
            matches = indexByFolder[source.folder][baseName(source.path)] or {}
            if #matches == 0 then
                reason = '未找到已导入 Lightroom 的同目录同名 RAW/DNG'
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
                    reason = '多个 RAW/DNG 候选，拍摄时间未能确定唯一目标'
                    code = 'ambiguous'
                end
            end
        end

        if reason then
            plan.skipped[#plan.skipped + 1] = { source = source, reason = reason, code = code }
        else
            plan.pairs[#plan.pairs + 1] = { source = source, target = matches[1] }
        end
    end
    return plan
end

return Pairing
