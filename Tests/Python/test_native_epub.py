import sys
import tempfile
from pathlib import Path
import unittest
import zipfile
import xml.etree.ElementTree as ET
import json

sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'Sources/ShelfCore/Tools'))
from epub_native import prepare_epub,resolve

class NativeEpubTests(unittest.TestCase):
    def make(self,root,unsafe=False):
        source=root/'book.epub'
        files={
         'META-INF/container.xml':'<container><rootfiles><rootfile full-path="EPUB/book.opf"/></rootfiles></container>',
         'EPUB/book.opf':'<package><metadata><title>日本語</title></metadata><manifest><item id="b" href="two.xhtml" media-type="application/xhtml+xml"/><item id="a" href="one.xhtml" media-type="application/xhtml+xml"/><item id="n" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>',
         'EPUB/nav.xhtml':'<html xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="two.xhtml#c">第二章</a></li><li><a href="one.xhtml#c">第一章</a></li></ol></nav></body></html>',
         'EPUB/one.xhtml':'<html><body><h1 id="c">First</h1><script>bad()</script><p onclick="bad()">Text<a href="two.xhtml#c">Next</a><a href="#c">Here</a><img src="img.jpg"/></p></body></html>',
         'EPUB/two.xhtml':'<html><body><h1 id="c">Second</h1></body></html>'}
        if unsafe:files['../escape.txt']='bad'
        with zipfile.ZipFile(source,'w') as z:
            for name,content in files.items():z.writestr(name,content)
        return source
    def test_spine_order_unique_anchors_navigation_and_script_removal(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);source=self.make(root);original=source.read_bytes()
            result=prepare_epub(source,root/'out');text=result.read_text()
            toc=json.loads((root/'out/chapters.json').read_text())
            self.assertEqual([r['title'] for r in toc],['第一章','第二章'])
            self.assertLess(text.index('First'),text.index('Second'))
            self.assertNotIn('<script',text);self.assertNotIn('onclick',text)
            self.assertIn('href="#shelf-spine-1--c"',text)
            self.assertIn('href="#shelf-spine-0--c"',text)
            self.assertIn('book/EPUB/img.jpg',text)
            self.assertEqual(source.read_bytes(),original)
    def test_archive_traversal_is_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            with self.assertRaises(ValueError):prepare_epub(self.make(root,True),root/'out')
            self.assertFalse((root/'escape.txt').exists())

class AppleDateTests(unittest.TestCase):
    def test_modern_core_data_dates_are_not_mistaken_for_unix_dates(self):
        from apple_books import core_date
        self.assertTrue(core_date(815184000).startswith('2026-'))
