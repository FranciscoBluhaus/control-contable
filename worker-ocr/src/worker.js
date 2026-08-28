// ============================================================
// Worker: control-contable-ocr
// Recibe un comprobante (imagen o PDF) en base64, lo lee con
// Gemini y devuelve los campos extraídos como JSON.
//
// No distingue compra/venta a propósito: cada comprobante tiene un
// EMISOR (ruc/razon_social) y normalmente un RECEPTOR
// (ruc_receptor/razon_social_receptor) — el Worker extrae ambos tal
// cual aparecen en el documento, sin asumir cuál de los dos es "el
// cliente" del estudio contable. Esa decisión es del frontend:
// - Formulario de compra: el proveedor es el EMISOR (ruc/razon_social).
// - Formulario de venta: el "cliente final" es el RECEPTOR
//   (ruc_receptor/razon_social_receptor) — el emisor ahí es el propio
//   cliente del estudio, no interesa para ese campo.
//
// Protección: solo acepta llamadas con un token de sesión válido
// de Supabase (el mismo access_token del login de Control
// Contable) — así no queda abierto a cualquiera que descubra la
// URL y gaste la cuota de Gemini. No hace falta un secreto
// adicional embebido en el HTML público.
//
// body esperado: { mimeType: string, data: string (base64) }
// respuesta: { ok: true, data: {...} } | { ok: false, error }
//
// Rutas:
// - POST /              -> extrae un comprobante individual (factura/boleta/etc).
// - POST /estado-cuenta  -> extrae los movimientos de un estado de cuenta
//                           bancario (conciliación bancaria, Etapa A).
// ============================================================

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
};

const PROMPT_FACTURA = `Eres un asistente que extrae datos de comprobantes de pago peruanos (facturas, boletas, recibos por honorarios, notas de crédito/débito) emitidos según el formato de SUNAT, a partir de una imagen o PDF.

Todo comprobante tiene dos partes (RUC) claramente identificadas en el documento:
- El EMISOR: quien emite/factura el comprobante (normalmente arriba, junto al logo/membrete).
- El RECEPTOR: la persona o empresa A QUIEN VA DIRIGIDO el comprobante — el "Señor(es)" / "Cliente" impreso en el documento (normalmente en el bloque de datos del comprador). NO es lo mismo que el emisor — son entidades distintas con RUCs distintos.

Extrae exactamente estos campos:
- ruc: el RUC (11 dígitos) del EMISOR.
- razon_social: la razón social o nombre del EMISOR.
- ruc_receptor: el RUC (11 dígitos) del RECEPTOR, tal como aparece impreso en el documento. Extráelo siempre que el documento lo muestre, sin importar el tipo de comprobante — en Boleta u otros tipos a veces no aparece o el comprador es una persona sin RUC; en ese caso deja "".
- razon_social_receptor: la razón social o nombre del RECEPTOR, mismo criterio que ruc_receptor.
- fecha_emision: la fecha de emisión, en formato YYYY-MM-DD.
- tipo_comprobante: uno de "Factura", "Boleta", "Recibo por honorarios", "Nota de crédito", "Nota de débito", "Recibo por Arrendamiento", "Ticket/Boleta de máquina registradora", "Recibo por Servicios Públicos", "Guía de Remisión", "Comprobante de Retención", "Comprobante de Percepción" u "Otro".
- numero_comprobante: la serie y número del comprobante, tal como aparece (ej. "F001-00123").
- concepto: la descripción del servicio o producto facturado, tal como aparece en el detalle del comprobante. Si hay varias líneas de detalle, resume en una sola frase breve.
- monto_total: el monto total del comprobante (incluye impuestos), como número.
- monto_igv: el monto del IGV discriminado en el comprobante, como número. Usa 0 si no aplica o no se distingue (por ejemplo en un recibo por honorarios).
- monto_retencion: el monto de la retención aplicada, si el documento la muestra (busca palabras como "Retención", "Ret.", "IR:", o un monto entre paréntesis restado del total — típico en un Recibo por Honorarios con retención de renta de 4ta categoría). Usa 0 si no aparece ninguna retención.
- porcentaje_retencion: el porcentaje de esa retención si se indica explícitamente (ej. "8%"). Usa 0 si no aparece.
- moneda: "PEN" si el documento está en soles (símbolo "S/"), o "USD" si está en dólares (símbolo "US$", "USD", "$", o dice "Dólares"). Si no hay ninguna indicación de moneda, asume "PEN" — es lo normal en un comprobante peruano.

No confundas emisor con receptor bajo ninguna circunstancia — son los dos RUCs más importantes del documento y deben quedar en los campos correctos. Si algún dato no aparece o no puedes leerlo con certeza, usa una cadena vacía "" (para texto) o 0 (para números). No inventes datos.`;

const RESPONSE_SCHEMA_FACTURA = {
  type: 'OBJECT',
  properties: {
    ruc: { type: 'STRING' },
    razon_social: { type: 'STRING' },
    ruc_receptor: { type: 'STRING' },
    razon_social_receptor: { type: 'STRING' },
    fecha_emision: { type: 'STRING' },
    tipo_comprobante: {
      type: 'STRING',
      enum: ['Factura', 'Boleta', 'Recibo por honorarios', 'Nota de crédito', 'Nota de débito', 'Recibo por Arrendamiento', 'Ticket/Boleta de máquina registradora', 'Recibo por Servicios Públicos', 'Guía de Remisión', 'Comprobante de Retención', 'Comprobante de Percepción', 'Otro']
    },
    numero_comprobante: { type: 'STRING' },
    concepto: { type: 'STRING' },
    monto_total: { type: 'NUMBER' },
    monto_igv: { type: 'NUMBER' },
    monto_retencion: { type: 'NUMBER' },
    porcentaje_retencion: { type: 'NUMBER' },
    moneda: { type: 'STRING', enum: ['PEN', 'USD'] }
  },
  required: ['ruc', 'razon_social', 'ruc_receptor', 'razon_social_receptor', 'fecha_emision', 'tipo_comprobante', 'numero_comprobante', 'concepto', 'monto_total', 'monto_igv', 'monto_retencion', 'porcentaje_retencion', 'moneda']
};

// ------------------------------------------------------------------
// Conciliación bancaria (Etapa A): extrae los movimientos de un estado
// de cuenta bancario (PDF, normalmente varias páginas) en vez de un
// comprobante individual. Ruta separada porque el prompt/schema no
// tienen nada que ver con una factura.
// ------------------------------------------------------------------
const PROMPT_ESTADO_CUENTA = `Eres un asistente que extrae movimientos de un estado de cuenta bancario peruano (PDF), a partir de una imagen o PDF que puede tener varias páginas.

Extrae:
- banco: el nombre del banco que emite el estado de cuenta (ej. "BCP", "Interbank", "BBVA", "Scotiabank", "Banco de la Nación", "Banco Pichincha"), normalmente visible en el logo o membrete. Solo si estás razonablemente seguro — usa "" si no lo puedes identificar con confianza, no adivines.
- periodo_inicio: la fecha de inicio del período que cubre el estado de cuenta (YYYY-MM-DD). Si el documento indica el período como un rango explícito de fechas, usa la fecha de inicio tal cual. Si en cambio lo indica como un mes y año (ej. "Enero 2026", "Estado de cuenta de 01/2026"), calcula el primer día de ese mes. Usa "" solo si no hay ninguna indicación de período en el documento.
- periodo_fin: la fecha de fin del período (YYYY-MM-DD). Mismo criterio que periodo_inicio — si el documento solo indica un mes y año, calcula el último día de ese mes. Usa "" solo si no hay ninguna indicación de período.
- movimientos: la lista de TODOS los movimientos (abonos y cargos) que aparecen en el detalle del documento, cada uno con:
  - fecha: fecha del movimiento (YYYY-MM-DD). IMPORTANTE: los estados de cuenta bancarios peruanos casi siempre muestran cada línea de movimiento SOLO con día y mes (ej. "13/05"), sin repetir el año — el año casi nunca aparece en cada fila individual. Cuando la línea del movimiento no trae año explícito, NO lo adivines ni asumas un año por defecto: usa el año que corresponde según periodo_inicio/periodo_fin de este mismo documento (calculados arriba). Si el período cruza un cambio de año (ej. de diciembre a enero), usa el año que le corresponda al mes de ese movimiento específico — diciembre toma el año de periodo_inicio, enero toma el año de periodo_fin. Solo si no hay absolutamente ninguna pista de año en todo el documento (ni en el período, ni en ningún encabezado), usa tu mejor estimación — esto debería ser muy poco común.
  - monto: el monto del movimiento, SIEMPRE como número positivo (el signo/dirección va en "tipo", nunca en el monto).
  - moneda: "PEN" si la cuenta/columna está en soles (símbolo "S/"), o "USD" si está en dólares (símbolo "US$", "USD" o "$").
  - tipo: "abono" si es dinero que ENTRA a la cuenta (depósito, transferencia recibida, abono, etc.) o "cargo" si es dinero que SALE (pago, transferencia enviada, comisión, cargo, etc.).
  - descripcion: la glosa/descripción del movimiento tal como aparece (ej. "TRANSF INTERBANCARIA - JUAN PEREZ").

No te saltes movimientos ni los resumas — extrae cada línea individual del detalle. Ignora saldos de apertura/cierre y totales, solo interesan los movimientos individuales. Si no puedes leer con certeza algún campo de un movimiento, usa tu mejor estimación razonable; no inventes movimientos que no existen en el documento.`;

const RESPONSE_SCHEMA_ESTADO_CUENTA = {
  type: 'OBJECT',
  properties: {
    banco: { type: 'STRING' },
    periodo_inicio: { type: 'STRING' },
    periodo_fin: { type: 'STRING' },
    movimientos: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          fecha: { type: 'STRING' },
          monto: { type: 'NUMBER' },
          moneda: { type: 'STRING', enum: ['PEN', 'USD'] },
          tipo: { type: 'STRING', enum: ['abono', 'cargo'] },
          descripcion: { type: 'STRING' }
        },
        required: ['fecha', 'monto', 'moneda', 'tipo', 'descripcion']
      }
    }
  },
  required: ['banco', 'periodo_inicio', 'periodo_fin', 'movimientos']
};

function jsonResponse(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json', ...CORS_HEADERS }
  });
}

// Códigos HTTP transitorios de Gemini (saturación/rate-limit) que vale la
// pena reintentar — no confundir con errores "de verdad" (archivo corrupto,
// prompt inválido, etc.), esos siguen fallando rápido sin reintentar.
const CODIGOS_REINTENTABLES = new Set([429, 500, 502, 503, 504]);
const ESPERAS_MS = [1000, 2000]; // backoff entre reintentos: 1s, luego 2s (2 reintentos como máximo)

async function llamarGeminiConReintentos(url, geminiBody) {
  let intento = 0;
  while (true) {
    let resp;
    try {
      resp = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(geminiBody)
      });
    } catch (e) {
      // Fallo de red al contactar a Gemini (DNS/conexión) — no es el caso de
      // saturación que pide reintento, falla rápido igual que antes.
      throw { mensaje: 'No se pudo contactar a Gemini: ' + e.message };
    }

    if (resp.ok) return resp;

    const puedeReintentar = CODIGOS_REINTENTABLES.has(resp.status) && intento < ESPERAS_MS.length;
    if (!puedeReintentar) {
      const errText = await resp.text();
      throw { mensaje: 'Gemini respondió con error: ' + errText };
    }

    await new Promise(r => setTimeout(r, ESPERAS_MS[intento]));
    intento++;
  }
}

async function esUsuarioValido(request, env) {
  const authHeader = request.headers.get('Authorization') || '';
  const token = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!token) return false;
  try {
    const resp = await fetch(`${env.SUPABASE_URL}/auth/v1/user`, {
      headers: { Authorization: `Bearer ${token}`, apikey: env.SUPABASE_ANON_KEY }
    });
    return resp.ok;
  } catch (e) {
    return false;
  }
}

export default {
  async fetch(request, env) {
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }
    if (request.method !== 'POST') {
      return jsonResponse({ ok: false, error: 'Método no permitido' }, 405);
    }
    if (!env.GEMINI_API_KEY) {
      return jsonResponse({ ok: false, error: 'Falta configurar el secret GEMINI_API_KEY en el Worker' }, 500);
    }
    if (!(await esUsuarioValido(request, env))) {
      return jsonResponse({ ok: false, error: 'No autorizado' }, 401);
    }

    let body;
    try {
      body = await request.json();
    } catch (e) {
      return jsonResponse({ ok: false, error: 'JSON inválido' }, 400);
    }
    const { mimeType, data } = body || {};
    if (!mimeType || !data) {
      return jsonResponse({ ok: false, error: 'Faltan mimeType o data (base64) del archivo' }, 400);
    }

    const esEstadoCuenta = new URL(request.url).pathname === '/estado-cuenta';
    const prompt = esEstadoCuenta ? PROMPT_ESTADO_CUENTA : PROMPT_FACTURA;
    const schema = esEstadoCuenta ? RESPONSE_SCHEMA_ESTADO_CUENTA : RESPONSE_SCHEMA_FACTURA;

    const modelo = env.GEMINI_MODEL || 'gemini-3.6-flash';
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${modelo}:generateContent?key=${env.GEMINI_API_KEY}`;

    const geminiBody = {
      contents: [{
        parts: [
          { text: prompt },
          { inlineData: { mimeType, data } }
        ]
      }],
      generationConfig: {
        responseMimeType: 'application/json',
        responseSchema: schema
      }
    };

    let geminiResp;
    try {
      geminiResp = await llamarGeminiConReintentos(url, geminiBody);
    } catch (e) {
      return jsonResponse({ ok: false, error: e.mensaje }, 502);
    }

    const geminiJson = await geminiResp.json();
    const textoRespuesta = geminiJson?.candidates?.[0]?.content?.parts?.[0]?.text;
    if (!textoRespuesta) {
      return jsonResponse({ ok: false, error: 'Gemini no devolvió datos legibles (posible bloqueo de contenido o archivo ilegible)' }, 502);
    }

    let datos;
    try {
      datos = JSON.parse(textoRespuesta);
    } catch (e) {
      return jsonResponse({ ok: false, error: 'La respuesta de Gemini no fue un JSON válido' }, 502);
    }

    return jsonResponse({ ok: true, data: datos });
  }
};
