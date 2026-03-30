import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const DAILY_API_KEY = Deno.env.get("DAILY_API_KEY")!;
const DAILY_DOMAIN = Deno.env.get("DAILY_DOMAIN") || "pulsetest.daily.co";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

    // 1. Parse request body (includes userToken for auth)
    const body = await req.json();
    const { appointmentId, userToken } = body;

    // 2. Authenticate: try userToken from body first, then Authorization header
    const authToken = userToken || (req.headers.get("Authorization") || "").replace("Bearer ", "");
    if (!authToken) {
      return new Response(JSON.stringify({ error: "Missing authentication" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: { user }, error: authError } = await supabase.auth.getUser(authToken);
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (!appointmentId) {
      return new Response(JSON.stringify({ error: "Missing appointmentId" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // 3. Load the appointment
    const { data: appt, error: apptError } = await supabase
      .from("appointments")
      .select("*")
      .eq("id", appointmentId)
      .single();

    if (apptError || !appt) {
      return new Response(JSON.stringify({ error: "Appointment not found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // 4. Authorize: user must be the consumer or the clinician
    const isConsumer = user.id === appt.consumer_id;
    const isClinician = user.id === appt.clinician_id;
    if (!isConsumer && !isClinician) {
      return new Response(JSON.stringify({ error: "Not authorized for this appointment" }), {
        status: 403,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // 5. Enforce join window: 5 minutes before appointment start, with 60-min grace after
    const apptTime = new Date(appt.scheduled_at).getTime();
    const duration = (appt.duration_minutes || 30) * 60 * 1000;

    // No time window restriction — allow joining at any time

    // 6. Get or create Daily room for this appointment (idempotent)
    let roomName = appt.daily_room_name;
    let roomUrl = appt.daily_room_url;

    if (!roomName) {
      // Create a new private room
      roomName = `pulse-${appointmentId.replace(/-/g, "").slice(0, 16)}`;
      const expiryTs = Math.floor((apptTime + duration + 60 * 60 * 1000) / 1000);

      const createRes = await fetch("https://api.daily.co/v1/rooms", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${DAILY_API_KEY}`,
        },
        body: JSON.stringify({
          name: roomName,
          privacy: "private",
          properties: {
            exp: expiryTs,
            enable_chat: true,
            enable_screenshare: true,
            enable_knocking: false,
            start_video_off: false,
            start_audio_off: false,
          },
        }),
      });

      if (!createRes.ok) {
        // Room might already exist — try to fetch it
        const getRes = await fetch(`https://api.daily.co/v1/rooms/${roomName}`, {
          headers: { Authorization: `Bearer ${DAILY_API_KEY}` },
        });
        if (!getRes.ok) {
          return new Response(JSON.stringify({ error: "Failed to create Daily room" }), {
            status: 500,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
      }

      roomUrl = `https://${DAILY_DOMAIN}/${roomName}`;

      // Store room info on appointment
      await supabase
        .from("appointments")
        .update({ daily_room_name: roomName, daily_room_url: roomUrl })
        .eq("id", appointmentId);
    }

    // 7. Generate a meeting token for this user
    const userName = isClinician
      ? (user.user_metadata?.cl_name ? `Dr. ${user.user_metadata.cl_name.split(" ")[0]}` : "Clinician")
      : (user.user_metadata?.first_name || user.email?.split("@")[0] || "Patient");

    const tokenExpiryTs = Math.floor((apptTime + duration + 60 * 60 * 1000) / 1000);
    const tokenRes = await fetch("https://api.daily.co/v1/meeting-tokens", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${DAILY_API_KEY}`,
      },
      body: JSON.stringify({
        properties: {
          room_name: roomName,
          user_name: userName,
          is_owner: isClinician,
          exp: tokenExpiryTs,
        },
      }),
    });

    if (!tokenRes.ok) {
      return new Response(JSON.stringify({ error: "Failed to generate meeting token" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { token: meetingToken } = await tokenRes.json();

    // 8. Update appointment status to confirmed if still pending
    if (appt.status === "pending" && isClinician) {
      await supabase
        .from("appointments")
        .update({ status: "confirmed" })
        .eq("id", appointmentId);
    }

    return new Response(
      JSON.stringify({
        roomUrl,
        token: meetingToken,
        roomName,
        userName,
        isClinician,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
