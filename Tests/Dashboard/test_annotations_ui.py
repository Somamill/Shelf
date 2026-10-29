"""Optional Chromium smoke test: requires Playwright and system Chromium. No accounts used."""
import json,sys,tempfile,http.server,threading,functools,io
from pathlib import Path
from playwright.sync_api import sync_playwright
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'Sources/ShelfCore/Tools'))
from shelf_annotations import Library,dispatch
import shelf_studio
from unittest.mock import patch
with tempfile.TemporaryDirectory() as tmp:
 lib=Library(Path(tmp)/'a.sqlite')
 lib.put({'text':'A quiet passage about books.','title':'Example book','author':'Writer','source':'Shelf','bookId':2})
 studio=shelf_studio.Studio(lib)
 notion_pending={}
 errors=[]
 with sync_playwright() as p:
  browser=p.chromium.launch(executable_path='/usr/bin/chromium',headless=True,args=['--no-sandbox'])
  page=browser.new_page(viewport={'width':1440,'height':1100})
  page.on('pageerror',lambda e:(errors.append(str(e)),print('PAGE ERROR:',e)))
  def bridge(payload):
   if payload.get('type')=='studio':
    try:
     action=payload['action']
     if action=='notionPreview':
      result=shelf_studio.dispatch(studio,payload)
      notion_pending['rules']=payload.get('rules',{})
      notion_pending['expected']=[x['digest'] for x in result['notionPreview']['pages']]
     elif action=='notionExport':
      with patch.object(shelf_studio,'http_json',return_value={'id':'12345678-0000-0000-0000-123456789abc'}):
       result=shelf_studio.dispatch(studio,{**payload,**notion_pending,'notionToken':'fixture-token'})
     elif action=='chat':
      with patch.object(shelf_studio,'http_json',return_value={'choices':[{'message':{'content':'Grounded answer [H1].'}}]}):
       result=shelf_studio.dispatch(studio,{**payload,'aiToken':'fixture-token'})
     else: result=shelf_studio.dispatch(studio,payload)
     return {**result,'action':action,'notionConnected':True,'openaiConnected':True}
    except ValueError as e:return {'ok':False,'error':str(e)}
   if payload.get('type')!='annotations': return None
   if payload['action'] in ('chooseImport','chooseRestore','chooseExportFolder','open'): return None
   if payload['action']=='importReadwise':
    fixture={'results':[{'user_book_id':42,'title':'Readwise article','source':'reader','category':'articles',
                         'highlights':[{'id':420,'text':'A passage from Readwise','note':'Imported note'}]}], 'nextPageCursor':None}
    with patch('shelf_annotations.urllib.request.urlopen',return_value=io.BytesIO(json.dumps(fixture).encode())):
     result=dispatch(lib,{**payload,'credentials':{'token':'fixture-token'}})
   else: result=dispatch(lib,payload)
   result['action']=payload['action'];result['readwiseConnected']=True;return result
  page.expose_function('nativeAnnotation',bridge)
  page.add_init_script('window.webkit={messageHandlers:{dashboard:{postMessage(o){window.nativeAnnotation(o).then(r=>{if(r){if(o.type==="studio")window.studioData(r);else window.annotationData(r)}})}}}};')
  server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(http.server.SimpleHTTPRequestHandler,directory=str(root/'Resources/Dashboard')))
  threading.Thread(target=server.serve_forever,daemon=True).start()
  page.goto(f'http://127.0.0.1:{server.server_port}/index.html')
  page.locator('[data-page="highlights"]').click()
  page.locator('#annotationList').get_by_text('A quiet passage about books.',exact=True).wait_for()
  page.get_by_role('button',name='Add passage',exact=True).click()
  page.locator('#annotationEditor [name="title"]').fill('日本の本')
  page.locator('#annotationEditor [name="author"]').fill('Author')
  page.locator('#annotationEditor [name="text"]').fill('月')
  page.locator('#annotationEditor [name="note"]').fill('Personal note')
  page.locator('#annotationEditor [name="tags"]').fill('日本語, focus')
  page.locator('#annotationEditor button[type="submit"]').click()
  page.locator('#annotationList').get_by_text('月',exact=True).wait_for()
  page.locator('#annotationSearch').fill('Personal note')
  assert page.locator('#annotationList .annotation-card').count()==1
  page.locator('#annotationList [data-annotation="favorite"]').click()
  page.wait_for_function("annotationState.items.some(x=>x.favorite)")
  page.get_by_role('button',name='Save filters as collection…').click()
  page.locator('#annotationCollectionForm [name="name"]').fill('Japanese notes')
  page.get_by_role('button',name='Save collection',exact=True).click()
  page.get_by_role('button',name='★ Japanese notes').wait_for()
  page.locator('[data-page="preferences"]').click()
  page.get_by_text('Sending highlights and Reader progress',exact=True).click()
  page.locator('[name="autoSync"]').check()
  page.locator('[name="dest_readwise"]').check()
  page.locator('[name="reviewSize"]').fill('3')
  page.get_by_role('button',name='Save settings',exact=True).click()
  page.wait_for_function('annotationState.settings.reviewSize===3')
  assert lib.settings()['autoSync']
  page.get_by_role('button',name='Preview export',exact=True).click()
  page.locator('#annotationExportDialog[open]').wait_for()
  assert 'Personal note' in page.locator('#annotationTextPreview').text_content()
  page.locator('#annotationExportDialog button').click()
  page.locator('[data-page="review"]').click()
  page.locator('#annotationReview .annotation-card').wait_for()
  page.keyboard.press('Enter')
  page.wait_for_function('annotationState.review.length===1')
  page.locator('[data-page="highlights"]').click()
  page.locator('#annotationSearch').fill('')
  page.screenshot(path=str(Path(tmp)/'highlights.png'),full_page=True)
  page.locator('[data-page="preferences"]').click()
  page.screenshot(path=str(Path(tmp)/'preferences.png'),full_page=True)
  page.locator('[data-page="studio"]').click()
  page.locator('#studioSettingsForm').wait_for()
  page.locator('#studioSettingsForm [name="notionParent"]').fill('12345678-1234-1234-1234-123456789abc')
  page.locator('#studioSettingsForm [name="chatProvider"]').select_option('openai')
  page.locator('#studioSettingsForm [name="chatModel"]').fill('gpt-4.1-mini')
  page.get_by_role('button',name='Save Studio settings',exact=True).click()
  page.wait_for_function("studioState.options.chatProvider==='openai'")
  page.locator('#studioQuestion').fill('books')
  page.get_by_role('button',name='Preview matching passages',exact=True).click()
  page.locator('#studioEvidence .annotation-card').wait_for()
  page.get_by_role('button',name='Ask selected model',exact=True).click()
  page.get_by_text('Connect an OpenAI key and explicitly allow sending these excerpts',exact=True).wait_for()
  assert studio.history()==[]
  page.locator('[name="studioCloudChat"]').check()
  page.get_by_role('button',name='Ask selected model',exact=True).click()
  page.get_by_text('Grounded answer [H1].',exact=True).wait_for()
  page.get_by_role('button',name='Preview current view for Notion',exact=True).click()
  page.locator('[name="studioNotionConsent"]').wait_for()
  page.locator('[name="studioNotionConsent"]').check()
  page.get_by_role('button',name='Export previewed snapshots',exact=True).click()
  page.locator('#studioNotionResults').get_by_text('sent',exact=True).wait_for()
  # Native OCR/audio dialogs are simulated; capture persistence/excerpt editing are real.
  response=shelf_studio.dispatch(studio,{'action':'importTranscript','title':'Fixture podcast','content':'1\n00:00:03,000 --> 00:00:05,000\nA spoken passage\n','format':'srt'})
  page.evaluate('value=>studioData(value)',response)
  page.locator('#studioExcerpt').fill('A corrected spoken passage')
  page.locator('#studioExcerptTags').fill('podcast')
  page.get_by_role('button',name='Save passage to Highlights',exact=True).click()
  page.wait_for_function("studioState.item?.text==='A corrected spoken passage'")
  assert any(x['source']=='Podcast' for x in lib.items())
  page.locator('[data-page="highlights"]').click()
  page.locator('#annotationSearch').fill('')
  page.locator('#readwiseImportButton').click()
  page.wait_for_function("annotationState.items.some(x=>x.source==='Readwise'&&x.text==='A passage from Readwise')")
  page.get_by_text('A passage from Readwise',exact=True).wait_for()
  assert '1 Readwise highlights saved' in page.locator('#readwiseImportStatus').text_content()
  assert page.get_by_role('button',name='Open in Readwise',exact=True).count()==1
  # Exercise the exact reader anchor code embedded in the native app.
  swift=(root/'Sources/ShelfMacApp/AppMain.swift').read_text()
  anchor=swift[swift.index('              function rangeAt('):]
  anchor=anchor[:anchor.index('\n',anchor.index('window.captureReaderHighlight=function'))]
  anchor_page=browser.new_page()
  anchor_page.set_content('<div id="reader-flow"><p>First repeated quote. Middle.</p><p>Second repeated quote. End.</p></div>')
  anchor_page.evaluate("""()=>{window.readerFlow=document.getElementById('reader-flow');window.readerViewport={scrollLeft:0};window.userHasNavigated=false;window.step=()=>100;window.setPage=()=>{};window.savedHighlightRange=null;window.savedHighlightText='';window.chapterIndex=()=>0;window.percentage=()=>0.5;window.currentPage=1;window.pageCount=4;window.readerChapters=[{title:'Chapter'}];window.readerBook={savedHighlights:[]};window.webkit={messageHandlers:{reader:{postMessage(x){window.capturedHighlight=x}}}}}""")
  anchor_page.add_script_tag(content=anchor)
  matched=anchor_page.evaluate("""()=>{const all=readerFlow.textContent,start=all.lastIndexOf('repeated quote'),item={text:'repeated quote',location:{start,end:start+14},note:'second',color:'blue'};readerBook.savedHighlights=[item];readerApplySavedHighlights();return readerFlow.querySelector('mark').parentElement.textContent.startsWith('Second')}""")
  assert matched,'Position must select the correct repeated passage'
  assert anchor_page.evaluate("highlightRange({text:'repeated quote'})===null"),'Ambiguous unanchored quotes must not be guessed'
  anchor_page.evaluate("""()=>{const node=readerFlow.querySelector('p').firstChild,range=document.createRange();range.setStart(node,0);range.setEnd(node,5);const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);captureReaderHighlight()}""")
  captured=anchor_page.evaluate('capturedHighlight')
  assert captured['text']=='First' and captured['start']==0 and captured['end']==5
  browser.close()
  server.shutdown()
 assert not errors,errors
 print('PASS: annotation and Studio UI, consent, Notion preview/export fixtures, cited chat fixtures, transcripts, and exact reader anchors through real SQLite backend')
 lib.db.close()
