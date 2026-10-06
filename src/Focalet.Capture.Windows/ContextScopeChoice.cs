using Focalet.Capture;

namespace Focalet.Windows;

internal sealed record ContextScopeChoice(Rectangle Bounds, string Label, Func<ContextSnapshot?> Capture);
