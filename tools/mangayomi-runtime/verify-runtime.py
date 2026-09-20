import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent
bundle = root.parent.parent / 'Eclipse/JSLoader/Resources/MangayomiDartRuntime.js'
script = '''
import 'package:mangayomi/bridge_lib.dart';
import 'dart:convert';
class Fixture extends MProvider {
  MSource source;
  Fixture(this.source);
  final Client client = Client(null, '{"followRedirects":false}');
  List<dynamic> getSourcePreferences() => [
    ListPreference(key:'audio', title:'Audio', valueIndex:0, entries:['Sub','Dub'], entryValues:['sub','dub']),
    EditTextPreference(key:'host', title:'Host', value:'https://fixture.invalid'),
  ];
  List<dynamic> getFilterList() => [SelectFilter('kind','Kind',0,[SelectFilterOption('All','')])];
  Future<MPages> search(String query, int page, FilterList filters) async {
    final response = await client.post(Uri.parse('https://fixture.invalid/search'), headers:{'Authorization':'fixture-token'}, body:{'q':query});
    final document = parseHtml(response.body);
    final matched = document.select('article:has(a):contains(Alpha)');
    final xpathTitles = xpath(response.body, '//article/a/@title');
    final manga = MManga();
    manga.name = '${xpathTitles.first} ${getPreferenceValue(source.id,'audio')}';
    manga.link = matched.first.selectFirst('a').getHref;
    manga.imageUrl = matched.first.selectFirst('img').getSrc;
    return MPages([manga],false);
  }
  Future<MManga> getDetail(String url) async {
    final manga = MManga();
    manga.name = 'Alpha';
    manga.chapters = [MChapter(name:'Episode 1', url:'/watch/1')];
    return manga;
  }
  Future<List<MVideo>> getVideoList(String url) async => [MVideo('https://fixture.invalid/media.m3u8','1080p Dub',url,headers:{'Referer':'https://fixture.invalid/'},subtitles:[MTrack(file:'https://fixture.invalid/en.vtt',label:'English')])];
}
Fixture main(MSource source) => Fixture(source);
'''
source = {'id':42,'name':'Fixture','baseUrl':'https://fixture.invalid','lang':'en'}
html = '<article><a href="/alpha" title="Alpha">Alpha</a><img src="https://fixture.invalid/alpha.jpg"></article>'
base = {'script':script,'source':source,'arguments':{},'preferences':{},'fixture':{'*':html}}
with tempfile.TemporaryDirectory(prefix='mangayomi-runtime-verify-') as temporary:
    directory = Path(temporary)
    executable = directory / 'verify'
    subprocess.run(['swiftc', str(root / 'verify-runtime.swift'), '-o', str(executable)], check=True)
    def run(operation, **changes):
        request = {**base,'operation':operation,**changes}
        path = directory / 'request.json'
        path.write_text(json.dumps(request))
        response = subprocess.run([str(executable), str(path), str(bundle)], check=True, capture_output=True, text=True, timeout=20)
        value = json.loads(response.stdout)
        if 'error' in value:
            raise AssertionError(value['error'])
        return value
    validated = run('validate')['result']
    assert validated['defaults']['audio'] == 'sub'
    filtered = run('filters')['result']
    assert filtered[0]['values'][0]['type_name'] == 'SelectOption'
    searched = run('search', arguments={'query':'Alpha & Beta','page':1}, preferences={'audio':'dub'})
    assert searched['result']['list'][0]['name'] == 'Alpha dub'
    assert searched['result']['list'][0]['link'] == '/alpha'
    assert searched['result']['list'][0]['imageUrl'] == 'https://fixture.invalid/alpha.jpg'
    assert searched['http'][0]['followRedirects'] is False
    assert {key.lower(): value for key, value in searched['http'][0]['headers'].items()}['authorization'] == 'fixture-token'
    import base64
    assert base64.b64decode(searched['http'][0]['bodyBase64']) == b'q=Alpha+%26+Beta'
    details = run('detail', arguments={'url':'/alpha'})['result']
    assert details['chapters'][0]['url'] == '/watch/1'
    videos = run('videos', arguments={'url':'/watch/1'})['result']
    assert videos[0]['headers']['Referer'] == 'https://fixture.invalid/'
    assert videos[0]['subtitles'][0]['label'] == 'English'
    extracted = run('videos', extractor='sibnetExtractor', arguments=['https://fixture.invalid/embed','Fixture'], fixture={'*':'player.src({src:"/media.mp4"});'})['result']
    assert extracted[0]['url'] == 'https://fixture.invalid/media.mp4'
    assert extracted[0]['headers']['Referer'] == 'https://fixture.invalid/embed'
    malicious = {**base,'script':'main(source) { while (true) {} }','operation':'validate','maxSteps':5000}
    path = directory / 'request.json'
    path.write_text(json.dumps(malicious))
    response = subprocess.run([str(executable),str(path),str(bundle)],check=True,capture_output=True,text=True,timeout=20)
    assert 'step limit' in json.loads(response.stdout)['error']
    print('PASS: real JSC interpreter, defaults/overrides, filters, HTTP body/headers/redirect policy, CSS/XPath, search/detail/video models, native extractor, execution budget')
