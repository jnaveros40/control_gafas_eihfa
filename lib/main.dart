import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'footer.dart';

/// Valores del firmware ESP32 (`codigoesp.ino`).
const String targetDeviceName = 'VISOR_FAC';
final Guid? targetServiceUuid =
    Guid('4fafc201-1fb5-459e-8fcc-c5c9c331914b');
final Guid? targetWriteCharacteristicUuid =
    Guid('beb5483e-36e1-4688-b7f5-ea07361b26a8');
final Guid? targetBatteryCharacteristicUuid =
    Guid('beb5483e-36e1-4688-b7f5-ea07361b26a9');

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
  BluetoothCharacteristic? _batteryCharacteristic;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<List<int>>? _batterySubscription;
  
  // Nuevas variables para medir la señal
  Timer? _rssiTimer;
  int? _rssi;
  int? _batteryLevel;
  double? _batteryVoltage;
  
  double _sliderValue = 100.0;

  bool _isBusy = false;
  bool _isConnected = false;
  bool _isOn = false;
  String _status = 'Desconectado';

  @override
  void dispose() {
    _stopRssiTimer();
    _connectionSubscription?.cancel();
    _batterySubscription?.cancel();
    unawaited(_disconnectQuietly());
    super.dispose();
  }

  // Rutina para detener la lectura de la señal
  void _stopRssiTimer() {
    _rssiTimer?.cancel();
    _rssiTimer = null;
  }

  // Rutina para iniciar la lectura de la señal periódicamente
  void _startRssiTimer() {
    _stopRssiTimer();
    _rssiTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_isConnected && _device != null) {
        try {
          final rssi = await _device!.readRssi();
          if (mounted) {
            setState(() {
              _rssi = rssi;
            });
          }
        } catch (e) {
          // Ignorar errores esporádicos de lectura
        }
      }
    });
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

  Future<void> _requestPermissions() async {
    if (!Platform.isAndroid) return;

    const channel = MethodChannel('com.example.control_gafas_eihfa/permissions');
    final granted = await channel.invokeMethod<bool>('requestPermissions') ?? false;
    if (!granted) {
      throw Exception('Permisos necesarios para Bluetooth denegados. Habilítalos en la configuración.');
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

  Future<void> _resolveCharacteristics(BluetoothDevice device) async {
    final services = await device.discoverServices();
    BluetoothCharacteristic? writeChar;
    BluetoothCharacteristic? batteryChar;

    for (final service in services) {
      if (targetServiceUuid != null && service.uuid != targetServiceUuid) continue;
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid == targetWriteCharacteristicUuid) {
          writeChar = characteristic;
        } else if (characteristic.uuid == targetBatteryCharacteristicUuid) {
          batteryChar = characteristic;
        }
      }
    }

    if (writeChar == null) {
      for (final service in services) {
        for (final characteristic in service.characteristics) {
          if (characteristic.properties.write ||
              characteristic.properties.writeWithoutResponse) {
            writeChar = characteristic;
            break;
          }
        }
        if (writeChar != null) break;
      }
    }

    if (writeChar == null) {
      throw Exception('El dispositivo no expone ninguna característica de escritura BLE.');
    }

    _writeCharacteristic = writeChar;
    _batteryCharacteristic = batteryChar;
  }

  Future<void> _subscribeToBattery() async {
    final char = _batteryCharacteristic;
    if (char == null) return;

    await _batterySubscription?.cancel();

    if (char.properties.notify || char.properties.indicate) {
      await char.setNotifyValue(true);
      _batterySubscription = char.onValueReceived.listen((value) {
        if (value.isNotEmpty) {
          final strValue = utf8.decode(value);
          final parts = strValue.split(',');
          if (parts.isNotEmpty) {
            final intValue = int.tryParse(parts[0]);
            double? voltValue;
            if (parts.length > 1) {
              final mvValue = int.tryParse(parts[1]);
              if (mvValue != null) {
                voltValue = mvValue / 1000.0;
              }
            }
            if (intValue != null && mounted) {
              setState(() {
                _batteryLevel = intValue;
                if (voltValue != null) _batteryVoltage = voltValue;
              });
            }
          }
        }
      });
    }

    if (char.properties.read) {
      try {
        final value = await char.read();
        if (value.isNotEmpty) {
          final strValue = utf8.decode(value);
          final parts = strValue.split(',');
          if (parts.isNotEmpty) {
            final intValue = int.tryParse(parts[0]);
            double? voltValue;
            if (parts.length > 1) {
              final mvValue = int.tryParse(parts[1]);
              if (mvValue != null) {
                voltValue = mvValue / 1000.0;
              }
            }
            if (intValue != null && mounted) {
              setState(() {
                _batteryLevel = intValue;
                if (voltValue != null) _batteryVoltage = voltValue;
              });
            }
          }
        }
      } catch (e) {
        // Ignorar
      }
    }
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
          _batteryCharacteristic = null;
          _batteryLevel = null;
          _batteryVoltage = null;
          _batterySubscription?.cancel();
          _status = 'Desconectado';
          _stopRssiTimer();
          _rssi = null;
        } else {
          _startRssiTimer(); // Iniciar medición de señal al conectar
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

    // Ensure runtime permissions before enabling/scanning Bluetooth
    await _requestPermissions();
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
    await _resolveCharacteristics(device);
    await _subscribeToBattery();

    final displayName =
        device.platformName.isEmpty ? device.remoteId.str : device.platformName;

    if (!mounted) return;
    setState(() {
      _device = device;
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
      final pct = _sliderValue.toInt();
      await _setStatus('Enviando nivel $pct%…');
      await _writeCommand('PCT:$pct');
      if (!mounted) return;
      setState(() {
        _isOn = true;
        _status = 'Gafas ENCENDIDAS ($pct%)';
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
      await _setStatus('Apagando gafas…');
      await _writeCommand('PCT:0');
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

  Future<void> _onSliderChangeEnd(double value) async {
    if (!_isConnected) return;
    try {
      await _writeCommand('PCT:${value.toInt()}');
      if (mounted && value > 0 && !_isOn) {
        setState(() {
          _isOn = true;
          _status = 'Gafas ENCENDIDAS (${value.toInt()}%)';
        });
      } else if (mounted && value == 0 && _isOn) {
        setState(() {
          _isOn = false;
          _status = 'Gafas APAGADAS';
        });
      }
    } catch (e) {
      // Ignorar errores esporádicos al deslizar
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
                      height: 240,
                      decoration: const BoxDecoration(
                        image: DecorationImage(
                          image: AssetImage('lib/public/LogosFAC/head.png'),
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                      child: Row(
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
                    ),
                    
                    const SizedBox(height: 20),
                    
                    // Labels centrales (fuera del fondo para mejor lectura)
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
                    const SizedBox(height: 10),

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
                                
                                // Indicadores
                                Expanded(
                                  flex: 6,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                    children: [
                                      _buildSignalColumn(), // Modificado para barras dinámicas
                                      _buildStatusColumn(
                                        'BATERÍA',
                                        _batteryLevel != null ? '$_batteryLevel%\n${_batteryVoltage?.toStringAsFixed(2) ?? "--"}V' : 'N/A',
                                        _batteryLevel != null
                                            ? (_batteryLevel! > 20 ? Icons.battery_full : Icons.battery_alert)
                                            : Icons.battery_unknown,
                                        _batteryLevel != null
                                            ? (_batteryLevel! > 20 ? const Color(0xFF00FF66) : Colors.redAccent)
                                            : Colors.grey,
                                      ),
                                      _buildStatusColumn(
                                        'ESTADO', 
                                        _isOn ? '${_sliderValue.toInt()}%' : 'OFF', 
                                        _isOn ? Icons.visibility : Icons.visibility_off, 
                                        _isOn ? const Color(0xFF00FF66) : Colors.grey
                                      ),
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
                                
                                const SizedBox(height: 20),
                                const Text(
                                  'NIVEL DE OSCURECIMIENTO',
                                  style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 1),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    const Icon(Icons.brightness_5, color: Colors.white54, size: 18),
                                    Expanded(
                                      child: SliderTheme(
                                        data: SliderThemeData(
                                          activeTrackColor: const Color(0xFF00FF66),
                                          inactiveTrackColor: Colors.white12,
                                          thumbColor: Colors.white,
                                          overlayColor: const Color(0xFF00FF66).withOpacity(0.2),
                                          trackHeight: 4,
                                        ),
                                        child: Slider(
                                          value: _sliderValue,
                                          min: 0,
                                          max: 100,
                                          divisions: 100,
                                          onChanged: _isConnected ? (val) {
                                            setState(() {
                                              _sliderValue = val;
                                            });
                                          } : null,
                                          onChangeEnd: _isConnected ? _onSliderChangeEnd : null,
                                        ),
                                      ),
                                    ),
                                    const Icon(Icons.brightness_3, color: Colors.white54, size: 18),
                                  ],
                                ),
                                Center(
                                  child: Text(
                                    '${_sliderValue.toInt()}%',
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
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

  // Widget de Señal Dinámico
  Widget _buildSignalColumn() {
    String text = 'N/A';
    Color color = Colors.grey;
    int bars = 0;

    if (_rssi != null && _isConnected) {
      if (_rssi! >= -65) {
        text = 'FUERTE';
        color = const Color(0xFF00FF66);
        bars = 4;
      } else if (_rssi! >= -75) {
        text = 'BUENA';
        color = const Color(0xFF00FF66);
        bars = 3;
      } else if (_rssi! >= -85) {
        text = 'DÉBIL';
        color = Colors.orangeAccent;
        bars = 2;
      } else {
        text = 'MALA';
        color = Colors.redAccent;
        bars = 1;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text('SEÑAL', style: TextStyle(color: Colors.white54, fontSize: 8)),
        const SizedBox(height: 4),
        Text(text, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11)),
        const SizedBox(height: 6),
        // Dibujo de las barras de señal
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(4, (index) {
            bool active = index < bars;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              width: 3.5,
              height: 6.0 + (index * 3), // Alturas escalonadas (6, 9, 12, 15)
              decoration: BoxDecoration(
                color: active ? color : Colors.white24,
                borderRadius: BorderRadius.circular(1),
              ),
            );
          }),
        ),
      ],
    );
  }

  // Widget auxiliar para las columnas de Batería y Estado
  Widget _buildStatusColumn(String title, String value, IconData icon, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(title, style: const TextStyle(color: Colors.white54, fontSize: 8)),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 11), textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Icon(icon, color: color, size: 16),
      ],
    );
  }
}