using Eclipse.Windows.Models;
using Eclipse.Windows.Navigation;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Xaml.Input;
using Windows.UI.ViewManagement;
namespace Eclipse.Windows.Views;
public sealed partial class SchedulePage : Page
{
    public event EventHandler<TitleRequestedEventArgs>? TitleRequested;
    private CancellationTokenSource? _load;
    private IReadOnlyList<ScheduleEntry> _entries=[];
    private bool _setting,_active,_loadingCalendar;
    private int _generation,_selectionGeneration;
    private DateOnly _calendarDay;
    private bool? _compact;
    private readonly UISettings _uiSettings=new();
    private ScheduleNavigationState _navigation=new();
    private bool _restorePending,_restoreQueued;
    public SchedulePage()
    {
        InitializeComponent();_setting=true;var p=PreferenceStore.Shared.Value;
        Mode.SelectedItem=Mode.Items.OfType<ComboBoxItem>().First(i=>(string)i.Tag==p.DefaultScheduleMode);
        Range.SelectedItem=Range.Items.OfType<ComboBoxItem>().First(i=>(string)i.Tag==p.ScheduleWindowDays.ToString());
        Zone.SelectedIndex=p.ShowLocalScheduleTime ? 0 : 1;_setting=false;
        Day.AddHandler(PointerWheelChangedEvent,new PointerEventHandler(Day_Wheel),true);
        Loaded+=(_,_)=>{_uiSettings.TextScaleFactorChanged+=TextScale_Changed;SizeDayStrip();QueueRestore();};Unloaded+=(_,_)=>_uiSettings.TextScaleFactorChanged-=TextScale_Changed;
    }
    protected override void OnNavigatedTo(NavigationEventArgs args){base.OnNavigatedTo(args);_navigation=args.Parameter as ScheduleNavigationState??new();if((_navigation.SourceOverride??_navigation.Mode) is{} source){_setting=true;Mode.SelectedItem=Mode.Items.OfType<ComboBoxItem>().First(i=>(string)i.Tag==source);_setting=false;_navigation.SourceOverride=null;}_navigation.Mode=(string)((ComboBoxItem)Mode.SelectedItem).Tag;_active=true;_=LoadAsync();}
    private async Task LoadAsync(bool refresh=false)
    {
        _load?.Cancel();_load?.Dispose();_load=new();var token=_load.Token;var generation=++_generation;
        _calendarDay=DateOnly.FromDateTime(Zone.SelectedIndex==0?DateTime.Now:DateTime.UtcNow);
        _loadingCalendar=true;_entries=[];Entries.ItemsSource=null;Empty.Visibility=Visibility.Collapsed;BusyBar.Visibility=Visibility.Visible;BusyBar.IsIndeterminate=true;Notice.IsOpen=false;Notice.Severity=InfoBarSeverity.Informational;Regroup();
        try
        {
            var result=await ScheduleService.Shared.LoadAsync((string)((ComboBoxItem)Mode.SelectedItem).Tag,int.Parse((string)((ComboBoxItem)Range.SelectedItem).Tag),token,refresh);
            if(token.IsCancellationRequested||generation!=_generation||!_active)return;
            _loadingCalendar=false;_entries=result.Entries;Notice.Message=result.Notice;Notice.IsOpen=result.Notice.Length>0;Regroup();
            try{await EpisodeReminderService.Shared.ConsumeAsync(result);}catch(Exception e)when(e is IOException or InvalidOperationException){if(_active&&generation==_generation){Notice.Message=e.Message;Notice.IsOpen=true;}}
        }
        catch(OperationCanceledException){}
        catch(ProviderException error){if(!token.IsCancellationRequested&&generation==_generation){Notice.Message=error.Message;Notice.Severity=InfoBarSeverity.Warning;Notice.IsOpen=true;}}
        finally{if(generation==_generation){_loadingCalendar=false;BusyBar.IsIndeterminate=false;BusyBar.Visibility=Visibility.Collapsed;}}
    }
    public void CheckCalendarDate(){if(_active&&_calendarDay!=DateOnly.FromDateTime(Zone.SelectedIndex==0?DateTime.Now:DateTime.UtcNow))_=LoadAsync();}
    private void Regroup()
    {
        var zone=Zone.SelectedIndex==0 ? TimeZoneInfo.Local : TimeZoneInfo.Utc;var today=DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(DateTimeOffset.UtcNow,zone).DateTime);
        var selected=(Day.SelectedItem as ScheduleDay)?.Date??_navigation.SelectedDay??today;var days=int.Parse((string)((ComboBoxItem)Range.SelectedItem).Tag);
        _setting=true;var rows=Enumerable.Range(0,days).Select(offset=>new ScheduleDay(today.AddDays(offset),_entries.Count(e=>ScheduleDates.InDay(e,today.AddDays(offset),zone))){Today=today}).ToArray();
        Day.ItemsSource=rows;Day.SelectedItem=rows.FirstOrDefault(d=>d.Date==selected)??rows[0];_setting=false;ShowDay();
    }
    private void ShowDay()
    {
        _restorePending=false;
        if(Day.SelectedItem is not ScheduleDay selected)return;
        ++_selectionGeneration;_navigation.SelectedDay=selected.Date;Day.ScrollIntoView(selected);DayHeading.Text=selected.Heading;DayCount.Text=_loadingCalendar?"Loading…":$"{selected.Count} airing";
        var local=Zone.SelectedIndex==0;var zone=local ? TimeZoneInfo.Local : TimeZoneInfo.Utc;
        var rows=_entries.Where(e=>ScheduleDates.InDay(e,selected.Date,zone)).OrderBy(e=>e.AiringAt).Select(e=>new ScheduleDisplayRow(e,local)).ToArray();
        Entries.ItemsSource=rows;Empty.Visibility=rows.Length==0&&!_loadingCalendar ? Visibility.Visible : Visibility.Collapsed;
        if(!_loadingCalendar&&_navigation.VisibleEntryId is{} id&&rows.FirstOrDefault(r=>r.Entry.Id==id) is{} restore)
        {
            _restorePending=true;QueueRestore();
        }
    }
    private void QueueRestore()
    {
        if(!IsLoaded||!_active||!_restorePending||_restoreQueued)return;
        var generation=_generation;var selection=_selectionGeneration;_restoreQueued=true;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low,()=>
        {
            _restoreQueued=false;
            if(!_active||!IsLoaded||generation!=_generation||selection!=_selectionGeneration||!_restorePending)return;
            if(Entries.Items.OfType<ScheduleDisplayRow>().FirstOrDefault(r=>r.Entry.Id==_navigation.VisibleEntryId) is{} restore)Entries.ScrollIntoView(restore);
            Entries.UpdateLayout();
            if(!_navigation.RestoreKeyboardFocus){_restorePending=false;return;}
            if(Entries.Items.OfType<ScheduleDisplayRow>().FirstOrDefault(r=>r.Entry.Id==_navigation.FocusEntryId) is{} focused)
            {
                Entries.ScrollIntoView(focused);Entries.UpdateLayout();
                if(Entries.ContainerFromItem(focused) is ListViewItem item){item.Focus(FocusState.Keyboard);_restorePending=false;}
            }
        });
    }
    private void SaveOptions()
    {var p=PreferenceStore.Shared.Copy();p.DefaultScheduleMode=(string)((ComboBoxItem)Mode.SelectedItem).Tag;p.ScheduleWindowDays=int.Parse((string)((ComboBoxItem)Range.SelectedItem).Tag);p.ShowLocalScheduleTime=Zone.SelectedIndex==0;try{PreferenceStore.Shared.Save(p);}catch{Notice.Message="Schedule preferences could not be saved.";Notice.IsOpen=true;}}
    private void Options_Changed(object sender,SelectionChangedEventArgs args){if(!_setting&&_active){_navigation.Mode=(string)((ComboBoxItem)Mode.SelectedItem).Tag;_navigation.VisibleEntryId=null;SaveOptions();_=LoadAsync();}}
    private void Zone_Changed(object sender,SelectionChangedEventArgs args){if(!_setting&&_active){SaveOptions();Regroup();}}
    private void Day_Changed(object sender,SelectionChangedEventArgs args){if(!_setting){_navigation.VisibleEntryId=null;ShowDay();}}
    private void Refresh_Click(object sender,RoutedEventArgs args)=>_=LoadAsync(true);
    private async void Entry_Click(object sender,ItemClickEventArgs args)
    {
        if(args.ClickedItem is not ScheduleDisplayRow row || _load is null)return;
        var first=Entries.ItemsPanelRoot is ItemsStackPanel panel?Math.Max(0,panel.FirstVisibleIndex):0;
        _navigation.VisibleEntryId=(Entries.Items.ElementAtOrDefault(first) as ScheduleDisplayRow)?.Entry.Id;
        _navigation.FocusEntryId=row.Entry.Id;
        _navigation.RestoreKeyboardFocus=(FocusManager.GetFocusedElement(XamlRoot) as Control)?.FocusState==FocusState.Keyboard;
        var token=_load.Token;var generation=_generation;var selection=++_selectionGeneration;
        try
        {
            var reference=await ScheduleService.Shared.ResolveAsync(row.Entry,token);
            if(!_active||token.IsCancellationRequested||generation!=_generation||selection!=_selectionGeneration)return;
            if(reference is null){Notice.Message="This schedule entry does not have a verified media identity yet.";Notice.IsOpen=true;}
            else TitleRequested?.Invoke(this,new(reference,row.Entry));
        }
        catch(OperationCanceledException){}catch(ProviderException error){if(_active&&!token.IsCancellationRequested){Notice.Message=error.Message;Notice.IsOpen=true;}}
    }
    protected override void OnNavigatedFrom(NavigationEventArgs args){_active=false;_restorePending=false;_load?.Cancel();BusyBar.IsIndeterminate=false;_entries=[];Entries.ItemsSource=null;base.OnNavigatedFrom(args);}
    private void Entry_Changing(ListViewBase sender,ContainerContentChangingEventArgs args)
    {if(!args.InRecycleQueue&&args.Item is ScheduleDisplayRow row){AutomationProperties.SetName(args.ItemContainer,$"{row.Title}, {row.Episode}, {row.Time}, {row.Provider}");if(row.Entry.Id==_navigation.FocusEntryId)QueueRestore();}}
    private void TextScale_Changed(UISettings sender,object args)=>DispatcherQueue.TryEnqueue(SizeDayStrip);
    private void SizeDayStrip()=>Day.Height=38+80*_uiSettings.TextScaleFactor;
    private void Day_Wheel(object sender,PointerRoutedEventArgs args){var p=args.GetCurrentPoint(Day).Properties;if(!p.IsHorizontalMouseWheel&&(args.KeyModifiers&(global::Windows.System.VirtualKeyModifiers.Control|global::Windows.System.VirtualKeyModifiers.Shift))==0)args.Handled=true;}
    private void Root_SizeChanged(object sender,SizeChangedEventArgs args)
    {
        var compact=args.NewSize.Width<700;Grid.SetColumn(Zone,compact?0:2);Grid.SetRow(Zone,compact?1:0);Grid.SetColumn(Refresh,compact?1:3);Grid.SetRow(Refresh,compact?1:0);Controls.ColumnDefinitions[2].Width=compact?new GridLength(0):new GridLength(1,GridUnitType.Star);Root.Padding=new Thickness(compact?14:24,20,compact?14:24,16);
        if(_compact!=compact){_compact=compact;Entries.ItemTemplate=(DataTemplate)Resources[compact?"CompactEntry":"WideEntry"];}
    }
}
