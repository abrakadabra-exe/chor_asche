// ═══════════════════════════════════════════════════════════
//  ESP32 Security System — Phase 2 Firmware (fixed FCM API)
//  State machine: DISARMED → ARMED → ENTRY_DELAY → ALARMING → SILENCED
//  ESP32 Arduino core v3.x + Firebase ESP32 Client latest
// ═══════════════════════════════════════════════════════════

#include <WiFi.h>
#include <FirebaseESP32.h>
#include <ArduinoJson.h>
#include <HTTPClient.h>
#include "secrets.h"

// ── Pin definitions ────────────────────────────────────────
#define PIR1_PIN      34
#define PIR2_PIN      35
#define BUZ1_PIN      25
#define BUZ2_PIN      26
#define BUZ3_PIN      27
#define LED_ARMED     2

// ── Timing constants ───────────────────────────────────────
#define ENTRY_DELAY_MS    15000
#define COOLDOWN_MS       10000
#define SIREN_DURATION_MS 30000
#define PWM_FREQ          3000
#define PWM_RES           8
#define FIREBASE_INTERVAL 2000

// ── System states ──────────────────────────────────────────
enum SystemState {
  DISARMED,
  ARMED,
  ENTRY_DELAY,
  ALARMING,
  SILENCED
};

// ── Global variables ───────────────────────────────────────
SystemState    currentState     = DISARMED;
unsigned long  stateEnteredAt   = 0;
unsigned long  lastToneSwitch   = 0;
unsigned long  lastFirebasePoll = 0;
bool           toneHigh         = true;
int            triggeredSensor  = 0;

// FCM device token — the Flutter app will write this to
// Firebase when it starts. ESP32 reads it from /fcm_token
String         deviceToken      = "";

FirebaseData   fbData;
FirebaseAuth   fbAuth;
FirebaseConfig fbConfig;

// ── Buzzer helpers ─────────────────────────────────────────
void buzzOn(int baseFreq) {
  ledcWriteTone(BUZ1_PIN, baseFreq);
  ledcWriteTone(BUZ2_PIN, baseFreq + 150);
  ledcWriteTone(BUZ3_PIN, baseFreq - 150);
}

void buzzOff() {
  ledcWriteTone(BUZ1_PIN, 0);
  ledcWriteTone(BUZ2_PIN, 0);
  ledcWriteTone(BUZ3_PIN, 0);
}

void entryBeep() {
  static unsigned long lastBeepOn  = 0;
  static bool          beepState   = false;

  unsigned long now = millis();

  if (!beepState && now - lastBeepOn > 800) {
    // time to beep ON
    buzzOn(1000);
    lastBeepOn = now;
    beepState  = true;
  }
  else if (beepState && now - lastBeepOn > 100) {
    // beep has been on for 100ms — turn off
    buzzOff();
    beepState = false;
  }
}

void updateSiren() {
  static int sirenStep = 0;
  
  if (millis() - lastToneSwitch >= 200) {
    lastToneSwitch = millis();
    sirenStep = (sirenStep + 1) % 10; // 10 steps = 5 full hi/lo cycles

    if (sirenStep % 2 == 0) {
      buzzOn(3000);
    } else {
      buzzOn(1500);
    }
  }
}

// ── State machine ──────────────────────────────────────────
void setState(SystemState newState) {
  currentState   = newState;
  stateEnteredAt = millis();
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

// ── Send FCM push via HTTP v1 API directly ─────────────────
// The library's built-in FCM sender changed APIs across versions
// so we send the HTTP POST ourselves — this works on all versions
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

  // Build JSON payload
  StaticJsonDocument<512> doc;
  doc["to"] = deviceToken;
  JsonObject notification  = doc.createNestedObject("notification");
  notification["title"]    = title;
  notification["body"]     = body;
  notification["sound"]    = "default";
  JsonObject data          = doc.createNestedObject("data");
  data["state"]            = (int)currentState;

  String payload;
  serializeJson(doc, payload);

  int httpCode = http.POST(payload);
  Serial.println("FCM response: " + String(httpCode));
  http.end();
}

// ── Sync state to Firebase ─────────────────────────────────
void syncStateToFirebase() {
  if (!Firebase.ready()) return;
  Firebase.setBool(fbData, "/alarm/triggered",    currentState == ALARMING);
  Firebase.setBool(fbData, "/alarm/active_siren", currentState == ALARMING);
}

// ── Poll Firebase for arm/disarm + device token ────────────
void pollFirebase() {
  if (!Firebase.ready()) return;
  if (millis() - lastFirebasePoll < FIREBASE_INTERVAL) return;
  lastFirebasePoll = millis();

  // Read device token written by Flutter app
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

    if (!appWantsArmed && (currentState == ARMED    ||
                           currentState == ENTRY_DELAY ||
                           currentState == ALARMING ||
                           currentState == SILENCED)) {
      setState(DISARMED);
      buzzOff();
      digitalWrite(LED_ARMED, LOW);
      Firebase.setBool(fbData, "/alarm/triggered",    false);
      Firebase.setBool(fbData, "/alarm/active_siren", false);
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

  // Firebase init — legacy token auth (no server_key in config)
  fbConfig.host = FIREBASE_URL;
  fbConfig.signer.tokens.legacy_token = FIREBASE_SECRET;
  Firebase.begin(&fbConfig, &fbAuth);
  Firebase.reconnectWiFi(true);

  // Write initial state
  Firebase.setBool(fbData, "/alarm/armed",        false);
  Firebase.setBool(fbData, "/alarm/triggered",    false);
  Firebase.setBool(fbData, "/alarm/active_siren", false);
  logEvent("ESP32 booted and online");

  Serial.println("PIR sensors warming up (30s)...");
  delay(30000);
  Serial.println("System ready. Currently DISARMED.");
}

// ══════════════════════════════════════════════════════════
void loop() {
  unsigned long now  = millis();
  bool motion1       = digitalRead(PIR1_PIN);
  bool motion2       = digitalRead(PIR2_PIN);
  bool anyMotion     = motion1 || motion2;

  pollFirebase();

  switch (currentState) {

    case DISARMED:
      break;

    case ARMED:
      if (anyMotion) {
        triggeredSensor = motion1 ? 1 : 2;
        Serial.println("Motion! Starting entry delay...");
        setState(ENTRY_DELAY);
        logEvent("Motion on sensor " + String(triggeredSensor) + " — entry delay started");
        sendPushNotification("⚠️ Motion Detected", "Disarm within 15 seconds to cancel");
      }
      break;

    case ENTRY_DELAY:
      entryBeep();
      if (now - stateEnteredAt >= ENTRY_DELAY_MS) {
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
        setState(ENTRY_DELAY);
        logEvent("New motion after silence — entry delay restarted");
        sendPushNotification("⚠️ Motion Again", "New motion detected after silence");
      }
      break;
  }
}