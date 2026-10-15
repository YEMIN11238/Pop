#!/usr/bin/env python3
"""Validate package structure and pure JXA requests; does not invoke pop or any host."""
from pathlib import Path
import argparse, datetime, hashlib, json, plistlib, re, stat, subprocess, tempfile, zipfile
root = Path(__file__).resolve().parent
project = root.parent
checks = []
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, help='Optional JSON report path; defaults to stdout only.')
args = parser.parse_args()

def run(*args): return subprocess.run(args, check=True, capture_output=True, text=True).stdout

def expect(value, message):
    if not value: raise AssertionError(message)

canonical = (root / 'Shared/request.js').read_bytes()
for relative in ['PopClip/pop.popclipext/request.js', 'Raycast/request.js', 'Alfred/source/request.js']:
    expect((root / relative).read_bytes() == canonical, 'JXA copy mismatch: ' + relative)
checks.append('三个集成包的 JXA 请求实现完全相同，目标为 com.local.pop，JSON 使用 path/body。')
for file in [root / 'PopClip/pop.popclipext/translate.sh', root / 'Alfred/source/invoke.sh', *sorted((root / 'Raycast').glob('*.sh'))]:
    run('/bin/zsh', '-n', str(file))
    expect(file.stat().st_mode & 0o111, 'Executable bit absent: ' + str(file))
checks.append('10 个 zsh 脚本语法检查及可执行权限通过；原文通过双引号包裹的 argv 传递。')
for file in [root / 'PopClip/Config-reference.plist', root / 'Alfred/source/info.plist']:
    run('/usr/bin/plutil', '-lint', str(file))
checks.append('PopClip plist 参考与 Alfred info.plist 通过 plutil；PopClip 只含一个 Config.json。')
config = json.loads((root / 'PopClip/pop.popclipext/Config.json').read_text())
with (root / 'PopClip/Config-reference.plist').open('rb') as stream: expect(plistlib.load(stream) == config, 'Config format mismatch')
expect(config['identifier'] == 'com.local.pop' and config['requirements'] == ['text'], 'PopClip identity/input')
expect(len(list((root / 'PopClip/pop.popclipext').glob('Config.*'))) == 1, 'Ambiguous PopClip config')
for file in sorted((root / 'Raycast').glob('*.sh')):
    script = file.read_text()
    for marker in ['# @raycast.schemaVersion 1', '# @raycast.title ', '# @raycast.mode silent']:
        expect(marker in script, 'Missing Raycast metadata')
    for line in script.splitlines():
        if line.startswith('# @raycast.argument1 '): expect(json.loads(line.split(' ', 2)[2])['type'] == 'text', 'Raycast argument schema')
checks.append('8 个 Raycast 命令具有必需元数据；翻译参数为未预编码的 text，避免双重编码。')
with (root / 'Alfred/source/info.plist').open('rb') as stream: info = plistlib.load(stream)
expect(info['bundleid'] == 'com.local.pop', 'Alfred bundle ID')
objects = {obj['uid']: obj for obj in info['objects']}
expect(len(objects) == 16 and len(info['connections']) == 8, 'Alfred object count')
for source, links in info['connections'].items():
    expect(source in objects and objects[source]['type'] == 'alfred.workflow.input.keyword', 'Alfred keyword missing')
    for link in links:
        target = objects[link['destinationuid']]
        expect(target['type'] == 'alfred.workflow.action.script' and target['config']['scriptargtype'] == 1, 'Alfred script must use argv')
        expect('{query}' not in target['config']['script'], 'Unsafe query interpolation')
checks.append('Alfred 8 组 keyword→script 连接完整，Run Script 使用 argv，没有 {query} 拼接。')
for archive, prefix, source in [(root / 'Alfred/pop.alfredworkflow', '', root / 'Alfred/source'), (root / 'PopClip/pop.popclipextz', 'pop.popclipext/', root / 'PopClip/pop.popclipext')]:
    with zipfile.ZipFile(archive) as z:
        expect(z.testzip() is None, 'ZIP CRC failed')
        names = z.namelist()
        expect(names and len(names) == len(set(names)), 'ZIP entries missing/duplicated')
        expect(all(not name.startswith('/') and '..' not in Path(name).parts and name.startswith(prefix) for name in names), 'Unsafe ZIP path')
        if not prefix: expect('info.plist' in names and 'invoke.sh' in names and 'request.js' in names, 'Alfred top-level entries')
        else: expect(prefix + 'Config.json' in names and prefix + 'translate.sh' in names, 'PopClip wrapped directory')
        files = [item for item in z.infolist() if not item.is_dir()]
        expected = {prefix + str(path.relative_to(source)) for path in source.rglob('*') if path.is_file()}
        expect({item.filename for item in files} == expected, 'ZIP entries differ from readable source')
        for item in files:
            expect(not stat.S_ISLNK(item.external_attr >> 16), 'ZIP must not contain symlinks')
            relative = item.filename[len(prefix):]
            expect(z.read(item) == (source / relative).read_bytes(), 'ZIP file differs from readable source: ' + relative)
checks.append('Alfred/PopClip 分发 ZIP CRC、相对路径、顶层结构、重复项、无符号链接及全部文件与可读源一致检查通过。')
with tempfile.TemporaryDirectory(prefix='pop-integrations-') as temporary:
    run('/usr/bin/osacompile', '-l', 'JavaScript', '-o', str(Path(temporary) / 'request.scpt'), str(root / 'Shared/request.js'))
    marker = Path(temporary) / 'must-not-exist'
    samples = ['simple text', '中文 😀\nsecond line\r\n\tquote: \' " \\', '$(touch ' + str(marker) + ') `touch ' + str(marker) + '`; \"); throw new Error("injected") //', '--leading-option {"path":"ocr"} & = ? % #']
    for sample in samples:
        for relative in ['Shared/request.js', 'PopClip/pop.popclipext/request.js', 'Raycast/request.js', 'Alfred/source/request.js']:
            output = run('/usr/bin/osascript', '-l', 'JavaScript', str(root / relative), '--dry-run', 'translateText', sample)
            expect(json.loads(output) == {'path':'translate', 'body':{'action':'translateText', 'text':sample}}, 'Literal argv roundtrip failed')
    for action in ['selectionTranslate','inputTranslate','pasteboardTranslate','snipTranslate','snipOCR','pasteboardOCR','continuousOCR']:
        output = json.loads(run('/usr/bin/osascript', '-l', 'JavaScript', str(root / 'Shared/request.js'), '--dry-run', action))
        expect(output['body']['action'] == action and output['path'] == ('ocr' if action.endswith('OCR') else 'translate'), 'Action mapping incorrect')
    expect(not marker.exists(), 'Input was executed')
checks.append('JXA 编译通过；16 次文字 argv 往返和 7 类动作路由实际执行通过：中文、emoji、CRLF、引号、反斜线、shell/JS 注入样本均保持字面文本，未启动 pop。')
result = {'passed':True, 'checks':checks, 'count':len(checks), 'hostApplicationsTested':False, 'installedExtensions':False, 'sentLivePopRequest':False, 'verifiedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(), 'limitations':['Only syntax, package structure and no-side-effect request construction were tested.', 'Actual host import, automation permission and pop result-window behavior require manual acceptance.']}
report = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
if args.output is not None:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(report)
print(report, end='')
