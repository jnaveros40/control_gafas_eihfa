/*
 * Control de brillo de pantalla por PWM a 8 kHz
 * ESP32-C3 SuperMini en modo Access Point + servidor web
 *
 * La ventana util del panel es 0 - 8% de duty.
 * Ese tramo se expande a una escala de 0 - 100% para el usuario.
 *
 * El navegador evita acumular peticiones:
 * solo puede haber UNA peticion /set en vuelo.
 * Si el usuario mueve el slider mientras se procesa,
 * se envia solamente el valor mas reciente.
 *
 * NUEVO:
 * - Lectura de bateria LiPo 3.7V por un divisor resistivo
 *   hacia un pin ADC, convertida a % con una curva de
 *   descarga aproximada (no lineal).
 * - Varias medidas para evitar que el WiFi en modo AP
 *   se caiga (sleep de radio, canal fijo, vigilancia
 *   del AP y diagnostico de reinicios).
 *
 * Conectarse a la red "PDLC-ESP32"
 * y abrir http://192.168.4.1
 */

#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <esp_wifi.h>
#include <esp_system.h>


// ---------------- Configuracion ----------------

const char* AP_SSID = "PDLC-ESP32";
const char* AP_PASS = "pdlc12345";

// Canal fijo del AP (evita que el driver lo cambie solo)
const int AP_CHANNEL = 1;

// Numero maximo de clientes conectados al AP
const int AP_MAX_CONN = 4;

// GPIO usado para PWM
const int PWM_PIN = 4;

// PWM
const int PWM_FREQ = 8000;   // 8 kHz -> periodo de 125 us
const int PWM_RES  = 12;     // 12 bits -> 4096 cuentas

// Solo se usa en Arduino-ESP32 2.x
const int PWM_CH = 0;

// Duty maximo de la ventana util
const float DUTY_TOPE = 8.0f;


// ---------------- Bateria ----------------

// GPIO del ADC donde llega el punto medio del divisor.
// GPIO0 = ADC1_CH0 en el ESP32-C3, libre en la SuperMini.
const int BAT_ADC_PIN = 0;

// Divisor resistivo: bateria+ -> R1 -> nodo ADC -> R2 -> GND
// Con R1 = R2 = 100k, el nodo queda a la mitad del voltaje
// de la bateria (maximo ~2.1V con batería a 4.2V), dentro
// del rango seguro del ADC (0 - ~3.3V con atenuacion 11dB).
// Ese divisor consume ~21 uA en reposo, despreciable.
// Se recomienda un capacitor ceramico de 100nF entre el
// nodo ADC y GND, pegado al pin, para filtrar ruido del PWM.
const float DIVIDER_RATIO = 2.0f;

// Cuantas lecturas se promedian por cada actualizacion
const int BAT_SAMPLES = 16;

// Factor de calibracion empirico: el ADC de la ESP32-C3
// (incluso con analogReadMilliVolts calibrado de fabrica)
// suele tener error de hasta 100-150 mV, y las resistencias
// del divisor tienen su propia tolerancia. Para corregirlo:
//
//   1) Mide el voltaje real de la bateria con un multimetro.
//   2) Anota lo que muestra la pagina web en ese mismo momento
//      (sin este factor, o con BAT_CAL = 1.0).
//   3) BAT_CAL = voltaje_multimetro / voltaje_mostrado_app
//
// Ejemplo con tus numeros: 4.07 / 3.77 = 1.0796
const float BAT_CAL = 1.0796f;

// Cada cuanto se refresca la lectura de bateria (no bloqueante)
const uint32_t BAT_INTERVALO_MS = 5000;

// Tabla de descarga aproximada de una LiPo 1S en reposo
// (mV, %). No es lineal: hay mucha meseta entre 60% y 90%.
// OJO: bajo carga (radio transmitiendo, PWM activo) el
// voltaje cae un poco mas de lo que marca esta tabla; es
// una estimacion, no un medidor de carga real (fuel gauge).
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


// ---------------- Calculos PWM ----------------

// 12 bits = 4096 cuentas
const uint32_t RAW_FULL = 1UL << PWM_RES;

// 8% de 4096 = 327.68 -> 328 cuentas
const uint32_t RAW_MAX =
      (uint32_t)lroundf(DUTY_TOPE * RAW_FULL / 100.0f);


// ---------------- Estado ----------------

uint32_t nivel = 0;

WebServer server(80);

// Vigilancia del AP (para que no se quede caido)
uint32_t apUltimoChequeo = 0;
const uint32_t AP_CHEQUEO_MS = 10000;


// ---------------- Web Log ----------------

String webLogBuffer = "";

void addLog(const char* format, ...) {
  char buf[256];
  va_list args;
  va_start(args, format);
  vsnprintf(buf, sizeof(buf), format, args);
  va_end(args);
  
  Serial.print(buf);
  
  uint32_t ms = millis();
  String msg = "[" + String(ms / 1000) + "." + String(ms % 1000) + "s] " + String(buf);
  
  webLogBuffer = msg + webLogBuffer;
  if(webLogBuffer.length() > 2048) {
    webLogBuffer = webLogBuffer.substring(0, 2048);
  }
}


// ---------------- PWM ----------------

void pwmInit() {

  addLog("-> pwmInit(): Configurando pin %d a %d Hz, %d bits de resolucion\n", PWM_PIN, PWM_FREQ, PWM_RES);

#if ESP_ARDUINO_VERSION_MAJOR >= 3
  addLog("-> pwmInit(): API ESP32 Core v3+ (ledcAttach)\n");
  ledcAttach(PWM_PIN, PWM_FREQ, PWM_RES);

#else
  addLog("-> pwmInit(): API ESP32 Core v2 (ledcSetup/Attach)\n");
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

  addLog(
    "-> aplicarNivel(): nivel %lu/%lu | %.1f%% usuario | duty %.3f%% | ton %.3f us\n",

    (unsigned long)nivel,
    (unsigned long)RAW_MAX,

    100.0f * nivel / RAW_MAX,

    100.0f * nivel / RAW_FULL,

    1e6f * nivel /
    (RAW_FULL * (float)PWM_FREQ)
  );
}


// ---------------- Bateria: lectura y curva ----------------

void adcBateriaInit() {

#if ESP_ARDUINO_VERSION_MAJOR >= 3
  analogSetAttenuation(ADC_11db);
#else
  analogSetPinAttenuation(BAT_ADC_PIN, ADC_11db);
#endif
}


uint16_t leerVoltajeBateriaMv() {

  uint32_t suma = 0;

  for (int i = 0; i < BAT_SAMPLES; i++) {

    suma += analogReadMilliVolts(BAT_ADC_PIN);
    delay(2);
  }

  uint32_t promedioNodo = suma / BAT_SAMPLES;

  float mv = promedioNodo * DIVIDER_RATIO * BAT_CAL;

  return (uint16_t)lroundf(mv);
}


uint8_t voltajeAPorcentaje(uint16_t mv) {

  if (mv >= TABLA_MV[0]) {
    return 100;
  }

  if (mv <= TABLA_MV[TABLA_N - 1]) {
    return 0;
  }

  for (int i = 0; i < TABLA_N - 1; i++) {

    if (mv <= TABLA_MV[i] && mv >= TABLA_MV[i + 1]) {

      float f = (float)(mv - TABLA_MV[i + 1]) /
                (float)(TABLA_MV[i] - TABLA_MV[i + 1]);

      float pct = TABLA_PCT[i + 1] +
                  f * (TABLA_PCT[i] - TABLA_PCT[i + 1]);

      return (uint8_t)lroundf(pct);
    }
  }

  return 0;
}


void actualizarBateriaSiToca() {

  uint32_t ahora = millis();

  if (ahora - batUltimaLectura < BAT_INTERVALO_MS &&
      batUltimaLectura != 0) {
    return;
  }

  batUltimaLectura = ahora;

  batVoltajeMv  = leerVoltajeBateriaMv();
  batPorcentaje = voltajeAPorcentaje(batVoltajeMv);

  addLog(
    "-> bateria: %u mV (%.2f V) -> %u%%\n",
    batVoltajeMv,
    batVoltajeMv / 1000.0f,
    batPorcentaje
  );
}


// ---------------- WiFi: estabilidad del AP ----------------

void wifiApInit() {

  WiFi.mode(WIFI_AP);

  // Evita que el driver apague la radio entre paquetes.
  // El ahorro de energia del modem es una causa comun de
  // que los clientes se "caigan" del AP intermitentemente.
  WiFi.setSleep(false);
  esp_wifi_set_ps(WIFI_PS_NONE);

  WiFi.softAP(
    AP_SSID,
    AP_PASS,
    AP_CHANNEL,
    0,               // red visible (no oculta)
    AP_MAX_CONN
  );

  Serial.print("AP listo. IP: ");
  Serial.println(WiFi.softAPIP());
}


void vigilarAP() {

  uint32_t ahora = millis();

  if (ahora - apUltimoChequeo < AP_CHEQUEO_MS) {
    return;
  }

  apUltimoChequeo = ahora;

  if (WiFi.getMode() != WIFI_AP ||
      WiFi.softAPIP() == IPAddress(0, 0, 0, 0)) {

    addLog(
      "AP caido, reiniciando WiFi...\n"
    );

    WiFi.softAPdisconnect(true);
    delay(100);
    wifiApInit();
  }
}


void imprimirMotivoReinicio() {

  esp_reset_reason_t motivo = esp_reset_reason();

  const char* txt = "desconocido";

  switch (motivo) {
    case ESP_RST_POWERON:   txt = "encendido normal"; break;
    case ESP_RST_SW:        txt = "reinicio por software"; break;
    case ESP_RST_PANIC:     txt = "panico / excepcion"; break;
    case ESP_RST_INT_WDT:   txt = "watchdog de interrupcion"; break;
    case ESP_RST_TASK_WDT:  txt = "watchdog de tarea"; break;
    case ESP_RST_WDT:       txt = "otro watchdog"; break;
    case ESP_RST_BROWNOUT:  txt = "brownout (caida de voltaje)"; break;
    default: break;
  }

  Serial.printf(
    "Motivo del ultimo reinicio: %s\n",
    txt
  );
}


// ---------------- Pagina web ----------------

const char PAGINA[] PROGMEM = R"rawliteral(

<!DOCTYPE html>

<html lang="es">

<head>

<meta charset="utf-8">

<meta name="viewport"
      content="width=device-width,initial-scale=1">

<title>Control de pantalla</title>

<style>

body{
  font-family:system-ui,sans-serif;
  background:#111;
  color:#eee;
  margin:0;
  padding:24px;
  display:flex;
  justify-content:center
}

.card{
  background:#1d1d1d;
  border-radius:14px;
  padding:24px;
  width:100%;
  max-width:430px;
  box-shadow:0 2px 12px #0008
}

h1{
  font-size:1.2rem;
  margin:0 0 4px
}

.sub{
  font-size:.78rem;
  color:#888;
  margin:0 0 18px
}

.bateria{
  display:flex;
  align-items:center;
  justify-content:space-between;
  background:#242424;
  border-radius:9px;
  padding:8px 12px;
  margin-bottom:18px;
  font-size:.85rem;
  color:#ccc
}

.bateria .pct{
  font-weight:600;
  font-size:1rem
}

.bateria.baja{
  color:#ff8a80
}

.val{
  font-size:3.4rem;
  font-weight:600;
  text-align:center;
  margin:6px 0 2px
}

.val span.u{
  font-size:1.4rem;
  color:#888;
  margin-left:2px
}

.tec{
  text-align:center;
  font-size:.75rem;
  color:#666;
  margin-bottom:16px;
  font-variant-numeric:tabular-nums
}

.fila{
  display:flex;
  align-items:center;
  gap:12px
}

input[type=range]{
  flex:1;
  height:34px
}

.nudge{
  width:46px;
  height:40px;
  font-size:1.3rem;
  border:1px solid #333;
  border-radius:9px;
  background:#242424;
  color:#ccc;
  cursor:pointer
}

.nudge:active{
  background:#333
}

.lim{
  display:flex;
  justify-content:space-between;
  font-size:.72rem;
  color:#777;
  margin:6px 58px 0
}

.rapidos{
  display:flex;
  gap:8px;
  margin-top:20px
}

.rapidos button{
  flex:1;
  padding:11px 0;
  font-size:.85rem;
  border:1px solid #333;
  border-radius:9px;
  background:#242424;
  color:#bbb;
  cursor:pointer
}

.rapidos button:hover{
  border-color:#555;
  color:#fff
}

.consola{
  margin-top:20px;
  background:#050505;
  border:1px solid #333;
  border-radius:9px;
  padding:12px;
  font-family:monospace;
  font-size:.7rem;
  color:#0f0;
  height:130px;
  overflow-y:auto;
  white-space:pre-wrap;
  word-break:break-all;
}

</style>

</head>

<body>

<div class="card">

  <h1>Brillo de pantalla</h1>

  <p class="sub">
    PWM 8 kHz &middot;
    GPIO%PIN% &middot;
    ventana util 0&ndash;%TOPE%% de duty
  </p>


  <div class="bateria" id="bat">
    <span>Bateria</span>
    <span>
      <span class="pct" id="batPct">--%</span>
      &nbsp;(<span id="batV">--</span> V)
    </span>
  </div>


  <div class="val">

    <span id="v">0.0</span>

    <span class="u">%</span>

  </div>


  <div class="tec" id="t">
    &mdash;
  </div>


  <div class="fila">

    <button class="nudge" id="menos">
      &minus;
    </button>

    <input
      type="range"
      id="s"
      min="0"
      max="%RMAX%"
      step="1"
      value="0"
    >

    <button class="nudge" id="mas">
      +
    </button>

  </div>


  <div class="lim">

    <span>0%</span>

    <span id="pasos"></span>

    <span>100%</span>

  </div>


  <div class="rapidos">

    <button data-p="0">
      Apagar
    </button>

    <button data-p="25">
      25%
    </button>

    <button data-p="50">
      50%
    </button>

    <button data-p="75">
      75%
    </button>

    <button data-p="100">
      100%
    </button>

  </div>

  <div class="consola" id="consola">
    Esperando hardware logs...
  </div>

</div>


<script>

const RMAX = %RMAX%;
const RFULL = %RFULL%;
const FREQ = 8000;


const s = document.getElementById('s');
const v = document.getElementById('v');
const t = document.getElementById('t');

const batDiv = document.getElementById('bat');
const batPct = document.getElementById('batPct');
const batV = document.getElementById('batV');
const consola = document.getElementById('consola');


// ------------------------------------------------
// Control de peticiones
// ------------------------------------------------

// Indica si actualmente hay una peticion al ESP32.
let enviando = false;

// Guarda el ultimo valor que el usuario quiere enviar.
let pendiente = null;


// ------------------------------------------------
// Actualizacion visual
// ------------------------------------------------

function pinta(){

  const r = +s.value;

  v.textContent =
    (100 * r / RMAX).toFixed(1);

  t.textContent =
    'cuenta ' + r + '/' + RMAX +
    '   duty ' +
    (100 * r / RFULL).toFixed(3) +
    '%   ton ' +
    (1e6 * r / (RFULL * FREQ)).toFixed(3) +
    ' us';
}


function pintaBateria(d){

  batPct.textContent = d.bp + '%';
  batV.textContent = (d.bv / 1000).toFixed(2);

  batDiv.classList.toggle('baja', d.bp <= 15);
  
  if (d.log) {
    consola.textContent = d.log;
  }
}


// ------------------------------------------------
// Envio inteligente
// ------------------------------------------------

async function envia(valor){

  // Siempre conservamos el ultimo valor solicitado.
  pendiente = valor;


  // Si ya hay una peticion en curso,
  // no creamos otra.
  if(enviando){
    return;
  }


  enviando = true;


  try{

    while(pendiente !== null){

      // Tomamos el valor mas reciente.
      const n = pendiente;

      // Marcamos que este valor ya esta siendo enviado.
      pendiente = null;


      try{

        const resp = await fetch(
          '/set?n=' + encodeURIComponent(n),
          {
            cache: 'no-store'
          }
        );
        
        if(resp.ok) {
          const d = await resp.json();
          if (d.log) consola.textContent = d.log;
        }

      }catch(e){

        console.log(
          'Error enviando valor:',
          e
        );

      }

    }

  }finally{

    enviando = false;

  }

}


// ------------------------------------------------
// Slider
// ------------------------------------------------

s.addEventListener('input', () => {

  // La interfaz cambia inmediatamente.
  pinta();

  // Se solicita enviar el nuevo valor.
  // Si ya hay una peticion en curso,
  // solo se reemplaza "pendiente".
  envia(+s.value);

});


// ------------------------------------------------
// Boton menos
// ------------------------------------------------

document.getElementById('menos').onclick = () => {

  s.value =
    Math.max(
      0,
      +s.value - 1
    );

  pinta();

  envia(+s.value);

};


// ------------------------------------------------
// Boton mas
// ------------------------------------------------

document.getElementById('mas').onclick = () => {

  s.value =
    Math.min(
      RMAX,
      +s.value + 1
    );

  pinta();

  envia(+s.value);

};


// ------------------------------------------------
// Botones rapidos
// ------------------------------------------------

document
  .querySelectorAll('.rapidos button')
  .forEach(b => {

    b.onclick = () => {

      s.value =
        Math.round(
          RMAX *
          (+b.dataset.p) /
          100
        );

      pinta();

      envia(+s.value);

    };

  });


// ------------------------------------------------
// Estado inicial (una sola vez, mueve el slider)
// ------------------------------------------------

fetch(
  '/estado',
  {
    cache: 'no-store'
  }
)

.then(r => r.json())

.then(d => {

  s.value = d.n;

  pinta();
  pintaBateria(d);

})

.catch(e => {

  console.log(
    'No se pudo obtener el estado inicial:',
    e
  );

});


// ------------------------------------------------
// Actualizacion periodica de bateria
// (no toca el slider, solo refresca el indicador)
// ------------------------------------------------

setInterval(() => {

  fetch('/estado', { cache: 'no-store' })
    .then(r => r.json())
    .then(pintaBateria)
    .catch(() => {});

}, 5000);


// Mostrar numero de pasos

document.getElementById('pasos').textContent =
  RMAX + ' pasos';

</script>

</body>

</html>

)rawliteral";


// ---------------- Handlers ----------------

void handleRoot() {

  String p = FPSTR(PAGINA);

  p.replace(
    "%RMAX%",
    String(RAW_MAX)
  );

  p.replace(
    "%RFULL%",
    String(RAW_FULL)
  );

  p.replace(
    "%PIN%",
    String(PWM_PIN)
  );

  p.replace(
    "%TOPE%",
    String(DUTY_TOPE, 1)
  );

  server.send(
    200,
    "text/html",
    p
  );
}


void handleSet() {

  if(!server.hasArg("n")){
    addLog("-> handleSet(): ERROR, peticion sin 'n'\n");
    server.send(
      400,
      "text/plain",
      "falta n"
    );

    return;
  }

  String argN = server.arg("n");
  addLog("-> handleSet(): Peticion WiFi recibida n = %s\n", argN.c_str());

  long n = argN.toInt();

  if(n < 0) {
    addLog("-> handleSet(): 'n' < 0, limitando a 0\n");
    n = 0;
  }

  if(n > (long)RAW_MAX) {
    addLog("-> handleSet(): 'n' > RAW_MAX (%lu), limitando\n", (unsigned long)RAW_MAX);
    n = RAW_MAX;
  }

  nivel = (uint32_t)n;

  addLog("-> handleSet(): Se actualizo el 'nivel', enviando al hardware...\n");
  aplicarNivel();

  String safeLog = webLogBuffer;
  safeLog.replace("\\", "\\\\");
  safeLog.replace("\"", "\\\"");
  safeLog.replace("\n", "\\n");
  safeLog.replace("\r", "");

  server.send(
    200,
    "application/json",
    "{\"n\":" + String(nivel) + ",\"log\":\"" + safeLog + "\"}"
  );
}


void handleEstado() {

  String safeLog = webLogBuffer;
  safeLog.replace("\\", "\\\\");
  safeLog.replace("\"", "\\\"");
  safeLog.replace("\n", "\\n");
  safeLog.replace("\r", "");

  String j =
    "{\"n\":" +
    String(nivel) +
    ",\"max\":" +
    String(RAW_MAX) +
    ",\"bv\":" +
    String(batVoltajeMv) +
    ",\"bp\":" +
    String(batPorcentaje) +
    ",\"log\":\"" +
    safeLog +
    "\"}";


  server.send(
    200,
    "application/json",
    j
  );
}


// ---------------- Setup ----------------

void setup() {

  Serial.begin(115200);

  delay(300);

  imprimirMotivoReinicio();


  // PWM

  pinMode(
    PWM_PIN,
    OUTPUT
  );

  digitalWrite(
    PWM_PIN,
    LOW
  );


  pwmInit();


  // Arranca apagado

  aplicarNivel();


  addLog(
    "Resolucion: %lu cuentas utiles de %lu por periodo\n",

    (unsigned long)RAW_MAX,

    (unsigned long)RAW_FULL
  );


  // ---------------- Bateria ----------------

  adcBateriaInit();

  actualizarBateriaSiToca();


  // ---------------- WiFi AP ----------------

  wifiApInit();


  // ---------------- Servidor ----------------

  server.on(
    "/",
    handleRoot
  );


  server.on(
    "/set",
    handleSet
  );


  server.on(
    "/estado",
    handleEstado
  );


  server.onNotFound(
    [](){

      server.send(
        404,
        "text/plain",
        "no existe"
      );

    }
  );


  server.begin();


  addLog(
    "Servidor HTTP iniciado\n"
  );

}


// ---------------- Loop ----------------

void loop() {

  server.handleClient();

  actualizarBateriaSiToca();

  vigilarAP();

}