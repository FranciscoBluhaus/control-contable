// ============================================================
// Edge Function: admin-create-user
// Crea un usuario nuevo con clave temporal "123456" y lo marca
// para que deba cambiarla en su primer inicio de sesión.
// SOLO puede ejecutarla un usuario con rol 'super_admin'.
//
// body: { email: string, rol?: 'usuario' | 'cliente', cliente_id?: string }
//   - rol por defecto es 'usuario' (compatibilidad con el flujo anterior).
//   - si rol === 'cliente', cliente_id es obligatorio: debe ser el id de
//     una fila existente en `clientes`. Se crea además una fila en
//     `asignaciones_clientes` (usuario_id = nuevo usuario, cliente_id)
//     para que el nuevo login caiga dentro del mismo patrón de RLS que
//     ya usa el personal del estudio.
//   - Nunca se acepta rol='super_admin' por esta vía (evita escalar
//     privilegios desde el formulario de invitación).
// ============================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Falta token de autorización' }), { status: 401, headers: corsHeaders });
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

    // Cliente "normal" con el token de quien llama, solo para verificar quién es
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } }
    });
    const { data: userData, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: 'Token inválido' }), { status: 401, headers: corsHeaders });
    }

    const { data: perfil, error: perfilErr } = await callerClient
      .from('perfiles')
      .select('rol')
      .eq('user_id', userData.user.id)
      .maybeSingle();

    if (perfilErr || !perfil || perfil.rol !== 'super_admin') {
      return new Response(JSON.stringify({ error: 'Solo el super administrador puede crear usuarios' }), { status: 403, headers: corsHeaders });
    }

    const body = await req.json();
    const email = (body.email || '').trim();
    if (!email) {
      return new Response(JSON.stringify({ error: 'Falta el email' }), { status: 400, headers: corsHeaders });
    }

    const rol = body.rol === 'cliente' ? 'cliente' : 'usuario';

    // Cliente con permisos de administrador — SOLO existe aquí, nunca en el navegador
    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    let clienteId = null;
    if (rol === 'cliente') {
      clienteId = (body.cliente_id || '').trim();
      if (!clienteId) {
        return new Response(JSON.stringify({ error: 'Falta cliente_id para crear un usuario de tipo cliente' }), { status: 400, headers: corsHeaders });
      }
      const { data: clienteRow, error: clienteErr } = await adminClient
        .from('clientes')
        .select('id')
        .eq('id', clienteId)
        .maybeSingle();
      if (clienteErr || !clienteRow) {
        return new Response(JSON.stringify({ error: 'El cliente indicado no existe' }), { status: 400, headers: corsHeaders });
      }
    }

    const { data: created, error: createErr } = await adminClient.auth.admin.createUser({
      email,
      password: '123456',
      email_confirm: true,
      user_metadata: { must_change_password: true }
    });
    if (createErr) {
      return new Response(JSON.stringify({ error: createErr.message }), { status: 400, headers: corsHeaders });
    }

    const { error: insertPerfilErr } = await adminClient.from('perfiles').insert({
      user_id: created.user.id,
      email: created.user.email,
      rol
    });
    if (insertPerfilErr) {
      return new Response(JSON.stringify({ error: 'El usuario se creó pero falló al crear su perfil: ' + insertPerfilErr.message }), { status: 500, headers: corsHeaders });
    }

    if (rol === 'cliente') {
      const { error: asigErr } = await adminClient.from('asignaciones_clientes').insert({
        usuario_id: created.user.id,
        cliente_id: clienteId
      });
      if (asigErr) {
        return new Response(JSON.stringify({ error: 'El usuario y su perfil se crearon, pero falló la asignación al cliente: ' + asigErr.message }), { status: 500, headers: corsHeaders });
      }
    }

    return new Response(JSON.stringify({ ok: true, user_id: created.user.id }), { status: 200, headers: corsHeaders });
  } catch (err) {
    return new Response(JSON.stringify({ error: err.message || 'Error desconocido' }), { status: 500, headers: corsHeaders });
  }
});
