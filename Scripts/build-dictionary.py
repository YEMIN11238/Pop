#!/usr/bin/env python3
"""Rebuild pop's offline ECDICT SQLite database from an immutable public revision.

Usage: python3 scripts/build-dictionary.py --download
Only ecdict.csv is used. The separately restricted lemma.en.txt is not bundled.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import urllib.request

REVISION = 'bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b'
SOURCE_SHA256 = {
    'ecdict.csv': '1a6947e04785db63613a92e14903cdae7954f7e84860b10e68e5c7cbb3f9c3cf',
    'LICENSE': 'f8552dd246f61a4e064569eae6194a01c6b3d63b03bf27c6ca863593c549ed0f',
}
PROJECT = Path(__file__).resolve().parent.parent


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        while data := stream.read(1024 * 1024): value.update(data)
    return value.hexdigest()


def unescape(value):
    return (value or '').replace(r'\\n', '\n').replace(r'\n', '\n').replace(r'\\r', '').replace(r'\r', '')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path, default=PROJECT.parent / 'ecdict-source.noindex')
    parser.add_argument('--download', action='store_true')
    args = parser.parse_args()
    args.source_dir.mkdir(parents=True, exist_ok=True)
    for name, expected in SOURCE_SHA256.items():
        path = args.source_dir / name
        if not path.exists() and args.download:
            url = f'https://raw.githubusercontent.com/skywind3000/ECDICT/{REVISION}/{name}'
            with urllib.request.urlopen(url, timeout=90) as source, path.open('wb') as dest:
                shutil.copyfileobj(source, dest)
        if not path.exists() or digest(path) != expected:
            raise SystemExit(f'{name} is missing or SHA-256 differs; use --download with an empty source directory.')
    output = PROJECT / 'Resources' / 'Dictionaries'
    output.mkdir(parents=True, exist_ok=True)
    database = output / 'ECDICT.sqlite'
    temporary = output / 'ECDICT.building.sqlite'
    temporary.unlink(missing_ok=True)
    connection = sqlite3.connect(temporary)
    connection.executescript('''
    PRAGMA page_size=4096;
    PRAGMA journal_mode=OFF;
    PRAGMA synchronous=OFF;
    PRAGMA user_version=1;
    CREATE TABLE entries(word TEXT PRIMARY KEY COLLATE NOCASE, phonetic TEXT NOT NULL,
      translation TEXT NOT NULL, definition TEXT NOT NULL, exchange TEXT NOT NULL, tags TEXT NOT NULL) WITHOUT ROWID;
    CREATE TABLE aliases(form TEXT COLLATE NOCASE, lemma TEXT COLLATE NOCASE, kind TEXT,
      PRIMARY KEY(form,lemma,kind)) WITHOUT ROWID;
    CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
    ''')
    rows = 0
    with (args.source_dir / 'ecdict.csv').open(encoding='utf-8-sig', newline='') as source:
        for row in csv.DictReader(source):
            word = row['word'].strip()
            if not word: continue
            rows += 1
            connection.execute('INSERT OR IGNORE INTO entries VALUES (?,?,?,?,?,?)', (
                word, row['phonetic'], unescape(row['translation']), unescape(row['definition']),
                row['exchange'], row['tag']))
            for change in row['exchange'].split('/'):
                kind, separator, forms = change.partition(':')
                if not separator or kind == '1': continue
                for form in forms.split(','):
                    form = form.strip()
                    if not form: continue
                    alias, lemma = (word, form) if kind == '0' else (form, word)
                    if alias.lower() != lemma.lower():
                        connection.execute('INSERT OR IGNORE INTO aliases VALUES (?,?,?)', (alias, lemma, kind))
            if rows % 100_000 == 0: print(f'Imported {rows:,} source entries', flush=True)
    entries = connection.execute('SELECT count(*) FROM entries').fetchone()[0]
    aliases = connection.execute('SELECT count(*) FROM aliases').fetchone()[0]
    metadata = {'schema': '1', 'repository': 'https://github.com/skywind3000/ECDICT', 'revision': REVISION,
                'source_sha256': SOURCE_SHA256['ecdict.csv'], 'license': 'MIT', 'entries': str(entries)}
    connection.executemany('INSERT INTO metadata VALUES (?,?)', metadata.items())
    connection.commit()
    connection.execute('VACUUM')
    integrity = connection.execute('PRAGMA integrity_check').fetchone()[0]
    if integrity != 'ok': raise SystemExit('SQLite integrity check failed: ' + integrity)
    fixtures = {}
    for word in ['hello', 'apple', 'run', 'running', 'gave']:
        record = connection.execute('SELECT word,translation FROM entries WHERE word=?', (word,)).fetchone()
        if not record or not record[1]: raise SystemExit('Missing dictionary fixture: ' + word)
        fixtures[word] = True
    connection.close()
    temporary.replace(database)
    license_dir = PROJECT / 'Resources' / 'Licenses'
    license_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.source_dir / 'LICENSE', license_dir / 'ECDICT-MIT.txt')
    provenance = {
        'repository': metadata['repository'], 'revision': REVISION, 'license': 'MIT',
        'source_url': f'https://raw.githubusercontent.com/skywind3000/ECDICT/{REVISION}/ecdict.csv',
        'source_sha256': SOURCE_SHA256, 'source_rows': rows, 'case_insensitive_unique_entries': entries,
        'morphology_aliases': aliases, 'sqlite_sha256': digest(database), 'sqlite_bytes': database.stat().st_size,
        'sqlite_integrity_check': integrity, 'fixtures': fixtures,
        'not_used': 'lemma.en.txt has a separate research/educational-use header and is not included or used.',
        'build': 'python3 scripts/build-dictionary.py --download',
    }
    (output / 'ECDICT-provenance.json').write_text(json.dumps(provenance, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(provenance, ensure_ascii=False, indent=2))


if __name__ == '__main__': main()
