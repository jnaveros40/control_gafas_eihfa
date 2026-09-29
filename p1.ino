/*
 * Control de brillo de pantalla por PWM a 8 kHz
 * ESP32-C3 SuperMini en modo BLE
 *
 * Transición de Web/WiFi a Bluetooth Low Energy (BLE)
 */

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLE2902.h> // Necesario para notificaciones (Batería)

// ---------------- Configuracion BLE ----------------

#define SERVICE_UUID           "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
// Característica para escribir el brillo (ON/OFF o número raw)
#define CHAR_PWM_UUID          "beb5483e-36e1-4688-b7f5-ea07361b26a8"
// Característica para leer/notificar la batería (%)
#define CHAR_BATTERY_UUID      "beb5483e-36e1-4688-b7f5-ea07361b26a9"

BLEServer* pServer = NULL;
BLECharacteristic* pCharPWM = NULL;
BLECharacteristic* pCharBattery = NULL;

bool deviceConnected = false;
bool oldDeviceConnected = false;


// ---------------- Configuracion Hardware ----------------

// GPIO usado para PWM
const int PWM_PIN = 3;

// PWM
const int PWM_FREQ = 8000;   // 8 kHz -> periodo de 125 us
const int PWM_RES  = 12;     // 12 bits -> 4096 cuentas
const int PWM_CH = 0;

// Rango de duty permitido (en %)
const float DUTY_MIN = 95.0f;
const float DUTY_MAX = 100.0f;


// ---------------- Bateria ----------------

const int BAT_ADC_PIN = 0;
const float DIVIDER_RATIO = 2.0f;
const int BAT_SAMPLES = 40;
const float BAT_CAL = 1.0796f;
const uint32_t BAT_INTERVALO_MS = 5000;
const int TABLA_N = 21;

const uint16_t TABLA_MV[TABLA_N] = {
  4200, 4150, 4110, 4080, 4020,
  3980, 3950, 3910, 3870, 3850,
  3840, 3820, 3800, 3790, 3770,
  3750, 3730, 3710, 3690, 3610,
  3270
};

const uint8_t TABLA_PCT[TABLA_N] = {
  100, 95, 90, 85, 80,
  75, 70, 65, 60, 55,
  50, 45, 40, 35, 30,
  25, 20, 15, 10, 5,
  0
};

uint16_t batVoltajeMv = 0;
uint8_t  batPorcentaje = 0;
uint32_t batUltimaLectura = 0;
uint8_t  lastNotifiedBat = 255;


// ---------------- Calculos PWM ----------------

const uint32_t RAW_FULL = 1UL << PWM_RES;
const uint32_t RAW_MIN = (uint32_t)lroundf(DUTY_MIN * RAW_FULL / 100.0f);
const uint32_t RAW_MAX = (uint32_t)lroundf(DUTY_MAX * RAW_FULL / 100.0f);


// ---------------- Estado ----------------

uint32_t nivel = RAW_MIN;
volatile bool commandPending = false;
volatile uint32_t pendingNivel = RAW_MIN;


// ---------------- PWM Funciones ----------------

void pwmInit() {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttach(PWM_PIN, PWM_FREQ, PWM_RES);
#else
  ledcSetup(PWM_CH, PWM_FREQ, PWM_RES);
  ledcAttachPin(PWM_PIN, PWM_CH);
#endif
}

void aplicarNivel() {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWrite(PWM_PIN, nivel);
#else
  ledcWrite(PWM_CH, nivel);
#endif
  Serial.printf("Nivel PWM: %lu (Duty: %.2f%%)\n", (unsigned long)nivel, 100.0f * nivel / RAW_FULL);
}


// ---------------- Bateria Funciones ----------------

void adcBateriaInit() {
  analogSetPinAttenuation(BAT_ADC_PIN, ADC_11db);
}

void ordenar(uint16_t* datos, int n) {
  for (int i = 1; i < n; i++) {
    uint16_t clave = datos[i];
    int j = i - 1;
    while (j >= 0 && datos[j] > clave) {
      datos[j + 1] = datos[j];
      j--;
    }
    datos[j + 1] = clave;
  }
}

uint16_t leerVoltajeBateriaMv() {
  static uint16_t muestras[BAT_SAMPLES];
  for (int i = 0; i < BAT_SAMPLES; i++) {
    muestras[i] = analogReadMilliVolts(BAT_ADC_PIN);
    delay(5);
  }
  ordenar(muestras, BAT_SAMPLES);
  uint16_t nodoMediana = muestras[BAT_SAMPLES / 2];
  float mv = nodoMediana * DIVIDER_RATIO * BAT_CAL;
  return (uint16_t)lroundf(mv);
}

uint8_t voltajeAPorcentaje(uint16_t mv) {
  if (mv >= TABLA_MV[0]) return 100;
  if (mv <= TABLA_MV[TABLA_N - 1]) return 0;
  for (int i = 0; i < TABLA_N - 1; i++) {
    if (mv <= TABLA_MV[i] && mv >= TABLA_MV[i + 1]) {
      float f = (float)(mv - TABLA_MV[i + 1]) / (float)(TABLA_MV[i] - TABLA_MV[i + 1]);
      float pct = TABLA_PCT[i + 1] + f * (TABLA_PCT[i] - TABLA_PCT[i + 1]);
      return (uint8_t)lroundf(pct);
    }
  }
  return 0;
}

void actualizarBateriaSiToca() {
  uint32_t ahora = millis();
  if (ahora - batUltimaLectura < BAT_INTERVALO_MS && batUltimaLectura != 0) {
    return;
  }
  batUltimaLectura = ahora;
  batVoltajeMv  = leerVoltajeBateriaMv();
  batPorcentaje = voltajeAPorcentaje(batVoltajeMv);
  
  Serial.printf("Bateria: %u mV -> %u%%\n", batVoltajeMv, batPorcentaje);
}


// ---------------- BLE Callbacks ----------------

class MyServerCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    Serial.println("BLE: Dispositivo conectado.");
  };

  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    Serial.println("BLE: Dispositivo desconectado.");
  }
};

class MyPWMCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) {
    // Extracción segura de los datos (compatible v2 y v3 de Arduino ESP32)
    const uint8_t* data = pCharacteristic->getData();
    size_t len = pCharacteristic->getLength();
    
    String value = "";
    for (size_t i = 0; i < len; i++) {
      value += (char)data[i];
    }
    
    value.trim();
    value.toUpperCase(); // Para aceptar "on", "ON", "oN", etc.

    if (value.length() > 0) {
      uint32_t newNivel = nivel;

      if (value == "ON") {
        newNivel = RAW_MAX;
      } else if (value == "OFF") {
        newNivel = RAW_MIN;
      } else if (value.startsWith("PCT:")) {
        long pct = value.substring(4).toInt();
        if (pct < 0) pct = 0;
        if (pct > 100) pct = 100;
        newNivel = RAW_MIN + (RAW_MAX - RAW_MIN) * pct / 100;
      } else {
        // Intenta parsearlo como numero (ej: si envían el valor del slider en un futuro)
        long n = value.toInt();
        if (n > 0 || value == "0") {
          if (n < (long)RAW_MIN) n = RAW_MIN;
          if (n > (long)RAW_MAX) n = RAW_MAX;
          newNivel = (uint32_t)n;
        }
      }

      pendingNivel = newNivel;
      commandPending = true;
      Serial.print("BLE Comando recibido: ");
      Serial.println(value);
    }
  }
};


// ---------------- Setup ----------------

void setup() {
  Serial.begin(115200);
  delay(300);

  // 1. Inicializar Hardware (PWM)
  pinMode(PWM_PIN, OUTPUT);
  digitalWrite(PWM_PIN, LOW);
  pwmInit();
  aplicarNivel();
  
  // 2. Inicializar Hardware (Batería)
  adcBateriaInit();
  actualizarBateriaSiToca();

  Serial.printf("Rango util PWM: %lu a %lu cuentas.\n", (unsigned long)RAW_MIN, (unsigned long)RAW_MAX);

  // 3. Inicializar BLE
  BLEDevice::init("VISOR_FAC"); // Este nombre debe coincidir con targetDeviceName en Flutter (o ser reconocido)
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks()); // <--- Corrige el bug del Auto-Advertising

  BLEService *pService = pServer->createService(SERVICE_UUID);

  // Característica PWM (Escritura)
  pCharPWM = pService->createCharacteristic(
    CHAR_PWM_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR
  );
  pCharPWM->setCallbacks(new MyPWMCallbacks());

  // Característica Batería (Lectura y Notificación)
  pCharBattery = pService->createCharacteristic(
    CHAR_BATTERY_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  pCharBattery->addDescriptor(new BLE2902()); // Vital para que Flutter en iOS reciba notificaciones
  
  // Establecer el valor inicial de la batería
  String batStr = String(batPorcentaje) + "," + String(batVoltajeMv);
  pCharBattery->setValue(batStr.c_str());

  pService->start();

  // 4. Configurar e iniciar Advertising
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMaxPreferred(0x12);
  
  BLEDevice::startAdvertising();
  Serial.println("Servidor BLE iniciado y anunciándose...");
}


// ---------------- Loop ----------------

void loop() {
  // 1. Procesar comandos pendientes de BLE
  if (commandPending) {
    commandPending = false;
    nivel = pendingNivel;
    aplicarNivel();
  }

  // 2. Leer batería cuando corresponda
  actualizarBateriaSiToca();

  // 3. Notificar a la app de la bateria periódicamente o si cambió
  static uint32_t lastNotifyTime = 0;
  if (deviceConnected && (batPorcentaje != lastNotifiedBat || millis() - lastNotifyTime > 5000)) {
    lastNotifiedBat = batPorcentaje;
    lastNotifyTime = millis();
    if (pCharBattery) {
      String batStr = String(batPorcentaje) + "," + String(batVoltajeMv);
      pCharBattery->setValue(batStr.c_str());
      pCharBattery->notify(); // Push de la batería hacia Flutter
    }
  }

  // 4. Gestión de auto-advertising al desconectarse
  if (!deviceConnected && oldDeviceConnected) {
    delay(500); // Dar tiempo a que la pila BLE se estabilice tras la desconexión
    pServer->startAdvertising(); 
    Serial.println("BLE: Reiniciando advertising...");
    oldDeviceConnected = deviceConnected;
  }
  
  // Registrar cuando se conecta para la próxima vez
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
  }
}