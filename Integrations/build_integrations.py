#!/usr/bin/env python3
"""Build only local integration packages. Does not launch/install any host application."""
from pathlib import Path
import json, plistlib, shutil, zipfile

root = Path(__file__).resolve().parent
project = root.parent
shared = root / 'Shared/request.js'
icon = project / 'Resources/AppIcon.iconset/icon_256x256.png'
small_icon = project / 'Resources/AppIcon.iconset/icon_32x32@2x.png'
popclip = root / 'PopClip/pop.popclipext'
shutil.copyfile(shared, popclip / 'request.js')
shutil.copyfile(icon, popclip / 'icon.png')
popclip_config = {
    'name': 'Pop', 'identifier': 'com.local.pop',
    'description': '使用 Pop 翻译选中文字。', 'icon': 'preserve-color file:icon.png',
    'macosVersion': '15.0', 'shellScriptFile': 'translate.sh',
    'interpreter': '/bin/zsh', 'shellMode': 'none', 'requirements': ['text'],
    'after': 'show-status',
    'shellScriptRationale': 'Pass selected text as an argv value to macOS JavaScript for Automation and the local com.local.pop request command.'
}
(popclip / 'Config.json').write_text(json.dumps(popclip_config, ensure_ascii=False, indent=2) + '\n')
with (popclip / 'Config.plist').open('wb') as stream:
    plistlib.dump(popclip_config, stream, sort_keys=False)
# Config.json is canonical. Keep an equivalent plist only as a human inspectable reference
# outside the package so the host never has to choose between two Config files.
shutil.move(popclip / 'Config.plist', root / 'PopClip/Config-reference.plist')

commands = [
    ('pop-translate-text', 'Pop 翻译文字', 'translateText', 'pop', True),
    ('pop-selection', 'Pop 划词翻译', 'selectionTranslate', 'pops', False),
    ('pop-input', 'Pop 输入翻译', 'inputTranslate', 'popi', False),
    ('pop-clipboard', 'Pop 剪贴板翻译', 'pasteboardTranslate', 'popclip', False),
    ('pop-screenshot', 'Pop 截图翻译', 'snipTranslate', 'popsnip', False),
    ('pop-ocr', 'Pop 截图 OCR', 'snipOCR', 'popocr', False),
    ('pop-clipboard-ocr', 'Pop 剪贴板 OCR', 'pasteboardOCR', 'popocrc', False),
    ('pop-continuous-ocr', 'Pop 连续 OCR', 'continuousOCR', 'popocra', False),
]
raycast = root / 'Raycast'
shutil.copyfile(shared, raycast / 'request.js')
shutil.copyfile(small_icon, raycast / 'icon.png')
for filename, title, action, keyword, needs_text in commands:
    script = '#!/bin/zsh\n# @raycast.schemaVersion 1\n# @raycast.title ' + title + '\n# @raycast.mode silent\n# @raycast.packageName Pop\n# @raycast.icon icon.png\n# @raycast.description 通过本地 com.local.pop request 提交请求，结果显示于 Pop。\n'
    if needs_text:
        script += '# @raycast.argument1 {"type":"text","placeholder":"需要翻译的文字"}\n'
    script += 'set -eu\nSCRIPT_DIRECTORY="${0:A:h}"\nexec /usr/bin/osascript -l JavaScript "$SCRIPT_DIRECTORY/request.js" ' + action + (' "${1:-}"' if needs_text else '') + '\n'
    file = raycast / (filename + '.sh'); file.write_text(script); file.chmod(0o755)

alfred = root / 'Alfred/source'
shutil.copyfile(shared, alfred / 'request.js')
shutil.copyfile(icon, alfred / 'icon.png')
objects, connections, uidata = [], {}, {}
for index, (filename, title, action, keyword, needs_text) in enumerate(commands):
    key_uid, run_uid = 'POP-KEYWORD-' + str(index), 'POP-RUN-' + str(index)
    objects.append({'type':'alfred.workflow.input.keyword', 'version':1, 'uid':key_uid, 'config':{'argumenttype':0 if needs_text else 2, 'keyword':keyword, 'subtext':'结果显示于 Pop 窗口；需已安装 Pop。', 'text':title, 'withspace':needs_text}})
    objects.append({'type':'alfred.workflow.action.script', 'version':2, 'uid':run_uid, 'config':{'concurrently':False, 'escaping':102, 'script':'exec /bin/zsh ./invoke.sh ' + action + (' "$1"' if needs_text else ''), 'scriptargtype':1, 'type':0}})
    connections[key_uid] = [{'destinationuid':run_uid, 'modifiers':0, 'modifiersubtext':''}]
    uidata[key_uid] = {'xpos':40.0, 'ypos':float(index * 120 + 40)}
    uidata[run_uid] = {'xpos':380.0, 'ypos':float(index * 120 + 40)}
workflow = {'bundleid':'com.local.pop', 'name':'Pop', 'version':'1.0.0', 'createdby':'Pop', 'description':'使用本地 Pop 进行文字翻译、划词、截图及 OCR。', 'disabled':False, 'objects':objects, 'connections':connections, 'uidata':uidata, 'readme':'在 Alfred 输入 pop 加文字进行翻译；pops 划词、popi 输入、popclip 剪贴板、popsnip 截图翻译、popocr 截图 OCR、popocrc 剪贴板 OCR、popocra 连续 OCR。结果在 Pop 显示。需 macOS 15+、Pop 及支持 Workflows 的 Alfred。不会自动分配热键。'}
with (alfred / 'info.plist').open('wb') as stream: plistlib.dump(workflow, stream, sort_keys=False)
for file in [popclip / 'translate.sh', alfred / 'invoke.sh']: file.chmod(0o755)
with zipfile.ZipFile(root / 'Alfred/pop.alfredworkflow', 'w', zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(alfred.iterdir()):
        if file.is_file(): archive.write(file, file.name)
with zipfile.ZipFile(root / 'PopClip/pop.popclipextz', 'w', zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(popclip.iterdir()):
        if file.is_file(): archive.write(file, 'pop.popclipext/' + file.name)
print('Generated PopClip package + ZIP, 8 Raycast scripts, Alfred workflow; no installation performed.')
