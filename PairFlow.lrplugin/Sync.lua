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

local function chooseOptions(props, prefs)
    local f = LrView.osFactory()
    local answer = LrDialogs.presentModalDialog {
        title = 'PairFlow：同步 RAW/JPEG 选片标记',
        actionVerb = '继续',
        contents = f:column {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:static_text {
                title = '范围：当前选中的原片。\n目标：已导入的同目录同名 JPEG 或 RAW/DNG 原片。',
            },
            f:popup_menu {
                value = LrView.bind('mode'),
                items = {
                    { title = '自动（按选中照片同步到另一种格式）', value = 'auto' },
                    { title = 'JPEG → RAW', value = 'jpegToRaw' },
                    { title = 'RAW → JPEG', value = 'rawToJpeg' },
                },
            },
            f:checkbox { title = '同步星级', value = LrView.bind('rating') },
            f:checkbox { title = '同步颜色标签', value = LrView.bind('color') },
            f:checkbox { title = '同步选取/拒绝状态', value = LrView.bind('pick') },
            f:separator { fill_horizontal = 1 },
            f:checkbox { title = '仅预览（不写入）', value = LrView.bind('preview') },
            f:static_text {
                title = '单向同步会覆盖目标标记，包括零星级和空状态。\n自动模式两边都选中：保留唯一星级；两边都有星则跳过整对。\n颜色标签或选取状态不同时，跳过冲突字段。',
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
        return { invalid = true }
    end
    prefs.rating, prefs.color, prefs.pick = props.rating, props.color, props.pick
    return { fields = fields, preview = props.preview, mode = props.mode }
end

local function runOptions(context, catalog, selected, options)
    local progress = LrProgressScope { title = 'PairFlow：扫描配对', functionContext = context }
    progress:setCancelable(true)
    local sources, folders, ignored = Adapter.collect(catalog, selected, progress, options.mode)
    if not sources then
        progress:done()
        LrDialogs.message('PairFlow', '扫描已取消，没有写入任何选片标记。', 'info')
        return false
    end
    if #sources == 0 then
        progress:done()
        LrDialogs.message('PairFlow', '选中项中没有适用于当前模式的 JPEG 或 RAW/DNG 原片。', 'info')
        return false
    end
    local plan = Pairing.build(sources, folders, options.mode)
    for _, pair in ipairs(plan.pairs) do
        if progress:isCanceled() then
            progress:done()
            return false
        end
        pair.resolution = Adapter.inspect(pair, options.fields)
        LrTasks.yield()
    end
    local scanCanceled = progress:isCanceled()
    progress:done()
    if scanCanceled then
        LrDialogs.message('PairFlow', '扫描已取消，没有写入任何选片标记。', 'info')
        return false
    end
    if options.preview or #plan.pairs == 0 then
        Report.show(Report.text(plan, options.fields, ignored), true)
        return false
    end
    local confirmed = LrDialogs.confirm('PairFlow：确认同步',
        Report.summary(plan, ignored) .. '\n\n单向同步将覆盖勾选的目标标记，包括来源的零星级、空颜色和未选取状态。\n自动模式两边都选中时，按星级和字段冲突规则处理。\n取消执行会保留已经完成的配对。',
        '同步', '取消')
    if confirmed ~= 'ok' then return false end

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
    return true
end

LrFunctionContext.postAsyncTaskWithContext('PairFlow', function(context)
    context:addFailureHandler(function(_, err)
        LrDialogs.message('PairFlow：操作失败', tostring(err), 'critical')
    end)
    local catalog = LrApplication.activeCatalog()
    if not catalog:getTargetPhoto() then
        LrDialogs.message('PairFlow', '请先选中需要同步的 JPEG 或 RAW/DNG 原片。', 'info')
        return
    end
    local selected = catalog:getTargetPhotos()
    local prefs = LrPrefs.prefsForPlugin()
    local props = LrBinding.makePropertyTable(context)
    props.rating = prefs.rating ~= false
    props.color = prefs.color ~= false
    props.pick = prefs.pick ~= false
    props.preview = false
    props.mode = 'auto'
    while true do
        local options = chooseOptions(props, prefs)
        if not options then return end
        if not options.invalid and runOptions(context, catalog, selected, options) then return end
    end
end)
