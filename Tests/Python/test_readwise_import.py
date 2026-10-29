"""Readwise export fixtures: actual SQLite, no account data or live API access."""
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import urllib.error
import urllib.parse
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'Sources/ShelfCore/Tools'))
import shelf_annotations as annotations


def book(identity=1, **changes):
    return {'user_book_id':identity,'title':'Article outside Calibre','author':'Author','category':'articles',
            'source':'reader','highlights':[{'id':identity*100,'text':'My saved passage','note':'Source note',
              'tags':[{'name':'research'}],'highlighted_at':'2026-10-28T12:00:00Z'}],**changes}


def response(books, cursor=None):
    return io.BytesIO(json.dumps({'results':books,'nextPageCursor':cursor}).encode())


class ReadwiseImportTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path=Path(self.temp.name)/'annotations.sqlite'
        self.lib=annotations.Library(self.path); self.addCleanup(lambda:self.lib.db.close())
        self.clock=patch.object(annotations,'now',return_value=2000000000)
        self.time=self.clock.start(); self.addCleanup(self.clock.stop)

    def pull(self, page, **kwargs):
        with patch.object(annotations.urllib.request,'urlopen',return_value=page) as fetch:
            result=self.lib.import_readwise('test-only-token',**kwargs)
        return result,fetch

    def test_all_sources_import_without_local_books_and_never_upload(self):
        self.lib.save_settings({'destinations':{'readwise':True}})
        self.pull(response([book(1),book(2,source='kindle',category='books')]))
        rows=self.lib.items()
        self.assertEqual(len(rows),2)
        self.assertTrue(all(x['bookId']==0 for x in rows))
        self.assertEqual({x['origin'] for x in rows},{'reader','kindle'})
        self.assertEqual(rows[0]['tags'],['research'])
        self.assertEqual(rows[0]['location']['document'],'https://readwise.io/open/100')
        self.assertEqual(self.lib.queue(),[])

    def test_pages_resume_after_restart_and_checkpoint_only_on_completion(self):
        result,_=self.pull(response([book(1)],'opaque-cursor'))
        self.assertTrue(result['readwiseMore'])
        self.assertNotIn('lastSuccess',self.lib.readwise_status())
        self.lib.db.close(); self.lib=annotations.Library(self.path)
        self.time.return_value+=5
        _,fetch=self.pull(response([book(2)]),automatic=True)
        query=urllib.parse.parse_qs(urllib.parse.urlsplit(fetch.call_args.args[0].full_url).query)
        self.assertEqual(query['pageCursor'],['opaque-cursor'])
        self.assertNotIn('updatedAfter',query)
        self.assertEqual(self.lib.readwise_status()['lastSuccess'],2000000000)
        self.assertEqual(self.lib.readwise_status()['imported'],2)

    def test_incremental_sync_uses_start_watermark_and_is_idempotent(self):
        self.pull(response([book()]))
        self.time.return_value+=901
        _,fetch=self.pull(response([book()]),automatic=True)
        url=fetch.call_args.args[0].full_url
        self.assertIn('updatedAfter=',url)
        self.assertNotIn('test-only-token',url)
        self.assertEqual(len(self.lib.items()),1)
        self.assertEqual(self.lib.readwise_status()['imported'],0)

    def test_remote_edit_updates_unmodified_notes_but_preserves_local_changes(self):
        self.pull(response([book()]))
        self.time.return_value+=901
        updated=book(highlights=[{'id':100,'text':'Updated passage','note':'Updated note'}])
        self.pull(response([updated]))
        item=self.lib.items()[0]
        self.assertEqual(item['text'],'Updated passage')
        self.assertEqual(item['note'],'Updated note')
        self.lib.update(item['id'],{'note':'My private note','favorite':True})
        updated['highlights'][0]['note']='Another remote note'
        self.time.return_value+=901
        self.pull(response([updated]))
        self.assertEqual(self.lib.items()[0]['note'],'My private note')
        self.assertTrue(self.lib.items()[0]['favorite'])
        self.assertEqual(len(self.lib.conflicts()),1)

    def test_malformed_page_rolls_back_items_counts_and_cursor(self):
        result,_=self.pull(response([book(),book(2,highlights=[{'id':200,'text':''}])],'next'))
        self.assertIn('readwiseError',result)
        self.assertEqual(self.lib.items(),[])
        state=self.lib.readwise_state()
        self.assertEqual(state['imported'],0)
        self.assertIsNone(state.get('cursor'))
        self.assertNotIn('lastSuccess',state)

    def test_existing_reader_highlight_is_upgraded_by_exact_external_id(self):
        item,_=self.lib.put({'source':'Readwise Reader','sourceId':'reader-id','text':'My saved passage',
                            'title':'Old title','note':'Source note','bookId':7})
        self.lib.update(item['id'],{'note':'Keep my local note'})
        self.pull(response([book(highlights=[{'id':100,'external_id':'reader-id','text':'My saved passage','note':'Source note'}])]))
        rows=self.lib.items()
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]['id'],item['id'])
        self.assertEqual(rows[0]['bookId'],7)
        self.assertEqual(rows[0]['note'],'Keep my local note')
        self.assertEqual(rows[0]['source'],'Readwise')

    def test_rate_limit_persists_backoff_and_never_exposes_response(self):
        error=urllib.error.HTTPError('https://readwise.io/',429,'private provider message',{'Retry-After':'120'},io.BytesIO(b'secret'))
        with patch.object(annotations.urllib.request,'urlopen',side_effect=error):
            result=self.lib.import_readwise('test-only-token')
        self.assertNotIn('private',json.dumps(result))
        self.assertEqual(self.lib.readwise_status()['nextAt'],self.time.return_value+120)
        with patch.object(annotations.urllib.request,'urlopen') as fetch:
            self.assertTrue(self.lib.import_readwise('test-only-token')['readwiseWaiting'])
            fetch.assert_not_called()

    def test_remote_deletions_archive_instead_of_destroying_notes(self):
        self.pull(response([book()]))
        item=self.lib.items()[0]; self.lib.update(item['id'],{'note':'Keep me'})
        self.time.return_value+=901
        self.pull(response([{'user_book_id':1,'is_deleted':True}]))
        item=self.lib.items()[0]
        self.assertTrue(item['archived']); self.assertTrue(item['remoteDeleted'])
        self.assertEqual(item['note'],'Keep me')

    def test_automatic_pause_and_poll_interval_make_no_requests(self):
        self.lib.save_settings({'readwiseAutoImport':False})
        with patch.object(annotations.urllib.request,'urlopen') as fetch:
            self.lib.import_readwise('test-only-token',automatic=True)
            fetch.assert_not_called()
        self.pull(response([book()]))
        with patch.object(annotations.urllib.request,'urlopen') as fetch:
            self.lib.import_readwise('test-only-token',automatic=True)
            fetch.assert_not_called()

    def test_portable_backup_contains_highlights_but_no_sync_credentials(self):
        self.pull(response([book()]))
        value=annotations.dispatch(self.lib,{'action':'backup'})['content']
        self.assertNotIn('test-only-token',value)
        self.assertNotIn('accountKey',value)
        status=json.dumps(self.lib.readwise_status())
        self.assertNotIn('accountKey',status)
        self.assertEqual(len(json.loads(value)['highlights']),1)


if __name__=='__main__': unittest.main()
