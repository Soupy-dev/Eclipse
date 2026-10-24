using Eclipse.Windows.Services;
using Microsoft.UI.Xaml.Controls;

namespace Eclipse.Windows.Views;

public sealed partial class EclipseDialog : ContentDialog
{
    public EclipseDialog() { foreach (var pair in AppearanceService.Current) Resources[pair.Key] = pair.Value; }
}
