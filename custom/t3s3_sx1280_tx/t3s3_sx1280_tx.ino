// T3S3 SX1280 serial-controlled LoRa transmitter.
// MATLAB sends one UTF-8 line over USB serial; the T3S3 transmits its bytes.

#include <Arduino.h>
#include <SPI.h>
#include <RadioLib.h>

// LILYGO T3S3 SX1280 pin map.
static constexpr int RADIO_SCLK = 5;
static constexpr int RADIO_MISO = 3;
static constexpr int RADIO_MOSI = 6;
static constexpr int RADIO_CS   = 7;
static constexpr int RADIO_DIO1 = 9;
static constexpr int RADIO_RST  = 8;
static constexpr int RADIO_BUSY = 36;

static constexpr float RF_FREQ_MHZ = 2400.0f;
static constexpr float LORA_BW_KHZ = 203.125f;
static constexpr uint8_t SPREADING_FACTOR = 7;
static constexpr uint8_t CODING_RATE_DENOMINATOR = 5; // LoRa CR 4/5.
static constexpr uint8_t SYNC_WORD = 0x12;            // Private LoRa sync word.
static constexpr int8_t TX_POWER_DBM = -10;           // Low power for initial testing.
static constexpr uint16_t PREAMBLE_SYMBOLS = 8;
static constexpr size_t MAX_PAYLOAD_BYTES = 255;
static constexpr size_t MAX_COMMAND_BYTES = MAX_PAYLOAD_BYTES + 3; // "TX:" prefix.

SX1280 radio = new Module(RADIO_CS, RADIO_DIO1, RADIO_RST, RADIO_BUSY, SPI);
static bool radioReady = false;
static int16_t radioInitStatus = RADIOLIB_ERR_UNKNOWN;

bool readSerialLine(String &line)
{
    static String incoming;
    static bool overflow = false;
    while (Serial.available() > 0) {
        const int value = Serial.read();
        if (value == '\n') {
            if (overflow) {
                incoming = "";
                overflow = false;
                Serial.println("ERR:MAXLEN");
                return false;
            }
            if (incoming.endsWith("\r")) {
                incoming.remove(incoming.length() - 1);
            }
            line = incoming;
            incoming = "";
            return true;
        }
        if (!overflow && incoming.length() < MAX_COMMAND_BYTES) {
            incoming += static_cast<char>(value);
        } else {
            overflow = true; // Ignore bytes until the terminating newline.
        }
    }
    return false;
}

void setup()
{
    Serial.begin(115200);
    delay(1500); // Allow USB CDC and MATLAB serial connection to settle.

    SPI.begin(RADIO_SCLK, RADIO_MISO, RADIO_MOSI, RADIO_CS);

    int16_t state = radio.begin(RF_FREQ_MHZ, LORA_BW_KHZ, SPREADING_FACTOR,
        CODING_RATE_DENOMINATOR, SYNC_WORD, TX_POWER_DBM, PREAMBLE_SYMBOLS);
    if (state != RADIOLIB_ERR_NONE) {
        radioInitStatus = state;
        Serial.print("RADIO_INIT_FAILED:");
        Serial.println(state);
        return;
    }

    radio.explicitHeader();
    state = radio.setCRC(2); // Two-byte LoRa PHY CRC.
    if (state != RADIOLIB_ERR_NONE) {
        radioInitStatus = state;
        Serial.print("CRC_CONFIG_FAILED:");
        Serial.println(state);
        return;
    }

    radioReady = true;
    radioInitStatus = RADIOLIB_ERR_NONE;
    Serial.println("RADIO_READY");
}

void loop()
{
    if (Serial.available() == 0) {
        delay(2);
        return;
    }

    String payload;
    if (!readSerialLine(payload)) {
        return;
    }
    if (payload == "STATUS") {
        if (radioReady) {
            Serial.println("READY");
        } else {
            Serial.print("ERR:RADIO_NOT_READY:");
            Serial.println(radioInitStatus);
        }
        return;
    }
    if (!payload.startsWith("TX:")) {
        Serial.println("ERR:COMMAND");
        return;
    }
    payload.remove(0, 3);
    if (payload.length() == 0) {
        Serial.println("ERR:EMPTY");
        return;
    }
    if (payload.length() > MAX_PAYLOAD_BYTES) {
        Serial.println("ERR:MAXLEN");
        return;
    }
    if (!radioReady) {
        Serial.print("ERR:RADIO_NOT_READY:");
        Serial.println(radioInitStatus);
        return;
    }

    const size_t payloadLength = payload.length();
    const int16_t state = radio.transmit(
        reinterpret_cast<const uint8_t *>(payload.c_str()), payloadLength);
    if (state == RADIOLIB_ERR_NONE) {
        Serial.print("TX_OK:");
        Serial.println(payloadLength);
    } else {
        Serial.print("ERR:TX:");
        Serial.println(state);
    }
}
