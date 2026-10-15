// Independent pop integration. Source text is always an argv value, never script source.
function run(argv) {
    var args = Array.prototype.slice.call(argv);
    var dryRun = args[0] === '--dry-run';
    if (dryRun) args.shift();
    var action = args[0] || 'translateText';
    var allowed = {
        translateText: 'translate', selectionTranslate: 'translate',
        snipTranslate: 'translate', inputTranslate: 'translate',
        pasteboardTranslate: 'translate', silentSelectionTranslate: 'translate',
        silentInputBoxTranslate: 'translate', imageTranslate: 'translate',
        snipOCR: 'ocr', pasteboardOCR: 'ocr', continuousOCR: 'ocr', fileOCR: 'ocr'
    };
    if (!Object.prototype.hasOwnProperty.call(allowed, action)) throw new Error('Unsupported pop action.');
    var body = {action: action};
    if (action === 'translateText') {
        body.text = args.length > 1 ? String(args[1]) : '';
        if (!body.text.trim()) throw new Error('Enter nonempty text for pop.');
    }
    var payload = JSON.stringify({path: allowed[action], body: body});
    if (dryRun) return payload;
    var reply = Application('com.local.pop').request(payload);
    var status = JSON.parse(String(reply));
    if (status.status !== 'accepted') throw new Error(status.message || 'pop rejected the request.');
    return '已提交到 pop'; // Accepted asynchronously; this is not the translated result.
}
