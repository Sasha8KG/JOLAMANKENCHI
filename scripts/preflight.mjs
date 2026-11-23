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

for (const item of checks) {
  process.stdout.write(`${item.ok ? 'PASS' : 'FAIL'}  ${item.label}\n`);
}
const failed = checks.filter((item) => !item.ok);
process.stdout.write(`\nPreflight: ${checks.length - failed.length}/${checks.length} checks passed.\n`);
if (failed.length) process.exitCode = 1;
