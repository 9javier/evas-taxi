import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { haversineDistance } from './utils/geofire';
import { sendPushNotification, sendUserPushNotification } from './utils/fcm';
import { enqueueTask, functionsBaseUrl } from './utils/tasks';

console.log('Inicializando Firebase Admin...');
try {
  admin.initializeApp({
    credential: admin.credential.cert(require('../serviceAccountKey.json'))
  });
} catch (err) {
  console.error('Error al inicializar Firebase Admin:', err);
}
const db = admin.firestore();

// ---------------------------------------------------------------------------
// Interfaces de documentos Firestore
// ---------------------------------------------------------------------------

interface LatLng {
  lat: number;
  lng: number;
}

interface DriverDoc {
  isOnline: boolean;
  status: 'available' | 'on_trip';
  /** GeoPoint almacenado como {latitude, longitude} */
  location: { latitude: number; longitude: number };
  fcmToken?: string;
  currentTravelId?: string;
  /** Viajes activos actualmente asignados (Trip Stacking). Máximo 2. */
  activeTripsCount?: number;
}

interface TravelDoc {
  origin: LatLng;
  destino: LatLng;
  viaje_status: 'pending' | 'queued' | 'accepted' | 'driver_near' | 'driver_arrived' | 'in_progress' | 'completed' | 'canceled' | 'canceled_passenger';
  userId: string;
  driverId?: string;
  wave1DriverIds?: string[];
  wave1Tokens?: string[];
  wave2Notified?: boolean;
  wave2DriverIds?: string[];
  wave2Tokens?: string[];
  wave3Notified?: boolean;
  wave3Tokens?: string[];
}

// ---------------------------------------------------------------------------
// Constantes de configuración
// ---------------------------------------------------------------------------

const ALLOWED_ORIGINS = ['http://localhost:4200'];
const REGION = 'us-central1';
const WAVE1_SIZE = 3;          // conductores en ola 1 (top Group A)
const WAVE2_GROUP_A_SIZE = 5;  // conductores adicionales de Group A en ola 2
const WAVE1_DELAY_S = 45;      // segundos hasta ola 2
const WAVE2_DELAY_S = 90;      // segundos hasta ola 3 (blast)
const NO_DRIVER_CANCEL_DELAY_S = 3 * 60; // 3 min sin conductor → cancelar y notificar pasajero
const AUTO_CANCEL_DELAY_S = 10 * 60;      // 10 min (seguridad) sin aceptar → cancelar
const BLAST_RADIUS_KM = 10;    // radio máximo para ola 3

// ---------------------------------------------------------------------------
// Helpers internos
// ---------------------------------------------------------------------------

/** Normaliza GeoPoint de Firestore ({latitude,longitude}) a LatLng ({lat,lng}). */
function toLatLng(loc: { latitude: number; longitude: number } | LatLng): LatLng {
  if ('latitude' in loc) {
    return { lat: (loc as { latitude: number; longitude: number }).latitude, lng: (loc as { latitude: number; longitude: number }).longitude };
  }
  return loc as LatLng;
}

/** Aplica cabeceras CORS al response. */
function setCors(req: functions.https.Request, res: functions.Response): void {
  const origin = req.headers.origin as string | undefined;
  if (origin && ALLOWED_ORIGINS.includes(origin)) {
    res.set('Access-Control-Allow-Origin', origin);
  }
  res.set('Vary', 'Origin');
  res.set('Access-Control-Allow-Methods', 'POST,OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
}

/** Lee el fcmToken de un usuario dentro de una transacción. */
async function getUserFcmToken(
  tx: admin.firestore.Transaction,
  userId: string
): Promise<string | undefined> {
  const snap = await tx.get(db.collection('users').doc(String(userId)));
  const data = snap.data() ?? {};
  return typeof data.fcmToken === 'string' && data.fcmToken ? data.fcmToken : undefined;
}

interface ScoredDriver {
  id: string;
  fcmToken?: string;
  dist: number;
}

/**
 * Construye y ordena el Group B (conductores con activeTripsCount == 1)
 * por proximidad del destino de su viaje activo al origen del nuevo viaje.
 */
async function buildGroupB(
  groupBDocs: Array<{ id: string; data: DriverDoc }>,
  tripOrigin: LatLng
): Promise<ScoredDriver[]> {
  if (groupBDocs.length === 0) return [];

  const withTripId = groupBDocs.filter(d => !!d.data.currentTravelId);
  if (withTripId.length === 0) return [];

  const refs = withTripId.map(d => db.collection('travels').doc(d.data.currentTravelId!));
  const snaps = await db.getAll(...refs);

  const destinoMap = new Map<string, LatLng>();
  for (const snap of snaps) {
    if (snap.exists) {
      const t = snap.data() as TravelDoc;
      if (t.destino) destinoMap.set(snap.id, t.destino);
    }
  }

  const scored: ScoredDriver[] = [];
  for (const d of withTripId) {
    const destino = destinoMap.get(d.data.currentTravelId!);
    if (destino) {
      scored.push({
        id: d.id,
        fcmToken: d.data.fcmToken,
        dist: haversineDistance(tripOrigin, destino),
      });
    }
  }
  return scored.sort((a, b) => a.dist - b.dist);
}

// ---------------------------------------------------------------------------
// assignDriver — Lógica de asignación con Trip Stacking y sistema de oleadas
// ---------------------------------------------------------------------------

/**
 * Asigna conductores a un viaje pendiente usando un sistema de 3 oleadas:
 *
 * Ola 1 (inmediata): Top 3 conductores del Grupo A (activeTripsCount == 0)
 *                    ordenados por distancia al origen del viaje.
 *
 * Ola 2 (45s):       Siguientes 5 de Grupo A + mejores de Grupo B
 *                    (activeTripsCount == 1), ordenados por cercanía del
 *                    destino de su viaje actual al origen del nuevo viaje.
 *
 * Ola 3 (90s):       Blast — todos los conductores elegibles en radio de 10km
 *                    que aún no hayan sido notificados.
 */
export const assignDriver = functions
  .region(REGION)
  .https.onRequest(async (req, res) => {
    setCors(req, res);
    if (req.method === 'OPTIONS') { res.status(204).send(''); return; }
    if (req.method !== 'POST') { res.status(405).json({ error: 'Method Not Allowed' }); return; }

    try {
      const { origin: travelOrigin, travelId } = req.body ?? {};
      if (!travelOrigin?.lat || !travelOrigin?.lng || !travelId) {
        res.status(400).json({ error: 'Invalid payload: se requiere origin.lat, origin.lng y travelId' });
        return;
      }

      const travelRef = db.collection('requestTravel').doc(travelId);
      const travelSnap = await travelRef.get();
      if (!travelSnap.exists) {
        res.status(404).json({ error: 'Travel not found' });
        return;
      }

      console.log(`assignDriver: procesando travelId=${travelId}`);

      // 1. Obtener todos los conductores online
      const driversSnap = await db.collection('drivers')
        .where('isOnline', '==', true)
        .get();

      // DEBUG: log total de drivers encontrados con isOnline==true
      console.log(`assignDriver: total drivers con isOnline=true → ${driversSnap.size}`);

      // DEBUG: si no hay ninguno, loguear TODOS los drivers para ver su estado real
      if (driversSnap.empty) {
        const allDrivers = await db.collection('drivers').get();
        console.log(`assignDriver: total drivers en colección → ${allDrivers.size}`);
        allDrivers.forEach(doc => {
          const d = doc.data();
          console.log(`  driver ${doc.id}: isOnline=${d.isOnline}, activeTripsCount=${d.activeTripsCount}, hasFcmToken=${!!d.fcmToken}`);
        });
      }

      const groupADocs: Array<{ id: string; data: DriverDoc }> = [];
      const groupBDocs: Array<{ id: string; data: DriverDoc }> = [];

      for (const doc of driversSnap.docs) {
        const data = doc.data() as DriverDoc;
        const count = data.activeTripsCount ?? 0;
        // DEBUG: log cada driver elegible
        console.log(`  driver ${doc.id}: activeTripsCount=${count}, hasFcmToken=${!!data.fcmToken}, hasLocation=${!!data.location}`);
        if (count >= 2) continue; // sin capacidad
        if (count === 0) groupADocs.push({ id: doc.id, data });
        else groupBDocs.push({ id: doc.id, data });
      }

      console.log(`assignDriver: Grupo A=${groupADocs.length} conductores, Grupo B=${groupBDocs.length} conductores`);

      // 2. Puntuar y ordenar Grupo A por distancia al origen
      const groupA: ScoredDriver[] = groupADocs
        .map(d => ({
          id: d.id,
          fcmToken: d.data.fcmToken,
          dist: haversineDistance(travelOrigin, toLatLng(d.data.location)),
        }))
        .sort((a, b) => a.dist - b.dist);

      // 3. Puntuar Grupo B por distancia del destino de su viaje activo al origen del nuevo viaje
      const groupB = await buildGroupB(groupBDocs, travelOrigin);

      // 4. Ola 1: Top WAVE1_SIZE del Grupo A.
      //    Si no hay Grupo A, usar los mejores del Grupo B como fallback
      //    para garantizar notificación inmediata sin depender de Cloud Tasks.
      const wave1Candidates = groupA.length > 0 ? groupA.slice(0, WAVE1_SIZE) : groupB.slice(0, WAVE1_SIZE);
      const wave1Tokens = wave1Candidates.map(d => d.fcmToken).filter((t): t is string => !!t);
      const wave1DriverIds = wave1Candidates.map(d => d.id);
      const wave1Source = groupA.length > 0 ? 'Grupo A' : 'Grupo B (fallback)';

      if (wave1Tokens.length > 0) {
        await sendPushNotification(
          wave1Tokens,
          { type: 'NEW_TRAVEL', travelId, wave: '1', driverIds: wave1DriverIds.join(',') },
          { title: 'New ride available', body: 'You have a new ride request to accept.' }
        );
        // Un documento por driver para que cada uno tenga su propio flag processed independiente
        const ts1 = admin.firestore.Timestamp.now();
        await Promise.all(wave1DriverIds.map(driverId =>
          db.collection('background_messages').add({
            data: { type: 'NEW_TRAVEL', travelId, wave: '1' },
            driverId,
            processed: false,
            receivedAt: ts1,
          })
        ));
        console.log(`assignDriver: Ola 1 enviada a ${wave1Tokens.length} conductores (${wave1Source})`);
      } else {
        console.log('assignDriver: Ola 1 sin conductores elegibles');
      }

      // 5. Persistir estado de ola 1 en el documento del viaje
      await travelRef.update({
        priorityDrivers: wave1DriverIds,
        priorityEndAt: admin.firestore.Timestamp.fromDate(new Date(Date.now() + WAVE1_DELAY_S * 1000)),
        wave1Tokens,
        wave1DriverIds,
        wave1NotifiedAt: admin.firestore.Timestamp.now(),
        viaje_status: 'pending',
      });

      // 6. Encolar tareas diferidas para olas 2, 3 y cancelación automática
      try {
        const baseUrl = functionsBaseUrl(REGION);
        const serviceAccountEmail = `${process.env.GCLOUD_PROJECT}@appspot.gserviceaccount.com`;

        await enqueueTask({
          url: `${baseUrl}/notifyWave2Task`,
          payload: { travelId },
          delaySeconds: WAVE1_DELAY_S,
          serviceAccountEmail,
        });
        console.log(`assignDriver: notifyWave2Task encolada (${WAVE1_DELAY_S}s)`);

        await enqueueTask({
          url: `${baseUrl}/notifyWave3Task`,
          payload: { travelId },
          delaySeconds: WAVE2_DELAY_S,
          serviceAccountEmail,
        });
        console.log(`assignDriver: notifyWave3Task encolada (${WAVE2_DELAY_S}s)`);

        await enqueueTask({
          url: `${baseUrl}/noDriverCancelTask`,
          payload: { travelId },
          delaySeconds: NO_DRIVER_CANCEL_DELAY_S,
          serviceAccountEmail,
        });
        console.log(`assignDriver: noDriverCancelTask encolada (${NO_DRIVER_CANCEL_DELAY_S}s)`);

        /*await enqueueTask({
          url: `${baseUrl}/cancelTravelTask`,
          payload: { travelId },
          delaySeconds: AUTO_CANCEL_DELAY_S,
          serviceAccountEmail,
        });*/
        console.log(`assignDriver: cancelTravelTask encolada (${AUTO_CANCEL_DELAY_S}s)`);
      } catch (taskErr: any) {
        console.error(
          `assignDriver: Error encolando tareas Cloud Tasks (proyecto=${process.env.GCLOUD_PROJECT}, queue=rides-queue-v2):`,
          taskErr?.message ?? taskErr
        );
      }

      res.json({ priorityDrivers: wave1DriverIds, notified: wave1Tokens.length });
    } catch (error: any) {
      console.error('assignDriver error:', error);
      res.status(500).json({ error: 'Internal error', detail: error?.message });
    }
  });

// ---------------------------------------------------------------------------
// notifyWave2Task — Ola 2: siguientes 5 de Grupo A + mejores de Grupo B
// ---------------------------------------------------------------------------

export const notifyWave2Task = functions
  .region(REGION)
  .https.onRequest(async (req, res) => {
    try {
      const { travelId } = req.body ?? {};
      if (!travelId) { res.status(400).send('Missing travelId'); return; }

      const travelRef = db.collection('requestTravel').doc(travelId);
      const snap = await travelRef.get();

      if (!snap.exists) { res.status(200).send('No-op: viaje no encontrado'); return; }

      const data = snap.data() as TravelDoc;
      if (data.viaje_status !== 'pending') {
        console.log(`notifyWave2Task: viaje ${travelId} ya no está pending (${data.viaje_status})`);
        res.status(200).send('No-op: viaje no pendiente');
        return;
      }
      if (data.wave2Notified) {
        console.log(`notifyWave2Task: ola 2 ya enviada para ${travelId}`);
        res.status(200).send('No-op: ola 2 ya enviada');
        return;
      }

      const travelOrigin = data.origin;
      const wave1DriverIds = new Set<string>(Array.isArray(data.wave1DriverIds) ? data.wave1DriverIds : []);
      const wave1Tokens = new Set<string>(Array.isArray(data.wave1Tokens) ? data.wave1Tokens : []);

      // Re-obtener conductores con estado actual
      const driversSnap = await db.collection('drivers').where('isOnline', '==', true).get();

      const groupADocs: Array<{ id: string; data: DriverDoc }> = [];
      const groupBDocs: Array<{ id: string; data: DriverDoc }> = [];

      for (const doc of driversSnap.docs) {
        const driverData = doc.data() as DriverDoc;
        const count = driverData.activeTripsCount ?? 0;
        if (count >= 2) continue;
        if (count === 0) groupADocs.push({ id: doc.id, data: driverData });
        else groupBDocs.push({ id: doc.id, data: driverData });
      }

      // Grupo A: excluir ola 1, tomar siguientes WAVE2_GROUP_A_SIZE
      const groupAWave2: ScoredDriver[] = groupADocs
        .filter(d => !wave1DriverIds.has(d.id))
        .map(d => ({
          id: d.id,
          fcmToken: d.data.fcmToken,
          dist: haversineDistance(travelOrigin, toLatLng(d.data.location)),
        }))
        .sort((a, b) => a.dist - b.dist)
        .slice(0, WAVE2_GROUP_A_SIZE);

      // Grupo B: conductores con trip stacking disponible
      const groupB = await buildGroupB(groupBDocs, travelOrigin);

      const wave2Candidates = [...groupAWave2, ...groupB];
      const wave2Tokens = wave2Candidates
        .map(d => d.fcmToken)
        .filter((t): t is string => !!t && !wave1Tokens.has(t));
      const wave2DriverIds = wave2Candidates.map(d => d.id);

      console.log(`notifyWave2Task: Grupo A ola2=${groupAWave2.length}, Grupo B=${groupB.length}, tokens a enviar=${wave2Tokens.length}`);

      if (wave2Tokens.length > 0) {
        await sendPushNotification(
          wave2Tokens,
          { type: 'NEW_TRAVEL', travelId, wave: '2', driverIds: wave2DriverIds.join(',') },
          { title: 'New ride available', body: 'Ride request still available.' }
        );
        // Un documento por driver para que cada uno tenga su propio flag processed independiente
        const ts2 = admin.firestore.Timestamp.now();
        await Promise.all(wave2DriverIds.map(driverId =>
          db.collection('background_messages').add({
            data: { type: 'NEW_TRAVEL', travelId, wave: '2' },
            driverId,
            processed: false,
            receivedAt: ts2,
          })
        ));
      }

      await travelRef.update({
        wave2Notified: true,
        wave2DriverIds,
        wave2Tokens,
        wave2NotifiedAt: admin.firestore.Timestamp.now(),
      });

      res.status(200).send('OK');
    } catch (e: any) {
      console.error('notifyWave2Task error:', e);
      res.status(500).send(e.message);
    }
  });

// ---------------------------------------------------------------------------
// notifyWave3Task — Ola 3: blast a todos los conductores elegibles en 10km
// ---------------------------------------------------------------------------

export const notifyWave3Task = functions
  .region(REGION)
  .https.onRequest(async (req, res) => {
    try {
      const { travelId } = req.body ?? {};
      if (!travelId) { res.status(400).send('Missing travelId'); return; }

      const travelRef = db.collection('requestTravel').doc(travelId);
      const snap = await travelRef.get();

      if (!snap.exists) { res.status(200).send('No-op: viaje no encontrado'); return; }

      const data = snap.data() as TravelDoc;
      if (data.viaje_status !== 'pending') {
        console.log(`notifyWave3Task: viaje ${travelId} ya no está pending (${data.viaje_status})`);
        res.status(200).send('No-op: viaje no pendiente');
        return;
      }
      if (data.wave3Notified) {
        console.log(`notifyWave3Task: ola 3 ya enviada para ${travelId}`);
        res.status(200).send('No-op: ola 3 ya enviada');
        return;
      }

      const travelOrigin = data.origin;

      // Todos los tokens ya notificados (olas 1 y 2)
      const alreadyNotified = new Set<string>([
        ...(Array.isArray(data.wave1Tokens) ? data.wave1Tokens : []),
        ...(Array.isArray(data.wave2Tokens) ? data.wave2Tokens : []),
      ]);

      // Obtener todos los conductores elegibles en radio de BLAST_RADIUS_KM
      const driversSnap = await db.collection('drivers').where('isOnline', '==', true).get();

      const blastTokens: string[] = [];
      const blastDriverIds: string[] = [];

      for (const doc of driversSnap.docs) {
        const driverData = doc.data() as DriverDoc;
        const count = driverData.activeTripsCount ?? 0;
        if (count >= 2 || !driverData.fcmToken) continue;

        const dist = haversineDistance(travelOrigin, toLatLng(driverData.location));
        if (dist > BLAST_RADIUS_KM) continue;

        if (!alreadyNotified.has(driverData.fcmToken)) {
          blastTokens.push(driverData.fcmToken);
          blastDriverIds.push(doc.id);
        }
      }

      console.log(`notifyWave3Task: blast a ${blastTokens.length} conductores en radio ${BLAST_RADIUS_KM}km`);

      if (blastTokens.length > 0) {
        await sendPushNotification(
          blastTokens,
          { type: 'NEW_TRAVEL', travelId, wave: '3', driverIds: blastDriverIds.join(',') },
          { title: 'New ride available', body: 'A ride request is available in your area.' }
        );
        // Un documento por driver para que cada uno tenga su propio flag processed independiente
        const ts3 = admin.firestore.Timestamp.now();
        await Promise.all(blastDriverIds.map(driverId =>
          db.collection('background_messages').add({
            data: { type: 'NEW_TRAVEL', travelId, wave: '3' },
            driverId,
            processed: false,
            receivedAt: ts3,
          })
        ));
      }

      await travelRef.update({
        wave3Notified: true,
        wave3DriverIds: blastDriverIds,
        wave3Tokens: blastTokens,
        wave3NotifiedAt: admin.firestore.Timestamp.now(),
      });

      res.status(200).send('OK');
    } catch (e: any) {
      console.error('notifyWave3Task error:', e);
      res.status(500).send(e.message);
    }
  });

// ---------------------------------------------------------------------------
// Helper: elimina todos los background_messages de un travelId
// ---------------------------------------------------------------------------

async function deleteBackgroundMessages(travelId: string): Promise<void> {
  const snap = await db.collection('background_messages')
    .where('data.travelId', '==', travelId)
    .get();
  if (snap.empty) return;
  await Promise.all(snap.docs.map(doc => doc.ref.delete()));
  console.log(`deleteBackgroundMessages: eliminados ${snap.docs.length} docs para travelId=${travelId}`);
}

// ---------------------------------------------------------------------------
// noDriverCancelTask — Cancela a los 3 min si nadie aceptó y notifica al pasajero
// ---------------------------------------------------------------------------

export const noDriverCancelTask = functions
  .region(REGION)
  .https.onRequest(async (req, res) => {
    try {
      const { travelId } = req.body ?? {};
      if (!travelId) { res.status(400).send('Missing travelId'); return; }

      const travelRef = db.collection('requestTravel').doc(travelId);
      const snap = await travelRef.get();

      if (!snap.exists) { res.status(200).send('No-op: viaje no encontrado'); return; }

      const data = snap.data() as TravelDoc;
      if (data.viaje_status !== 'pending') {
        console.log(`noDriverCancelTask: viaje ${travelId} ya no está pending (${data.viaje_status}), no-op`);
        res.status(200).send('No-op: viaje no pendiente');
        return;
      }

      // Cancelar el viaje
      await travelRef.update({ viaje_status: 'canceled' });
      console.log(`noDriverCancelTask: viaje ${travelId} cancelado por falta de conductor (3 min)`);

      // Notificar al pasajero por FCM (cubre foreground y background)
      if (data.userId) {
        const userSnap = await db.collection('users').doc(String(data.userId)).get();
        const fcmToken = userSnap.data()?.fcmToken;
        if (fcmToken) {
          await sendUserPushNotification(
            fcmToken,
            { type: 'NO_DRIVER_FOUND', travelId },
            { title: 'No driver found', body: 'No drivers are available right now. Please try again later.' }
          );
        }
      }

      // Limpiar background_messages de los conductores notificados
      await deleteBackgroundMessages(travelId);

      // Eliminar el documento de requestTravel — ya no es necesario
      await travelRef.delete();
      console.log(`noDriverCancelTask: requestTravel/${travelId} eliminado`);

      res.status(200).send('OK');
    } catch (e: any) {
      console.error('noDriverCancelTask error:', e);
      res.status(500).send(e.message);
    }
  });

// ---------------------------------------------------------------------------
// cancelTravelTask — Cancela el viaje si sigue pendiente tras el tiempo límite
// ---------------------------------------------------------------------------

export const cancelTravelTask = functions
  .region(REGION)
  .https.onRequest(async (req, res) => {
    try {
      const { travelId } = req.body ?? {};
      if (!travelId) { res.status(400).send('Missing travelId'); return; }

      const travelRef = db.collection('requestTravel').doc(travelId);
      const snap = await travelRef.get();
      const data = snap.data();

      if (data?.viaje_status === 'pending') {
        await travelRef.update({ viaje_status: 'canceled' });
        console.log(`cancelTravelTask: viaje ${travelId} cancelado por timeout`);
      } else {
        console.log(`cancelTravelTask: viaje ${travelId} ya no está pending (${data?.viaje_status}), no-op`);
      }

      // Limpiar background_messages independientemente del status
      await deleteBackgroundMessages(travelId);

      res.status(200).send('OK');
    } catch (e: any) {
      console.error('cancelTravelTask error:', e);
      res.status(500).send(e.message);
    }
  });

// ---------------------------------------------------------------------------
// acceptTravel — Conductor acepta un viaje (transacción atómica con Trip Stacking)
// ---------------------------------------------------------------------------

/**
 * Transacción que valida y ejecuta la aceptación de un viaje.
 *
 * Parámetros:
 *   travelId  — ID del viaje en requestTravel
 *   driverId  — ID del conductor
 *   queueMode — (opcional, default false) Si true, el viaje se guarda con
 *               viaje_status 'queued' en lugar de 'accepted'. Se usa cuando
 *               el conductor ya tiene un viaje activo y acepta un segundo.
 *
 * En ambos modos:
 *   - El viaje debe estar en viaje_status == 'pending'
 *   - El conductor debe tener activeTripsCount < 2
 *   - Mueve el documento de requestTravel → travels
 *   - Incrementa activeTripsCount del conductor
 */
export const acceptTravel = functions
  .region(REGION)
  .https.onRequest(async (req, res) => {
    setCors(req, res);
    if (req.method === 'OPTIONS') { res.status(204).send(''); return; }
    if (req.method !== 'POST') { res.status(405).json({ error: 'Method Not Allowed' }); return; }

    try {
      const { travelId, driverId, queueMode = false } = req.body ?? {};
      if (!travelId || !driverId) {
        res.status(400).json({ error: 'Missing travelId or driverId' });
        return;
      }

      const travelRef = db.collection('requestTravel').doc(travelId);
      const driverRef = db.collection('drivers').doc(driverId);

      await db.runTransaction(async (tx) => {
        // --- Lecturas primero ---
        const travelSnap = await tx.get(travelRef);
        if (!travelSnap.exists) throw new Error('Travel not found');

        const travelData = travelSnap.data() as TravelDoc;
        if (travelData.viaje_status !== 'pending') {
          throw new Error(`Travel not available (status: ${travelData.viaje_status})`);
        }

        const driverSnap = await tx.get(driverRef);
        if (!driverSnap.exists) throw new Error('Driver not found');

        const driverData = driverSnap.data() as DriverDoc;
        if (!driverData.isOnline) throw new Error('Driver offline');

        const currentCount = driverData.activeTripsCount ?? 0;
        if (currentCount >= 2) {
          throw new Error('Driver at max trip capacity (activeTripsCount >= 2)');
        }

        // --- Escrituras después ---
        const travelsRef = db.collection('travels').doc(travelId);
        const nowTs = admin.firestore.Timestamp.now();
        const finalStatus = queueMode ? 'queued' : 'accepted';

        tx.set(travelsRef, {
          ...travelData,
          viaje_status: finalStatus,
          acceptedDriver: driverId,
          driverId,
          acceptedAt: nowTs,
        });
        tx.delete(travelRef);
        tx.update(driverRef, {
          activeTripsCount: currentCount + 1,
          status: 'on_trip',
          // En modo cola el conductor ya tiene un viaje activo; no pisamos currentTravelId
          ...(queueMode ? {} : { currentTravelId: travelId }),
        });
      });

      const mode = queueMode ? 'cola (queued)' : 'aceptado';
      console.log(`acceptTravel: travelId=${travelId} ${mode} por driverId=${driverId}`);

      // Limpiar background_messages — el viaje ya fue tomado, ningún otro driver debe verlo
      await deleteBackgroundMessages(travelId);

      res.status(200).json({ success: true, travelId, driverId, queueMode });
    } catch (e: any) {
      console.error('acceptTravel error:', e);
      res.status(400).json({ error: e.message });
    }
  });

// ---------------------------------------------------------------------------
// promoteQueuedTravel — Promueve el viaje en cola a activo al terminar el 1er viaje
// ---------------------------------------------------------------------------

/**
 * Cuando el conductor termina su viaje activo, este endpoint promueve el viaje
 * en cola (viaje_status == 'queued') al estado 'accepted', arrancando el ciclo
 * normal del segundo viaje.
 *
 * No modifica activeTripsCount porque completeTravel ya lo decrementó (2 → 1).
 * Solo actualiza viaje_status y currentTravelId del conductor.
 */
export const promoteQueuedTravel = functions
  .region(REGION)
  .https.onRequest(async (req, res) => {
    setCors(req, res);
    if (req.method === 'OPTIONS') { res.status(204).send(''); return; }
    if (req.method !== 'POST') { res.status(405).json({ error: 'Method Not Allowed' }); return; }

    try {
      const { travelId, driverId } = req.body ?? {};
      if (!travelId || !driverId) {
        res.status(400).json({ error: 'Missing travelId or driverId' });
        return;
      }

      const travelRef = db.collection('travels').doc(travelId);
      const driverRef = db.collection('drivers').doc(driverId);

      await db.runTransaction(async (tx) => {
        // --- Lecturas primero ---
        const travelSnap = await tx.get(travelRef);
        if (!travelSnap.exists) throw new Error('Travel not found in travels collection');

        const travelData = travelSnap.data() as TravelDoc;
        if (travelData.viaje_status !== 'queued') {
          throw new Error(`Travel is not queued (current status: ${travelData.viaje_status})`);
        }

        // --- Escrituras después ---
        const nowTs = admin.firestore.Timestamp.now();
        tx.update(travelRef, {
          viaje_status: 'accepted',
          promotedAt: nowTs,
        });
        // Actualizar currentTravelId al nuevo viaje activo
        tx.update(driverRef, {
          currentTravelId: travelId,
          status: 'on_trip',
        });
      });

      console.log(`promoteQueuedTravel: travelId=${travelId} promovido a accepted por driverId=${driverId}`);
      res.status(200).json({ success: true, travelId, driverId });
    } catch (e: any) {
      console.error('promoteQueuedTravel error:', e);
      res.status(400).json({ error: e.message });
    }
  });

// ---------------------------------------------------------------------------
// completeTravel — Finaliza un viaje y libera (o mantiene ocupado) al conductor
// ---------------------------------------------------------------------------

export const completeTravel = functions.https.onRequest(async (req, res) => {
  const { travelId, driverId } = req.body;
  if (!travelId || !driverId) {
    res.status(400).json({ error: 'Faltan datos necesarios' });
    return;
  }

  try {
    const travelRef = db.collection('travels').doc(travelId);
    const driverRef = db.collection('drivers').doc(driverId);

    await db.runTransaction(async (tx) => {
      // --- Lecturas primero ---
      const travelSnap = await tx.get(travelRef);
      if (!travelSnap.exists) throw new Error('Viaje no encontrado');
      const travelData = travelSnap.data() as TravelDoc;

      const driverSnap = await tx.get(driverRef);
      if (!driverSnap.exists) throw new Error('Conductor no encontrado');
      const driverData = driverSnap.data() as DriverDoc;

      // --- Escrituras después ---
      const newCount = Math.max(0, (driverData.activeTripsCount ?? 1) - 1);
      const driverUpdate: Record<string, unknown> = {
        activeTripsCount: newCount,
        status: newCount === 0 ? 'available' : 'on_trip',
      };
      if (newCount === 0) {
        driverUpdate.currentTravelId = admin.firestore.FieldValue.delete();
      }
      tx.update(driverRef, driverUpdate);

      const nowTs = admin.firestore.Timestamp.now();
      tx.update(travelRef, {
        viaje_status: 'completed',
        completedAt: nowTs,
      });
      tx.set(db.collection('historical_travels').doc(travelId), {
        ...travelData,
        viaje_status: 'completed',
        completedAt: nowTs,
      });
      tx.delete(travelRef);
    });

    console.log(`completeTravel: travelId=${travelId} completado`);
    res.status(200).json({ success: true, travelId, driverId });
  } catch (e: any) {
    console.error('completeTravel error:', e);
    res.status(400).json({ error: e.message });
  }
});

// ---------------------------------------------------------------------------
// Funciones de notificación de estado (sin cambios funcionales)
// ---------------------------------------------------------------------------

export const testFCM = functions.https.onRequest(async (req, res) => {
  const { travelId, driverId } = req.body;
  if (!travelId || !driverId) {
    res.status(400).json({ error: 'Missing travelId or driverId' });
    return;
  }
  try {
    const driverRef = db.collection('drivers').doc(driverId);
    const travelRef = db.collection('travels').doc(travelId);

    const [driverSnap, travelSnap] = await Promise.all([driverRef.get(), travelRef.get()]);
    if (!driverSnap.exists || !travelSnap.exists) {
      res.status(404).json({ error: 'Driver or travel not found' });
      return;
    }

    await travelRef.update({ viaje_status: 'driver_near' });

    const userId = travelSnap.data()?.userId;
    const passengerFcmToken: string | undefined = await db.runTransaction(async (tx) => {
      return getUserFcmToken(tx, String(userId));
    });

    if (passengerFcmToken) {
      await sendUserPushNotification(
        passengerFcmToken,
        { type: 'DRIVER_NEAR', travelId, driverId },
        { title: 'Driver is near', body: 'Your driver is near your location.' }
      );
    }

    res.status(200).json({ success: true, travelId, driverId });
  } catch (e: any) {
    console.error('testFCM error:', e);
    res.status(400).json({ error: e.message });
  }
});

export const notifyDriverArrivedUrl = functions.https.onRequest(async (req, res) => {
  const { travelId, driverId } = req.body;
  if (!travelId || !driverId) {
    res.status(400).json({ error: 'Missing travelId or driverId' });
    return;
  }
  try {
    const travelRef = db.collection('travels').doc(travelId);
    const [driverSnap, travelSnap] = await Promise.all([
      db.collection('drivers').doc(driverId).get(),
      travelRef.get(),
    ]);

    if (!driverSnap.exists || !travelSnap.exists) {
      res.status(404).json({ error: 'Driver or travel not found' });
      return;
    }

    await travelRef.update({ viaje_status: 'driver_arrived' });

    const userId = travelSnap.data()?.userId;
    const passengerFcmToken: string | undefined = await db.runTransaction(async (tx) => {
      return getUserFcmToken(tx, String(userId));
    });

    if (passengerFcmToken) {
      await sendUserPushNotification(
        passengerFcmToken,
        { type: 'DRIVER_ARRIVED', travelId, driverId },
        { title: 'Driver is arriving', body: 'Your driver is about to arrive at your location.' }
      );
    }

    res.status(200).json({ success: true, travelId, driverId });
  } catch (e: any) {
    console.error('notifyDriverArrivedUrl error:', e);
    res.status(400).json({ error: e.message });
  }
});

export const updateTravelStatus = functions.https.onRequest(async (req, res) => {
  const { travelId, newStatus } = req.body;
  if (!travelId || !newStatus) {
    res.status(400).json({ error: 'Missing travelId or newStatus' });
    return;
  }
  try {
    const travelRef = db.collection('travels').doc(travelId);
    const travelSnap = await travelRef.get();
    if (!travelSnap.exists) {
      res.status(404).json({ error: 'Travel not found' });
      return;
    }
    await travelRef.update({ viaje_status: newStatus });
    res.status(200).json({ success: true, travelId, newStatus });
  } catch (e: any) {
    console.error('updateTravelStatus error:', e);
    res.status(400).json({ error: e.message });
  }
});

// ---------------------------------------------------------------------------
// getDriverETA — Estima el tiempo de llegada del conductor más cercano
// ---------------------------------------------------------------------------

/**
 * Calcula el tiempo estimado de llegada (ETA) del conductor más cercano
 * a la ubicación del pasajero.
 *
 * Parámetros (body):
 *   direction: { lat: number, lng: number } — ubicación del pasajero
 *
 * Respuesta:
 *   - { eta: number } — tiempo estimado en minutos (redondeado)
 *   - { eta: -0 } — si no hay conductores disponibles o ETA > 16 min
 *   - { driversNearby: number } — cantidad de conductores en radio de 10km
 */
export const getDriverETA = functions
  .region(REGION)
  .https.onRequest(async (req, res) => {
    setCors(req, res);
    if (req.method === 'OPTIONS') { res.status(204).send(''); return; }
    if (req.method !== 'POST') { res.status(405).json({ error: 'Method Not Allowed' }); return; }

    try {
      const { direction } = req.body ?? {};
      if (!direction?.lat || !direction?.lng) {
        res.status(400).json({ error: 'Invalid payload: se requiere direction.lat y direction.lng' });
        return;
      }

      const passengerLocation: LatLng = { lat: direction.lat, lng: direction.lng };

      // Velocidad promedio urbana en km/h (considerando tráfico de Atlanta)
      const AVG_SPEED_KMH = 25;
      // Tiempo máximo aceptable en minutos
      const MAX_ETA_MINUTES = 18;
      // Radio máximo de búsqueda en km
      const SEARCH_RADIUS_KM = 15;

      // 1. Obtener todos los conductores online
      const driversSnap = await db.collection('drivers')
        .where('isOnline', '==', true)
        .get();

      if (driversSnap.empty) {
        console.log('getDriverETA: No hay conductores online');
        res.json({ eta: -0, driversNearby: 0, message: 'No hay conductores disponibles' });
        return;
      }

      // 2. Filtrar y calcular distancias
      interface DriverWithDistance {
        id: string;
        distance: number; // km
        eta: number; // minutos
        activeTripsCount: number;
      }

      const driversWithETA: DriverWithDistance[] = [];

      for (const doc of driversSnap.docs) {
        const data = doc.data() as DriverDoc;
        const count = data.activeTripsCount ?? 0;

        // Solo conductores con capacidad (menos de 2 viajes activos)
        if (count >= 2) continue;
        if (!data.location) continue;

        const driverLocation = toLatLng(data.location);
        const distance = haversineDistance(passengerLocation, driverLocation);

        // Ignorar conductores fuera del radio de búsqueda
        if (distance > SEARCH_RADIUS_KM) continue;

        // Calcular ETA: tiempo = distancia / velocidad * 60 (para convertir a minutos)
        // Añadir 2 minutos base de "tiempo de reacción/aceptación"
        const etaMinutes = (distance / AVG_SPEED_KMH) * 60 + 2;

        driversWithETA.push({
          id: doc.id,
          distance,
          eta: etaMinutes,
          activeTripsCount: count,
        });
      }

      // 3. Ordenar: primero por activeTripsCount (preferir libres), luego por ETA
      driversWithETA.sort((a, b) => {
        // Priorizar conductores sin viajes activos (Grupo A)
        if (a.activeTripsCount !== b.activeTripsCount) {
          return a.activeTripsCount - b.activeTripsCount;
        }
        // Luego por ETA más bajo
        return a.eta - b.eta;
      });

      const driversNearby = driversWithETA.length;

      if (driversNearby === 0) {
        console.log('getDriverETA: No hay conductores en el radio de búsqueda');
        res.json({ eta: -0, driversNearby: 0, message: 'No hay conductores cercanos' });
        return;
      }

      // 4. Tomar el conductor más cercano/disponible
      const bestDriver = driversWithETA[0];
      const roundedETA = Math.round(bestDriver.eta);

      // 5. Si el ETA es mayor a 18 minutos, devolver -0
      if (roundedETA > MAX_ETA_MINUTES) {
        console.log(`getDriverETA: ETA más bajo es ${roundedETA} min, excede límite de ${MAX_ETA_MINUTES} min`);
        res.json({
          eta: -0,
          driversNearby,
          message: `Tiempo de espera estimado muy alto (${roundedETA} min)`
        });
        return;
      }

      console.log(`getDriverETA: ETA estimado = ${roundedETA} min, conductores cercanos = ${driversNearby}`);
      res.json({
        eta: roundedETA,
        driversNearby,
        // Info adicional útil para la UI
        nearestDriverDistance: Math.round(bestDriver.distance * 10) / 10, // km con 1 decimal
      });

    } catch (error: any) {
      console.error('getDriverETA error:', error);
      res.status(500).json({ error: 'Internal error', detail: error?.message });
    }
  });

// ---------------------------------------------------------------------------
// notifyAllDriversTask — mantenido para compatibilidad con tareas en vuelo
// ---------------------------------------------------------------------------

/** @deprecated Usar notifyWave2Task. Se mantiene para tareas de Cloud Tasks ya encoladas. */
export const notifyAllDriversTask = functions
  .region(REGION)
  .https.onRequest(async (req, res) => {
    try {
      const { travelId } = req.body ?? {};
      if (!travelId) { res.status(400).send('Missing travelId'); return; }

      const travelRef = db.collection('requestTravel').doc(travelId);
      const snap = await travelRef.get();
      const data = snap.data();

      if (!data || data.viaje_status !== 'pending') {
        res.status(200).send('No-op');
        return;
      }
      if (data.secondWaveNotified) {
        res.status(200).send('No-op');
        return;
      }

      const driversSnap = await db.collection('drivers')
        .where('isOnline', '==', true)
        .where('status', '==', 'available')
        .get();

      const allTokens: string[] = [];
      driversSnap.forEach(d => {
        const t = d.data().fcmToken;
        if (t) allTokens.push(t);
      });

      const wave1: string[] = Array.isArray(data.wave1Tokens) ? data.wave1Tokens : [];
      const excludeSet = new Set(wave1);
      const secondWaveTokens = allTokens.filter(t => !excludeSet.has(t));

      if (secondWaveTokens.length) {
        await sendPushNotification(
          secondWaveTokens,
          { type: 'NEW_TRAVEL', travelId, wave: '2' },
          { title: 'New ride available', body: 'Ride request still available.' }
        );
      }

      await travelRef.update({
        secondWaveNotified: true,
        secondWaveTokens,
        secondWaveNotifiedAt: admin.firestore.Timestamp.now(),
      });

      res.status(200).send('OK');
    } catch (e: any) {
      console.error('notifyAllDriversTask error:', e);
      res.status(500).send(e.message);
    }
  });

  /**
   * Función para cancelar un viaje específico. Se mantiene para compatibilidad con tareas en vuelo.
   * @deprecated Usar noDriverCancelTask. Se mantiene para tareas de Cloud Tasks ya encoladas.
   * @param travelId ID del viaje a cancelar
   * @param flagIsPassenger Indica si la cancelación es por parte del pasajero (true) o por falta de conductor (false)
   * @param flagCancellRequestTravel Indica si se debe eliminar el documento de requestTravel (true) o solo actualizar su estado a 'canceled' (false)
    * @returns Respuesta HTTP indicando el resultado de la operación
    *
    * Lógica:
    * -verifica que el viaje exista y el flagIsPassenger es false y esté en estado diferente de 'pending' | 'queued' | 'in_progress';(esto significa que el viaje ya estaba activo y el conductor lo canceló antes de iniciar)
    * -actualiza el estado del viaje a 'canceled'
    * -elimina los background_messages asociados al viaje para evitar notificaciones futuras
    * -elimina el documento de requestTravel si flagCancellRequestTravel es true, o lo deja con estado 'canceled' si es false
    * -si el flagIsPassenger es false, se asume que la cancelación es por falta de conductor y se notifica al pasajero por FCM;
    * -si flagIsPassenger es true, se asume que el pasajero canceló y no se envía notificación
   */
  export const cancellOperationTravelTask = functions
    .region(REGION)
    .https.onRequest(async (req, res) => {
      try {
        const { travelId, flagIsPassenger = false } = req.body ?? {};
        if (!travelId) { res.status(400).send('Missing travelId'); return; }

        const travelsRef = db.collection('travels').doc(travelId);
        const travelsSnap = await travelsRef.get();

        const requestTravelRef = db.collection('requestTravel').doc(travelId);
        const requestTravelSnap = await requestTravelRef.get();

        if (!travelsSnap.exists && !requestTravelSnap.exists) {
          res.status(200).send('No-op: viaje no encontrado');
          return;
        }

        // Preferir el documento en 'travels' si existe, sino usar 'requestTravel'
        const activeSnap = travelsSnap.exists ? travelsSnap : requestTravelSnap;
        const data = activeSnap.data() as TravelDoc;
        const status = data?.viaje_status;

        // Si el viaje ya está en un estado final, no hacemos nada
        const finalStates = ['completed', 'canceled', 'canceled_driver', 'canceled_passenger'];
        if (!status || finalStates.includes(status)) {
          res.status(200).send(`No-op: viaje en estado final (${status})`);
          return;
        }

        const now = admin.firestore.Timestamp.now();

        if (flagIsPassenger) {
          // Cancelación por parte del pasajero
          await db.collection('historical_travels').doc(travelId).set({
            ...(activeSnap.data() ?? {}),
            viaje_status: 'canceled_passenger',
            canceledAt: now,
          });

          // Limpiar y eliminar documentos activos
          await deleteBackgroundMessages(travelId);
          if (requestTravelSnap.exists) await requestTravelRef.delete();
          if (travelsSnap.exists) await travelsRef.delete();

          // No notificamos al conductor porque el pasajero canceló antes de que el conductor aceptara o iniciara el viaje
          if (data.driverId) {
            const driverSnap = await db.collection('drivers').doc(String(data.driverId)).get();
            // Necesitamos cambiar el status del conductor a 'available' y limpiar currentTravelId si el conductor estaba marcado como 'on_trip'
            if (driverSnap.exists) {
              const driverData = driverSnap.data() as DriverDoc;
              const updates: Record<string, unknown> = {};
              if (driverData.status === 'on_trip') {
                updates.status = 'available';
                updates.currentTravelId = admin.firestore.FieldValue.delete();
              }
              const activeTripsCount = driverData.activeTripsCount ?? 0;
              if (activeTripsCount > 0) {
                updates.activeTripsCount = Math.max(0, activeTripsCount - 1);
              }
              if (Object.keys(updates).length > 0) {
                await db.collection('drivers').doc(String(data.driverId)).update(updates);
              }
            }
            const fcmToken = driverSnap.data()?.fcmToken;
            if (fcmToken) {
              await sendUserPushNotification(
                fcmToken,
                { type: 'CANCELED_PASSENGER', travelId },
                { title: 'Ride canceled by passenger', body: 'The passenger canceled the ride.' }
              );
            }
          }

          console.log(`cancellOperationTravelTask: travel ${travelId} cancelado por pasajero`);
          res.status(200).send('OK: canceled_passenger');
          return;
        }

        // Cancelación por parte del conductor (o por falta de conductor)
        await db.collection('historical_travels').doc(travelId).set({
          ...(activeSnap.data() ?? {}),
          viaje_status: 'canceled_driver',
          canceledAt: now,
        });

        // Notificar al pasajero si existe token
        if (data.userId && !flagIsPassenger) {
            // Necesitamos cambiar el status del conductor a 'available' y limpiar currentTravelId si el conductor estaba marcado como 'on_trip'
            const driverSnap = await db.collection('drivers').doc(String(data.driverId)).get();
            if (driverSnap.exists) {
              const driverData = driverSnap.data() as DriverDoc;
              const updates: Record<string, unknown> = {};
              if (driverData.status === 'on_trip') {
                updates.status = 'available';
                updates.currentTravelId = admin.firestore.FieldValue.delete();
              }
              const activeTripsCount = driverData.activeTripsCount ?? 0;
              if (activeTripsCount > 0) {
                updates.activeTripsCount = Math.max(0, activeTripsCount - 1);
              }
              if (Object.keys(updates).length > 0) {
                await db.collection('drivers').doc(String(data.driverId)).update(updates);
              }
            }
          // Data user for passenger notification
          const userSnap = await db.collection('users').doc(String(data.userId)).get();
          const fcmToken = userSnap.data()?.fcmToken;
          if (fcmToken) {
            await sendUserPushNotification(
              fcmToken,
              { type: 'CANCEL_DRIVER', travelId },
              { title: 'Driver canceled', body: 'The ride has been canceled by the driver.' }
            );
          }
        }

        // Limpiar y eliminar documentos activos
        await deleteBackgroundMessages(travelId);
        if (requestTravelSnap.exists) await requestTravelRef.delete();
        if (travelsSnap.exists) await travelsRef.delete();

        console.log(`cancellOperationTravelTask: travel ${travelId} cancelado por conductor`);
        res.status(200).send('OK: canceled_driver');
      } catch (e: any) {
        console.error('cancellOperationTravelTask error:', e);
        res.status(500).send(e.message);
      }
    });

// ---------------------------------------------------------------------------
// claimPendingBackgroundMessage — Rescate de notificaciones no mostradas
// ---------------------------------------------------------------------------
/**
 * La app lo llama a los 10 s de abrir TravelScreen si no detectó viaje activo.
 * Busca en background_messages un doc no procesado del driver:
 *  - Si receivedAt > 12 min → elimina el doc (obsoleto).
 *  - Si el viaje ya no existe en Firestore → elimina el doc.
 *  - Si es válido → marca processed=true y devuelve travelId.
 * Responde { travelId: string | null }.
 */
export const claimPendingBackgroundMessage = functions
  .region(REGION)
  .https.onRequest(async (req, res) => {
    setCors(req, res);
    if (req.method === 'OPTIONS') { res.status(204).send(''); return; }
    if (req.method !== 'POST') { res.status(405).json({ error: 'Method Not Allowed' }); return; }

    const { driverId } = req.body ?? {};
    if (!driverId) { res.status(400).json({ error: 'Missing driverId' }); return; }

    try {
      const cutoffMs = Date.now() - 12 * 60 * 1000;

      const snap = await db.collection('background_messages')
        .where('driverId', '==', driverId)
        .where('processed', '==', false)
        .limit(10)
        .get();

      if (snap.empty) {
        res.status(200).json({ travelId: null });
        return;
      }

      // Ordenar por receivedAt desc en código (evita índice compuesto)
      const docs = snap.docs.slice().sort((a, b) => {
        const aMs = (a.data().receivedAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
        const bMs = (b.data().receivedAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;
        return bMs - aMs;
      });

      const batch = db.batch();
      let validTravelId: string | null = null;

      for (const doc of docs) {
        const data = doc.data();
        const receivedAtMs = (data.receivedAt as admin.firestore.Timestamp | undefined)?.toMillis() ?? 0;

        // Obsoleto: más de 12 min → eliminar
        if (!receivedAtMs || receivedAtMs < cutoffMs) {
          batch.delete(doc.ref);
          console.log(`claimPendingBackgroundMessage: doc ${doc.id} obsoleto → eliminado`);
          continue;
        }

        const travelId = (data.data?.travelId ?? '').toString();
        if (!travelId) { batch.delete(doc.ref); continue; }

        // Verificar que el viaje aún existe en Firestore
        const [reqSnap, travSnap] = await Promise.all([
          db.collection('requestTravel').doc(travelId).get(),
          db.collection('travels').doc(travelId).get(),
        ]);

        if (!reqSnap.exists && !travSnap.exists) {
          batch.delete(doc.ref);
          console.log(`claimPendingBackgroundMessage: travelId=${travelId} ya no existe → eliminado`);
          continue;
        }

        // Primer doc válido: marcarlo y retornar su travelId
        if (validTravelId === null) {
          batch.update(doc.ref, { processed: true });
          validTravelId = travelId;
        } else {
          batch.update(doc.ref, { processed: true });
        }
      }

      await batch.commit();
      console.log(`claimPendingBackgroundMessage: driverId=${driverId} → travelId=${validTravelId}`);
      res.status(200).json({ travelId: validTravelId });
    } catch (e: any) {
      console.error('claimPendingBackgroundMessage error:', e);
      res.status(500).json({ error: e.message });
    }
  });
