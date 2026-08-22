enum RemoteTransportRoute {
  lanDirect('局域网直连', false),
  localPairing('二维码本地连接', false),
  vpsRelay('公网 VPS 中转', true),
  internetP2p('公网点对点', true);

  const RemoteTransportRoute(this.label, this.usesInternet);

  final String label;
  final bool usesInternet;
}
