import copy
import hashlib
import json
import unittest
import tempfile
from pathlib import Path
from pack import validate_manifest, parse_manifest, validate_places, validate_style, generate, encode, string


def manifest():
    return dict(format=1, id='rila', revision='2026-11-16', name='Rila',
                dataDate='2026-11-16', boundsE7=[229500000,417500000,240500000,425000000],
                minZoom=0, maxZoom=14, engine='valhalla-3.9.2', attribution='© OpenStreetMap contributors',
                files=[dict(path=p, asset=p.replace('/', '-'), bytes=1, sha256='0'*64)
                       for p in ['map.pmtiles','routing.tar','places.json','style.json','licenses/OSM.txt']])


class PackTests(unittest.TestCase):
    def test_text_uses_code_points_and_rejects_unpaired_surrogates(self):
        self.assertTrue(string('\U0001f3d4'*120,120))
        self.assertFalse(string('\U0001f3d4'*121,120))
        self.assertFalse(string('Rila\ud800',120))
        self.assertFalse(string('Rila\udfff',120))
    def test_sprite_requires_all_local_densities(self):
        m=manifest()
        s=dict(version=8,sources={'osm':dict(type='vector',url='pmtiles://{PACK_ROOT}/map.pmtiles')},layers=[],sprite='{PACK_ROOT}/sprite')
        with self.assertRaises(ValueError): validate_style(s,m)
        for p in ['sprite.json','sprite.png','sprite@2x.json','sprite@2x.png']:
            m['files'].append(dict(path=p,asset=p,bytes=1,sha256='0'*64))
        validate_manifest(m); validate_style(s,m)
        for p in ['sprite.json','sprite.png','sprite@2x.json','sprite@2x.png']:
            bad=copy.deepcopy(m); bad['files']=[f for f in bad['files'] if f['path']!=p]
            with self.subTest(path=p), self.assertRaises(ValueError): validate_style(s,bad)

    def test_generated_final_terrain_style_matches_native_zoom_contract(self):
        from finalize import finalize_style
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); (root/'pack').mkdir()
            (root/'pack/style.json').write_text((Path(__file__).parent/'style.json').read_text(encoding='utf-8'),encoding='utf-8')
            (root/'pack/terrain.pmtiles').write_bytes(b'terrain fixture')
            finalize_style(root)
            style=json.loads((root/'pack/style.json').read_text(encoding='utf-8'))
            self.assertEqual(style['sources']['terrain']['minzoom'],10)
            self.assertEqual(style['sources']['terrain']['maxzoom'],12)
            m=manifest()
            for p in (Path(__file__).parent/'assets').rglob('*.pbf'):
                m['files'].append(dict(path=p.relative_to(Path(__file__).parent/'assets').as_posix(),asset='glyph-'+str(len(m['files'])),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest()))
            m['files'].append(dict(path='terrain.pmtiles',asset='terrain.pmtiles',bytes=1,sha256='0'*64))
            validate_manifest(m); validate_style(style,m)

    def test_shared_literal_manifest_vectors(self):
        vectors=json.loads((Path(__file__).resolve().parents[2]/'protocol/maps/region-v1-vectors.json').read_text(encoding='utf-8'))
        for case in vectors['cases']:
            with self.subTest(case=case['id']):
                if case['valid']: validate_manifest(case['manifest'])
                else:
                    with self.assertRaises(ValueError): validate_manifest(case['manifest'])
    def test_generator_hashes_real_files_and_flattened_assets(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for f in manifest()['files']:
                p=root/f['path']; p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(b'real bytes')
            (root/'places.json').write_bytes(encode(dict(format=1,places=[])))
            (root/'style.json').write_bytes(encode(dict(version=8,sources={'osm':dict(type='vector',url='pmtiles://{PACK_ROOT}/map.pmtiles')},layers=[])))
            metadata=manifest(); del metadata['files']
            digest=generate(root,metadata); parsed=parse_manifest((root/'manifest.json').read_bytes(),digest)
            file=next(f for f in parsed['files'] if f['path']=='map.pmtiles')
            self.assertEqual(file['sha256'],hashlib.sha256(b'real bytes').hexdigest())
            self.assertEqual(next(f for f in parsed['files'] if f['path']=='licenses/OSM.txt')['asset'],'licenses--OSM.txt')
            self.assertEqual(generate(root,metadata),digest)

    def test_checked_in_style_is_closed_and_cyrillic_complete(self):
        assets=Path(__file__).parent/'assets'
        m=manifest()
        for p in assets.rglob('*.pbf'):
            m['files'].append(dict(path=p.relative_to(assets).as_posix(),asset=p.name+'-'+str(len(m['files'])),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest()))
        validate_manifest(m)
        validate_style(json.loads((Path(__file__).parent/'style.json').read_text(encoding='utf-8')),m)

    def test_generator_requires_glyph_ranges_used_by_place_names_and_aliases(self):
        source = Path(__file__).parent
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for path in (source/'assets').rglob('*.pbf'):
                glyph = root/path.relative_to(source/'assets')
                glyph.parent.mkdir(parents=True, exist_ok=True)
                glyph.write_bytes(path.read_bytes())
            for path in ('map.pmtiles', 'routing.tar', 'licenses/OSM.txt'):
                output = root/path
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(b'fixture')
            (root/'style.json').write_bytes((source/'style.json').read_bytes())
            (root/'places.json').write_bytes(encode(dict(format=1, places=[
                dict(id='node/11147926305', name='Fountain', aliases=['King Ferdinand\u2019s fountain'],
                     kind='water', latE7=421700000, lonE7=233600000),
            ])))
            metadata = manifest()
            del metadata['files']
            glyph = root/'glyphs/Noto Sans Regular/8192-8447.pbf'
            digest = hashlib.sha256(glyph.read_bytes()).hexdigest()
            self.assertEqual(digest, 'f061e5b4e42e5925228534d8822b423a029569263db09f5ce44573600d45295f')
            generate(root,metadata)
            glyph.unlink()
            with self.assertRaisesRegex(ValueError, 'missing glyph range: .*8192-8447'):
                generate(root,metadata)
    def test_valid_manifest(self):
        self.assertEqual(validate_manifest(manifest())['id'], 'rila')

    def test_paths_collisions_and_budgets(self):
        for path in ['../x','/x','a//x','a/./x','a\\x','a/%20x','a/é']:
            m=manifest(); m['files'][0]['path']=path
            with self.subTest(path=path), self.assertRaises(ValueError): validate_manifest(m)
        for change in ['collision','asset','budget','boolean','unknown']:
            m=manifest()
            if change=='collision': m['files'][1]['path']='MAP.PMTILES'
            if change=='asset': m['files'][1]['asset']='MAP.PMTILES'
            if change=='budget': m['files'][0]['bytes']=2147483647
            if change=='boolean': m['format']=True
            if change=='unknown': m['url']='https://evil.test'
            with self.subTest(change=change), self.assertRaises(ValueError): validate_manifest(m)

    def test_hash_before_parse_and_duplicate_keys(self):
        raw=json.dumps(manifest()).encode()
        self.assertEqual(parse_manifest(raw, hashlib.sha256(raw).hexdigest())['id'],'rila')
        with self.assertRaises(ValueError): parse_manifest(raw,'0'*64)
        raw=b'{"format":1,"format":1}'
        with self.assertRaises(ValueError): parse_manifest(raw,hashlib.sha256(raw).hexdigest())

    def test_places_bounds_and_aliases(self):
        p=dict(format=1,places=[dict(id='node/1',name='Мальовица',aliases=['Malyovitsa'],kind='peak',latE7=421700000,lonE7=233600000)])
        validate_places(p,manifest()['boundsE7'])
        for key,value in [('latE7',0),('lonE7',True),('aliases',['x']*9),('kind','hotel')]:
            bad=copy.deepcopy(p); bad['places'][0][key]=value
            with self.subTest(key=key), self.assertRaises(ValueError): validate_places(bad,manifest()['boundsE7'])

    def test_style_resource_closure(self):
        s=dict(version=8,sources={'osm':dict(type='vector',url='pmtiles://{PACK_ROOT}/map.pmtiles')},layers=[])
        validate_style(s,manifest())
        for extra in [{'sprite':'https://evil.test/sprite'},{'imports':[]},{'glyphs':'file:///tmp/a'}, {'terrain':{} }]:
            with self.subTest(extra=extra), self.assertRaises(ValueError): validate_style(dict(s,**extra),manifest())
        s['sources']['osm']['tiles']=['https://evil.test/{z}']
        with self.assertRaises(ValueError): validate_style(s,manifest())


if __name__=='__main__': unittest.main()
