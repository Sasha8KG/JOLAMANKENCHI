const FIREBASE_API_KEY = "AIzaSyBh5WG_rXaxBjDHOVPXPmmw8gqBCRubIAM";
const PROJECT_ID = "jol-aman-kenchi";
const DISPATCHER_UID = "AMGNzQEr7GfnisJcr7u4BqcdIvh1";

function response(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "Content-Type, Authorization",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS"
    }
  });
}

function hasForbiddenControlCharacters(value) {
  return Array.from(String(value)).some((character) => {
    const code = character.charCodeAt(0);
    return (code < 32 && code !== 9 && code !== 10 && code !== 13) || code === 127;
  });
}
async function verifyFirebaseUser(request) {
  const h = request.headers.get("Authorization") || "";
  const token = h.startsWith("Bearer ") ? h.slice(7) : "";
  if (!token) throw new Error("Не передан токен Firebase");
  const r = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=" + FIREBASE_API_KEY, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ idToken: token })
  });
  const data = await r.json();
  if (!r.ok || !data.users || !data.users.length) throw new Error("Firebase не подтвердил пользователя");
  if (data.users[0].disabled) throw new Error("Учётная запись отключена");
  return { user: data.users[0], token };
}

async function driverRow(env, uid) {
  // No hardcoded test-account bypass: every driver must be approved in D1 by dispatch.
  return await env.DB.prepare("SELECT * FROM drivers WHERE uid=?").bind(uid).first();
}

async function requireDispatcher(request) {
  const auth = await verifyFirebaseUser(request);
  if (auth.user.localId !== DISPATCHER_UID) throw new Error("Требуются права диспетчера");
  return auth;
}

async function requireApprovedDriver(request, env, requireOnline = false) {
  const auth = await verifyFirebaseUser(request);
  const driver = await driverRow(env, auth.user.localId);
  if (!driver || Number(driver.approved) !== 1) throw new Error("Водитель ещё не одобрен диспетчером");
  if (requireOnline && Number(driver.online) !== 1) throw new Error("Сначала выйдите на линию");
  return { ...auth, driver };
}

async function requireRadioMember(request, env) {
  const auth = await verifyFirebaseUser(request);
  if (auth.user.localId === DISPATCHER_UID) return { ...auth, role: "dispatcher", name: "Диспетчер" };
  const driver = await driverRow(env, auth.user.localId);
  if (!driver || Number(driver.approved) !== 1) throw new Error("Рация доступна только одобренным водителям и диспетчеру");
  return { ...auth, role: "driver", driver, name: String(driver.name || "Водитель") };
}

function base64Url(value) {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value;
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

async function createLiveKitToken(env, uid, name) {
  const key = env.LIVEKIT_API_KEY;
  const secret = env.LIVEKIT_API_SECRET;
  if (!key || !secret || !env.LIVEKIT_URL) throw new Error("Голосовая рация ещё не настроена: администратору нужно подключить LiveKit в Cloudflare");
  const now = Math.floor(Date.now() / 1000);
  const header = base64Url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const payload = base64Url(JSON.stringify({
    iss: key, sub: uid, name: name.slice(0, 80), nbf: now - 5, iat: now, exp: now + 3600,
    video: { roomJoin: true, room: "jol-aman-kenchi-radio", canPublish: true, canSubscribe: true, canPublishData: true }
  }));
  const unsigned = header + "." + payload;
  const cryptoKey = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(unsigned)));
  return unsigned + "." + base64Url(signature);
}

function num(v) { const n = Number(v); return Number.isFinite(n) ? n : null; }

function hasFreshValidDriverLocation(driver, nowSeconds = Math.floor(Date.now() / 1000)) {
  const latitude = num(driver?.latitude);
  const longitude = num(driver?.longitude);
  const updatedAt = num(driver?.location_updated_at);
  if (latitude === null || longitude === null || updatedAt === null ||
      latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) return false;
  const ageSeconds = nowSeconds - updatedAt;
  return ageSeconds >= 0 && ageSeconds <= 60;
}

// Kyrgyzstan business day: UTC+6, independent of the Cloudflare data-center timezone.
function kgTodayDate() {
  return new Date(Date.now() + 6 * 60 * 60 * 1000).toISOString().slice(0, 10);
}
function kgDateBounds(dateText) {
  const value = String(dateText || "");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error("Дата смены должна быть в формате ГГГГ-ММ-ДД");
  const [year, month, day] = value.split("-").map(Number);
  const check = new Date(Date.UTC(year, month - 1, day));
  if (check.getUTCFullYear() !== year || check.getUTCMonth() + 1 !== month || check.getUTCDate() !== day) {
    throw new Error("Указана неверная дата смены");
  }
  const start = Math.floor(Date.UTC(year, month - 1, day) / 1000) - 6 * 60 * 60;
  return { start, end: start + 86400 };
}
function distanceKm(aLat, aLng, bLat, bLng) {
  const rad = x => x * Math.PI / 180;
  const dLat = rad(bLat - aLat), dLng = rad(bLng - aLng);
  const x = Math.sin(dLat / 2) ** 2 + Math.cos(rad(aLat)) * Math.cos(rad(bLat)) * Math.sin(dLng / 2) ** 2;
  return 6371 * 2 * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
}

async function patchFirestoreAssignment(order, driver, token) {
  const fields = {
    status: { stringValue: "driver_assigned" },
    assignedDriverUid: { stringValue: driver.uid },
    driver: { stringValue: driver.car_number ? (driver.name || "Водитель") + " / " + driver.car_number : (driver.name || "Водитель") }
  };
  const url = `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents/orders/${encodeURIComponent(order.firebase_order_id)}?updateMask.fieldPaths=status&updateMask.fieldPaths=assignedDriverUid&updateMask.fieldPaths=driver`;
  const r = await fetch(url, {
    method: "PATCH", headers: { "Content-Type": "application/json", "Authorization": "Bearer " + token },
    body: JSON.stringify({ fields })
  });
  if (!r.ok) {
    const detail = await r.text();
    return { ok: false, message: "D1 назначил водителя, но Firebase не обновился: " + detail.slice(0, 220) };
  }
  return { ok: true };
}

async function finalizeExpiredOrders(env) {
  const now = Math.floor(Date.now() / 1000);
  const expired = await env.DB.prepare("SELECT * FROM orders WHERE status='new' AND response_deadline IS NOT NULL AND response_deadline<=?")
    .bind(now).all();
  for (const order of (expired.results || [])) {
    const rows = await env.DB.prepare(`SELECT r.driver_uid, r.requested_at, d.name, d.car_number, d.latitude, d.longitude, d.location_updated_at
      FROM order_responses r JOIN drivers d ON d.uid=r.driver_uid
      WHERE r.order_id=? AND d.approved=1 AND d.online=1 AND d.location_updated_at>=? AND d.location_updated_at<=?
      AND NOT EXISTS (SELECT 1 FROM order_refusals x WHERE x.order_id=r.order_id AND x.driver_uid=r.driver_uid)
      AND NOT EXISTS (SELECT 1 FROM orders active WHERE active.assigned_driver_uid=r.driver_uid
        AND active.status IN ('driver_assigned','arrived'))`)
      .bind(order.id, now - 60, now).all();
    const pickupLat = num(order.pickup_lat), pickupLng = num(order.pickup_lng);
    const candidates = (rows.results || []).filter(d => hasFreshValidDriverLocation(d, now) &&
      pickupLat !== null && pickupLng !== null && pickupLat >= -90 && pickupLat <= 90 &&
      pickupLng >= -180 && pickupLng <= 180)
      .map(d => ({ ...d, distance: distanceKm(pickupLat, pickupLng, Number(d.latitude), Number(d.longitude)) }))
      .sort((a, b) => a.distance - b.distance || Number(a.requested_at) - Number(b.requested_at));
    if (!candidates.length) {
      await env.DB.prepare("DELETE FROM order_responses WHERE order_id=?").bind(order.id).run();
      await env.DB.prepare("UPDATE orders SET response_deadline=NULL WHERE id=? AND status='new'").bind(order.id).run();
      continue;
    }
    const winner = candidates[0];
    const assignmentNow = Math.floor(Date.now() / 1000);
    const assigned = await env.DB.prepare(`UPDATE orders SET status='driver_assigned',
      assigned_driver_uid=?, assigned_at=?, response_deadline=NULL
      WHERE id=? AND status='new' AND response_deadline<=?
        AND NOT EXISTS (SELECT 1 FROM orders active WHERE active.assigned_driver_uid=?
          AND active.status IN ('driver_assigned','arrived'))
        AND EXISTS (SELECT 1 FROM drivers current_driver WHERE current_driver.uid=?
          AND current_driver.approved=1 AND current_driver.online=1
          AND current_driver.latitude BETWEEN -90 AND 90
          AND current_driver.longitude BETWEEN -180 AND 180
          AND current_driver.location_updated_at BETWEEN ? AND ?)`)
      .bind(winner.driver_uid, assignmentNow, order.id, assignmentNow, winner.driver_uid,
        winner.driver_uid, assignmentNow - 60, assignmentNow).run();
    if (Number(assigned.meta?.changes || 0) === 1) {
      // Remove all competing responses only after this request wins the atomic assignment.
      await env.DB.prepare("DELETE FROM order_responses WHERE order_id=?").bind(order.id).run();
    }
  }
}

async function syncOrder(env, o) {
  if (!o || !o.id) throw new Error("В заявке отсутствует ID Firebase");
  const id = String(o.id);
  const status = String(o.status || "new");
  await env.DB.prepare(`INSERT INTO orders
    (id, firebase_order_id, customer_uid, pickup_address, pickup_lat, pickup_lng, destination_address, destination_lat, destination_lng, passenger_count, payment_method, tariff_type, comment, status, assigned_driver_uid)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(firebase_order_id) DO UPDATE SET
      customer_uid=excluded.customer_uid, pickup_address=excluded.pickup_address, pickup_lat=excluded.pickup_lat,
      pickup_lng=excluded.pickup_lng, destination_address=excluded.destination_address, destination_lat=excluded.destination_lat,
      destination_lng=excluded.destination_lng, passenger_count=excluded.passenger_count, payment_method=excluded.payment_method,
      tariff_type=excluded.tariff_type, comment=excluded.comment, status=excluded.status,
      assigned_driver_uid=excluded.assigned_driver_uid`)
    .bind(id, id, o.customerUid || null, o.pickup || "", num(o.pickupLat), num(o.pickupLng), o.destination || o.dest || "",
      num(o.destinationLat), num(o.destinationLng), Number(o.people || 1), o.payment || "", o.tariff || "", o.comment || "",
      status, o.assignedDriverUid || null).run();
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === "OPTIONS") return response({ ok: true });
    try {
      await env.DB.prepare(`CREATE TABLE IF NOT EXISTS order_refusals (
        order_id TEXT NOT NULL, driver_uid TEXT NOT NULL, refused_at INTEGER NOT NULL,
        PRIMARY KEY (order_id, driver_uid)
      )`).run();
      // Independent ledger: no ALTER TABLE is required on the existing orders schema.
      await env.DB.prepare(`CREATE TABLE IF NOT EXISTS trip_finances (
        order_id TEXT PRIMARY KEY NOT NULL,
        driver_uid TEXT NOT NULL,
        fare_som INTEGER NOT NULL CHECK (fare_som > 0),
        dispatcher_uid TEXT NOT NULL,
        completed_at INTEGER NOT NULL
      )`).run();
      await env.DB.prepare(`CREATE TABLE IF NOT EXISTS tariff_settings (
        id INTEGER PRIMARY KEY CHECK (id=1),
        city_fare_som INTEGER NOT NULL DEFAULT 0 CHECK (city_fare_som>=0),
        intercity_fare_som INTEGER NOT NULL DEFAULT 0 CHECK (intercity_fare_som>=0),
        updated_by TEXT,
        updated_at INTEGER NOT NULL DEFAULT (unixepoch())
      )`).run();
      // Driver commission and immutable daily shift snapshots; existing trip_finances stays untouched.
      await env.DB.prepare(`CREATE TABLE IF NOT EXISTS driver_commission_settings (
        driver_uid TEXT PRIMARY KEY NOT NULL,
        commission_percent INTEGER NOT NULL DEFAULT 50 CHECK (commission_percent BETWEEN 0 AND 100),
        updated_by TEXT,
        updated_at INTEGER NOT NULL DEFAULT (unixepoch()),
        FOREIGN KEY(driver_uid) REFERENCES drivers(uid)
      )`).run();
      await env.DB.prepare(`CREATE TABLE IF NOT EXISTS driver_shifts (
        id TEXT PRIMARY KEY NOT NULL,
        driver_uid TEXT NOT NULL,
        shift_date TEXT NOT NULL,
        trip_count INTEGER NOT NULL,
        gross_earnings_som INTEGER NOT NULL,
        driver_percent INTEGER NOT NULL CHECK (driver_percent BETWEEN 0 AND 100),
        driver_share_som INTEGER NOT NULL,
        park_share_som INTEGER NOT NULL,
        closed_at INTEGER NOT NULL,
        closed_by TEXT NOT NULL,
        UNIQUE(driver_uid, shift_date),
        FOREIGN KEY(driver_uid) REFERENCES drivers(uid)
      )`).run();
      await env.DB.prepare(`CREATE TABLE IF NOT EXISTS shift_finance_items (
        shift_id TEXT NOT NULL,
        order_id TEXT NOT NULL UNIQUE,
        driver_uid TEXT NOT NULL,
        fare_som INTEGER NOT NULL,
        completed_at INTEGER NOT NULL,
        PRIMARY KEY(shift_id, order_id),
        FOREIGN KEY(shift_id) REFERENCES driver_shifts(id),
        FOREIGN KEY(order_id) REFERENCES trip_finances(order_id)
      )`).run();
      // Existing drivers receive the legacy model's 50% default once; saved values are never overwritten.
      await env.DB.prepare(`INSERT OR IGNORE INTO driver_commission_settings (driver_uid, commission_percent)
        SELECT uid, 50 FROM drivers`).run();
      await env.DB.prepare(`CREATE TABLE IF NOT EXISTS radio_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        sender_uid TEXT NOT NULL,
        sender_name TEXT NOT NULL,
        sender_role TEXT NOT NULL CHECK(sender_role IN ('driver','dispatcher')),
        message TEXT NOT NULL CHECK(length(message) BETWEEN 1 AND 500),
        created_at INTEGER NOT NULL DEFAULT (unixepoch())
      )`).run();
      await env.DB.prepare(`CREATE TABLE IF NOT EXISTS radio_floor (
        id INTEGER PRIMARY KEY CHECK(id=1),
        holder_uid TEXT,
        holder_name TEXT,
        expires_at INTEGER NOT NULL DEFAULT 0
      )`).run();
      await env.DB.prepare("INSERT OR IGNORE INTO radio_floor (id,holder_uid,holder_name,expires_at) VALUES (1,NULL,NULL,0)").run();
      await env.DB.prepare(`CREATE TABLE IF NOT EXISTS driver_documents (
        driver_uid TEXT PRIMARY KEY NOT NULL,
        license_url TEXT NOT NULL,
        driver_photo_url TEXT NOT NULL,
        car_photo_url TEXT NOT NULL,
        submitted_at INTEGER NOT NULL DEFAULT (unixepoch()),
        FOREIGN KEY(driver_uid) REFERENCES drivers(uid)
      )`).run();
      // Additive, backward-compatible review metadata for existing Stage 12 databases.
      const docColumns = await env.DB.prepare("PRAGMA table_info(driver_documents)").all();
      const knownDocColumns = new Set((docColumns.results || []).map(c => c.name));
      for (const [name, definition] of [
        ["review_status", "TEXT NOT NULL DEFAULT 'pending'"],
        ["rejection_reason", "TEXT"],
        ["reviewed_at", "INTEGER"],
        ["reviewed_by", "TEXT"]
      ]) {
        if (!knownDocColumns.has(name)) {
          await env.DB.prepare(`ALTER TABLE driver_documents ADD COLUMN ${name} ${definition}`).run();
        }
      }
      await env.DB.prepare(`INSERT OR IGNORE INTO tariff_settings (id,city_fare_som,intercity_fare_som)
        VALUES (1,0,0)`).run();
      if (url.pathname === "/health" && request.method === "GET") {
        const tables = await env.DB.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").all();
        return response({ status: "ok", project: PROJECT_ID, database: "connected", tables: tables.results });
      }

      if (url.pathname === "/auth/check" && request.method === "POST") {
        const { user } = await verifyFirebaseUser(request);
        const driver = await driverRow(env, user.localId);
        return response({ status: "ok", authenticated: true, uid: user.localId,
          dispatcher: user.localId === DISPATCHER_UID,
          driver: !!driver, driverApproved: !!driver && Number(driver.approved) === 1 });
      }

      if (url.pathname === "/drivers/me" && request.method === "GET") {
        const auth = await verifyFirebaseUser(request);
        const driver = await driverRow(env, auth.user.localId);
        const docs = driver ? await env.DB.prepare("SELECT review_status,rejection_reason,submitted_at FROM driver_documents WHERE driver_uid=?").bind(auth.user.localId).first() : null;
        return response({ status: "ok", driver: driver ? {
          uid: driver.uid, name: driver.name, phone: driver.phone, car_model: driver.car_model,
          car_number: driver.car_number, approved: Number(driver.approved) === 1, online: Number(driver.online) === 1,
          review_status: docs?.review_status || "not_submitted", rejection_reason: docs?.rejection_reason || null
        } : null });
      }

      if (url.pathname === "/drivers/register" && request.method === "POST") {
        const auth = await verifyFirebaseUser(request);
        const b = await request.json();
        if (!b || typeof b !== "object" || Array.isArray(b) ||
            ![b.name, b.phone, b.car_model, b.car_number].every(value => typeof value === "string")) {
          return response({ status: "error", message: "Передайте ФИО, телефон, марку и номер автомобиля обычным текстом." }, 400);
        }
        // Reject oversized raw values before trimming or normalizing them.
        if (b.name.length > 240 || b.phone.length > 64 || b.car_model.length > 180 || b.car_number.length > 60) {
          return response({ status: "error", message: "Одно из полей анкеты слишком длинное. Проверьте введённые данные." }, 400);
        }
        const clean = value => String(value ?? "").trim().replace(/\s+/g, " ");
        const name = clean(b.name);
        const phoneInput = clean(b.phone);
        const carModel = clean(b.car_model);
        const carNumber = clean(b.car_number).toUpperCase();
        const phoneDigits = phoneInput.replace(/\D/g, "");
        let parenthesisDepth = 0;
        for (const character of phoneInput) {
          if (character === "(") {
            if (parenthesisDepth !== 0) {
              return response({ status: "error", message: "Проверьте скобки в номере телефона." }, 400);
            }
            parenthesisDepth = 1;
          } else if (character === ")") {
            if (parenthesisDepth !== 1) {
              return response({ status: "error", message: "Проверьте скобки в номере телефона." }, 400);
            }
            parenthesisDepth = 0;
          }
        }
        if (hasForbiddenControlCharacters(name) || name.length < 3 || name.length > 80) {
          return response({ status: "error", message: "Укажите ФИО водителя от 3 до 80 символов." }, 400);
        }
        if (hasForbiddenControlCharacters(phoneInput) || !/^\+?[0-9 ()-]+$/.test(phoneInput) ||
            parenthesisDepth !== 0 ||
            !( /^0[0-9]{9}$/.test(phoneDigits) || /^996[0-9]{9}$/.test(phoneDigits) )) {
          return response({ status: "error", message: "Укажите корректный номер Кыргызстана: 0XXXXXXXXX или +996XXXXXXXXX." }, 400);
        }
        // Store one canonical international form so formatting differences do not
        // create duplicate-looking profiles or trigger unnecessary re-approval.
        const phone = phoneDigits.startsWith("0")
          ? "+996" + phoneDigits.slice(1)
          : "+" + phoneDigits;
        if (hasForbiddenControlCharacters(carModel) || carModel.length < 2 || carModel.length > 60) {
          return response({ status: "error", message: "Укажите марку и модель автомобиля от 2 до 60 символов." }, 400);
        }
        if (hasForbiddenControlCharacters(carNumber) || carNumber.length < 2 || carNumber.length > 20) {
          return response({ status: "error", message: "Укажите государственный номер автомобиля от 2 до 20 символов." }, 400);
        }
        const profile = { name, phone, carModel, carNumber };
        // In one D1 batch, invalidate the old document review first and then
        // update the profile using the same old-value comparison. This keeps
        // approval, online state and document review consistent on retries.
        const changedWhere = "(name<>? OR phone<>? OR car_model<>? OR car_number<>?)";
        const profileResults = await env.DB.batch([
          env.DB.prepare(`UPDATE driver_documents SET review_status='rejected',
            rejection_reason='Данные анкеты изменены. Повторно отправьте водительское удостоверение, фото водителя и фото автомобиля.',
            reviewed_at=NULL, reviewed_by=NULL
            WHERE driver_uid=? AND EXISTS (
              SELECT 1 FROM drivers WHERE uid=? AND ${changedWhere}
            )`).bind(auth.user.localId, auth.user.localId, name, phone, carModel, carNumber),
          env.DB.prepare(`INSERT INTO drivers (uid,name,phone,car_model,car_number,approved,online)
            VALUES (?,?,?,?,?,0,0) ON CONFLICT(uid) DO UPDATE SET
            name=excluded.name, phone=excluded.phone, car_model=excluded.car_model, car_number=excluded.car_number,
            approved=CASE WHEN drivers.name<>excluded.name OR drivers.phone<>excluded.phone OR
              drivers.car_model<>excluded.car_model OR drivers.car_number<>excluded.car_number
              THEN 0 ELSE drivers.approved END,
            online=CASE WHEN drivers.name<>excluded.name OR drivers.phone<>excluded.phone OR
              drivers.car_model<>excluded.car_model OR drivers.car_number<>excluded.car_number
              THEN 0 ELSE drivers.online END`)
            .bind(auth.user.localId, name, phone, carModel, carNumber)
        ]);
        if (Number(profileResults?.[1]?.meta?.changes || 0) !== 1) {
          return response({ status: "error", message: "Не удалось сохранить анкету водителя. Повторите попытку." }, 409);
        }
        const savedProfile = await env.DB.prepare("SELECT approved FROM drivers WHERE uid=?")
          .bind(auth.user.localId).first();
        const documents = await env.DB.prepare("SELECT review_status,rejection_reason FROM driver_documents WHERE driver_uid=?")
          .bind(auth.user.localId).first();
        const profileChanged = Number(profileResults?.[0]?.meta?.changes || 0) > 0;
        const reviewRequired = documents?.review_status === "rejected";
        return response({
          status: "ok",
          approved: Number(savedProfile?.approved) === 1,
          review_required: reviewRequired,
          message: profileChanged
            ? "Данные анкеты изменены. Водитель временно снят с линии до повторной проверки диспетчером."
            : reviewRequired
              ? (documents.rejection_reason || "Документы отклонены. Исправьте замечания и отправьте документы повторно.")
              : "Анкета сохранена. Ожидайте одобрения диспетчера."
        });
      }

      if (url.pathname === "/drivers/documents" && request.method === "POST") {
        const auth = await verifyFirebaseUser(request);
        const driver = await driverRow(env, auth.user.localId);
        if (!driver) return response({ status: "error", message: "Сначала отправьте анкету водителя" }, 409);
        const b = await request.json();
        const paths = [b.license_url, b.driver_photo_url, b.car_photo_url].map(v => String(v || ""));
        const expectedPaths = [
          `drivers/${auth.user.localId}/license.jpg`,
          `drivers/${auth.user.localId}/driver_photo.jpg`,
          `drivers/${auth.user.localId}/car_photo.jpg`
        ];
        const valid = paths.every((value, index) => value === expectedPaths[index]);
        if (!valid) return response({ status: "error", message: "Укажите три документа в правильном порядке из личной папки Firebase Storage" }, 400);
        // Save the new submission and revoke line access in the same D1 batch.
        const documentResults = await env.DB.batch([
          env.DB.prepare(`INSERT INTO driver_documents (driver_uid,license_url,driver_photo_url,car_photo_url,submitted_at,review_status,rejection_reason,reviewed_at,reviewed_by)
            VALUES (?,?,?,?,unixepoch(),'pending',NULL,NULL,NULL) ON CONFLICT(driver_uid) DO UPDATE SET
            license_url=excluded.license_url, driver_photo_url=excluded.driver_photo_url,
            car_photo_url=excluded.car_photo_url, submitted_at=unixepoch(), review_status='pending',
            rejection_reason=NULL, reviewed_at=NULL, reviewed_by=NULL`)
            .bind(auth.user.localId, ...paths),
          env.DB.prepare("UPDATE drivers SET approved=0, online=0, updated_at=unixepoch() WHERE uid=?")
            .bind(auth.user.localId)
        ]);
        if (Number(documentResults?.[0]?.meta?.changes || 0) !== 1 ||
            Number(documentResults?.[1]?.meta?.changes || 0) !== 1) {
          return response({ status: "error", message: "Не удалось безопасно сохранить документы и снять водителя с линии. Повторите отправку." }, 409);
        }
        return response({ status: "ok", documents_saved: true, review_status: "pending" });
      }

      if (url.pathname === "/drivers/review" && request.method === "POST") {
        const auth = await requireDispatcher(request);
        const b = await request.json();
        const uid = String(b.uid || "");
        const decision = String(b.decision || "");
        const reason = String(b.reason || "").trim().slice(0, 500);
        if (!uid || !["approved", "rejected"].includes(decision))
          return response({ status: "error", message: "Укажите водителя и решение" }, 400);
        if (decision === "rejected" && reason.length < 5)
          return response({ status: "error", message: "Напишите причину отказа (не менее 5 символов)" }, 400);
        const docs = await env.DB.prepare("SELECT license_url,driver_photo_url,car_photo_url,review_status FROM driver_documents WHERE driver_uid=?").bind(uid).first();
        if (!docs || !docs.license_url || !docs.driver_photo_url || !docs.car_photo_url)
          return response({ status: "error", message: "У водителя ещё нет всех трёх документов" }, 409);
        if (docs.review_status !== "pending")
          return response({ status: "error", message: "Водитель должен повторно отправить документы. Одобрение до новой отправки запрещено." }, 409);
        const exists = await env.DB.prepare("SELECT uid FROM drivers WHERE uid=?").bind(uid).first();
        if (!exists) return response({ status: "error", message: "Водитель не найден" }, 404);
        // Apply the document decision and driver access change in one D1 batch.
        // The second statement is tied to the exact review result, preventing a
        // concurrent reviewer from changing access based on a stale decision.
        const reviewResults = await env.DB.batch([
          env.DB.prepare(`UPDATE driver_documents SET review_status=?, rejection_reason=?, reviewed_at=unixepoch(), reviewed_by=?
            WHERE driver_uid=? AND review_status='pending'`)
            .bind(decision, decision === "rejected" ? reason : null, auth.user.localId, uid),
          env.DB.prepare(`UPDATE drivers SET approved=?, online=0, updated_at=unixepoch()
            WHERE uid=? AND EXISTS (
              SELECT 1 FROM driver_documents WHERE driver_uid=? AND review_status=? AND reviewed_by=?
            )`)
            .bind(decision === "approved" ? 1 : 0, uid, uid, decision, auth.user.localId)
        ]);
        if (Number(reviewResults?.[0]?.meta?.changes || 0) !== 1 ||
            Number(reviewResults?.[1]?.meta?.changes || 0) !== 1) {
          return response({ status: "error", message: "Заявка уже обработана или данные водителя изменились. Обновите список заявок." }, 409);
        }
        return response({ status: "ok", review_status: decision });
      }

      if (url.pathname === "/drivers/approve" && request.method === "POST") {
        const auth = await requireDispatcher(request);
        const b = await request.json();
        const uid = String(b.uid || "");
        if (!uid) return response({ status: "error", message: "Не указан UID водителя" }, 400);
        if (b.approved) {
          const docs = await env.DB.prepare("SELECT review_status FROM driver_documents WHERE driver_uid=?").bind(uid).first();
          if (!docs || docs.review_status !== "approved")
            return response({ status: "error", message: "Сначала проверьте документы через /drivers/review" }, 409);
        }
        await env.DB.prepare("UPDATE drivers SET approved=?, online=0, updated_at=unixepoch() WHERE uid=?")
          .bind(b.approved ? 1 : 0, uid).run();
        return response({ status: "ok" });
      }

      if (url.pathname === "/tariffs" && request.method === "GET") {
        await verifyFirebaseUser(request);
        const tariffs = await env.DB.prepare("SELECT city_fare_som, intercity_fare_som, updated_at FROM tariff_settings WHERE id=1").first();
        return response({ status: "ok", tariffs: tariffs || { city_fare_som: 0, intercity_fare_som: 0 } });
      }

      if (url.pathname === "/tariffs" && request.method === "POST") {
        const auth = await requireDispatcher(request);
        const b = await request.json();
        const city = Number(b.city_fare_som), intercity = Number(b.intercity_fare_som);
        if (!Number.isSafeInteger(city) || !Number.isSafeInteger(intercity) || city < 0 || intercity < 0 || city > 1000000 || intercity > 1000000) {
          return response({ status: "error", message: "Укажите целые суммы от 0 до 1 000 000 сом" }, 400);
        }
        await env.DB.prepare(`INSERT INTO tariff_settings (id,city_fare_som,intercity_fare_som,updated_by,updated_at)
          VALUES (1,?,?,?,unixepoch())
          ON CONFLICT(id) DO UPDATE SET city_fare_som=excluded.city_fare_som,
          intercity_fare_som=excluded.intercity_fare_som, updated_by=excluded.updated_by, updated_at=unixepoch()`)
          .bind(city, intercity, auth.user.localId).run();
        return response({ status: "ok", tariffs: { city_fare_som: city, intercity_fare_som: intercity } });
      }

      if (url.pathname === "/drivers/commission" && request.method === "POST") {
        const auth = await requireDispatcher(request);
        const b = await request.json();
        const driverUid = String(b.driver_uid || "");
        const percent = Number(b.commission_percent);
        if (!driverUid || !Number.isSafeInteger(percent) || percent < 0 || percent > 100) {
          return response({ status: "error", message: "Укажите водителя и процент от 0 до 100" }, 400);
        }
        const driver = await env.DB.prepare("SELECT uid FROM drivers WHERE uid=?").bind(driverUid).first();
        if (!driver) return response({ status: "error", message: "Водитель не найден" }, 404);
        await env.DB.prepare(`INSERT INTO driver_commission_settings (driver_uid,commission_percent,updated_by,updated_at)
          VALUES (?,?,?,unixepoch())
          ON CONFLICT(driver_uid) DO UPDATE SET commission_percent=excluded.commission_percent,
          updated_by=excluded.updated_by, updated_at=unixepoch()`)
          .bind(driverUid, percent, auth.user.localId).run();
        return response({ status: "ok", driver_uid: driverUid, commission_percent: percent });
      }

      if (url.pathname === "/dispatcher/shifts/close" && request.method === "POST") {
        const auth = await requireDispatcher(request);
        const b = await request.json();
        const driverUid = String(b.driver_uid || "");
        const shiftDate = String(b.shift_date || kgTodayDate());
        if (!driverUid) return response({ status: "error", message: "Не указан водитель" }, 400);
        const { start, end } = kgDateBounds(shiftDate);
        if (shiftDate > kgTodayDate()) return response({ status: "error", message: "Нельзя закрыть смену за будущую дату" }, 400);
        const driver = await env.DB.prepare("SELECT uid,name FROM drivers WHERE uid=?").bind(driverUid).first();
        if (!driver) return response({ status: "error", message: "Водитель не найден" }, 404);
        const shiftId = crypto.randomUUID();
        // D1 batch is transactional. A fresh random ID means a repeated close cannot copy items
        // into an already closed shift, while UNIQUE(driver_uid, shift_date) prevents duplicates.
        const results = await env.DB.batch([
          env.DB.prepare(`INSERT INTO driver_shifts
            (id,driver_uid,shift_date,trip_count,gross_earnings_som,driver_percent,driver_share_som,park_share_som,closed_at,closed_by)
            SELECT ?, f.driver_uid, ?, COUNT(*), SUM(f.fare_som),
              COALESCE(MAX(c.commission_percent),50),
              CAST(ROUND(SUM(f.fare_som)*COALESCE(MAX(c.commission_percent),50)/100.0) AS INTEGER),
              SUM(f.fare_som)-CAST(ROUND(SUM(f.fare_som)*COALESCE(MAX(c.commission_percent),50)/100.0) AS INTEGER),
              unixepoch(), ?
            FROM trip_finances f
            LEFT JOIN driver_commission_settings c ON c.driver_uid=f.driver_uid
            WHERE f.driver_uid=? AND f.completed_at>=? AND f.completed_at<?
              AND NOT EXISTS (SELECT 1 FROM shift_finance_items si WHERE si.order_id=f.order_id)
            GROUP BY f.driver_uid
            ON CONFLICT(driver_uid,shift_date) DO NOTHING`)
            .bind(shiftId, shiftDate, auth.user.localId, driverUid, start, end),
          env.DB.prepare(`INSERT INTO shift_finance_items (shift_id,order_id,driver_uid,fare_som,completed_at)
            SELECT ?, f.order_id, f.driver_uid, f.fare_som, f.completed_at
            FROM trip_finances f
            WHERE f.driver_uid=? AND f.completed_at>=? AND f.completed_at<?
              AND EXISTS (SELECT 1 FROM driver_shifts ds WHERE ds.id=?)
              AND NOT EXISTS (SELECT 1 FROM shift_finance_items si WHERE si.order_id=f.order_id)`)
            .bind(shiftId, driverUid, start, end, shiftId)
        ]);
        const inserted = Number(results?.[0]?.meta?.changes || 0);
        if (inserted !== 1) {
          const existing = await env.DB.prepare("SELECT id FROM driver_shifts WHERE driver_uid=? AND shift_date=?")
            .bind(driverUid, shiftDate).first();
          return response({ status: "error", message: existing
            ? "Смена этого водителя за выбранную дату уже закрыта"
            : "Нет незакрытых завершённых поездок за выбранную дату" }, 409);
        }
        const shift = await env.DB.prepare(`SELECT ds.*, d.name AS driver_name
          FROM driver_shifts ds JOIN drivers d ON d.uid=ds.driver_uid WHERE ds.id=?`).bind(shiftId).first();
        return response({ status: "ok", closed: true, shift });
      }

      // Secure dispatcher dashboard: only the fixed dispatcher Firebase UID can read fleet data.
      if (url.pathname === "/dispatcher/overview" && request.method === "GET") {
        await requireDispatcher(request);
        const drivers = await env.DB.prepare(`SELECT d.uid, d.name, d.phone, d.car_model, d.car_number, d.approved, d.online,
          d.latitude, d.longitude, d.location_updated_at,
          docs.license_url, docs.driver_photo_url, docs.car_photo_url, docs.submitted_at AS documents_submitted_at,
          docs.review_status, docs.rejection_reason, docs.reviewed_at
          FROM drivers d LEFT JOIN driver_documents docs ON docs.driver_uid=d.uid
          ORDER BY d.approved ASC, d.name ASC`).all();
        const orders = await env.DB.prepare(`SELECT o.id, o.firebase_order_id, o.pickup_address, o.pickup_lat, o.pickup_lng,
          o.destination_address, o.destination_lat, o.destination_lng, o.passenger_count, o.payment_method,
          o.tariff_type, o.comment, o.status, o.created_at, o.assigned_at, o.assigned_driver_uid,
          d.name AS driver_name, d.car_number AS driver_car_number
          FROM orders o LEFT JOIN drivers d ON d.uid=o.assigned_driver_uid
          ORDER BY o.created_at DESC LIMIT 100`).all();
        const todayDate = kgTodayDate();
        const todayBounds = kgDateBounds(todayDate);
        const today = await env.DB.prepare(`SELECT status, COUNT(*) AS count FROM orders
          WHERE created_at>=? AND created_at<? GROUP BY status`).bind(todayBounds.start, todayBounds.end).all();
        const earnings = await env.DB.prepare(`SELECT d.uid AS driver_uid, d.name AS driver_name,
          d.car_number AS car_number, COALESCE(c.commission_percent,50) AS commission_percent,
          COUNT(f.order_id) AS completed_trips, COALESCE(SUM(f.fare_som),0) AS earned_som,
          CAST(ROUND(COALESCE(SUM(f.fare_som),0)*COALESCE(c.commission_percent,50)/100.0) AS INTEGER) AS driver_share_som,
          COALESCE(SUM(f.fare_som),0)-CAST(ROUND(COALESCE(SUM(f.fare_som),0)*COALESCE(c.commission_percent,50)/100.0) AS INTEGER) AS park_share_som
          FROM drivers d
          LEFT JOIN driver_commission_settings c ON c.driver_uid=d.uid
          LEFT JOIN trip_finances f ON f.driver_uid=d.uid AND f.completed_at>=? AND f.completed_at<?
            AND NOT EXISTS (SELECT 1 FROM shift_finance_items si WHERE si.order_id=f.order_id)
          GROUP BY d.uid ORDER BY earned_som DESC, d.name ASC`)
          .bind(todayBounds.start, todayBounds.end).all();
        const closedShifts = await env.DB.prepare(`SELECT ds.*, d.name AS driver_name, d.car_number
          FROM driver_shifts ds JOIN drivers d ON d.uid=ds.driver_uid
          ORDER BY ds.shift_date DESC, ds.closed_at DESC LIMIT 50`).all();
        // Normalize SQLite integer flags before JSON serialization so Flutter
        // receives stable booleans for approval and online state.
        const driverRows = (drivers.results || []).map(d => ({
          ...d,
          approved: Number(d.approved) === 1,
          online: Number(d.online) === 1
        }));
        return response({ status: "ok", drivers: driverRows, orders: orders.results || [],
          today: today.results || [], earnings: earnings.results || [],
          closed_shifts: closedShifts.results || [], business_date: todayDate });
      }

      if (url.pathname === "/orders/assign" && request.method === "POST") {
        await requireDispatcher(request);
        const b = await request.json();
        const orderId = String(b.order_id || "");
        const driverUid = String(b.driver_uid || "");
        if (!orderId || !driverUid) return response({ status: "error", message: "Укажите заказ и водителя" }, 400);
        const driver = await env.DB.prepare("SELECT uid, approved, online, latitude, longitude, location_updated_at FROM drivers WHERE uid=?").bind(driverUid).first();
        if (!driver || Number(driver.approved) !== 1) return response({ status: "error", message: "Водитель не найден или не одобрен" }, 409);
        const assignmentNow = Math.floor(Date.now() / 1000);
        if (Number(driver.online) !== 1 || !hasFreshValidDriverLocation(driver, assignmentNow)) {
          return response({ status: "error", message: "Назначить можно только водителя на линии с актуальной геолокацией. Попросите водителя выйти на линию и обновить GPS." }, 409);
        }
        const refused = await env.DB.prepare("SELECT 1 AS found FROM order_refusals WHERE order_id=? AND driver_uid=?")
          .bind(orderId, driverUid).first();
        if (refused) return response({ status: "error", message: "Этот водитель ранее отказался от данного заказа" }, 409);
        const result = await env.DB.prepare(`UPDATE orders SET status='driver_assigned', assigned_driver_uid=?,
          assigned_at=unixepoch(), response_deadline=NULL WHERE id=? AND status='new'
          AND NOT EXISTS (SELECT 1 FROM orders active WHERE active.assigned_driver_uid=?
            AND active.status IN ('driver_assigned','arrived'))
          AND EXISTS (SELECT 1 FROM drivers current_driver WHERE current_driver.uid=?
            AND current_driver.approved=1 AND current_driver.online=1
            AND current_driver.latitude BETWEEN -90 AND 90
            AND current_driver.longitude BETWEEN -180 AND 180
            AND current_driver.location_updated_at BETWEEN ? AND ?)`)
          .bind(driverUid, orderId, driverUid, driverUid, assignmentNow - 60, assignmentNow).run();
        if (!result.meta || Number(result.meta.changes || 0) !== 1) {
          return response({ status: "error", message: "Заказ уже назначен, принят или больше недоступен" }, 409);
        }
        await env.DB.prepare("DELETE FROM order_responses WHERE order_id=?").bind(orderId).run();
        return response({ status: "ok", assigned: true, order_id: orderId, driver_uid: driverUid });
      }

      if (url.pathname === "/drivers/online" && request.method === "POST") {
        const auth = await requireApprovedDriver(request, env);
        const b = await request.json();
        if (typeof b.online !== "boolean") {
          return response({ status: "error", message: "Укажите, выходит ли водитель на линию" }, 400);
        }
        const hasLatitude = b.latitude !== undefined && b.latitude !== null;
        const hasLongitude = b.longitude !== undefined && b.longitude !== null;
        if (hasLatitude !== hasLongitude || (b.online && (!hasLatitude || !hasLongitude))) {
          return response({ status: "error", message: "Для выхода на линию необходимы обе координаты GPS" }, 400);
        }
        if ((hasLatitude && (typeof b.latitude !== "number" || !Number.isFinite(b.latitude) || b.latitude < -90 || b.latitude > 90)) ||
            (hasLongitude && (typeof b.longitude !== "number" || !Number.isFinite(b.longitude) || b.longitude < -180 || b.longitude > 180))) {
          return response({ status: "error", message: "Получены неверные координаты GPS" }, 400);
        }
        const online = b.online ? 1 : 0;
        const lat = hasLatitude ? b.latitude : null;
        const lng = hasLongitude ? b.longitude : null;
        // Keep the line state transition atomic with trip eligibility: an
        // offline update must not race an assignment or strand an active trip.
        const result = await env.DB.prepare(`UPDATE drivers SET online=?, latitude=COALESCE(?,latitude), longitude=COALESCE(?,longitude),
          location_updated_at=CASE WHEN ? IS NOT NULL AND ? IS NOT NULL THEN unixepoch() ELSE location_updated_at END,
          updated_at=unixepoch()
          WHERE uid=? AND approved=1
            AND (?=1 OR NOT EXISTS (
              SELECT 1 FROM orders active WHERE active.assigned_driver_uid=?
                AND active.status IN ('driver_assigned','arrived')
            ))`)
          .bind(online, lat, lng, lat, lng, auth.user.localId, online, auth.user.localId).run();
        if (!result.meta || Number(result.meta.changes || 0) !== 1) {
          return response({
            status: "error",
            message: "Статус не изменён: проверьте одобрение диспетчера и отсутствие активного заказа"
          }, 409);
        }
        return response({ status: "ok", online: !!online });
      }

      if (url.pathname === "/orders/publish" && request.method === "POST") {
        const auth = await verifyFirebaseUser(request);
        const b = await request.json();
        const orderId = String(b.id || "").trim();
        if (!/^[A-Za-z0-9_-]{1,128}$/.test(orderId)) {
          return response({ status: "error", message: "Укажите корректный номер заявки" }, 400);
        }
        if (b.customerUid && b.customerUid !== auth.user.localId) {
          return response({ status: "error", message: "UID клиента не совпадает" }, 403);
        }
        const pickup = typeof b.pickup === "string" ? b.pickup.trim() : "";
        const destination = typeof b.destination === "string" ? b.destination.trim() :
          (typeof b.dest === "string" ? b.dest.trim() : "");
        const pickupLat = b.pickupLat;
        const pickupLng = b.pickupLng;
        const people = b.people;
        const payment = b.payment;
        const tariff = b.tariff;
        const comment = b.comment === undefined || b.comment === null ? "" : b.comment;
        if (!pickup || pickup.length > 200 || /[\\u0000-\\u001f\\u007f]/.test(pickup)) {
          return response({ status: "error", message: "Укажите корректное место подачи автомобиля" }, 400);
        }
        if (!destination || destination.length > 200 || /[\\u0000-\\u001f\\u007f]/.test(destination)) {
          return response({ status: "error", message: "Укажите корректный пункт назначения" }, 400);
        }
        if (typeof pickupLat !== "number" || !Number.isFinite(pickupLat) || pickupLat < -90 || pickupLat > 90 ||
            typeof pickupLng !== "number" || !Number.isFinite(pickupLng) || pickupLng < -180 || pickupLng > 180) {
          return response({ status: "error", message: "Проверьте координаты места подачи автомобиля" }, 400);
        }
        if (!Number.isInteger(people) || people < 1 || people > 4) {
          return response({ status: "error", message: "Количество пассажиров должно быть от 1 до 4" }, 400);
        }
        if (!["Наличные", "QR-код", "По договору"].includes(payment)) {
          return response({ status: "error", message: "Выберите допустимый способ оплаты" }, 400);
        }
        if (!["По городу", "Межгород"].includes(tariff)) {
          return response({ status: "error", message: "Выберите допустимый тариф" }, 400);
        }
        if (typeof comment !== "string" || comment.length > 500 || hasForbiddenControlCharacters(comment)) {
          return response({ status: "error", message: "Комментарий не должен превышать 500 символов" }, 400);
        }
        // Publishing is idempotent: a retry must never reset an assigned or completed order.
        await env.DB.prepare(`INSERT INTO orders
          (id, firebase_order_id, customer_uid, pickup_address, pickup_lat, pickup_lng, destination_address, destination_lat, destination_lng, passenger_count, payment_method, tariff_type, comment, status, assigned_driver_uid)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'new', NULL)
          ON CONFLICT DO NOTHING`)
          .bind(orderId, orderId, auth.user.localId, pickup, pickupLat, pickupLng,
            destination, num(b.destinationLat), num(b.destinationLng),
            people, payment, tariff, comment).run();
        const existing = await env.DB.prepare(
          "SELECT customer_uid FROM orders WHERE firebase_order_id=?"
        ).bind(orderId).first();
        if (!existing) {
          return response({ status: "error", message: "Не удалось сохранить заявку с таким номером" }, 409);
        }
        if (existing.customer_uid !== auth.user.localId) {
          return response({ status: "error", message: "Заявка с таким номером уже принадлежит другому клиенту" }, 403);
        }
        return response({ status: "ok", published: true, already_published: true });
      }

      if (url.pathname === "/orders/sync" && request.method === "POST") {
        await requireDispatcher(request);
        const b = await request.json();
        const items = Array.isArray(b.orders) ? b.orders : [b.order];
        for (const item of items) if (item) await syncOrder(env, item);
        return response({ status: "ok", synced: items.filter(Boolean).length });
      }

      if (url.pathname === "/drivers/nearby" && request.method === "GET") {
        await verifyFirebaseUser(request);
        const now = Math.floor(Date.now() / 1000);
        const rows = await env.DB.prepare(`SELECT latitude, longitude, location_updated_at
          FROM drivers d WHERE approved=1 AND online=1
            AND location_updated_at>=? AND location_updated_at<=?
            AND NOT EXISTS (SELECT 1 FROM orders active
              WHERE active.assigned_driver_uid=d.uid
                AND active.status IN ('driver_assigned','arrived'))
          ORDER BY location_updated_at DESC LIMIT 50`).bind(now - 60, now).all();
        const drivers = (rows.results || []).filter(d => hasFreshValidDriverLocation(d, now));
        return response({ status: "ok", drivers });
      }

      if (url.pathname === "/orders/open" && request.method === "GET") {
        const auth = await requireApprovedDriver(request, env, true);
        await finalizeExpiredOrders(env);
        // Если этот водитель выиграл отбор, он сам обновляет соответствующую заявку в Firebase своим токеном.
        const assignedToSync = await env.DB.prepare("SELECT * FROM orders WHERE status='driver_assigned' AND assigned_driver_uid=? AND firebase_synced_at IS NULL")
          .bind(auth.user.localId).all();
        const syncResults = [];
        for (const o of (assignedToSync.results || [])) {
          const patch = await patchFirestoreAssignment(o, auth.driver, auth.token);
          if (patch.ok) await env.DB.prepare("UPDATE orders SET firebase_synced_at=unixepoch() WHERE id=?").bind(o.id).run();
          syncResults.push({ id: o.firebase_order_id, ...patch });
        }
        const openNow = Math.floor(Date.now() / 1000);
        const open = await env.DB.prepare(`SELECT id, firebase_order_id, pickup_address, pickup_lat, pickup_lng,
          destination_address, destination_lat, destination_lng, passenger_count, payment_method, tariff_type, comment,
          created_at, response_deadline FROM orders o WHERE status='new'
          AND EXISTS (SELECT 1 FROM drivers available_driver WHERE available_driver.uid=?
            AND available_driver.approved=1 AND available_driver.online=1
            AND available_driver.latitude BETWEEN -90 AND 90
            AND available_driver.longitude BETWEEN -180 AND 180
            AND available_driver.location_updated_at BETWEEN ? AND ?)
          AND NOT EXISTS (SELECT 1 FROM orders active WHERE active.assigned_driver_uid=?
            AND active.status IN ('driver_assigned','arrived'))
          AND NOT EXISTS (SELECT 1 FROM order_refusals x WHERE x.order_id=o.id AND x.driver_uid=?)
          ORDER BY created_at ASC LIMIT 100`).bind(
            auth.user.localId, openNow - 60, openNow,
            auth.user.localId, auth.user.localId
          ).all();
        const assignedOrders = await env.DB.prepare(`SELECT id, firebase_order_id, pickup_address, pickup_lat, pickup_lng,
          destination_address, destination_lat, destination_lng, passenger_count, payment_method, tariff_type, comment,
          assigned_at, status FROM orders WHERE status IN ('driver_assigned','arrived') AND assigned_driver_uid=? ORDER BY assigned_at DESC LIMIT 5`)
          .bind(auth.user.localId).all();
        return response({ status: "ok", orders: open.results || [], assignedOrders: assignedOrders.results || [], firebaseSync: syncResults });
      }

      if (url.pathname === "/orders/status" && request.method === "GET") {
        const auth = await verifyFirebaseUser(request);
        const id = url.searchParams.get("id") || "";
        if (!id) return response({ status: "error", message: "Не указан ID заказа" }, 400);
        const order = await env.DB.prepare(`SELECT o.id, o.firebase_order_id, o.status, o.pickup_address,
          o.pickup_lat, o.pickup_lng, o.destination_address, o.destination_lat, o.destination_lng,
          o.passenger_count, o.payment_method, o.tariff_type, o.assigned_driver_uid,
          d.name AS driver_name, d.phone AS driver_phone, d.car_model, d.car_number,
          d.latitude AS driver_latitude, d.longitude AS driver_longitude, d.online AS driver_online,
          d.location_updated_at AS driver_location_updated_at
          FROM orders o LEFT JOIN drivers d ON d.uid=o.assigned_driver_uid
          WHERE o.firebase_order_id=? AND o.customer_uid=? LIMIT 1`)
          .bind(id, auth.user.localId).first();
        if (!order) return response({ status: "error", message: "Заказ не найден" }, 404);
        const driver = order.assigned_driver_uid ? {
          uid: order.assigned_driver_uid, name: order.driver_name, phone: order.driver_phone,
          car_model: order.car_model, car_number: order.car_number,
          latitude: order.driver_latitude, longitude: order.driver_longitude,
          online: Number(order.driver_online) === 1,
          location_updated_at: order.driver_location_updated_at
        } : null;
        return response({ apiStatus: "ok", status: order.status, order, driver });
      }

      if (url.pathname === "/orders/complete" && request.method === "POST") {
        const auth = await requireDispatcher(request);
        const b = await request.json();
        const orderId = String(b.order_id || "");
        const fareSom = Number(b.fare_som);
        if (!orderId || !Number.isSafeInteger(fareSom) || fareSom < 1 || fareSom > 1000000) {
          return response({ status: "error", message: "Укажите заказ и корректную сумму от 1 до 1 000 000 сом" }, 400);
        }
        // D1 batch is transactional. A unique order_id prevents double accounting.
        const results = await env.DB.batch([
          env.DB.prepare(`INSERT INTO trip_finances (order_id,driver_uid,fare_som,dispatcher_uid,completed_at)
            SELECT id, assigned_driver_uid, ?, ?, unixepoch() FROM orders
            WHERE id=? AND status='arrived' AND assigned_driver_uid IS NOT NULL
            ON CONFLICT(order_id) DO NOTHING`).bind(fareSom, auth.user.localId, orderId),
          env.DB.prepare(`UPDATE orders SET status='completed'
            WHERE id=? AND status='arrived' AND EXISTS (
              SELECT 1 FROM trip_finances f WHERE f.order_id=orders.id AND f.dispatcher_uid=?
            )`).bind(orderId, auth.user.localId)
        ]);
        const inserted = Number(results?.[0]?.meta?.changes || 0);
        const updated = Number(results?.[1]?.meta?.changes || 0);
        if (inserted !== 1 || updated !== 1) {
          return response({ status: "error", message: "Поездка не закрыта: проверьте, что водитель отметил прибытие и заказ ещё не завершён" }, 409);
        }
        return response({ status: "ok", completed: true, order_id: orderId, fare_som: fareSom });
      }

      if (url.pathname === "/orders/arrived" && request.method === "POST") {
        const auth = await requireApprovedDriver(request, env);
        const b = await request.json();
        const orderId = String(b.order_id || "");
        if (!orderId) return response({ status: "error", message: "Не указан заказ" }, 400);
        const result = await env.DB.prepare(`UPDATE orders SET status='arrived'
          WHERE id=? AND assigned_driver_uid=? AND status='driver_assigned'`)
          .bind(orderId, auth.user.localId).run();
        if (!result.meta || Number(result.meta.changes || 0) !== 1) {
          return response({ status: "error", message: "Нельзя отметить прибытие: заказ уже изменил статус или назначен другому водителю" }, 409);
        }
        return response({ status: "ok", arrived: true, statusNow: "arrived" });
      }

      if (url.pathname === "/orders/cancel" && request.method === "POST") {
        const b = await request.json();
        const orderId = String(b.order_id || "");
        const role = String(b.role || "");
        if (!orderId || !["customer", "driver"].includes(role)) {
          return response({ status: "error", message: "Не указан заказ или сторона отказа" }, 400);
        }
        // Re-check dispatcher approval for driver-side cancellation; offline drivers may still refuse an assigned trip.
        const auth = role === "driver"
          ? await requireApprovedDriver(request, env)
          : await verifyFirebaseUser(request);
        const order = await env.DB.prepare("SELECT * FROM orders WHERE id=?").bind(orderId).first();
        if (!order) return response({ status: "error", message: "Заказ не найден" }, 404);
        if (role === "customer") {
          if (order.customer_uid !== auth.user.localId) return response({ status: "error", message: "Можно отменить только свой заказ" }, 403);
          const result = await env.DB.prepare(`UPDATE orders SET status='cancelled_by_customer', response_deadline=NULL
            WHERE id=? AND customer_uid=? AND status IN ('new','driver_assigned')`)
            .bind(orderId, auth.user.localId).run();
          if (!result.meta || Number(result.meta.changes || 0) !== 1) {
            return response({ status: "error", message: "Отмена уже невозможна: заказ изменил статус или водитель уже прибыл" }, 409);
          }
          await env.DB.prepare("DELETE FROM order_responses WHERE order_id=?").bind(orderId).run();
          return response({ status: "ok", cancelled: true, statusNow: "cancelled_by_customer" });
        }
        // A driver may refuse only the order assigned to this driver, before arrival.
        if (order.assigned_driver_uid !== auth.user.localId) return response({ status: "error", message: "Этот заказ назначен не вам" }, 403);
        if (Number(order.status === "driver_assigned") !== 1) {
          return response({ status: "error", message: "Отказ доступен только до прибытия водителя" }, 409);
        }
        const result = await env.DB.prepare(`UPDATE orders SET status='new', assigned_driver_uid=NULL,
          assigned_at=NULL, response_deadline=NULL WHERE id=? AND assigned_driver_uid=? AND status='driver_assigned'`)
          .bind(orderId, auth.user.localId).run();
        if (!result.meta || Number(result.meta.changes || 0) !== 1) {
          return response({ status: "error", message: "Заказ уже изменил статус; отказ не выполнен" }, 409);
        }
        await env.DB.prepare("INSERT OR IGNORE INTO order_refusals (order_id,driver_uid,refused_at) VALUES (?,?,unixepoch())")
          .bind(orderId, auth.user.localId).run();
        await env.DB.prepare("DELETE FROM order_responses WHERE order_id=? AND driver_uid=?")
          .bind(orderId, auth.user.localId).run();
        return response({ status: "ok", cancelled: true, reopened: true, statusNow: "new",
          message: "Вы отказались от заказа. Он снова доступен другим водителям." });
      }

      if (url.pathname === "/orders/respond" && request.method === "POST") {
        const auth = await requireApprovedDriver(request, env, true);
        const b = await request.json();
        const order = await env.DB.prepare("SELECT * FROM orders WHERE id=? AND status='new'").bind(String(b.order_id || "")).first();
         const activeOrder = await env.DB.prepare("SELECT id FROM orders WHERE assigned_driver_uid=? AND status IN ('driver_assigned','arrived') LIMIT 1")
           .bind(auth.user.localId).first();
         if (activeOrder) {
           return response({ status: "error", message: "Сначала завершите текущий заказ. Следующий станет доступен после его закрытия." }, 409);
         }
        if (!order) return response({ status: "error", message: "Заказ уже принят другим водителем или недоступен" }, 409);
        const refused = await env.DB.prepare("SELECT 1 AS found FROM order_refusals WHERE order_id=? AND driver_uid=?")
          .bind(order.id, auth.user.localId).first();
        if (refused) return response({ status: "error", message: "Вы уже отказались от этого заказа; повторный отклик недоступен" }, 409);
        const now = Math.floor(Date.now() / 1000);
        if (!hasFreshValidDriverLocation(auth.driver, now))
          return response({ status: "error", message: "Сначала обновите геолокацию и попробуйте снова" }, 409);
        await env.DB.prepare("INSERT OR IGNORE INTO order_responses (order_id,driver_uid,requested_at) VALUES (?,?,?)")
          .bind(order.id, auth.user.localId, now).run();
        await env.DB.prepare("UPDATE orders SET response_deadline=COALESCE(response_deadline, ?) WHERE id=? AND status='new'")
          .bind(now + 10, order.id).run();
        const fresh = await env.DB.prepare("SELECT response_deadline,status,assigned_driver_uid FROM orders WHERE id=?").bind(order.id).first();
        const assignedToThisDriver = ["driver_assigned", "arrived"].includes(fresh.status) &&
          fresh.assigned_driver_uid === auth.user.localId;
        const assignedToAnotherDriver = fresh.status !== "new" && !assignedToThisDriver;
        return response({
          status: "ok",
          result: assignedToThisDriver ? "assigned" : assignedToAnotherDriver ? "taken" : "waiting",
          responseDeadline: fresh.response_deadline,
          message: assignedToThisDriver
            ? "Заказ назначен вам."
            : assignedToAnotherDriver
              ? "Заказ уже назначен другому водителю."
              : "Отклик принят. Подождите до 10 секунд: система выберет ближайшего водителя."
        });
      }

      if (url.pathname === "/radio/messages" && request.method === "GET") {
        await requireRadioMember(request, env);
        const rows = await env.DB.prepare(`SELECT id,sender_uid,sender_name,sender_role,message,created_at
          FROM radio_messages ORDER BY id DESC LIMIT 60`).all();
        return response({ status: "ok", messages: (rows.results || []).reverse() });
      }

      if (url.pathname === "/radio/messages" && request.method === "POST") {
        const member = await requireRadioMember(request, env);
        const body = await request.json();
        const message = String(body.message || "").trim();
        if (!message || message.length > 500 || hasForbiddenControlCharacters(message)) return response({ status: "error", message: "Сообщение должно содержать от 1 до 500 символов и не содержать управляющих символов" }, 400);
        const result = await env.DB.prepare(`INSERT INTO radio_messages (sender_uid,sender_name,sender_role,message,created_at)
          VALUES (?,?,?,?,unixepoch())`).bind(member.user.localId, member.name, member.role, message).run();
        await env.DB.prepare("DELETE FROM radio_messages WHERE id NOT IN (SELECT id FROM radio_messages ORDER BY id DESC LIMIT 300)").run();
        return response({ status: "ok", id: result.meta?.last_row_id || null });
      }

      if (url.pathname === "/radio/token" && request.method === "POST") {
        const member = await requireRadioMember(request, env);
        const token = await createLiveKitToken(env, member.user.localId, member.name);
        return response({ status: "ok", url: env.LIVEKIT_URL, token, room: "jol-aman-kenchi-radio" });
      }

      if (url.pathname === "/radio/ptt" && (request.method === "GET" || request.method === "POST")) {
        const member = await requireRadioMember(request, env);
        const now = Math.floor(Date.now() / 1000);
        if (request.method === "GET") {
          const floor = await env.DB.prepare("SELECT holder_uid,holder_name,expires_at FROM radio_floor WHERE id=1").first();
          if (floor && Number(floor.expires_at) <= now) {
            await env.DB.prepare("UPDATE radio_floor SET holder_uid=NULL,holder_name=NULL,expires_at=0 WHERE id=1 AND expires_at<=?").bind(now).run();
            return response({ status: "ok", busy: false });
          }
          return response({ status: "ok", busy: !!floor?.holder_uid, holder_name: floor?.holder_name || null });
        }
        const body = await request.json();
        const action = String(body.action || "");
        if (action === "release") {
          await env.DB.prepare("UPDATE radio_floor SET holder_uid=NULL,holder_name=NULL,expires_at=0 WHERE id=1 AND holder_uid=?").bind(member.user.localId).run();
          return response({ status: "ok", released: true });
        }
        if (!['acquire','refresh'].includes(action)) return response({ status: "error", message: "Неизвестное действие рации" }, 400);
        const updated = await env.DB.prepare(`UPDATE radio_floor SET holder_uid=?,holder_name=?,expires_at=?
          WHERE id=1 AND (expires_at<=? OR holder_uid=?)`).bind(member.user.localId, member.name, now + 6, now, member.user.localId).run();
        if (!updated.meta || Number(updated.meta.changes || 0) !== 1) {
          const floor = await env.DB.prepare("SELECT holder_name FROM radio_floor WHERE id=1").first();
          return response({ status: "busy", busy: true, holder_name: floor?.holder_name || "Другой участник" }, 409);
        }
        return response({ status: "ok", acquired: true, expires_at: now + 6 });
      }

      return response({ status: "error", message: "Адрес не найден" }, 404);
    } catch (error) {
      const message = error && error.message ? error.message : String(error);
      const code = /права диспетчера|рация доступна только/.test(message) ? 403 : /голосовая рация ещё не настроена/.test(message) ? 503 : /не одобрен|выйдите на линию/.test(message) ? 403 : /дата смены|неверная дата/.test(message) ? 400 : 401;
      return response({ status: "error", message }, code);
    }
  }
};
