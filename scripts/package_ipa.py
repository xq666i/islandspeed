"""Package unsigned Xcode product and verify location-mode settings."""
import argparse
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path
from zipfile import BadZipFile, ZipFile


def package(app: Path, output: Path) -> None:
    widget = Path('PlugIns/IslandSpeedWidget.appex')
    required = (Path('IslandSpeed'), Path('Info.plist'), widget / 'IslandSpeedWidget', widget / 'Info.plist')
    for relative in required:
        path = app / relative
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f'构建产物缺少文件：{path}')
    with (app / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if set(info.get('UIBackgroundModes', [])) != {'location'} or info.get('BGTaskSchedulerPermittedIdentifiers'):
        raise ValueError('后台模式必须为 location，不得保留后台测量任务标识')
    for key in ('NSLocationWhenInUseUsageDescription', 'NSLocationAlwaysAndWhenInUseUsageDescription', 'NSSupportsLiveActivities'):
        if not info.get(key):
            raise ValueError(f'缺少 Info.plist 配置：{key}')
    if not any('islandspeed' in item.get('CFBundleURLSchemes', []) for item in info.get('CFBundleURLTypes', [])):
        raise ValueError('主 App 未注册预约恢复链接')
    with (app / widget / 'Info.plist').open('rb') as stream:
        extension = plistlib.load(stream)
    if extension.get('NSExtension', {}).get('NSExtensionPointIdentifier') != 'com.apple.widgetkit-extension':
        raise ValueError('扩展缺少 WidgetKit 入口')
    main_id = info.get('CFBundleIdentifier', '')
    if not main_id or not extension.get('CFBundleIdentifier', '').startswith(main_id + '.'):
        raise ValueError('扩展包名与主 App 包名不匹配')
    for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
        if not info.get(key) or info[key] != extension.get(key):
            raise ValueError(f'主 App 与扩展版本不匹配：{key}')
    if info.get('CFBundleExecutable') != 'IslandSpeed' or extension.get('CFBundleExecutable') != 'IslandSpeedWidget':
        raise ValueError('Info.plist 中的可执行文件名与构建产物不匹配')
    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temporary:
        staging = Path(temporary)
        bundle = Path('Payload') / app.name
        shutil.copytree(app, staging / bundle, symlinks=True)
        archive = staging / 'unsigned.ipa'
        subprocess.run(['/usr/bin/zip', '-qry', str(archive), 'Payload'], cwd=staging, check=True)
        with ZipFile(archive) as ipa:
            for relative in required:
                ipa.getinfo((bundle / relative).as_posix())
            corrupt = ipa.testzip()
            if corrupt is not None:
                raise ValueError(f'IPA 内容校验失败：{corrupt}')
        archive.replace(output)
    print(f'已生成未签名 IPA：{output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        package(args.app, args.output)
    except (OSError, ValueError, KeyError, BadZipFile, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        raise SystemExit(f'打包失败：{error}')
