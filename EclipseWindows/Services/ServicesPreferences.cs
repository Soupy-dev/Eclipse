using System.Text.Json;
using System.Text.Json.Serialization;

namespace Eclipse.Windows.Services;

public sealed class ServicesPreferences
{
    public static readonly int[] SupportedQualityHeights=[2160,1440,1080,720,480,360];
    [JsonPropertyName("autoUpdateServicesEnabled")] public bool AutoUpdate {get;set;}=true;
    [JsonPropertyName("servicesAutoModeSourceIds")] public List<string> AutoModeSourceIds {get;set;}=[];
    [JsonPropertyName("servicesAutoModeSourceOrderIds")] public List<string> SourceOrder {get;set;}=[];
    [JsonPropertyName("servicesStremioStyleSheetEnabled")] public bool StremioStyleList {get;set;}
    [JsonPropertyName("servicesResultMinimumSimilarity")] public double MinimumSimilarity {get;set;}=.85;
    [JsonPropertyName("servicesDropMismatchedResults")] public bool DropMismatchedResults {get;set;}=true;
    [JsonPropertyName("servicesHiddenStreamLanguages")] public List<string> HiddenLanguages {get;set;}=[];
    [JsonPropertyName("servicesIncludedStreamLanguages")] public List<string> IncludedLanguages {get;set;}=[];
    [JsonPropertyName("servicesHideStreamsWithoutLanguageData")] public bool HideUnknownLanguage {get;set;}
    [JsonPropertyName("servicesAssumeOriginalAudio")] public bool AssumeOriginalAudio {get;set;}
    [JsonPropertyName("servicesTreatDubbedAnimeAsEnglish")] public bool TreatDubbedAnimeAsEnglish {get;set;}
    [JsonPropertyName("servicesHiddenStreamQualities")] public List<int> HiddenQualities {get;set;}=[];
    [JsonPropertyName("servicesHideStreamsWithoutDetectedQuality")] public bool HideUnknownQuality {get;set;}
    [JsonPropertyName("servicesExtraRulesSourceIds")] public List<string>? ExtraRulesSourceIds {get;set;}
    [JsonPropertyName("contentBlockingBlockAddonSubtitles")] public bool BlockAddonSubtitles {get;set;}
    [JsonPropertyName("contentBlockingBlockAddonCatalogs")] public bool BlockAddonCatalogs {get;set;}
    [JsonPropertyName("highQualityThreshold")] public double HighQualityThreshold {get;set;}=.9;
    [JsonPropertyName("selectedSimilarityAlgorithm")] public string SimilarityAlgorithm {get;set;}="hybrid";
    [JsonExtensionData] public Dictionary<string,JsonElement>? Extra {get;set;}

    public bool StremioComponent(string component,string sourceId)=>Extra?.TryGetValue($"stremioAddonComponent.{component}.{sourceId}",out var v)!=true||v.ValueKind!=JsonValueKind.False;
    public void SetStremioComponent(string component,string sourceId,bool enabled)
    {
        var key=$"stremioAddonComponent.{component}.{sourceId}";Extra??=[];
        if(enabled)Extra.Remove(key);else Extra[key]=JsonSerializer.SerializeToElement(false);
    }
    public void ForgetSource(string sourceId)
    {
        SourceOrder.Remove(sourceId);AutoModeSourceIds.Remove(sourceId);ExtraRulesSourceIds?.Remove(sourceId);
        if(Extra is not null)foreach(var key in Extra.Keys.Where(k=>k.StartsWith("stremioAddonComponent.")&&k.EndsWith("."+sourceId)).ToArray())Extra.Remove(key);
    }
    public bool ExtraRulesApply(string? sourceId)=>sourceId is null||ExtraRulesSourceIds is null||ExtraRulesSourceIds.Contains(sourceId);

    public void Normalize()
    {
        MinimumSimilarity=double.IsFinite(MinimumSimilarity)?Math.Clamp(MinimumSimilarity,.5,1):.85;
        HighQualityThreshold=double.IsFinite(HighQualityThreshold)?Math.Clamp(HighQualityThreshold,0,1):.9;
        if(SimilarityAlgorithm is not ("hybrid" or "jaro_winkler" or "levenshtein"))SimilarityAlgorithm="hybrid";
        SourceOrder=SourceOrder.Where(s=>s is {Length:>0 and <=300}).Distinct().Take(1000).ToList();
        AutoModeSourceIds=AutoModeSourceIds.Where(s=>s is {Length:>0 and <=300}).Distinct().Take(1000).ToList();
        HiddenLanguages=SanitizedLanguages(HiddenLanguages);IncludedLanguages=SanitizedLanguages(IncludedLanguages);
        HiddenQualities=HiddenQualities.Where(SupportedQualityHeights.Contains).Distinct().OrderDescending().ToList();
        if(ExtraRulesSourceIds is not null)ExtraRulesSourceIds=SanitizedRuleSources(ExtraRulesSourceIds);
    }
    public static List<string> SanitizedLanguages(IEnumerable<string> values)
    {
        var seen=new HashSet<string>();var result=new List<string>();
        foreach(var value in values)
        {
            var trimmed=value.Trim();if(trimmed.Length==0)continue;
            var language=MediaLanguages.CanonicalFilterValue(trimmed)??trimmed;if(language.Length>40)language=language[..40];
            var normalized=StreamLanguageFilter.NormalizedKey(language);
            if(!seen.Add(MediaLanguages.FilterCanonicalId(language)??(normalized.Length==0?language.ToLowerInvariant():normalized)))continue;
            result.Add(language);if(result.Count==40)break;
        }
        return result;
    }
    public static List<string> SanitizedRuleSources(IEnumerable<string> values)=>
        values.Select(v=>v.Trim()).Where(v=>v.Length is >0 and <=268&&(v.StartsWith("service:")||v.StartsWith("stremio:")||ValidScopedSource(v,"skystream:")||ValidScopedSource(v,"nuvio:"))).Distinct().Take(200).ToList();
    public static bool ValidScopedSource(string id,string prefix)
    {
        if(!id.StartsWith(prefix)||id.Length>268)return false;
        var parts=id[prefix.Length..].Split("::");
        return parts.Length is 1 or 2&&parts.All(p=>p.Length is >0 and <=128&&!p.Contains("..")&&p.All(c=>char.IsAsciiLetterOrDigit(c)||c is '.' or '_' or '-')&&char.IsAsciiLetterOrDigit(p[0])&&char.IsAsciiLetterOrDigit(p[^1]));
    }
    public static string QualityLabel(int height)=>height==2160?"4K / 2160p":$"{height}p";
}

public sealed class ServicesPreferenceStore
{
    private static readonly JsonSerializerOptions Options=new(){WriteIndented=true};
    public static ServicesPreferenceStore Shared {get;}=new();
    private readonly string _path=LocalProtection.LocalPath("services-preferences.json");
    public ServicesPreferences Value {get;private set;}=new();
    public string? ReadError {get;private set;}
    public event EventHandler? Changed;
    private ServicesPreferenceStore()
    {
        try
        {
            if(File.Exists(_path)){if(new FileInfo(_path).Length>512*1024)throw new IOException();Value=JsonSerializer.Deserialize<ServicesPreferences>(File.ReadAllText(_path),Options)??throw new JsonException();}
            Value.Normalize();
        }
        catch{Value=new();ReadError="Saved source settings could not be read. The original file has been preserved.";}
    }
    public ServicesPreferences Copy()=>JsonSerializer.Deserialize<ServicesPreferences>(JsonSerializer.Serialize(Value,Options),Options)!;
    public void Save(ServicesPreferences value)
    {
        if(ReadError is not null)throw new IOException(ReadError);
        value.Normalize();var bytes=JsonSerializer.SerializeToUtf8Bytes(value,Options);
        if(bytes.Length>512*1024)throw new IOException("Source settings exceed the local size limit.");
        LocalProtection.WriteAtomically(_path,bytes);Value=value;StreamLanguageFilter.Invalidate();Changed?.Invoke(this,EventArgs.Empty);
    }
    public void Update(Action<ServicesPreferences> change){var copy=Copy();change(copy);Save(copy);}
}

public static class SourceOrder
{
    private static void Change(Action<ServicesPreferences> change){try{ServicesPreferenceStore.Shared.Update(change);}catch(Exception error) when(error is IOException or UnauthorizedAccessException){}}
    public static void Append(string sourceId)=>Change(p=>{if(!p.AutoModeSourceIds.Contains(sourceId))p.AutoModeSourceIds.Add(sourceId);if(!p.SourceOrder.Contains(sourceId))p.SourceOrder.Add(sourceId);});
    public static void Enroll(IReadOnlyCollection<string> sourceIds){if(sourceIds.Count==0||sourceIds.All(ServicesPreferenceStore.Shared.Value.SourceOrder.Contains))return;Change(p=>{foreach(var id in sourceIds.Where(id=>!p.SourceOrder.Contains(id))){if(!p.AutoModeSourceIds.Contains(id))p.AutoModeSourceIds.Add(id);p.SourceOrder.Add(id);}});}
    public static void Remove(string sourceId)=>Change(p=>{p.AutoModeSourceIds.Remove(sourceId);p.SourceOrder.Remove(sourceId);});
    public static void Forget(string sourceId)=>Change(p=>p.ForgetSource(sourceId));
}
