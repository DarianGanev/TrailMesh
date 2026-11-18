"""Derive named places and a public, non-personal hut/peak smoke case from the pack PBF."""
import json
import sys
import osmium
from pack import encode, validate_places

BOUNDS=[229500000,417500000,240500000,425000000]


def kind(tags):
    if tags.get('tourism') in ('alpine_hut','wilderness_hut'): return 'hut'
    if tags.get('natural')=='peak': return 'peak'
    if tags.get('amenity')=='shelter': return 'shelter'
    if tags.get('amenity')=='drinking_water' or tags.get('natural')=='spring': return 'water'
    if tags.get('highway')=='trailhead': return 'trailhead'
    if tags.get('place'): return 'place'


class Places(osmium.SimpleHandler):
    def __init__(self): super().__init__(); self.places=[]

    def add(self,obj,typ,lat,lon):
        tags=dict(obj.tags); k=kind(tags)
        name=tags.get('name') or tags.get('name:bg') or tags.get('name:en')
        if not k or not name or len(name)>120: return
        lat=round(lat*1e7); lon=round(lon*1e7)
        if not (BOUNDS[0]<=lon<=BOUNDS[2] and BOUNDS[1]<=lat<=BOUNDS[3]): return
        aliases=[]
        for key in ('name:bg','name:en','int_name','alt_name','short_name'):
            for alias in tags.get(key,'').split(';'):
                if alias and alias!=name and len(alias)<=120 and alias not in aliases: aliases.append(alias)
        self.places.append(dict(id=f'{typ}/{obj.id}',name=name,aliases=aliases[:8],kind=k,latE7=lat,lonE7=lon))

    def node(self,n):
        if n.location.valid(): self.add(n,'node',n.location.lat,n.location.lon)

    def way(self,w):
        if not kind(dict(w.tags)): return
        coords=[n for n in w.nodes if n.location.valid()]
        if coords: self.add(w,'way',sum(n.lat for n in coords)/len(coords),sum(n.lon for n in coords)/len(coords))


if __name__=='__main__':
    handler=Places(); handler.apply_file(sys.argv[1],locations=True,idx='flex_mem')
    doc=dict(format=1,places=sorted(handler.places,key=lambda p:(p['name'],p['id'])))
    validate_places(doc,BOUNDS)
    open(sys.argv[2],'wb').write(encode(doc))
    candidates=[p for p in doc['places'] if any('мальовиц' in s.lower() or 'malyovits' in s.lower() or 'maliovits' in s.lower() for s in [p['name']]+p['aliases'])]
    hut=next(p for p in candidates if p['kind']=='hut'); peak=next(p for p in candidates if p['kind']=='peak')
    # Summit approaches in this extract include a SAC 3 path. The normal SAC 2
    # cap excludes it, so the smoke route must deliberately opt in to SAC 3.
    smoke=dict(format=1,maximumHikingDifficulty=3,
               description='Public OSM Malyovitsa hut to peak, explicit mapped difficulty 3; graph verification only, not a safety recommendation',
               start=hut,end=peak,
               **{'from':{'latE7':hut['latE7'],'lonE7':hut['lonE7']},'to':{'latE7':peak['latE7'],'lonE7':peak['lonE7']},'query':'Мальовица'})
    open(sys.argv[3],'wb').write(encode(smoke))
