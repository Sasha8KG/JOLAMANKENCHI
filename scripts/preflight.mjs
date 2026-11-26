import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const checks = [];
function check(label, condition) {
  checks.push({ label, ok: Boolean(condition) });
}

// Check ordered source fragments without fragile multiline regular expressions.
function containsInOrder(source, fragments) {
  let offset = 0;
  for (const fragment of fragments) {
    const found = source.indexOf(fragment, offset);
    if (found < 0) return false;
    offset = found + fragment.length;
  }
  return true;
}

const pubspec = read('testapp/pubspec.yaml');
const gradle = read('testapp/android/app/build.gradle');
const manifest = read('testapp/android/app/src/main/AndroidManifest.xml');
const firebase = JSON.parse(read('testapp/android/app/google-services.json'));
const worker = read('backend/cloudflare-worker/worker.js');
const api = read('testapp/lib/services/worker_api.dart');
const gps = read('testapp/lib/services/gps_freshness.dart');
const gpsPolicy = read('testapp/lib/services/gps_fix_policy.dart');
const gpsPolicyTests = read('testapp/test/gps_fix_policy_test.dart');
const refreshGate = read('testapp/lib/services/refresh_gate.dart');
const orderSnapshot = read('testapp/lib/services/server_order_snapshot.dart');
const orderSnapshotTests = read('testapp/test/server_order_snapshot_test.dart');
const app = read('testapp/lib/main.dart');
const localization = read('testapp/lib/services/taxi_localization.dart');
const registration = read('testapp/lib/driver_registration_screen.dart');
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
check('Driver no-show cancellation is allowed only after arrival', worker.includes('if (order.status === "arrived")') && worker.includes("status='cancelled_by_driver_no_show'"));
check('Driver no-show cancellation validates three explicit reasons', ['customer_not_found', 'customer_unreachable', 'customer_left_with_other_car'].every((reason) => worker.includes(reason)));
check('Driver no-show cancellation is scoped to assigned driver and arrived order', worker.includes("WHERE id=? AND assigned_driver_uid=? AND status='arrived'"));
check('Driver no-show cancellation excludes orders already recorded in trip finance', worker.includes('NOT EXISTS (SELECT 1 FROM trip_finances WHERE order_id=orders.id)'));
check('Driver no-show cancellation records zero earnings', worker.includes('earned_som: 0'));
check('No-show cancellation does not force driver offline', !worker.includes("UPDATE drivers SET online=0 WHERE uid=(SELECT assigned_driver_uid FROM orders"));
check('Flutter API validates no-show cancellation reason codes', api.includes('allowedReasons') && api.includes("'customer_left_with_other_car'"));
check('Driver UI no longer requires an arrival step before order completion', !app.includes('_markAssignedOrderArrived') && !app.includes('_cancelArrivedNoShowOrder') && app.includes("russian: 'ЗАКАЗ ИСПОЛНЕН'"));
check('Driver UI does not expose obsolete arrival/no-show stages', !app.includes('ПАССАЖИР НЕ ВЫШЕЛ') && !app.includes('НЕ ОТВЕЧАЕТ') && !app.includes('УЕХАЛ НА ДРУГОЙ МАШИНЕ'));
check('Driver order completion refreshes assigned and open orders', app.includes('WorkerApi.completeDriverOrder') && app.includes('await _pollServerOrders();'));
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
check('Android launcher uses the modern gold taxi location emblem', read('testapp/android/app/src/main/res/drawable/ic_launcher_kyrgyz.xml').includes('android:fillColor="#073B32"') && read('testapp/android/app/src/main/res/drawable/ic_launcher_kyrgyz.xml').includes('android:fillColor="#FFC928"') && read('testapp/android/app/src/main/res/drawable/ic_launcher_kyrgyz.xml').includes('M54,15c-17.1'));

check('Order snapshot parser rejects partial, duplicate and contradictory responses',
  orderSnapshot.includes("rawOpen is! List || rawAssigned is! List") &&
  orderSnapshot.includes("!seen.add(id)") &&
  orderSnapshot.includes("openIds.contains(order['id'])"));
check('Order snapshot parser limits free offers to Worker page size',
  orderSnapshot.includes('maxOpenOrders = 100') && orderSnapshot.includes('rawOpen.length > maxOpenOrders'));
check('Order snapshot tests cover malformed, duplicate, status and overlap cases',
  ['rejects non-map order entries', 'rejects duplicate free order ids',
   'rejects more than one assigned order', 'rejects the same order appearing in both lists',
   'returns unmodifiable snapshot lists'].every(label => orderSnapshotTests.includes(label)));
check('Driver clears stale offers and route after approval is denied',
  app.includes('_driverAccessWarningShown') &&
  app.includes('_serverOpenOrders = [];') &&
  app.includes('_driverApproachRoute = null;'));
check('Open orders require an approved online driver', worker.includes('url.pathname === "/orders/open"') && worker.includes('requireApprovedDriver(request, env, true)'));
check('Open offers exclude drivers with an active order', worker.includes("active.assigned_driver_uid=?") && worker.includes("active.status IN ('driver_assigned','arrived')"));
check('Assigned orders are limited to active states', worker.includes("status IN ('driver_assigned','arrived') AND assigned_driver_uid=?"));
check('Self-selection requires an approved online driver', worker.includes('url.pathname === "/orders/respond"') && worker.includes('requireApprovedDriver(request, env, true)'));
check('Self-selection rejects a second active order', worker.includes('Сначала завершите текущий заказ.'));
check('Dispatcher overview reports each driver active order for safe assignment filtering', worker.includes('AS active_order_id') && worker.includes("active.status IN ('driver_assigned','arrived')"));
check('Dispatcher assignment picker excludes unapproved, offline, busy, stale-GPS and invalid-coordinate drivers', app.includes('_driverCanReceiveAssignment') && app.includes("driver['active_order_id']") && app.includes('isGpsTimestampFresh(gpsUpdatedAt)') && app.includes('latitude.isFinite && longitude.isFinite'));
check('Dispatcher assignment validates the selected driver again after the dialog closes', app.includes('final selectedDriver = _drivers.firstWhere(') && app.includes('if (!_driverCanReceiveAssignment(selectedDriver))'));
check('Dispatcher assignment rejects malformed or stale order IDs before opening the picker', app.includes('final orderId = (order[\'id\'] ?? \'\').toString().trim()') && app.includes('orderId.length > 128'));
check('Dispatcher explains when no approved driver is eligible for a new assignment', app.includes('Нет свободных водителей на линии с актуальной геолокацией') && app.includes('Нет одобренных водителей.'));
check('Dispatcher assignment uses the validated order ID and confirmed driver UID', app.includes('WorkerApi.assignOrder(orderId: orderId, driverUid: confirmed)'));
check('Dispatcher driver choices are labeled as online and GPS-eligible', app.includes(' · на линии'), worker.includes('AS active_order_id'));
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
check('Driver route requires a fresh local GPS timestamp',
  app.includes('if (!isGpsTimestampFresh(driver.locationUpdatedAt))') &&
  app.includes('Ожидаем свежие координаты GPS'));
check('Driver GPS timestamp is updated from the initial fix, stream and heartbeat',
  app.includes('driver.locationUpdatedAt = firstPosition.timestamp;') &&
  app.includes('driver.locationUpdatedAt = position.timestamp;') &&
  app.includes('_driverRouteRetryAfter = null;'));
check('Route response verifies the current driver identity', /TaxiParkState\.currentLoggedInDriver\?\.id != driver\.id/.test(app));
check('Route response verifies the assigned order is unchanged', /final latestAssignedId = _serverAssignedOrders\.isEmpty[\s\S]{0,120}if \(latestAssignedId != id\) \{\s*refreshAfterRoute = latestAssignedId\.isNotEmpty;\s*return;/.test(app));
check('Route response rejects a stale driver GPS position', /if \(latestRouteKey != routeKey\) \{\s*refreshAfterRoute = latestRouteKey != null;\s*return;/.test(app));
check('Driver order polling requires both server order arrays', orderSnapshot.includes('if (rawOpen is! List || rawAssigned is! List)'));
check('Driver order polling preserves previous data when the response is malformed', app.includes('final snapshot = ServerOrderSnapshot.parse(data);') && app.includes('catch (_) {') && app.includes('A transient network error is retried by the next scheduled poll.'));
check('Driver order IDs are restricted to safe 1-128 character identifiers', app.includes("RegExp(r'^[A-Za-z0-9_-]{1,128}$')"));
check('Driver order polling rejects duplicate or malformed order rows', orderSnapshot.includes('A-Za-z0-9_-') && orderSnapshot.includes('!seen.add(id)') && orderSnapshotTests.includes('rejects malformed and overlong order ids') && orderSnapshotTests.includes('rejects duplicate free order ids'));
check('Driver order polling enforces at most one active trip', orderSnapshot.includes('rawAssigned.length > 1') && orderSnapshotTests.includes('rejects more than one assigned order'));
check('Driver open-order feed contains only new orders', orderSnapshot.includes("expectedStatus: 'new'") && orderSnapshotTests.includes('rejects an invalid free-order status'));
check('Driver assigned-order feed contains only active statuses', orderSnapshot.includes("allowedStatuses: const {'driver_assigned', 'arrived'}") && orderSnapshotTests.includes('rejects an invalid assigned-order status'));
check('Driver order polling rejects an order listed as both open and assigned', orderSnapshot.includes("assigned.any((order) => openIds.contains(order['id']))") && orderSnapshotTests.includes('rejects the same order appearing in both lists'));
check('Driver route re-fetches after an in-flight request observes a replacement assignment', app.includes('refreshAfterRoute = latestAssignedId.isNotEmpty;'));
check('Driver route response revalidates current pickup and GPS coordinates', app.includes('String? _currentDriverRouteKey(String orderId)') && app.includes('final latestRouteKey = _currentDriverRouteKey(id);'));
check('A stale route request is refreshed after GPS movement', /if \(refreshAfterRoute && mounted\)\s*\{\s*unawaited\(_loadDriverApproachRoute\(\)\);/.test(app));
check('Route loading state is reset through setState', /setState\(\(\) => _driverRouteLoading = false\)/.test(app));
check('Driver map draws a route only for its assigned order', /_driverApproachRoute != null &&\s*_serverAssignedOrders\.isNotEmpty &&\s*_driverRouteOrderId ==/.test(app));


check('Passenger pickup is not treated as confirmed at the regional fallback center', /bool _pickupPointConfirmed = false;/.test(app));
const clientLocateStart = app.indexOf('Future<void> _locateClient');
const clientLocateEnd = app.indexOf('Future<void> _refreshNearbyDrivers', clientLocateStart);
const clientLocateBlock = clientLocateStart >= 0 && clientLocateEnd > clientLocateStart
  ? app.slice(clientLocateStart, clientLocateEnd)
  : '';
check(
  'Passenger GPS success confirms the pickup point',
  containsInOrder(clientLocateBlock, [
    '_clientCurrentLocation = point;',
    '_pickupPoint = point;',
    '_pickupPointConfirmed = true;',
  ]),
);
const passengerMapTapStart = app.indexOf('onTap: (tapPosition, point) {');
const passengerMapTapEnd = app.indexOf('children: [', passengerMapTapStart);
const passengerMapTapBlock = passengerMapTapStart >= 0 && passengerMapTapEnd > passengerMapTapStart
  ? app.slice(passengerMapTapStart, passengerMapTapEnd)
  : '';
check(
  'Manual passenger map selection confirms the pickup point',
  containsInOrder(passengerMapTapBlock, [
    '_pickupPoint = point;',
    '_pickupPointConfirmed = true;',
  ]),
);
check('Passenger cannot submit an order with an unconfirmed fallback pickup', app.includes('if (!_pickupPointConfirmed)') && app.includes('Сначала определите своё местоположение'));
check('Passenger map explains how to confirm the pickup point', app.includes('Определите местоположение или отметьте точку на карте'));

const preflightRouteCachePolicy = read('testapp/lib/services/route_cache_policy.dart');
const passengerRouteStart = app.indexOf('Future<void> _loadApproachRoute');
const passengerRouteEnd = app.indexOf('double? _readValidCoordinate', passengerRouteStart);
const passengerRouteBlock = passengerRouteStart >= 0 && passengerRouteEnd > passengerRouteStart
  ? app.slice(passengerRouteStart, passengerRouteEnd)
  : '';
check('Passenger route requires an active taxi order', passengerRouteBlock.includes("final order = TaxiParkState.activeOrder") && passengerRouteBlock.includes("order.status != 'accepted'"));
check('Passenger route requires an assigned driver', passengerRouteBlock.includes('driverId == null'));
check('Passenger route requires a valid order identifier', passengerRouteBlock.includes('orderId.isEmpty'));
check('Passenger route requires the driver to be online', passengerRouteBlock.includes('!driver.isOnline'));
check('Passenger route requires a fresh GPS timestamp without whole-second rounding',
  passengerRouteBlock.includes('!isGpsTimestampFresh(driver.locationUpdatedAt)'));
check('Passenger route cache includes order and driver identity', passengerRouteBlock.includes("final key = '$orderId:$driverId:"));
check('Passenger route cache includes pickup coordinates', passengerRouteBlock.includes('pickupPoint.latitude.toStringAsFixed(5)') && passengerRouteBlock.includes('pickupPoint.longitude.toStringAsFixed(5)'));
check('Passenger route cache includes driver coordinates', passengerRouteBlock.includes('driverPoint.latitude.toStringAsFixed(3)') && passengerRouteBlock.includes('driverPoint.longitude.toStringAsFixed(3)'));
check('Passenger route avoids overlapping route requests', passengerRouteBlock.includes('if (_routeLoading) return;'));
check('Passenger route respects retry cooldown', passengerRouteBlock.includes('_routeRetryAfter != null') && passengerRouteBlock.includes('routeCheckTime.isBefore(_routeRetryAfter!)'));
check('Passenger route clears previous line before refresh', passengerRouteBlock.includes('_approachRoute = null;') && passengerRouteBlock.includes('var refreshAfterRoute = false;'));
check('Passenger route loading state is enabled before request', passengerRouteBlock.includes('_routeLoading = true;') && passengerRouteBlock.includes('_routeError = null;'));
check('Passenger route uses a captured pickup point for the request', passengerRouteBlock.includes('final pickupPoint = _pickupPoint;') && passengerRouteBlock.includes('RouteService.drivingRoute(driverPoint, pickupPoint)'));
check('Passenger route response validates the latest pickup point as well as taxi GPS', (passengerRouteBlock.match(/final latestPickupPoint = _pickupPoint;/g) || []).length === 2 && passengerRouteBlock.includes('latestPickupPoint.latitude.toStringAsFixed(5)') && passengerRouteBlock.includes('latestPickupPoint.longitude.toStringAsFixed(5)'));
check('Passenger route starts at taxi and ends at the captured pickup', passengerRouteBlock.includes('RouteService.drivingRoute(driverPoint, pickupPoint)'));
check('Passenger route response checks current order identity', passengerRouteBlock.includes('latestOrder?.id != orderId'));
check('Passenger route response checks current driver identity', passengerRouteBlock.includes('latestOrder?.assignedDriver?.id != driverId'));
check('Passenger route response is discarded after taxi arrival', passengerRouteBlock.includes("latestOrder?.status != 'accepted'"));
check('Passenger route response rejects outdated endpoint coordinates', passengerRouteBlock.includes('if (latestKey != key)') && passengerRouteBlock.includes("refreshAfterRoute = latestOrder.status == 'accepted';"));
check('Passenger route retries after driver or pickup point changes during request', passengerRouteBlock.includes('unawaited(_loadApproachRoute(latestDriver.currentLocation))'));
check('Passenger route errors trigger a bounded retry delay', passengerRouteBlock.includes('_routeRetryAfter = DateTime.now().add(const Duration(seconds: 30))'));
check('Passenger route cache is reused only while the matching route is fresh', passengerRouteBlock.includes('RouteCachePolicy.isFresh(') && passengerRouteBlock.includes('cachedKey: _routeLoadedKey') && passengerRouteBlock.includes('requestedKey: key'));
check('Passenger route cache expires after two minutes', preflightRouteCachePolicy.includes('Duration(minutes: 2)'));
check('Passenger route cache timestamp is updated only after a successful route response', passengerRouteBlock.includes('_routeLoadedKey = key;') && passengerRouteBlock.includes('_routeLoadedAt = DateTime.now();'));
check('Passenger route cache is cleared after a failed route response', passengerRouteBlock.includes('_routeLoadedKey = null;') && passengerRouteBlock.includes('_routeLoadedAt = null;'));
check('Route cache freshness tests cover expiry and coordinate changes', read('testapp/test/widget_test.dart').includes('Passenger route cache freshness') && read('testapp/test/widget_test.dart').includes('does not reuse a route after pickup or taxi coordinates change'));


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
const nearbyRefreshStart = app.indexOf('Future<void> _refreshNearbyDrivers');
const nearbyRefreshEnd = app.indexOf('int _parseFare', nearbyRefreshStart);
const nearbyRefreshBlock = nearbyRefreshStart >= 0 && nearbyRefreshEnd > nearbyRefreshStart
  ? app.slice(nearbyRefreshStart, nearbyRefreshEnd)
  : '';
check('Nearby refresh hides cars until pickup is confirmed',
  nearbyRefreshBlock.includes('if (!_pickupPointConfirmed)') &&
  nearbyRefreshBlock.includes('_nearbyDriverPoints.clear()'));
check('Nearby refresh gate prevents overlapping network requests',
  nearbyRefreshBlock.includes('!_nearbyDriversRefreshGate.begin()'));
check('Nearby refresh always releases its gate in finally',
  nearbyRefreshBlock.includes('finally {') && nearbyRefreshBlock.includes('_nearbyDriversRefreshGate.finish()'));
check('Nearby refresh retries only when a request was coalesced',
  nearbyRefreshBlock.includes('if (refreshAgain && mounted)'));
check('Nearby refresh retry starts after releasing the gate',
  nearbyRefreshBlock.includes('final refreshAgain = _nearbyDriversRefreshGate.finish();') &&
  nearbyRefreshBlock.includes('unawaited(_refreshNearbyDrivers());'));
check('Nearby refresh gate is shared by the passenger map state',
  app.includes('final CoalescedRefreshGate _nearbyDriversRefreshGate = CoalescedRefreshGate();'));
check('Refresh gate starts the first request',
  refreshGate.includes('_running = true;') && refreshGate.includes('return true;'));
check('Refresh gate coalesces repeated requests into one pending retry',
  refreshGate.includes('_pending = true;') && refreshGate.includes('final shouldRefreshAgain = _pending;'));
check('Refresh gate clears pending state when finishing',
  refreshGate.includes('_pending = false;'));
check('Refresh gate does not release an inactive request',
  refreshGate.includes('if (!_running) return false;'));
check('Refresh gate unit tests cover overlapping and idle requests',
  ['turns overlapping refresh calls into one follow-up request',
   'does not schedule a retry when no request arrived during refresh',
   'clears the pending flag before the follow-up begins']
    .every((label) => read('testapp/test/widget_test.dart').includes(label)));
check("Passenger validates latitude and longitude bounds", /lat < -90 \|\| lat > 90 \|\| lng < -180 \|\| lng > 180/.test(app));
check("Passenger rejects stale GPS responses", /!isGpsTimestampFresh\(updatedAt\)/.test(app));
check("Passenger only shows nearby cars after pickup confirmation",
  app.includes('if (!_pickupPointConfirmed)') &&
  app.includes('_nearbyDriverPoints.clear()'));
check("Passenger keeps previous markers only until GPS expires", /_nearbyDriverPoints\.removeWhere\([\s\S]{0,100}!isGpsTimestampFresh\(entry\.value\)/.test(app));
check('Nearby refresh gate is released after completion', /_nearbyDriversRefreshGate\.finish\(\)/.test(app) && /final refreshAgain = _nearbyDriversRefreshGate\.finish\(\);/.test(app));
const nearbyMarkerStart = app.indexOf('_nearbyDriverPoints.map((entry) => Marker(');
const nearbyMarkerBlock = nearbyMarkerStart >= 0 ? app.slice(nearbyMarkerStart, nearbyMarkerStart + 500) : '';
check("Passenger uses the tested nearby-driver ranking helper", app.includes("selectNearbyDriverLocations(") && app.includes("maxDistanceKm: 20") && app.includes("maxResults: 10"));
check("Nearby-driver filter rejects invalid pickup and search limits", /maxDistanceKm < 0/.test(read('testapp/lib/services/nearby_driver_filter.dart')) && /maxResults <= 0/.test(read('testapp/lib/services/nearby_driver_filter.dart')));
check("Nearby-driver filter sorts by distance and caps result count", /ranked\.sort/.test(read('testapp/lib/services/nearby_driver_filter.dart')) && /ranked\.take\(maxResults\)/.test(read('testapp/lib/services/nearby_driver_filter.dart')));
check("Nearby-driver filter has unit tests for radius, ordering, freshness and result limits", ['sorts fresh nearby cars by distance', 'excludes cars beyond the requested radius', 'limits the number of visible cars', 'excludes stale, future and invalid GPS positions'].every((label) => read('testapp/test/widget_test.dart').includes(label)));
check('Nearby filter handles a zero-kilometre radius', read('testapp/test/widget_test.dart').includes('accepts the pickup coordinate when the search radius is zero'));
check('Nearby filter resolves equal-distance ties by newest GPS', read('testapp/test/widget_test.dart').includes('prefers the newest GPS fix when two cars are equally distant'));
check('Nearby filter handles longitude wrap at the date line', read('testapp/test/widget_test.dart').includes('calculates short distances across the international date line'));
check('Nearby filter handles valid high-latitude coordinates', read('testapp/test/widget_test.dart').includes('keeps valid nearby cars at high latitudes'));
check('Nearby filter rejects non-finite and negative radii', read('testapp/test/widget_test.dart').includes('rejects infinite and negative search radii'));
check("Passenger map renders distinct green taxi markers", nearbyMarkerBlock.includes("point: entry.key") && nearbyMarkerBlock.includes("Icons.local_taxi") && nearbyMarkerBlock.includes("Colors.green"));
check("Passenger cancels nearby timer when disposed", /_nearbyDriversTimer\?\.cancel\(\)/.test(app));

 // Dispatcher live fleet map and refresh regression checks.
check("Dispatcher overview supplies driver GPS coordinates", worker.includes("d.latitude, d.longitude, d.location_updated_at"));
check("Dispatcher overview is protected by dispatcher authentication", /url\.pathname === "\/dispatcher\/overview"[\s\S]{0,100}requireDispatcher\(request\)/.test(worker));
check("Dispatcher dashboard refresh timer is configured", app.includes("Timer.periodic(const Duration(seconds: 15)"));
check("Dispatcher refresh runs without replacing the dashboard", app.includes("_load(showLoading: false)"));
check("Dispatcher refresh coalesces overlapping requests into one follow-up", app.includes("if (_dispatcherLoadInProgress) {") && app.includes("_dispatcherRefreshPending = true;") && app.includes("scheduleMicrotask(() => _load(showLoading: false))"));
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
check("Dispatcher map uses the restored keyless OpenStreetMap DE layer", app.includes("https://tile.openstreetmap.de/{z}/{x}/{y}.png") && app.includes("buildTaxiDarkMapLayers"));
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
check("Dispatcher load lock marks a pending refresh instead of starting a concurrent request", app.includes("if (_dispatcherLoadInProgress) {") && app.includes("_dispatcherRefreshPending = true;"));
check("Dispatcher load lock is released even after request errors", app.includes("_dispatcherLoadInProgress = false;"));
check("Dispatcher fleet map falls back to Sulyukta when no fresh cars exist", app.includes("markers.isEmpty") && app.includes("TaxiParkState.sulyuktaCenter"));
check("Dispatcher fleet map calculates latitude center from fresh markers", app.includes("marker.point.latitude).reduce"));
check("Dispatcher fleet map calculates longitude center from fresh markers", app.includes("marker.point.longitude).reduce"));
check("Dispatcher fleet map averages coordinates for initial center", app.includes("initialCenter: center"));
check("Dispatcher fleet map chooses a zoom level for broad service areas", app.includes("latitudeSpan > 0.5 || longitudeSpan > 0.5"));
check("Dispatcher fleet map uses a regional zoom for medium spread", app.includes("latitudeSpan > 0.1 || longitudeSpan > 0.1"));
check("Dispatcher map centering only uses already validated markers", app.includes("final center = markers.isEmpty"));
check("Dispatcher map continues to exclude stale GPS before calculating center", app.includes("!isGpsTimestampFresh(updatedAt)"));
check("Dispatcher map retains shared OpenStreetMap DE layer and attribution", app.includes("...buildTaxiDarkMapLayers()") && app.includes("OpenStreetMap DE") && app.includes("© OpenStreetMap contributors"));
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
const driverScreenStart = app.indexOf('class _DriverMapScreenState');
const driverDisposeStart = app.indexOf('void dispose()', driverScreenStart);
const driverDisposeEnd = app.indexOf('\n  Future<void> _logoutDriver()', driverDisposeStart);
const driverDisposeBlock = driverDisposeStart >= 0 && driverDisposeEnd > driverDisposeStart
  ? app.slice(driverDisposeStart, driverDisposeEnd) : '';
check('Leaving the live driver screen marks the driver offline', driverDisposeBlock.includes('WorkerApi.setDriverOnline(online: false)'));
check('Driver order polling runs every five seconds', app.includes('Timer.periodic(const Duration(seconds: 5), (_) {') && app.includes('_pollServerOrders();'));
check('Open-order endpoint requires an approved online driver', worker.includes('url.pathname === "/orders/open"') && worker.includes('requireApprovedDriver(request, env, true)'));
check('Open-order query returns only unassigned new orders', worker.includes("FROM orders o WHERE status='new'"));
check('Open-order query excludes a driver with an active assigned trip', worker.includes("active.assigned_driver_uid=?") && worker.includes("active.status IN ('driver_assigned','arrived')"));

// Open offers are visible only while the requesting driver has fresh, valid GPS.
const openOrdersStart = worker.indexOf('if (url.pathname === "/orders/open" && request.method === "GET")');
const openOrdersEnd = worker.indexOf('if (url.pathname === "/orders/status" && request.method === "GET")', openOrdersStart);
const openOrdersRoute = openOrdersStart >= 0 && openOrdersEnd > openOrdersStart ? worker.slice(openOrdersStart, openOrdersEnd) : '';
const openOrdersQueryStart = openOrdersRoute.indexOf('const open = await env.DB.prepare');
const openOrdersQueryEnd = openOrdersRoute.indexOf('const assignedOrders =', openOrdersQueryStart);
const openOrdersQuery = openOrdersQueryStart >= 0 && openOrdersQueryEnd > openOrdersQueryStart ? openOrdersRoute.slice(openOrdersQueryStart, openOrdersQueryEnd) : '';
check('Open-order offers use a dedicated current-time snapshot', openOrdersRoute.includes('const openNow = Math.floor(Date.now() / 1000);'));
check('Open-order offers are filtered through the current driver profile', openOrdersQuery.includes('FROM drivers available_driver WHERE available_driver.uid=?'));
check('Open-order offers require approved driver status in SQL', openOrdersQuery.includes('available_driver.approved=1'));
check('Open-order offers require online driver status in SQL', openOrdersQuery.includes('available_driver.online=1'));
check('Open-order offers require a valid latitude in SQL', openOrdersQuery.includes('available_driver.latitude BETWEEN -90 AND 90'));
check('Open-order offers require a valid longitude in SQL', openOrdersQuery.includes('available_driver.longitude BETWEEN -180 AND 180'));
check('Open-order offers reject GPS timestamps older than 60 seconds', openOrdersQuery.includes('available_driver.location_updated_at BETWEEN ? AND ?') && openOrdersRoute.includes('openNow - 60'));
check('Open-order offers reject future GPS timestamps', openOrdersQuery.includes('available_driver.location_updated_at BETWEEN ? AND ?') && openOrdersRoute.includes('openNow,'));
check('Open-order offers bind the authenticated driver UID to the profile filter', openOrdersQuery.includes('.bind(\n            auth.user.localId, openNow - 60, openNow,'));
check('Open-order offers bind both active-trip and refusal exclusions', openOrdersQuery.includes('auth.user.localId, auth.user.localId\n          ).all()'));
check('Open-order offers remain limited to new unassigned orders', openOrdersQuery.includes("FROM orders o WHERE status='new'"));
check('Open-order offers continue excluding active trips', openOrdersQuery.includes("active.status IN ('driver_assigned','arrived')"));
check('Open-order offers continue respecting driver refusals', openOrdersQuery.includes('order_refusals x WHERE x.order_id=o.id AND x.driver_uid=?'));
check('Open-order offer result count remains bounded', openOrdersQuery.includes('ORDER BY created_at ASC LIMIT 100'));
check('Assigned active orders are fetched separately from open offers', openOrdersRoute.includes('const assignedOrders = await env.DB.prepare'));
check('Assigned active orders remain visible even when open-offer GPS is stale', openOrdersRoute.includes("status IN ('driver_assigned','arrived') AND assigned_driver_uid=?"));
check('Driver API response keeps open and assigned order lists separate', openOrdersRoute.includes('orders: open.results || [], assignedOrders: assignedOrders.results || []'));
check('Driver UI clears open offers when the driver manually goes offline', app.includes('_driverWantsOnline = false;') && app.includes('_serverOpenOrders = [];'));
check('Driver order polling can restore assigned trips while offline', app.includes('if (_ordersPollInProgress) {') && app.includes('unawaited(_pollServerOrders());'))

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
check('Offline drivers never display new order offers', app.includes('final visibleOpen = _driverWantsOnline ? open : <Map<String, dynamic>>[];') && app.includes('_serverOpenOrders = visibleOpen;'));
check('GPS retry scheduling requires desired online state', app.includes('if (!mounted || !_driverWantsOnline || _locationRetryTimer?.isActive == true) return;'));
check('GPS retry callback rechecks desired online state', app.includes('if (mounted && _driverWantsOnline) unawaited(_startLocationTracking());'));
check('GPS tracking startup requires desired online state', app.includes('driver == null || !mounted || !_driverWantsOnline || _locationTrackingStarting'));
check('GPS stream ignores updates after the driver goes offline', app.includes('if (!mounted || !_driverWantsOnline) return;'));
check('Heartbeat refresh requires desired online state', app.includes('if (!mounted || !_driverWantsOnline || _positionSubscription == null'));
check('GPS publication refuses to advertise an offline driver', app.includes('if (!mounted || !_driverWantsOnline || _locationUpdateInProgress'));
check('An in-flight GPS publication restores offline state after a concurrent opt-out', app.includes('If the driver switched off while this request was in flight') && app.includes('await WorkerApi.setDriverOnline(online: false);'));

check('Driver availability restores its initial value from the authenticated profile and saved preference', app.includes('final currentDriver = TaxiParkState.currentLoggedInDriver;') && app.includes('_driverWantsOnline = currentDriver?.isOnline ?? false;') && app.includes('unawaited(_saveDriverLinePreference(currentDriver.id, true))'));
check('An offline driver does not start GPS automatically after reopening the driver screen', app.includes('if (_driverWantsOnline && currentDriver != null)') && !app.includes('if (_driverWantsOnline) {\n      _startLocationTracking();'));
check('Assigned orders are restored on initial screen load regardless of line preference', (() => { const start=app.indexOf('void initState()', app.indexOf('class _DriverMapScreenState')); const end=app.indexOf('_ordersPollTimer =', start); const block=app.slice(start,end); return block.includes('if (_driverWantsOnline && currentDriver != null)') && block.includes('unawaited(_pollServerOrders());'); })());
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
check('Driver profile restoration uses server online state and saved local preference', app.includes("isOnline: _isEnabled(data['online']) ||") && app.includes('await _readDriverLinePreference(restoringUid)'));

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
check('GPS readiness helper updates the driver model only from confirmed readiness', app.includes('if (driver != null) driver.isOnline = confirmedReady;'));
check('GPS readiness helper also respects dispatcher-forced offline state', app.includes('final confirmedReady = ready && mounted && _driverWantsOnline && !_dispatcherForcedOffline;'));
check('GPS readiness helper avoids setState after disposal', app.includes('if (!mounted || _driverGpsReady == confirmedReady) return;'));
check('GPS readiness helper applies only the guarded readiness value', app.includes('setState(() => _driverGpsReady = confirmedReady);'));
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

 
// Complete paginated dispatcher audit history for passenger no-show cancellations.
const cancellationHistoryStart = worker.indexOf('if (url.pathname === "/dispatcher/cancellations"');
const cancellationHistoryEnd = worker.indexOf('if (url.pathname === "/dispatcher/overview"', cancellationHistoryStart);
const cancellationHistoryRoute = cancellationHistoryStart >= 0 && cancellationHistoryEnd > cancellationHistoryStart
  ? worker.slice(cancellationHistoryStart, cancellationHistoryEnd) : '';
// Durable passenger no-show cancellation history and dispatcher visibility.
const noShowStart = worker.indexOf('if (order.status === "arrived")', worker.indexOf('url.pathname === "/orders/cancel"'));
const noShowEnd = worker.indexOf('if (order.status !== "driver_assigned")', noShowStart);
const noShowRoute = noShowStart >= 0 && noShowEnd > noShowStart ? worker.slice(noShowStart, noShowEnd) : '';
const overviewStart = worker.indexOf('if (url.pathname === "/dispatcher/overview"');
const overviewEnd = worker.indexOf('if (url.pathname === "/orders/assign"', overviewStart);
const overviewRoute = overviewStart >= 0 && overviewEnd > overviewStart ? worker.slice(overviewStart, overviewEnd) : '';
check('No-show cancellations have a durable one-row-per-order audit table', worker.includes('CREATE TABLE IF NOT EXISTS order_cancellations') && worker.includes('order_id TEXT PRIMARY KEY NOT NULL'));
check('Cancellation audit table restricts reasons to the three supported values', worker.includes("CHECK(reason IN ('customer_not_found','customer_unreachable','customer_left_with_other_car'))"));
check('Order status update and cancellation audit insert use one D1 batch', noShowRoute.includes('const noShowResults = await env.DB.batch(['));
check('No-show cancellation checks both atomic batch results', noShowRoute.includes('noShowResults?.[0]?.meta?.changes') && noShowRoute.includes('noShowResults?.[1]?.meta?.changes'));
check('Dispatcher cancellation audit API remains available after hiding the dashboard section', cancellationHistoryRoute.includes('LEFT JOIN order_cancellations c ON c.order_id=o.id') && cancellationHistoryRoute.includes('c.reason') && cancellationHistoryRoute.includes('c.cancelled_at'));
check('Removed dispatcher sections do not delete server-side no-show audit records', !app.includes('Водитель прибыл · ожидают закрытия') && !app.includes('Отмены после прибытия · неявка пассажира') && worker.includes('INSERT INTO order_cancellations'));




check('Driver assigned-order card exposes completion without arrival-only cancellation', app.includes('_completeAssignedOrder(item)') && !app.includes('_cancelArrivedNoShowOrder'));

check('Cancellation audit history has a dedicated dispatcher-only endpoint', cancellationHistoryRoute.includes('await requireDispatcher(request)'));
check('Cancellation history includes all no-show statuses, not only recent dashboard orders', cancellationHistoryRoute.includes("WHERE o.status='cancelled_by_driver_no_show'"));
check('Cancellation history retains legacy rows without a reason audit record', cancellationHistoryRoute.includes('LEFT JOIN order_cancellations c'));
check('Cancellation history uses stable timestamp and order ID cursor ordering', cancellationHistoryRoute.includes('ORDER BY sort_at DESC, o.id DESC') && cancellationHistoryRoute.includes('o.id < ?'));
check('Cancellation history validates cursor timestamp and order ID', cancellationHistoryRoute.includes('Number.isSafeInteger(beforeAt)') && cancellationHistoryRoute.includes('beforeId.length > 128'));
check('Cancellation history fetches one extra row to determine whether another page exists', cancellationHistoryRoute.includes('LIMIT 51') && cancellationHistoryRoute.includes('rows.length > 50'));
check('Cancellation history returns the next cursor from the last visible row', cancellationHistoryRoute.includes('before_at: Number(last.sort_at)') && cancellationHistoryRoute.includes('before_id: String(last.order_id)'));
check('Cancellation endpoint rejects repeated cursor query parameters', cancellationHistoryRoute.includes('beforeAtValues.length > 1') && cancellationHistoryRoute.includes('beforeIdValues.length > 1'));
check('Cancellation endpoint rejects a cursor missing either field', cancellationHistoryRoute.includes('beforeAtRaw === null || beforeIdRaw === null'));
check('Cancellation endpoint accepts only canonical non-negative decimal timestamps', cancellationHistoryRoute.includes('/^(0|[1-9][0-9]*)$/.test(beforeAtRaw)'));
check('Cancellation endpoint rejects unsafe timestamp values', cancellationHistoryRoute.includes('Number.isSafeInteger(beforeAt)'));
check('Cancellation endpoint rejects control characters and oversized cursor IDs', cancellationHistoryRoute.includes('beforeId.length > 128') && cancellationHistoryRoute.includes('beforeIdRaw.trim()'));
check('Flutter API rejects negative and unsafe cancellation timestamps', api.includes('beforeAt < 0') && api.includes('beforeAt > 9007199254740991'));
check('Flutter API rejects oversized and control-character cancellation IDs', api.includes('normalizedId!.length > 128') && api.includes("RegExp(r'[\\x00-\\x1F\\x7F]')"));
check('Dispatcher validates cancellation page response shape', app.includes('_parseCancellationPage') && app.includes('rawRows is! List || hasMore is! bool'));
check('Dispatcher rejects empty and duplicate order IDs within a cancellation page', app.includes('orderId.isEmpty || !pageIds.add(orderId)'));
check('Dispatcher rejects malformed or missing next-page cursors', app.includes('rawCursor is! Map || rows.isEmpty') && app.includes('rawAt % 1 != 0'));
check('Dispatcher prevents a non-advancing cancellation pagination cursor', app.includes('nextAt == beforeAt && nextId == beforeId'));
check('Dispatcher client requests the protected cancellation history endpoint', api.includes("return _request('/dispatcher/cancellations$query')"));
check('Dispatcher can load subsequent cancellation pages without duplicate order IDs', app.includes('_loadMoreCancellationHistory') && app.includes('knownIds.contains'));
check('Dispatcher cancellation audit API keeps pagination while the dashboard panel is hidden', api.includes("return _request('/dispatcher/cancellations$query')") && cancellationHistoryRoute.includes('LIMIT 51') && !app.includes('Обновить историю'));
check('Server-side no-show cancellation history retains route details and excludes fare credit', cancellationHistoryRoute.includes('o.pickup_address') && worker.includes('earned_som: 0'));
check('Recent 100-order overview no longer limits the dedicated cancellation history', !worker.slice(worker.indexOf('if (url.pathname === "/dispatcher/overview"'), worker.indexOf('if (url.pathname === "/orders/assign"')).includes('LEFT JOIN order_cancellations c'));
// Private local copies and a bounded direct-transfer packet protocol.
check('Local document storage dependencies are declared', /crypto:\s*\^3\.0\.3/.test(pubspec) && /path_provider:\s*\^2\.1\.2/.test(pubspec));
const localDocumentStore = read('testapp/lib/services/driver_document_store.dart');
const transferProtocol = read('testapp/lib/services/driver_document_transfer_protocol.dart');
check('Driver originals are stored in app-private phone documents', localDocumentStore.includes('getApplicationDocumentsDirectory()') && localDocumentStore.includes('driver_documents'));
check('Local document store restricts UID paths and document types', localDocumentStore.includes("_uid=RegExp") && localDocumentStore.includes("'license','driver_photo','car_photo'"));
check('Local document store enforces 8 MB file limit', localDocumentStore.includes('8*1024*1024'));
check('Local document write verifies SHA-256 before final rename', localDocumentStore.includes('sha256.convert(saved).toString()!=digest') && localDocumentStore.includes('temp.rename(target.path)'));
check('Transfer protocol uses 10 KiB chunks', transferProtocol.includes('chunkBytes = 10 * 1024'));
check('Transfer protocol caps packets at 14 KiB', transferProtocol.includes('maxPacketBytes = 14 * 1024'));
check('Transfer protocol validates request, driver, document and chunk sequence', transferProtocol.includes('_identity(requestId, driverUid, documentType)') && transferProtocol.includes('chunkCountFor(total)'));
check('Transfer protocol validates payload size and SHA-256 format', transferProtocol.includes('_sha.hasMatch(digest)') && transferProtocol.includes('payload.length != expected'));
check('Transfer protocol supports chunk acknowledgements', transferProtocol.includes('encodeAck') && transferProtocol.includes('decodeAck'));
check('Driver registration stores selected originals locally before cloud upload', registration.includes("uid: 'pending-registration'") && registration.includes("uid: uid, documentType: 'license'"));
check('Driver review screen restores local documents on entry', app.includes('_restoreLocalDocuments()') && app.includes('DriverDocumentStore.find'));
// Driver registration and local phone-to-phone document transfer regression checks.
check('Driver registration photos are optional', registration.includes('whereType<XFile>()') && !registration.includes('_license == null || _driverPhoto == null || _carPhoto == null'));
check('Driver registration does not depend on Firebase Storage', !registration.includes('firebase_storage') && !registration.includes('FirebaseStorage') && !registration.includes('_upload('));
check('Selected registration photos are saved locally under the authenticated driver UID', registration.includes('DriverDocumentStore.persistPickedImage(uid: uid') && registration.includes('documentType:'));
check('Optional selected photos are individually saved only when present', registration.includes('if (_license != null)') && registration.includes('if (_driverPhoto != null)') && registration.includes('if (_carPhoto != null)'));
check('Selected local photos remain bounded to 8 MB each and 18 MB total', registration.includes('size > maxPhotoBytes') && registration.includes('totalBytes > maxTotalBytes'));
check('Registration reuses an existing Firebase account after email-already-in-use', registration.includes("e.code != 'email-already-in-use'") && registration.includes('FirebaseService.signInWithPhone(phone: phone, password: password)'));
check('Driver profile is saved before optional local photos', registration.includes('await WorkerApi.registerDriver(') && registration.indexOf('await WorkerApi.registerDriver(') < registration.indexOf('DriverDocumentStore.persistPickedImage(uid: uid'));
check('Registration signs out after optional local photo persistence', registration.indexOf('DriverDocumentStore.persistPickedImage(uid: uid') < registration.indexOf('await FirebaseService.signOut()'));
check('Rejected driver resubmission saves photos locally and uses the local review endpoint', app.includes('await WorkerApi.resubmitDriverDocuments()') && app.includes('DriverDocumentStore.persistPickedImage(') && !app.includes('await WorkerApi.saveDriverDocuments('));
check('Worker reopens rejected document review without Firebase Storage paths', worker.includes('url.pathname === "/drivers/documents/resubmit"') && worker.includes("local_transfer_request_id=NULL"));
check('Dispatcher approval is not blocked by missing or unreceived photos', worker.includes('Photos and documents are optional at registration') && !worker.includes('const hasAllDocuments = hasNewLocalDocuments') && !worker.includes('Сервер пока не подтвердил получение всех трёх документов'));
check('Storage document names are restricted to the three approved file names', ["'license.jpg'","'driver_photo.jpg'","'car_photo.jpg'"].every(name => storageRules.includes(name)));
check('Storage reads are limited to the document owner or dispatcher', storageRules.includes('request.auth.uid == driverUid || isDispatcher()'));
check('Storage writes are limited to the authenticated document owner', storageRules.includes('request.auth.uid == driverUid') && storageRules.includes('allow create, update:'));
check('Storage upload limit is 8 MB', storageRules.includes('request.resource.size <= 8 * 1024 * 1024'));
check('Storage accepts only image MIME types', storageRules.includes("request.resource.contentType.matches('image/(jpeg|png|webp)')"));
check('Storage deletion is limited to the document owner', storageRules.includes('allow delete: if signedIn()') && storageRules.includes('request.auth.uid == driverUid'));
const documentsStart = worker.indexOf('if (url.pathname === "/drivers/documents" && request.method === "POST")');
const documentsEnd = worker.indexOf('if (url.pathname === "/drivers/review" && request.method === "POST")', documentsStart);
const documentsRoute = documentsStart >= 0 && documentsEnd > documentsStart ? worker.slice(documentsStart, documentsEnd) : '';
const reviewStart = worker.indexOf('if (url.pathname === "/drivers/review" && request.method === "POST")');
const reviewEnd = worker.indexOf('if (url.pathname === "/drivers/approve" && request.method === "POST")', reviewStart);
const reviewRoute = reviewStart >= 0 && reviewEnd > reviewStart ? worker.slice(reviewStart, reviewEnd) : '';
const approveStart = worker.indexOf('if (url.pathname === "/drivers/approve" && request.method === "POST")');
const approveEnd = worker.indexOf('if (url.pathname === "/tariffs" && request.method === "GET")', approveStart);
const approveRoute = approveStart >= 0 && approveEnd > approveStart ? worker.slice(approveStart, approveEnd) : '';
check('Document submission requires Firebase authentication', documentsRoute.includes('await verifyFirebaseUser(request)'));
check('Document submission requires an existing driver profile', documentsRoute.includes('if (!driver)'));
check('Document submission constructs paths under the authenticated UID', documentsRoute.includes('`drivers/${auth.user.localId}/license.jpg`') && documentsRoute.includes('`drivers/${auth.user.localId}/driver_photo.jpg`') && documentsRoute.includes('`drivers/${auth.user.localId}/car_photo.jpg`'));
check('Document submission rejects paths in the wrong order or from another UID', documentsRoute.includes('paths.every((value, index) => value === expectedPaths[index])'));
check('Document submission stores a pending review state and clears any previous local-transfer marker', documentsRoute.includes("VALUES (?,?,?,?,unixepoch(),'pending',NULL,NULL,NULL,NULL)") && documentsRoute.includes('local_transfer_request_id=NULL'));
check('Resubmitted documents reset the review state to pending', documentsRoute.includes("review_status='pending'"));
check('Document submission clears previous rejection details', documentsRoute.includes('rejection_reason=NULL, reviewed_at=NULL, reviewed_by=NULL'));
check('Document submission immediately disables driver approval and online status', documentsRoute.includes('UPDATE drivers SET approved=0, online=0'));
check('Driver review endpoint requires dispatcher authentication', reviewRoute.includes('await requireDispatcher(request)'));
check('Driver review accepts only approved or rejected decisions', reviewRoute.includes('!["approved", "rejected"].includes(decision)'));
check('Driver rejection requires a meaningful reason', reviewRoute.includes("decision === \"rejected\" && reason.length < 5"));
check('Driver approval can proceed when no document row exists', reviewRoute.includes('if (!docs)') && reviewRoute.includes('INSERT OR IGNORE INTO driver_documents'));
check('Dispatcher can reject an incomplete driver application with a reason', reviewRoute.includes('decision === "rejected"') && reviewRoute.includes("VALUES (?,'','','',unixepoch(),'pending',NULL,NULL,NULL)") && reviewRoute.includes('reason.length < 5'));
check('Driver review only acts on a pending document submission', reviewRoute.includes('docs.review_status !== "pending"'));
check('Driver review records reviewer identity and timestamp', reviewRoute.includes('reviewed_at=unixepoch(), reviewed_by=?'));
check('Driver review updates the driver approval state and keeps driver offline', reviewRoute.includes('UPDATE drivers SET approved=?, online=0, updated_at=unixepoch()'));
check('Legacy approval endpoint cannot bypass document review', approveRoute.includes('docs.review_status !== "approved"'));
check('Dispatcher pending queue includes every unapproved pending application', app.includes("d['review_status'] ?? 'pending').toString() == 'pending'") && app.includes("!(d['approved'] == true || d['approved'] == 1"));
check('Dispatcher shows rejected driver applications separately', app.includes("d['review_status'] == 'rejected'"));
check('Driver review screen explains that approval is required before going online', app.includes('До одобрения выход на линию недоступен.'));
check('Rejected driver can submit replacement photos for another review', app.includes("if (rejected) ...[") && app.includes('_resubmit'));
check('Driver document submission uses a single D1 batch for documents and access revocation', documentsRoute.includes('const documentResults = await env.DB.batch([') && documentsRoute.includes('UPDATE drivers SET approved=0, online=0'));
check('Driver document submission verifies both D1 batch results', documentsRoute.includes('documentResults?.[0]?.meta?.changes') && documentsRoute.includes('documentResults?.[1]?.meta?.changes'));
check('Driver approval or rejection updates documents and driver access in one D1 batch', reviewRoute.includes('const reviewResults = await env.DB.batch([') && reviewRoute.includes('UPDATE drivers SET approved=?, online=0'));
check('Driver review update is conditional on the exact reviewer and decision', reviewRoute.includes('review_status=? AND reviewed_by=?') && reviewRoute.includes("WHERE driver_uid=? AND review_status='pending'"));
check('Driver review rejects a stale or concurrently processed decision', reviewRoute.includes('reviewResults?.[0]?.meta?.changes') && reviewRoute.includes('reviewResults?.[1]?.meta?.changes') && reviewRoute.includes('409'));
const registerStart = worker.indexOf('if (url.pathname === "/drivers/register" && request.method === "POST")');
const registerEnd = worker.indexOf('if (url.pathname === "/drivers/documents" && request.method === "POST")', registerStart);
const registerRoute = registerStart >= 0 && registerEnd > registerStart ? worker.slice(registerStart, registerEnd) : '';
check('Registration rejects non-object or non-text profile payloads', registerRoute.includes('!b || typeof b !== "object" || Array.isArray(b)') && registerRoute.includes('typeof value === "string"'));
check('Registration caps raw field lengths before normalization', registerRoute.includes('b.name.length > 240') && registerRoute.includes('b.phone.length > 64') && registerRoute.includes('b.car_model.length > 180') && registerRoute.includes('b.car_number.length > 60'));
check('Registration collapses repeated whitespace with a real whitespace regex', registerRoute.includes('replace(/\\s+/g, " ")'));
check('Registration extracts digits with a real nondigit regex', registerRoute.includes('phoneInput.replace(/\\D/g, "")'));
check('Registration validates phone syntax with an optional leading plus', registerRoute.includes('!/^\\+?[0-9 ()-]+$/.test(phoneInput)'));
check('Registration rejects unbalanced or nested phone parentheses', registerRoute.includes('parenthesisDepth !== 0') && registerRoute.includes('if (parenthesisDepth !== 0)'));
check('Registration accepts only ten-digit local Kyrgyz numbers', registerRoute.includes('/^0[0-9]{9}$/.test(phoneDigits)'));
check('Registration accepts only twelve-digit international Kyrgyz numbers', registerRoute.includes('/^996[0-9]{9}$/.test(phoneDigits)'));
check('Registration stores local and international numbers in canonical +996 form', registerRoute.includes('"+996" + phoneDigits.slice(1)') && registerRoute.includes('"+" + phoneDigits'));
check('Registration validates car model and plate length on the server', registerRoute.includes('carModel.length < 2 || carModel.length > 60') && registerRoute.includes('carNumber.length < 2 || carNumber.length > 20'));
check('Profile review revocation and profile update stay in one D1 batch', registerRoute.includes('const profileResults = await env.DB.batch([') && registerRoute.includes("review_status='rejected'") && registerRoute.includes('approved=CASE WHEN drivers.name<>excluded.name'));
check('Profile response distinguishes changed data from previously rejected documents', registerRoute.includes('const profileChanged = Number(profileResults?.[0]?.meta?.changes || 0) > 0') && registerRoute.includes('documents.rejection_reason'));
check('Profile save checks D1 result and reloads persisted approval', registerRoute.includes('profileResults?.[1]?.meta?.changes') && registerRoute.includes('SELECT approved FROM drivers WHERE uid=?'));
check('Registration UI enforces the same three-character minimum as the Worker', registration.includes('value.length < 3 || value.length > 80'));
check('Registration phone field allows formatted international Kyrgyz numbers', registration.includes('maxLength: 24') && registration.includes('+996XXXXXXXXX'));
const phoneSyntax = /^\+?[0-9 ()-]+$/;
const digitsOnly = value => value.replace(/\D/g, '');
check('Phone syntax accepts local and international formatted examples', phoneSyntax.test('0700 123 456') && phoneSyntax.test('+996 (700) 123-456'));
check('Phone digit extraction accepts the supported local number', digitsOnly('0700 123-456') === '0700123456');
check('Phone digit extraction accepts the supported international number', digitsOnly('+996 (700) 123-456') === '996700123456');
check('Phone validation rejects letters, extensions and misplaced plus signs', !phoneSyntax.test('+996700123456 ext2') && !phoneSyntax.test('996+700123456'));

check('GPS Unix seconds are converted with millisecond precision', gps.includes('milliseconds.round()') && gps.includes('seconds * 1000'));
check('GPS numeric timestamps reject non-finite values', gps.includes('!seconds.isFinite'));
check('GPS numeric timestamps enforce the DateTime millisecond range', gps.includes('_maxUnixTimestampMilliseconds') && gps.includes('milliseconds.abs() > _maxUnixTimestampMilliseconds'));
check('GPS parser accepts numeric-string Unix seconds', gps.includes("RegExp(r'^[+-]?") && gps.includes('double.tryParse(text)'));
check('GPS parser caps timestamp text length before parsing', gps.includes('text.length > 64'));
check('GPS parser retains ISO timestamp compatibility', gps.includes('DateTime.tryParse(text)'));
check('Shared GPS fix policy validates coordinate bounds, accuracy and timestamp freshness', gpsPolicy.includes('latitude < -90') && gpsPolicy.includes('longitude > 180') && gpsPolicy.includes('accuracyMeters > maxAccuracyMeters') && gpsPolicy.includes('isGpsTimestampFresh(timestamp, now: now, maxAge: maxAge)'));
check('Passenger GPS rejects stale and imprecise fixes before moving the pickup marker', app.includes('GPS вернул устаревшие или недостаточно точные координаты') && app.includes('accuracyMeters: position.accuracy') && app.includes('timestamp: position.timestamp'));
check('Driver initial, streaming and heartbeat fixes share the same GPS acceptance policy', app.includes('bool _isUsableDriverPosition(Position position)') && app.includes('return isUsableGpsFix('));
check('GPS policy tests cover coordinate bounds, invalid accuracy, missing time, stale and future fixes', gpsPolicyTests.includes('rejects non-finite and out-of-range coordinates') && gpsPolicyTests.includes('rejects missing, negative, non-finite or excessive accuracy') && gpsPolicyTests.includes('rejects a cached fix older than sixty seconds') && gpsPolicyTests.includes('rejects a GPS timestamp in the future'));
check('GPS policy tests cover exact boundaries and stricter custom limits', gpsPolicyTests.includes('accepts exact coordinate and accuracy boundaries') && gpsPolicyTests.includes('honors a stricter caller-supplied accuracy limit'));
check('GPS freshness compares full Duration precision, not truncated seconds', gps.includes('!age.isNegative && age <= maxAge') && !gps.includes('ageSeconds >= 0'));
check('GPS freshness rejects negative age limits', gps.includes('maxAge.isNegative'));
check('GPS tests cover fractional and string Unix timestamps', read('testapp/test/widget_test.dart').includes('preserves fractional Unix seconds') && read('testapp/test/widget_test.dart').includes('serialized as numeric strings'));
check('GPS tests cover sub-second future timestamps and exact custom age boundaries', read('testapp/test/widget_test.dart').includes('less than one second ahead') && read('testapp/test/widget_test.dart').includes('exactly at a custom freshness limit') && read('testapp/test/widget_test.dart').includes('negative freshness limits'));


check('Branded animated splash is the first app screen', app.includes('home: const BrandedSplashGate()'));
check('Branded splash loads the optimized high-resolution WebP artwork', app.includes("'assets/jak_splash_optimized.webp'") && pubspec.includes('assets/jak_splash_optimized.webp') && fs.existsSync(path.join(root, 'testapp/assets/jak_splash_optimized.webp')) && fs.statSync(path.join(root, 'testapp/assets/jak_splash_optimized.webp')).size > 10000);
check('Branded splash stays visible for a bounded interval before the existing session gate', app.includes('Timer(const Duration(milliseconds: 4200)') && app.includes('const SessionGate()'));
check('Branded splash animates its logo entrance and fades into the app', app.includes('TickerProviderStateMixin') && !app.includes('SingleTickerProviderStateMixin') && app.includes('_entrance.forward()') && app.includes('FadeTransition(') && app.includes('ScaleTransition(') && app.includes('CircularProgressIndicator(') && app.includes('transitionDuration: const Duration(milliseconds: 450)'));
check('Branded splash cancels its navigation timer on dispose', app.includes('_navigationTimer?.cancel();'));
check('Branded splash guards navigation after widget disposal', app.includes('if (!mounted) return;'));
check('Branded splash exposes an accessible semantic brand label', app.includes("label: 'ЖОЛ АМАН КЕНЧИ Такси'"));
check('Branded splash shows the complete supplied artwork without a drawn frame', app.includes('backgroundColor: const Color(0xFF102D4D)') && app.includes('fit: BoxFit.contain') && !app.includes('Border.all(color: gold, width: 4)'));
check('Branded splash decodes raster artwork near device pixel width', app.includes('Image.asset(') && app.includes('cacheWidth:') && app.includes('.clamp(1, 1440)'));
check('Driver and dispatcher sections use the requested green header palette', app.includes('backgroundColor: const Color(0xFF087A42)') && app.includes('foregroundColor: Colors.white'));
check('Passenger order action uses a gold button with dark text', app.includes('backgroundColor: const Color(0xFFFFD400)') && app.includes('foregroundColor: const Color(0xFF171717)'));
check('Global app bars use the gold and black brand palette', app.includes('backgroundColor: Color(0xFFFFD400)') && app.includes('foregroundColor: Color(0xFF171717)'));
check('Primary buttons use black surfaces with gold labels', app.includes('backgroundColor: const Color(0xFF171717)') && app.includes('foregroundColor: const Color(0xFFFFD400)'));
check('Cards use gold brand borders', app.includes('BorderSide(color: Color(0xFFE6A900), width: 1.2)'));
check('Map tile source remains keyless OpenStreetMap DE', app.includes('https://tile.openstreetmap.de/{z}/{x}/{y}.png'));
const clientMapStart = app.indexOf('class _ClientMapScreenState');
const clientMapEnd = app.indexOf('class DriverMapScreen', clientMapStart);
const clientMapSource = clientMapStart >= 0 && clientMapEnd > clientMapStart
  ? app.slice(clientMapStart, clientMapEnd) : '';
check('Client map requests the phone GPS automatically on entry', clientMapSource.includes('_locateClient(showMessage: false)'));
check('Client location checks GPS service and requests runtime permission', clientMapSource.includes('Geolocator.isLocationServiceEnabled()') && clientMapSource.includes('Geolocator.requestPermission()'));
check('Client GPS handles permanently denied permission without leaving the loading state', clientMapSource.includes('permission == LocationPermission.deniedForever') && clientMapSource.includes('setState(() => _clientLocationLoading = false)'));
check('Client GPS offers a direct route to Android app settings after permanent denial', clientMapSource.includes('_showClientLocationSettingsDialog()') && clientMapSource.includes('Geolocator.openAppSettings()'));
check('Client GPS settings dialog explains how to restore location access', clientMapSource.includes('Доступ к геолокации запрещён') && clientMapSource.includes('Открыть настройки'));
check('Manual passenger pickup selection is protected from a late automatic GPS response', clientMapSource.includes('_clientPickupManuallySelected = true') && clientMapSource.includes('if (!keepManualPickup)') && clientMapSource.includes('!keepManualPickup'));
check('Passenger map readiness does not recenter over a manually selected pickup', clientMapSource.includes('current != null && mounted && !_clientPickupManuallySelected'));
check('Client GPS request has high accuracy and a bounded timeout', clientMapSource.includes('desiredAccuracy: LocationAccuracy.high') && clientMapSource.includes('timeLimit: const Duration(seconds: 15)'));
check('Client GPS coordinates update the passenger pickup marker', clientMapSource.includes('_clientCurrentLocation = point') && clientMapSource.includes('_pickupPoint = point'));
check('Client map centers after map readiness and GPS acquisition', clientMapSource.includes('onMapReady:') && clientMapSource.includes('_clientMapController.move(point, 16.0)'));
check('Client has a manual retry control for current location', clientMapSource.includes('centerClientOnMyLocation') && clientMapSource.includes('_locateClient(showMessage: true)'));
check('Client map keeps manual pickup selection when GPS is unavailable', clientMapSource.includes('Keep the Sülüktü fallback and manual map selection available'));
check('Passenger order screen uses branded yellow black app bar and language switcher', app.includes('ЖОЛ АМАН КЕНЧИ • ТАКСИ') && app.includes('child: TaxiLanguageSwitcher()'));
check('Passenger order form is presented in a rounded gold bordered card', app.includes('BorderRadius.vertical(top: Radius.circular(24))') && app.includes('Border.all(color: const Color(0xFFE6A900), width: 1.5)'));
check('Passenger city and intercity tariff chips use gold selected state with dark readable text', app.includes('selectedColor: const Color(0xFFFFD400)') && app.includes('color: !_isIntercity ? const Color(0xFF171717)') && app.includes('color: _isIntercity ? const Color(0xFF171717)'));
check('Passenger tariff section has a localized visual heading', app.includes("TaxiLocalizedText(russian: 'ВЫБЕРИТЕ ТАРИФ'") && app.includes('letterSpacing: 0.8'));
check('Passenger pickup instructions are highlighted with a location icon', app.includes('Точка подачи: нажмите на карту') && app.includes('Icons.location_on_rounded'));
check('Passenger destination field has a flag icon and branded focus border', app.includes('Icons.flag_rounded') && app.includes('focusedBorder: OutlineInputBorder'));
check('Passenger order action is a large taxi button with branded colors', app.includes('ElevatedButton.icon(') && app.includes('minimumSize: const Size.fromHeight(60)') && app.includes('ВЫЗВАТЬ МАШИНУ'));
check('Passenger count controls are grouped in a readable surface', app.includes('Icons.people_alt_rounded') && app.includes('Пассажиры: '));
check('Widget test covers the complete contained taxi splash and bottom loading animation', read('testapp/test/widget_test.dart').includes('shows complete contained taxi artwork and bottom loading animation'));


check('Language switch offers Russian and Kyrgyz', localization.includes("DropdownMenuItem(value: 'ru', child: Text('Русский'))") && localization.includes("DropdownMenuItem(value: 'ky', child: Text('Кыргызча'))"));
check('Language switch updates a shared app language notifier', localization.includes("static final ValueNotifier<String> current") && localization.includes("TaxiLanguage.current.value = value"));
check('Role menu listens for language changes and rebuilds', app.includes("TaxiLanguage.current.addListener(_handleLanguageChanged)") && app.includes("removeListener(_handleLanguageChanged)"));
check('Role menu passenger action target remains accessible over the supplied artwork', app.includes("label: 'Я пассажир / Мен жүргүнчүмүн'") && app.includes('ClientAuthScreen()'));
check('Role menu driver action target remains accessible over the supplied artwork', app.includes("label: 'Я водитель / Мен айдоочумун'") && app.includes('DriverEntryScreen()'));
check('Role menu language control overlays the supplied artwork and opens language choices', app.includes('_showMainMenuLanguagePicker(context)') && app.includes('label: \'Выбрать язык / Тилди тандоо\'') && app.includes('SizedBox.expand()'));
check('Role menu passenger hit target aligns with the supplied artwork', app.includes('height * 0.665') && app.includes('ClientAuthScreen()'));
check('Role menu driver hit target stays aligned with the artwork button', app.includes('height * 0.758') && app.includes('DriverEntryScreen()'));
check('Role menu uses the prepared banner image containing the supplied slogans', app.includes("'assets/jak_main_menu_optimized.webp'") && pubspec.includes('assets/jak_main_menu_optimized.webp') && fs.existsSync(path.join(root, 'testapp/assets/jak_main_menu_optimized.webp')) && fs.statSync(path.join(root, 'testapp/assets/jak_main_menu_optimized.webp')).size > 10000);
check('Role menu decodes the supplied optimized artwork at bounded device resolution', app.includes('cacheWidth:') && app.includes('.clamp(1, 1152)'));
check('Splash screen places the animated loading indicator at the bottom center', app.includes('CircularProgressIndicator(') && app.includes('top: height * 0.785') && app.includes('left: 0') && app.includes('right: 0'));
check('Role menu dispatcher hit target stays aligned with the artwork button', app.includes('height * 0.852') && app.includes('_showDispatcherAuth(context)'));
check('Widget test covers switching between Russian and Kyrgyz', read('testapp/test/widget_test.dart').includes('Russian and Kyrgyz language switch'));


check('Client login and registration titles are localized', app.includes("Кардар катары кирүү") && app.includes("Кардарды каттоо"));
check('Client login and registration actions are localized', app.includes("Аккаунтка кирүү") && app.includes("Жаңы кардарды каттоо"));
check('Client auth page exposes the language switcher', app.includes("title: const TaxiLocalizedText(russian: 'Клиентская панель', kyrgyz: 'Кардардын панели')") && app.includes("actions: const [Padding(padding: EdgeInsets.only(right: 12), child: TaxiLanguageSwitcher())]"));
check('Driver login page exposes the language switcher', app.includes("title: const TaxiLocalizedText(russian: 'Кабинет водителя', kyrgyz: 'Айдоочунун кабинети')") && app.includes("actions: const [Padding(padding: EdgeInsets.only(right: 12), child: TaxiLanguageSwitcher())]"));
check('Driver login title, fields and actions are localized', app.includes("Айдоочунун телефону") && app.includes("АЙДООЧУ КАТАРЫ КИРҮҮ") && app.includes("АЙДООЧУ БОЛУУГА ӨТҮНМӨ БЕРҮҮ"));
check('Client login password field is localized', app.includes("Сырсөз (кеминде 6 белги)"));
check('Client registration name field is localized', app.includes("Атыңыз"));
check('Widget test covers client login language switching', read('testapp/test/widget_test.dart').includes('Localized login screens'));

// These regression checks must inspect the actual source and run before the
// summary; literal true values would silently allow a broken UI through CI.
const driverStart = app.indexOf('class DriverMapScreen');
const dispatcherStart = app.indexOf('class DispatcherScreen');
const driverUi = driverStart >= 0 ? app.slice(driverStart, dispatcherStart > driverStart ? dispatcherStart : undefined) : '';
const dispatcherUi = dispatcherStart >= 0 ? app.slice(dispatcherStart) : '';
check("Driver cabinet uses branded green header", /backgroundColor: const Color\(0xFF087A42\)/.test(driverUi) && /foregroundColor: Colors\.white/.test(driverUi));
check("Driver cabinet exposes language switcher", driverUi.includes('TaxiLanguageSwitcher()'));
check("Driver approach route is high-contrast gold", /PolylineLayer\(polylines: \[Polyline\(points: _driverApproachRoute!\.points, color: const Color\(0xFFFFD400\)/.test(driverUi));
check("Driver marker has black and gold frame", /color: const Color\(0xFF171717\), shape: BoxShape\.circle, border: Border\.all\(color: const Color\(0xFFFFD400\)/.test(driverUi));
check("Open pickup marker uses branded gold pin", /color: const Color\(0xFFFFD400\), shape: BoxShape\.circle, border: Border\.all\(color: const Color\(0xFF171717\)/.test(driverUi));
check("Assigned pickup marker uses contrasting gold flag", driverUi.includes("child: const Icon(Icons.flag, color: Color(0xFF171717), size: 25)"));
check("Driver order panel uses light surface with green accent", /decoration: BoxDecoration\(color: const Color\(0xFFFFFEFA\), border: Border\(top: BorderSide\(color: const Color\(0xFF087A42\)/.test(driverUi));
check("Driver panel title uses green and supports live localization", driverUi.includes("TaxiLocalizedText(russian: 'Заказы и их статусы обновляются с сервера'") && driverUi.includes('fontSize: 14, color: Color(0xFF087A42)'));
check("Assigned order heading is localized and retains the driver accent", driverUi.includes("TaxiLocalizedText(russian: 'ВАШ НАЗНАЧЕННЫЙ ЗАКАЗ'") && driverUi.includes('color: Color(0xFF087A42)'));
check("Dispatcher header uses branded green styling", /backgroundColor: const Color\(0xFF087A42\)/.test(dispatcherUi) && /foregroundColor: Colors\.white/.test(dispatcherUi));


// Offline drivers must still be able to restore an assigned trip; only the open queue
// is restricted to online drivers with fresh GPS.
const openRouteStart = worker.indexOf('if (url.pathname === "/orders/open" && request.method === "GET")');
const openRouteEnd = worker.indexOf('if (url.pathname === "/orders/status"', openRouteStart);
const openRouteSource = openRouteStart >= 0 && openRouteEnd > openRouteStart
  ? worker.slice(openRouteStart, openRouteEnd)
  : '';
check('Assigned-order endpoint permits approved offline drivers to restore active trips', openRouteSource.includes('requireApprovedDriver(request, env);') && !openRouteSource.includes('requireApprovedDriver(request, env, true)'));
check('Open-order query still requires the driver to be online', /status='new'[\s\S]*?available_driver\.online=1/.test(worker));
check('Open-order query still requires fresh driver GPS', /available_driver\.location_updated_at BETWEEN \? AND \?/.test(worker));
check('Assigned-order query is independent of driver online status', /const assignedOrders = await env\.DB\.prepare\([\s\S]*?status IN \('driver_assigned','arrived'\) AND assigned_driver_uid=\?/.test(worker));
check('Driver screen restores assigned orders immediately even when offline', (() => { const start=app.indexOf('void initState()', app.indexOf('class _DriverMapScreenState')); const end=app.indexOf('_ordersPollTimer =', start); const block=app.slice(start,end); return block.includes('if (_driverWantsOnline && currentDriver != null)') && block.includes('unawaited(_pollServerOrders());'); })());
check('Driver order polling does not stop solely because the driver is offline', app.includes('if (_ordersPollInProgress) {') && !app.includes('if (!mounted || !_driverWantsOnline || _ordersPollInProgress) return;'));
check('Driver order polling remains protected against overlapping requests', app.includes('if (_ordersPollInProgress) {') && app.includes('_ordersPollInProgress = true;') && app.includes('_ordersPollInProgress = false;') && app.includes('_ordersPollRefreshPending = true;') && app.includes('_ordersPollRefreshPending = false;'));
check('Passenger screen observes Android app lifecycle', app.includes('class _ClientMapScreenState extends State<ClientMapScreen> with WidgetsBindingObserver'));
check('Passenger screen registers and removes its lifecycle observer', app.includes('WidgetsBinding.instance.addObserver(this);') && app.includes('WidgetsBinding.instance.removeObserver(this);'));
check('Passenger GPS and nearby cars refresh when app resumes', app.includes('if (state != AppLifecycleState.resumed || !mounted) return;') && app.includes('unawaited(_locateClient(showMessage: false));') && app.includes('unawaited(_refreshNearbyDrivers());'));
check('Passenger resume GPS refresh does not override manually selected pickup', app.includes('_locateClient(showMessage: false)') && app.includes('_clientPickupManuallySelected'));
check('Driver screen observes Android app lifecycle', app.includes('class _DriverMapScreenState extends State<DriverMapScreen> with WidgetsBindingObserver'));
check('Driver screen registers and removes its lifecycle observer', (app.match(/WidgetsBinding\.instance\.addObserver\(this\);/g) || []).length === 2 && (app.match(/WidgetsBinding\.instance\.removeObserver\(this\);/g) || []).length === 2);
check('Driver order list refreshes immediately after app resumes', app.includes('unawaited(_pollServerOrders());') && app.includes('state != AppLifecycleState.resumed'));
check('Driver restarts GPS stream after Android paused or dropped it', app.includes('if (_positionSubscription == null)') && app.includes('unawaited(_startLocationTracking());'));
check('Driver refreshes live GPS heartbeat on resume when stream exists', app.includes('unawaited(_refreshDriverHeartbeat(driver));'));
check('Driver resume recovery never turns an explicitly offline driver online', app.includes('if (!_driverWantsOnline || driver == null) return;'));

check('GPS and manual pickup changes request a nearby-driver refresh',
  app.includes('unawaited(_refreshNearbyDrivers());') &&
  nearbyRefreshBlock.includes('WorkerApi.nearbyDrivers()'));
check('Offline restore accepts only assigned and arrived active statuses',
  orderSnapshot.includes("allowedStatuses: const {'driver_assigned', 'arrived'}") &&
  orderSnapshot.includes('!allowedStatuses.contains(status)') &&
  orderSnapshotTests.includes('rejects an invalid assigned-order status') &&
  app.includes('_serverAssignedOrders = assigned;'));
check('Offline restore clears stale route when there is no active assignment', app.includes('if (assigned.isEmpty) {') && app.includes('_driverApproachRoute = null;') && app.includes('_driverRouteOrderId = null;'));
check('Periodic order refresh continues to recover an assigned trip', app.includes('Timer.periodic(const Duration(seconds: 5), (_) {') && app.includes('_pollServerOrders();'));

// Cancellation safeguards: malformed requests are rejected and state changes are atomic.
const cancelStart = worker.indexOf('if (url.pathname === "/orders/cancel" && request.method === "POST")');
const cancelEnd = worker.indexOf('if (url.pathname === "/orders/respond"', cancelStart);
const cancelRoute = cancelStart >= 0 && cancelEnd > cancelStart ? worker.slice(cancelStart, cancelEnd) : '';
check('Cancellation rejects malformed, non-object and array request bodies through the shared JSON reader', cancelRoute.includes('const b = await readJsonObject(request);') && cancelRoute.includes('if (!b)'));
check('Cancellation validates order IDs before database lookup', cancelRoute.includes('/^[A-Za-z0-9_-]{1,128}$/.test(orderId)'));
check('Cancellation accepts only explicit customer or driver roles', cancelRoute.includes('["customer", "driver"].includes(role)'));
check('Customer cancellation and response cleanup run in one D1 batch', cancelRoute.includes('const customerCancelResults = await env.DB.batch([') && cancelRoute.includes('DELETE FROM order_responses WHERE order_id=?'));
check('Customer cancellation checks the conditional status transition result', cancelRoute.includes('customerCancelResults?.[0]?.meta?.changes') && cancelRoute.includes("status IN ('new','driver_assigned')"));
check('Driver pre-arrival refusal, audit and response cleanup run in one D1 batch', cancelRoute.includes('const driverRefusalResults = await env.DB.batch([') && cancelRoute.includes('INSERT OR IGNORE INTO order_refusals') && cancelRoute.includes('DELETE FROM order_responses WHERE order_id=? AND driver_uid=?'));
check('Driver refusal cannot reopen an order after a concurrent status change', cancelRoute.includes('driverRefusalResults?.[0]?.meta?.changes') && cancelRoute.includes("status='driver_assigned'"));

// All user-supplied JSON bodies are parsed through one safe object reader.
check('Worker JSON reader converts malformed and empty request bodies into client validation failures', /async function readJsonObject\(request\)[\s\S]*?try \{[\s\S]*?await request\.json\(\)[\s\S]*?catch \(_\)[\s\S]*?return null;/.test(worker));
check('Worker JSON reader rejects arrays and primitive JSON values', /return value && typeof value === "object" && !Array\.isArray\(value\) \? value : null;/.test(worker));
check('Worker JSON reader is the only direct request JSON parser', (worker.match(/request\.json\(\)/g) || []).length === 1);
check('All 24 POST JSON handlers use the safe JSON reader', (worker.match(/await readJsonObject\(request\)/g) || []).length === 24);
const driverCompleteRoute = worker.slice(worker.indexOf('url.pathname === "/orders/complete-driver"'));
check('Driver can complete only their own assigned trip and save it once to the finance ledger',
  driverCompleteRoute.includes('requireApprovedDriver(request, env)') &&
  driverCompleteRoute.includes("assigned_driver_uid=?") &&
  driverCompleteRoute.includes("ON CONFLICT(order_id) DO NOTHING") &&
  driverCompleteRoute.includes("status='completed'"));
check('Driver registration and document upload reject malformed JSON before field access', /\/drivers\/register[\s\S]*?readJsonObject\(request\)[\s\S]*?if \(!b\)/.test(worker) && /\/drivers\/documents[\s\S]*?readJsonObject\(request\)[\s\S]*?if \(!b\)/.test(worker));
check('Driver review and approval reject malformed JSON before field access', /\/drivers\/review[\s\S]*?readJsonObject\(request\)[\s\S]*?if \(!b\)/.test(worker) && /\/drivers\/approve[\s\S]*?readJsonObject\(request\)[\s\S]*?if \(!b\)/.test(worker));
check('Tariff, commission and shift handlers reject malformed JSON before numeric conversion', /\/tariffs[\s\S]*?readJsonObject\(request\)[\s\S]*?if \(!b\)/.test(worker) && /\/drivers\/commission[\s\S]*?readJsonObject\(request\)[\s\S]*?if \(!b\)/.test(worker) && /\/dispatcher\/shifts\/close[\s\S]*?readJsonObject\(request\)[\s\S]*?if \(!b\)/.test(worker));
check('Order assignment, online status and publishing reject malformed JSON before database writes', /\/orders\/assign[\s\S]*?readJsonObject\(request\)[\s\S]*?if \(!b\)/.test(worker) && /\/drivers\/online[\s\S]*?readJsonObject\(request\)[\s\S]*?if \(!b\)/.test(worker) && /\/orders\/publish[\s\S]*?readJsonObject\(request\)[\s\S]*?if \(!b\)/.test(worker));
check('Order sync, completion and arrival reject malformed JSON before database writes', /\/orders\/sync[\s\S]*?readJsonObject\(request\)[\s\S]*?if \(!b\)/.test(worker) && /\/orders\/complete[\s\S]*?readJsonObject\(request\)[\s\S]*?if \(!b\)/.test(worker) && /\/orders\/arrived[\s\S]*?readJsonObject\(request\)[\s\S]*?if \(!b\)/.test(worker));
check('Order cancellation and driver self-selection reject malformed JSON before database reads', /\/orders\/cancel[\s\S]*?readJsonObject\(request\)[\s\S]*?if \(!b\)/.test(worker) && /\/orders\/respond[\s\S]*?readJsonObject\(request\)[\s\S]*?if \(!b\)/.test(worker));
check('Radio message and push-to-talk actions reject malformed JSON before field access', /\/radio\/messages[\s\S]*?readJsonObject\(request\)[\s\S]*?if \(!body\)/.test(worker) && /\/radio\/ptt[\s\S]*?readJsonObject\(request\)[\s\S]*?if \(!body\)/.test(worker));
check('Dispatcher overview uses a strict bounded snapshot parser', app.includes("import 'services/dispatcher_overview_snapshot.dart';") && app.includes('DispatcherOverviewSnapshot.parse(data)'));
check('Dispatcher overview parser validates all five dashboard sections', read('testapp/lib/services/dispatcher_overview_snapshot.dart').includes("'drivers'") && read('testapp/lib/services/dispatcher_overview_snapshot.dart').includes("'closed_shifts'"));
check('Dispatcher dashboard rejects duplicate driver and order identifiers', read('testapp/lib/services/dispatcher_overview_snapshot.dart').includes("seen.add(id)") && read('testapp/test/dispatcher_overview_snapshot_test.dart').includes('rejects duplicate order IDs'));
check('Dispatcher dashboard enforces Worker order page limit', read('testapp/lib/services/dispatcher_overview_snapshot.dart').includes('maxOrders = 100'));
check('Dispatcher dashboard validates business date and daily status counts', read('testapp/lib/services/dispatcher_overview_snapshot.dart').includes('business_date') && read('testapp/lib/services/dispatcher_overview_snapshot.dart').includes('count % 1 != 0'));
check('Dispatcher dashboard preserves last good state when response parsing fails', app.includes('final snapshot = DispatcherOverviewSnapshot.parse(data);') && app.includes('_dispatcherRefreshError = e.toString();'));
check('Dispatcher dashboard refresh requests are coalesced instead of dropped', app.includes('_dispatcherRefreshPending = true;') && app.includes('scheduleMicrotask(() => _load(showLoading: false));'));
check('Dispatcher dashboard ignores responses from a previous Firebase account', app.includes('FirebaseAuth.instance.currentUser?.uid != requestUid'));
check('Dispatcher dashboard copies validated immutable rows into UI state', app.includes('_drivers = snapshot.drivers.map((e) => Map<String, dynamic>.from(e)).toList();'));
check('Dispatcher snapshot regression tests cover malformed and duplicate data', read('testapp/test/dispatcher_overview_snapshot_test.dart').includes('rejects a malformed row') && read('testapp/test/dispatcher_overview_snapshot_test.dart').includes('returns immutable row maps and lists'));


check('Dispatcher section headings wrap and localize inside the available phone width', app.includes('Expanded(\n          child: TaxiLocalizedText(\n            russian: value,') && app.includes('softWrap: true,') && app.includes('kyrgyz: TaxiLanguage.translate(value)'));

check('Dispatcher app-bar title truncates safely on narrow devices', app.includes("'Диспетчер · ЖОЛ АМАН КЕНЧИ',\n          maxLines: 1,\n          softWrap: false,\n          overflow: TextOverflow.ellipsis,"));
check('Driver assigned-order completion remains available after removing the dispatcher arrived-orders panel', app.includes('_completeAssignedOrder(item)') && app.includes("russian: 'ЗАКАЗ ИСПОЛНЕН'"));
check('Closed-shift earnings trailing text has a bounded responsive width', app.includes('trailing: SizedBox(\n                    width: 116,') && app.includes('maxLines: 2,\n                      softWrap: true,'));


check('Passenger taxi screen provides an explicit logout action', app.includes("tooltip: 'Выйти из аккаунта пассажира'") && app.includes('onPressed: _clientLoggingOut ? null : _logoutClient'));
check('Passenger logout asks for confirmation and warns that an active order is not cancelled', app.includes("title: const TaxiLocalizedText(russian: 'Выйти из аккаунта?'") && app.includes('Текущий заказ не будет отменён'));
check('Passenger logout signs out, clears local client state and returns to role selection', app.includes('await FirebaseService.signOut().timeout(const Duration(seconds: 20));') && app.includes('TaxiParkState.currentLoggedInClient = null;') && app.includes('Navigator.of(context).pushAndRemoveUntil('));
check('Passenger logout prevents duplicate taps and cancels local polling timers', app.includes('bool _clientLoggingOut = false;') && app.includes('_orderStatusTimer?.cancel();\n      _nearbyDriversTimer?.cancel();'));
check('Shared radio message input uses dark text on an explicit white background', app.includes('color: Color(0xFF171717),\n                fontSize: 15,') && app.includes('filled: true,\n                fillColor: Colors.white,'));
check('Shared radio input has visible hint, cursor and focused borders', app.includes('cursorColor: Color(0xFF8A6500),') && app.includes('hintStyle: TextStyle(color: Colors.black54)') && app.includes('focusedBorder: OutlineInputBorder('));


check('Driver logout waits until the server order list has been checked', app.includes('bool _assignedOrdersLoaded = false;') && app.includes('_assignedOrdersLoaded = true;') && app.includes('if (!_assignedOrdersLoaded) {') && app.includes('unawaited(_pollServerOrders());'));
check('Driver cannot log out while an assigned trip remains active', app.includes('if (_serverAssignedOrders.isNotEmpty) {') && app.includes('Нельзя выйти из аккаунта во время назначенного заказа'));
check('Driver logout has a duplicate-action guard', app.includes('bool _logoutInProgress = false;') && app.includes('if (_logoutInProgress || _availabilityChanging || _offlineSyncInProgress) return;'));
check('Driver logout disables its button while logout is running', app.includes('(_availabilityChanging || _logoutInProgress) ? null : _logoutDriver'));
check('Driver logout cancels location retry before leaving the line', app.includes('_locationRetryTimer?.cancel();\n        _locationRetryTimer = null;'));
check('Driver logout stops the GPS subscription and heartbeat before sign-out', app.includes('await _positionSubscription?.cancel();\n        _positionSubscription = null;\n        _stopLocationHeartbeat();'));
check('Driver logout confirms server-side offline state before Firebase sign-out', (() => { const start=app.indexOf('Future<void> _logoutDriver()'); const end=app.indexOf('\n  @override', start); const block=app.slice(start,end); const request=block.indexOf('WorkerApi.setDriverOnline(online: false)'); const confirmation=block.indexOf("if (result['online'] != false)"); const signOut=block.indexOf('FirebaseService.signOut()'); return request >= 0 && confirmation > request && signOut > confirmation; })());
check('Driver logout keeps authentication when server offline confirmation fails', app.includes('Не удалось безопасно выйти. Аккаунт оставлен открытым') && app.includes('if (!_driverWantsOnline) _scheduleOfflineStateRetry();'));
check('Driver logout clears local availability before requesting server offline state', app.includes('_driverWantsOnline = false;\n          _driverGpsReady = false;\n          _serverOpenOrders = [];'));
check('Driver logout only clears the driver session after Firebase sign-out succeeds', app.includes('await FirebaseService.signOut().timeout(const Duration(seconds: 20));\n      TaxiParkState.currentLoggedInDriver = null;'));


check('Driver logout always asks the server to confirm offline state, including after a previous failed attempt', app.includes('Always ask the server to confirm offline state') && app.includes('final result = await WorkerApi.setDriverOnline(online: false)') && app.includes('await FirebaseService.signOut().timeout(const Duration(seconds: 20));'));
check('Driver logout server-offline request is not conditional on the local online flag', (() => { const start=app.indexOf('Future<void> _logoutDriver()'); const end=app.indexOf('\n  @override',start); const block=app.slice(start,end); return block.includes('WorkerApi.setDriverOnline(online: false)') && !block.includes('if (_driverWantsOnline)'); })());
check('Driver logout cancels any pending offline retry before its final server confirmation', app.includes('_offlineSyncRetryTimer?.cancel();\n      _offlineSyncRetryTimer = null;\n      await _positionSubscription?.cancel();'));
check('Driver logout confirms server offline state before Firebase sign-out on every path', (() => { const start=app.indexOf('Future<void> _logoutDriver()'); const end=app.indexOf('\n  @override',start); const block=app.slice(start,end); return block.indexOf('WorkerApi.setDriverOnline(online: false)') >= 0 && block.indexOf('WorkerApi.setDriverOnline(online: false)') < block.indexOf('FirebaseService.signOut()'); })());
check('Driver logout preserves the session if offline confirmation times out or fails', app.includes('Не удалось безопасно выйти. Аккаунт оставлен открытым') && app.includes('if (!_driverWantsOnline) _scheduleOfflineStateRetry();'));
check('Driver logout cannot bypass a scheduled offline retry by relying only on local online state', app.includes('even if the local') && app.includes('previous failed request must never be bypassed by signing out'));
check('Driver logout clears local online and GPS-ready flags before server request', app.includes('_driverWantsOnline = false;\n        _driverGpsReady = false;\n        _serverOpenOrders = [];'));
check('Driver logout cancels GPS retry and stops the position stream before server request', app.includes('_locationRetryTimer?.cancel();\n      _locationRetryTimer = null;') && app.includes('await _positionSubscription?.cancel();\n      _positionSubscription = null;'));
check('Driver logout stops the heartbeat before server confirmation', app.includes('_positionSubscription = null;\n      _stopLocationHeartbeat();\n\n      final result = await WorkerApi.setDriverOnline(online: false)'));
check('Driver logout retains the active-trip and initial-order-check safeguards', app.includes('if (!_assignedOrdersLoaded) {') && app.includes('if (_serverAssignedOrders.isNotEmpty) {'));


check('Legacy Firebase Storage helper retains the configured project bucket for existing previews', app.includes("const String taxiFirebaseStorageBucket =\n    'gs://jol-aman-kenchi.firebasestorage.app';") && app.includes('FirebaseStorage.instanceFor(bucket: taxiFirebaseStorageBucket)'));
check('Dispatcher legacy document preview uses the configured bucket', app.includes('future: taxiFirebaseStorage.ref(path).getData(8 * 1024 * 1024)'));
check('No dispatcher document preview falls back to the Firebase default bucket', !app.includes('FirebaseStorage.instance.ref(path)'));
check('Configured Firebase bucket retains the exact project identifier', app.includes('jol-aman-kenchi.firebasestorage.app'));
check('Firebase Storage reads share one configured bucket helper', app.split('taxiFirebaseStorage.ref').length >= 2);


check('Worker stores document transfer requests as metadata only', worker.includes('CREATE TABLE IF NOT EXISTS driver_document_transfer_requests') && worker.includes('CREATE TABLE IF NOT EXISTS driver_document_receipts'));
check('Document transfer requests are dispatcher-authorized and persistent', worker.includes('url.pathname === "/drivers/documents/request" && request.method === "POST"') && worker.includes('requested_by TEXT NOT NULL') && worker.includes("status IN ('requested','transferring')"));
check('Pending drivers can request their own document-transfer token only', worker.includes('url.pathname === "/drivers/documents/token" && request.method === "POST"') && worker.includes('auth.user.localId !== transfer.driver_uid'));
check('Document transfer uses a dedicated per-request LiveKit room', worker.includes('jol-aman-kenchi-docs-') && worker.includes('createLiveKitToken(env, auth.user.localId, name, room)'));
check('Dispatcher receipt confirmation validates exactly three document hashes and sizes', worker.includes('files.length !== 3') && worker.includes('^[a-f0-9]{64}$') && worker.includes('total > 18 * 1024 * 1024'));
check('Document receipt metadata is committed before review status is pending', worker.includes('driver_document_receipts') && worker.includes("review_status='pending'") && worker.includes("status='received'"));
check('Flutter API exposes authenticated document request, polling, token and receipt methods', api.includes('requestDriverDocuments') && api.includes('driverDocumentRequest') && api.includes('driverDocumentsTransferToken') && api.includes('confirmDriverDocumentsReceived'));
check('Document transfer uses D1 metadata and does not put image bytes in D1', !/CREATE TABLE IF NOT EXISTS driver_document_transfer_requests[\\s\\S]{0,900}BLOB/i.test(worker));

// Responsive green driver/dispatcher surfaces and language-switch regression guards.
check('Driver header title truncates safely on compact screens', app.includes("maxLines: 1,\n          softWrap: false,\n          overflow: TextOverflow.ellipsis,"));
check('Driver order controls remain reachable in a bounded scrollable panel on short screens', app.includes('maxHeight: MediaQuery.sizeOf(context).height * 0.42') && app.includes('child: SingleChildScrollView(\n                child: Column('));
check('Driver green panel keeps its contrast and identity while using compact padding', app.includes('padding: const EdgeInsets.fromLTRB(12, 10, 12, 10)') && app.includes('Color(0xFF087A42)'));
check('Dispatcher app bar retains a one-line ellipsized title for narrow screens', app.includes("'Диспетчер · ЖОЛ АМАН КЕНЧИ',\n          maxLines: 1,\n          softWrap: false,\n          overflow: TextOverflow.ellipsis,"));
check('Russian and Kyrgyz language selector remains available in driver and dispatcher headers', (app.match(/TaxiLanguageSwitcher\(\)/g) || []).length >= 3);
check('Language selector exposes both supported language values', localization.includes("DropdownMenuItem(value: 'ru', child: Text('Русский'))") && localization.includes("DropdownMenuItem(value: 'ky', child: Text('Кыргызча'))"));
check('Language change is reactive and localized text listens to the shared language state', localization.includes('TaxiLanguage.current.value = value') && localization.includes('valueListenable: TaxiLanguage.current') && localization.includes("language == 'ky' ? (kyrgyz ?? TaxiLanguage.translate(russian)) : russian") && localization.includes('static String translate(String russian) {'));
check('Language switch regression tests cover live switching and narrow layout', read('testapp/test/responsive_language_test.dart').includes("expect(TaxiLanguage.isKyrgyz, isTrue)") && read('testapp/test/responsive_language_test.dart').includes('width: 220'));
check('Driver route map, location stream and order polling code remain present after layout changes', app.includes('FlutterMap(\n              mapController: _driverMapController') && app.includes('_positionSubscription') && app.includes('_pollServerOrders();'));
check('Dispatcher refresh and server-backed driver/order loading remain present after layout changes', app.includes('_dispatcherRefreshTimer = Timer.periodic') && app.includes('WorkerApi.dispatcherOverview()') && app.includes('WorkerApi.assignOrder'));
check('Firebase session restoration and role authorization remain in place', app.includes('FirebaseAuth.instance.currentUser') && app.includes('WorkerApi.checkAuth()') && app.includes("access['dispatcher']") && app.includes("access['driver']"));


check('Driver text chat availability depends only on server-assigned trips after removing the local-only order flow', (() => { const start=app.indexOf('class _DriverMapScreenState'); const end=app.indexOf('class DispatcherScreen',start); const block=app.slice(start,end); return block.includes('allowText: _serverAssignedOrders.isEmpty)') && !block.includes('order.status != \'accepted\''); })());
check('Driver local-only demo completion cannot show a false financial credit', !app.includes("Поездка завершена! Зачислено:") && !app.includes('void _completeOrder(TaxiOrder order)') && !app.includes('onPressed: () => _acceptOrder(order)'));
check('Driver online preference is stored locally per authenticated UID', app.includes('getApplicationSupportDirectory()') && app.includes('_readDriverLinePreference') && app.includes('_saveDriverLinePreference'));
check('An already-online server profile is captured as local preference on first launch', app.includes('unawaited(_saveDriverLinePreference(currentDriver.id, true))'));
check('Both automatic session restoration and manual driver login restore the saved line preference', app.includes('await _readDriverLinePreference(restoringUid)') && app.includes('await _readDriverLinePreference(driverUid)'));
check('Explicit offline action clears the saved line preference', (() => { const start=app.indexOf('Future<void> _toggleDriverAvailability()'); const end=app.indexOf('\n  void _showLocationMessage',start); const block=app.slice(start,end); return block.includes('_saveDriverLinePreference(') && block.includes('false,'); })());
check('Explicit online action saves the line preference before GPS startup', (() => { const start=app.indexOf('Future<void> _toggleDriverAvailability()'); const end=app.indexOf('\n  void _showLocationMessage',start); const block=app.slice(start,end); const save=block.indexOf('_saveDriverLinePreference('); const gps=block.indexOf('_startLocationTracking()'); return save>=0 && gps>save && block.includes('true,'); })());
check('Dispatcher restore-access action uses a responsive card action layout', app.includes("label: const Text('ВОССТАНОВИТЬ ДОПУСК')") && app.includes('Wrap(\n                            spacing: 8,') && app.includes('alignment: WrapAlignment.end'));


check('Dispatcher can force a driver offline without cancelling the assigned trip',worker.includes('url.pathname === "/dispatcher/drivers/force-offline"')&&worker.includes('active_order_preserved:!!active')&&app.includes('_forceDriverOffline(d)'));
check('A forced-offline driver remains unavailable to new orders while GPS continues for an assigned trip',worker.includes('dispatcher_forced_offline INTEGER NOT NULL DEFAULT 0')&&worker.includes('dispatcher_forced_offline:true,location_updated:true')&&api.includes("'/drivers/return-to-line'")&&app.includes("_dispatcherForcedOffline = true")&&app.includes('WorkerApi.returnDriverToLine()'));
check('Driver self-close uses approved-driver Firebase UID and its own protected endpoint',worker.includes('url.pathname==="/driver/shifts/close"')&&worker.includes('requireApprovedDriver(request,env)')&&api.includes("'/driver/shifts/close'"));
check('Driver self-close button appears only when server reports unclosed trips',app.includes("_driverEarnings['can_close_shift']==true")&&app.includes('_closeOwnDriverShift'));
check('Driver and dispatcher financial calculations never silently replace a missing commission with 50 percent',!worker.includes('COALESCE(MAX(c.commission_percent),50)')&&!worker.includes('commission?.commission_percent ?? 50')&&!app.includes("_driverEarnings['commission_percent'] ?? 50")&&!app.includes("row['commission_percent'] as num?)?.toInt() ?? 50"));
check('Commission settings have no automatic 50 percent default or driver backfill',!worker.includes('commission_percent INTEGER NOT NULL DEFAULT 50')&&!worker.includes('SELECT uid, 50 FROM drivers'));
check('Only legacy commission rows without a dispatcher audit are cleared',worker.includes('DELETE FROM driver_commission_settings WHERE updated_by IS NULL')&&worker.includes('updated_by=excluded.updated_by'));
check('FCM push token registration and Android notification channel are wired',worker.includes('driver_push_tokens')&&api.includes("'/drivers/push-token'")&&pubspec.includes('firebase_messaging:')&&pubspec.includes('flutter_local_notifications:')&&manifest.includes('POST_NOTIFICATIONS')&&app.includes('driverOrderNotificationChannel'));
check('New orders are sent as high-priority audible Firebase push notifications',worker.includes('notifyOnlineDriversOfNewOrder(env')&&worker.includes('priority:"high"')&&worker.includes('sound:"default"'));

for (const item of checks) {
  process.stdout.write(`${item.ok ? 'PASS' : 'FAIL'}  ${item.label}\n`);
}
const failed = checks.filter((item) => !item.ok);
process.stdout.write(`\nPreflight: ${checks.length - failed.length}/${checks.length} checks passed.\n`);
if (failed.length) process.exitCode = 1;
