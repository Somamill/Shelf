local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Event = require("ui/event")
local ShelfProgress = WidgetContainer:extend{
    name = "shelfprogress",
    is_doc_only = true,
}
function ShelfProgress:onReaderReady()
    local sync = self.ui and self.ui.kosync
    if not sync or sync.shelf_percent_support then return end
    sync.shelf_percent_support = true
    local original = sync.syncToProgress
    sync.syncToProgress = function(plugin, progress)
        local fraction = tonumber(progress)
        if not plugin.ui.document.info.has_pages and fraction and fraction >= 0 and fraction <= 1 then
            plugin.ui:handleEvent(Event:new("GotoPercent", fraction * 100))
        else
            original(plugin, progress)
        end
    end
end
function ShelfProgress:init()
    self:onReaderReady()
end
return ShelfProgress
