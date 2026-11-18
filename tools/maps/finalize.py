"""Record build inputs and outputs without claiming native or physical acceptance."""
import json
from pathlib import Path
import platform
import subprocess
import sys
from pack import encode, sha256_file
from fetch_pbf import SOURCE_URL

def finalize_style(out):
    style=json.loads((out/'pack/style.json').read_text())
    if (out/'pack/terrain.pmtiles').exists():
        style['sources']['terrain']={'type':'raster-dem','url':'pmtiles://{PACK_ROOT}/terrain.pmtiles','tileSize':256,'encoding':'terrarium','minzoom':10,'maxzoom':12}
        style['layers'].insert(3,{'id':'mountain-relief','type':'hillshade','source':'terrain','paint':{'hillshade-shadow-color':'#6d715e','hillshade-highlight-color':'#fffbea','hillshade-accent-color':'#9a927a','hillshade-exaggeration':0.42,'hillshade-illumination-direction':315}})
    (out/'pack/style.json').write_bytes(encode(style))


def main():
    out,root=map(Path,sys.argv[1:])
    finalize_style(out)
    evidence={
        'format':1,'scope':'regional-data-build; native offline renderer/router and physical acceptance recorded separately',
        'source':{'url':SOURCE_URL,'sha256':sha256_file(out/'work/bulgaria.osm.pbf'),'bytes':(out/'work/bulgaria.osm.pbf').stat().st_size,'extractSha256':sha256_file(out/'work/rila.osm.pbf'),'extractAsset':'rila-source.osm.pbf','boundsE7':[229500000,417500000,240500000,425000000]},
        'tooling':{'osmium':subprocess.check_output(['osmium','--version'],text=True).splitlines()[0], 'tilemaker':'2.4.0-1build4','pmtiles':'1.31.2','valhalla':'3.9.2','valhallaImageDigest':'sha256:1c68a8c0f870a018b3b04dddee4b21ef2f41d24bbda68fa7b48e2bee053d5eef','python':platform.python_version()},
        'inputs':{p.relative_to(root).as_posix():sha256_file(p) for p in sorted((root/'tools/maps').rglob('*')) if p.is_file() and not {'__pycache__', 'node_modules'}.intersection(p.parts)},
        'places':{'count':len(json.loads((out/'pack/places.json').read_text())['places']),'smokeEndpoints':'route-smoke.json','endpointProvenance':'OSM named hut and peak from the identical routing/map PBF'},
        'checks':{'pmtilesVerify':True,'graphExtractBuilt':(out/'pack/routing.tar').stat().st_size>0,'nativeOfflineRoute':'not run by data build','nativeOfflineSnapshot':'not run by data build'},
    }
    (out/'build-evidence.json').write_bytes(encode(evidence))


if __name__=='__main__': main()
