#!/usr/bin/env python3
"""Shelf's local annotation library. JSON stdin/stdout; credentials never persisted.

Only explicit sync operations access the network. All imports are previewable and
merge by provider identity/position. Archiving is local and never deletes remotely.
"""
from __future__ import annotations
import csv
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.request
import urllib.parse
import uuid
from datetime import datetime, timezone

DEFAULTS = {
    'sort': 'newest', 'view': 'list', 'color': 'yellow', 'suggestTags': True,
    'showArchived': False, 'reviewSize': 5, 'reviewDays': [0,1,2,3,4,5,6],
    'reminderTime': '09:00', 'reminders': False, 'snoozeUntil': 0,
    'excludedTags': [], 'excludedBooks': [], 'reviewCollection': '',
    'exportFormat': 'markdown', 'exportNotes': True, 'exportTags': True,
    'exportLocation': True, 'exportTemplate': '# {title}\n\n{highlights}\n',
    'filename': '{title} - highlights', 'autoSync': False,
    'destinations': {'readwise': False, 'reader': False, 'crosspoint': False},
    'paused': [], 'importReadwise': True, 'importProgress': True,
    'rememberPerBook': False, 'restorePosition': True, 'defaultReader': 'shelf',
    'scheduledExport': False,
    'readwiseAutoImport': True,
}


def now(): return int(time.time())
def compact(s): return ' '.join(str(s or '').split())
def text(s, limit=20000): return str(s or '')[:limit]


class Library:
    def __init__(self, path=None):
        path = Path(path or Path.home() / 'Library/Application Support/Shelf/annotations.sqlite')
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, timeout=15)
        os.chmod(path, 0o600)
        self.db.row_factory = sqlite3.Row
        self.batch = False
        self.db.executescript('''
        CREATE TABLE IF NOT EXISTS highlights(id TEXT PRIMARY KEY, identity TEXT UNIQUE, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS conflicts(id TEXT PRIMARY KEY, highlight TEXT UNIQUE, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS collections(id TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS sync_state(provider TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS queue(id TEXT PRIMARY KEY, highlight TEXT NOT NULL, destination TEXT NOT NULL,
          status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL DEFAULT 0,
          message TEXT NOT NULL DEFAULT '', updated INTEGER NOT NULL, UNIQUE(highlight,destination));
        ''')
        # A crashed non-idempotent upload is uncertain, not safe to auto-repeat.
        self.db.execute("UPDATE queue SET status='uncertain', message='Previous upload was interrupted; check destination before retrying' WHERE status='sending' AND updated < ?", (now()-600,))
        self.db.commit()

    def commit(self):
        if not self.batch: self.db.commit()

    def settings(self):
        return {**DEFAULTS, **{r['key']: json.loads(r['value']) for r in self.db.execute('SELECT * FROM settings')}}

    def save_settings(self, values):
        result = self.settings()
        for k, v in values.items():
            if k not in DEFAULTS: continue
            default = DEFAULTS[k]
            if isinstance(default, bool) and type(v) is not bool: raise ValueError('Invalid toggle')
            if type(default) is int and type(v) is not int: raise ValueError('Invalid number')
            if isinstance(default, str) and not isinstance(v, str): raise ValueError('Invalid text')
            if isinstance(default, list) and not isinstance(v, list): raise ValueError('Invalid list')
            if isinstance(default, dict) and not isinstance(v, dict): raise ValueError('Invalid destinations')
            result[k] = v
        result['reviewSize'] = min(50, max(1, result['reviewSize']))
        result['destinations'] = {k: result['destinations'].get(k) is True for k in DEFAULTS['destinations']}
        result['paused'] = [v for v in result['paused'] if v in DEFAULTS['destinations']]
        result['excludedTags']=self.tags(result['excludedTags'])
        result['excludedBooks']=[str(v) for v in result['excludedBooks'] if str(v).isdigit()]
        result['reviewDays'] = [v for v in result['reviewDays'] if type(v) is int and 0 <= v <= 6]
        if not re.fullmatch(r'(?:[01]\d|2[0-3]):[0-5]\d', result['reminderTime']): raise ValueError('Use HH:MM for reminder time')
        for key, choices in {'sort':['newest','oldest','title','author'], 'view':['list','cards'], 'color':['yellow','green','blue','pink'], 'exportFormat':['markdown','csv','json'], 'defaultReader':['shelf','system']}.items():
            if result[key] not in choices: raise ValueError('Invalid preference: '+key)
        if len(result['exportTemplate']) > 10000: raise ValueError('Template is too long')
        for k,v in result.items(): self.db.execute('INSERT OR REPLACE INTO settings VALUES (?,?)',(k,json.dumps(v)))
        self.commit()
        return result

    def items(self):
        return [json.loads(r[0]) for r in self.db.execute('SELECT value FROM highlights')]

    def put(self, raw, enqueue=False, overwrite=False, commit=True):
        if not isinstance(raw, dict) or not compact(raw.get('text')): raise ValueError('A passage is required')
        if raw.get('id'):
            exact=self.db.execute('SELECT value FROM highlights WHERE id=?',(str(raw['id']),)).fetchone()
            if exact:
                prior_item=json.loads(exact[0])
                if prior_item['source']==raw.get('source') and prior_item['text']==raw.get('text'):
                    return prior_item,False
        source = text(raw.get('source') or 'Manual',100)
        book_id = int(raw.get('bookId') or 0)
        title,author = text(raw.get('title') or 'Untitled',500),text(raw.get('author'),500)
        location = {k:raw[k] for k in ['chapter','chapterIndex','percentage','page','start','end','prefix','suffix','document'] if k in raw and isinstance(raw[k], (str,int,float))}
        for k in ('percentage','start','end','page','chapterIndex'):
            if k in location and (not isinstance(location[k],(int,float)) or not math.isfinite(location[k])):
                location.pop(k)
        provider = text(raw.get('sourceId') or '',500)
        identity = hashlib.sha256(json.dumps([source,provider] if provider else [source,book_id,title,author,compact(raw['text']),location],sort_keys=True,ensure_ascii=False).encode()).hexdigest()
        prior = self.db.execute('SELECT value FROM highlights WHERE identity=?',(identity,)).fetchone()
        if prior and not overwrite:
            existing=json.loads(prior[0])
            changed=(raw['text']!=existing.get('sourceText',existing['text']) or text(raw.get('note'))!=existing.get('sourceNote',existing['note']))
            if provider and changed and not existing['archived']:
                self.db.execute('INSERT OR REPLACE INTO conflicts VALUES (?,?,?)',(existing['id'],existing['id'],json.dumps(raw,ensure_ascii=False)))
                if commit: self.commit()
            return existing,False
        old = json.loads(prior[0]) if prior else {}
        value = {**old, 'id':old.get('id') or str(uuid.uuid4()), 'text':text(raw['text']),
                 'title':title,'author':author,'bookId':book_id,'source':source,'sourceId':provider,
                 'location':location,'sourceText':raw.get('sourceText',raw['text']),'sourceNote':text(raw.get('sourceNote',raw.get('note'))),'note':text(raw.get('note')), 'tags':self.tags(raw.get('tags',[])),
                 'sourceBookId':text(raw.get('sourceBookId',old.get('sourceBookId','')),100),
                 'sourceCategory':text(raw.get('sourceCategory',old.get('sourceCategory','')),100),
                 'origin':text(raw.get('origin',old.get('origin','')),100),
                 'favorite':raw.get('favorite') is True, 'archived':raw.get('archived') is True,
                 'color':raw.get('color') if raw.get('color') in ('yellow','green','blue','pink') else self.settings()['color'], 'createdAt':int(raw.get('createdAt') or now()),
                 'updatedAt':now(), 'nextReview':max(0,int(raw.get('nextReview',0))), 'frequency':min(10,max(0,float(raw.get('frequency',1)))),
                 'reviewCount':max(0,int(raw.get('reviewCount',0)))}
        if not prior:
            try: value['id']=str(uuid.UUID(str(raw.get('id'))))
            except (ValueError,TypeError,AttributeError): value['id']=str(uuid.uuid4())
            if self.db.execute('SELECT 1 FROM highlights WHERE id=?',(value['id'],)).fetchone(): value['id']=str(uuid.uuid4())
        self.db.execute('INSERT OR REPLACE INTO highlights VALUES (?,?,?)',(value['id'],identity,json.dumps(value,ensure_ascii=False)))
        if enqueue and not value['archived']: self.enqueue(value['id'])
        if commit: self.commit()
        return value,not bool(prior)

    @staticmethod
    def tags(values):
        if isinstance(values,str): values=values.split(',')
        if not isinstance(values,list): return []
        return list(dict.fromkeys(text(v,80).strip() for v in values if isinstance(v,str) and v.strip()))[:50]

    def update(self, key, changes):
        row = self.db.execute('SELECT identity,value FROM highlights WHERE id=?',(key,)).fetchone()
        if not row: raise ValueError('Highlight no longer exists')
        item=json.loads(row['value'])
        # Passage text and source identity stay stable. Personal notes are editable.
        for k in ('note','tags','favorite','archived','color','bookId','nextReview','frequency'):
            if k in changes: item[k]=changes[k]
        item['note']=text(item['note']); item['tags']=self.tags(item['tags'])
        item['bookId']=max(0,int(item.get('bookId') or 0))
        item['frequency']=min(10,max(0,float(item.get('frequency',1))))
        item['nextReview']=max(0,int(item.get('nextReview',0)))
        item['updatedAt']=now()
        self.db.execute('UPDATE highlights SET value=? WHERE id=?',(json.dumps(item,ensure_ascii=False),key))
        if item['archived']:
            self.db.execute("DELETE FROM queue WHERE highlight=? AND status!='sending' AND status!='sent'",(key,))
        self.db.commit()
        return item

    def filter(self, rules=None):
        rules=rules or {}; settings=self.settings()
        q=compact(rules.get('search')).casefold()
        items=[x for x in self.items() if (rules.get('archived',settings['showArchived']) or not x['archived'])
               and (not rules.get('favorite') or x['favorite'])
               and (not rules.get('notes') or x['note'].strip())
               and (not rules.get('bookId') or str(x['bookId'])==str(rules['bookId']))
               and (not rules.get('source') or x['source']==rules['source'])
               and (not rules.get('tag') or rules['tag'] in x['tags'])
               and (not rules.get('author') or rules['author'].casefold() in x['author'].casefold())
               and (not rules.get('since') or int(x['updatedAt'])>=int(rules['since']))
               and (not q or q in ' '.join([x['text'],x['note'],x['title'],x['author'],*x['tags']]).casefold())]
        order=rules.get('sort') or settings['sort']
        return sorted(items,key=lambda x: x['title'].casefold() if order=='title' else x['author'].casefold() if order=='author' else float(x['createdAt']) if isinstance(x['createdAt'],(int,float)) else 0,reverse=order=='newest')

    def collections(self): return [json.loads(r[0]) for r in self.db.execute('SELECT value FROM collections')]
    def collection(self, name, rules, key=None, pinned=True):
        value={'id': key or str(uuid.uuid4()),'name':text(name,100),'rules':rules,'pinned':bool(pinned)}
        if not value['name'].strip() or not isinstance(rules,dict): raise ValueError('Collection needs a name and filters')
        self.db.execute('INSERT OR REPLACE INTO collections VALUES (?,?)',(value['id'],json.dumps(value))); self.commit()
        return value

    def review(self, day=None):
        s=self.settings(); day=day or datetime.now()
        if now()<s['snoozeUntil'] or day.weekday() not in s['reviewDays']: return []
        rules=next((c['rules'] for c in self.collections() if c['id']==s['reviewCollection']),{})
        candidates=[x for x in self.filter(rules) if not x['archived'] and x['frequency']>0 and x['nextReview']<=now()
                    and str(x['bookId']) not in [str(v) for v in s['excludedBooks']]
                    and not set(x['tags'])&set(s['excludedTags'])]
        # Stable daily order, favor unseen items without excluding short/Japanese passages.
        candidates.sort(key=lambda x:(x['reviewCount']/x['frequency'],hashlib.sha256((day.date().isoformat()+x['id']).encode()).hexdigest()))
        return candidates[:s['reviewSize']]

    def reviewed(self,key,days):
        item=next((x for x in self.items() if x['id']==key),None)
        if not item: raise ValueError('Highlight not found')
        item['reviewCount']+=1; item['nextReview']=now()+min(365,max(1,int(days)))*86400
        self.db.execute('UPDATE highlights SET value=? WHERE id=?',(json.dumps(item),key)); self.db.commit()

    def enqueue(self,key,destination=None):
        s=self.settings()
        for dest,enabled in s['destinations'].items():
            if (destination==dest or (not destination and enabled)):
                self.db.execute("INSERT OR IGNORE INTO queue(id,highlight,destination,status,updated) VALUES (?,?,?,'pending',?)",(str(uuid.uuid4()),key,dest,now()))
        self.db.commit()

    def conflicts(self):
        return [{'id':r['id'],'highlight':r['highlight'],'incoming':json.loads(r['value'])} for r in self.db.execute('SELECT * FROM conflicts')]

    def resolve(self,key,accept):
        row=self.db.execute('SELECT highlight,value FROM conflicts WHERE id=?',(key,)).fetchone()
        if not row: raise ValueError('Conflict no longer exists')
        incoming=json.loads(row['value']); current=next(x for x in self.items() if x['id']==row['highlight'])
        current['sourceText']=incoming['text']; current['sourceNote']=text(incoming.get('note'))
        if accept:
            current['text']=incoming['text']; current['note']=text(incoming.get('note')); current['location']={k:incoming[k] for k in ('chapter','start','end','prefix','suffix','percentage','document') if k in incoming}
        self.db.execute('UPDATE highlights SET value=? WHERE id=?',(json.dumps(current,ensure_ascii=False),current['id']))
        self.db.execute('DELETE FROM conflicts WHERE id=?',(key,)); self.commit()

    def queue(self): return [dict(r) for r in self.db.execute('SELECT * FROM queue ORDER BY updated DESC')]

    def readwise_state(self):
        row=self.db.execute("SELECT value FROM sync_state WHERE provider='readwise'").fetchone()
        return json.loads(row[0]) if row else {}

    def save_readwise_state(self,state):
        self.db.execute("INSERT OR REPLACE INTO sync_state VALUES ('readwise',?)",(json.dumps(state),))

    def readwise_status(self):
        state=self.readwise_state()
        return {k:state[k] for k in ('lastSuccess','nextAt','message','inProgress','imported','processed','failures') if k in state}

    def import_readwise(self,token,automatic=False):
        """Commit one export page with its cursor; resume without re-uploading anything."""
        if not token: raise ValueError('Connect Readwise once in Connections to import your library.')
        if automatic and not self.settings()['readwiseAutoImport']: return {}
        state=self.readwise_state()
        fingerprint=hashlib.sha256(token.encode()).hexdigest()
        if state.get('accountKey')!=fingerprint: state={'accountKey':fingerprint}
        if now()<state.get('nextAt',0) and (automatic or state.get('failures',0)):
            return {'readwiseWaiting':True}
        if not state.get('inProgress'):
            state.update(inProgress=True,startedAt=now(),imported=0,processed=0,cursor=None)
        query={}
        if state.get('lastSuccess'):
            query['updatedAfter']=datetime.fromtimestamp(state['lastSuccess']-60,timezone.utc).isoformat()
        if state.get('cursor'): query['pageCursor']=state['cursor']
        query['includeDeleted']='true'
        request=urllib.request.Request('https://readwise.io/api/v2/export/?'+urllib.parse.urlencode(query),headers={'Authorization':'Token '+token})
        previous_counts=(state['imported'],state['processed'])
        try:
            with urllib.request.urlopen(request,timeout=30) as response:
                content=response.read(20_000_001)
                if len(content)>20_000_000: raise ValueError('Readwise page is too large')
                page=json.loads(content)
            if not isinstance(page,dict) or not isinstance(page.get('results'),list): raise ValueError('Invalid response')
            cursor=page.get('nextPageCursor')
            if cursor is not None and (not isinstance(cursor,str) or not cursor or cursor==state.get('cursor')):
                raise ValueError('Invalid export cursor')
            # No changes to highlights or cursor survive a malformed/failed page.
            self.db.execute('SAVEPOINT readwise_page')
            for book in page['results']:
                if not isinstance(book,dict) or not book.get('user_book_id'):
                    raise ValueError('Invalid book')
                book_id=str(book['user_book_id'])
                if book.get('is_deleted'):
                    for item in self.items():
                        if item['source']=='Readwise' and item.get('sourceBookId')==book_id: self.archive_readwise(item)
                    continue
                if not isinstance(book.get('highlights'),list): raise ValueError('Invalid highlights')
                for highlight in book['highlights']:
                    if not isinstance(highlight,dict) or not highlight.get('id'): raise ValueError('Invalid highlight')
                    source_id=str(highlight['id'])
                    identity=hashlib.sha256(json.dumps(['Readwise',source_id],sort_keys=True,ensure_ascii=False).encode()).hexdigest()
                    prior=self.db.execute('SELECT value FROM highlights WHERE identity=?',(identity,)).fetchone()
                    existing=json.loads(prior[0]) if prior else None
                    if not existing and highlight.get('external_id'):
                        # Upgrade an old Reader import only with an exact provider ID.
                        legacy=[x for x in self.items() if x['source']=='Readwise Reader' and x['sourceId']==str(highlight['external_id'])]
                        if len(legacy)==1:
                            existing={**legacy[0],'source':'Readwise','sourceId':source_id,'sourceBookId':book_id}
                            self.db.execute('UPDATE highlights SET identity=?,value=? WHERE id=?',
                                            (identity,json.dumps(existing,ensure_ascii=False),existing['id']))
                    if highlight.get('is_deleted'):
                        if existing: self.archive_readwise(existing)
                        continue
                    if not compact(highlight.get('text')): raise ValueError('Empty highlight')
                    def tags(rows):
                        if not isinstance(rows,list): raise ValueError('Invalid tags')
                        return [r.get('name','') if isinstance(r,dict) else str(r) for r in rows]
                    raw={'source':'Readwise','sourceId':source_id,'sourceBookId':book_id,
                         'sourceCategory':book.get('category',''),'origin':book.get('source',''),
                         'title':book.get('title') or book.get('readable_title') or 'Untitled', 'author':book.get('author') or '',
                         'text':highlight['text'],'note':highlight.get('note') or '',
                         'tags':tags(book.get('book_tags') or [])+tags(highlight.get('tags') or []),
                         'favorite':highlight.get('is_favorite') is True,'color':highlight.get('color'),
                         'document':highlight.get('readwise_url') or 'https://readwise.io/open/'+urllib.parse.quote(source_id,safe=''),
                         'chapter':str(highlight.get('location') or '')}
                    date=highlight.get('highlighted_at') or highlight.get('created_at')
                    if date:
                        raw['createdAt']=int(datetime.fromisoformat(date.replace('Z','+00:00')).timestamp())
                    clean=existing and existing['note']==existing.get('sourceNote','') and existing['text']==existing.get('sourceText',existing['text'])
                    if existing and clean:
                        raw={**existing,**raw,'favorite':existing['favorite'],'tags':list(dict.fromkeys(existing['tags']+raw['tags'])),
                             'archived':existing['archived'],'bookId':existing['bookId'],
                             'sourceText':raw['text'],'sourceNote':raw['note']}
                        # Do not take the generic import's identical-ID early return.
                        raw.pop('id',None)
                    _,created=self.put(raw,overwrite=bool(clean),commit=False)
                    state['imported']+=int(created); state['processed']+=1
            state.update(cursor=cursor,inProgress=bool(cursor),failures=0,
                         nextAt=now()+4 if cursor else now()+900,
                         message='Importing Readwise library…' if cursor else 'Readwise library is up to date.')
            if not cursor: state['lastSuccess']=state.pop('startedAt')
            self.save_readwise_state(state)
            self.db.execute('RELEASE readwise_page'); self.db.commit()
            return {'readwiseMore':bool(cursor)}
        except Exception as error:
            self.db.rollback()
            state['imported'],state['processed']=previous_counts
            state['failures']=state.get('failures',0)+1
            delay=min(3600,60*2**min(state['failures']-1,6))
            if isinstance(error,urllib.error.HTTPError):
                if error.code in (401,403):
                    delay=86400; message='Reconnect Readwise: the saved token was rejected.'
                elif error.code==429:
                    try: delay=max(delay,min(86400,int((error.headers or {}).get('Retry-After','60'))))
                    except (ValueError,TypeError): pass
                    message='Readwise is busy. Shelf will retry automatically.'
                else: message='Readwise is temporarily unavailable. Shelf will retry automatically.'
            elif isinstance(error,(OSError,ValueError,KeyError,TypeError,OverflowError)):
                message='Readwise import could not finish. Saved highlights are safe; Shelf will retry.'
            else: raise
            state.update(nextAt=now()+delay,message=message)
            self.save_readwise_state(state); self.db.commit()
            return {'readwiseError':message}

    def archive_readwise(self,item):
        item.update(archived=True,remoteDeleted=True,updatedAt=now())
        self.db.execute('UPDATE highlights SET value=? WHERE id=?',(json.dumps(item,ensure_ascii=False),item['id']))

    def sync(self, credentials, automatic=False):
        s=self.settings()
        if automatic and not s['autoSync']: return
        for job in [j for j in self.queue() if j['status'] in ('pending','failed') and j['next_at']<=now()][:5]:
            if job['destination'] in s['paused'] or not s['destinations'][job['destination']]: continue
            if job['status'] not in ('pending','failed') or job['next_at']>now(): continue
            item=next((x for x in self.items() if x['id']==job['highlight']),None)
            if not item or item['archived']: continue
            dest=job['destination']
            if not credentials.get('token') and dest!='crosspoint': continue
            if dest=='crosspoint' and not credentials.get('syncKey'): continue
            with self.db:
                claimed=self.db.execute("UPDATE queue SET status='sending',updated=? WHERE id=? AND status IN ('pending','failed')",(now(),job['id'])).rowcount
            if not claimed: continue
            status='sent'; message='Sent'; delay=0
            try:
                if dest=='readwise':
                    payload={'highlights':[{'text':item['text'],'title':item['title'],'author':item['author'], 'note':item['note'], 'source_type':'shelf','category':'books', 'highlight_url':'shelf://highlight/'+item['id']} ]}
                    request=urllib.request.Request('https://readwise.io/api/v2/highlights/',data=json.dumps(payload).encode(),headers={'Authorization':'Token '+credentials['token'],'Content-Type':'application/json'},method='POST')
                    with urllib.request.urlopen(request,timeout=25) as response:
                        if response.status not in (200,201): raise ValueError('Unexpected service response')
                elif dest=='reader':
                    from readwise_reader_sync import create_highlight
                    if not create_highlight(credentials['token'],item['title'],item['author'],item['text'],item['note'],item['tags']).get('created'):
                        raise ValueError('Reader did not confirm creation')
                else:
                    loc=item['location']; document=loc.get('document','')
                    if not re.fullmatch(r'[a-fA-F0-9]{32}',document): raise ValueError('This passage has no device file fingerprint')
                    clip={'id':item['id'],'text':item['text'],'note':item['note'],'chapter':loc.get('chapter',''),'color':item['color'],'created_at':item['createdAt'],'start_page':loc.get('page',1),'end_page':loc.get('page',1),'spine':loc.get('chapterIndex',0),'start_offset':loc.get('start'),'end_offset':loc.get('end')}
                    request=urllib.request.Request(credentials['crosspoint'].rstrip('/')+'/clippings/'+document,data=json.dumps({'items':[clip]}).encode(),headers={'Content-Type':'application/json','x-auth-user':credentials['username'],'x-auth-key':credentials['syncKey'],'Accept':'application/vnd.koreader.v1+json'},method='PUT')
                    with urllib.request.urlopen(request,timeout=25) as response:
                        if response.status not in (200,201,204): raise ValueError('Unexpected device response')
            except urllib.error.HTTPError as e:
                status='failed' if e.code in (401,403,429) else 'uncertain'
                message=f'HTTP {e.code}. '+('Reconnect this service.' if e.code in (401,403) else 'Check the destination before retrying.' if status=='uncertain' else 'Rate limited; retry later.')
                delay=min(86400,60*2**min(job['attempts'],10))
            except (OSError,ValueError,RuntimeError):
                # A lost response may follow a successful non-idempotent POST.
                status='uncertain'; message='Upload not confirmed. Check the destination before retrying.'
            with self.db:
                self.db.execute('UPDATE queue SET status=?,message=?,attempts=attempts+1,next_at=?,updated=? WHERE id=?',(status,message,now()+delay,now(),job['id']))


def parse_import(content, kind):
    if len(content)>20_000_000: raise ValueError('Import is larger than 20 MB')
    if kind in ('json','backup','koreader'):
        value=json.loads(content)
        if isinstance(value,dict) and 'highlights' in value: value=value['highlights']
        if isinstance(value,dict) and 'entries' in value:
            value=[{'title':value.get('title','Untitled'),'author':value.get('author',''),**entry} for entry in value['entries'] if isinstance(entry,dict)]
        if isinstance(value,dict):
            # KOReader JSON exporter groups entries under a book title.
            value=[{**item,'title':title,'source':'KOReader'} for title,entries in value.items() if isinstance(entries,list) for item in entries if isinstance(item,dict)]
        if not isinstance(value,list): raise ValueError('Expected a list of highlights')
        result=[]
        for raw in value:
            if not isinstance(raw,dict): raise ValueError('Invalid highlight record')
            loc=raw.get('location') if isinstance(raw.get('location'),dict) else {}
            result.append({**raw,**loc,'text':raw.get('text') or raw.get('highlight') or '', 'source':raw.get('source') or ('KOReader' if kind=='koreader' else 'Imported'), 'sourceId':raw.get('sourceId',raw.get('id') or raw.get('uuid') or ''), 'note':raw.get('note') or raw.get('notes') or ''})
        return [x for x in result if compact(x.get('text'))]
    if kind=='csv': return [dict(row,source=row.get('source') or 'CSV') for row in csv.DictReader(io.StringIO(content)) if row.get('text')]
    if kind=='kindle':
        result=[]
        for block in content.split('=========='):
            lines=block.strip().splitlines()
            if len(lines)<3 or not re.search(r'highlight|markierung|ハイライト',lines[1],re.I): continue
            title,author=lines[0],''
            match=re.match(r'^(.*?)\s*\(([^()]*)\)\s*$',title)
            if match: title,author=match.groups()
            passage='\n'.join(lines[2:]).strip()
            result.append({'text':passage,'title':title,'author':author,'source':'Kindle','chapter':lines[1]})
        return result
    raise ValueError('Unsupported import format')


def export_items(items, settings, kind):
    if kind=='json':
        rows=[{**x,'note':x['note'] if settings['exportNotes'] else '', 'tags':x['tags'] if settings['exportTags'] else [],'location':x['location'] if settings['exportLocation'] else {}} for x in items]
        return json.dumps({'version':1,'highlights':rows},ensure_ascii=False,indent=2)
    if kind=='csv':
        stream=io.StringIO(); fields=['id','source','sourceId','bookId','title','author','text','note','tags','chapter','percentage','createdAt']
        writer=csv.DictWriter(stream,fieldnames=fields); writer.writeheader()
        for item in items:
            row={k:item.get(k,'') for k in fields}; row['tags']=','.join(item['tags']) if settings['exportTags'] else ''; row['note']=item['note'] if settings['exportNotes'] else ''
            row['chapter']=item['location'].get('chapter','') if settings['exportLocation'] else ''; row['percentage']=item['location'].get('percentage','') if settings['exportLocation'] else ''; writer.writerow(row)
        return stream.getvalue()
    if kind!='markdown': raise ValueError('Unsupported export format')
    books={}
    for item in items: books.setdefault((item['title'],item['author']),[]).append(item)
    result=[]
    for (title,author),rows in books.items():
        highlights=[]
        for x in rows:
            part='> '+x['text'].replace('\n','\n> ')
            if settings['exportNotes'] and x['note']: part+='\n\n'+x['note']
            if settings['exportTags'] and x['tags']: part+='\n\nTags: '+', '.join(x['tags'])
            if settings['exportLocation']:
                loc=x['location']; part+='\n\nSource: '+x['source']+(' · '+str(loc['chapter']) if loc.get('chapter') else '')+' · shelf://highlight/'+x['id']
            highlights.append(part)
        # Literal replacement only: no evaluation of user template code.
        template=settings['exportTemplate']
        for k,v in {'title':title,'author':author,'highlights':'\n\n---\n\n'.join(highlights),'date':datetime.now().date().isoformat()}.items(): template=template.replace('{'+k+'}',v)
        result.append(template)
    return '\n\n'.join(result)


def apple_books_annotations(roots=None, catalogs=None):
    """Read a supported Apple Books annotation schema; never write to Apple's DBs."""
    from apple_books import candidate_databases, read_database
    if catalogs is None:
        paths,denied=candidate_databases()
        if denied and not paths: raise ValueError('Allow Shelf to read Apple Books in macOS privacy settings, then reopen Books and Shelf')
        catalogs={}
        for path in paths:
            data=read_database(path) or {}
            for book in data.get('books',[]):
                for key in ('assetId','guid'):
                    if book.get(key): catalogs[str(book[key])]=book
    if roots is None:
        roots=[Path.home()/'Library/Containers/com.apple.iBooksX/Data/Documents/AEAnnotation',Path.home()/'Library/Group Containers/group.com.apple.iBooks/AEAnnotation']
    result=[]; denied=False; supported=False
    for root in roots:
        try: paths=list(Path(root).glob('*.sqlite'))
        except PermissionError: denied=True; continue
        for path in paths:
            try:
                conn=sqlite3.connect(path.resolve().as_uri()+'?mode=ro',uri=True,timeout=2)
                conn.row_factory=sqlite3.Row
                try:
                    conn.execute('PRAGMA query_only=ON')
                    cols={r[1] for r in conn.execute('PRAGMA table_info(ZAEANNOTATION)')}
                    if not {'ZANNOTATIONSELECTEDTEXT','ZANNOTATIONASSETID','ZANNOTATIONUUID'}.issubset(cols): continue
                    supported=True
                    for row in conn.execute('SELECT * FROM ZAEANNOTATION'):
                        r=dict(row)
                        if not compact(r.get('ZANNOTATIONSELECTEDTEXT')) or r.get('ZANNOTATIONDELETED'): continue
                        book=catalogs.get(str(r['ZANNOTATIONASSETID']),{})
                        result.append({'text':r['ZANNOTATIONSELECTEDTEXT'],'note':r.get('ZANNOTATIONNOTE') or '',
                                       'source':'Apple Books','sourceId':str(r['ZANNOTATIONUUID']),
                                       'title':book.get('title') or 'Apple Books title','author':book.get('author') or '',
                                       'chapter':r.get('ZANNOTATIONREPRESENTATIVELOCATION') or ''})
                finally: conn.close()
            except (PermissionError,sqlite3.OperationalError): denied=True
    if not supported: raise ValueError('Apple Books annotation database is unavailable, access is denied, or this schema is unsupported. Open Books to sync first; PDF markings may not be available.')
    return result


def dispatch(lib, p):
    action=p.get('action','list'); result={}
    if action=='add': result['item'],result['added']=lib.put(p['item'],enqueue=True)
    elif action=='edit': result['item']=lib.update(p['id'],p.get('changes',{}))
    elif action=='migrate':
        for book,items in p.get('legacy',{}).items():
            for item in items:
                lib.put({**item,**item.get('location',{}),'bookId':int(book),'sourceId':item.get('id',''),'source':item.get('source') or ('Shelf' if str(item.get('id','')).startswith('shelf-') else 'Readwise Reader'),'title':item.get('title') or 'Book '+book})
    elif action in ('previewImport','import'):
        items=parse_import(p['content'],p.get('format','json'))
        result={'preview':items[:100],'total':len(items)}
        if action=='import':
            added=0
            # Atomic import: malformed records cannot leave a half-imported collection.
            lib.db.execute('SAVEPOINT import_batch')
            try:
                for item in items:
                    if p.get('bookId'): item['bookId']=int(p['bookId'])
                    _,created=lib.put(item,commit=False); added+=created
            except Exception:
                lib.db.rollback(); raise
            lib.db.execute('RELEASE import_batch'); lib.db.commit()
            result['added']=added
    elif action=='previewAppleBooks':
        entries=apple_books_annotations()
        result={'preview':entries[:100],'total':len(entries),'importContent':json.dumps(entries,ensure_ascii=False)}
    elif action=='settings': lib.save_settings(p.get('values',{}))
    elif action=='collection': lib.collection(p['name'],p.get('rules',{}),p.get('id'),p.get('pinned',True))
    elif action=='deleteCollection':
        with lib.db: lib.db.execute('DELETE FROM collections WHERE id=?',(p['id'],))
    elif action=='resolve': lib.resolve(p['id'],p.get('accept') is True)
    elif action=='reviewed': lib.reviewed(p['id'],p.get('days',7))
    elif action=='enqueue': lib.enqueue(p['id'],p.get('destination'))
    elif action=='retry':
        with lib.db: lib.db.execute("UPDATE queue SET status='pending',next_at=0,updated=? WHERE id=? AND status!='sending'",(now(),p['id']))
    elif action=='sync': lib.sync(p.get('credentials',{}),p.get('automatic',False))
    elif action=='importReadwise': result=lib.import_readwise(p.get('credentials',{}).get('token',''),p.get('automatic',False))
    elif action in ('export','exportPreview'): result['content']=export_items(lib.filter(p.get('rules')),lib.settings(),p.get('format','markdown'))
    elif action=='bookMetadata':
        for item in lib.items():
            if item['bookId']==int(p['bookId']) and item['title']=='Book '+str(p['bookId']):
                item['title']=text(p.get('title'),500); item['author']=text(p.get('author'),500)
                lib.db.execute('UPDATE highlights SET value=? WHERE id=?',(json.dumps(item),item['id']))
        lib.db.commit()
    elif action=='backup':
        from shelf_studio import Studio
        result['content']=json.dumps({'version':1,'highlights':lib.items(),'settings':lib.settings(),'collections':lib.collections(),'studio':Studio(lib).backup()},ensure_ascii=False,indent=2)
        if len(result['content'].encode())>20_000_000: raise ValueError('Backup exceeds 20 MB. Export large captures separately before creating a portable backup.')
    elif action=='restore':
        data=json.loads(p['content'])
        if data.get('version')!=1 or not isinstance(data.get('highlights'),list): raise ValueError('Not a Shelf annotation backup')
        studio=None
        if 'studio' in data:
            from shelf_studio import Studio
            studio=Studio(lib)
        lib.db.execute('SAVEPOINT restore_backup'); lib.batch=True
        try:
            for item in parse_import(p['content'],'backup'): lib.put(item)
            # Merge only; never restore secrets, upload jobs, or delete current data.
            for c in data.get('collections',[]): lib.collection(c['name'],c['rules'],c.get('id'),c.get('pinned',True))
            lib.save_settings(data.get('settings',{}))
            if studio: studio.restore(data['studio'])
            lib.db.execute('RELEASE restore_backup'); lib.db.commit()
        except Exception:
            lib.db.rollback(); raise
        finally: lib.batch=False
    elif action!='list': raise ValueError('Unknown annotation action')
    return {'ok':True,**result,'readwiseSync':lib.readwise_status(),'items':lib.filter({'archived':True} if p.get('all') else p.get('rules')),'settings':lib.settings(),'collections':lib.collections(),'review':lib.review(),'queue':lib.queue(),'conflicts':lib.conflicts()}


def main():
    try:
        os.umask(0o077)
        payload=json.load(sys.stdin)
        library=Library()
        try: result=dispatch(library,payload)
        finally: library.db.close()
        print(json.dumps(result,ensure_ascii=False,allow_nan=False))
        return 0
    except (OSError,ValueError,TypeError,KeyError,sqlite3.Error) as e:
        print(json.dumps({'ok':False,'error':'Annotation operation failed: '+str(e)[:250]})); return 1

if __name__=='__main__': sys.exit(main())
