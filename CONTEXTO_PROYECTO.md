# Control Contable v2 — Módulo de Comprobantes (Compras/Ventas + OCR)

## Contexto para Claude Code

Este es un sistema existente en producción (`index.html`, single-file app) usado por un
estudio contable independiente en Perú. El dueño (Francisco) es asesor externo de 5 clientes.
El sistema YA FUNCIONA y está en uso — cualquier cambio debe hacerse sin romper lo existente.

**Antes de tocar cualquier código: crear una rama nueva en git (`feature/comprobantes`) y
hacer un respaldo del `index.html` actual. No trabajar directo sobre main/master.**

---

## 1. Qué ya existe (no modificar su lógica base, solo extender)

- **Frontend**: single-file HTML (`index.html`), vanilla JS, sin build step.
- **Backend**: Supabase (Auth + Postgres + Storage). URL y Anon Key ya están configuradas
  en el archivo (líneas ~1399-1400).
- **Auth**: Supabase Auth con roles `admin` / `cliente`, manejado en `applyRoleUI()` y
  `bootstrapPerfil()`.
- **Estilo**: paleta navy/violeta/teal (variables CSS en `:root`), tipografía Segoe UI/system.
  Mantener esta identidad visual — es un sistema distinto a otros proyectos del cliente
  (Bluhaus), no mezclar estilos.
- **Modelo de datos existente relevante**:
  - `clientes` — catálogo de clientes del estudio
  - `cuentas` — cuentas por cobrar/pagar genéricas, con `abonos[]`, función `saldo()`,
    `estadoCuenta()` → pendiente / parcial / pagado / vencido
  - `tipos_impuesto`, `cronograma`, `uit_valor`, `agenda` — módulo de impuestos y
    vencimientos SUNAT
- **Encriptación**: PBKDF2 + AES-GCM client-side para campos sensibles (`deriveKey()`,
  `encryptText()`, `decryptText()`) — reutilizar el mismo patrón si se agregan campos
  sensibles nuevos.
- **Dashboard**: `renderDashboard()` ya arma vista de pendientes ordenados y alertas
  de vencimiento — el nuevo módulo debe alimentar este dashboard, no crear uno paralelo.

## 2. Qué se va a agregar

Un módulo de comprobantes (compras y ventas) con lectura automática por IA, integrado
en la MISMA base de datos y el MISMO login. No es un sistema aparte.

### Flujo de negocio

**Compras** (facturas que el cliente recibe de sus proveedores):
1. El cliente sube la factura de compra (foto/PDF).
2. Gemini la lee y extrae: RUC proveedor, razón social, fecha, monto, IGV, tipo de comprobante.
3. El cliente sube el sustento del pago (voucher/captura de banco) y lo vincula a esa factura.
4. Estado: `pendiente_sustento` → `sustentado` cuando ambos documentos están.

**Ventas** (facturas que el ESTUDIO emite en nombre/representación del cliente, o que el
cliente ya emitió y el estudio registra):
1. El ADMIN (Francisco) sube la factura de venta — no el cliente.
2. Gemini la lee y la asigna a la empresa/cliente correspondiente.
3. Como son servicios afectos a detracción, se calculan: % detracción, monto detracción,
   neto a cobrar (total − detracción).
4. Queda en estado `pendiente_cobro`.
5. El cliente solo sube el voucher de cobro cuando le abonan → estado `cobrado`.

### Reutilizar patrón de OCR de otro proyecto (Rendiciones)

Ya existe un patrón probado para lectura de comprobantes con Google Gemini vía Cloudflare
Workers, usado en el proyecto "Rendiciones" (petty cash app del mismo usuario). Pedir al
usuario acceso a ese repo como referencia si es necesario, o replicar el mismo enfoque:
Worker que recibe la imagen/PDF, llama a Gemini con un prompt estructurado, devuelve JSON
con los campos extraídos (RUC, razón social, fecha, monto, IGV, tipo de documento).

## 3. Esquema de base de datos propuesto (Supabase / Postgres)

```sql
-- Comprobantes de compra
create table comprobantes_compra (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid references clientes(id) not null,
  archivo_url text not null,          -- storage path del comprobante
  ruc_proveedor text,
  razon_social_proveedor text,
  fecha_emision date,
  tipo_comprobante text,              -- factura, boleta, recibo por honorarios, etc.
  numero_comprobante text,
  monto_total numeric(12,2),
  monto_igv numeric(12,2),
  estado text default 'pendiente_sustento', -- pendiente_sustento | sustentado
  ocr_raw jsonb,                      -- respuesta cruda de Gemini, por auditoría
  subido_por uuid references auth.users(id),
  created_at timestamptz default now()
);

-- Comprobantes de venta
create table comprobantes_venta (
  id uuid primary key default gen_random_uuid(),
  cliente_id uuid references clientes(id) not null,
  archivo_url text not null,
  ruc_cliente_final text,             -- a quién le factura el cliente del estudio
  razon_social_cliente_final text,
  fecha_emision date,
  tipo_comprobante text,
  numero_comprobante text,
  monto_total numeric(12,2),
  detraccion_pct numeric(5,2),
  detraccion_monto numeric(12,2),
  neto_cobrar numeric(12,2),
  estado text default 'pendiente_cobro', -- pendiente_cobro | cobrado
  ocr_raw jsonb,
  subido_por uuid references auth.users(id), -- normalmente el admin
  created_at timestamptz default now()
);

-- Pagos/vouchers (aplica a compra o venta)
create table pagos (
  id uuid primary key default gen_random_uuid(),
  comprobante_compra_id uuid references comprobantes_compra(id),
  comprobante_venta_id uuid references comprobantes_venta(id),
  archivo_url text not null,          -- voucher/captura de banco
  monto numeric(12,2),
  fecha_pago date,
  metodo text,                        -- transferencia, detracción, efectivo, etc.
  created_at timestamptz default now(),
  constraint chk_un_comprobante check (
    (comprobante_compra_id is not null)::int + (comprobante_venta_id is not null)::int = 1
  )
);
```

Políticas RLS a definir en Claude Code (siguiendo el mismo patrón que ya usa el sistema
para `clientes`/`cuentas`):
- Cliente: solo puede ver/insertar filas donde `cliente_id` = su empresa asignada.
- Admin: acceso total (lectura/escritura) a las 3 tablas.

## 4. KPIs a agregar al dashboard existente

- **Por cobrar** = suma de `neto_cobrar` de `comprobantes_venta` en estado `pendiente_cobro`,
  por cliente y total consolidado.
- **Por pagar** = suma de `monto_total` de `comprobantes_compra` en estado `pendiente_sustento`.
- **Detracciones pendientes** = suma de `detraccion_monto` de ventas no acreditadas.
- Semáforo de antigüedad (0-15 / 15-30 / +30 días) reutilizando la lógica de `daysUntil()`
  y `badgeYtexto()` ya existentes.

## 5. Módulo de impuestos (extensión, no reemplazo)

El sistema ya tiene `tipos_impuesto`, `cronograma`, `uit_valor`. Con las tablas nuevas se
puede alimentar automáticamente:
- IGV ventas − IGV compras (crédito fiscal) → IGV a pagar, por cliente y por periodo.
- Base mensual para pagos a cuenta de renta según régimen del cliente (RG/RMT/RER).

## 6. Orden de trabajo sugerido (no hacer todo junto)

1. Rama nueva + respaldo del `index.html` actual.
2. Crear tablas nuevas en Supabase + políticas RLS. Probar con datos de prueba.
3. Vista "Mis Comprobantes" en el sidebar del cliente (subir compra, ver/pagar ventas).
4. Vista de carga de ventas para el admin.
5. Integración Gemini OCR (Cloudflare Worker, mismo patrón que Rendiciones).
6. Lógica de detracción en ventas.
7. KPIs por cobrar/por pagar en el dashboard existente.
8. Extensión del módulo de impuestos con los datos de comprobantes.

## 7. Datos de acceso que el usuario tendrá listos (NO pedir que los pegue en chat)

- URL y Anon Key de Supabase (ya en el archivo actual).
- API Key de Google Gemini.
- Acceso a Cloudflare (si se despliega Worker para el OCR).

## 8. Restricciones importantes

- Este proyecto es independiente del estudio/empresa Bluhaus — no reutilizar ni mezclar
  código, branding o contexto de ese otro proyecto, solo el PATRÓN técnico de OCR.
- Actualmente son 5 clientes — no sobre-diseñar para escala; priorizar simplicidad de uso
  tanto para el admin como para los clientes (poca fricción, pocos clics para subir un
  comprobante).
- Mantener todo en un solo `index.html` / mismo repo, sin crear un sistema aparte.
