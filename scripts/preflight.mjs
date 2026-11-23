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
check('Dispatcher assignment atomically excludes active orders', worker.includes("active.status IN ('driver_assigned','arrived')") && worker.includes('.bind(driverUid, orderId, driverUid).run()'));
check('Automatic candidate selection requires approved online drivers', worker.includes('d.approved=1 AND d.online=1'));
check('Automatic selection excludes drivers with active orders', worker.includes('active.assigned_driver_uid=r.driver_uid'));
check('Automatic assignment rechecks active-order exclusion', worker.includes('.bind(winner.driver_uid, now, order.id, now, winner.driver_uid).run()'));
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

for (const item of checks) {
  process.stdout.write(`${item.ok ? 'PASS' : 'FAIL'}  ${item.label}\n`);
}
const failed = checks.filter((item) => !item.ok);
process.stdout.write(`\nPreflight: ${checks.length - failed.length}/${checks.length} checks passed.\n`);
if (failed.length) process.exitCode = 1;
