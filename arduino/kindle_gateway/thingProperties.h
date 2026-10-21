#include <ArduinoIoTCloud.h>
#include <Arduino_ConnectionHandler.h>
#include <Arduino_NetworkConfigurator.h>
#include "configuratorAgents/agents/SerialAgent.h"


// Variabili del Thing (diagnostica, tutte in sola lettura)
String lastError;
String lastReset;
int uptimeMin;
bool kindleOnline;
bool spotifyOk;
bool weatherOk;

// Niente agente Bluetooth: costava ~1,6 KB di RAM, che servono all'heap per
// l'HTTPS. Il WiFi si configura via USB dal Cloud (agente seriale).
KVStore kvStore;
SerialAgentClass SerialAgent;
WiFiConnectionHandler ArduinoIoTPreferredConnection; 
NetworkConfiguratorClass NetworkConfigurator(ArduinoIoTPreferredConnection);

void initProperties(){
  ArduinoCloud.addProperty(lastError, READ, ON_CHANGE, NULL);
  ArduinoCloud.addProperty(lastReset, READ, ON_CHANGE, NULL);
  ArduinoCloud.addProperty(uptimeMin, READ, ON_CHANGE, NULL);
  ArduinoCloud.addProperty(kindleOnline, READ, ON_CHANGE, NULL);
  ArduinoCloud.addProperty(spotifyOk, READ, ON_CHANGE, NULL);
  ArduinoCloud.addProperty(weatherOk, READ, ON_CHANGE, NULL);

  NetworkConfigurator.addAgent(SerialAgent);
  NetworkConfigurator.setStorage(kvStore);
  // For changing the default reset pin uncomment and set your preferred pin. Use DISABLE_PIN for disabling the reset procedure.
  //NetworkConfigurator.setReconfigurePin(your_pin);
  ArduinoCloud.setConfigurator(NetworkConfigurator);


}
