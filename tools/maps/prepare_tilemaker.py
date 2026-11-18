"""Apply explicit hiking changes to pinned upstream OpenMapTiles processing."""
import json
import pathlib
import sys

source,out=map(pathlib.Path,sys.argv[1:])
config=json.loads((source/'config-openmaptiles.json').read_text())
config['layers']={k:v for k,v in config['layers'].items() if 'source' not in v}
config['layers']['poi']['minzoom']=10
config['layers']['mountain_peak']['minzoom']=10
config['settings']['filemetadata'].pop('tiles',None)
config['settings']['name']='Rila hiking OSM'
(out/'config.json').write_text(json.dumps(config))
lua=(source/'process-openmaptiles.lua').read_text()
lua=lua.replace('additional_languages = { }','additional_languages = { "bg", "en" }')
lua=lua.replace('"alpine_hut", "aquarium"','"alpine_hut", "wilderness_hut", "aquarium"')
lua=lua.replace('alpine_hut="lodging"','wilderness_hut="lodging", alpine_hut="lodging"')
lua=lua.replace('way:Attribute("class", h)','way:Attribute("class", h)\n\t\t\tway:Attribute("subclass", highway)\n\t\t\tway:Attribute("sac_scale", way:Find("sac_scale"))\n\t\t\tway:Attribute("trail_visibility", way:Find("trail_visibility"))')
# Preserve all mapped minor trails at useful hiking zooms, including tracks and steps.
lua=lua.replace('-- Write to layer','if h == "path" or h == "track" then minzoom = 10 end\n\t\t-- Write to layer')
lua=lua.replace('if rank>4 then layer="poi_detail" end','if rank>4 and subclass~="alpine_hut" and subclass~="wilderness_hut" and subclass~="shelter" then layer="poi_detail" end')
poi_function = 'function GetPOIRank(obj)\n\tlocal k,list,v,class,rank'
if lua.count(poi_function) != 1 or lua.count('for k,list in pairs(poiTags) do') != 1:
    raise ValueError('unexpected upstream GetPOIRank implementation')
lua = lua.replace(poi_function, '''-- Lua table traversal order is unspecified. Sort once, then reuse the order.
local poiTagOrder = {}
for key in pairs(poiTags) do table.insert(poiTagOrder, key) end
table.sort(poiTagOrder)

function GetPOIRank(obj)
	local tourism = obj:Find("tourism")
	if tourism == "alpine_hut" or tourism == "wilderness_hut" then
		return poiClassRanks.lodging or 25, "lodging", tourism
	end
	if obj:Find("amenity") == "shelter" then
		local class = poiClasses.shelter or "amenity"
		return poiClassRanks[class] or 25, class, "shelter"
	end
	local v,class,rank''')
lua = lua.replace('for k,list in pairs(poiTags) do',
                  'for _,k in ipairs(poiTagOrder) do\n\t\tlocal list = poiTags[k]')
(out/'process.lua').write_text(lua)
