@echo off
chcp 65001 >nul
set PYTHONUTF8=1
cd /d "%~dp0"

python -c "import os, zipfile, lief; app='Payload/Arizona.app'; exe=os.path.join(app,'Arizona'); modules=os.path.join(app,'LoaderLib'); assert os.path.isfile(exe), 'Extract Arizona.app into Payload/Arizona.app first'; assert os.path.isdir(modules) and os.listdir(modules), 'LoaderLib resource folder is missing'; binary=lief.MachO.parse(exe)[0]; library='@executable_path/Frameworks/LuaLoader.dylib'; binary.add_library(library) if not any(item.name==library for item in binary.libraries) else None; binary.write(exe); output='Arizona_42loader.ipa'; os.remove(output) if os.path.exists(output) else None; archive=zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED); [archive.write(os.path.join(root,name),os.path.join(root,name).replace(os.sep,'/')) for root,_,names in os.walk('Payload') for name in names]; archive.close(); print('Created:',output,'| size:',round(os.path.getsize(output)/1024/1024,1),'MB')"
if errorlevel 1 exit /b 1
pause
