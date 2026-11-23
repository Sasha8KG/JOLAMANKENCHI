import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const checks = [];
function check(label, condition) {
  checks.push({ label, ok: Boolean(condition) });
}

const pubspec = read('testapp/pubspec.yaml');
const gradle = read('testapp/android/app/build.gradle');
const manifest = read('testapp/android/app/src/main/AndroidManifest.xml');
const firebase = JSON.parse(read('testapp/android/app/google-services.json'));
const worker = read('backend/cloudflare-worker/worker.js');
const api = read('testapp/lib/services/worker_api.dart');
const app = read('testapp/lib/main.dart');
const storageRules = read('backend/firebase-storage.rules');

check('Android applicationId is com.jolamankenchi.taxi', /applicationId\s+["']com\.jolamankenchi\.taxi["']/.test(gradle));
check('Release signing uses private keystore config', /signingConfig signingConfigs\.release/.test(gradle));
check('Release signing refuses missing secrets', /requestsRelease && !jakSigningConfigured/.test(gradle) && /JAK_KEYSTORE_PASSWORD/.test(gradle));
check('Release signing never falls back to debug key', !/signingConfig signingConfigs\.debug/.test(gradle));
check('Firebase config matches Android package', firebase.client?.some((c) => c.client_info?.android_client_info?.package_name === 'com.jolamankenchi.taxi'));
check('Firebase project is jol-aman-kenchi', firebase.project_info?.project_id === 'jol-aman-kenchi');
check('LiveKit client dependency is pinned', /livekit_client:\s*2\.2\.4(?:\s|$)/.test(pubspec));
check('App has microphone permission', /android\.permission\.RECORD_AUDIO/.test(manifest));
check('App has location permissions', /ACCESS_FINE_LOCATION/.test(manifest) && /ACCESS_COARSE_LOCATION/.test(manifest));
check('Worker has cancellation endpoint', worker.includes('"/orders/cancel"'));
check('Worker has trip completion endpoint', worker.includes('"/orders/complete"'));
check('Worker has radio token endpoint', worker.includes('"/radio/token"'));
check('Worker has radio chat endpoint', worker.includes('"/radio/messages"'));
check('Worker reads LiveKit secret only from environment', /env\.LIVEKIT_API_SECRET/.test(worker) && !/LIVEKIT_API_SECRET\s*=\s*["'][^"']+["']/.test(worker));
check('Flutter API calls radio endpoints', api.includes("'/radio/token'") && api.includes("'/radio/messages'"));
check('App includes shared radio UI', app.includes('ОБЩАЯ РАЦИЯ ТАКСОПАРКА'));
const dispatcherUid = worker.match(/const DISPATCHER_UID = "([^"]+)";/)?.[1];
const storageDispatcherUid = storageRules.match(/request\.auth\.uid == '([^']+)'/)?.[1];
check('Firebase Storage dispatcher access matches Worker dispatcher', Boolean(dispatcherUid) && dispatcherUid === storageDispatcherUid);
check('Firebase Storage accepts the full 8 MB app upload limit', /request\.resource\.size\s*<=\s*8\s*\*\s*1024\s*\*\s*1024/.test(storageRules));
const driverDocumentRule = storageRules.match(/function isDriverDocument\(fileName\) \{([\s\S]*?)\}/)?.[1] || '';
const driverDocumentRuleUses = (storageRules.match(/isDriverDocument\(fileName\)/g) || []).length;
check('Firebase Storage exposes only the three approved driver documents', ['license.jpg', 'driver_photo.jpg', 'car_photo.jpg'].every((name) => driverDocumentRule.includes(`'${name}'`)) && driverDocumentRuleUses >= 4);
check('Worker accepts only exact driver document paths', /const expectedPaths = \[\s*`drivers\/\$\{auth\.user\.localId\}\/license\.jpg`,\s*`drivers\/\$\{auth\.user\.localId\}\/driver_photo\.jpg`,\s*`drivers\/\$\{auth\.user\.localId\}\/car_photo\.jpg`\s*\]/.test(worker) && /paths\.every\(\(value, index\) => value === expectedPaths\[index\]\)/.test(worker));
check('Android launcher label matches the approved app name', /android:label="«Жол Аман Кенчи» Такси"/.test(manifest));

check('Open orders require an approved online driver', worker.includes('url.pathname === "/orders/open"') && worker.includes('requireApprovedDriver(request, env, true)'));
check('Open offers exclude drivers with an active order', worker.includes("active.assigned_driver_uid=?") && worker.includes("active.status IN ('driver_assigned','arrived')"));
check('Assigned orders are limited to active states', worker.includes("status IN ('driver_assigned','arrived') AND assigned_driver_uid=?"));
check('Self-selection requires an approved online driver', worker.includes('url.pathname === "/orders/respond"') && worker.includes('requireApprovedDriver(request, env, true)'));
check('Self-selection rejects a second active order', worker.includes('Сначала завершите текущий заказ.'));
check('Dispatcher assignment checks driver approval', worker.includes('Number(driver.approved) !== 1'));
check('Dispatcher assignment checks driver online state', worker.includes('Number(driver.online) !== 1'));
check('Dispatcher assignment requires fresh GPS', worker.includes('Назначить можно только водителя на линии с актуальной геолокацией'));
check('Dispatcher assignment atomically excludes active orders', worker.includes("UPDATE orders SET status='driver_assigned'") && worker.includes('NOT EXISTS (SELECT 1 FROM orders active WHERE active.assigned_driver_uid=?') && worker.includes("active.status IN ('driver_assigned','arrived')") && worker.includes('.bind(driverUid, orderId, driverUid, driverUid, assignmentNow - 60, assignmentNow).run()'));
check('Automatic candidate selection requires approved online drivers', worker.includes('d.approved=1 AND d.online=1'));
check('Automatic selection excludes drivers with active orders', worker.includes('active.assigned_driver_uid=r.driver_uid'));
check('Automatic assignment rechecks active-order exclusion', worker.includes("UPDATE orders SET status='driver_assigned'") && worker.includes('NOT EXISTS (SELECT 1 FROM orders active WHERE active.assigned_driver_uid=?') && worker.includes("active.status IN ('driver_assigned','arrived')") && /\.bind\(winner\.driver_uid, assignmentNow, order\.id, assignmentNow, winner\.driver_uid,\s*winner\.driver_uid, assignmentNow - 60, assignmentNow\)\.run\(\)/.test(worker));
check('Automatic assignment only changes new orders', worker.includes("WHERE id=? AND status='new' AND response_deadline<=?"));
check('Trip completion is dispatcher-only', worker.includes('url.pathname === "/orders/complete"') && worker.includes('const auth = await requireDispatcher(request);'));
check('Trip completion requires driver arrival', worker.includes("WHERE id=? AND status='arrived' AND assigned_driver_uid IS NOT NULL"));
check('Trip earnings insert is idempotent', worker.includes('ON CONFLICT(order_id) DO NOTHING'));
check('Trip completion changes status to completed', worker.includes("UPDATE orders SET status='completed'"));
check('Trip completion does not take driver offline', !worker.includes("UPDATE drivers SET online=0 WHERE uid=(SELECT assigned_driver_uid FROM orders"));
check('Driver app polls server orders every five seconds', app.includes('Timer.periodic(const Duration(seconds: 5), (_) {') && app.includes('_pollServerOrders();'));
check('Driver app notifies availability after active order clears', app.includes('hadAssignedOrder && assigned.isEmpty') && app.includes('Вы снова можете принимать заказы'));

check('Driver route requires an assigned order', /_serverAssignedOrders\.isEmpty/.test(app) && /final order = _serverAssignedOrders\.first/.test(app));
check('Driver route requires a valid order identifier', /if \(id\.isEmpty\) return;/.test(app));
check('Pickup latitude is parsed from the server order', /order\['pickup_lat'\]/.test(app));
check('Pickup longitude is parsed from the server order', /order\['pickup_lng'\]/.test(app));
check('Pickup coordinates reject non-finite values', /!lat\.isFinite \|\| !lng\.isFinite/.test(app));
check('Pickup coordinates enforce geographic bounds', /lat < -90 \|\| lat > 90 \|\| lng < -180 \|\| lng > 180/.test(app));
check('Driver approach route runs from driver to pickup', /RouteService\.drivingRoute\(driverPoint, pickup\)/.test(app));
check('Route cache key includes the order identifier', /final routeKey = '\$id:/.test(app));
check('Route cache key includes pickup coordinates', /final routeKey = '[^']*pickup\.latitude\.toStringAsFixed\(5\)/.test(app) && /pickup\.longitude\.toStringAsFixed\(5\)/.test(app));
check('Route cache key includes driver coordinates', /driverPoint\.latitude\.toStringAsFixed\(3\)/.test(app) && /driverPoint\.longitude\.toStringAsFixed\(3\)/.test(app));
check('An unchanged successful route is not requested again', /_driverRouteKey == routeKey && _driverApproachRoute != null/.test(app));
check('Route retries respect the retry cooldown', /_driverRouteRetryAfter != null &&\s*DateTime\.now\(\)\.isBefore\(_driverRouteRetryAfter!\)/.test(app));
check('A previous route is cleared when a new route is requested', /_driverApproachRoute = null;\s*_driverRouteOrderId = id;\s*_driverRouteError = null;/.test(app));
check('Route loading state is published through setState', /setState\(\(\) \{\s*_driverRouteLoading = true;/.test(app));
check('Route response verifies the current driver identity', /TaxiParkState\.currentLoggedInDriver\?\.id != driver\.id/.test(app));
check('Route response verifies the assigned order is unchanged', /_serverOrderId\(_serverAssignedOrders\.first\)\s*;[\s\S]{0,100}if \(latestAssignedId != id\) return;/.test(app));
check('Route response rejects a stale driver GPS position', /if \(latestRouteKey != routeKey\) \{\s*refreshAfterRoute = true;/.test(app));
check('A stale route request is refreshed after GPS movement', /if \(refreshAfterRoute && mounted\)\s*\{\s*unawaited\(_loadDriverApproachRoute\(\)\);/.test(app));
check('Route loading state is reset through setState', /setState\(\(\) => _driverRouteLoading = false\)/.test(app));
check('Driver map draws a route only for its assigned order', /_driverApproachRoute != null &&\s*_serverAssignedOrders\.isNotEmpty &&\s*_driverRouteOrderId ==/.test(app));

check('Passenger route requires an active taxi order', /final order = TaxiParkState\.activeOrder/.test(app) && /order\.status != 'accepted'/.test(app));
check('Passenger route requires an assigned driver', /driverId == null/.test(app));
check('Passenger route requires a valid order identifier', /orderId\.isEmpty/.test(app));
check('Passenger route requires the driver to be online', /!driver\.isOnline/.test(app));
check('Passenger route requires a known GPS timestamp', /gpsAge == null/.test(app));
check('Passenger route rejects stale GPS older than 60 seconds', /gpsAge > 60/.test(app));
check('Passenger route cache includes order and driver identity', /final key = '\$orderId:\$driverId:/.test(app));
check('Passenger route cache includes driver coordinates', /driverPoint\.latitude\.toStringAsFixed\(3\)/.test(app) && /driverPoint\.longitude\.toStringAsFixed\(3\)/.test(app));
check('Passenger route avoids overlapping route requests', /if \(_routeLoading\) return;/.test(app));
check('Passenger route respects retry cooldown', /_routeRetryAfter == null \|\| DateTime\.now\(\)\.isBefore\(_routeRetryAfter!\)/.test(app));
check('Passenger route clears previous line before refresh', /_approachRoute = null;\s*\}\);\s*\}\s*var refreshAfterRoute/.test(app));
check('Passenger route loading state is enabled before request', /_routeLoading = true;\s*_routeError = null;/.test(app));
check('Passenger route starts at taxi and ends at pickup', /RouteService\.drivingRoute\(driverPoint, _pickupPoint\)/.test(app));
check('Passenger route response checks current order identity', /latestOrder\?\.id != orderId/.test(app));
check('Passenger route response checks current driver identity', /latestOrder\?\.assignedDriver\?\.id != driverId/.test(app));
check('Passenger route response is discarded after taxi arrival', /latestOrder\?\.status != 'accepted'/.test(app));
check('Passenger route response rejects outdated GPS coordinates', /if \(latestKey != key\) \{\s*refreshAfterRoute = latestOrder\.status == 'accepted';/.test(app));
check('Passenger route retries after driver moved during request', /unawaited\(_loadApproachRoute\(latestDriver\.currentLocation\)\)/.test(app));
check('Passenger route errors trigger a bounded retry delay', /_routeRetryAfter = DateTime\.now\(\)\.add\(const Duration\(seconds: 30\)\)/.test(app));
check('Passenger map hides road route when GPS is stale', /_approachRoute != null && gpsIsFresh/.test(app));

check("Nearby endpoint requires Firebase authentication", /url\.pathname === "\/drivers\/nearby"[\s\S]{0,100}verifyFirebaseUser\(request\)/.test(worker));
const nearbyEndpointStart = worker.indexOf('if (url.pathname === "/drivers/nearby"');
const nearbyEndpointEnd = worker.indexOf('if (url.pathname === "/orders/open"', nearbyEndpointStart);
const nearbyEndpoint = nearbyEndpointStart >= 0 && nearbyEndpointEnd > nearbyEndpointStart
  ? worker.slice(nearbyEndpointStart, nearbyEndpointEnd)
  : '';
check("Nearby endpoint returns approved drivers only", nearbyEndpoint.includes("FROM drivers d WHERE approved=1"));
check("Nearby endpoint returns online drivers only", nearbyEndpoint.includes("WHERE approved=1 AND online=1"));
check("Nearby endpoint applies GPS age lower bound", /location_updated_at>=\?/.test(worker));
check("Nearby endpoint rejects future GPS timestamps", /location_updated_at<=\?/.test(worker) && /ageSeconds >= 0 && ageSeconds <= 60/.test(worker));
check("Nearby endpoint excludes drivers with active trips", /active\.status IN \('driver_assigned','arrived'\)/.test(worker));
check("Nearby endpoint limits results to 50", /location_updated_at DESC LIMIT 50/.test(worker));
check("Nearby endpoint selects only location fields", /SELECT latitude, longitude, location_updated_at/.test(worker));
check("Nearby endpoint validates GPS records", /filter\(d => hasFreshValidDriverLocation\(d, now\)\)/.test(worker));
check("Flutter API calls the nearby endpoint", /nearbyDrivers\(\) =>\s*_request\('\/drivers\/nearby'\)/.test(api));
check("Passenger stores GPS timestamps with map points", /List<MapEntry<LatLng, DateTime>> _nearbyDriverPoints/.test(app));
check("Passenger loads nearby cars when screen opens", /unawaited\(_refreshNearbyDrivers\(\)\)/.test(app));
check("Passenger refreshes nearby cars every 20 seconds", /Timer\.periodic\(const Duration\(seconds: 20\)/.test(app));
check("Nearby refresh prevents overlapping requests", /_nearbyDriversRequestInProgress\) return/.test(app));
check("Passenger validates latitude and longitude bounds", /lat < -90 \|\| lat > 90 \|\| lng < -180 \|\| lng > 180/.test(app));
check("Passenger rejects stale GPS responses", /!isGpsTimestampFresh\(updatedAt\)/.test(app));
check("Passenger keeps previous markers only until GPS expires", /_nearbyDriverPoints\.removeWhere\([\s\S]{0,100}!isGpsTimestampFresh\(entry\.value\)/.test(app));
check("Nearby request lock is released after completion", /_nearbyDriversRequestInProgress = false;/.test(app));
const nearbyMarkerStart = app.indexOf('_nearbyDriverPoints.map((entry) => Marker(');
const nearbyMarkerBlock = nearbyMarkerStart >= 0 ? app.slice(nearbyMarkerStart, nearbyMarkerStart + 500) : '';
check("Passenger map renders distinct green taxi markers", nearbyMarkerBlock.includes("point: entry.key") && nearbyMarkerBlock.includes("Icons.local_taxi") && nearbyMarkerBlock.includes("Colors.green"));
check("Passenger cancels nearby timer when disposed", /_nearbyDriversTimer\?\.cancel\(\)/.test(app));

 // Dispatcher live fleet map and refresh regression checks.
check("Dispatcher overview supplies driver GPS coordinates", worker.includes("d.latitude, d.longitude, d.location_updated_at"));
check("Dispatcher overview is protected by dispatcher authentication", /url\.pathname === "\/dispatcher\/overview"[\s\S]{0,100}requireDispatcher\(request\)/.test(worker));
check("Dispatcher dashboard refresh timer is configured", app.includes("Timer.periodic(const Duration(seconds: 15)"));
check("Dispatcher refresh runs without replacing the dashboard", app.includes("_load(showLoading: false)"));
check("Dispatcher refresh avoids overlapping requests", app.includes("if (_dispatcherLoadInProgress) return;"));
check("Dispatcher refresh lock is released in finally", app.includes("_dispatcherLoadInProgress = false;"));
check("Dispatcher refresh pauses while an action is running", app.includes("mounted && !_working"));
check("Dispatcher map filters approved drivers", app.includes("if (!approved || !online) continue;") && app.includes("driver['approved']"));
check("Dispatcher map filters online drivers", app.includes("driver['online']"));
check("Dispatcher map parses latitude", app.includes("double.tryParse((driver['latitude'] ?? '').toString())"));
check("Dispatcher map parses longitude", app.includes("double.tryParse((driver['longitude'] ?? '').toString())"));
check("Dispatcher map rejects non-finite coordinates", app.includes("!latitude.isFinite || !longitude.isFinite"));
check("Dispatcher map validates latitude bounds", app.includes("latitude < -90 || latitude > 90"));
check("Dispatcher map validates longitude bounds", app.includes("longitude < -180 || longitude > 180"));
check("Dispatcher map parses GPS update timestamp", app.includes("parseGpsTimestamp(driver['location_updated_at'])"));
check("Dispatcher map hides stale GPS positions", app.includes("!isGpsTimestampFresh(updatedAt)"));
check("Dispatcher map creates markers from validated coordinates", app.includes("point: LatLng(latitude, longitude)"));
check("Dispatcher map uses green taxi markers", app.includes("Icons.local_taxi, color: Colors.green"));
check("Dispatcher map uses the configured OpenStreetMap layer", app.includes("https://tile.openstreetmap.de/{z}/{x}/{y}.png"));
check("Dispatcher refresh timer is cancelled on dispose", app.includes("_dispatcherRefreshTimer?.cancel()"));

 // Dispatcher background refresh resilience and fleet map centering checks.
check("Dispatcher keeps a separate background refresh error state", app.includes("String? _dispatcherRefreshError;"));
check("Dispatcher clears refresh error after successful overview load", app.includes("_dispatcherRefreshError = null;"));
check("Foreground dispatcher load still reports authentication and initial load errors", app.includes("if (showLoading) {") && app.includes("_error = e.toString();"));
check("Background refresh failure does not replace the full-screen error state", app.includes("_dispatcherRefreshError = e.toString();"));
check("Background refresh failure preserves the last loaded driver data", /else \{\s*_dispatcherRefreshError = e\.toString\(\);\s*\}/.test(app));
check("Dispatcher shows a non-blocking offline refresh notice", app.includes("Показаны последние загруженные данные"));
check("Dispatcher refresh notice can be dismissed", app.includes("onPressed: () => setState(() => _dispatcherRefreshError = null)"));
check("Dispatcher refresh still retries on its periodic timer", app.includes("Timer.periodic(const Duration(seconds: 15)"));
check("Dispatcher load lock still prevents overlapping refresh calls", app.includes("if (_dispatcherLoadInProgress) return;"));
check("Dispatcher load lock is released even after request errors", app.includes("_dispatcherLoadInProgress = false;"));
check("Dispatcher fleet map falls back to Sulyukta when no fresh cars exist", app.includes("markers.isEmpty") && app.includes("TaxiParkState.sulyuktaCenter"));
check("Dispatcher fleet map calculates latitude center from fresh markers", app.includes("marker.point.latitude).reduce"));
check("Dispatcher fleet map calculates longitude center from fresh markers", app.includes("marker.point.longitude).reduce"));
check("Dispatcher fleet map averages coordinates for initial center", app.includes("initialCenter: center"));
check("Dispatcher fleet map chooses a zoom level for broad service areas", app.includes("latitudeSpan > 0.5 || longitudeSpan > 0.5"));
check("Dispatcher fleet map uses a regional zoom for medium spread", app.includes("latitudeSpan > 0.1 || longitudeSpan > 0.1"));
check("Dispatcher map centering only uses already validated markers", app.includes("final center = markers.isEmpty"));
check("Dispatcher map continues to exclude stale GPS before calculating center", app.includes("!isGpsTimestampFresh(updatedAt)"));
check("Dispatcher map retains the configured OSM tile layer", app.includes("https://tile.openstreetmap.de/{z}/{x}/{y}.png"));
check("Dispatcher refresh timer is still cancelled on dispose", app.includes("_dispatcherRefreshTimer?.cancel()"));


 // Atomic eligibility rechecks: a driver must still be online with fresh GPS at commit time.
const dispatcherAssignStart = worker.indexOf('if (url.pathname === "/orders/assign" && request.method === "POST")');
const dispatcherAssignEnd = worker.indexOf('if (url.pathname === "/drivers/online" && request.method === "POST")', dispatcherAssignStart);
const dispatcherAssignBlock = dispatcherAssignStart >= 0 && dispatcherAssignEnd > dispatcherAssignStart
  ? worker.slice(dispatcherAssignStart, dispatcherAssignEnd) : '';
const automaticAssignStart = worker.indexOf('const winner = candidates[0];');
const automaticAssignEnd = worker.indexOf('if (Number(assigned.meta?.changes || 0) === 1)', automaticAssignStart);
const automaticAssignBlock = automaticAssignStart >= 0 && automaticAssignEnd > automaticAssignStart
  ? worker.slice(automaticAssignStart, automaticAssignEnd) : '';
check('Dispatcher assignment captures one timestamp for its GPS freshness decision', dispatcherAssignBlock.includes('const assignmentNow = Math.floor(Date.now() / 1000);'));
check('Dispatcher assignment validates GPS against that timestamp', dispatcherAssignBlock.includes('hasFreshValidDriverLocation(driver, assignmentNow)'));
check('Dispatcher assignment rechecks the driver inside the atomic order update', dispatcherAssignBlock.includes('EXISTS (SELECT 1 FROM drivers current_driver'));
check('Atomic dispatcher assignment requires approved driver state', dispatcherAssignBlock.includes('current_driver.approved=1'));
check('Atomic dispatcher assignment requires online driver state', dispatcherAssignBlock.includes('current_driver.online=1'));
check('Atomic dispatcher assignment rejects invalid latitude', dispatcherAssignBlock.includes('current_driver.latitude BETWEEN -90 AND 90'));
check('Atomic dispatcher assignment rejects invalid longitude', dispatcherAssignBlock.includes('current_driver.longitude BETWEEN -180 AND 180'));
check('Atomic dispatcher assignment rejects missing or stale GPS timestamp', dispatcherAssignBlock.includes('current_driver.location_updated_at BETWEEN ? AND ?'));
check('Atomic dispatcher assignment uses the 60-second GPS lower bound', dispatcherAssignBlock.includes('assignmentNow - 60, assignmentNow'));
check('Atomic dispatcher assignment retains active-trip exclusion', dispatcherAssignBlock.includes("active.status IN ('driver_assigned','arrived')"));
check('Atomic dispatcher assignment only updates new orders', dispatcherAssignBlock.includes("WHERE id=? AND status='new'"));
check('Automatic assignment captures a fresh timestamp immediately before update', automaticAssignBlock.includes('const assignmentNow = Math.floor(Date.now() / 1000);'));
check('Automatic assignment rechecks the winner driver inside its atomic update', automaticAssignBlock.includes('EXISTS (SELECT 1 FROM drivers current_driver'));
check('Atomic automatic assignment requires approved driver state', automaticAssignBlock.includes('current_driver.approved=1'));
check('Atomic automatic assignment requires online driver state', automaticAssignBlock.includes('current_driver.online=1'));
check('Atomic automatic assignment rejects invalid latitude', automaticAssignBlock.includes('current_driver.latitude BETWEEN -90 AND 90'));
check('Atomic automatic assignment rejects invalid longitude', automaticAssignBlock.includes('current_driver.longitude BETWEEN -180 AND 180'));
check('Atomic automatic assignment enforces the fresh GPS time window', automaticAssignBlock.includes('current_driver.location_updated_at BETWEEN ? AND ?'));
check('Atomic automatic assignment preserves the active-trip exclusion', automaticAssignBlock.includes("active.status IN ('driver_assigned','arrived')"));
check('Atomic automatic assignment still requires the order response deadline', automaticAssignBlock.includes("response_deadline<=?"));


 // Reuse dispatcherAssignBlock and automaticAssignBlock extracted above so the
 // structural assertions inspect the same route sections without redeclaring constants.
const dispatcherUpdateStart = dispatcherAssignBlock.indexOf("UPDATE orders SET status='driver_assigned'");
const dispatcherUpdateEnd = dispatcherAssignBlock.indexOf('.run();', dispatcherUpdateStart);
const dispatcherUpdate = dispatcherUpdateStart >= 0 && dispatcherUpdateEnd > dispatcherUpdateStart ? dispatcherAssignBlock.slice(dispatcherUpdateStart, dispatcherUpdateEnd + 6) : '';
const autoUpdateStart = worker.indexOf('const winner = candidates[0];');
const autoUpdateEnd = worker.indexOf('if (Number(assigned.meta?.changes || 0) === 1)', autoUpdateStart);
const autoUpdate = autoUpdateStart >= 0 && autoUpdateEnd > autoUpdateStart ? worker.slice(autoUpdateStart, autoUpdateEnd) : '';
check('Dispatcher atomic update is isolated for structural checks', dispatcherUpdate.includes("UPDATE orders SET status='driver_assigned'"));
check('Dispatcher atomic update contains both eligibility and active-order guards', dispatcherUpdate.includes('NOT EXISTS (SELECT 1 FROM orders active') && dispatcherUpdate.includes('EXISTS (SELECT 1 FROM drivers current_driver'));
check('Dispatcher active-order guard matches the same driver UID', /active\.assigned_driver_uid=\?/.test(dispatcherUpdate));
check('Dispatcher active-order guard blocks driver_assigned status', dispatcherUpdate.includes("'driver_assigned'"));
check('Dispatcher active-order guard blocks arrived status', dispatcherUpdate.includes("'arrived'"));
check('Dispatcher driver recheck uses the same UID as the assignment', /current_driver\.uid=\?/.test(dispatcherUpdate));
check('Dispatcher update binds six SQL parameters', (dispatcherUpdate.match(/\?/g) || []).length === 6);
check('Dispatcher update binds assigned driver first', dispatcherUpdate.includes('.bind(driverUid, orderId, driverUid, driverUid, assignmentNow - 60, assignmentNow)'));
check('Dispatcher update binds order ID second', dispatcherUpdate.includes('.bind(driverUid, orderId,'));
check('Dispatcher update binds active driver UID third', dispatcherUpdate.includes('.bind(driverUid, orderId, driverUid,'));
check('Dispatcher update binds eligibility UID fourth', dispatcherUpdate.includes('.bind(driverUid, orderId, driverUid, driverUid,'));
check('Dispatcher update binds lower GPS age bound before upper bound', dispatcherUpdate.includes('assignmentNow - 60, assignmentNow).run()'));
check('Automatic update is isolated for structural checks', autoUpdate.includes("UPDATE orders SET status='driver_assigned'"));
check('Automatic update contains both eligibility and active-order guards', autoUpdate.includes('NOT EXISTS (SELECT 1 FROM orders active') && autoUpdate.includes('EXISTS (SELECT 1 FROM drivers current_driver'));
check('Automatic active-order guard matches the winning driver UID', /active\.assigned_driver_uid=\?/.test(autoUpdate));
check('Automatic update binds eight SQL parameters', (autoUpdate.match(/\?/g) || []).length === 8);
check('Automatic update binds the winner as assigned driver', autoUpdate.includes('.bind(winner.driver_uid, assignmentNow,'));
check('Automatic update binds the winner to the active-order guard', autoUpdate.includes('order.id, assignmentNow, winner.driver_uid,'));
check('Automatic update binds the winner again to driver eligibility', /\.bind\(winner\.driver_uid, assignmentNow, order\.id, assignmentNow, winner\.driver_uid,\s*winner\.driver_uid, assignmentNow - 60, assignmentNow\)\.run\(\)/.test(autoUpdate));
check('Automatic update binds fresh GPS bounds as the final parameters', autoUpdate.includes('assignmentNow - 60, assignmentNow).run()'));


 // Driver online/offline and post-trip availability regression coverage.
const driverOnlineStart = worker.indexOf('if (url.pathname === "/drivers/online" && request.method === "POST")');
const driverOnlineEnd = worker.indexOf('if (url.pathname === "/orders/publish" && request.method === "POST")', driverOnlineStart);
const driverOnlineBlock = driverOnlineStart >= 0 && driverOnlineEnd > driverOnlineStart
  ? worker.slice(driverOnlineStart, driverOnlineEnd) : '';
check('Driver online endpoint requires an approved driver', driverOnlineBlock.includes('requireApprovedDriver(request, env)'));
check('Driver online endpoint accepts only a boolean state', driverOnlineBlock.includes('typeof b.online !== "boolean"'));
check('Driver online endpoint requires paired GPS coordinates', driverOnlineBlock.includes('hasLatitude !== hasLongitude'));
check('Driver cannot go online without both GPS coordinates', driverOnlineBlock.includes('(b.online && (!hasLatitude || !hasLongitude))'));
check('Driver latitude must be finite and geographically valid', driverOnlineBlock.includes('!Number.isFinite(b.latitude)') && driverOnlineBlock.includes('b.latitude < -90 || b.latitude > 90'));
check('Driver longitude must be finite and geographically valid', driverOnlineBlock.includes('!Number.isFinite(b.longitude)') && driverOnlineBlock.includes('b.longitude < -180 || b.longitude > 180'));
check('Driver online state is persisted as a numeric flag', driverOnlineBlock.includes('const online = b.online ? 1 : 0'));
check('Driver location update preserves coordinates when none are supplied', driverOnlineBlock.includes('latitude=COALESCE(?,latitude)') && driverOnlineBlock.includes('longitude=COALESCE(?,longitude)'));
check('GPS freshness timestamp changes only with a complete coordinate pair', driverOnlineBlock.includes('location_updated_at=CASE WHEN ? IS NOT NULL AND ? IS NOT NULL THEN unixepoch()'));
check('Driver online update binds the authenticated UID, requested state, and active-trip guard', driverOnlineBlock.includes('.bind(online, lat, lng, lat, lng, auth.user.localId, online, auth.user.localId).run()'));
check('Flutter online API requires both GPS coordinates when online', api.includes('(online && latitude == null)'));
check('Flutter online API rejects non-finite and out-of-range GPS', api.includes('!latitude.isFinite') && api.includes('!longitude.isFinite') && api.includes('latitude < -90') && api.includes('longitude > 180'));
check('Driver GPS stream failure marks the driver offline', app.includes('Stop advertising an old position as live while GPS is unavailable.') && app.includes('WorkerApi.setDriverOnline(online: false)'));
check('Driver heartbeat failure marks the driver offline', app.includes('Do not keep the driver advertised as online when fresh GPS cannot be confirmed.') && app.includes('WorkerApi.setDriverOnline(online: false)'));
check('Leaving the live driver screen marks the driver offline', /void dispose\(\) \{[\s\S]{0,300}WorkerApi\.setDriverOnline\(online: false\)/.test(app));
check('Driver order polling runs every five seconds', app.includes('Timer.periodic(const Duration(seconds: 5), (_) {') && app.includes('_pollServerOrders();'));
check('Open-order endpoint requires an approved online driver', worker.includes('url.pathname === "/orders/open"') && worker.includes('requireApprovedDriver(request, env, true)'));
check('Open-order query returns only unassigned new orders', worker.includes("FROM orders o WHERE status='new'"));
check('Open-order query excludes a driver with an active assigned trip', worker.includes("active.assigned_driver_uid=?") && worker.includes("active.status IN ('driver_assigned','arrived')"));
check('Driver sees availability again after the active order disappears', app.includes('hadAssignedOrder && assigned.isEmpty') && app.includes('Вы снова можете принимать заказы.'));

check('Driver screen keeps a user-controlled desired availability state with offline as the safe default', app.includes('bool _driverWantsOnline = false;'));
check('Driver screen exposes a guarded availability control in the app bar', app.includes('onPressed: _availabilityChanging ? null : _toggleDriverAvailability'));
check('Availability control labels the online action as going offline', app.includes("!_driverWantsOnline\n                ? 'Выйти на линию'"));
check('Availability control uses distinct online and offline icons', app.includes('Icons.toggle_on') && app.includes('Icons.toggle_off'));
check('Driver availability toggle refuses to go offline during an active assigned order', app.includes('if (_serverAssignedOrders.isNotEmpty)') && app.includes('Сначала завершите активный заказ.'));
check('Going offline updates the local desired state before network work', app.includes('_driverWantsOnline = false;'));
check('Going offline clears stale open-order offers', app.includes('_serverOpenOrders = [];'));
check('Going offline cancels a pending GPS retry', app.includes('_locationRetryTimer?.cancel();'));
check('Going offline cancels the GPS stream', app.includes('await _positionSubscription?.cancel();'));
check('Going offline stops the GPS heartbeat', app.includes('_stopLocationHeartbeat();'));
check('Going offline is persisted through the Worker API', app.includes('await WorkerApi.setDriverOnline(online: false);'));
check('Going online restarts GPS tracking', app.includes('_driverWantsOnline = true;') && app.includes('await _startLocationTracking();'));
check('Offline drivers do not poll for new orders', app.includes('if (!mounted || !_driverWantsOnline || _ordersPollInProgress) return;'));
check('GPS retry scheduling requires desired online state', app.includes('if (!mounted || !_driverWantsOnline || _locationRetryTimer?.isActive == true) return;'));
check('GPS retry callback rechecks desired online state', app.includes('if (mounted && _driverWantsOnline) unawaited(_startLocationTracking());'));
check('GPS tracking startup requires desired online state', app.includes('driver == null || !mounted || !_driverWantsOnline || _locationTrackingStarting'));
check('GPS stream ignores updates after the driver goes offline', app.includes('if (!mounted || !_driverWantsOnline) return;'));
check('Heartbeat refresh requires desired online state', app.includes('if (!mounted || !_driverWantsOnline || _positionSubscription == null'));
check('GPS publication refuses to advertise an offline driver', app.includes('if (!mounted || !_driverWantsOnline || _locationUpdateInProgress'));
check('An in-flight GPS publication restores offline state after a concurrent opt-out', app.includes('If the driver switched off while this request was in flight') && app.includes('await WorkerApi.setDriverOnline(online: false);'));

check('Driver availability restores its initial value from the authenticated server profile', app.includes("_driverWantsOnline = TaxiParkState.currentLoggedInDriver?.isOnline ?? false;"));
check('An offline driver does not start GPS automatically after reopening the driver screen', app.includes('if (_driverWantsOnline) {\n      _startLocationTracking();'));
check('An offline driver does not fetch new orders on initial screen load', app.includes('if (_driverWantsOnline) {\n      _startLocationTracking();\n      unawaited(_pollServerOrders());'));
check('The five-second order timer remains available for later online transitions', app.includes("_ordersPollTimer = Timer.periodic(const Duration(seconds: 5)"));
check('Availability changes have a dedicated in-progress lock', app.includes('bool _availabilityChanging = false;'));
check('Rapid repeated availability taps are ignored while a change is running', app.includes('if (!mounted || _availabilityChanging) return;'));
check('The availability button is disabled during a state transition', app.includes('onPressed: _availabilityChanging ? null : _toggleDriverAvailability'));
check('The driver sees a clear online status label', app.includes("_driverGpsReady ? 'На линии' : 'GPS не подтверждён'") && app.includes("'Не на линии'"));
check('The driver sees a waiting label while the state is changing', app.includes("? 'Подождите…'"));
check('The status control retains an explanatory tooltip', app.includes("message: !_driverWantsOnline") && app.includes("'Отменить выход на линию'"));
check('Availability transition lock is always released after completion', app.includes('finally {\n      if (mounted) setState(() => _availabilityChanging = false);'));
check('Online transition still starts location tracking', app.includes('await _startLocationTracking();'));
check('Online transition refreshes server orders after GPS startup', app.includes('if (mounted) unawaited(_pollServerOrders());'));
check('Offline transition clears server open-order offers', app.includes('_serverOpenOrders = [];'));
check('Offline transition cancels the GPS retry timer', app.includes('_locationRetryTimer?.cancel();'));
check('Offline transition cancels the location subscription before returning', app.includes('await _positionSubscription?.cancel();'));
check('GPS startup checks desired state after the initial position lookup', app.includes('if (!mounted || !_driverWantsOnline) return;\n      if (!_isUsableDriverPosition(firstPosition))'));
check('GPS startup checks desired state after server location publication', app.includes('if (!mounted || !_driverWantsOnline) return;\n      if (!published)'));
check('GPS startup rejects an unconfirmed online publication', app.includes("throw StateError('Не удалось подтвердить выход на линию на сервере.')"));
check('Driver profile restoration continues to use the server online flag', app.includes("isOnline: _isEnabled(data['online'])"));

check('Offline state retry timer is declared', app.includes('Timer? _offlineSyncRetryTimer;'));
check('Offline state retry lock is declared', app.includes('bool _offlineSyncInProgress = false;'));
check('Offline retry is scheduled after ten seconds', app.includes('Timer(const Duration(seconds: 10)'));
check('Offline retry stops if driver wants online', app.includes('if (!mounted || _driverWantsOnline || _offlineSyncInProgress) return;'));
check('Offline retry calls Worker API', app.includes('final result = await WorkerApi.setDriverOnline(online: false);'));
check('Offline retry verifies false server response', app.includes("result['online'] != false"));
check('Offline retry reschedules after request failure', app.includes('_scheduleOfflineStateRetry();'));
check('Offline retry clears timer after confirmation', app.includes('_offlineSyncRetryTimer?.cancel();'));
check('Manual offline failure informs user of retry', app.includes('Приложение повторит отключение автоматически.'));
check('Manual offline transition validates server response', app.includes('Сервер не подтвердил отключение водителя.'));
check('Going online cancels pending offline retry', app.includes('_offlineSyncRetryTimer?.cancel();\n        _offlineSyncRetryTimer = null;\n        setState(() {\n          _driverWantsOnline = true;'));
check('Availability change is blocked during offline sync', app.includes('if (_offlineSyncInProgress) {'));
check('Offline retry timer is cancelled on dispose', app.includes('_offlineSyncRetryTimer?.cancel();'));
check('Offline retry uses a dedicated async method', app.includes('Future<void> _retryOfflineStateSync() async'));
check('Offline retry lock releases in finally', app.includes('_offlineSyncInProgress = false;'));
check('Manual offline state clears order offers', app.includes('_driverWantsOnline = false;'));
check('Offline retry method is separate from GPS startup', !app.slice(app.indexOf('Future<void> _retryOfflineStateSync'), app.indexOf('Future<void> _toggleDriverAvailability')).includes('_startLocationTracking'));
check('Offline retry has mounted guard', app.includes('if (!mounted || _driverWantsOnline || _offlineSyncInProgress) return;'));
check('GPS retry timer remains separate', app.includes('Timer? _locationRetryTimer;') && app.includes('Timer? _offlineSyncRetryTimer;'));
check('Offline retry timer is cleared before returning online', app.includes('_offlineSyncRetryTimer = null;'));


// Server-side driver availability must remain consistent with active-trip rules.
const onlineRouteStart = worker.indexOf('if (url.pathname === "/drivers/online" && request.method === "POST")');
const onlineRouteEnd = worker.indexOf('if (url.pathname === "/orders/publish" && request.method === "POST")', onlineRouteStart);
const onlineRoute = onlineRouteStart >= 0 && onlineRouteEnd > onlineRouteStart
  ? worker.slice(onlineRouteStart, onlineRouteEnd) : '';
check('Driver online route authenticates an approved driver', onlineRoute.includes('requireApprovedDriver(request, env)'));
check('Driver online route validates the requested boolean state', onlineRoute.includes('typeof b.online !== "boolean"'));
check('Driver online route rejects unpaired GPS coordinates', onlineRoute.includes('hasLatitude !== hasLongitude'));
check('Driver online route requires GPS before going online', onlineRoute.includes('(b.online && (!hasLatitude || !hasLongitude))'));
check('Driver online route validates finite latitude and longitude', onlineRoute.includes('!Number.isFinite(b.latitude)') && onlineRoute.includes('!Number.isFinite(b.longitude)'));
check('Driver online route enforces latitude bounds', onlineRoute.includes('b.latitude < -90 || b.latitude > 90'));
check('Driver online route enforces longitude bounds', onlineRoute.includes('b.longitude < -180 || b.longitude > 180'));
check('Driver state update is scoped to the authenticated UID', onlineRoute.includes('WHERE uid=? AND approved=1'));
check('Driver state update rechecks approval atomically', onlineRoute.includes('WHERE uid=? AND approved=1'));
check('Driver state update allows going online only with approved state', onlineRoute.includes('AND (?=1 OR NOT EXISTS'));
check('Driver offline update is blocked by an active assigned trip', onlineRoute.includes('NOT EXISTS (') && onlineRoute.includes('active.assigned_driver_uid=?'));
check('Driver offline update blocks driver_assigned trips', onlineRoute.includes("active.status IN ('driver_assigned','arrived')"));
check('Driver offline update blocks arrived trips', onlineRoute.includes("'driver_assigned','arrived'"));
check('Online state can bypass only the offline active-trip guard', onlineRoute.includes('(?=1 OR NOT EXISTS'));
check('Driver location coordinates are preserved when omitted', onlineRoute.includes('latitude=COALESCE(?,latitude)') && onlineRoute.includes('longitude=COALESCE(?,longitude)'));
check('GPS freshness timestamp changes only with a complete coordinate pair', onlineRoute.includes('location_updated_at=CASE WHEN ? IS NOT NULL AND ? IS NOT NULL THEN unixepoch()'));
check('Driver online update checks the database affected-row count', onlineRoute.includes('Number(result.meta.changes || 0) !== 1'));
check('Unapplied driver state transitions return HTTP 409', onlineRoute.includes('}, 409);'));
check('Failed driver state transition does not return success', onlineRoute.includes('if (!result.meta || Number(result.meta.changes || 0) !== 1)'));
check('Successful response reports the requested persisted online state', onlineRoute.includes('return response({ status: "ok", online: !!online });'));


// The driver-facing line label must reflect a confirmed, fresh GPS publication.
check('Driver GPS readiness has a dedicated state separate from line intent', app.includes('bool _driverGpsReady = false;'));
check('GPS readiness helper updates the driver model online flag', app.includes('if (driver != null) driver.isOnline = ready;'));
check('GPS readiness helper avoids setState after disposal', app.includes('if (!mounted || _driverGpsReady == ready) return;'));
check('Starting a new GPS session clears stale readiness', app.includes('_locationTrackingStarting = true;') && app.includes('_setDriverGpsReady(false);'));
check('GPS readiness becomes true only after server location publication succeeds', app.includes('Не удалось подтвердить выход на линию на сервере.') && app.includes('_setDriverGpsReady(true);'));
check('GPS stream publication result updates the readiness indicator', app.includes('_publishDriverLocation(driver).then<void>((published) {') && app.includes('_setDriverGpsReady(published);'));
check('GPS stream errors clear readiness', app.includes('onError: (Object error) {') && app.includes('_setDriverGpsReady(false);'));
check('Heartbeat success confirms GPS readiness', app.includes('Не удалось обновить геолокацию на сервере.') && app.includes('_setDriverGpsReady(true);'));
check('Heartbeat failure clears GPS readiness', app.includes('_setDriverGpsReady(false);') && app.includes('_scheduleLocationRetry();'));
check('GPS startup failure clears GPS readiness', app.includes('_setDriverGpsReady(false);') && app.includes('Не удалось включить геолокацию: $e'));
check('Manual offline transition clears GPS readiness', app.includes('_driverWantsOnline = false;') && app.includes('_driverGpsReady = false;'));
check('Manual online transition begins with unconfirmed GPS readiness', app.includes('_driverWantsOnline = true;') && app.includes('_driverGpsReady = false;'));
check('Driver UI no longer equates line intent with confirmed online status', app.includes("_driverGpsReady ? 'На линии' : 'GPS не подтверждён'"));
check('Driver UI shows a GPS-specific icon before location confirmation', app.includes('_driverGpsReady ? Icons.toggle_on : Icons.gps_not_fixed'));
check('Driver tooltip distinguishes pending GPS from confirmed online state', app.includes("_driverGpsReady ? 'Выйти с линии' : 'Отменить выход на линию'"));
check('Driver availability label closes its nested Text expression', app.includes(": (_driverGpsReady ? 'На линии' : 'GPS не подтверждён'))),"));
check('GPS readiness remains independent of desired online intent', app.includes('bool _driverWantsOnline = false;') && app.includes('bool _driverGpsReady = false;'));
check('Location retry can leave the line label unconfirmed until server acknowledgement', app.includes('_setDriverGpsReady(false);') && app.includes('Future<void> _startLocationTracking() async'));
check('A fresh successful stream update can restore the line label', app.includes('_setDriverGpsReady(published);'));
check('A successful heartbeat can restore the line label after reconnect', app.includes('_setDriverGpsReady(true);'));
check('Offline status is not falsely presented as GPS-confirmed', app.includes("? 'Не на линии'") && app.includes("'GPS не подтверждён'"));
for (const item of checks) {
  process.stdout.write(`${item.ok ? 'PASS' : 'FAIL'}  ${item.label}\n`);
}
const failed = checks.filter((item) => !item.ok);
process.stdout.write(`\nPreflight: ${checks.length - failed.length}/${checks.length} checks passed.\n`);
if (failed.length) process.exitCode = 1;
