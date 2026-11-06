import AppKit

/// Native searchable contents, kept in the EPUB's reading order.
final class ReaderContentsController:NSViewController,NSTableViewDataSource,NSTableViewDelegate,NSSearchFieldDelegate {
    private let chapters:[[String:Any]]
    private let selected:Int
    private let choose:(Int)->Void
    private let search=NSSearchField()
    private let table=NSTableView()
    private var indices:[Int]
    private var selecting=false
    init(chapters:[[String:Any]],selected:Int,choose:@escaping (Int)->Void) {
        self.chapters=chapters;self.selected=selected;self.choose=choose;self.indices=Array(chapters.indices)
        super.init(nibName:nil,bundle:nil)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    override func loadView() {
        view=NSView(frame:NSRect(x:0,y:0,width:340,height:390))
        search.frame=NSRect(x:14,y:348,width:312,height:28)
        search.placeholderString="Find a chapter…";search.delegate=self
        search.setAccessibilityLabel("Search book chapters")
        view.addSubview(search)
        let scroll=NSScrollView(frame:NSRect(x:8,y:8,width:324,height:330))
        scroll.hasVerticalScroller=true;scroll.drawsBackground=false
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("chapter"));column.width=304
        table.addTableColumn(column);table.headerView=nil;table.rowHeight=32;table.dataSource=self;table.delegate=self
        table.backgroundColor = .clear;table.setAccessibilityLabel("Book chapters")
        scroll.documentView=table;view.addSubview(scroll)
        table.reloadData()
        selecting=true
        if chapters.indices.contains(selected) { table.selectRowIndexes(IndexSet(integer:selected),byExtendingSelection:false);table.scrollRowToVisible(selected) }
        selecting=false
    }
    override func viewDidAppear() { super.viewDidAppear();view.window?.makeFirstResponder(search) }
    func numberOfRows(in tableView:NSTableView)->Int { indices.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let index=indices[row],chapter=chapters[index]
        let text=NSTextField(labelWithString:String(repeating:"  ",count:min(4,chapter["depth"] as? Int ?? 0))+(chapter["title"] as? String ?? "Section \(index+1)"))
        text.font = .systemFont(ofSize:13);text.lineBreakMode = .byTruncatingTail;text.toolTip=chapter["title"] as? String
        return text
    }
    func tableViewSelectionDidChange(_ notification:Notification) {
        guard !selecting,indices.indices.contains(table.selectedRow) else { return }
        choose(indices[table.selectedRow])
    }
    func controlTextDidChange(_ notification:Notification) {
        let query=search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        indices=chapters.indices.filter { query.isEmpty || "\($0+1) \(chapters[$0]["title"] as? String ?? "")".localizedCaseInsensitiveContains(query) }
        selecting=true;table.reloadData();table.deselectAll(nil);selecting=false
    }
}
