#!/usr/bin/env python3
"""Prepare an isolated user dictionary and additive Jev overrides."""
import argparse, json, shutil
from pathlib import Path
import yaml
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('destination',type=Path);args=p.parse_args()
dest=args.destination.resolve()
if not (dest/'wanxiang.schema.yaml').is_file():raise SystemExit('Copy the source Rime directory before preparing overrides.')
shutil.copytree(root/'rime/lua/jev',dest/'lua/jev',dirs_exist_ok=True)
def patch(name):
    file=dest/name
    data=yaml.safe_load(file.read_text()) if file.exists() else {}
    data=data or {};data.setdefault('patch',{})
    return file,data
schema=yaml.safe_load((dest/'wanxiang.schema.yaml').read_text())
filters=[f for f in schema['engine']['filters'] if f!='lua_filter@*jev.bridge']
filters.insert(filters.index('uniquifier'),'lua_filter@*jev.bridge')
f,d=patch('wanxiang.custom.yaml');d['patch']['engine/filters']=filters
processors=d['patch'].get('engine/processors',schema['engine']['processors'])
d['patch']['engine/processors']=['lua_processor@*jev.paging']+[x for x in processors if x!='lua_processor@*jev.paging']
f.write_text(yaml.safe_dump(d,allow_unicode=True,sort_keys=False))
f,d=patch('squirrel.custom.yaml');q=d['patch'];q.update({'style/candidate_list_layout':'linear','style/color_scheme':'jev_reference','style/color_scheme_dark':'jev_reference','style/font_point':17,'style/comment_font_point':13,'style/label_font_point':13,'show_notifications_when':'never'})
q['preset_color_schemes/jev_reference']={'name':'Jev','author':'Rime-Jev','back_color':'0x202020','candidate_text_color':'0xEEEEEE','text_color':'0xEEEEEE','comment_text_color':'0xDCCDB9','label_color':'0xB5B5B5','hilited_candidate_back_color':'0x8B663F','hilited_candidate_text_color':'0xEEEEEE','hilited_comment_text_color':'0xDCCDB9','hilited_candidate_label_color':'0xDCCDB9','border_color':'0x141414','corner_radius':8,'hilited_corner_radius':8,'border_height':6,'border_width':8,'translucency':False}
f.write_text(yaml.safe_dump(d,allow_unicode=True,sort_keys=False))
print(json.dumps({'prepared':str(dest),'filters':len(filters)}))
