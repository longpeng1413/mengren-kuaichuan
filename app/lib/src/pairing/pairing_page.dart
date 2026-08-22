import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../network/local_network_service.dart';
import 'pairing_endpoint.dart';

typedef ConnectPairing = Future<void> Function(PairingEndpoint endpoint);

class PairingPage extends StatefulWidget {
  const PairingPage({
    required this.pairingCode,
    required this.port,
    required this.onConnect,
    super.key,
  });

  final String pairingCode;
  final int port;
  final ConnectPairing onConnect;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final LocalNetworkService _networkService = const LocalNetworkService();
  List<LocalNetworkAddress> _addresses = const [];
  String? _selectedAddress;
  bool _loading = true;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    _loadAddresses();
  }

  Future<void> _loadAddresses() async {
    List<LocalNetworkAddress> addresses = const [];
    try {
      addresses = await _networkService.listAddresses();
    } catch (_) {
      // The manual pairing form remains available if enumeration fails.
    }
    if (!mounted) return;
    setState(() {
      _addresses = addresses;
      _selectedAddress = addresses.isEmpty ? null : addresses.first.address;
      _loading = false;
    });
  }

  Future<void> _scan() async {
    if (!Platform.isAndroid) return;
    final payload = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const _QrScannerPage()));
    if (!mounted || payload == null) return;
    final endpoint = PairingEndpoint.tryParse(payload);
    if (endpoint == null) {
      _showMessage('二维码不是有效的猛人快传配对码');
      return;
    }
    await _connect(endpoint);
  }

  Future<void> _manual() async {
    final endpoint = await showDialog<PairingEndpoint>(
      context: context,
      builder: (_) => _ManualPairDialog(defaultPort: widget.port),
    );
    if (!mounted || endpoint == null) return;
    await _connect(endpoint);
  }

  Future<void> _connect(PairingEndpoint endpoint) async {
    if (_connecting) return;
    setState(() => _connecting = true);
    try {
      await widget.onConnect(endpoint);
      if (mounted) _showMessage('配对成功，设备已加入列表');
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final address = _selectedAddress;
    final endpoint = address == null
        ? null
        : PairingEndpoint(
            host: address,
            port: widget.port,
            code: widget.pairingCode,
          );
    return Scaffold(
      appBar: AppBar(
        title: const Text('二维码 / 手动连接'),
        actions: [
          IconButton(
            onPressed: _loading
                ? null
                : () {
                    setState(() => _loading = true);
                    _loadAddresses();
                  },
            tooltip: '刷新热点和局域网地址',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('让另一台设备连接我', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text('另一台手机或电脑连接到同一 Wi-Fi/热点后，扫描此二维码即可直连。数据不会经过互联网。'),
          const SizedBox(height: 12),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.wifi_tethering),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '手机热点互传：一台手机打开热点，另一台连接热点。任意一台显示二维码，另一台扫码；自动发现失败时仍可正常配对。',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: _loading
                ? const SizedBox.square(
                    dimension: 48,
                    child: CircularProgressIndicator(),
                  )
                : endpoint == null
                ? const Text('没有找到可用的局域网 IPv4 地址')
                : Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          QrImageView(
                            data: endpoint.payload.toString(),
                            version: QrVersions.auto,
                            size: 230,
                            eyeStyle: const QrEyeStyle(
                              eyeShape: QrEyeShape.square,
                              color: Colors.black,
                            ),
                            dataModuleStyle: const QrDataModuleStyle(
                              dataModuleShape: QrDataModuleShape.square,
                              color: Colors.black,
                            ),
                          ),
                          if (_addresses.length > 1)
                            DropdownButton<String>(
                              value: address,
                              items: _addresses
                                  .map(
                                    (value) => DropdownMenuItem<String>(
                                      value: value.address,
                                      child: Text(value.displayLabel),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (value) {
                                if (value != null) {
                                  setState(() => _selectedAddress = value);
                                }
                              },
                            )
                          else
                            SelectableText(
                              '${_addresses.first.displayLabel}\n$address:${widget.port}',
                              textAlign: TextAlign.center,
                            ),
                          const SizedBox(height: 6),
                          Text(
                            '配对码：${formatPairingCode(widget.pairingCode)}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 20),
          Text('连接另一台设备', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          if (Platform.isAndroid)
            FilledButton.icon(
              onPressed: _connecting ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('扫描另一台设备二维码'),
            ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _connecting ? null : _manual,
            icon: const Icon(Icons.keyboard),
            label: const Text('手动输入 IP 和配对码'),
          ),
          if (_connecting) ...[
            const SizedBox(height: 18),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}

class _QrScannerPage extends StatefulWidget {
  const _QrScannerPage();

  @override
  State<_QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<_QrScannerPage> {
  bool _completed = false;

  void _detected(BarcodeCapture capture) {
    if (_completed) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && value.isNotEmpty) {
        _completed = true;
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫描另一台设备二维码')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(onDetect: _detected),
          IgnorePointer(
            child: Center(
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white, width: 3),
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ManualPairDialog extends StatefulWidget {
  const _ManualPairDialog({required this.defaultPort});

  final int defaultPort;

  @override
  State<_ManualPairDialog> createState() => _ManualPairDialogState();
}

class _ManualPairDialogState extends State<_ManualPairDialog> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  late final TextEditingController _codeController;
  String? _error;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController();
    _portController = TextEditingController(
      text: widget.defaultPort.toString(),
    );
    _codeController = TextEditingController();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _submit() {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    final code = normalizePairingCode(_codeController.text);
    if (host.isEmpty ||
        port == null ||
        port < 1 ||
        port > 65535 ||
        code == null) {
      setState(() => _error = '请输入有效的 IP、端口和 8 位配对码');
      return;
    }
    Navigator.of(context)
        .pop(PairingEndpoint(host: host, port: port, code: code));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('手动连接'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _hostController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '设备 IP 地址',
                hintText: '例如：192.168.0.65',
              ),
            ),
            TextField(
              controller: _portController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: '端口'),
            ),
            TextField(
              controller: _codeController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 8,
              decoration: const InputDecoration(labelText: '8 位配对码'),
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('连接')),
      ],
    );
  }
}
