import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Valores del firmware ESP32 (`codigoesp.ino`).
const String targetDeviceName = 'VISOR_FAC';
final Guid? targetServiceUuid =
    Guid('4fafc201-1fb5-459e-8fcc-c5c9c331914b');
final Guid? targetWriteCharacteristicUuid =
    Guid('beb5483e-36e1-4688-b7f5-ea07361b26a8');

/// El ESP acepta exactamente "ON" / "OFF" (UTF-8, mayúsculas).
const String commandOn = 'ON';
const String commandOff = 'OFF';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterBluePlus.setLogLevel(LogLevel.info, color: true);
  runApp(const GafasEihfaApp());
}

class GafasEihfaApp extends StatelessWidget {
  const GafasEihfaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Control de gafas EIHFA',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0B3D5C),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const ControlGafasPage(),
    );
  }
}

class ControlGafasPage extends StatefulWidget {
  const ControlGafasPage({super.key});

  @override
  State<ControlGafasPage> createState() => _ControlGafasPageState();
}

class _ControlGafasPageState extends State<ControlGafasPage> {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeCharacteristic;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;

  bool _isBusy = false;
  bool _isConnected = false;
  bool _isOn = false;
  String _status = 'Desconectado';

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    unawaited(_disconnectQuietly());
    super.dispose();
  }

  Future<void> _disconnectQuietly() async {
    try {
      await _device?.disconnect();
    } catch (_) {
      // Ignorar errores al cerrar.
    }
  }

  Future<void> _setStatus(String message) async {
    if (!mounted) return;
    setState(() => _status = message);
  }

  Future<void> _ensureBluetoothOn() async {
    if (await FlutterBluePlus.isSupported == false) {
      throw Exception('Este dispositivo no soporta Bluetooth Low Energy.');
    }

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      throw Exception('Activa el Bluetooth del sistema e inténtalo de nuevo.');
    }
  }

  bool _matchesTarget(BluetoothDevice device) {
    if (targetDeviceName.trim().isEmpty) return true;
    final name = device.platformName.trim().toLowerCase();
    final advName = device.advName.trim().toLowerCase();
    final target = targetDeviceName.trim().toLowerCase();
    return name.contains(target) || advName.contains(target);
  }

  Future<BluetoothDevice?> _findBondedOrSystemDevice() async {
    final bonded = await FlutterBluePlus.bondedDevices;
    for (final device in bonded) {
      if (_matchesTarget(device)) return device;
    }

    final system = await FlutterBluePlus.systemDevices([]);
    for (final device in system) {
      if (_matchesTarget(device)) return device;
    }
    return null;
  }

  Future<BluetoothDevice> _scanAndConnect() async {
    await FlutterBluePlus.stopScan();

    final completer = Completer<BluetoothDevice>();
    late final StreamSubscription<List<ScanResult>> subscription;

    subscription = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        if (_matchesTarget(result.device) && !completer.isCompleted) {
          completer.complete(result.device);
          break;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 8),
        withServices: targetServiceUuid != null ? [targetServiceUuid!] : [],
      );

      final device = await completer.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw Exception(
          targetDeviceName.trim().isEmpty
              ? 'No se encontró ningún dispositivo BLE cercano.'
              : 'No se encontró el dispositivo "$targetDeviceName".',
        ),
      );
      return device;
    } finally {
      await subscription.cancel();
      await FlutterBluePlus.stopScan();
    }
  }

  Future<BluetoothCharacteristic> _resolveWriteCharacteristic(
    BluetoothDevice device,
  ) async {
    final services = await device.discoverServices();

    if (targetServiceUuid != null && targetWriteCharacteristicUuid != null) {
      for (final service in services) {
        if (service.uuid != targetServiceUuid) continue;
        for (final characteristic in service.characteristics) {
          if (characteristic.uuid == targetWriteCharacteristicUuid &&
              (characteristic.properties.write ||
                  characteristic.properties.writeWithoutResponse)) {
            return characteristic;
          }
        }
      }
      throw Exception(
        'No se encontró la característica de escritura configurada.',
      );
    }

    for (final service in services) {
      for (final characteristic in service.characteristics) {
        if (characteristic.properties.write ||
            characteristic.properties.writeWithoutResponse) {
          return characteristic;
        }
      }
    }

    throw Exception(
      'El dispositivo no expone ninguna característica de escritura BLE.',
    );
  }

  Future<void> _listenConnection(BluetoothDevice device) async {
    await _connectionSubscription?.cancel();
    _connectionSubscription = device.connectionState.listen((state) {
      final connected = state == BluetoothConnectionState.connected;
      if (!mounted) return;
      setState(() {
        _isConnected = connected;
        if (!connected) {
          _writeCharacteristic = null;
          _status = 'Desconectado';
        }
      });
    });
  }

  Future<void> _connectIfNeeded() async {
    if (_isConnected &&
        _device != null &&
        _writeCharacteristic != null &&
        _device!.isConnected) {
      return;
    }

    await _ensureBluetoothOn();
    await _setStatus('Buscando dispositivo…');

    BluetoothDevice? device = await _findBondedOrSystemDevice();
    if (device == null) {
      await _setStatus('Escaneando BLE…');
      device = await _scanAndConnect();
    }

    await _setStatus('Conectando a ${device.platformName.isEmpty ? device.remoteId.str : device.platformName}…');
    await device.connect(license: License.nonprofit, autoConnect: false, mtu: null);
    await _listenConnection(device);

    await _setStatus('Descubriendo servicios…');
    final writeCharacteristic = await _resolveWriteCharacteristic(device);

    final displayName =
        device.platformName.isEmpty ? device.remoteId.str : device.platformName;

    if (!mounted) return;
    setState(() {
      _device = device;
      _writeCharacteristic = writeCharacteristic;
      _isConnected = true;
      _status = 'Conectado a $displayName';
    });
  }

  Future<void> _writeCommand(String command) async {
    final characteristic = _writeCharacteristic;
    if (characteristic == null) {
      throw Exception('No hay característica de escritura lista.');
    }

    final bytes = utf8.encode(command);
    final withoutResponse = characteristic.properties.writeWithoutResponse &&
        !characteristic.properties.write;

    await characteristic.write(bytes, withoutResponse: withoutResponse);
  }

  Future<void> _onEncender() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);

    try {
      await _connectIfNeeded();
      await _setStatus('Enviando "$commandOn"…');
      await _writeCommand(commandOn);
      if (!mounted) return;
      setState(() {
        _isOn = true;
        _status = 'Gafas ENCENDIDAS ("$commandOn" enviado)';
      });
    } catch (e) {
      await _setStatus('Error al encender: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al encender: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _onApagar() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);

    try {
      await _connectIfNeeded();
      await _setStatus('Enviando "$commandOff"…');
      await _writeCommand(commandOff);
      if (!mounted) return;
      setState(() {
        _isOn = false;
        _status = 'Gafas APAGADAS ("$commandOff" enviado)';
      });
    } catch (e) {
      await _setStatus('Error al apagar: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al apagar: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Control de gafas de entrenamientos de pilotos de la EIHFA',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: colorScheme.primary,
                    ),
              ),
              const SizedBox(height: 28),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _isConnected
                              ? Icons.bluetooth_connected
                              : Icons.bluetooth_disabled,
                          color: _isConnected
                              ? Colors.green.shade700
                              : colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _isConnected ? 'BLE conectado' : 'BLE desconectado',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _isBusy ? null : _onEncender,
                icon: const Icon(Icons.power_settings_new),
                label: const Text('Encender'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                  backgroundColor: Colors.green.shade700,
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: _isBusy ? null : _onApagar,
                icon: const Icon(Icons.power_off),
                label: const Text('Apagar'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                  textStyle: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              if (_isBusy) const Center(child: CircularProgressIndicator()),
              if (!_isBusy)
                Text(
                  _isOn ? 'Estado lógico: ON' : 'Estado lógico: OFF',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
