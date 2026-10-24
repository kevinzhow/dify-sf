"""Build the controlled local plugin deterministically, excluding test harnesses and caches."""
import argparse, hashlib, pathlib, zipfile
p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
root=pathlib.Path(__file__).resolve().parent
files=['manifest.yaml','main.py','requirements.txt','_assets/icon.svg','provider/five.yaml','provider/five.py','tools/echo.yaml','tools/echo.py']
a.output.parent.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(a.output,'w',compression=zipfile.ZIP_DEFLATED)as archive:
 for name in files:
  info=zipfile.ZipInfo(name, date_time=(1980,1,1,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED;info.external_attr=0o644<<16
  archive.writestr(info,(root/name).read_bytes())
print(hashlib.sha256(a.output.read_bytes()).hexdigest())
