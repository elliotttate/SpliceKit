import hashlib
from contextlib import closing
from pathlib import Path
import plistlib
import shutil
import sqlite3
import tempfile
import unittest

from tests.live.sqlite_diff import compare_trees, unarchive


class SQLiteEvidenceTests(unittest.TestCase):
    def test_only_changed_rows_columns_and_decoded_cache_are_reported_without_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);before=root/'before';after=root/'after';before.mkdir();after.mkdir()
            a=before/'CurrentVersion.fcpevent';b=after/a.name
            with closing(sqlite3.connect(a)) as db, db:
                db.execute('CREATE TABLE state (id INTEGER PRIMARY KEY, Z_OPT INTEGER, ZDICTIONARYDATA BLOB, content TEXT)')
                db.execute('INSERT INTO state VALUES (1,1,?,?)',(plistlib.dumps({'cache':'old'},fmt=plistlib.FMT_BINARY),'unchanged timeline'))
            shutil.copy2(a,b)
            with closing(sqlite3.connect(b)) as db, db:
                db.execute('UPDATE state SET Z_OPT=2,ZDICTIONARYDATA=? WHERE id=1',(plistlib.dumps({'cache':'new'},fmt=plistlib.FMT_BINARY),))
                db.execute('INSERT INTO state VALUES (2,1,NULL,?)',('new record',))
            hashes=lambda:[hashlib.sha256(p.read_bytes()).hexdigest() for p in (a,b)]
            original=hashes();report=compare_trees(before,after);self.assertEqual(original,hashes())
            rows=report[0]['tables']['state']['changed_rows']
            self.assertEqual(set(rows[0]['columns']),{'Z_OPT','ZDICTIONARYDATA'})
            self.assertEqual(rows[0]['columns']['ZDICTIONARYDATA']['decoded_changes'],[{'path':'/cache','before':'old','after':'new'}])
            self.assertEqual(rows[1],{'rowid':2,'kind':'inserted'})

    def test_keyed_archive_dictionary_is_resolved_by_keys_not_object_indices(self):
        value={'$archiver':'NSKeyedArchiver','$version':100000,
               '$top':{'root':plistlib.UID(1)},
               '$objects':['$null',{'NS.keys':[plistlib.UID(2)],'NS.objects':[plistlib.UID(3)]},'defaults',{'persistentPlayheadTime':{'value':0,'timescale':1}}]}
        self.assertEqual(unarchive(plistlib.dumps(value,fmt=plistlib.FMT_BINARY)),{'defaults':{'persistentPlayheadTime':{'value':0,'timescale':1}}})
