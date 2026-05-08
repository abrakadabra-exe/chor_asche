// ═══════════════════════════════════════════════════════════
//  ESP32 Security System — Full Firmware v3
//  Fixes: floating pin noise, sensor debounce,
//         wailing siren, heartbeat, individual sensor tracking
//  ESP32 Arduino core v3.x compatible
// ═══════════════════════════════════════════════════════════

#include <WiFi.h>
#include <FirebaseESP32.h>
#include <ArduinoJson.h>
#include <HTTPClient.h>
#include "secrets.h"

// ── Pin definitions ────────────────────────────────────────
#define PIR1_PIN            34
#define PIR2_PIN            35
#define BUZ1_PIN            25
#define BUZ2_PIN            26
#define BUZ3_PIN            27
#define LED_ARMED           2

// ── Timing constants ───────────────────────────────────────
#define ENTRY_DELAY_MS      15000
#define COOLDOWN_MS         10000
#define SIREN_DURATION_MS   30000
#define PWM_FREQ            3000
#define PWM_RES             8
#define FIREBASE_INTERVAL   2000
#define HEARTBEAT_INTERVAL  10000

// ── Debounce — sensor must be HIGH for this many consecutive
//    readings before it counts as real motion ───────────────
#define DEBOUNCE_COUNT      5

// ── System states ──────────────────────────────────────────
enum SystemState {
  DISARMED,
  ARMED,
  ENTRY_DELAY,
  ALARMING,
  SILENCED
};

// ── Global variables ───────────────────────────────────────
SystemState    currentState      = DISARMED;
unsigned long  stateEnteredAt    = 0;
unsigned long  lastToneSwitch    = 0;
unsigned long  lastFirebasePoll  = 0;
unsigned long  lastHeartbeat     = 0;
int            triggeredSensor   = 0;
int            sirenStep         = 0;
String         deviceToken       = "";

// Debounce counters for each sensor
int            pir1Count         = 0;
int            pir2Count         = 0;

FirebaseData   fbData;
FirebaseAuth   fbAuth;
FirebaseConfig fbConfig;

// ── Debounced sensor reading ───────────────────────────────
// Returns true only if sensor has been HIGH for DEBOUNCE_COUNT
// consecutive readings — filters out floating pin noise
void readSensors(bool &motion1, bool &motion2) {
  if (digitalRead(PIR1_PIN) == HIGH) {
    pir1Count = min(pir1Count + 1, DEBOUNCE_COUNT + 1);
  } else {
    pir1Count = max(pir1Count - 1, 0);
  }

  if (digitalRead(PIR2_PIN) == HIGH) {
    pir2Count = min(pir2Count + 1, DEBOUNCE_COUNT + 1);
  } else {
    pir2Count = max(pir2Count - 1, 0);
  }

  motion1 = (pir1Count >= DEBOUNCE_COUNT);
  motion2 = (pir2Count >= DEBOUNCE_COUNT);
}

// ── Buzzer helpers ─────────────────────────────────────────
void buzzOn(int baseFreq) {
  ledcWriteTone(BUZ1_PIN, baseFreq);
  ledcWriteTone(BUZ2_PIN, baseFreq + 200);
  ledcWriteTone(BUZ3_PIN, baseFreq - 200);
}

void buzzOff() {
  ledcWriteTone(BUZ1_PIN, 0);
  ledcWriteTone(BUZ2_PIN, 0);
  ledcWriteTone(BUZ3_PIN, 0);
}

// ── Non-blocking entry beep ────────────────────────────────
void entryBeep() {
  static unsigned long lastBeepOn = 0;
  static bool          beepState  = false;
  unsigned long now = millis();
  if (!beepState && now - lastBeepOn > 800) {
    buzzOn(1000);
    lastBeepOn = now;
    beepState  = true;
  } else if (beepState && now - lastBeepOn > 100) {
    buzzOff();
    beepState = false;
  }
}

// ── Wailing siren — attack / hold / drop / silence ────────
void updateSiren() {
  static unsigned long phaseStart = 0;
  static int           phase      = 0;
  static int           freq       = 800;

  unsigned long now     = millis();
  unsigned long elapsed = now - phaseStart;

  switch (phase) {
    case 0:
      // ATTACK — sweep up from 800Hz to 3000Hz
      freq += 30;
      buzzOn(freq);
      if (freq >= 3000) {
        freq = 3000;
        phase = 1;
        phaseStart = now;
      }
      break;

    case 1:
      // HOLD — scream at peak for 200ms
      buzzOn(4000);
      if (elapsed >= 200) {
        phase = 2;
        phaseStart = now;
      }
      break;

    case 2:
      // DROP — sweep down from 4000Hz to 800Hz
      freq -= 40;
      buzzOn(freq);
      if (freq <= 800) {
        freq = 800;
        phase = 3;
        phaseStart = now;
      }
      break;

    case 3:
      // SILENCE — 80ms gap before next cycle
      buzzOff();
      if (elapsed >= 80) {
        phase = 0;
        freq  = 800;
        phaseStart = now;
      }
      break;
  }
}

// ── State machine helper ───────────────────────────────────
void setState(SystemState newState) {
  currentState   = newState;
  stateEnteredAt = millis();
  if (newState == ALARMING) sirenStep = 0;
  Serial.print("State → ");
  switch (newState) {
    case DISARMED:    Serial.println("DISARMED");    break;
    case ARMED:       Serial.println("ARMED");       break;
    case ENTRY_DELAY: Serial.println("ENTRY_DELAY"); break;
    case ALARMING:    Serial.println("ALARMING");    break;
    case SILENCED:    Serial.println("SILENCED");    break;
  }
}

// ── Log event to Firebase ──────────────────────────────────
void logEvent(String message) {
  if (!Firebase.ready()) return;
  String path = "/events/" + String(millis());
  FirebaseJson json;
  json.set("message", message);
  json.set("timestamp", (int)(millis() / 1000));
  Firebase.setJSON(fbData, path, json);
  Serial.println("Event logged: " + message);
}

// ── Send FCM push notification via HTTP ────────────────────
void sendPushNotification(String title, String body) {
  if (deviceToken == "") {
    Serial.println("No device token yet — skipping push");
    return;
  }
  if (WiFi.status() != WL_CONNECTED) return;

  HTTPClient http;
  http.begin("https://fcm.googleapis.com/fcm/send");
  http.addHeader("Content-Type",  "application/json");
  http.addHeader("Authorization", "key=" + String(FCM_SERVER_KEY));

  StaticJsonDocument<512> doc;
  doc["to"] = deviceToken;
  JsonObject notification = doc.createNestedObject("notification");
  notification["title"]   = title;
  notification["body"]    = body;
  notification["sound"]   = "default";
  JsonObject data         = doc.createNestedObject("data");
  data["state"]           = (int)currentState;

  String payload;
  serializeJson(doc, payload);

  int httpCode = http.POST(payload);
  Serial.println("FCM response: " + String(httpCode));
  http.end();
}

// ── Sync alarm state to Firebase ──────────────────────────
void syncStateToFirebase() {
  if (!Firebase.ready()) return;
  Firebase.setBool(fbData, "/alarm/triggered",        currentState == ALARMING);
  Firebase.setBool(fbData, "/alarm/active_siren",     currentState == ALARMING);
  Firebase.setInt(fbData,  "/alarm/triggered_sensor", triggeredSensor);
}

// ── Get Unix time via NTP ──────────────────────────────────
unsigned long getUnixTime() {
  struct tm timeinfo;
  if (!getLocalTime(&timeinfo)) return 0;
  return mktime(&timeinfo);
}

// ── Heartbeat ──────────────────────────────────────────────
void sendHeartbeat() {
  if (!Firebase.ready()) return;
  if (millis() < 32000) return;
  if (millis() - lastHeartbeat < HEARTBEAT_INTERVAL) return;
  lastHeartbeat = millis();

  unsigned long unixTime = getUnixTime();
  if (unixTime == 0) {
    Firebase.setInt(fbData, "/heartbeat", (int)(millis() / 1000));
  } else {
    Firebase.setInt(fbData, "/heartbeat", (int)unixTime);
  }
  Serial.println("Heartbeat sent — Unix time: " + String(unixTime));
}

// ── Poll Firebase for commands + device token ──────────────
void pollFirebase() {
  if (!Firebase.ready()) return;
  if (millis() - lastFirebasePoll < FIREBASE_INTERVAL) return;
  lastFirebasePoll = millis();

  // Read FCM token written by Flutter app
  if (Firebase.getString(fbData, "/fcm_token")) {
    String token = fbData.stringData();
    if (token != "" && token != deviceToken) {
      deviceToken = token;
      Serial.println("Device token updated: " + deviceToken.substring(0, 20) + "...");
    }
  }

  // Read armed flag set by Flutter app
  if (Firebase.getBool(fbData, "/alarm/armed")) {
    bool appWantsArmed = fbData.boolData();

    if (appWantsArmed && currentState == DISARMED) {
      setState(ARMED);
      digitalWrite(LED_ARMED, HIGH);
      logEvent("System armed via app");
      sendPushNotification("Security System", "System is now ARMED");
    }

    if (!appWantsArmed && (currentState == ARMED       ||
                           currentState == ENTRY_DELAY ||
                           currentState == ALARMING    ||
                           currentState == SILENCED)) {
      setState(DISARMED);
      buzzOff();
      digitalWrite(LED_ARMED, LOW);
      pir1Count = 0;
      pir2Count = 0;
      Firebase.setBool(fbData, "/alarm/triggered",        false);
      Firebase.setBool(fbData, "/alarm/active_siren",     false);
      Firebase.setInt(fbData,  "/alarm/triggered_sensor", 0);
      logEvent("System disarmed via app");
      sendPushNotification("Security System", "System is now DISARMED");
    }
  }
}

// ══════════════════════════════════════════════════════════
void setup() {
  Serial.begin(115200);

  pinMode(PIR1_PIN, INPUT);
  pinMode(PIR2_PIN, INPUT);
  pinMode(LED_ARMED, OUTPUT);
  digitalWrite(LED_ARMED, LOW);

  ledcAttach(BUZ1_PIN, PWM_FREQ,       PWM_RES);
  ledcAttach(BUZ2_PIN, PWM_FREQ + 150, PWM_RES);
  ledcAttach(BUZ3_PIN, PWM_FREQ - 150, PWM_RES);
  buzzOff();

  // Connect to Wi-Fi
  Serial.print("Connecting to Wi-Fi");
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\nWi-Fi connected — IP: " + WiFi.localIP().toString());

  // Sync time via NTP — UTC+6 for Bangladesh
  configTime(6 * 3600, 0, "pool.ntp.org");

  // Firebase init
  fbConfig.host = FIREBASE_URL;
  fbConfig.signer.tokens.legacy_token = FIREBASE_SECRET;
  Firebase.begin(&fbConfig, &fbAuth);
  Firebase.reconnectWiFi(true);

  // Write initial state
  Firebase.setBool(fbData, "/alarm/armed",             false);
  Firebase.setBool(fbData, "/alarm/triggered",         false);
  Firebase.setBool(fbData, "/alarm/active_siren",      false);
  Firebase.setInt(fbData,  "/alarm/triggered_sensor",  0);
  Firebase.setInt(fbData,  "/heartbeat",               0);
  logEvent("ESP32 booted and online");

  Serial.println("PIR sensors warming up (30s)...");
  delay(30000);
  Serial.println("System ready. Currently DISARMED.");
}

// ══════════════════════════════════════════════════════════
void loop() {
  unsigned long now = millis();
  bool motion1      = false;
  bool motion2      = false;

  readSensors(motion1, motion2);

  bool anyMotion = motion1 || motion2;

  pollFirebase();
  sendHeartbeat();

  switch (currentState) {

    case DISARMED:
      break;

    case ARMED:
      if (anyMotion) {
        // Determine which sensor triggered
        // If both fire simultaneously, sensor 1 takes priority
        triggeredSensor = motion1 ? 1 : 2;
        Serial.print("Motion detected on sensor ");
        Serial.println(triggeredSensor);
        setState(ENTRY_DELAY);
        Firebase.setInt(fbData, "/alarm/triggered_sensor", triggeredSensor);
        logEvent("Motion on sensor " + String(triggeredSensor) + " — entry delay started");
        sendPushNotification("⚠️ Motion Detected", "Disarm within 15 seconds to cancel");
      }
      break;

    case ENTRY_DELAY:
      entryBeep();
      if (now - stateEnteredAt >= ENTRY_DELAY_MS) {
        buzzOff();
        delay(50);
        setState(ALARMING);
        syncStateToFirebase();
        logEvent("ALARM triggered — sensor " + String(triggeredSensor));
        sendPushNotification("🚨 ALARM TRIGGERED", "Motion on sensor " + String(triggeredSensor));
      }
      break;

    case ALARMING:
      updateSiren();
      if (now - stateEnteredAt >= SIREN_DURATION_MS) {
        setState(SILENCED);
        buzzOff();
        syncStateToFirebase();
        logEvent("Siren auto-silenced after 30s");
        sendPushNotification("Security System", "Siren silenced — system still armed");
      }
      break;

    case SILENCED:
      if (anyMotion && (now - stateEnteredAt >= COOLDOWN_MS)) {
        triggeredSensor = motion1 ? 1 : 2;
        setState(ENTRY_DELAY);
        Firebase.setInt(fbData, "/alarm/triggered_sensor", triggeredSensor);
        logEvent("New motion after silence — sensor " + String(triggeredSensor));
        sendPushNotification("⚠️ Motion Again", "New motion detected after silence");
      }
      break;
  }
}