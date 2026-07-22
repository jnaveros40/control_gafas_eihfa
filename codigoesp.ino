#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>

#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

#define RELAY_PIN 3   

// Variables de control
volatile bool triggerRelay = false;
bool relayActive = false;
unsigned long relayStart = 0;
const unsigned long relayDuration = 90; // ms (ajústalo si necesitas)

// Clase para manejar escritura en la característica
class MyCallbacks: public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) {
    String value = pCharacteristic->getValue();

    if (value == "ON") {
      if (!relayActive) {   // evita múltiples disparos
        triggerRelay = true;
      }
    } else {
      Serial.print("Comando desconocido: ");
      Serial.println(value);
    }
  }
};

void setup() {
  Serial.begin(115200);

  pinMode(RELAY_PIN, OUTPUT);
  digitalWrite(RELAY_PIN, HIGH); // apagado inicial (activo en LOW)

  // Inicializa BLE
  BLEDevice::init("VISOR_FAC");
  BLEServer *pServer = BLEDevice::createServer();

  BLEService *pService = pServer->createService(SERVICE_UUID);

  BLECharacteristic *pCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE
  );

  pCharacteristic->setValue("Esperando comando...");
  pCharacteristic->setCallbacks(new MyCallbacks());

  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);
  pAdvertising->setMaxPreferred(0x12);

  BLEDevice::startAdvertising();

  Serial.println("Servidor BLE iniciado. Conéctate desde tu celular.");
}

void loop() {

  // Activar relé (simula pulsador)
  if (triggerRelay && !relayActive) {
    triggerRelay = false;
    relayActive = true;

    digitalWrite(RELAY_PIN, LOW); // activar
    relayStart = millis();

    Serial.println("Relé ACTIVADO");
  }

  // Desactivar relé después del tiempo
  if (relayActive && millis() - relayStart >= relayDuration) {
    digitalWrite(RELAY_PIN, HIGH); // desactivar
    relayActive = false;

    Serial.println("Relé DESACTIVADO");
  }
}