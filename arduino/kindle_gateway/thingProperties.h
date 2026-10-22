#include <ArduinoIoTCloud.h>
#include <Arduino_ConnectionHandler.h>
#include <Arduino_NetworkConfigurator.h>
#include "configuratorAgents/agents/SerialAgent.h"


// Thing variables (diagnostics, all read-only)
String lastError;
String lastReset;
int uptimeMin;
bool kindleOnline;
bool spotifyOk;
bool weatherOk;

// No Bluetooth agent: it cost ~1.6 KB of RAM that the heap needs for HTTPS.
// WiFi is configured over USB from the Cloud (serial agent).
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
