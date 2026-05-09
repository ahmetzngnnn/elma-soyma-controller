// lib/main.dart
// Flutter mobile controller for the Raspberry Pi "Elma Soyma – Sade Sistem"
// - Connects via plain TCP (JSON Lines) to the server (default port 8787 on your Pi)
// - Lets you: read status, start_main, start_blade, toggle vacuum, estop
// - Edit and send parameters: blade_run_s, main_run_s, vacuum_pre_off_s,
//   esc_blade_speed_pct, esc_main_speed_pct, vacuum_start_on, ignore_while_busy
//
// pubspec.yaml (özet):
// environment:
//   sdk: '>=3.3.0 <4.0.0'
// dependencies:
//   flutter: { sdk: flutter }
//   cupertino_icons: ^1.0.6
//   shared_preferences: ^2.2.3
//
// Android INTERNET izni (AndroidManifest.xml):
// <uses-permission android:name="android.permission.INTERNET"/>
//
// Notlar:
// - IP ve Port GÖMÜLÜ DEĞİL: Uygulamada elle girmen gerekiyor.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ElmaApp());
}

class ElmaApp extends StatelessWidget {
  const ElmaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Elma Controller',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // IP/Port başlangıçta boş (gömülü değil)
  final _ipCtrl = TextEditingController();
  final _portCtrl = TextEditingController();

  // Parametre alanları (varsayılan UI değerleri; sunucuya "set" ile gönderilene kadar sadece ekranda durur)
  final _bladeRunSCtrl = TextEditingController(text: '10');
  final _mainRunSCtrl = TextEditingController(text: '4');
  final _vacuumPreOffCtrl = TextEditingController(text: '1');
  final _escBladePctCtrl = TextEditingController(text: '60');
  final _escMainPctCtrl = TextEditingController(text: '50');
  bool _vacuumStartOn = true;
  bool _ignoreWhileBusy = true;

  String _connectionStatus = 'Disconnected';
  bool _connecting = false;

  final _log = <String>[];
  StreamSubscription<List<int>>? _rxSub;

  Socket? _sock;
  String _rxBuf = '';

  Map<String, dynamic>? _lastState;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final sp = await SharedPreferences.getInstance();
    setState(() {
      // Not: İstersen önceki IP/Port’u hatırlatmak için kaydedilmiş değerleri dolduruyoruz.
      _ipCtrl.text = sp.getString('ip') ?? _ipCtrl.text;
      _portCtrl.text = sp.getString('port') ?? _portCtrl.text;

      _bladeRunSCtrl.text =
          sp.getString('blade_run_s') ?? _bladeRunSCtrl.text;
      _mainRunSCtrl.text = sp.getString('main_run_s') ?? _mainRunSCtrl.text;
      _vacuumPreOffCtrl.text =
          sp.getString('vacuum_pre_off_s') ?? _vacuumPreOffCtrl.text;
      _escBladePctCtrl.text =
          sp.getString('esc_blade_speed_pct') ?? _escBladePctCtrl.text;
      _escMainPctCtrl.text =
          sp.getString('esc_main_speed_pct') ?? _escMainPctCtrl.text;
      _vacuumStartOn = sp.getBool('vacuum_start_on') ?? _vacuumStartOn;
      _ignoreWhileBusy =
          sp.getBool('ignore_while_busy') ?? _ignoreWhileBusy;
    });
  }

  Future<void> _savePrefs() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('ip', _ipCtrl.text.trim());
    await sp.setString('port', _portCtrl.text.trim());
    await sp.setString('blade_run_s', _bladeRunSCtrl.text.trim());
    await sp.setString('main_run_s', _mainRunSCtrl.text.trim());
    await sp.setString('vacuum_pre_off_s', _vacuumPreOffCtrl.text.trim());
    await sp.setString('esc_blade_speed_pct', _escBladePctCtrl.text.trim());
    await sp.setString('esc_main_speed_pct', _escMainPctCtrl.text.trim());
    await sp.setBool('vacuum_start_on', _vacuumStartOn);
    await sp.setBool('ignore_while_busy', _ignoreWhileBusy);
  }

  void _appendLog(String s) {
    setState(() {
      final ts = TimeOfDay.now().format(context);
      _log.add('[$ts] $s');
      if (_log.length > 500) _log.removeAt(0);
    });
  }

  Future<void> _connect() async {
    if (_connecting) return;
    final host = _ipCtrl.text.trim();
    final portStr = _portCtrl.text.trim();
    if (host.isEmpty || portStr.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('IP ve Port giriniz.')),
      );
      return;
    }
    final port = int.tryParse(portStr) ?? 8787;

    _connecting = true;
    try {
      _appendLog('Connecting to $host:$port ...');
      setState(() => _connectionStatus = 'Connecting');

      final sock = await Socket.connect(host, port,
          timeout: const Duration(seconds: 5));
      _sock = sock;
      setState(() => _connectionStatus = 'Connected');
      _appendLog('Connected');

      _rxSub?.cancel();
      _rxSub = sock.listen(_onBytes,
          onDone: _onDone,
          onError: (e, st) => _appendLog('Socket error: $e'));
    } catch (e) {
      _appendLog('Connect failed: $e');
      setState(() => _connectionStatus = 'Disconnected');
    } finally {
      _connecting = false;
    }
  }

  void _onBytes(List<int> data) {
    try {
      _rxBuf += utf8.decode(data, allowMalformed: true);
    } catch (_) {
      _rxBuf += String.fromCharCodes(data);
    }
    int idx;
    while ((idx = _rxBuf.indexOf('\n')) != -1) {
      final line = _rxBuf.substring(0, idx).trim();
      _rxBuf = _rxBuf.substring(idx + 1);
      if (line.isEmpty) continue;
      try {
        final obj = json.decode(line);
        if (obj is Map<String, dynamic>) {
          if (obj.containsKey('data')) {
            _lastState = obj['data'] as Map<String, dynamic>?;
          }
          if (obj.containsKey('log')) {
            _appendLog(obj['log'].toString());
          } else {
            _appendLog('RX: ${jsonEncode(obj)}');
          }
          setState(() {});
        } else {
          _appendLog('RX(non-map): $line');
        }
      } catch (_) {
        _appendLog('RX: $line');
      }
    }
  }

  void _onDone() {
    _appendLog('Disconnected by remote');
    setState(() => _connectionStatus = 'Disconnected');
    _sock?.destroy();
    _sock = null;
  }

  Future<void> _disconnect() async {
    await _sock?.flush();
    await _sock?.close();
    _sock = null;
    setState(() => _connectionStatus = 'Disconnected');
    _appendLog('Disconnected');
  }

  void _send(Map<String, dynamic> obj) {
    final s = jsonEncode(obj) + '\n';
    try {
      _sock?.add(utf8.encode(s));
      _appendLog('TX: ${jsonEncode(obj)}');
    } catch (e) {
      _appendLog('Send failed: $e');
    }
  }

  void _cmdGet() => _send({"cmd": "get"});
  void _cmdStartMain() => _send({"cmd": "start_main"});
  void _cmdStartBlade() => _send({"cmd": "start_blade"});
  void _cmdVacuum(bool on) => _send({"cmd": "vacuum", "on": on});
  void _cmdEstop() => _send({"cmd": "estop"});

  void _cmdSetParams() {
    final bladeRun = double.tryParse(_bladeRunSCtrl.text.trim()) ?? 10.0;
    final mainRun = double.tryParse(_mainRunSCtrl.text.trim()) ?? 4.0;
    final preOff = double.tryParse(_vacuumPreOffCtrl.text.trim()) ?? 1.0;
    final bladePct = int.tryParse(_escBladePctCtrl.text.trim()) ?? 60;
    final mainPct = int.tryParse(_escMainPctCtrl.text.trim()) ?? 50;

    final params = {
      'blade_run_s': bladeRun,
      'main_run_s': mainRun,
      'vacuum_pre_off_s': preOff,
      'esc_blade_speed_pct': bladePct,
      'esc_main_speed_pct': mainPct,
      'vacuum_start_on': _vacuumStartOn,
      'ignore_while_busy': _ignoreWhileBusy,
    };
    _savePrefs();
    _send({"cmd": "set", "params": params});
  }

  @override
  void dispose() {
    _rxSub?.cancel();
    _sock?.destroy();
    _ipCtrl.dispose();
    _portCtrl.dispose();
    _bladeRunSCtrl.dispose();
    _mainRunSCtrl.dispose();
    _vacuumPreOffCtrl.dispose();
    _escBladePctCtrl.dispose();
    _escMainPctCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _connectionStatus == 'Connected' && _sock != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Elma Controller'),
        actions: [
          IconButton(
            tooltip: 'GET',
            onPressed: connected ? _cmdGet : null,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'ESTOP',
            onPressed: connected ? _cmdEstop : null,
            icon: const Icon(Icons.warning_amber),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _buildConnectionCard(connected),
            const SizedBox(height: 12),
            _buildParamsCard(connected),
            const SizedBox(height: 12),
            _buildActionsCard(connected),
            const SizedBox(height: 12),
            _buildStateCard(),
            const SizedBox(height: 12),
            _buildLogCard(),
          ],
        ),
      ),
    );
  }

  // ======= UI parçası: Connection =======
  Widget _buildConnectionCard(bool connected) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.lan),
                const SizedBox(width: 8),
                Text('Connection', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Chip(
                  label: Text(_connectionStatus),
                  avatar: Icon(
                    connected ? Icons.check_circle : Icons.cancel,
                    color: connected ? Colors.green : Colors.red,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(children: [
              Flexible(
                flex: 3,
                child: TextField(
                  controller: _ipCtrl,
                  decoration: const InputDecoration(labelText: 'RPi IP'),
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: TextField(
                  controller: _portCtrl,
                  decoration: const InputDecoration(labelText: 'Port'),
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: () {
                  if (!connected) {
                    if (_ipCtrl.text.trim().isEmpty ||
                        _portCtrl.text.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('IP ve Port giriniz.')),
                      );
                      return;
                    }
                    _connect();
                  } else {
                    _disconnect();
                  }
                },
                icon: Icon(connected ? Icons.link_off : Icons.link),
                label: Text(connected ? 'Disconnect' : 'Connect'),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  // ======= UI parçası: Parameters =======
  Widget _buildParamsCard(bool connected) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.tune),
                const SizedBox(width: 8),
                Text('Parameters', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: connected ? _cmdSetParams : null,
                  icon: const Icon(Icons.save),
                  label: const Text('Send/Save'),
                )
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              runSpacing: 8,
              spacing: 8,
              children: [
                _numField(_bladeRunSCtrl, 'blade_run_s', 's'),
                _numField(_mainRunSCtrl, 'main_run_s', 's'),
                _numField(_vacuumPreOffCtrl, 'vacuum_pre_off_s', 's'),
                _numField(_escBladePctCtrl, 'esc_blade_speed_pct', '%'),
                _numField(_escMainPctCtrl, 'esc_main_speed_pct', '%'),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('vacuum_start_on'),
                    Switch(
                      value: _vacuumStartOn,
                      onChanged: (v) => setState(() => _vacuumStartOn = v),
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('ignore_while_busy'),
                    Switch(
                      value: _ignoreWhileBusy,
                      onChanged: (v) => setState(() => _ignoreWhileBusy = v),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _numField(TextEditingController c, String label, String unit) {
    return SizedBox(
      width: 170,
      child: TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          suffixText: unit,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  // ======= UI parçası: Actions =======
  Widget _buildActionsCard(bool connected) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.play_arrow_rounded),
                const SizedBox(width: 8),
                Text('Actions', style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: connected ? _cmdStartMain : null,
                  icon: const Icon(Icons.rotate_right),
                  label: const Text('Start MAIN'),
                ),
                ElevatedButton.icon(
                  onPressed: connected ? _cmdStartBlade : null,
                  icon: const Icon(Icons.content_cut), // blade_rounded yerine
                  label: const Text('Start BLADE'),
                ),
                ElevatedButton.icon(
                  onPressed: connected ? () => _cmdVacuum(true) : null,
                  icon: const Icon(Icons.air),
                  label: const Text('Vacuum ON'),
                ),
                ElevatedButton.icon(
                  onPressed: connected ? () => _cmdVacuum(false) : null,
                  icon: const Icon(Icons.air_outlined),
                  label: const Text('Vacuum OFF'),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: connected ? _cmdEstop : null,
                  icon: const Icon(Icons.warning),
                  label: const Text('E-STOP'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ======= UI parçası: Device State =======
  Widget _buildStateCard() {
    final state = _lastState ?? const {};
    final vacuum = state['vacuum_on'];
    final s = state['state']?.toString() ?? 'unknown';

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.monitor_heart),
                const SizedBox(width: 8),
                Text('Device State', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (vacuum is bool)
                  Chip(
                    label: Text('Vacuum: ${vacuum ? 'ON' : 'OFF'}'),
                    avatar: Icon(vacuum ? Icons.air : Icons.air_outlined),
                  ),
                const SizedBox(width: 8),
                Chip(label: Text('State: $s')),
              ],
            ),
            const SizedBox(height: 8),
            Text(const JsonEncoder.withIndent('  ').convert(state)),
          ],
        ),
      ),
    );
  }

  // ======= UI parçası: Logs =======
  Widget _buildLogCard() {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.list_alt),
                const SizedBox(width: 8),
                Text('Logs', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: 'Clear',
                  onPressed: () => setState(() => _log.clear()),
                  icon: const Icon(Icons.clear_all),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 200,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.black12),
                ),
                child: ListView.builder(
                  itemCount: _log.length,
                  itemBuilder: (context, i) => Text(_log[i]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
