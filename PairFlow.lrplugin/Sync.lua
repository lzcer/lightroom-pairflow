local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs = import 'LrPrefs'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local Pairing = require 'Pairing'
local Adapter = require 'CatalogAdapter'
local Report = require 'Report'

local function chooseOptions(context)
    local prefs = LrPrefs.prefsForPlugin()
    local props = LrBinding.makePropertyTable(context)
    props.rating = prefs.rating ~= false
    props.color = prefs.color ~= false
    props.pick = prefs.pick ~= false
    props.preview = true
    local f = LrView.osFactory()
    local answer = LrDialogs.presentModalDialog {
        title = 'PairFlow：JPEG → RAW 选片标记',
        actionVerb = '继续',
        contents = f:column {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:static_text {
                title = '范围：当前选中的 JPEG 原片。\n目标：已导入的同目录同名 RAW/DNG 原片。',
            },
            f:checkbox { title = '同步星级', value = LrView.bind('rating') },
            f:checkbox { title = '同步颜色标签', value = LrView.bind('color') },
            f:checkbox { title = '同步选取/拒绝状态', value = LrView.bind('pick') },
            f:separator { fill_horizontal = 1 },
            f:checkbox { title = '仅预览（不写入）', value = LrView.bind('preview') },
            f:static_text {
                title = 'JPEG 的零星级、无颜色和未选取状态也会覆盖 RAW。\n不修改 Develop 参数；不保存 XMP；不复制或删除文件。',
            },
        },
    }
    if answer ~= 'ok' then return nil end
    local fields = {}
    if props.rating then fields[#fields + 1] = 'rating' end
    if props.color then fields[#fields + 1] = 'label' end
    if props.pick then fields[#fields + 1] = 'pickStatus' end
    if #fields == 0 then
        LrDialogs.message('PairFlow', '请至少勾选一个同步字段。', 'info')
        return nil
    end
    prefs.rating, prefs.color, prefs.pick = props.rating, props.color, props.pick
    return { fields = fields, preview = props.preview }
end

LrFunctionContext.postAsyncTaskWithContext('PairFlow', function(context)
    context:addFailureHandler(function(_, err)
        LrDialogs.message('PairFlow：操作失败', tostring(err), 'critical')
    end)
    local catalog = LrApplication.activeCatalog()
    if not catalog:getTargetPhoto() then
        LrDialogs.message('PairFlow', '请先选中需要同步的 JPEG 原片。', 'info')
        return
    end
    local selected = catalog:getTargetPhotos()
    local options = chooseOptions(context)
    if not options then return end

    local progress = LrProgressScope { title = 'PairFlow：扫描配对', functionContext = context }
    progress:setCancelable(true)
    local sources, folders, ignored = Adapter.collect(catalog, selected, progress)
    progress:done()
    if not sources then
        LrDialogs.message('PairFlow', '扫描已取消，没有写入任何选片标记。', 'info')
        return
    end
    if #sources == 0 then
        LrDialogs.message('PairFlow', '选中项中没有 JPEG 原片。请分开导入 RAW/JPEG，并过滤 JPEG 后选择。', 'info')
        return
    end
    local plan = Pairing.build(sources, folders)
    if options.preview or #plan.pairs == 0 then
        Report.show(Report.text(plan, options.fields, ignored), true)
        return
    end
    local confirmed = LrDialogs.confirm('PairFlow：确认同步',
        Report.summary(plan, ignored) .. '\n\n将覆盖勾选的 RAW 标记，包括 JPEG 的零星级、无颜色和未选取状态。\n取消执行会保留已经完成的配对。',
        '同步', '取消')
    if confirmed ~= 'ok' then return end

    local execution = LrProgressScope { title = 'PairFlow：同步标记', functionContext = context }
    execution:setCancelable(true)
    local results = {}
    for i, pair in ipairs(plan.pairs) do
        if execution:isCanceled() then break end
        execution:setPortionComplete(i - 1, #plan.pairs)
        execution:setCaption(pair.source.path)
        results[#results + 1] = Adapter.apply(catalog, pair, options.fields)
        execution:setPortionComplete(i, #plan.pairs)
        LrTasks.yield()
    end
    local canceled = execution:isCanceled()
    execution:done()
    Report.show(Report.text(plan, options.fields, ignored, results, canceled), false)
end)
