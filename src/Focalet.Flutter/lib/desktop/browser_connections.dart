enum CaptureBrowser {
  edge('Microsoft Edge'),
  chrome('Google Chrome');

  const CaptureBrowser(this.label);
  final String label;
}

class BrowserConnectionStatus {
  const BrowserConnectionStatus({
    required this.browser,
    required this.state,
    required this.message,
    this.explicitEndpoint = false,
  });

  factory BrowserConnectionStatus.fromJson(Map<String, Object?> json) =>
      BrowserConnectionStatus(
        browser: CaptureBrowser.values.byName(json['browser']! as String),
        state: json['state']! as String,
        message: json['message']! as String,
        explicitEndpoint: json['explicitEndpoint'] == true,
      );

  final CaptureBrowser browser;
  final String state;
  final String message;
  final bool explicitEndpoint;

  String get label => switch (state) {
    'connected' => 'Connected',
    'available' => 'Ready to connect',
    'disabled' => 'Off',
    'setup-required' => 'Setup needed',
    'other-browser' => 'Different browser configured',
    _ => 'Disconnected',
  };
}

abstract interface class BrowserConnectionSettings {
  bool get supportsBrowserConnections;
  Future<List<BrowserConnectionStatus>> browserConnections();
  Future<BrowserConnectionStatus> reconnectBrowser(CaptureBrowser browser);
}
