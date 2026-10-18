"""Read-only row/column comparison of preserved CurrentVersion database trees."""
import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import plistlib
import sqlite3


def summary(value):
    if isinstance(value, bytes):
        return {'bytes':len(value), 'sha256':hashlib.sha256(value).hexdigest()}
    return value


def unarchive(data):
    archive = plistlib.loads(data)
    if not isinstance(archive,dict) or archive.get('$archiver') != 'NSKeyedArchiver':
        return archive
    objects = archive['$objects']
    def read(value, seen=()):
        if isinstance(value,plistlib.UID):
            index=value.data
            if index in seen:return {'cycle':index}
            return read(objects[index],(*seen,index))
        if isinstance(value,list):return [read(v,seen) for v in value]
        if isinstance(value,dict):
            if 'NS.keys' in value and 'NS.objects' in value:
                return dict(zip(read(value['NS.keys'],seen),read(value['NS.objects'],seen)))
            if set(value).issubset({'$class','NS.objects'}) and 'NS.objects' in value:
                return read(value['NS.objects'],seen)
            return {k:read(v,seen) for k,v in value.items() if k!='$class'}
        return value
    return read(archive['$top'].get('root',archive['$top']))


def changes(before, after, path=''):
    if type(before) is not type(after):return [{'path':path,'before':summary(before),'after':summary(after)}]
    if isinstance(before,dict):
        out=[]
        for key in sorted(set(before)|set(after)):
            if key not in before or key not in after:
                out.append({'path':path+'/'+str(key),'before':summary(before.get(key)),'after':summary(after.get(key))})
            else:out.extend(changes(before[key],after[key],path+'/'+str(key)))
        return out
    if isinstance(before,list):
        if len(before)!=len(after):return [{'path':path,'before_length':len(before),'after_length':len(after)}]
        return [c for i,(b,a) in enumerate(zip(before,after)) for c in changes(b,a,path+'/'+str(i))]
    return [] if before==after else [{'path':path,'before':summary(before),'after':summary(after)}]


def compare_sqlite(before,after):
    def connect(path):return sqlite3.connect(Path(path).resolve().as_uri()+'?mode=ro&immutable=1',uri=True)
    result={}
    with closing(connect(before)) as left,closing(connect(after)) as right:
        tables=lambda db:{n:s for n,s in db.execute("SELECT name,sql FROM sqlite_master WHERE type='table'")}
        a,b=tables(left),tables(right)
        for name in sorted(set(a)|set(b)):
            if a.get(name)!=b.get(name):
                result[name]={'schema_before':a.get(name),'schema_after':b.get(name)};continue
            quoted='"'+name.replace('"','""')+'"'
            cols=[r[1] for r in left.execute('PRAGMA table_info('+quoted+')')]
            try:
                rows=lambda db:{r[0]:r[1:] for r in db.execute('SELECT rowid,* FROM '+quoted)}
                old,new=rows(left),rows(right)
            except sqlite3.OperationalError:
                result[name]={'error':'No rowid; explicit key comparison required'};continue
            updates=[]
            for key in sorted(set(old)|set(new)):
                if key not in old or key not in new:
                    updates.append({'rowid':key,'kind':'inserted' if key in new else 'deleted'});continue
                edited={}
                for col,x,y in zip(cols,old[key],new[key]):
                    if x==y:continue
                    info={'before':summary(x),'after':summary(y)}
                    if isinstance(x,bytes) and isinstance(y,bytes):
                        try:info['decoded_changes']=changes(unarchive(x),unarchive(y))
                        except (ValueError,TypeError,KeyError,IndexError,plistlib.InvalidFileException):pass
                    edited[col]=info
                if edited:updates.append({'rowid':key,'kind':'updated','columns':edited})
            if updates:result[name]={'changed_rows':updates}
    return result


def compare_trees(before,after):
    before,after=Path(before),Path(after)
    paths=lambda root:{str(p.relative_to(root)):p for p in root.rglob('CurrentVersion.*') if p.is_file()}
    a,b=paths(before),paths(after);result=[]
    for name in sorted(set(a)|set(b)):
        if name not in a or name not in b:
            result.append({'path':name,'missing':'before' if name not in a else 'after'});continue
        old,new=a[name].read_bytes(),b[name].read_bytes()
        row={'path':name,'sha256_before':hashlib.sha256(old).hexdigest(),'sha256_after':hashlib.sha256(new).hexdigest(),'bytes_equal':old==new}
        if old!=new:
            if old.startswith(b'SQLite format 3\0') and new.startswith(b'SQLite format 3\0'):
                row['tables']=compare_sqlite(a[name],b[name])
            else:
                try:row['plist_changes']=changes(plistlib.loads(old),plistlib.loads(new))
                except (ValueError,plistlib.InvalidFileException):row['opaque_bytes_changed']=True
        result.append(row)
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('before',type=Path);parser.add_argument('after',type=Path);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    if args.output.exists():parser.error('Refusing to replace an existing comparison')
    result={'schema':'splicekit.sqlite-tree-diff/1','before':str(args.before),'after':str(args.after),'files':compare_trees(args.before,args.after)}
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(str(args.output))

if __name__=='__main__':main()
