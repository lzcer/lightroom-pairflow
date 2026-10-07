local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'

local Report = {}
local fieldNames = {
    rating = '星级', label = '颜色标签', pickStatus = '选取/拒绝状态',
}

function Report.summary(plan, ignored)
    local counts = { missing = 0, ambiguous = 0, error = 0 }
    for _, item in ipairs(plan.skipped) do counts[item.code] = counts[item.code] + 1 end
    return string.format('JPEG 原片：%d\n唯一配对：%d\n未匹配：%d；歧义：%d；读取失败：%d\n跳过合计：%d\n忽略的其他类型/虚拟副本：%d',
        #plan.pairs + #plan.skipped, #plan.pairs, counts.missing, counts.ambiguous, counts.error,
        #plan.skipped, ignored)
end

function Report.text(plan, fields, ignored, results, canceled)
    local lines = { results and 'PairFlow 执行报告' or 'PairFlow 预览报告', Report.summary(plan, ignored) }
    local names = {}
    for _, field in ipairs(fields) do names[#names + 1] = fieldNames[field] end
    lines[#lines + 1] = '同步字段：' .. table.concat(names, '、')
    lines[#lines + 1] = '仅修改 Lightroom 目录元数据，不保存 XMP 或修改 Develop 参数。'
    if canceled then lines[#lines + 1] = '操作已取消，已完成的同步保留。' end

    local byPair = {}
    local updated, unchanged, failed = 0, 0, 0
    for _, result in ipairs(results or {}) do
        byPair[result.pair] = result
        if result.ok then
            if result.unchanged then unchanged = unchanged + 1 else updated = updated + 1 end
        else
            failed = failed + 1
        end
    end
    if results then
        lines[#lines + 1] = string.format('更新：%d；已一致：%d；失败：%d；未执行：%d',
            updated, unchanged, failed, #plan.pairs - #results)
    end
    lines[#lines + 1] = ''

    for _, pair in ipairs(plan.pairs) do
        local result = byPair[pair]
        local state = '可同步'
        if results then
            if not result then state = '未执行'
            elseif result.ok then state = result.unchanged and '已一致' or '已更新'
            else state = '失败' end
        end
        lines[#lines + 1] = '[' .. state .. '] ' .. pair.source.path
        lines[#lines + 1] = '  → ' .. pair.target.path
        if result and result.error then
            lines[#lines + 1] = '  ' .. result.error
            if result.restored then lines[#lines + 1] = '  已恢复本照片尝试写入字段的旧值。' end
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
        actionVerb = '关闭',
        contents = f:column {
            spacing = f:control_spacing(),
            f:static_text { title = '下方明细可以全选并复制。' },
            f:edit_field { value = text, width_in_chars = 95, height_in_lines = 24 },
        },
    }
end

return Report
