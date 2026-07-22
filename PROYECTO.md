# Control de gafas EIHFA

Documento de referencia del proyecto para desarrollo en Flutter / Xcode (iOS y macOS).

---

## 1. De qué trata

Aplicación Flutter para **iOS y macOS** que controla por **Bluetooth Low Energy (BLE)** las **gafas de entrenamiento de pilotos de la EIHFA**.

La interfaz muestra el título:

> **Control de gafas de entrenamientos de pilotos de la EIHFA**

Y dos acciones principales:

| Botón | Comando BLE enviado |
|--------|---------------------|
| **Encender** | Cadena de texto `"on"` |
| **Apagar** | Cadena de texto `"off"` |

El comando se escribe en la **característica (characteristic) de escritura** del periférico BLE.

---

## 2. Stack técnico

| Elemento | Valor |
|----------|--------|
| Framework | Flutter (SDK ^3.8.1) |
| Paquete BLE | `flutter_blue_plus: ^2.3.10` |
| Plataformas objetivo | iOS, macOS |
| Código principal | `lib/main.dart` |
| Nombre del paquete | `control_gafas_eihfa` |

---

## 3. Cómo está implementado

### 3.1 Flujo lógico

```
Usuario pulsa Encender / Apagar
        │
        ▼
¿Bluetooth del sistema encendido?
        │
        ▼
Buscar dispositivo ya vinculado / del sistema
        │ (si no hay)
        ▼
Escanear BLE (timeout ~8 s) y conectar
        │
        ▼
discoverServices()
        │
        ▼
Localizar característica writable
        │
        ▼
write( utf8.encode("on" | "off") )
```

### 3.2 Archivo principal (`lib/main.dart`)

- **`GafasEihfaApp`**: `MaterialApp` con tema y pantalla de control.
- **`ControlGafasPage`**: UI + lógica BLE (estado de conexión, botones, mensajes).

Constantes configurables (arriba del archivo):

```dart
const String targetDeviceName = '';           // Nombre parcial del periférico
const Guid? targetServiceUuid = null;         // UUID del servicio GATT
const Guid? targetWriteCharacteristicUuid = null; // UUID de la char. de escritura
```

Comportamiento actual si están vacíos / `null`:

1. Acepta cualquier dispositivo BLE cercano (o el primero vinculado).
2. Usa la **primera característica con `write` o `writeWithoutResponse`**.

### 3.3 UI implementada

- Título fijo de la EIHFA.
- Indicador de estado BLE (conectado / desconectado) y mensaje de estado.
- Botones **Encender** y **Apagar**.
- Indicador de carga mientras hay una operación en curso.
- SnackBars ante errores.

### 3.4 Permisos Apple (ya aplicados en el repo)

#### iOS — `ios/Runner/Info.plist`

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Esta aplicación necesita Bluetooth para conectar y controlar las gafas de entrenamiento de pilotos de la EIHFA.</string>

<key>NSBluetoothPeripheralUsageDescription</key>
<string>Esta aplicación necesita Bluetooth para conectar y controlar las gafas de entrenamiento de pilotos de la EIHFA.</string>
```

#### macOS — `macos/Runner/Info.plist`

Las mismas dos claves (`NSBluetoothAlwaysUsageDescription` y `NSBluetoothPeripheralUsageDescription`).

#### macOS — Entitlements (sandbox)

En `macos/Runner/DebugProfile.entitlements` y `macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.device.bluetooth</key>
<true/>
```

En Xcode también debe quedar marcado:

**Runner → Signing & Capabilities → App Sandbox → Hardware → Bluetooth**

---

## 4. Checklist Xcode (al abrir el proyecto)

Abrir workspaces:

- iOS: `ios/Runner.xcworkspace`
- macOS: `macos/Runner.xcworkspace`

Antes de probar en dispositivo real:

1. [ ] Team / Signing configurado (Apple Developer).
2. [ ] Bundle Identifier correcto.
3. [ ] Bluetooth del Mac/iPhone **activado**.
4. [ ] Probar en **dispositivo físico** (el simulador no sirve bien para BLE).
5. [ ] macOS: App Sandbox → Hardware → **Bluetooth** habilitado.
6. [ ] Confirmar que `Info.plist` tiene las claves de privacidad BLE.
7. [ ] Aceptar el diálogo del sistema de permiso Bluetooth la primera vez.

Comandos útiles desde la raíz del repo:

```bash
flutter pub get
flutter run -d <id_dispositivo>
flutter devices   # listar dispositivos / Mac
```

---

## 5. Qué falta implementar / decidir

Pendiente respecto al hardware real y a producto:

### 5.1 Crítico (hardware)

- [ ] **Nombre BLE exacto** de las gafas → rellenar `targetDeviceName`.
- [ ] **UUID del servicio GATT** → `targetServiceUuid`.
- [ ] **UUID de la característica de escritura** → `targetWriteCharacteristicUuid`.
- [ ] Confirmar que el firmware espera exactamente `"on"` / `"off"` en UTF-8 (sin `\n`, sin CRC, etc.).
- [ ] Probar write **with response** vs **without response** según lo que acepte el periférico.

Ejemplo típico (Nordic UART / NUS), solo si el hardware lo usa:

```dart
const String targetDeviceName = 'NOMBRE_REAL';
const Guid? targetServiceUuid =
    Guid('6E400001-B5A3-F393-E0A9-E50E24DCCA9E');
const Guid? targetWriteCharacteristicUuid =
    Guid('6E400002-B5A3-F393-E0A9-E50E24DCCA9E');
```

### 5.2 Mejoras de app (recomendadas)

- [ ] Pantalla / lista para elegir dispositivo si hay varios.
- [ ] Guardar el último `remoteId` y reconectar sin reescaneo completo.
- [ ] Botón **Desconectar** explícito.
- [ ] Reconexión automática si se pierde el enlace.
- [ ] Feedback de lectura/notificación si el firmware confirma el estado.
- [ ] Modo background BLE (`UIBackgroundModes` → `bluetooth-central`) solo si se necesita.
- [ ] Icono, splash y nombre de display definitivo en App Store / Mac App Store.
- [ ] Tests de integración BLE con dispositivo real.

### 5.3 Plataforma / distribución

- [ ] Certificados y perfiles de provisión en Xcode.
- [ ] Privacy Nutrition Labels / declaración de uso de Bluetooth en App Store Connect.
- [ ] Revisar licencia de `flutter_blue_plus` (`License.nonprofit` vs comercial si aplica a la organización).

---

## 6. Estructura útil del repositorio

```
control_gafas_eihfa/
├── lib/main.dart                 # UI + lógica BLE
├── pubspec.yaml                  # Dependencias (flutter_blue_plus)
├── PROYECTO.md                   # Este documento
├── ios/Runner/Info.plist         # Permisos Bluetooth iOS
├── macos/Runner/Info.plist       # Permisos Bluetooth macOS
├── macos/Runner/*.entitlements   # Sandbox + Bluetooth
└── test/widget_test.dart         # Smoke test de UI
```

---

## 7. Notas rápidas

- Sin nombre/UUID configurados, la app puede conectarse al **primer** dispositivo writable que encuentre: conviene fijarlos antes de uso real.
- `device.connect(license: License.nonprofit, ...)` es requisito de la API actual de `flutter_blue_plus` 2.x.
- BLE requiere hardware real; no depender del Simulator de iOS ni de entornos sin radio Bluetooth.

---

*Última actualización del documento: alineada con la implementación actual en `lib/main.dart` y permisos Apple del repo.*
