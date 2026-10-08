local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'

local Report = {}
local fieldNames = {
    rating = '星级', label = '颜色标签', pickStatus = '选取/拒绝状态',
}
local modeNames = { auto = '自动', jpegToRaw = 'JPEG → RAW', rawToJpeg = 'RAW → JPEG' }

function Report.summary(plan, ignored, results)
    local counts = { missing = 0, ambiguous = 0, error = 0 }
    for _, item in ipairs(plan.skipped) do counts[item.code] = counts[item.code] + 1 end
    local byPair = {}
    for _, result in ipairs(results or {}) do byPair[result.pair] = result end
    local blocked, partial, readErrors = 0, 0, 0
    for _, pair in ipairs(plan.pairs) do
        local result = byPair[pair]
        local resolution = result and result.resolution or pair.resolution
        if resolution then
            if resolution.blocked then blocked = blocked + 1
            elseif #resolution.conflicts > 0 then partial = partial + 1 end
            if resolution.error then readErrors = readErrors + 1 end
        end
    end
    return string.format('同步模式：%s\n选中来源：JPEG %d；RAW/DNG %d\n唯一配对：%d\n未匹配：%d；歧义：%d；读取失败：%d\n配对跳过：%d；星级冲突跳过整对：%d；存在字段冲突：%d\n忽略的非当前模式类型/虚拟副本：%d',
        modeNames[plan.mode], plan.jpegCount, plan.rawCount, #plan.pairs,
        counts.missing, counts.ambiguous, counts.error + readErrors,
        #plan.skipped, blocked, partial, ignored)
end

local function valueText(value)
    return string.format('%q', tostring(value))
end

function Report.text(plan, fields, ignored, results, canceled)
    local lines = { results and 'PairFlow 执行报告' or 'PairFlow 预览报告', Report.summary(plan, ignored, results) }
    local names = {}
    for _, field in ipairs(fields) do names[#names + 1] = fieldNames[field] end
    lines[#lines + 1] = '同步字段：' .. table.concat(names, '、')
    lines[#lines + 1] = '仅修改 Lightroom 目录元数据，不保存 XMP 或修改 Develop 参数。'
    if canceled then lines[#lines + 1] = '操作已取消，已完成的同步保留。' end

    local byPair = {}
    local updated, unchanged, failed, blocked, partial = 0, 0, 0, 0, 0
    for _, result in ipairs(results or {}) do
        byPair[result.pair] = result
        if result.ok then
            if result.blocked then blocked = blocked + 1
            elseif result.unchanged then unchanged = unchanged + 1 else updated = updated + 1 end
            if not result.blocked and #result.resolution.conflicts > 0 then partial = partial + 1 end
        else
            failed = failed + 1
        end
    end
    if results then
        lines[#lines + 1] = string.format('更新：%d；无需写入：%d；星级冲突跳过：%d；字段冲突：%d；失败：%d；未执行：%d',
            updated, unchanged, blocked, partial, failed, #plan.pairs - #results)
    end
    lines[#lines + 1] = ''

    for _, pair in ipairs(plan.pairs) do
        local result = byPair[pair]
        local resolution = result and result.resolution or pair.resolution
        local state = '可同步'
        if resolution then
            if resolution.error then state = '读取失败'
            elseif resolution.blocked then state = '星级冲突，跳过整对'
            elseif #resolution.conflicts > 0 then state = '跳过冲突字段'
            elseif #resolution.writes == 0 then state = '已一致' end
        end
        if results then
            if not result then state = '未执行'
            elseif result.blocked then state = '星级冲突，跳过整对'
            elseif result.ok then
                state = result.unchanged and '无需写入' or '已更新'
                if #result.resolution.conflicts > 0 then state = state .. '，跳过冲突字段' end
            else state = '失败' end
        end
        lines[#lines + 1] = '[' .. state .. '] ' .. pair.source.path
        lines[#lines + 1] = (pair.bothSelected and '  ↔ ' or '  → ') .. pair.target.path
        if resolution then
            if resolution.error then lines[#lines + 1] = '  ' .. resolution.error end
            for _, conflict in ipairs(resolution.conflicts) do
                lines[#lines + 1] = '  冲突：' .. fieldNames[conflict.field]
                    .. '（上方 ' .. valueText(conflict.source) .. '；下方 ' .. valueText(conflict.target) .. '）'
            end
            for _, change in ipairs(resolution.writes) do
                lines[#lines + 1] = '  ' .. fieldNames[change.field] .. '：'
                    .. valueText(change.old) .. ' → ' .. valueText(change.value) .. '；目标：' .. change.item.path
            end
        end
        if result and result.error then
            lines[#lines + 1] = '  ' .. result.error
            if result.restored then lines[#lines + 1] = '  已恢复本配对尝试写入字段的旧值。' end
        end
    end
    for _, item in ipairs(plan.skipped) do
        lines[#lines + 1] = '[跳过] ' .. item.source.path
        lines[#lines + 1] = '  ' .. item.reason
    end
    return table.concat(lines, '\n')
end

function Report.show(text, preview)
    local f = LrView.osFactory()
    LrDialogs.presentModalDialog {
        title = preview and 'PairFlow：预览（没有写入）' or 'PairFlow：执行结果',
        actionVerb = preview and '完成' or '关闭',
        contents = f:column {
            spacing = f:control_spacing(),
            f:static_text { title = preview and '下方明细可以全选并复制。完成或取消后返回同步设置。'
                or '下方明细可以全选并复制。' },
            f:edit_field { value = text, width_in_chars = 95, height_in_lines = 24 },
        },
    }
end

return Report
