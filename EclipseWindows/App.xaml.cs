using Microsoft.UI.Xaml;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppLifecycle;
using Eclipse.Windows.Services;

namespace Eclipse.Windows;

public partial class App : Application
{
    private MainWindow? _window;
    private readonly System.Collections.Concurrent.ConcurrentQueue<AppActivationArguments> _pendingActivations=new();

    public App()
    {
        InitializeComponent();
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var instance=AppInstance.FindOrRegisterForKey("Eclipse.Main");
        if(!instance.IsCurrent)
        {
            await instance.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs());
            Environment.Exit(0);return;
        }
        instance.Activated+=(_,activationArgs)=>{_pendingActivations.Enqueue(activationArgs);DispatchActivations();};
        _window = new MainWindow();
        var notifications=AppNotificationManager.Default;
        notifications.NotificationInvoked+=NotificationInvoked;
        try{notifications.Register();}catch(Exception){WindowsReminderPlatform.RegistrationError="Windows notification activation could not be registered for this installation.";}
        _window.Closed+=(_,_)=>{try{notifications.Unregister();}catch(Exception){}};
#if ECLIPSE_LOCAL_DIAGNOSTICS
        Diagnostics.StartupProbe.Attach(_window.Content);
#endif
        var activation=AppInstance.GetCurrent().GetActivatedEventArgs();
        if(activation.Kind==ExtendedActivationKind.AppNotification&&activation.Data is AppNotificationActivatedEventArgs notification)_= _window.OpenNotificationAsync(notification.Argument);
        else if(!Environment.GetCommandLineArgs().Any(a=>a.Contains("----AppNotificationActivated:",StringComparison.Ordinal)))_window.Activate();
        DispatchActivations();
    }
    private void NotificationInvoked(AppNotificationManager sender,AppNotificationActivatedEventArgs args)
    { _window?.DispatcherQueue.TryEnqueue(async()=>{if(_window is not null)await _window.OpenNotificationAsync(args.Argument);}); }
    private void DispatchActivations()=>_window?.DispatcherQueue.TryEnqueue(async()=>
    {
        while(_window is not null&&_pendingActivations.TryDequeue(out var activation))
        {if(activation.Kind==ExtendedActivationKind.AppNotification&&activation.Data is AppNotificationActivatedEventArgs invoked)await _window.OpenNotificationAsync(invoked.Argument);else _window.Activate();}
    });
}
