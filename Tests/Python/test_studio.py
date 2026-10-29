"""Studio tests use fixtures, never user accounts, private audio, or external AI."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

TOOLS=Path(__file__).resolve().parents[2]/'Sources/ShelfCore/Tools'
sys.path.insert(0,str(TOOLS))
from shelf_annotations import Library, dispatch as annotation_dispatch
import shelf_studio as studio


class StudioTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.path=Path(self.temp.name)/'a.sqlite';self.lib=Library(self.path)
        self.addCleanup(lambda:self.lib.db.close());self.s=studio.Studio(self.lib)

    def add(self,**values):
        return self.lib.put({'text':'Reading habits improve with daily practice.','title':'Reading','source':'Shelf','note':'My personal note',**values})[0]

    def notion_setup(self):
        self.add();self.s.settings({'notionParent':'12345678-1234-1234-1234-123456789abc'})

    def test_notion_plan_has_bounded_batches_and_preserves_text(self):
        self.notion_setup()
        for i in range(45):self.add(text='Passage '+str(i),note='N'*5000)
        plan=self.s.notion_plan({})
        self.assertGreater(len(plan['pages']),1)
        for page in plan['pages']:
            self.assertLessEqual(len(page['payload']['children']),90)
            self.assertLess(len(json.dumps(page['payload']).encode()),500000)
            for block in page['payload']['children']:
                for part in block[block['type']]['rich_text']: self.assertLessEqual(len(part['text']['content']),2000)

    def test_notion_requires_consent_and_frozen_preview(self):
        self.notion_setup();plan=self.s.notion_plan({})
        with patch.object(studio,'http_json') as network:
            with self.assertRaises(ValueError):self.s.notion_export({},'token',False)
            with self.assertRaises(ValueError):self.s.notion_export({},'token',True,expected=['outdated'])
            self.assertEqual(network.call_count,0)

    def test_notion_sent_receipts_prevent_duplicates_and_do_not_store_token(self):
        self.notion_setup()
        with patch.object(studio,'http_json',return_value={'id':'12345678-0000-0000-0000-123456789abc'}) as network:
            first=self.s.notion_export({},'private-notion-token',True)
            second=self.s.notion_export({},'private-notion-token',True)
            self.assertEqual(network.call_count,1)
        self.assertEqual(first[0]['status'],'sent');self.assertEqual(second[0]['status'],'sent')
        self.assertNotIn(b'private-notion-token',self.path.read_bytes())

    def test_notion_lost_response_does_not_auto_repeat(self):
        self.notion_setup()
        with patch.object(studio,'http_json',side_effect=studio.ServiceError('Connection lost')) as network:
            self.assertEqual(self.s.notion_export({},'token',True)[0]['status'],'uncertain')
            self.s.notion_export({},'token',True)
            self.assertEqual(network.call_count,1)

    def test_notion_access_denial_is_failed_not_sent(self):
        self.notion_setup()
        with patch.object(studio,'http_json',side_effect=studio.ServiceError('HTTP 403',403)):
            self.assertEqual(self.s.notion_export({},'token',True)[0]['status'],'failed')

    def test_capture_is_persistent_and_excerpt_keeps_time(self):
        capture=self.s.capture('Podcast','Episode',[{'text':'A transcript','start':63.5,'end':70}])
        self.assertEqual(self.s.capture('Podcast','Episode',capture['segments'])['id'],capture['id'])
        item=self.s.excerpt(capture['id'],0,'A transcript','note',['podcast'])
        self.assertEqual(item['location']['chapter'],'00:01:03')
        studio.dispatch(self.s,{'action':'deleteCapture','id':capture['id']})
        self.assertEqual(len(self.lib.items()),1)

    def test_transcript_import_handles_srt_vtt_and_ignores_markup(self):
        for content in ['1\n00:01:02,000 --> 00:01:04,250\nA passage\n','WEBVTT\n\n00:01:02.000 --> 00:01:04.250\n<i>A passage</i>\n']:
            parts=studio.import_transcript(content,'srt')
            self.assertEqual(parts[0]['start'],62);self.assertEqual(parts[0]['text'],'A passage')

    def test_retrieval_excludes_archives_and_stays_within_collection(self):
        self.add(tags=['reading']);archived=self.add(text='Reading secret',tags=['reading'])
        self.lib.update(archived['id'],{'archived':True})
        self.add(text='Reading outside scope',tags=['other'])
        result=self.s.retrieval('reading',{'tag':'reading'})
        self.assertEqual(len(result),1);self.assertNotIn('secret',result[0]['text'])

    def test_japanese_retrieval_works_without_spaces(self):
        self.add(text='読書は毎日の習慣です。',title='日本語')
        self.assertEqual(len(self.s.retrieval('読書')),1)

    def test_cloud_chat_requires_consent_and_does_not_leak_unrelated_notes(self):
        self.add(tags=['scope']);self.add(text='Other reading passage',note='unrelated private note',tags=['outside'])
        self.s.settings({'chatProvider':'openai','chatModel':'gpt-4.1-mini'})
        with patch.object(studio,'http_json',return_value={'choices':[{'message':{'content':'Practice reading daily [H1].'}}]}) as network:
            with self.assertRaises(ValueError):self.s.chat('reading',{'tag':'scope'},'secret',False)
            self.assertEqual(network.call_count,0)
            result=self.s.chat('reading',{'tag':'scope'},'secret',True)
            body=network.call_args.args[0].data.decode()
            self.assertNotIn('unrelated private note',body)
            self.assertEqual(len(result['citations']),1)
        self.assertNotIn(b'secret',self.path.read_bytes())

    def test_unknown_model_citations_are_rejected_and_not_saved(self):
        self.add();self.s.settings({'chatProvider':'openai','chatModel':'gpt-4.1-mini'})
        with patch.object(studio,'http_json',return_value={'choices':[{'message':{'content':'Invented [H99]'}}]}):
            with self.assertRaises(ValueError):self.s.chat('reading',{},'token',True)
        self.assertEqual(self.s.history(),[])

    def test_uncited_model_answer_falls_back_to_evidence(self):
        self.add()
        with patch.object(studio,'http_json',return_value={'message':{'content':'An ungrounded answer'}}):
            result=self.s.chat('reading',{})
        self.assertIn('did not provide',result['answer']);self.assertTrue(result['citations'])

    def test_service_errors_never_echo_remote_body(self):
        error=urllib.error.HTTPError('https://api.notion.com',401,'Secret body',{},None)
        with patch.object(studio.urllib.request,'urlopen',side_effect=error):
            with self.assertRaises(studio.ServiceError) as caught:studio.http_json(object())
        self.assertNotIn('Secret body',str(caught.exception))

    def test_cloud_transcription_requires_consent_before_opening_audio(self):
        with patch.object(studio,'http_json') as network:
            with self.assertRaises(ValueError):studio.transcribe_cloud('/does/not/exist','token',False)
            self.assertEqual(network.call_count,0)

    def test_cloud_multipart_has_no_personal_filename_and_returns_segments(self):
        path=Path(self.temp.name)/'personal-secret-name.wav';path.write_bytes(b'RIFFtest')
        with patch.object(studio,'http_json',return_value={'segments':[{'text':'Hello','start':1,'end':2}]}) as network:
            result=studio.transcribe_cloud(path,'private-token',True)
            data=network.call_args.args[0].data
            self.assertNotIn(b'personal-secret-name',data)
            self.assertIn(b'filename="audio.wav"',data)
        self.assertEqual(result[0]['start'],1)

    def test_portable_backup_preserves_captures_chats_and_sent_notion_receipts(self):
        self.notion_setup()
        capture=self.s.capture('OCR','Page',[{'text':'A printed passage','page':1}])
        with patch.object(studio,'http_json',return_value={'message':{'content':'Practice daily [H1].'}}): self.s.chat('reading',{})
        with patch.object(studio,'http_json',return_value={'id':'12345678-0000-0000-0000-123456789abc'}): self.s.notion_export({},'private-token',True)
        backup=annotation_dispatch(self.lib,{'action':'backup'})['content']
        other=Library(Path(self.temp.name)/'other.sqlite')
        try:
            annotation_dispatch(other,{'action':'restore','content':backup})
            restored=studio.Studio(other)
            self.assertEqual(restored.get_capture(capture['id'])['segments'][0]['text'],'A printed passage')
            self.assertEqual(len(restored.history()),1)
            self.assertEqual(restored.notion_plan({})['pages'][0]['status'],'sent')
            self.assertNotIn('private-token',backup)
        finally:other.db.close()

    def test_invalid_studio_backup_rolls_back_highlights_and_captures(self):
        backup=json.dumps({'version':1,'highlights':[{'text':'New'}],'studio':{'version':1,'captures':[{'id':'bad','kind':'OCR','title':'Bad','segments':[{'text':'bad'}]}]}})
        with self.assertRaises(ValueError):annotation_dispatch(self.lib,{'action':'restore','content':backup})
        self.assertEqual(self.lib.items(),[]);self.assertEqual(self.s.captures(),[])

    def test_local_processing_cancel_stops_child(self):
        flag=Path(self.temp.name)/'cancel';flag.touch()
        with self.assertRaises(ValueError):studio.run_local([sys.executable,'-c','import time;time.sleep(10)'],str(flag),timeout=5)

    @unittest.skipUnless(shutil.which('tesseract'),'Optional Tesseract binary is unavailable')
    def test_real_ocr_of_synthetic_fixture(self):
        try: from PIL import Image,ImageDraw,ImageFont
        except ImportError:self.skipTest('Pillow is unavailable for the synthetic test fixture')
        fontpath=Path('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf')
        if not fontpath.exists():self.skipTest('Test font unavailable')
        image=Image.new('RGB',(1100,180),'white');draw=ImageDraw.Draw(image)
        draw.text((30,50),'Shelf reading notes',font=ImageFont.truetype(str(fontpath),48),fill='black')
        path=Path(self.temp.name)/'fixture.png';image.save(path)
        self.assertIn('Shelf reading notes',studio.ocr_tesseract(path))

if __name__=='__main__':unittest.main()
