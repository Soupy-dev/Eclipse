using System.Xml.Linq;
using Eclipse.Windows.Models;
using Microsoft.Windows.AppNotifications;
using Windows.Data.Xml.Dom;
using Windows.UI.Notifications;

namespace Eclipse.Windows.Services;

// OS scheduling survives process exit. Only this feature's group is enumerated or removed.
public sealed class WindowsReminderPlatform : IReminderPlatform
{
    public const string Group = "Eclipse.Remind";
    public static string? RegistrationError { get; set; }
    public Task<string?> AvailabilityAsync()
    {
        try
        {
            return Task.FromResult(RegistrationError ?? (ToastNotificationManager.CreateToastNotifier().Setting == NotificationSetting.Enabled
                ? null : "Notifications are disabled for Eclipse or by Windows policy. Enable them in Windows notification settings."));
        }
        catch (Exception) { return Task.FromResult<string?>("Windows notifications are unavailable for this installation."); }
    }
    public Task<IReadOnlyList<PendingReminder>> PendingAsync() => Task.Run<IReadOnlyList<PendingReminder>>(() =>
        ToastNotificationManager.CreateToastNotifier().GetScheduledToastNotifications().Where(n => n.Group == Group)
            .Select(n => new PendingReminder(n.Tag, n.DeliveryTime, Key(n.Content.GetXml()))).ToArray());
    public Task ScheduleAsync(ReminderPlan plan)
    {
        var xml = new XmlDocument(); xml.LoadXml(Payload(plan));
        ToastNotificationManager.CreateToastNotifier().AddToSchedule(new ScheduledToastNotification(xml, plan.FireDate) { Tag = plan.Tag, Group = Group });
        return Task.CompletedTask;
    }
    public Task RemoveAsync(string tag)
    {
        var notifier = ToastNotificationManager.CreateToastNotifier();
        foreach (var item in notifier.GetScheduledToastNotifications().Where(n => n.Group == Group && n.Tag == tag)) notifier.RemoveFromSchedule(item);
        return Task.CompletedTask;
    }
    public Task ShowAsync(ReminderPlan plan)
    {
        AppNotificationManager.Default.Show(new AppNotification(Payload(plan)) { Tag = plan.Tag, Group = Group });
        return Task.CompletedTask;
    }
    public Task<IReadOnlyList<DeliveredReminder>> DeliveredAsync() => Task.Run<IReadOnlyList<DeliveredReminder>>(() =>
        ToastNotificationManager.History.GetHistory().Where(n => n.Group == Group).Select(n => {var xml=n.Content.GetXml();var launch=(string?)XElement.Parse(xml).Attribute("launch");ReminderPolicy.ReadArgument(launch,out var token,out var occurrence);return new DeliveredReminder(n.Tag,token,occurrence);}).ToArray());
    public Task RemoveDeliveredAsync(string tag) { ToastNotificationManager.History.Remove(tag, Group); return Task.CompletedTask; }
    internal static string Payload(ReminderPlan plan) => new XElement("toast", new XAttribute("launch", "eclipse-reminder=" + plan.RouteToken+"&occurrence="+ReminderPolicy.OccurrenceKey(plan.Id,plan.FireDate)),
        new XElement("visual", new XElement("binding", new XAttribute("template", "ToastGeneric"), new XElement("text", plan.Entry.Title), new XElement("text", plan.Body)))).ToString(SaveOptions.DisableFormatting);
    private static string Token(string xml)
    {
        if (xml.Length > 10000) return "";
        var launch = (string?)XElement.Parse(xml).Attribute("launch");
        return ReminderPolicy.ReadArgument(launch,out var token,out _)?token:"";
    }
    private static string Key(string xml)
    {
        if (xml.Length > 10000) return "invalid";
        var text = XElement.Parse(xml).Descendants("text").Select(e => e.Value).ToArray();
        return text.Length >= 2 ? ReminderPolicy.ContentKey(text[0], text[1], Token(xml)) : "invalid";
    }
}
