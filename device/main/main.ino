#include <Arduino_HTS221.h>
#include <ArduinoBLE.h>

BLEService service("181A"); // Standard Environmental Sensing Service
BLEFloatCharacteristic characteristic("2A1C", BLERead | BLENotify); // Temperature Measurement

void setup() {
  Serial.begin(9600);
  while (!Serial);

  pinMode(LED_BUILTIN, OUTPUT);

  if (!HTS.begin()) {
    Serial.println("Humidity and temperature sensor initialization failed!");
    while (true);
  }

  if (!BLE.begin()) {
    Serial.println("Bluetooth module initialization failed!");
    while (true);
  }

  BLE.setLocalName("temper-device");

  service.addCharacteristic(characteristic);
  BLE.addService(service);

  BLE.setAdvertisedService(service);
  if (!BLE.advertise()) {
    Serial.println("Bluetooth advertising failed!");
    while (true);
  }

  Serial.println("Setup complete.");
}

void loop() {
  BLEDevice central = BLE.central();
  if (!central)
    return;

  Serial.print("Connected to central device: ");
  Serial.println(central.address());
  digitalWrite(LED_BUILTIN, HIGH);

  while (central.connected()) {
      float new_temperature = HTS.readTemperature();
      Serial.println(new_temperature);
      if (new_temperature != characteristic.value())
        characteristic.writeValue(new_temperature);
      delay(1000);
  }

  Serial.print("Disconnected from central device: ");
  Serial.println(central.address());
  digitalWrite(LED_BUILTIN, LOW);
}
