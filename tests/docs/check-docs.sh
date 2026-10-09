#!/usr/bin/env bash
# Manual docs consistency check (not wired into CI; it reports, it is not a guard).
# Run from anywhere:  bash tests/docs/check-docs.sh
#
# Checks, over every tracked *.md in this repo:
#   1. relative links resolve (file exists; a #fragment matches a heading in that file)
#   2. links to sibling repos (github.com/<org>/<repo>/blob/main/<path>[#frag]) point at a
#      file that exists in the sibling checkout next to this repo, with a matching heading
#   3. no `file.ext:NN` line pins remain in prose (they rot; the dated ledgers ASSUMPTIONS/DECISIONS are exempt)
#   4. every action input/output named in actions/*/README.md exists in its action.yml
#   5. inbound anchors other repos link to still exist in DELIVERY-STANDARD.md
#   6. repo matrix vs standardize.sh ALL_REPOS / EXCLUDED_REPOS
#   7. every ```mermaid block parses (only if `npx` + network are available; else skipped)
# Sibling checkouts missing => those links are reported as SKIPPED, not failed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ORG=agentcontextdistributionprotocol
cd "$ROOT"
export ROOT ORG
python3 - <<'PY'
import os, re, subprocess, sys, tempfile, shutil
root=os.environ['ROOT']; org=os.environ['ORG']
parent=os.path.dirname(root)
fails=[]; skipped=[]; checked=0
def fail(m): fails.append(m)

def slug(h):
    h=h.strip().lower()
    h=re.sub(r'[`*_]','',h)           # inline code/emphasis markers vanish
    h=re.sub(r'[^\w\- ]','',h)         # punctuation vanishes
    return h.replace(' ','-')
def anchors(path):
    out=set();
    try: txt=open(path,encoding='utf-8').read()
    except OSError: return None
    infence=False
    for line in txt.splitlines():
        if line.startswith('```'): infence=not infence; continue
        if infence: continue
        m=re.match(r'#{1,6}\s+(.*)',line)
        if m: out.add(slug(re.sub(r'\[([^\]]*)\]\([^)]*\)',r'\1',m.group(1))))
    return out

files=subprocess.run(['git','ls-files','*.md'],capture_output=True,text=True,cwd=root).stdout.split()
files=[f for f in files if not f.startswith('plans/')]
link=re.compile(r'\[[^\]]*\]\(([^)\s]+)\)')
sibdir={'.github':'dotgithub'}
for f in files:
    txt=open(os.path.join(root,f),encoding='utf-8').read()
    infence=False
    for ln,line in enumerate(txt.splitlines(),1):
        if line.startswith('```'): infence=not infence; continue
        if infence: continue
        # 3. line pins in prose
        if f not in ('ASSUMPTIONS.md','DECISIONS.md') and re.search(r'`[\w./-]+\.(?:sh|yml|yaml|md|json|rs):\d+(?:-\d+)?`',line):
            fail(f'{f}:{ln}: line-number pin in prose')
        for m in link.finditer(line):
            url=m.group(1); checked+=1
            if url.startswith('http'):
                mm=re.match(r'https://github\.com/%s/([^/]+)/blob/main/([^#]+)(?:#(.*))?$'%org,url)
                if not mm: continue
                repo,path,frag=mm.groups()
                if repo=='acdp-ci': tgt=os.path.join(root,path)
                else: tgt=os.path.join(parent,sibdir.get(repo,repo),path)
                if not os.path.isdir(os.path.dirname(tgt)) and repo!='acdp-ci':
                    skipped.append(f'{f}:{ln}: sibling {repo} not checked out'); continue
                if not os.path.isfile(tgt): fail(f'{f}:{ln}: sibling file missing: {repo}/{path}'); continue
                if frag and tgt.endswith('.md'):
                    a=anchors(tgt)
                    if a is not None and frag not in a: fail(f'{f}:{ln}: anchor #{frag} not found in {repo}/{path}')
            elif url.startswith('#'):
                a=anchors(os.path.join(root,f))
                if url[1:] not in a: fail(f'{f}:{ln}: anchor {url} not found in {f}')
            elif not url.startswith('mailto:'):
                p,_,frag=url.partition('#')
                tgt=os.path.normpath(os.path.join(root,os.path.dirname(f),p))
                if not os.path.exists(tgt): fail(f'{f}:{ln}: broken relative link {url}'); continue
                if frag and tgt.endswith('.md'):
                    a=anchors(tgt)
                    if frag not in a: fail(f'{f}:{ln}: anchor #{frag} not found in {p}')

# 4. action identifiers
import glob
for readme in glob.glob(os.path.join(root,'actions','*','README.md')):
    d=os.path.dirname(readme); y=os.path.join(d,'action.yml')
    ytxt=open(y).read(); rtxt=open(readme).read()
    for name in re.findall(r'^\| `([a-z][a-z0-9-]*)` \|',rtxt,re.M):
        if not re.search(r'^  %s:'%re.escape(name),ytxt,re.M):
            fail(f'{os.path.relpath(readme,root)}: `{name}` is not an input/output in action.yml')

# 5. inbound anchors
ds=anchors(os.path.join(root,'DELIVERY-STANDARD.md'))
for a in ['sdk-propagation-a-new-acdp-package--its-consumers','spec-propagation-a-new-spec-revision--its-sha-pinners','releasing-acdp-ci-the-v1-tag','credentials']:
    if a not in ds: fail(f'DELIVERY-STANDARD.md: inbound anchor #{a} missing')

# 6. matrix vs standardize.sh
sh=open(os.path.join(root,'scripts','standardize.sh')).read()
allr=re.search(r'^ALL_REPOS="([^"]*)"',sh,re.M).group(1).split()
exc=re.search(r'^EXCLUDED_REPOS="([^"]*)"',sh,re.M).group(1).split()
dstxt=open(os.path.join(root,'DELIVERY-STANDARD.md')).read()
mat=dstxt[dstxt.index('## Repo matrix'):]
mat=mat[:mat.index('\n## ',5)] if '\n## ' in mat[5:] else mat
for r in allr+exc:
    if r=='.github': ok='| `.github` |' in mat
    else: ok=('| %s |'%r in mat) or ('| %s ('%r in mat)
    if not ok: fail(f'DELIVERY-STANDARD.md repo matrix: no row for {r}')

# 7. mermaid
blocks=[]
for f in files:
    t=open(os.path.join(root,f),encoding='utf-8').read()
    for i,b in enumerate(re.findall(r'```mermaid\n(.*?)```',t,re.S)): blocks.append((f,i,b))
if os.environ.get("DOCS_CHECK_MERMAID")=="1" and shutil.which("npx"):
    td=tempfile.mkdtemp()
    for f,i,b in blocks:
        src=os.path.join(td,'b.mmd'); open(src,'w').write(b)
        r=subprocess.run(['npx','-y','@mermaid-js/mermaid-cli','-i',src,'-o',os.path.join(td,'o.svg'),'-q'],capture_output=True,text=True)
        if r.returncode!=0: fail(f'{f}: mermaid block #{i+1} does not parse: {r.stderr.strip()[:200]}')
else:
    skipped.append(f'mermaid: {len(blocks)} block(s) not parsed (set DOCS_CHECK_MERMAID=1; needs npx + network)')

print(f'links checked: {checked}; mermaid blocks: {len(blocks)}')
for s in skipped: print('SKIPPED:',s)
for f in fails: print('FAIL:',f)
print('RESULT:', 'FAIL' if fails else 'OK')
sys.exit(1 if fails else 0)
PY
