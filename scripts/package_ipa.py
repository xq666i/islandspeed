"""Package the unsigned Xcode product, preserving its embedded widget and file modes."""

import argparse
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path
from zipfile import BadZipFile, ZipFile


def package(app: Path, output: Path) -> None:
    widget = Path("PlugIns/IslandSpeedWidget.appex")
    required = (
        Path("IslandSpeed"), Path("Info.plist"), Path("silence.wav"), Path("quiet.wav"),
        widget / "IslandSpeedWidget", widget / "Info.plist",
    )
    for relative_path in required:
        path = app / relative_path
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"构建产物缺少文件或文件为空：{path}")

    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    identifiers = info.get("BGTaskSchedulerPermittedIdentifiers", [])
    if not isinstance(identifiers, list) or not any(
        isinstance(item, str) and item.endswith(".measurement.*") and "$(" not in item
        for item in identifiers
    ):
        raise ValueError(f"{app}/Info.plist 缺少已展开的后台测量任务标识。")

    output = output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temporary:
        staging = Path(temporary)
        bundle = Path("Payload") / app.name
        shutil.copytree(app, staging / bundle, symlinks=True)
        archive = staging / "unsigned.ipa"
        subprocess.run(["/usr/bin/zip", "-qry", str(archive), "Payload"], cwd=staging, check=True)
        with ZipFile(archive) as ipa:
            for relative_path in required:
                ipa.getinfo((bundle / relative_path).as_posix())
            corrupt = ipa.testzip()
            if corrupt is not None:
                raise ValueError(f"IPA 内容校验失败：{corrupt}")
        archive.replace(output)
    print(f"已生成未签名 IPA：{output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        package(args.app, args.output)
    except (OSError, ValueError, KeyError, BadZipFile, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        raise SystemExit(f"打包失败：{error}")
