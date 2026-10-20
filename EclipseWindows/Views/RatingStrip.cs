using Eclipse.Windows.Models;
using Eclipse.Windows.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
namespace Eclipse.Windows.Views;

public sealed class RatingStrip : UserControl
{
    private readonly Grid _grid = new() { ColumnSpacing = 8, RowSpacing = 8, HorizontalAlignment = HorizontalAlignment.Left };
    private MediaTitle? _title; private CancellationTokenSource? _load; private int _generation; private double _trakt, _mal; private bool _loaded;
    public RatingStrip() { Content = _grid; HorizontalAlignment = HorizontalAlignment.Stretch; Loaded += (_, _) => { _loaded = true; UserRatingStore.Shared.Changed += Changed; Start(); }; Unloaded += (_, _) => { _loaded = false; UserRatingStore.Shared.Changed -= Changed; _load?.Cancel(); ++_generation; }; SizeChanged += (_, _) => Render(); }
    public void SetTitle(MediaTitle title) { _title = title; _trakt = _mal = 0; Render(); if (_loaded) Start(); }
    private void Changed(object? sender, EventArgs args) => Render();
    private async void Start()
    {
        _load?.Cancel(); _load?.Dispose(); _load = new(); var ct = _load.Token; var gen = ++_generation; if (_title is not { } title) return;
        try { var ratings = await PublicRatingService.Shared.RatingsAsync(title, ct); if (ct.IsCancellationRequested || gen != _generation) return; _trakt = ratings.Trakt; _mal = ratings.Mal; Render(); } catch (OperationCanceledException) { } catch (ProviderException) { }
    }
    private void Render()
    {
        _grid.Children.Clear(); _grid.RowDefinitions.Clear(); _grid.ColumnDefinitions.Clear(); if (_title is not { } title) return; var chips = new List<(string Label, double Score, string? Logo)>(); if (title.Score > 0) chips.Add((title.ScoreProvider, title.Score, title.ScoreProvider == "TMDB" ? "TMDBLogo.svg" : null)); if (_trakt > 0) chips.Add(("Trakt", _trakt, "TraktLogo.svg")); if (_mal > 0) chips.Add(("MAL", _mal, null)); var user = UserRatingStore.Shared.HeroRating(title); if (user.Score is { } score) chips.Add((user.Average ? "Your avg" : "You", score, null));
        var columns = ActualWidth > 420 ? 4 : 2; for (var i = 0; i < columns; i++) _grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); for (var i = 0; i < (chips.Count + columns - 1) / columns; i++) _grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
        for (var i = 0; i < chips.Count; i++) { var chip = chips[i]; var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7 }; if (chip.Logo is { } path) stack.Children.Add(new Image { Source = new SvgImageSource(new($"ms-appx:///Assets/{path}")), Width = chip.Label == "TMDB" ? 40 : 16, Height = 16, Stretch = Stretch.Uniform }); if (chip.Logo is null || chip.Label != "TMDB") stack.Children.Add(new TextBlock { Foreground = (Brush)Application.Current.Resources["EclipseHeroTextBrush"], Text = chip.Label, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }); stack.Children.Add(new TextBlock { Foreground = (Brush)Application.Current.Resources["EclipseHeroTextBrush"], Text = chip.Score.ToString("0.0"), FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }); var border = new Border { Child = stack, Padding = new(9, 7, 9, 7), CornerRadius = new(8), Background = (Brush)Application.Current.Resources["EclipseHeroCardBrush"], BorderBrush = (Brush)Application.Current.Resources["EclipseHeroSecondaryBrush"], BorderThickness = new(1) }; Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(border, $"{chip.Label} rating {chip.Score:0.0} out of 10"); Grid.SetColumn(border, i % columns); Grid.SetRow(border, i / columns); _grid.Children.Add(border); }
    }
}
