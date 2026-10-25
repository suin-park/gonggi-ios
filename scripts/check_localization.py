#!/usr/bin/env python3
"""Localization guard for the WHIK shell (docs/WHIK_LOCALIZATION.md).

1. Every L("key") used in app code exists in Gonggi/Resources/Localizable.xcstrings with en / ko / ja / zh-Hans.
2. Placeholder counts match across languages.
3. No Korean string literal remains in user-reachable code (hidden features are listed in EXCLUDED_DIRS; a few
   comparisons with Korean server text are allowed in ALLOWED).
usage: python3 scripts/check_localization.py [repo]
"""
import json
import os
import re
import sys

REPO = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
BS = chr(92)
LANGS = ['en', 'ko', 'ja', 'zh-Hans']
EXCLUDED_DIRS = ['/Features/Kmo/', '/Features/Catalog/', '/Features/StoreShelf/', '/Features/PublicSpaces/',
                 '/Experiments/', '/Debug/', '/Features/Home/', '/Features/Library/Placement/']
EXCLUDED_FILES = ['App/MainTabView.swift', 'Features/Library/Image3DCreateFlowView.swift',
                  'Features/Profile/ProfileView.swift', 'Features/Library/LibraryView.swift']
# Korean kept on purpose: matching Korean server text, and the Korean language name.
ALLOWED = {'어요', '아요', '습니다', '최대', '한국어'}
HANGUL = re.compile('[가-힣]')
CALL = re.compile(r'\bL\("((?:[^"' + BS + BS + r']|' + BS + BS + r'.)*)"')
PH = re.compile(r'%(?:\d+\$)?[@dlfs]')


def unescape(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == BS and i + 1 < len(s):
            out.append({'n': '\n', '"': '"', BS: BS, 't': '\t'}.get(s[i + 1], BS + s[i + 1]))
            i += 2
            continue
        out.append(s[i])
        i += 1
    return ''.join(out)


def literals(line):
    i, n = 0, len(line)
    while i < n:
        if line[i:i + 2] == '//':
            return
        if line[i] == '"':
            if line[i:i + 3] == '"""':
                return
            j = i + 1
            while j < n:
                if line[j] == BS and j + 1 < n:
                    if line[j + 1] == '(':
                        k, d, inq = j + 2, 1, False
                        while k < n and d > 0:
                            if line[k] == '"' and line[k - 1] != BS:
                                inq = not inq
                            elif not inq and line[k] == '(':
                                d += 1
                            elif not inq and line[k] == ')':
                                d -= 1
                            k += 1
                        j = k
                        continue
                    j += 2
                    continue
                if line[j] == '"':
                    break
                j += 1
            yield line[i + 1:j]
            i = j + 1
            continue
        i += 1


def main():
    doc = json.load(open(os.path.join(REPO, 'Gonggi', 'Resources', 'Localizable.xcstrings'), encoding='utf-8'))
    strings = doc['strings']
    errors = []
    for key, entry in strings.items():
        locs = entry.get('localizations', {})
        vals = {}
        for lang in LANGS:
            v = locs.get(lang, {}).get('stringUnit', {}).get('value')
            if not v:
                errors.append(f'missing {lang}: {key!r}')
            vals[lang] = v or ''
        n = len(PH.findall(key.replace('%%', '')))
        for lang in LANGS:
            if len(PH.findall(vals[lang].replace('%%', ''))) != n:
                errors.append(f'placeholder count differs in {lang}: {key!r}')
    used = 0
    for root, _, files in os.walk(os.path.join(REPO, 'Gonggi')):
        for name in files:
            if not name.endswith('.swift'):
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, os.path.join(REPO, 'Gonggi')).replace(os.sep, '/')
            reachable = not any(d in '/' + rel for d in EXCLUDED_DIRS) and rel not in EXCLUDED_FILES
            for ln, line in enumerate(open(path, encoding='utf-8'), 1):
                for m in CALL.finditer(line):
                    used += 1
                    key = unescape(m.group(1))
                    if key not in strings:
                        errors.append(f'key not in catalog: {rel}:{ln}: {key!r}')
                if reachable and not line.lstrip().startswith('//'):
                    for lit in literals(line):
                        if HANGUL.search(lit) and lit not in ALLOWED and 'DateFormatter' not in line:
                            errors.append(f'Korean literal in reachable code: {rel}:{ln}: {lit[:60]!r}')
    print(f'catalog keys {len(strings)}, L() calls {used}, problems {len(errors)}')
    for e in errors[:200]:
        print('ERROR', e)
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
