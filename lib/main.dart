import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'footer.dart';

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
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0E14),
        primaryColor: const Color(0xFF00FF66),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00FF66),
        ),
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
        _status = 'Gafas ENCENDIDAS';
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
        _status = 'Gafas APAGADAS';
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

  Future<void> _onToggleSwitch(bool value) async {
    if (_isBusy) return;
    if (value) {
      await _onEncender();
    } else {
      await _onApagar();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    // --- SECCIÓN 1 Y 2: HEADER (CON FONDO HEAD.PNG) Y LABELS ---
                    Container(
                      width: double.infinity,
                      decoration: const BoxDecoration(
                        image: DecorationImage(
                          image: AssetImage('lib/public/LogosFAC/head.png'),
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                      child: Column(
                        children: [
                          // Escudos superiores
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Image.asset(
                                'lib/public/LogosFAC/Escudo Fuerza Aeroespacial Colombiana- Vertical.png',
                                width: 80,
                                errorBuilder: (context, error, stackTrace) =>
                                    const Icon(Icons.shield, color: Colors.white54, size: 50),
                              ),
                              Image.asset(
                                'lib/public/LogosFAC/ESCUDO CACOM-4.png',
                                width: 80,
                                errorBuilder: (context, error, stackTrace) =>
                                    const Icon(Icons.security, color: Colors.white54, size: 50),
                              ),
                            ],
                          ),
                          const SizedBox(height: 40),

                          // Labels centrales
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(width: 30, height: 3, color: const Color(0xFF00FF66)),
                              const SizedBox(width: 12),
                              const Text(
                                'VISOR FAC',
                                style: TextStyle(
                                  color: Color(0xFF00FF66),
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 4,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Container(width: 30, height: 3, color: const Color(0xFF00FF66)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'SISTEMA DE LIMITACIÓN VISUAL',
                            style: TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 2),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'EIHFA - ENTRENAMIENTO QUE SALVAN VIDAS',
                            style: TextStyle(color: Color(0xFF00FF66), fontSize: 10, letterSpacing: 1),
                          ),
                          const SizedBox(height: 20),
                        ],
                      ),
                    ),

                    // --- SECCIÓN 3 Y 4: TARJETAS DE DATOS ---
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                      child: Column(
                        children: [
                          // Tarjeta de Conexión y Señales
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(0xFF131B26),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: Row(
                              children: [
                                // Estado BLE Real
                                Expanded(
                                  flex: 5,
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF0B121A),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: _isConnected 
                                                ? const Color(0xFF00FF66).withOpacity(0.3) 
                                                : Colors.redAccent.withOpacity(0.3),
                                          ),
                                        ),
                                        child: Icon(
                                          Icons.bluetooth,
                                          color: _isConnected ? const Color(0xFF00FF66) : Colors.redAccent,
                                          size: 20,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            const Text('CONEXIÓN BLE', style: TextStyle(color: Colors.white54, fontSize: 9)),
                                            const SizedBox(height: 2),
                                            Text(
                                              _isConnected ? 'CONECTADO' : 'DESCONECTADO',
                                              style: TextStyle(
                                                color: _isConnected ? const Color(0xFF00FF66) : Colors.redAccent,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 11,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              _device?.platformName.isNotEmpty == true 
                                                  ? _device!.platformName 
                                                  : 'Visor_FAC_01',
                                              style: const TextStyle(color: Colors.white70, fontSize: 10),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            // Indicador dinámico de estado BLE
                                            Text(
                                              _status,
                                              style: const TextStyle(color: Colors.white38, fontSize: 8),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                
                                // Indicadores N/A
                                Expanded(
                                  flex: 6,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                    children: [
                                      _buildStatusColumn('SEÑAL', 'N/A', Icons.signal_cellular_alt, Colors.grey),
                                      _buildStatusColumn('BATERÍA', 'N/A', Icons.battery_unknown, Colors.grey),
                                      _buildStatusColumn('ESTADO', 'N/A', Icons.help_outline, Colors.grey),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 20),

                          // Tarjeta de Control de Gafas
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(0xFF131B26),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      'CONTROL DE GAFAS',
                                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15, letterSpacing: 1),
                                    ),
                                    Switch(
                                      value: _isOn,
                                      activeColor: Colors.white,
                                      activeTrackColor: const Color(0xFF00FF66),
                                      inactiveThumbColor: Colors.white54,
                                      inactiveTrackColor: Colors.redAccent.withOpacity(0.5),
                                      onChanged: _isBusy ? null : _onToggleSwitch,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0B121A),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: _isOn 
                                          ? const Color(0xFF00FF66).withOpacity(0.2) 
                                          : Colors.redAccent.withOpacity(0.2),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      // Imagen del Casco
                                      Container(
                                        width: 90,
                                        height: 90,
                                        decoration: BoxDecoration(
                                          color: Colors.black54,
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: Image.asset(
                                            'lib/public/LogosFAC/casco.png',
                                            fit: BoxFit.cover,
                                            errorBuilder: (context, error, stackTrace) => 
                                                const Icon(Icons.security, size: 36, color: Colors.white54),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 14),
                                      
                                      // Estado dinámico
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'ESTADO ACTUAL', 
                                              style: TextStyle(
                                                color: _isOn ? const Color(0xFF00FF66) : Colors.redAccent, 
                                                fontSize: 10, 
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              _isOn ? 'ENCENDIDO' : 'APAGADO',
                                              style: TextStyle(
                                                color: _isOn ? const Color(0xFF00FF66) : Colors.redAccent,
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            const Text(
                                              'Sistema operativo y limitación visual activa.',
                                              style: TextStyle(color: Colors.white70, fontSize: 11),
                                            ),
                                            // Progress indicator visual mientras envía datos
                                            if (_isBusy) ...[
                                              const SizedBox(height: 8),
                                              const LinearProgressIndicator(color: Color(0xFF00FF66), backgroundColor: Colors.black12),
                                            ]
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      
                                      // Ícono de Poder
                                      Container(
                                        width: 50,
                                        height: 50,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: _isOn ? const Color(0xFF00FF66) : Colors.redAccent, 
                                            width: 2,
                                          ),
                                          color: const Color(0xFF0D1612),
                                        ),
                                        child: Center(
                                          child: Icon(
                                            Icons.power_settings_new,
                                            color: _isOn ? const Color(0xFF00FF66) : Colors.redAccent,
                                            size: 24,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Footer
            const Footer(),
          ],
        ),
      ),
    );
  }

  // Widget auxiliar para las columnas "N/A"
  Widget _buildStatusColumn(String title, String value, IconData icon, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(title, style: const TextStyle(color: Colors.white54, fontSize: 8)),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)),
        const SizedBox(height: 4),
        Icon(icon, color: color, size: 16),
      ],
    );
  }
}