/// fespalier's reconnect signal from connectivity_plus (since 0.9.0): `reconnectSignal.overrideWith(ConnectivitySignal.new)`
/// in startup() makes `Freshness(refetchOnReconnect: true)` load again when the device gets a network back, and
/// [hasNetwork] tells a banner whether it has one. Connectivity is not reachability: a network interface can be up
/// with no internet behind it (docs/data.md, "Reconnects: fespalier_connectivity").
library;

export 'package:connectivity_plus/connectivity_plus.dart'
    show ConnectivityResult;

export 'src/network.dart'
    show
        NetworkConnectivity,
        connectivitySource,
        hasNetwork,
        networkConnectivity;
export 'src/signal.dart' show ConnectivitySignal;
export 'src/source.dart' show ConnectivitySource, PluginConnectivitySource;
