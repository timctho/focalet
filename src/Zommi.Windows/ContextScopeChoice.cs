using Zommi.Capture;

namespace Zommi.Windows;

internal sealed record ContextScopeChoice(Rectangle Bounds, string Label, Func<ContextSnapshot?> Capture);
