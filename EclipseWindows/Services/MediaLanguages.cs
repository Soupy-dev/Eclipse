using System.Globalization;
using System.Text;

namespace Eclipse.Windows.Services;

public sealed record MediaLanguage(string Id,string Name,string NativeName,IReadOnlyList<string> Aliases,string FilterValue)
{
    public bool Matches(string query)
    {
        var searchable=MediaLanguages.SearchKey(string.Join(' ',new[]{Id,Name,NativeName}.Concat(Aliases)));
        return MediaLanguages.SearchKey(query).Split((char[]?)null,StringSplitOptions.RemoveEmptyEntries).All(searchable.Contains);
    }
}

public static class MediaLanguages
{
    private static readonly Dictionary<string,string> PreferredNames=new(){["bh"]="Bihari",["cu"]="Church Slavonic",["el"]="Greek",["gd"]="Scottish Gaelic",["ht"]="Haitian Creole",["ia"]="Interlingua",["km"]="Khmer",["nb"]="Norwegian Bokmål",["nn"]="Norwegian Nynorsk",["ny"]="Chichewa",["tl"]="Tagalog / Filipino"};
    private const string BaseData="aa|aar||Afar\nab|abk||Abkhazian\nae|ave||Avestan\naf|afr||Afrikaans\nak|aka||Akan\nam|amh||Amharic\nan|arg||Aragonese\nar|ara||Arabic\nas|asm||Assamese\nav|ava||Avaric\nay|aym||Aymara\naz|aze||Azerbaijani\nba|bak||Bashkir\nbe|bel||Belarusian\nbg|bul||Bulgarian\nbh|bih||Bihari\nbi|bis||Bislama\nbm|bam||Bambara\nbn|ben||Bengali\nbo|tib|bod|Tibetan\nbr|bre||Breton\nbs|bos||Bosnian\nca|cat||Catalan; Valencian\nce|che||Chechen\nch|cha||Chamorro\nco|cos||Corsican\ncr|cre||Cree\ncs|cze|ces|Czech\ncu|chu||Church Slavic; Old Slavonic; Church Slavonic; Old Bulgarian; Old Church Slavonic\ncv|chv||Chuvash\ncy|wel|cym|Welsh\nda|dan||Danish\nde|ger|deu|German\ndv|div||Divehi; Dhivehi; Maldivian\ndz|dzo||Dzongkha\nee|ewe||Ewe\nel|gre|ell|Modern Greek (1453-)\nen|eng||English\neo|epo||Esperanto\nes|spa||Spanish; Castilian\net|est||Estonian\neu|baq|eus|Basque\nfa|per|fas|Persian\nff|ful||Fulah\nfi|fin||Finnish\nfj|fij||Fijian\nfo|fao||Faroese\nfr|fre|fra|French\nfy|fry||Western Frisian\nga|gle||Irish\ngd|gla||Gaelic; Scottish Gaelic\ngl|glg||Galician\ngn|grn||Guarani\ngu|guj||Gujarati\ngv|glv||Manx\nha|hau||Hausa\nhe|heb||Hebrew\nhi|hin||Hindi\nho|hmo||Hiri Motu\nhr|hrv||Croatian\nht|hat||Haitian; Haitian Creole\nhu|hun||Hungarian\nhy|arm|hye|Armenian\nhz|her||Herero\nia|ina||Interlingua (International Auxiliary Language Association)\nid|ind||Indonesian\nie|ile||Interlingue; Occidental\nig|ibo||Igbo\nii|iii||Sichuan Yi; Nuosu\nik|ipk||Inupiaq\nio|ido||Ido\nis|ice|isl|Icelandic\nit|ita||Italian\niu|iku||Inuktitut\nja|jpn||Japanese\njv|jav||Javanese\nka|geo|kat|Georgian\nkg|kon||Kongo\nki|kik||Kikuyu; Gikuyu\nkj|kua||Kuanyama; Kwanyama\nkk|kaz||Kazakh\nkl|kal||Kalaallisut; Greenlandic\nkm|khm||Central Khmer\nkn|kan||Kannada\nko|kor||Korean\nkr|kau||Kanuri\nks|kas||Kashmiri\nku|kur||Kurdish\nkv|kom||Komi\nkw|cor||Cornish\nky|kir||Kirghiz; Kyrgyz\nla|lat||Latin\nlb|ltz||Luxembourgish; Letzeburgesch\nlg|lug||Ganda\nli|lim||Limburgan; Limburger; Limburgish\nln|lin||Lingala\nlo|lao||Lao\nlt|lit||Lithuanian\nlu|lub||Luba-Katanga\nlv|lav||Latvian\nmg|mlg||Malagasy\nmh|mah||Marshallese\nmi|mao|mri|Maori\nmk|mac|mkd|Macedonian\nml|mal||Malayalam\nmn|mon||Mongolian\nmr|mar||Marathi\nms|may|msa|Malay\nmt|mlt||Maltese\nmy|bur|mya|Burmese\nna|nau||Nauru\nnb|nob||Norwegian Bokmål\nnd|nde||North Ndebele\nne|nep||Nepali\nng|ndo||Ndonga\nnl|dut|nld|Dutch; Flemish\nnn|nno||Norwegian Nynorsk\nno|nor||Norwegian\nnr|nbl||South Ndebele\nnv|nav||Navajo; Navaho\nny|nya||Chichewa; Chewa; Nyanja\noc|oci||Occitan (post 1500)\noj|oji||Ojibwa\nom|orm||Oromo\nor|ori||Oriya\nos|oss||Ossetian; Ossetic\npa|pan||Panjabi; Punjabi\npi|pli||Pali\npl|pol||Polish\nps|pus||Pushto; Pashto\npt|por||Portuguese\nqu|que||Quechua\nrm|roh||Romansh\nrn|run||Rundi\nro|rum|ron|Romanian; Moldavian; Moldovan\nru|rus||Russian\nrw|kin||Kinyarwanda\nsa|san||Sanskrit\nsc|srd||Sardinian\nsd|snd||Sindhi\nse|sme||Northern Sami\nsg|sag||Sango\nsi|sin||Sinhala; Sinhalese\nsk|slo|slk|Slovak\nsl|slv||Slovenian\nsm|smo||Samoan\nsn|sna||Shona\nso|som||Somali\nsq|alb|sqi|Albanian\nsr|srp||Serbian\nss|ssw||Swati\nst|sot||Sotho, Southern\nsu|sun||Sundanese\nsv|swe||Swedish\nsw|swa||Swahili\nta|tam||Tamil\nte|tel||Telugu\ntg|tgk||Tajik\nth|tha||Thai\nti|tir||Tigrinya\ntk|tuk||Turkmen\ntl|tgl||Tagalog\ntn|tsn||Tswana\nto|ton||Tonga (Tonga Islands)\ntr|tur||Turkish\nts|tso||Tsonga\ntt|tat||Tatar\ntw|twi||Twi\nty|tah||Tahitian\nug|uig||Uighur; Uyghur\nuk|ukr||Ukrainian\nur|urd||Urdu\nuz|uzb||Uzbek\nve|ven||Venda\nvi|vie||Vietnamese\nvo|vol||Volapük\nwa|wln||Walloon\nwo|wol||Wolof\nxh|xho||Xhosa\nyi|yid||Yiddish\nyo|yor||Yoruba\nza|zha||Zhuang; Chuang\nzh|chi|zho|Chinese\nzu|zul||Zulu";
    public static IReadOnlyList<MediaLanguage> All {get;}=Build();
    private static readonly Dictionary<string,MediaLanguage> ByAlias=Index();
    private static readonly HashSet<string> RegionStopWords=["audio","dub","dubbed","dubs","track","tracks","sub","subs","subtitle","captions"];

    private static IReadOnlyList<MediaLanguage> Build()
    {
        var entries=new List<MediaLanguage>();
        foreach(var line in BaseData.Split('\n'))
        {
            var f=line.Split('|');if(f.Length!=4)continue;
            var names=f[3].Split(';').Select(n=>n.Trim()).ToArray();
            var name=PreferredNames.GetValueOrDefault(f[0])??names.FirstOrDefault()??f[0];
            entries.Add(Entry(f[0],name,Native(f[0])??name,[f[1],f[2],..names]));
        }
        entries.Add(Entry("en-US","American English","English (United States)",["US English","English US","eng-US"]));
        entries.Add(Entry("en-GB","British English","English (United Kingdom)",["UK English","English UK","eng-GB"]));
        entries.Add(Entry("es-ES","Spanish (Spain)","Español (España)",["Castilian Spanish","European Spanish","spa-ES"]));
        entries.Add(Entry("es-419","Latin American Spanish","Español latinoamericano",["Latino","Latin","lat","latam","es-419","spa-LATAM","Spanish (Latino)","Spanish (Latin America)","Spanish Latino","Latinoamericano"]));
        entries.Add(Entry("pt-BR","Brazilian Portuguese","Português (Brasil)",["Portuguese (Brazil)","Portuguese BR","por-BR"]));
        entries.Add(Entry("pt-PT","European Portuguese","Português (Portugal)",["Portuguese (Portugal)","Portuguese PT","por-PT"]));
        entries.Add(Entry("zh-Hans","Simplified Chinese","简体中文",["Chinese Simplified","zho-Hans","chi-Hans"]));
        entries.Add(Entry("zh-Hant","Traditional Chinese","繁體中文",["Chinese Traditional","zho-Hant","chi-Hant"]));
        entries.Add(Entry("cmn","Mandarin Chinese","普通话",["Mandarin","cmn","国语","國語"]));
        entries.Add(Entry("yue","Cantonese","粵語",["Cantonese Chinese","yue","广东话","廣東話"]));
        entries.Add(Entry("fil","Filipino","Filipino",["fil","Pilipino"]));
        return entries.OrderBy(e=>e.Name,StringComparer.CurrentCultureIgnoreCase).ToArray();
    }
    private static string? Native(string id)
    {
        try{var native=CultureInfo.GetCultureInfo(id,true).NativeName;return string.IsNullOrWhiteSpace(native)?null:native;}
        catch(CultureNotFoundException){return null;}
    }
    private static Dictionary<string,MediaLanguage> Index()
    {
        var result=new Dictionary<string,MediaLanguage>();
        foreach(var entry in All)foreach(var alias in new[]{entry.Id,entry.Name,entry.NativeName}.Concat(entry.Aliases))result.TryAdd(LookupKey(alias),entry);
        foreach(var (alias,id) in new[]{("jp","ja"),("iw","he"),("ji","yi"),("in","id"),("mo","ro"),("esp","es"),("farsi","fa"),("lat","la"),("latin","la")})
            if(All.FirstOrDefault(e=>e.Id==id) is {} target)result[alias]=target;
        return result;
    }
    private static MediaLanguage Entry(string id,string name,string native,IEnumerable<string> aliases)=>
        new(id,name,native,aliases.Where(a=>a.Length>0).ToArray(),id.Length==2&&id is not ("nb" or "nn")?id:"language:"+id);
    internal static string SearchKey(string value)
    {
        var builder=new StringBuilder(value.Length);
        foreach(var c in value.Normalize(NormalizationForm.FormKD))if(CharUnicodeInfo.GetUnicodeCategory(c)!=UnicodeCategory.NonSpacingMark)builder.Append(c);
        return builder.ToString().ToLowerInvariant();
    }
    private static string LookupKey(string value)=>SearchKey(value.Trim()).Replace('_','-');

    public static MediaLanguage? Find(string value)
    {
        var key=LookupKey(value);var unwrapped=key.StartsWith("language:")?key["language:".Length..]:key;
        if(ByAlias.TryGetValue(unwrapped,out var entry))return entry;
        var parts=unwrapped.Split('-');
        if(parts.Length is <2 or >4||!ByAlias.TryGetValue(parts[0],out var baseEntry)||baseEntry.Id.Length!=2)return null;
        if(!parts.Skip(1).All(p=>p.Length is >=2 and <=8&&!RegionStopWords.Contains(p)&&p.All(char.IsAsciiLetterOrDigit)))return null;
        var suffixes=parts.Skip(1).Select(p=>p.Length==2||p.All(char.IsAsciiDigit)?p.ToUpperInvariant():p.Length==4?char.ToUpperInvariant(p[0])+p[1..]:p).ToArray();
        var id=string.Join('-',[baseEntry.Id,..suffixes]);
        if(ByAlias.TryGetValue(LookupKey(id),out var known))return known;
        string name;try{var culture=CultureInfo.GetCultureInfo(id,true);name=culture.EnglishName;}catch(CultureNotFoundException){name=$"{baseEntry.Name} ({string.Join('-',suffixes)})";}
        return Entry(id,name,Native(id)??name,[value]);
    }
    public static string? CanonicalId(string value)=>Find(value)?.Id;
    public static string DisplayName(string value)=>Find(value)?.Name??value.Trim();
    public static MediaLanguage? FilterLanguage(string value)
    {
        var key=LookupKey(value);if(key.StartsWith("language:"))return Find(value);
        var tokens=key.Split(c=>!char.IsLetterOrDigit(c));
        string[] latino=["lat","latin","latino","latam","419","latinoamerican","latinamerican"];
        if(tokens.Any(latino.Contains)&&tokens.Any(new[]{"es","spa","spanish","lat","latin","latino","latam"}.Contains))return Find("es-419");
        if(key is "cantonese" or "mandarin")return Find("zh");
        if(key is "fil" or "filipino" or "pilipino")return Find("tl");
        if(key is "nb" or "nob" or "nn" or "nno")return Find("no");
        var prefix=key.Split('-')[0];
        if(prefix.Length<key.Length&&prefix.Length>0&&FilterLanguage(prefix) is {Id.Length:2} baseEntry)return baseEntry;
        return Find(value);
    }
    public static string? FilterCanonicalId(string value)=>FilterLanguage(value)?.Id;
    public static string FilterDisplayName(string value)=>FilterLanguage(value)?.Name??value.Trim();
    public static string? CanonicalFilterValue(string value)=>FilterLanguage(value)?.FilterValue;
    public static IEnumerable<MediaLanguage> Search(string query)=>All.Where(e=>e.Matches(query));
    public static bool RuleMatches(string ruleId,string languageId)
    {
        if(Find(ruleId) is not {} rule||Find(languageId) is not {} language)return false;
        if(rule.Id==language.Id)return true;
        if(rule.Id.Length!=2||language.Id=="es-419")return false;
        if(language.Id.StartsWith(rule.Id+"-"))return true;
        if(rule.Id=="zh"&&language.Id is "cmn" or "yue")return true;
        if(rule.Id=="no"&&language.Id is "nb" or "nn")return true;
        return rule.Id=="tl"&&language.Id=="fil";
    }
}
