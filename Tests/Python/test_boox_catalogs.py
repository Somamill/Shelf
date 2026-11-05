import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TOOL = Path(__file__).resolve().parents[2]/'Sources/ShelfCore/Tools/boox_settings.py'
spec = importlib.util.spec_from_file_location('boox_catalog_settings', TOOL)
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)


class CatalogMigrationTests(unittest.TestCase):
    def test_network_change_deduplicates_and_preserves_other_catalogs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            existing, output = root/'existing', root/'output'
            existing.mkdir()
            servers = {
                1: {'title':'Calibre library', 'url':'http://192.168.0.123:8082/opds'},
                2: {'title':'Calibre Library', 'url':'http://10.0.1.97:8082/opds/'},
                3: {'title':'Other books', 'url':'https://example.org/catalog'},
            }
            settings.write_settings(existing/'opds.lua', {'servers':servers, 'downloads':{'keep':True}})
            settings.write_settings(existing/'settings.reader.lua', {'opds_servers':servers, 'font_size':24})
            values = {'opds_url':'http://10.0.1.97:8082/opds/', 'sync_url':'http://10.0.1.97:17200',
                      'username':'test-user', 'calibre_password':'test-password', 'kosync_userkey':'test-key'}
            for source in (existing, output):
                subprocess.run([sys.executable, str(TOOL), str(source), str(output)],
                               input=json.dumps(values), text=True, check=True, capture_output=True)
                opds = settings.read_settings(output/'opds.lua')
                legacy = settings.read_settings(output/'settings.reader.lua')
                for items in (opds['servers'], legacy['opds_servers']):
                    self.assertEqual(list(items), [1,2])
                    self.assertEqual(items[1]['url'], values['opds_url'])
                    self.assertEqual(items[2]['title'], 'Other books')
                self.assertEqual(legacy['font_size'],24)
                self.assertEqual(opds['downloads'],{'keep':True})


if __name__ == '__main__':
    unittest.main()
