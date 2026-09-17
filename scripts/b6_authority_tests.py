"""Test-only: B6 World regressions in an isolated VM; never load a live World."""
from pathlib import Path
import argparse
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MODULES = [('mmo_contracts', 'voxel/'+n) for n in ['structure','attachments','refined','payload','codec']]
MODULES += [('mmo_contracts','session/codec')]
MODULES += [('voxel_region',n) for n in ['structure','attachments','prefab','overlay_log','damage','property_observation','dc_network','circuit','thermal_geometry','thermal_attachments','combustion','world']]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--container',default='voxim-b4-acceptance')
    parser.add_argument('--out',type=Path,default=ROOT/'.demo/b6-authority-tests')
    args=parser.parse_args()
    out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
    remote='/tmp/voxim-b6-authority'
    script='Code.compiler_options(ignore_module_conflict: true)\n'
    for i,(app,name) in enumerate(MODULES):
        shutil.copy2(ROOT/f'apps/{app}/lib/{app}/{name}.ex',out/f'{i}.ex')
        script+=f'Code.compile_file("{remote}/{i}.ex")\n'
    catalog=ROOT.parent/'Voxim/Content/Voxel/Properties/Published/ade8e630274214b6d9abba77286d8a5d8625d485bd6018e92a9bf0a43d3231ba.json'
    shutil.copy2(catalog,out/'properties.json')
    script+=f'System.put_env("B6_CATALOG","{remote}/properties.json")\n'
    script+='Logger.configure(level: :warning)\nExUnit.start(autorun: false,timeout: 300000,exclude: [:test],include: [:b6,:b3,:b3_heater,:b4,:b5],seed: 0)\n'
    for name in ['damage_world_test.exs','combustion_test.exs','combustion_world_test.exs']:
        source=(ROOT/'apps/voxel_region/test'/name).read_text(encoding='utf-8')
        if name=='combustion_test.exs':
            source=source.replace('use ExUnit.Case, async: true','use ExUnit.Case, async: true\n  @moduletag :b6')
        (out/name).write_text(source,encoding='utf-8')
        script+=f'Code.require_file("{remote}/{name}")\n'
    script+='r=ExUnit.run()\nSystem.halt(if r.failures>0,do: 1,else: 0)\n'
    (out/'run.exs').write_text(script,encoding='utf-8')
    subprocess.run(['docker','exec',args.container,'mkdir','-p',remote],check=True)
    subprocess.run(['docker','cp',str(out)+'/.',args.container+':'+remote],check=True)
    with (out/'run.log').open('wb') as log:
        result=subprocess.run(['docker','exec',args.container,'elixir','--erl','+S 2:2',remote+'/run.exs'],stdout=log,stderr=subprocess.STDOUT)
    print('exit',result.returncode,'log',out/'run.log')
    return result.returncode

if __name__=='__main__':
    raise SystemExit(main())
