namespace Eclipse.Windows.Services;

public enum SourceKind { Service, Stremio, Nuvio }

public sealed record SourceEntry(string SourceId,SourceKind Kind,string Name,long SortIndex,bool IsActive,object Model)
{
    public JsService? Service=>Model as JsService;
    public StremioAddon? Addon=>Model as StremioAddon;
    public NuvioScraper? Scraper=>Model as NuvioScraper;
}

public static class SourceRegistry
{
    public static event EventHandler? Changed;
    private static bool _hooked;
    public static void Hook()
    {
        if(_hooked)return;_hooked=true;
        JsServices.Shared.Changed+=(_,_)=>Changed?.Invoke(null,EventArgs.Empty);
        StremioAddonStore.Shared.Changed+=(_,_)=>Changed?.Invoke(null,EventArgs.Empty);
        NuvioPlugins.Shared.Changed+=(_,_)=>Changed?.Invoke(null,EventArgs.Empty);
    }
    public static IReadOnlyList<SourceEntry> Unified()
    {
        var entries=new List<SourceEntry>();
        entries.AddRange(JsServices.Shared.Services.Select(s=>new SourceEntry(s.SourceId,SourceKind.Service,s.Metadata.SourceName,s.SortIndex,s.IsActive,s)));
        entries.AddRange(StremioAddonStore.Shared.Addons.Select(a=>new SourceEntry(a.SourceId,SourceKind.Stremio,a.Manifest.Name,a.SortIndex,a.IsActive,a)));
        entries.AddRange(NuvioPlugins.Shared.ActiveScrapers.Select(s=>new SourceEntry(s.Id,SourceKind.Nuvio,s.DisplayName,long.MaxValue,true,s)));
        var rank=new Dictionary<string,int>();var order=ServicesPreferenceStore.Shared.Value.SourceOrder;
        for(var i=0;i<order.Count;i++)rank.TryAdd(order[i],i);
        entries.Sort((l,r)=>
        {
            var hl=rank.TryGetValue(l.SourceId,out var lr);var hr=rank.TryGetValue(r.SourceId,out var rr);
            if(hl&&hr&&lr!=rr)return lr.CompareTo(rr);
            if(hl!=hr)return hl?-1:1;
            if(l.SortIndex!=r.SortIndex)return l.SortIndex.CompareTo(r.SortIndex);
            return string.Compare(l.Name,r.Name,StringComparison.CurrentCultureIgnoreCase);
        });
        return entries;
    }
    public static void SaveOrder(IReadOnlyList<SourceEntry> items)
    {
        var visible=items.Select(i=>i.SourceId).ToList();
        ServicesPreferenceStore.Shared.Update(p=>
        {
            var hidden=p.SourceOrder.Where(id=>!visible.Contains(id)).ToList();
            p.SourceOrder=[..visible,..hidden];
        });
        var services=items.Where(i=>i.Kind==SourceKind.Service).Select(i=>i.Service!.Id).ToList();
        if(services.Count>0&&!services.SequenceEqual(JsServices.Shared.Services.Select(s=>s.Id)))JsServices.Shared.Reorder(services);
        var addons=items.Where(i=>i.Kind==SourceKind.Stremio).Select(i=>i.Addon!.Id).ToList();
        if(addons.Count>0&&!addons.SequenceEqual(StremioAddonStore.Shared.Addons.Select(a=>a.Id)))StremioAddonStore.Shared.Reorder(addons);
        Changed?.Invoke(null,EventArgs.Empty);
    }
    public static void SetActive(SourceEntry entry,bool active)
    {
        switch(entry.Kind)
        {
            case SourceKind.Service:JsServices.Shared.SetActive(entry.Service!,active);break;
            case SourceKind.Stremio:StremioAddonStore.Shared.SetActive(entry.Addon!,active);break;
            case SourceKind.Nuvio:NuvioPlugins.Shared.SetScraperEnabled(entry.SourceId,active);break;
        }
    }
    public static bool HasDisabledSource=>JsServices.Shared.Services.Any(s=>!s.IsActive)||StremioAddonStore.Shared.Addons.Any(a=>!a.IsActive)||NuvioPlugins.Shared.State.Repositories.Count>0&&(!NuvioPlugins.Shared.State.PluginsEnabled||NuvioPlugins.Shared.State.Repositories.Any(r=>!r.IsEnabled)||NuvioPlugins.Shared.State.Scrapers.Any(s=>s.ManifestEnabled&&!s.Enabled));
    public static bool HasEnabledSource=>JsServices.Shared.Services.Any(s=>s.IsActive)||StremioAddonStore.Shared.Addons.Any(a=>a.IsActive)||NuvioPlugins.Shared.ActiveScrapers.Any();
    public static void SetAllEnabled(bool enabled)
    {
        foreach(var service in JsServices.Shared.Services.ToArray())if(service.IsActive!=enabled)JsServices.Shared.SetActive(service,enabled);
        foreach(var addon in StremioAddonStore.Shared.Addons.ToArray())if(addon.IsActive!=enabled)StremioAddonStore.Shared.SetActive(addon,enabled);
        var nuvio=NuvioPlugins.Shared;
        if(nuvio.State.Repositories.Count==0)return;
        if(enabled&&!nuvio.State.PluginsEnabled)nuvio.SetPluginsEnabled(true);
        foreach(var repository in nuvio.State.Repositories.ToArray()){if(enabled&&!repository.IsEnabled)nuvio.SetRepositoryEnabled(repository.Id,true);nuvio.SetAllScrapersEnabled(repository.Id,enabled);}
    }
    public static void Remove(SourceEntry entry)
    {
        switch(entry.Kind)
        {
            case SourceKind.Service:JsServices.Shared.Remove(entry.Service!);break;
            case SourceKind.Stremio:StremioAddonStore.Shared.Remove(entry.Addon!);break;
            case SourceKind.Nuvio:NuvioPlugins.Shared.SetScraperEnabled(entry.SourceId,false);break;
        }
    }
    public static async Task RefreshAllAsync(CancellationToken token)
    {
        await JsServices.Shared.UpdateAllAsync(token);
        await StremioAddonStore.Shared.RefreshAsync(token);
        await NuvioPlugins.Shared.RefreshAllAsync(token);
    }
    public static async Task AutoUpdateOnLaunchAsync(CancellationToken token)
    {
        if(!ServicesPreferenceStore.Shared.Value.AutoUpdate)return;
        try
        {
            await JsServices.Shared.AutoUpdateIfNeededAsync(token);
            await StremioAddonStore.Shared.RefreshAsync(token);
            await NuvioPlugins.Shared.RefreshAllAsync(token);
        }
        catch(OperationCanceledException){}
        catch(Exception error) when(error is IOException or SourceException or UnauthorizedAccessException){}
    }
}
