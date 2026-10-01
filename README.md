# Control de gafas EIHFA

Documento de referencia del proyecto para desarrollo en Flutter / Android / iOS / Web / Desktop.

---

## 1. De qué trata

Aplicación Flutter para **Android, iOS, macOS y otras plataformas** que controla por **Bluetooth Low Energy (BLE)** las **gafas de entrenamiento de entrenamiento de pilotos de la EIHFA** (Visor FAC).

La interfaz incluye el encabezado institucional (Fuerza Aeroespacial Colombiana y CACOM-4) y permite el control total del visor a través de:

| Acción / Control | Comando BLE enviado / Operación | Descripción |
|------------------|--------------------------------|-------------|
| **Encender (ON)** | Cadena `"ON"` o `"PCT:100"` | Establece el visor al nivel máximo de intensidad permitida. |
| **Apagar (OFF)** | Cadena `"OFF"` o `"PCT:0"` | Apaga la opacidad / pantalla PWM (nivel mínimo). |
| **Slider de Intensidad (0 - 100%)** | Cadena `"PCT:<porcentaje>"` | Ajuste continuo proporcional del brillo / opacidad del visor. |
| **Monitoreo de Batería** | Suscripción / Lectura a `beb5483e-36e1-4688-b7f5-ea07361b26a9` | Recibe lecturas periódicas en formato `porcentaje,milivoltios` (ej: `85,3980`). |
| **Indicador de Señal (RSSI)** | Consulta de RSSI periódica (cada 2s) | Muestra la intensidad del enlace BLE en dBm. |

El comando se escribe en la **característica de escritura PWM** del periférico BLE (`VISOR_FAC`).

---

## 2. Stack técnico y Parámetros BLE

### 2.1 Especificación General

| Elemento | Valor |
|----------|--------|
| Framework | Flutter (SDK ^3.8.1) |
| Paquete BLE | `flutter_blue_plus: ^2.3.10` |
| Plataformas objetivo | Android, iOS, macOS, Windows, Web |
| Código principal app | `lib/main.dart`, `lib/footer.dart` |
| Firmware ESP32 | `p1.ino` / `codigoesp.ino` (ESP32-C3 SuperMini) |

### 2.2 Parámetros del Periférico BLE (`VISOR_FAC`)

```dart
const String targetDeviceName = 'VISOR_FAC';
final Guid targetServiceUuid = Guid('4fafc201-1fb5-459e-8fcc-c5c9c331914b');
final Guid targetWriteCharacteristicUuid = Guid('beb5483e-36e1-4688-b7f5-ea07361b26a8');
final Guid targetBatteryCharacteristicUuid = Guid('beb5483e-36e1-4688-b7f5-ea07361b26a9');
```

---

## 3. Arquitectura e Implementación

### 3.1 Flujo de Conexión y Control BLE

```
   Usuario interactúa (Switch, Slider, Encender/Apagar)
                            │
                            ▼
              ¿Permisos BLE y Adaptador ON?
                            │
                            ▼
       Buscar dispositivo vinculado / `VISOR_FAC`
                            │ (si no está vinculado)
                            ▼
         Escanear BLE por Service UUID (8s timeout)
                            │
                            ▼
       Conectar a `VISOR_FAC` y Descubrir Servicios
                            │
                            ├────────────────────────────────────────┐
                            ▼                                        ▼
          Suscribirse a Notificaciones Batería          Medición Periódica RSSI (2s)
                            │
                            ▼
          Enviar comando ASCII ("PCT:X", "ON", "OFF") 
           por Característica de Escritura PWM
```

### 3.2 Protocolo de Comandos BLE (Firmware ESP32-C3)

El firmware (`p1.ino`) interpreta las siguientes cadenas enviadas mediante UTF-8:

- **`ON`**: Configura el nivel PWM al duty cycle máximo configurado en hardware (`RAW_MAX`).
- **`OFF`**: Configura el nivel PWM al duty cycle mínimo (`RAW_MIN`).
- **`PCT:<0-100>`**: Ajusta de forma lineal el nivel PWM entre `DUTY_MIN` (95%) y `DUTY_MAX` (100%).
- **Valor numérico libre**: Acepta directamente el valor entero del *duty cycle raw*.

---

## 4. Componentes y UI Implementada

- **Encabezado Institucional:** Imagen de cabecera (`head.png`), Escudo FAC (`Escudo Fuerza Aeroespacial Colombiana- Vertical.png`) y Escudo CACOM-4 (`ESCUDO CACOM-4.png`).
- **Control Principal:** Switch interactivo ON/OFF y Slider desplegable (0 a 100%).
- **Indicadores en Tiempo Real:** 
  - Nivel de batería (porcentaje e indicador de voltaje en mV).
  - Nivel de señal BLE (RSSI en dBm).
  - Estado del enlace y notificaciones contextuales (SnackBars).
- **Footer Dinámico (`lib/footer.dart`):** Enlaces e información complementaria de la institución.

---

## 5. Permisos y Configuración Nativa

### Android (`android/app/src/main/AndroidManifest.xml`)

Permisos de Bluetooth y Ubicación configurados:
- `BLUETOOTH`, `BLUETOOTH_ADMIN`
- `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`
- `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`

### Apple iOS / macOS (`ios/Runner/Info.plist`, `macos/Runner/Info.plist`)

- `NSBluetoothAlwaysUsageDescription`: Mensaje explicativo para acceso a Bluetooth.
- `NSBluetoothPeripheralUsageDescription`: Mensaje explicativo para periferia BLE.
- macOS Entitlements: `com.apple.security.device.bluetooth` activado.

---

## 6. Ejecución y Desarrollo

Para ejecutar el proyecto en un dispositivo físico conectado:

```bash
# Obtener dependencias
flutter pub get

# Listar dispositivos físicos conectados
flutter devices

# Compilar y ejecutar
flutter run -d <id_dispositivo>
```

---

*Última actualización: Alineada con la especificación del firmware ESP32-C3 (`p1.ino`) y la aplicación Flutter (`lib/main.dart`).*

