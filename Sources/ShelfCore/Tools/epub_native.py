"""Build a script-free, spine-ordered reader document without ebook conversion."""
from pathlib import Path, PurePosixPath
import copy
import html
import json
import posixpath
import re
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile


def local(tag):
    return tag.rsplit('}',1)[-1]


def resolve(base, href):
    parsed=urllib.parse.urlsplit(href)
    if parsed.scheme or parsed.netloc:
        return None
    path=posixpath.normpath(posixpath.join(posixpath.dirname(base),urllib.parse.unquote(parsed.path))) if parsed.path else base
    if path.startswith('../') or path.startswith('/'):
        raise ValueError('EPUB resource escapes its archive')
    return path,urllib.parse.unquote(parsed.fragment)


def prepare_epub(source: Path, staging: Path):
    content=staging/'content'; book=content/'book'; book.mkdir(parents=True)
    with zipfile.ZipFile(source) as archive:
        entries=archive.infolist()
        if len(entries)>20000 or sum(x.file_size for x in entries)>512*1024*1024:
            raise ValueError('EPUB exceeds the reader extraction limit')
        for item in entries:
            target=(book/item.filename).resolve()
            if not target.is_relative_to(book.resolve()):
                raise ValueError('EPUB contains an unsafe archive path')
        container=ET.fromstring(archive.read('META-INF/container.xml'))
        opf=next(x.attrib['full-path'] for x in container.iter() if local(x.tag)=='rootfile')
        package=ET.fromstring(archive.read(opf))
        manifest={x.attrib['id']:x.attrib for x in package.iter() if local(x.tag)=='item'}
        spine=next(x for x in package.iter() if local(x.tag)=='spine')
        ordered=[]
        for ref in spine:
            item=manifest.get(ref.get('idref'))
            if item and ref.get('linear')!='no' and item.get('media-type') in ('application/xhtml+xml','text/html'):
                ordered.append(resolve(opf,item['href'])[0])
        if not ordered:raise ValueError('EPUB has no readable spine')
        docs={path:ET.fromstring(archive.read(path)) for path in ordered}
        # Parse author navigation; preserve nesting, then order by the actual spine.
        toc=[]
        nav=next((x for x in manifest.values() if 'nav' in x.get('properties','').split()),None)
        if nav:
            nav_path=resolve(opf,nav['href'])[0]
            tree=ET.fromstring(archive.read(nav_path))
            nav_node=next((x for x in tree.iter() if local(x.tag)=='nav' and any('toc' in v.split() for k,v in x.attrib.items() if local(k)=='type')),None)
            if nav_node is not None:
                def walk(node,depth=0):
                    for child in node:
                        if local(child.tag)=='a' and child.get('href'):
                            target=resolve(nav_path,child.get('href'))
                            if target:toc.append((target,' '.join(''.join(child.itertext()).split()),max(0,depth-1)))
                        else:walk(child,depth+(local(child.tag)=='ol'))
                walk(nav_node)
        if not toc:
            ncx=manifest.get(spine.get('toc')) or next((x for x in manifest.values() if x.get('media-type')=='application/x-dtbncx+xml'),None)
            if ncx:
                ncx_path=resolve(opf,ncx['href'])[0]
                def walk_ncx(node,depth=0):
                    for child in node:
                        if local(child.tag)=='navPoint':
                            label=next((x for x in child if local(x.tag)=='navLabel'),None)
                            target=next((x for x in child if local(x.tag)=='content'),None)
                            if target is not None:
                                href=resolve(ncx_path,target.get('src',''))
                                if href:toc.append((href,' '.join(''.join(label.itertext()).split()) if label is not None else 'Chapter',depth))
                            walk_ncx(child,depth+1)
                        else:walk_ncx(child,depth)
                walk_ncx(ET.fromstring(archive.read(ncx_path)))
        sections={path:f'shelf-spine-{i}' for i,path in enumerate(ordered)}
        anchors={}
        ranks={}
        for i,(path,tree) in enumerate(docs.items()):
            for n,node in enumerate(tree.iter()):
                if node.get('id'):
                    anchors[(path,node.get('id'))]=sections[path]+'--'+node.get('id')
                    ranks[(path,node.get('id'))]=(i,n)
        def target_id(path,fragment):return anchors.get((path,fragment),sections.get(path))
        chapters=[];seen=set()
        for (path,fragment),label,depth in sorted(toc,key=lambda x:ranks.get(x[0],(ordered.index(x[0][0]),-1)) if x[0][0] in sections else (len(ordered),0)):
            identifier=target_id(path,fragment)
            if identifier and identifier not in seen:
                chapters.append({'id':identifier,'title':label or 'Chapter','depth':depth});seen.add(identifier)
        sheets=[]; bodies=[]
        for path,tree in docs.items():
            for node in tree.iter():
                if local(node.tag)=='link' and 'stylesheet' in node.get('rel','').split() and node.get('href'):
                    resource=resolve(path,node.get('href'))
                    if resource:sheets.append('book/'+urllib.parse.quote(resource[0],safe='/'))
            body=next((x for x in tree.iter() if local(x.tag)=='body'),None)
            if body is None:raise ValueError('EPUB chapter has no body')
            body=copy.deepcopy(body)
            for parent in list(body.iter()):
                for child in list(parent):
                    if local(child.tag) in ('script','iframe','object','embed','base','form'):parent.remove(child)
            for node in body.iter():
                node.tag=local(node.tag)
                for key in list(node.attrib):
                    if key.startswith('{http://www.w3.org/1999/xlink}'):
                        node.set(local(key),node.attrib.pop(key))
                for key in list(node.attrib):
                    if local(key).lower().startswith('on'):del node.attrib[key]
                if node.get('id'):node.set('id',anchors.get((path,node.get('id')),sections[path]+'--'+node.get('id')))
                for key in list(node.attrib):
                    name=local(key)
                    if name not in ('src','href','poster'):continue
                    value=node.attrib[key]
                    if re.match(r'(?i)\s*(javascript|vbscript):',value):del node.attrib[key];continue
                    resource=resolve(path,value)
                    if resource:
                        destination=target_id(*resource) if name=='href' else None
                        node.attrib[key]='#'+destination if destination else 'book/'+urllib.parse.quote(resource[0],safe='/')+('#'+urllib.parse.quote(resource[1]) if resource[1] else '')
            body.tag='section';body.set('id',sections[path]);body.set('data-spine-index',str(ordered.index(path)))
            bodies.append(ET.tostring(body,encoding='unicode',method='html'))
        if not chapters:
            for i,path in enumerate(ordered):
                heading=next((x for x in docs[path].iter() if local(x.tag) in ('h1','h2','h3')),None)
                title=' '.join(''.join(heading.itertext()).split()) if heading is not None else f'Section {i+1}'
                chapters.append({'id':sections[path],'title':title,'depth':0})
        archive.extractall(book)
    links=''.join(f'<link rel="stylesheet" href="{html.escape(path,quote=True)}">' for path in dict.fromkeys(sheets))
    title=next((''.join(x.itertext()) for x in package.iter() if local(x.tag)=='title'),'Book')
    (content/'index.html').write_text('<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="script-src \'none\'; object-src \'none\'; frame-src \'none\'"><title>'+html.escape(title)+'</title>'+links+'</head><body>'+''.join(bodies)+'</body></html>',encoding='utf-8')
    (staging/'chapters.json').write_text(json.dumps(chapters,ensure_ascii=False),encoding='utf-8')
    return content/'index.html'
