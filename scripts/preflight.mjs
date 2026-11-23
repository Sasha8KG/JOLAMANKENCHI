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
check('Android launcher label matches the approved app name', /android:label="«Жол Аман Кенчи» Такси"/.test(manifest));

for (const item of checks) {
  process.stdout.write(`${item.ok ? 'PASS' : 'FAIL'}  ${item.label}\n`);
}
const failed = checks.filter((item) => !item.ok);
process.stdout.write(`\nPreflight: ${checks.length - failed.length}/${checks.length} checks passed.\n`);
if (failed.length) process.exitCode = 1;
