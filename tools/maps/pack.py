"""Strict reference validation and deterministic offline-region manifest generation."""
import argparse
import datetime
import hashlib
import json
import re
from pathlib import Path

MAX_TOTAL = 2147483647
RESOURCE_MAX_BYTES = {'places.json': 8 * 1024 * 1024, 'style.json': 1024 * 1024}
REQUIRED = {'map.pmtiles','routing.tar','places.json','style.json','licenses/OSM.txt'}
FIELDS = {'format','id','revision','name','dataDate','boundsE7','minZoom','maxZoom','engine','attribution','files'}


def require(ok, message):
    if not ok: raise ValueError(message)


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def string(value, maximum):
    return (isinstance(value,str) and 1 <= len(value) <= maximum
            and not any(ord(c)<32 or 0xD800<=ord(c)<=0xDFFF for c in value))


def safe_path(value):
    return (string(value,160) and re.fullmatch(r'[A-Za-z0-9_ ./,@+\-]+',value) is not None
            and all(s not in ('','.','..') for s in value.split('/')))


def validate_manifest(m):
    require(isinstance(m,dict) and set(m)==FIELDS,'manifest fields')
    require(type(m['format']) is int and m['format']==1,'format')
    for key in ('id','revision'):
        require(isinstance(m[key],str) and re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*',m[key]) and len(m[key])<=64,key)
    require(string(m['name'],120) and string(m['attribution'],1000),'text')
    require(isinstance(m['dataDate'],str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}',m['dataDate']),'date')
    try: datetime.date.fromisoformat(m['dataDate'])
    except ValueError: raise ValueError('date') from None
    b=m['boundsE7']
    require(isinstance(b,list) and len(b)==4 and all(integer(v,-1800000000,1800000000) for v in b),'bounds')
    require(-900000000<=b[1]<b[3]<=900000000 and b[0]<b[2],'bounds order')
    require(type(m['minZoom']) is int and m['minZoom']==0 and type(m['maxZoom']) is int and m['maxZoom']==14,'zoom')
    require(m['engine']=='valhalla-3.9.2','engine')
    require(isinstance(m['files'],list) and 1<=len(m['files'])<=256,'file count')
    paths=set(); assets=set(); total=0
    for f in m['files']:
        require(isinstance(f,dict) and set(f)=={'path','asset','bytes','sha256'},'file fields')
        require(safe_path(f['path']),'path')
        require(safe_path(f['asset']) and '/' not in f['asset'],'asset')
        require(f['path'].lower() not in paths and f['asset'].lower() not in assets,'collision')
        paths.add(f['path'].lower()); assets.add(f['asset'].lower())
        require(integer(f['bytes'],1,RESOURCE_MAX_BYTES.get(f['path'], MAX_TOTAL)),'bytes')
        total+=f['bytes']
        require(isinstance(f['sha256'],str) and re.fullmatch('[0-9a-f]{64}',f['sha256']),'sha256')
    require(total<=MAX_TOTAL and REQUIRED <= {f['path'] for f in m['files']},'budget or required file')
    return m


def no_duplicates(pairs):
    out={}
    for k,v in pairs:
        require(k not in out,'duplicate JSON key'); out[k]=v
    return out


def parse_json(raw, maximum):
    require(len(raw)<=maximum,'JSON size')
    try: return json.loads(raw.decode('utf-8'),object_pairs_hook=no_duplicates,
                           parse_constant=lambda x: (_ for _ in ()).throw(ValueError('nonfinite JSON')))
    except (UnicodeError,json.JSONDecodeError,RecursionError) as e: raise ValueError('invalid JSON') from e


def parse_manifest(raw, expected_sha256):
    require(isinstance(expected_sha256,str) and re.fullmatch('[0-9a-f]{64}',expected_sha256),'expected hash')
    require(hashlib.sha256(raw).hexdigest()==expected_sha256,'manifest hash mismatch')
    return validate_manifest(parse_json(raw,262144))


def validate_places(doc,bounds):
    require(isinstance(doc,dict) and set(doc)=={'format','places'} and type(doc['format']) is int and doc['format']==1,'places fields')
    require(isinstance(doc['places'],list) and len(doc['places'])<=25000,'places count')
    ids=set()
    for p in doc['places']:
        require(isinstance(p,dict) and set(p)=={'id','name','aliases','kind','latE7','lonE7'},'place fields')
        require(isinstance(p['id'],str) and re.fullmatch(r'(node|way|relation)/[1-9][0-9]*',p['id']) and p['id'] not in ids,'place id'); ids.add(p['id'])
        require(string(p['name'],120),'place name')
        require(isinstance(p['aliases'],list) and len(p['aliases'])<=8 and all(string(a,120) for a in p['aliases']),'aliases')
        require(p['kind'] in ('hut','peak','shelter','water','trailhead','place'),'kind')
        require(integer(p['lonE7'],bounds[0],bounds[2]) and integer(p['latE7'],bounds[1],bounds[3]),'place bounds')
    require(len(encode(doc))<=RESOURCE_MAX_BYTES['places.json'],'places bytes')
    return doc


def validate_style(style,manifest):
    require(isinstance(style,dict) and style.get('version')==8,'style version')
    require(not ({'imports','terrain'} & set(style)),'unsupported style imports/terrain')
    paths={f['path'] for f in manifest['files']}
    for key,template in [('glyphs','{PACK_ROOT}/glyphs/{fontstack}/{range}.pbf'),('sprite','{PACK_ROOT}/sprite')]:
        if key in style: require(style[key]==template,'local '+key)
    if 'sprite' in style:
        require({'sprite.json','sprite.png','sprite@2x.json','sprite@2x.png'} <= paths,'missing sprite resources')
    sources=style.get('sources')
    require(isinstance(sources,dict) and sources,'sources')
    for source in sources.values():
        require(isinstance(source,dict),'source')
        require(source.get('type') in ('vector','raster-dem'),'source type')
        allowed='terrain.pmtiles' if source['type']=='raster-dem' else 'map.pmtiles'
        require(source.get('url')=='pmtiles://{PACK_ROOT}/'+allowed and allowed in paths,'source URL')
        require(set(source)<= {'type','url','tileSize','encoding','attribution','minzoom','maxzoom'},'source fields')
    def scan(value):
        if isinstance(value,str):
            require(not any(t in value.lower() for t in ('http:','https:','file:','data:','ftp:','\\')),'external style resource')
        elif isinstance(value,dict):
            for k,v in value.items():
                require(k not in ('icon-image','fill-pattern','line-pattern','background-pattern') or 'sprite' in style,'missing sprite')
                scan(v)
        elif isinstance(value,list):
            for v in value: scan(v)
    scan(style)
    if 'glyphs' in style:
        fonts=set()
        for layer in style.get('layers',[]):
            layout=layer.get('layout',{})
            if 'text-field' in layout:
                font=layout.get('text-font'); require(isinstance(font,list) and font and all(isinstance(f,str) for f in font),'literal text font')
                fonts.add(','.join(font))
        for font in fonts:
            for interval in ('0-255','256-511','1024-1279'):
                require('glyphs/'+font+'/'+interval+'.pbf' in paths,'missing Latin/Cyrillic glyph range')
    return style


def encode(obj): return (json.dumps(obj,ensure_ascii=False,sort_keys=True,separators=(',',':'))+'\n').encode('utf-8')


def sha256_file(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
    return h.hexdigest()


def generate(root, metadata):
    root=Path(root)
    files=[]
    for p in sorted(root.rglob('*')):
        require(not p.is_symlink(),'symlink')
        if p.is_file() and p.name!='manifest.json':
            path=p.relative_to(root).as_posix()
            files.append(dict(path=path,asset=path.replace('/','--'),bytes=p.stat().st_size,sha256=sha256_file(p)))
    m=validate_manifest(dict(metadata,files=files))
    validate_places(parse_json((root/'places.json').read_bytes(),RESOURCE_MAX_BYTES['places.json']),m['boundsE7'])
    validate_style(parse_json((root/'style.json').read_bytes(),RESOURCE_MAX_BYTES['style.json']),m)
    raw=encode(m); require(len(raw)<=262144,'manifest bytes')
    (root/'manifest.json').write_bytes(raw)
    return hashlib.sha256(raw).hexdigest()


if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('root'); parser.add_argument('metadata')
    args=parser.parse_args()
    print(generate(args.root,parse_json(Path(args.metadata).read_bytes(),262144)))
