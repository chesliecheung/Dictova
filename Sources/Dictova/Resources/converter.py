#!/usr/bin/env python3
"""Dictova conversion engine.

Bootstraps an isolated Python environment, reads MDX/MDD safely, emits Apple
Dictionary XML, and compiles it with Apple's legacy Dictionary Development Kit.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path, PurePosixPath
from urllib.parse import quote

APP_VERSION = "1.6.2"
MDICT_VERSION = "1.3.14"
DDK_REPOSITORY = "https://github.com/SebastianSzturo/Dictionary-Development-Kit.git"
XML_INVALID_CHARACTERS = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\ufffe\uffff]")
XML_ATTRIBUTE_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_.:-]*$")
SAFE_HTML_ATTRIBUTES = {
    "alt", "class", "colspan", "controls", "dir", "download", "height",
    "href", "id", "lang", "loop", "muted", "poster", "preload", "rel",
    "rowspan", "src", "style", "title", "type", "width",
}


def emit(value: float, message: str) -> None:
    print(f"::progress::{value:.3f}::{message}", flush=True)


def log(message: str) -> None:
    print(message, flush=True)


def run(command: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None) -> None:
    log("$ " + " ".join(command))
    process = subprocess.Popen(
        command,
        cwd=str(cwd) if cwd else None,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        errors="replace",
    )
    assert process.stdout is not None
    for line in process.stdout:
        log(line.rstrip())
    if process.wait() != 0:
        raise RuntimeError(f"命令执行失败（退出码 {process.returncode}）：{command[0]}")


def support_directory() -> Path:
    application_support = Path.home() / "Library" / "Application Support"
    root = application_support / "Dictova"
    legacy = application_support / "MDictBridge"
    if legacy.exists() and not root.exists():
        shutil.move(str(legacy), str(root))
    root.mkdir(parents=True, exist_ok=True)
    return root


def python_in_venv(venv: Path) -> Path:
    return venv / "bin" / "python3"


def bootstrap(args: argparse.Namespace) -> None:
    root = support_directory()
    venv = root / "python"
    python = python_in_venv(venv)
    marker = venv / ".mdictbridge-version"
    wanted = f"dependencies-v1:{MDICT_VERSION}"
    ready = python.exists() and marker.exists() and marker.read_text(errors="ignore").strip() == wanted
    if not ready:
        emit(0.03, "首次运行：准备解析组件")
        if venv.exists():
            shutil.rmtree(venv)
        run([sys.executable, "-m", "venv", str(venv)])
        run([
            str(python), "-m", "pip", "install", "--disable-pip-version-check",
            f"mdict-utils=={MDICT_VERSION}", "lxml>=5,<7"
        ])
        marker.write_text(wanted, encoding="utf-8")
    worker_args = [str(python), str(Path(__file__).resolve()), "--worker"] + sys.argv[1:]
    os.execv(str(python), worker_args)


def check_requirements() -> None:
    if sys.platform != "darwin":
        raise RuntimeError("此工具只能在 macOS 上生成原生 .dictionary。")
    missing = [tool for tool in ("git", "xmllint", "xsltproc", "plutil") if shutil.which(tool) is None]
    if missing:
        raise RuntimeError("缺少系统工具：" + ", ".join(missing) + "。请先安装 Xcode Command Line Tools。")
    if os.uname().machine == "arm64":
        test = subprocess.run(["/usr/bin/arch", "-x86_64", "/usr/bin/true"], capture_output=True)
        if test.returncode != 0:
            raise RuntimeError("Apple 芯片上的 Dictionary Development Kit 需要 Rosetta 2。请先在终端运行：softwareupdate --install-rosetta --agree-to-license")


def ensure_ddk() -> Path:
    root = support_directory() / "Dictionary-Development-Kit"
    build_script = root / "bin" / "build_dict.sh"
    if not build_script.exists():
        emit(0.09, "首次运行：获取 Apple 词典编译工具")
        if root.exists():
            shutil.rmtree(root)
        run(["git", "clone", "--depth", "1", DDK_REPOSITORY, str(root)])
    for path in (root / "bin").iterdir():
        if path.is_file():
            path.chmod(path.stat().st_mode | 0o111)
    return root


def companion_mdds(mdx: Path) -> list[Path]:
    escaped = re.escape(mdx.stem)
    pattern = re.compile(rf"^{escaped}(?:\.(\d+))?\.mdd$", re.IGNORECASE)
    found: list[tuple[int, Path]] = []
    for candidate in mdx.parent.iterdir():
        match = pattern.match(candidate.name)
        if match:
            index = int(match.group(1)) if match.group(1) is not None else 0
            found.append((index, candidate))
    return [item[1] for item in sorted(found, key=lambda item: item[0])]


def mdd_sort_key(path: Path) -> tuple[int, str]:
    match = re.search(r"\.(\d+)\.mdd$", path.name, re.IGNORECASE)
    return (int(match.group(1)) if match else 0, path.name.casefold())


def companion_css(mdx: Path) -> Path | None:
    exact = mdx.with_suffix(".css")
    if exact.exists():
        return exact
    for candidate in mdx.parent.iterdir():
        if candidate.stem.casefold() == mdx.stem.casefold() and candidate.suffix.casefold() == ".css":
            return candidate
    return None


def safe_resource_path(raw_name: str) -> Path | None:
    normalized = raw_name.replace("\\", "/").lstrip("/")
    pieces = [part for part in PurePosixPath(normalized).parts if part not in ("", ".")]
    if not pieces or ".." in pieces:
        return None
    return Path(*pieces)


def extract_resources(mdds: list[Path], destination: Path) -> tuple[int, int]:
    from mdict_utils.base.readmdict import MDD

    written = 0
    skipped = 0
    destination.mkdir(parents=True, exist_ok=True)
    for number, mdd_path in enumerate(mdds, 1):
        log(f"读取资源卷 {number}/{len(mdds)}：{mdd_path.name}")
        archive = MDD(str(mdd_path))
        for raw_key, data in archive.items():
            key = raw_key.decode("utf-8", errors="replace")
            relative = safe_resource_path(key)
            if relative is None:
                skipped += 1
                continue
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            written += 1
    return written, skipped


def normalize_url(value: str) -> str:
    value = value.strip().replace("\\", "/")
    if value.lower().startswith("javascript:"):
        return "#"
    if value.lower().startswith("entry://"):
        return "x-dictionary:r:" + value[len("entry://"):]
    if value.lower().startswith("sound://"):
        value = value[len("sound://"):]
    if value.startswith("/"):
        value = value[1:]
    return value


def sanitize_fragment(fragment: str) -> str:
    from lxml import etree, html as lxml_html

    fragment = XML_INVALID_CHARACTERS.sub("", fragment)
    link = re.fullmatch(r"\s*@@@LINK=(.+?)\s*", fragment, flags=re.DOTALL)
    if link:
        target = link.group(1).strip()
        escaped_target = html.escape(target, quote=True)
        return f'<a href="x-dictionary:r:{escaped_target}">参见 {html.escape(target)}</a>'

    try:
        container = lxml_html.fragment_fromstring(fragment, create_parent="div")
    except (etree.ParserError, ValueError):
        return f"<p>{html.escape(fragment)}</p>"

    for element in list(container.iter()):
        tag = element.tag.lower() if isinstance(element.tag, str) else ""
        if tag in {"script", "noscript", "iframe", "object", "embed"}:
            parent = element.getparent()
            if parent is not None:
                parent.remove(element)
            continue
        had_invalid_attribute = False
        for attribute in list(element.attrib):
            lower = attribute.lower()
            if not XML_ATTRIBUTE_NAME.fullmatch(attribute):
                had_invalid_attribute = True
                del element.attrib[attribute]
            elif lower.startswith("on") or lower in {"srcdoc", "integrity", "crossorigin"}:
                del element.attrib[attribute]
            elif lower not in SAFE_HTML_ATTRIBUTES:
                del element.attrib[attribute]
            elif lower in {"src", "href", "poster"}:
                element.attrib[attribute] = normalize_url(element.attrib[attribute])
            else:
                element.attrib[attribute] = XML_INVALID_CHARACTERS.sub("", element.attrib[attribute] or lower)
        if had_invalid_attribute and tag == "a" and element.attrib.get("href", "").startswith("x-dictionary:r:"):
            visible_target = " ".join(element.text_content().split())
            if visible_target and len(visible_target) <= 200:
                element.attrib["href"] = "x-dictionary:r:" + quote(visible_target, safe="")

    serialized: list[str] = []
    if container.text:
        serialized.append(html.escape(container.text))
    for child in container:
        serialized.append(etree.tostring(child, encoding="unicode", method="xml", with_tail=True))
    result = "".join(serialized) or "<p></p>"
    try:
        etree.fromstring(("<root>" + result + "</root>").encode("utf-8"))
        return result
    except etree.XMLSyntaxError:
        plain_text = XML_INVALID_CHARACTERS.sub("", " ".join(container.text_content().split()))
        return '<p class="mdictbridge-fallback">' + html.escape(plain_text) + "</p>"


def write_dictionary_xml(mdx_path: Path, destination: Path) -> int:
    from mdict_utils.base.readmdict import MDX

    mdx = MDX(str(mdx_path), substyle=True)
    total = len(mdx)
    log(f"词条总数：{total}")
    with destination.open("w", encoding="utf-8", newline="\n") as output:
        output.write('<?xml version="1.0" encoding="UTF-8"?>\n')
        output.write('<d:dictionary xmlns="http://www.w3.org/1999/xhtml" xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng">\n')
        count = 0
        fallback_count = 0
        for count, (raw_key, raw_value) in enumerate(mdx.items(), 1):
            key = XML_INVALID_CHARACTERS.sub("", raw_key.decode("utf-8", errors="replace")).strip("\x00\r\n ")
            if not key:
                continue
            body = raw_value.decode("utf-8", errors="replace").strip("\x00")
            escaped = html.escape(key, quote=True)
            output.write(f'<d:entry id="e{count}" d:title="{escaped}">\n')
            output.write(f'<d:index d:value="{escaped}"/>\n')
            cleaned = sanitize_fragment(body)
            if 'class="mdictbridge-fallback"' in cleaned:
                fallback_count += 1
            output.write(cleaned)
            output.write("\n</d:entry>\n")
            if count % 1000 == 0:
                value = 0.18 + 0.37 * (count / max(total, 1))
                emit(value, f"转换词条 {count:,} / {total:,}")
        output.write("</d:dictionary>\n")
    if fallback_count:
        log(f"有 {fallback_count:,} 个严重损坏的词条已自动降级为纯文本，以保证整本词典可编译。")
    return count


BASE_CSS = """@charset "UTF-8";
@namespace d url(http://www.apple.com/DTDs/DictionaryService-1.0.rng);
d|entry { display: block; font-family: -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.48; }
img { max-width: 100%; height: auto; }
audio { max-width: 100%; }
a { color: -apple-system-link; }
"""


def write_css(source: Path | None, destination: Path) -> None:
    supplied = source.read_text(encoding="utf-8", errors="replace") if source else ""
    supplied = re.sub(r"@charset\s+[^;]+;", "", supplied, flags=re.IGNORECASE)
    supplied = re.sub(r"expression\s*\([^)]*\)", "", supplied, flags=re.IGNORECASE)
    supplied = re.sub(r"url\(\s*(['\"]?)javascript:.*?\1\s*\)", "none", supplied, flags=re.IGNORECASE)
    supplied = re.sub(
        r"url\(\s*(['\"]?)(?!data:|https?:|#)(?:/|\\)+([^)'\"]+)\1\s*\)",
        lambda match: f"url({match.group(1)}{match.group(2).replace(chr(92), '/')}{match.group(1)})",
        supplied,
        flags=re.IGNORECASE,
    )
    destination.write_text(BASE_CSS + "\n/* 原词典样式 */\n" + supplied, encoding="utf-8")


def safe_identifier(name: str, mdx: Path) -> str:
    digest = hashlib.sha256((name + str(mdx.resolve())).encode()).hexdigest()[:12]
    return f"local.dictova.dictionary.{digest}"


def write_plist(destination: Path, name: str, identifier: str) -> None:
    payload = {
        "CFBundleDevelopmentRegion": "zh_CN",
        "CFBundleDisplayName": name,
        "CFBundleIdentifier": identifier,
        "CFBundleName": name,
        "CFBundleShortVersionString": "1.0",
        "DCSDictionaryCopyright": "Converted locally by Dictova",
        "DCSDictionaryManufacturerName": "Dictova",
        "DCSDictionaryUseSystemAppearance": True,
    }
    with destination.open("wb") as handle:
        plistlib.dump(payload, handle, fmt=plistlib.FMT_XML, sort_keys=False)


def unique_destination(parent: Path, name: str, suffix: str) -> Path:
    candidate = parent / f"{name}{suffix}"
    if not candidate.exists():
        return candidate
    stamp = time.strftime("%Y%m%d-%H%M%S")
    return parent / f"{name}-{stamp}{suffix}"


def compile_dictionary(ddk: Path, project: Path, name: str) -> Path:
    objects = project / "objects"
    env = os.environ.copy()
    env["DICT_DEV_KIT_OBJ_DIR"] = str(objects)
    command = [
        str(ddk / "bin" / "build_dict.sh"), "-v", "10.11", name,
        str(project / "Dictionary.xml"), str(project / "Dictionary.css"), str(project / "Info.plist")
    ]
    run(command, cwd=project, env=env)
    bundle = objects / f"{name}.dictionary"
    if not bundle.exists():
        raise RuntimeError("编译器没有生成 .dictionary 包。")
    return bundle


def move_resources(source: Path, destination: Path, total: int) -> tuple[int, int, int]:
    """Merge an MDD resource tree without copying its file contents again."""
    moved = 0
    skipped = 0
    moved_bytes = 0
    destination.mkdir(parents=True, exist_ok=True)
    for item in source.rglob("*"):
        relative = item.relative_to(source)
        target = destination / relative
        if item.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        if not item.is_file():
            skipped += 1
            continue
        # Never let an MDD resource replace compiler-generated dictionary data.
        if target.exists():
            skipped += 1
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        size = item.stat().st_size
        os.replace(item, target)
        moved += 1
        moved_bytes += size
        if moved % 2000 == 0:
            progress = 0.88 + 0.035 * (moved / max(total, 1))
            emit(progress, f"整理资源 {moved:,} / {total:,}")
    return moved, skipped, moved_bytes


def clone_or_copytree(source: Path, destination: Path) -> bool:
    """Prefer an APFS clone and fall back to a regular recursive copy."""
    cloned = subprocess.run(
        ["/bin/cp", "-cR", str(source), str(destination)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if cloned.returncode == 0:
        return True
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination, symlinks=True)
    return False


def verify_bundle(bundle: Path) -> None:
    resources = bundle / "Contents" / "Resources"
    required = ["Body.data", "KeyText.index", "EntryID.index", "DefaultStyle.css"]
    missing = [name for name in required if not (resources / name).exists()]
    if not (bundle / "Contents" / "Info.plist").exists():
        missing.append("Info.plist")
    if missing:
        raise RuntimeError("生成的词典不完整，缺少：" + ", ".join(missing))


def worker(args: argparse.Namespace) -> None:
    check_requirements()
    mdx = Path(args.mdx).expanduser().resolve()
    output = Path(args.output).expanduser().resolve()
    if not mdx.is_file() or mdx.suffix.casefold() != ".mdx":
        raise RuntimeError("输入文件不是有效的 .mdx 文件。")
    output.mkdir(parents=True, exist_ok=True)
    name = re.sub(r"[/:]", "-", args.name).strip().strip(".")
    if not name:
        raise RuntimeError("词典名称不能为空。")

    emit(0.06, "检查编译环境")
    ddk = ensure_ddk()
    selected = [Path(value).expanduser().resolve() for value in args.resource]
    missing_selected = [str(path) for path in selected if not path.is_file()]
    if missing_selected:
        raise RuntimeError("所选资源文件不存在：" + ", ".join(missing_selected))
    if selected:
        mdds = sorted(
            [path for path in selected if path.suffix.casefold() == ".mdd"],
            key=mdd_sort_key,
        )
        css_files = [path for path in selected if path.suffix.casefold() == ".css"]
        css = css_files[0] if css_files else None
        if len(css_files) > 1:
            log("提示：选择了多个 CSS，仅使用第一个：" + css.name)
        js_files = [path for path in selected if path.suffix.casefold() == ".js"]
        if js_files:
            log("为保证 Dictionary.app 安全兼容，已忽略 JS：" + ", ".join(path.name for path in js_files))
    else:
        mdds = companion_mdds(mdx)
        css = companion_css(mdx)
    log("MDX：" + str(mdx))
    log("MDD：" + (", ".join(path.name for path in mdds) if mdds else "无"))
    log("CSS：" + (css.name if css else "使用内置样式"))

    # Keeping the work directory beside the destination lets finalization use
    # atomic renames instead of copying a potentially huge bundle a second time.
    with tempfile.TemporaryDirectory(prefix=".Dictova-", dir=output) as temporary:
        project = Path(temporary)
        emit(0.15, "读取 MDX 词条")
        count = write_dictionary_xml(mdx, project / "Dictionary.xml")
        log(f"已写入 {count:,} 个词条。")
        emit(0.57, "验证词典 XML")
        run(["xmllint", "--stream", "--noout", str(project / "Dictionary.xml")])

        write_css(css, project / "Dictionary.css")
        write_plist(project / "Info.plist", name, safe_identifier(name, mdx))

        extracted_resources: Path | None = None
        if args.keep_resources and mdds:
            emit(0.61, "提取 MDD 资源")
            extracted_resources = project / "MDDResources"
            written, skipped = extract_resources(mdds, extracted_resources)
            log(f"已提取 {written:,} 个资源；跳过 {skipped:,} 个不安全路径。")

        emit(0.72, "编译 macOS 原生词典")
        bundle = compile_dictionary(ddk, project, name)
        compiled_size = sum(path.stat().st_size for path in bundle.rglob("*") if path.is_file())
        resource_size = 0

        if extracted_resources is not None:
            emit(0.88, "整理词典资源")
            moved, conflicts, resource_size = move_resources(
                extracted_resources,
                bundle / "Contents" / "Resources",
                written,
            )
            log(f"已整理 {moved:,} 个资源到词典包；跳过 {conflicts:,} 个冲突项。")
        verify_bundle(bundle)

        emit(0.93, "保存词典包")
        destination = unique_destination(output, name, ".dictionary")
        os.replace(bundle, destination)
        verify_bundle(destination)
        result_size = compiled_size + resource_size
        log("输出：" + str(destination))
        print("::resultsize::" + str(result_size), flush=True)
        print("::result::" + str(destination), flush=True)

        if args.install:
            emit(0.96, "安装到 macOS 词典")
            install_root = Path.home() / "Library" / "Dictionaries"
            install_root.mkdir(parents=True, exist_ok=True)
            installed = unique_destination(install_root, name, ".dictionary")
            cloned = clone_or_copytree(destination, installed)
            os.utime(install_root, None)
            log("已安装：" + str(installed))
            if cloned:
                log("已使用 APFS 快速克隆，未重复写入整本词典。")
            print("::installed::" + str(installed), flush=True)
            subprocess.run(["/usr/bin/killall", "Dictionary"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["/usr/bin/open", "-a", "Dictionary"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    emit(1.0, "完成")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--mdx", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--resource", action="append", default=[])
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--keep-resources", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        if args.worker:
            worker(args)
        else:
            bootstrap(args)
    except KeyboardInterrupt:
        log("已取消。")
        raise SystemExit(130)
    except Exception as error:
        log(f"错误：{error}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
