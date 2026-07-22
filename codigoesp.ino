#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>

#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

#define RELAY_PIN 3

// true = relé encendido (activo en LOW)
volatile bool relayOn = false;
volatile bool commandPending = false;
volatile bool pendingState = false; // true=ON, false=OFF

class MyCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) {
    String value = pCharacteristic->getValue();
    value.trim();

    if (value == "ON") {
      pendingState = true;
      commandPending = true;
    } else if (value == "OFF") {
      pendingState = false;
      commandPending = true;
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
  relayOn = false;

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

  Serial.println("Servidor BLE iniciado. Comandos: ON / OFF");
}

void loop() {
  if (!commandPending) {
    return;
  }

  commandPending = false;
  bool turnOn = pendingState;

  if (turnOn) {
    digitalWrite(RELAY_PIN, LOW); // activar
    relayOn = true;
    Serial.println("Relé ENCENDIDO (ON)");
  } else {
    digitalWrite(RELAY_PIN, HIGH); // desactivar
    relayOn = false;
    Serial.println("Relé APAGADO (OFF)");
  }
}
