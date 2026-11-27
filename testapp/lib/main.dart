import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:livekit_client/livekit_client.dart' hide ConnectionState;
import 'services/firebase_service.dart';
import 'driver_registration_screen.dart';
import 'services/worker_api.dart';
import 'services/driver_document_store.dart';
import 'services/driver_document_transfer_livekit.dart';
import 'services/route_service.dart';
import 'services/route_cache_policy.dart';
import 'services/gps_freshness.dart';
import 'services/gps_fix_policy.dart';
import 'services/nearby_driver_filter.dart';
import 'services/refresh_gate.dart';
import 'services/server_order_snapshot.dart';
import 'services/dispatcher_overview_snapshot.dart';
import 'services/taxi_localization.dart';
export 'services/taxi_localization.dart';

// Use the exact bucket configured for the Firebase project. Relying on a
// platform default can select an empty or legacy bucket on some installations.
const String taxiFirebaseStorageBucket =
    'gs://jol-aman-kenchi.firebasestorage.app';
FirebaseStorage get taxiFirebaseStorage =>
    FirebaseStorage.instanceFor(bucket: taxiFirebaseStorageBucket);

// Remember the driver's explicit line preference on this phone. On the next
// login we restore it only after approval and a fresh GPS fix are confirmed.
String _driverLinePreferenceName(String uid) =>
    uid.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

Future<File> _driverLinePreferenceFile(String uid) async {
  final directory = await getApplicationSupportDirectory();
  return File(
    '${directory.path}${Platform.pathSeparator}driver_line_${_driverLinePreferenceName(uid)}.txt',
  );
}

Future<bool> _readDriverLinePreference(String uid) async {
  if (uid.trim().isEmpty) return false;
  try {
    final file = await _driverLinePreferenceFile(uid);
    return await file.exists() && (await file.readAsString()).trim() == '1';
  } catch (_) {
    return false;
  }
}

Future<void> _saveDriverLinePreference(String uid, bool online) async {
  if (uid.trim().isEmpty) return;
  try {
    final file = await _driverLinePreferenceFile(uid);
    if (online) {
      await file.writeAsString('1', flush: true);
    } else if (await file.exists()) {
      await file.delete();
    }
  } catch (_) {
    // A local preference failure must not block server-authorized line control.
  }
}

// Сохраняем проверенную карту OpenStreetMap DE: ей не нужен API-ключ.
List<Widget> buildTaxiDarkMapLayers() => [
  TileLayer(
    urlTemplate: 'https://tile.openstreetmap.de/{z}/{x}/{y}.png',
    userAgentPackageName: 'com.jolamankenchi.taxi',
  ),
  RichAttributionWidget(
    attributions: [
      TextSourceAttribution('© OpenStreetMap contributors'),
      TextSourceAttribution('Карта OpenStreetMap DE'),
    ],
  ),
];


final FlutterLocalNotificationsPlugin taxiLocalNotifications=FlutterLocalNotificationsPlugin();
const AndroidNotificationChannel driverOrderNotificationChannel=AndroidNotificationChannel(
  'driver_orders','Новые заказы',description:'Звуковые уведомления о новых заказах для водителя',
  importance:Importance.max,playSound:true,
);
@pragma('vm:entry-point')
Future<void> taxiFirebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(taxiFirebaseMessagingBackgroundHandler);
  await taxiLocalNotifications.initialize(const InitializationSettings(
    android:AndroidInitializationSettings('@drawable/ic_launcher_kyrgyz'),
  ));
  final android=taxiLocalNotifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await android?.createNotificationChannel(driverOrderNotificationChannel);
  FirebaseMessaging.onMessage.listen((message){
    unawaited(taxiLocalNotifications.show(message.hashCode,
      message.notification?.title??'Новый заказ · ЖОЛ АМАН КЕНЧИ',
      message.notification?.body??'Поступил новый заказ. Откройте приложение.',
      const NotificationDetails(android:AndroidNotificationDetails(
        'driver_orders','Новые заказы',channelDescription:'Звуковые уведомления о новых заказах для водителя',
        importance:Importance.max,priority:Priority.high,playSound:true,
      )),
    ));
  });
  runApp(const SulyuktaTaxiApp());
}

// Модель для рации
class RadioMessage {
  final String senderName;
  final String text;
  final String time;

  RadioMessage(
      {required this.senderName, required this.text, required this.time});
}

// Запись о выполненном заказе водителя для отчета диспетчера
class DriverShiftRecord {
  final String driverId;
  final String driverName;
  final String carInfo;
  int tripsCount;
  int totalEarned;

  DriverShiftRecord({
    required this.driverId,
    required this.driverName,
    required this.carInfo,
    this.tripsCount = 0,
    this.totalEarned = 0,
  });
}

// Модель диспетчера со своей кассой, ПИН-кодом и детальным отчетом по водителям
class DispatcherAccount {
  String id;
  String name;
  String phone;
  String pinCode;
  int shiftRevenue; // Общая касса смены диспетчера
  int closedOrders; // Общее количество закрытых заказов
  Map<String, DriverShiftRecord> driverReports = {};

  DispatcherAccount({
    required this.id,
    required this.name,
    required this.phone,
    required this.pinCode,
    this.shiftRevenue = 0,
    this.closedOrders = 0,
  });
}

class TaxiParkState {
  static int cityFixedPrice = 100; // Фиксированная сумма по городу
  static TaxiOrder? activeOrder;
  static ClientModel? currentLoggedInClient;
  static DriverModel? currentLoggedInDriver;

  // Уровни доступа
  static const String superAdminPin = '310184'; // Супер пин Администратора
  static DispatcherAccount? currentLoggedInDispatcher;

  // Базовые координаты: Сулюкта и Раззаков (Исфана)
  static final LatLng sulyuktaCenter = const LatLng(39.9380, 69.5650);
  static final LatLng razzakovCenter = const LatLng(39.8333, 69.8667);

  static List<DispatcherAccount> dispatchers = [
    DispatcherAccount(
        id: 'd1',
        name: 'Главный диспетчер',
        phone: '0555112233',
        pinCode: '7777',
        shiftRevenue: 0,
        closedOrders: 0),
  ];

  static List<RadioMessage> radioLog = [
    RadioMessage(
        senderName: 'Диспетчер',
        text: 'Всем водителям в Сулюкте и Раззакове добрый день!',
        time: '10:00'),
  ];

  static List<ClientModel> clients = [
    ClientModel(id: 'c1', name: 'Айбек', phone: '0700112233', pinCode: '1111'),
  ];

  static List<DriverModel> drivers = [
    DriverModel(
      id: '1',
      name: 'Асанбек',
      phone: '+996 777 11-22-33',
      carBrand: 'Honda Civic',
      carColor: 'Белый',
      plateNumber: '01KG 777 ABC',
      pinCode: '1234',
      currentLocation: LatLng(39.9380, 69.5650), // Сулюкта
      isApproved: true,
      isOnline: true,
      dailyEarnings: 500,
      customPercent: 30,
    ),
    DriverModel(
      id: '2',
      name: 'Бакыт',
      phone: '+996 555 44-55-66',
      carBrand: 'Toyota Camry',
      carColor: 'Серый',
      plateNumber: '01KG 333 DEF',
      pinCode: '5678',
      currentLocation: LatLng(39.8333, 69.8667), // Раззаков
      isApproved: true,
      isOnline: true,
      dailyEarnings: 1200,
      customPercent: 50,
    ),
  ];

  static bool isValidKgPhone(String phone) {
    return FirebaseService.isValidKgPhone(phone);
  }
}

class ClientModel {
  final String id;
  final String name;
  final String phone;
  final String pinCode;

  ClientModel(
      {required this.id,
      required this.name,
      required this.phone,
      required this.pinCode});
}

class TaxiOrder {
  final String id;
  final LatLng pickupPoint;
  final String destination;
  final ClientModel client;
  final bool isIntercity;
  final int fixedPrice;
  final bool isByContract;
  String status; // 'searching', 'accepted', 'completed'
  DriverModel? assignedDriver;
  int finalAmount;

  TaxiOrder({
    required this.id,
    required this.pickupPoint,
    required this.destination,
    required this.client,
    required this.isIntercity,
    required this.fixedPrice,
    this.isByContract = false,
    this.status = 'searching',
    this.assignedDriver,
    this.finalAmount = 0,
  });
}

class DriverModel {
  final String id;
  final String name;
  final String phone;
  final String carBrand;
  final String carColor;
  final String plateNumber;
  final String pinCode;
  LatLng currentLocation;
  DateTime? locationUpdatedAt;
  bool isApproved;
  bool isOnline;
  int dailyEarnings;
  int lastDailyEarnings;
  int customPercent;
  bool pendingIntercityReport;

  DriverModel({
    required this.id,
    required this.name,
    required this.phone,
    required this.carBrand,
    required this.carColor,
    required this.plateNumber,
    required this.pinCode,
    required this.currentLocation,
    this.locationUpdatedAt,
    this.isApproved = false,
    this.isOnline = false,
    this.dailyEarnings = 0,
    this.lastDailyEarnings = 0,
    this.customPercent = 50,
    this.pendingIntercityReport = false,
  });

  String get fullCarInfo => '$carBrand ($carColor, $plateNumber)';
}

class SessionGate extends StatefulWidget {
  const SessionGate({super.key});

  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  Widget? _destination;
  bool _restoreInProgress = false;
  String? _restoreError;

  bool _isEnabled(dynamic value) {
    if (value == true || value == 1) return true;
    final normalized = value?.toString().trim().toLowerCase();
    return normalized == 'true' || normalized == '1';
  }

  @override
  void initState() {
    super.initState();
    _restoreSavedSession();
  }

  Future<void> _restoreSavedSession() async {
    if (_restoreInProgress || !mounted) return;
    _restoreInProgress = true;
    TaxiParkState.currentLoggedInClient = null;
    TaxiParkState.currentLoggedInDriver = null;
    if (mounted) {
      setState(() {
        _restoreError = null;
        _destination = null;
      });
    }

    try {
      User? user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        if (mounted) {
          setState(() => _destination = const RoleSelectionScreen());
        }
        return;
      }

      final restoringUid = user.uid;
      // Retry temporary network failures without discarding Firebase auth.
      Map<String, dynamic>? access;
      Object? lastError;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          access = await WorkerApi.checkAuth();
          lastError = null;
          break;
        } catch (error) {
          lastError = error;
          if (attempt < 2) {
            await Future<void>.delayed(Duration(seconds: attempt + 1));
            if (!mounted) return;
            user = FirebaseAuth.instance.currentUser;
            if (user == null) {
              if (mounted) {
                setState(() => _destination = const RoleSelectionScreen());
              }
              return;
            }
          }
        }
      }
      if (lastError != null || access == null) {
        throw lastError ?? StateError('Не удалось проверить авторизацию');
      }
      if (!mounted) return;
      final activeUser = FirebaseAuth.instance.currentUser;
      if (activeUser == null || activeUser.uid != restoringUid) {
        if (mounted) {
          setState(() => _destination = const RoleSelectionScreen());
        }
        return;
      }
      user = activeUser;

      if (_isEnabled(access['dispatcher'])) {
        if (mounted) setState(() => _destination = const DispatcherScreen());
        return;
      }

      if (_isEnabled(access['driver'])) {
        final profile = await WorkerApi.driverProfile();
        if (!mounted) return;
        final profileUser = FirebaseAuth.instance.currentUser;
        if (profileUser == null || profileUser.uid != restoringUid) {
          setState(() => _destination = const RoleSelectionScreen());
          return;
        }
        final raw = profile['driver'];
        if (raw is Map) {
          final data = Map<String, dynamic>.from(raw);
          final profileUid = (data['uid'] ?? '').toString().trim();
          if (profileUid.isNotEmpty && profileUid != restoringUid) {
            throw const FormatException('Профиль водителя не совпадает с текущим аккаунтом');
          }
          final approved = _isEnabled(data['approved']);

          if (!approved) {
            if (mounted) {
              setState(() => _destination =
                  DriverReviewStatusScreen(profile: data));
            }
            return;
          }

          TaxiParkState.currentLoggedInDriver = DriverModel(
            id: (data['uid'] ?? restoringUid).toString(),
            name: (data['name'] ?? 'Водитель').toString(),
            phone: (data['phone'] ?? '').toString(),
            carBrand: (data['car_model'] ?? '').toString(),
            carColor: '',
            plateNumber: (data['car_number'] ?? '').toString(),
            pinCode: '',
            currentLocation: TaxiParkState.sulyuktaCenter,
            isApproved: true,
            isOnline: _isEnabled(data['online']) ||
                await _readDriverLinePreference(restoringUid),
          );
          if (mounted) {
            setState(() => _destination = const DriverMapScreen());
          }
          return;
        }
        throw const FormatException('Профиль водителя получен в неверном формате');
      }

      // Restore passenger profile for accounts without a driver/dispatcher role.
      final loginEmail = (user.email ?? '').trim().toLowerCase();
      var passengerPhone = (user.phoneNumber ?? '').trim();
      const emailSuffix = '@jolamankenchi.app';
      if (loginEmail.startsWith('kg996') && loginEmail.endsWith(emailSuffix)) {
        final nationalNumber =
            loginEmail.substring(5, loginEmail.length - emailSuffix.length);
        passengerPhone = '0$nationalNumber';
      }
      TaxiParkState.currentLoggedInClient = ClientModel(
        id: restoringUid,
        name: (user.displayName ?? '').trim().isEmpty
            ? 'Клиент'
            : user.displayName!.trim(),
        phone: passengerPhone,
        pinCode: '',
      );
      if (mounted) {
        setState(() => _destination = const ClientMapScreen());
      }
    } catch (error) {
      // A temporary Worker/network error must not send an authenticated user
      // back to registration or clear the saved Firebase session.
      if (mounted) {
        setState(() {
          _restoreError =
              'Не удалось восстановить вход. Проверьте интернет и повторите попытку.';
          _destination = null;
        });
      }
    } finally {
      _restoreInProgress = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_destination != null) return _destination!;
    if (_restoreError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off, size: 46, color: Colors.orange),
                const SizedBox(height: 14),
                const TaxiText(
                  'Не удалось восстановить сохранённый вход',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                TaxiText(_restoreError!, textAlign: TextAlign.center),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _restoreInProgress ? null : _restoreSavedSession,
                  icon: const Icon(Icons.refresh),
                  label: const TaxiLocalizedText(russian: 'Повторить', kyrgyz: 'Кайталоо'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 14),
            TaxiText('Восстанавливаем сохранённый вход…'),
          ],
        ),
      ),
    );
  }
}


class BrandedSplashGate extends StatefulWidget {
  const BrandedSplashGate({super.key});
  @override
  State<BrandedSplashGate> createState() => _BrandedSplashGateState();
}

class _BrandedSplashGateState extends State<BrandedSplashGate>
    with TickerProviderStateMixin {
  Timer? _navigationTimer;
  late final AnimationController _entrance;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _fade = CurvedAnimation(parent: _entrance, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.97, end: 1.0).animate(
      CurvedAnimation(parent: _entrance, curve: Curves.easeOutCubic),
    );
    _entrance.forward();
    _navigationTimer = Timer(const Duration(milliseconds: 4200), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 450),
          pageBuilder: (_, animation, secondaryAnimation) => const SessionGate(),
          transitionsBuilder: (_, animation, secondaryAnimation, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
      );
    });
  }

  @override
  void dispose() {
    _navigationTimer?.cancel();
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF102D4D),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final dpr = MediaQuery.of(context).devicePixelRatio;
          final maxWidth = constraints.maxWidth;
          final maxHeight = constraints.maxHeight;
          final imageWidth = (maxHeight * 1199 / 1312).clamp(1.0, maxWidth);
          final width = imageWidth.toDouble();
          final height = width * 1312 / 1199;
          return Stack(
            fit: StackFit.expand,
            children: [
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF0875C9), Color(0xFFB9DDF5), Color(0xFF102D4D)],
                    stops: [0.0, 0.48, 1.0],
                  ),
                ),
              ),
              Center(
                child: SizedBox(
                  width: width,
                  height: height,
                  child: FadeTransition(
                    opacity: _fade,
                    child: ScaleTransition(
                      scale: _scale,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Semantics(
                            label: 'ЖОЛ АМАН КЕНЧИ Такси',
                            image: true,
                            child: Image.asset(
                              'assets/jak_splash_optimized.webp',
                              fit: BoxFit.contain,
                              cacheWidth: (width * dpr).round().clamp(1, 1440).toInt(),
                            ),
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            top: height * 0.785,
                            child: Center(
                              child: Container(
                                width: width * 0.085,
                                height: width * 0.085,
                                decoration: const BoxDecoration(
                                  color: Color(0xFF102D4D),
                                  shape: BoxShape.circle,
                                ),
                                padding: EdgeInsets.all(4),
                                child: const CircularProgressIndicator(
                                  strokeWidth: 3.5,
                                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFFFC928)),
                                  backgroundColor: Color(0xFF8995A4),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TaxiCheckSquare extends StatelessWidget {
  const _TaxiCheckSquare({this.dark = false});
  final bool dark;
  @override
  Widget build(BuildContext context) => Container(
    width: 25, height: 25, margin: const EdgeInsets.symmetric(horizontal: 2),
    color: dark ? const Color(0xFF171717) : const Color(0xFFFFF2A6),
  );
}

class SulyuktaTaxiApp extends StatelessWidget {
  const SulyuktaTaxiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '«Жол Аман Кенчи» Такси',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE6A900),
          primary: const Color(0xFFE6A900),
          secondary: const Color(0xFF8A3028),
          surface: const Color(0xFFFFFCF5),
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F1E7),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFFD400),
          foregroundColor: Color(0xFF171717),
          centerTitle: true,
          elevation: 0,
          titleTextStyle: TextStyle(
            color: Color(0xFF171717),
            fontSize: 19,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
          ),
        ),
        cardTheme: CardTheme(
          color: const Color(0xFFFFFEFA),
          elevation: 3,
          margin: const EdgeInsets.symmetric(vertical: 7, horizontal: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFFE6A900), width: 1.2),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF171717),
            foregroundColor: const Color(0xFFFFD400),
            minimumSize: const Size(0, 58),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFFFFFFF),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: const BorderSide(color: Color(0xFFE3D8C3)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: const BorderSide(color: Color(0xFFE3D8C3)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: const BorderSide(color: Color(0xFF171717), width: 2),
          ),
        ),
      ),
      home: const BrandedSplashGate(),
    );
  }
}

class KyrgyzOrnamentHeader extends StatelessWidget {
  const KyrgyzOrnamentHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: const BoxDecoration(
        color: Color(0xFF202522),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              11,
              (index) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: TaxiText(
                  index % 2 == 0 ? '❧' : '✥',
                  style: const TextStyle(
                    color: Color(0xFFFFC928),
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 7),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.home_work_rounded, color: Color(0xFFFFD45A), size: 20),
              SizedBox(width: 8),
              TaxiText('ЖОЛ АМАН КЕНЧИ', style: TextStyle(
                color: Color(0xFFFFD45A), fontSize: 16,
                fontWeight: FontWeight.w900, letterSpacing: 1.2)),
            ],
          ),
          const SizedBox(height: 5),
          const TaxiText('СУЛЮКТА  •  ЛЕЙЛЕК  •  БАТКЕН',
            style: TextStyle(color: Colors.white70, fontSize: 10,
              letterSpacing: 1.4, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class WalkieTalkieWidget extends StatefulWidget {
  final String senderName;
  final bool allowText;
  const WalkieTalkieWidget({super.key, required this.senderName, this.allowText = true});

  @override
  State<WalkieTalkieWidget> createState() => _WalkieTalkieWidgetState();
}

class _WalkieTalkieWidgetState extends State<WalkieTalkieWidget> {
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _chatScroll = ScrollController();
  final List<Map<String, dynamic>> _messages = [];
  Room? _room;
  Timer? _chatTimer;
  Timer? _floorTimer;
  bool _connecting = false;
  bool _connected = false;
  bool _startingSpeaking = false;
  bool _speaking = false;
  bool _loadingMessages = false;
  bool _sendingMessage = false;
  String? _radioError;
  bool _pressRequested = false;
  bool _refreshingFloor = false;

  @override
  void initState() {
    super.initState();
    _connectRoom();
    _loadMessages();
    _chatTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) _loadMessages();
    });
  }

  Future<void> _connectRoom() async {
    if (!mounted || _connecting || _connected) return;
    setState(() { _connecting = true; _radioError = null; });
    Room? pendingRoom;
    try {
      final credentials = await WorkerApi.radioToken();
      final url = (credentials['url'] ?? '').toString();
      final token = (credentials['token'] ?? '').toString();
      if (url.isEmpty || token.isEmpty) throw Exception('Сервер голосовой рации не выдал параметры подключения.');
      final room = Room();
      pendingRoom = room;
      await room.connect(url, token);
      _room = room;
      if (!mounted) { await room.disconnect(); return; }
      setState(() { _connected = true; _connecting = false; });
    } catch (e) {
      try { await pendingRoom?.disconnect(); } catch (_) {}
      if (!mounted) return;
      setState(() { _connecting = false; _connected = false; _radioError = e.toString(); });
    }
  }

  Future<void> _loadMessages() async {
    if (!mounted || _loadingMessages) return;
    _loadingMessages = true;
    try {
      final result = await WorkerApi.radioMessages();
      final rawRows = result['messages'];
      final rows = <Map<String, dynamic>>[];
      if (rawRows is List) {
        for (final item in rawRows) {
          if (item is Map) {
            try { rows.add(Map<String, dynamic>.from(item)); } catch (_) {}
          }
        }
      }
      final visibleRows = rows.length > 100
          ? rows.sublist(rows.length - 100)
          : rows;
      if (mounted) setState(() { _messages
        ..clear()
        ..addAll(visibleRows); });
    } catch (_) {
      // The next poll retries; the radio remains usable for voice if chat is offline.
    } finally {
      _loadingMessages = false;
    }
  }

  Future<void> _sendTextMessage() async {
    if (!mounted || !widget.allowText || _sendingMessage) return;
    final message = _msgController.text.trim();
    if (message.isEmpty) return;
    if (message.length > 500) {
      _notice('Сообщение не должно превышать 500 символов.');
      return;
    }
    setState(() => _sendingMessage = true);
    _msgController.clear();
    try {
      await WorkerApi.sendRadioMessage(message);
      if (mounted) await _loadMessages();
    } catch (e) {
      if (mounted) {
        _msgController.text = message;
        _notice('Не удалось отправить сообщение: $e');
      }
    } finally {
      if (mounted) setState(() => _sendingMessage = false);
    }
  }

  void _pressToTalkDown() {
    _pressRequested = true;
    _startSpeaking();
  }

  Future<void> _startSpeaking() async {
    if (!mounted || _speaking || _startingSpeaking) return;
    if (!_connected || _room == null) {
      _notice('Голосовой канал не подключён. Нажмите «Подключить» и проверьте интернет.');
      return;
    }
    _startingSpeaking = true;
    try {
      await WorkerApi.radioFloor(action: 'acquire');
      if (!_pressRequested) {
        await WorkerApi.radioFloor(action: 'release');
        return;
      }
      final participant = _room?.localParticipant;
      if (participant == null) {
        await WorkerApi.radioFloor(action: 'release');
        _notice('Голосовой канал ещё не готов. Подключитесь повторно.');
        return;
      }
      await participant.setMicrophoneEnabled(true);
      if (!_pressRequested) {
        await participant.setMicrophoneEnabled(false);
        await WorkerApi.radioFloor(action: 'release');
        return;
      }
      if (!mounted) return;
      setState(() { _speaking = true; });
      _floorTimer?.cancel();
      _floorTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
        if (_refreshingFloor || !_speaking || !mounted) return;
        _refreshingFloor = true;
        try {
          await WorkerApi.radioFloor(action: 'refresh');
        } catch (_) {
          await _stopSpeaking(showNotice: true);
        } finally {
          _refreshingFloor = false;
        }
      });
    } on WorkerApiException catch (e) {
      if (e.statusCode == 409) {
        _notice('Эфир занят другим участником. Подождите очереди.');
      } else {
        _notice(e.message);
      }
    } catch (e) {
      _notice('Не удалось включить микрофон: $e');
      try { await WorkerApi.radioFloor(action: 'release'); } catch (_) {}
    } finally {
      _startingSpeaking = false;
    }
  }

  Future<void> _stopSpeaking({bool showNotice = false}) async {
    _pressRequested = false;
    _floorTimer?.cancel();
    _floorTimer = null;
    try { await _room?.localParticipant?.setMicrophoneEnabled(false); } catch (_) {}
    try { await WorkerApi.radioFloor(action: 'release'); } catch (_) {}
    if (mounted && _speaking) setState(() => _speaking = false);
    if (showNotice && mounted) _notice('Передача остановлена: потеряно соединение с эфиром.');
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: TaxiText(message)));
  }

  @override
  void dispose() {
    _pressRequested = false;
    _chatTimer?.cancel();
    _floorTimer?.cancel();
    if (_speaking || _connecting) {
      try { _room?.localParticipant?.setMicrophoneEnabled(false); } catch (_) {}
      WorkerApi.radioFloor(action: 'release').catchError((_) => <String, dynamic>{});
    }
    _room?.disconnect();
    _msgController.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber, width: 2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.wifi_tethering, color: Colors.amber), SizedBox(width: 8),
          TaxiText('ОБЩАЯ РАЦИЯ ТАКСОПАРКА', style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(_connected ? Icons.wifi : Icons.wifi_off, size: 15, color: _connected ? Colors.greenAccent : Colors.orangeAccent),
          const SizedBox(width: 6),
          Flexible(child: TaxiText(_connected ? 'Голосовой канал подключён · Сулюкта / Лейлек' : (_connecting ? 'Подключение к голосовому каналу…' : 'Голосовой канал не подключён'),
            style: const TextStyle(color: Colors.white70, fontSize: 11), textAlign: TextAlign.center)),
        ]),
        if (!_connected) ...[
          if (_radioError != null) Padding(padding: const EdgeInsets.only(top: 5), child: TaxiText(_radioError!, style: const TextStyle(color: Colors.orangeAccent, fontSize: 11), textAlign: TextAlign.center)),
          TextButton.icon(onPressed: _connecting ? null : _connectRoom, icon: const Icon(Icons.wifi, color: Colors.amber), label: const TaxiText('ПОДКЛЮЧИТЬ ГОЛОС', style: TextStyle(color: Colors.amber))),
        ],
        const SizedBox(height: 8),
        Center(child: GestureDetector(
          onTapDown: _connected ? (_) => _pressToTalkDown() : null,
          onTapUp: (_) => _stopSpeaking(),
          onTapCancel: _stopSpeaking,
          child: AnimatedContainer(duration: const Duration(milliseconds: 120), width: 92, height: 92,
            decoration: BoxDecoration(color: _speaking ? Colors.red : Colors.amber, shape: BoxShape.circle,
              boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 3))]),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(_speaking ? Icons.mic : Icons.mic_none, color: _speaking ? Colors.white : Colors.black, size: 30),
              TaxiText(_speaking ? 'ГОВОРИТЕ' : 'ЗАЖАТЬ', style: TextStyle(color: _speaking ? Colors.white : Colors.black, fontWeight: FontWeight.bold, fontSize: 11)),
            ]),
          ),
        )),
        const SizedBox(height: 4),
        const TaxiText('Удерживайте кнопку для передачи живого звука. Отпустите — микрофон выключится.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white60, fontSize: 10)),
        const Divider(color: Colors.white24, height: 18),
        const TaxiText('ОБЩИЙ ТЕКСТОВЫЙ ЧАТ', style: TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 12)),
        if (!widget.allowText) const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: TaxiText('Отправка текста временно отключена во время выполнения заказа. Освободитесь от поездки, чтобы писать в чате.', style: TextStyle(color: Colors.orangeAccent, fontSize: 11))),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _msgController,
              enabled: widget.allowText,
              style: const TextStyle(
                color: Color(0xFF171717),
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
              cursorColor: Color(0xFF8A6500),
              maxLength: 500,
              maxLines: 2,
              minLines: 1,
              decoration: InputDecoration(
                counterText: '',
                hintText: 'Написать сообщение…',
                hintStyle: TextStyle(color: Colors.black54),
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.amber),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.amber, width: 1.2),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFFFFD45A), width: 2),
                ),
                disabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Colors.white24),
                ),
              ),
            ),
          ),
          IconButton(icon: Icon(_sendingMessage ? Icons.hourglass_top : Icons.send, color: Colors.amber), onPressed: widget.allowText && !_sendingMessage ? _sendTextMessage : null),
        ]),
        const SizedBox(height: 6),
        const TaxiLocalizedText(russian: 'Сообщения общего канала:', kyrgyz: 'Жалпы каналдын билдирүүлөрү:', style: TextStyle(color: Colors.white70, fontSize: 11)),
        Container(height: 140, decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
          child: _messages.isEmpty ? const Center(child: TaxiLocalizedText(russian: 'Сообщений пока нет', kyrgyz: 'Азырынча билдирүү жок', style: TextStyle(color: Colors.white38, fontSize: 12))) : ListView.builder(
            controller: _chatScroll, reverse: true, itemCount: _messages.length,
            itemBuilder: (context, index) {
              final m = _messages[_messages.length - 1 - index];
              final stamp = (m['created_at'] as num?)?.toInt() ?? 0;
              final dt = stamp > 0 ? DateTime.fromMillisecondsSinceEpoch(stamp * 1000).toLocal() : DateTime.now();
              final time = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
              return Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), child: TaxiText('[$time] ${m['sender_name'] ?? 'Участник'}: ${m['message'] ?? ''}', style: const TextStyle(color: Colors.amberAccent, fontSize: 12)));
            },
          )),
      ]),
    );
  }
}

class RoleSelectionScreen extends StatefulWidget {
  const RoleSelectionScreen({super.key});
  @override
  State<RoleSelectionScreen> createState() => _RoleSelectionScreenState();
}
class _RoleSelectionScreenState extends State<RoleSelectionScreen> {
  @override
  void initState() {
    super.initState();
    TaxiLanguage.current.addListener(_handleLanguageChanged);
  }
  void _handleLanguageChanged() { if (mounted) setState(() {}); }
  @override
  void dispose() {
    TaxiLanguage.current.removeListener(_handleLanguageChanged);
    super.dispose();
  }

  void _showDispatcherAuth(BuildContext context) {
    final phoneController = TextEditingController();
    final passwordController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const TaxiLocalizedText(russian: 'Вход диспетчера', kyrgyz: 'Диспетчердин кирүүсү'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: phoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Телефон диспетчера'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: passwordController,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Пароль Firebase'),
          ),
          const SizedBox(height: 8),
          const TaxiLocalizedText(russian: 'Доступ проверяется сервером. Старый локальный ПИН-код больше не используется.', kyrgyz: 'Кирүү сервер аркылуу текшерилет. Эски жергиликтүү PIN-код колдонулбайт.', style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const TaxiLocalizedText(russian: 'Отмена', kyrgyz: 'Жокко чыгаруу')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.amber),
            onPressed: () async {
              final phone = phoneController.text.trim();
              final password = passwordController.text;
              if (!TaxiParkState.isValidKgPhone(phone) || password.length < 6) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: TaxiLocalizedText(russian: 'Введите правильный номер Кыргызстана и пароль.', kyrgyz: 'Кыргызстандын туура телефон номерин жана сырсөздү киргизиңиз.')));
                return;
              }
              try {
                await FirebaseService.signInWithPhone(phone: phone, password: password);
                final access = await WorkerApi.checkAuth();
                if (access['dispatcher'] != true) {
                  await FirebaseAuth.instance.signOut();
                  throw const WorkerApiException('Эта учётная запись не имеет прав диспетчера.');
                }
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const DispatcherScreen()));
              } on FirebaseAuthException catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: TaxiText('Ошибка входа: ${e.message ?? e.code}')));
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: TaxiText(e.toString())));
              }
            },
            child: const TaxiLocalizedText(russian: 'Войти', kyrgyz: 'Кирүү'),
          ),
        ],
      ),
    ).whenComplete(() {
      Future<void>.delayed(const Duration(milliseconds: 350), () {
        phoneController.dispose();
        passwordController.dispose();
      });
    });
  }

  void _showMainMenuLanguagePicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFFFFF8E7),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.language_rounded),
              title: const Text('Русский'),
              trailing: TaxiLanguage.current.value == 'ru'
                  ? const Icon(Icons.check_circle, color: Color(0xFF087A42))
                  : null,
              onTap: () {
                TaxiLanguage.current.value = 'ru';
                Navigator.pop(sheetContext);
              },
            ),
            ListTile(
              leading: const Icon(Icons.language_rounded),
              title: const Text('Кыргызча'),
              trailing: TaxiLanguage.current.value == 'ky'
                  ? const Icon(Icons.check_circle, color: Color(0xFF087A42))
                  : null,
              onTap: () {
                TaxiLanguage.current.value = 'ky';
                Navigator.pop(sheetContext);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFB9DDF5),
      body: SafeArea(
        child: Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF087DE0), Color(0xFFF5F8FC)],
            ),
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: SingleChildScrollView(
                padding: EdgeInsets.zero,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final height = width * 2048 / 1016;
                    final dpr = MediaQuery.of(context).devicePixelRatio;
                    return SizedBox(
                      width: width,
                      height: height,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Semantics(
                            label: 'Главное меню ЖОЛ АМАН КЕНЧИ Такси',
                            image: true,
                            child: Image.asset(
                              'assets/jak_main_menu_optimized.webp',
                              fit: BoxFit.fill,
                              cacheWidth: (width * dpr).round().clamp(1, 1152).toInt(),
                            ),
                          ),
                          Positioned(
                            left: width * 0.535,
                            top: height * 0.012,
                            width: width * 0.42,
                            height: height * 0.047,
                            child: Semantics(
                              button: true,
                              label: 'Выбрать язык / Тилди тандоо',
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _showMainMenuLanguagePicker(context),
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ),
                          Positioned(
                            left: width * 0.035,
                            top: height * 0.665,
                            width: width * 0.93,
                            height: height * 0.080,
                            child: Semantics(
                              button: true,
                              label: 'Я пассажир / Мен жүргүнчүмүн',
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => const ClientAuthScreen()),
                                ),
                              child: Center(
                                child: Container(
                                  width: width * 0.82,
                                  height: height * 0.056,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0xFFD9F3FF),
                                        Color(0xFF83C9F0),
                                        Color(0xFF368BC7),
                                      ],
                                      stops: [0.0, 0.42, 1.0],
                                    ),
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: Color(0xFFEAF9FF),
                                      width: 1.4,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Color(0xFF123F67).withOpacity(0.48),
                                        blurRadius: 9,
                                        offset: Offset(0, 7),
                                      ),
                                      BoxShadow(
                                        color: Colors.white.withOpacity(0.72),
                                        blurRadius: 2,
                                        offset: Offset(0, -2),
                                      ),
                                      BoxShadow(
                                        color: Color(0xFF4B9BCB).withOpacity(0.22),
                                        blurRadius: 12,
                                        spreadRadius: 1,
                                      ),
                                    ],
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  child: const FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: TaxiLocalizedText(
                                      russian: 'Я пассажир',
                                      kyrgyz: 'Мен жүргүнчүмүн',
                                      style: TextStyle(color: Color(0xFF103B5A), fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 0.2),
                                    ),
                                  ),
                                ),
                              ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: width * 0.035,
                            top: height * 0.758,
                            width: width * 0.93,
                            height: height * 0.080,
                            child: Semantics(
                              button: true,
                              label: 'Я водитель / Мен айдоочумун',
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => const DriverEntryScreen()),
                                ),
                              child: Center(
                                child: Container(
                                  width: width * 0.82,
                                  height: height * 0.056,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0xFFD9F3FF),
                                        Color(0xFF83C9F0),
                                        Color(0xFF368BC7),
                                      ],
                                      stops: [0.0, 0.42, 1.0],
                                    ),
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: Color(0xFFEAF9FF),
                                      width: 1.4,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Color(0xFF123F67).withOpacity(0.48),
                                        blurRadius: 9,
                                        offset: Offset(0, 7),
                                      ),
                                      BoxShadow(
                                        color: Colors.white.withOpacity(0.72),
                                        blurRadius: 2,
                                        offset: Offset(0, -2),
                                      ),
                                      BoxShadow(
                                        color: Color(0xFF4B9BCB).withOpacity(0.22),
                                        blurRadius: 12,
                                        spreadRadius: 1,
                                      ),
                                    ],
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  child: const FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: TaxiLocalizedText(
                                      russian: 'Я водитель',
                                      kyrgyz: 'Мен айдоочумун',
                                      style: TextStyle(color: Color(0xFF103B5A), fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 0.2),
                                    ),
                                  ),
                                ),
                              ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: width * 0.035,
                            top: height * 0.852,
                            width: width * 0.93,
                            height: height * 0.080,
                            child: Semantics(
                              button: true,
                              label: 'Диспетчер',
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _showDispatcherAuth(context),
                              child: Center(
                                child: Container(
                                  width: width * 0.82,
                                  height: height * 0.056,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0xFFD9F3FF),
                                        Color(0xFF83C9F0),
                                        Color(0xFF368BC7),
                                      ],
                                      stops: [0.0, 0.42, 1.0],
                                    ),
                                    borderRadius: BorderRadius.circular(18),
                                    border: Border.all(
                                      color: Color(0xFFEAF9FF),
                                      width: 1.4,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Color(0xFF123F67).withOpacity(0.48),
                                        blurRadius: 9,
                                        offset: Offset(0, 7),
                                      ),
                                      BoxShadow(
                                        color: Colors.white.withOpacity(0.72),
                                        blurRadius: 2,
                                        offset: Offset(0, -2),
                                      ),
                                      BoxShadow(
                                        color: Color(0xFF4B9BCB).withOpacity(0.22),
                                        blurRadius: 12,
                                        spreadRadius: 1,
                                      ),
                                    ],
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  child: const FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: TaxiLocalizedText(
                                      russian: 'Диспетчер',
                                      kyrgyz: 'Диспетчер',
                                      style: TextStyle(color: Color(0xFF103B5A), fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 0.2),
                                    ),
                                  ),
                                ),
                              ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

}

class ClientAuthScreen extends StatefulWidget {
  const ClientAuthScreen({super.key});
  @override
  State<ClientAuthScreen> createState() => _ClientAuthScreenState();
}
class _ClientAuthScreenState extends State<ClientAuthScreen> {
  List<String> _dispatcherPhones = [];
  bool _dispatcherPhonesLoading = true;
  String? _dispatcherPhonesError;

  Future<void> _loadDispatcherPhones() async {
    try {
      final data = await WorkerApi.getPublicDispatcherPhones();
      final raw = data['phones'];
      if (raw is! List || raw.length > 3 || raw.any((value) => value is! String)) {
        throw const FormatException('Сервер вернул неверный список телефонов.');
      }
      if (!mounted) return;
      setState(() {
        _dispatcherPhones = raw.map((value) => value.toString()).toList();
        _dispatcherPhonesLoading = false;
        _dispatcherPhonesError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() { _dispatcherPhonesLoading = false; _dispatcherPhonesError = error.toString(); });
    }
  }

  Future<void> _callDispatcherPhone(String phone) async {
    try {
      if (!await launchUrl(Uri(scheme: 'tel', path: phone))) throw Exception('Телефонное приложение недоступно.');
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: TaxiText('Не удалось открыть набор номера: $error')));
    }
  }
  @override
  void initState() {
    super.initState();
    TaxiLanguage.current.addListener(_handleLanguageChanged);
    _loadDispatcherPhones();
  }
  void _handleLanguageChanged() { if (mounted) setState(() {}); }
  @override
  void dispose() {
    TaxiLanguage.current.removeListener(_handleLanguageChanged);
    super.dispose();
  }

  void _showLoginDialog(BuildContext context) {
    final phoneController = TextEditingController();
    final pinController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const TaxiLocalizedText(russian: 'Вход клиента', kyrgyz: 'Кардар катары кирүү'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                decoration:
                    const InputDecoration(labelText: 'Телефон (0700112233)')),
            const SizedBox(height: 10),
            TextField(
                controller: pinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration:
                    InputDecoration(labelText: TaxiLanguage.isKyrgyz ? 'Сырсөз (кеминде 6 белги)' : 'Пароль (не менее 6 символов)')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const TaxiLocalizedText(russian: 'Отмена', kyrgyz: 'Жокко чыгаруу')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.amber),
            onPressed: () async {
              final phone = phoneController.text.trim();
              final password = pinController.text;
              if (!TaxiParkState.isValidKgPhone(phone) || password.length < 6) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: TaxiText('Проверьте телефон и пароль (не менее 6 символов).')));
                return;
              }
              try {
                final credential = await FirebaseService.signInWithPhone(
                  phone: phone,
                  password: password,
                );
                final user = credential.user!;
                final client = ClientModel(
                  id: user.uid,
                  name: user.displayName ?? 'Клиент',
                  phone: phone,
                  pinCode: '',
                );
                TaxiParkState.currentLoggedInClient = client;
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                Navigator.pushReplacement(context,
                    MaterialPageRoute(builder: (_) => const ClientMapScreen()));
              } on FirebaseAuthException catch (e) {
                final message = e.code == 'user-not-found' || e.code == 'wrong-password' || e.code == 'invalid-credential'
                    ? 'Неверный телефон или пароль.'
                    : 'Ошибка входа: ${e.message ?? e.code}';
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: TaxiText(message)));
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: TaxiText('Не удалось войти: $e')));
              }
            },
            child: const TaxiLocalizedText(russian: 'Войти', kyrgyz: 'Кирүү'),
          ),
        ],
      ),
    ).whenComplete(() {
      Future<void>.delayed(const Duration(milliseconds: 350), () {
        phoneController.dispose();
        pinController.dispose();
      });
    });
  }

  void _showRegisterDialog(BuildContext context) {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final pinController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const TaxiLocalizedText(russian: 'Регистрация клиента', kyrgyz: 'Кардарды каттоо'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameController,
                maxLength: 80,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(labelText: TaxiLanguage.isKyrgyz ? 'Атыңыз' : 'Ваше имя')),
            const SizedBox(height: 10),
            TextField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                    labelText: TaxiLanguage.isKyrgyz ? 'Телефон (форматы: 0700112233)' : 'Телефон (формат: 0700112233)')),
            const SizedBox(height: 10),
            TextField(
                controller: pinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Пароль (не менее 6 символов)')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const TaxiLocalizedText(russian: 'Отмена', kyrgyz: 'Жокко чыгаруу')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green, foregroundColor: Colors.white),
            onPressed: () async {
              final name = nameController.text.trim();
              final phone = phoneController.text.trim();
              final password = pinController.text;
              if (name.isEmpty || password.length < 6) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: TaxiText('Укажите имя и пароль не короче 6 символов.')));
                return;
              }
              if (!TaxiParkState.isValidKgPhone(phone)) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: TaxiText('Введите правильный номер, например 0700112233.')));
                return;
              }
              try {
                final credential = await FirebaseService.registerWithPhone(
                  phone: phone,
                  password: password,
                );
                final user = credential.user!;
                try {
                  await user.updateDisplayName(name);
                } catch (_) {
                  // Authentication succeeded; a profile-name update is optional.
                }
                TaxiParkState.currentLoggedInClient = ClientModel(
                  id: user.uid,
                  name: name,
                  phone: phone,
                  pinCode: '',
                );
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                Navigator.pushReplacement(context,
                    MaterialPageRoute(builder: (_) => const ClientMapScreen()));
              } on FirebaseAuthException catch (e) {
                final message = e.code == 'email-already-in-use'
                    ? 'Этот номер уже зарегистрирован. Войдите в аккаунт.'
                    : 'Ошибка регистрации: ${e.message ?? e.code}';
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: TaxiText(message)));
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: TaxiText('Не удалось зарегистрироваться: $e')));
              }
            },
            child: const TaxiLocalizedText(russian: 'Зарегистрироваться', kyrgyz: 'Катталуу'),
          ),
        ],
      ),
    ).whenComplete(() {
      Future<void>.delayed(const Duration(milliseconds: 350), () {
        nameController.dispose();
        phoneController.dispose();
        pinController.dispose();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: const TaxiLocalizedText(russian: 'Клиентская панель', kyrgyz: 'Кардардын панели'),
          backgroundColor: Colors.amber,
          actions: const [Padding(padding: EdgeInsets.only(right: 12), child: TaxiLanguageSwitcher())]),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const SizedBox(height: 12),
            const Icon(Icons.account_circle, size: 80, color: Colors.amber),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, padding: const EdgeInsets.symmetric(vertical: 16)),
              onPressed: () => _showLoginDialog(context),
              child: const TaxiLocalizedText(russian: 'Войти в аккаунт', kyrgyz: 'Аккаунтка кирүү',
                style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              onPressed: () => _showRegisterDialog(context),
              child: const TaxiLocalizedText(russian: 'Регистрация нового клиента', kyrgyz: 'Жаңы кардарды каттоо',
                style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 24),
            Card(child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const TaxiLocalizedText(russian: 'Телефоны диспетчера', kyrgyz: 'Диспетчердин телефондору',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const TaxiLocalizedText(
                  russian: 'Если приложение временно не работает по техническим или другим причинам, вы можете оформить заказ такси по телефонам диспетчера:',
                  kyrgyz: 'Эгер тиркеме техникалык же башка себептерден улам убактылуу иштебей калса, таксиге буйрутманы төмөнкү диспетчердик телефондор аркылуу бере аласыз:',
                ),
                const SizedBox(height: 10),
                if (_dispatcherPhonesLoading)
                  const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))
                else if (_dispatcherPhonesError != null)
                  Row(children: [
                    const Expanded(child: TaxiLocalizedText(russian: 'Не удалось загрузить телефоны.', kyrgyz: 'Телефондорду жүктөө мүмкүн болгон жок.')),
                    IconButton(onPressed: _loadDispatcherPhones, icon: const Icon(Icons.refresh)),
                  ])
                else if (_dispatcherPhones.isEmpty)
                  const TaxiLocalizedText(russian: 'Телефоны пока не добавлены.', kyrgyz: 'Телефондор азырынча кошулган жок.')
                else
                  ..._dispatcherPhones.map((phone) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.phone, color: Color(0xFF087A42)),
                    title: TaxiText(phone, style: const TextStyle(fontWeight: FontWeight.bold)),
                    trailing: const Icon(Icons.call, color: Color(0xFF087A42)),
                    onTap: () => _callDispatcherPhone(phone),
                  )),
              ]),
            )),
          ],
        ),
      ),
    );
  }
}

class ClientMapScreen extends StatefulWidget {
  const ClientMapScreen({super.key});

  @override
  State<ClientMapScreen> createState() => _ClientMapScreenState();
}

class _ClientMapScreenState extends State<ClientMapScreen> with WidgetsBindingObserver {
  LatLng _pickupPoint = TaxiParkState.sulyuktaCenter;
  final TextEditingController _destinationController = TextEditingController();
  // Поле ввода цены клиентом удалено
  bool _isIntercity = false;
  bool _isByContract = false;
  String _paymentMethod = 'Наличные';
  int _passengerCount = 1;
  bool _sendingOrder = false;
  bool _cancellingOrder = false;
  bool _clientLoggingOut = false;
  int _cityFareSom = 0;
  int _intercityFareSom = 0;
  bool _tariffsLoaded = false;
  Timer? _orderStatusTimer;
  bool _orderStatusRequestInProgress = false;
  RoadRoute? _approachRoute;
  bool _routeLoading = false;
  String? _routeError;
  String? _lastRouteKey;
  DateTime? _routeRetryAfter;
  String? _routeLoadedKey;
  DateTime? _routeLoadedAt;
  final List<MapEntry<LatLng, DateTime>> _nearbyDriverPoints = <MapEntry<LatLng, DateTime>>[];
  Timer? _nearbyDriversTimer;
  final CoalescedRefreshGate _nearbyDriversRefreshGate = CoalescedRefreshGate();
  final MapController _clientMapController = MapController();
  LatLng? _clientCurrentLocation;
  bool _clientMapReady = false;
  bool _clientLocationLoading = false;
  bool _clientPickupManuallySelected = false;
  // A default regional map center must never be mistaken for a confirmed pickup.
  bool _pickupPointConfirmed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadTariffs();
    // Determine the passenger pickup point from the phone GPS on entry.
    unawaited(_locateClient(showMessage: false));
    unawaited(_refreshNearbyDrivers());
    _nearbyDriversTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_refreshNearbyDrivers());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    // Re-check GPS on return without overwriting a pickup pin chosen manually.
    if (TaxiParkState.activeOrder == null) {
      unawaited(_locateClient(showMessage: false));
    }
    unawaited(_refreshNearbyDrivers());
  }

  Future<void> _showClientLocationSettingsDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const TaxiLocalizedText(russian: 'Доступ к геолокации запрещён', kyrgyz: 'Геолокацияга уруксат берилген жок'),
        content: const TaxiText(
          'Разрешение было запрещено в настройках телефона. '
          'Откройте настройки приложения и включите доступ к местоположению, '
          'затем вернитесь сюда и нажмите кнопку геолокации ещё раз.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const TaxiLocalizedText(russian: 'Позже', kyrgyz: 'Кийинчерээк'),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await Geolocator.openAppSettings();
            },
            icon: const Icon(Icons.settings),
            label: const TaxiLocalizedText(russian: 'Открыть настройки', kyrgyz: 'Жөндөөлөрдү ачуу'),
          ),
        ],
      ),
    );
  }

  Future<void> _locateClient({required bool showMessage}) async {
    if (!mounted || _clientLocationLoading || TaxiParkState.activeOrder != null) return;
    setState(() {
      _clientLocationLoading = true;
      if (showMessage) _clientPickupManuallySelected = false;
    });
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('Включите геолокацию (GPS) в настройках телефона.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() => _clientLocationLoading = false);
        }
        if (showMessage) {
          await _showClientLocationSettingsDialog();
        }
        return;
      }
      if (permission == LocationPermission.denied) {
        throw Exception('Разрешите приложению доступ к местоположению.');
      }
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );
      if (!isUsableGpsFix(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMeters: position.accuracy,
        timestamp: position.timestamp,
      )) {
        throw Exception('GPS вернул устаревшие или недостаточно точные координаты. Попробуйте ещё раз или отметьте точку на карте.');
      }
      final point = LatLng(position.latitude, position.longitude);
      if (!mounted) return;
      final keepManualPickup = _clientPickupManuallySelected;
      setState(() {
        _clientCurrentLocation = point;
        if (!keepManualPickup) {
          _pickupPoint = point;
          _pickupPointConfirmed = true;
        }
        _clientLocationLoading = false;
      });
      if (_clientMapReady && !keepManualPickup) {
        _clientMapController.move(point, 16.0);
      }
      unawaited(_refreshNearbyDrivers());
    } catch (error) {
      if (!mounted) return;
      setState(() => _clientLocationLoading = false);
      if (showMessage) {
        final message = error.toString().replaceFirst('Exception: ', '');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: TaxiText('Не удалось определить ваше местоположение: $message')),
        );
      }
      // Keep the Sülüktü fallback and manual map selection available.
    }
  }

  Future<void> _refreshNearbyDrivers() async {
    if (!mounted) return;
    // Do not show cars around the regional fallback center before the
    // passenger confirms a real GPS or manually selected pickup point.
    if (!_pickupPointConfirmed) {
      if (_nearbyDriverPoints.isNotEmpty) {
        setState(() => _nearbyDriverPoints.clear());
      }
      return;
    }
    if (!_nearbyDriversRefreshGate.begin()) return;
    try {
      final data = await WorkerApi.nearbyDrivers();
      final rawDrivers = data['drivers'];
      final candidates = <MapEntry<LatLng, DateTime>>[];
      if (rawDrivers is List) {
        for (final raw in rawDrivers.whereType<Map>()) {
          final lat = double.tryParse((raw['latitude'] ?? '').toString());
          final lng = double.tryParse((raw['longitude'] ?? '').toString());
          final updatedAt = parseGpsTimestamp(raw['location_updated_at']);
          if (lat == null || lng == null || !lat.isFinite || !lng.isFinite ||
              lat < -90 || lat > 90 || lng < -180 || lng > 180 ||
              !isGpsTimestampFresh(updatedAt)) continue;
          candidates.add(MapEntry(LatLng(lat, lng), updatedAt!));
        }
      }
      final points = selectNearbyDriverLocations(
        pickup: _pickupPoint,
        candidates: candidates,
        maxDistanceKm: 20,
        maxResults: 10,
      );
      if (mounted) {
        setState(() {
          _nearbyDriverPoints
            ..clear()
            ..addAll(points);
        });
      }
    } catch (_) {
      // Keep the last successful snapshot; stale markers are hidden by GPS age.
    } finally {
      if (mounted) {
        setState(() {
          _nearbyDriverPoints.removeWhere(
            (entry) => !isGpsTimestampFresh(entry.value),
          );
        });
      }
      final refreshAgain = _nearbyDriversRefreshGate.finish();
      if (refreshAgain && mounted) {
        // The gate has released its slot; immediately run one coalesced retry.
        unawaited(_refreshNearbyDrivers());
      }
    }
  }

  int _parseFare(dynamic value) {
    final parsed = value is num
        ? value.toInt()
        : int.tryParse((value ?? '').toString().trim());
    if (parsed == null || parsed < 0 || parsed > 1000000) return 0;
    return parsed;
  }

  Future<void> _loadTariffs() async {
    try {
      final data = await WorkerApi.getTariffs();
      final tariffs = Map<String, dynamic>.from(data['tariffs'] as Map? ?? {});
      if (!mounted) return;
      setState(() {
        _cityFareSom = _parseFare(tariffs['city_fare_som']);
        _intercityFareSom = _parseFare(tariffs['intercity_fare_som']);
        _tariffsLoaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _tariffsLoaded = true);
    }
  }

  Future<void> _createOrder() async {
    if (_sendingOrder) return;
    final destination = _destinationController.text.trim();
    final client = TaxiParkState.currentLoggedInClient;
    if (destination.isEmpty || destination.length > 200) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: TaxiText(destination.isEmpty
            ? 'Укажите пункт назначения!'
            : 'Пункт назначения слишком длинный. Укажите не более 200 символов.'),
      ));
      return;
    }
    if (!_pickupPointConfirmed) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: TaxiLocalizedText(russian: 'Сначала определите своё местоположение кнопкой геолокации или отметьте точку подачи нажатием на карту.', kyrgyz: 'Адегенде геолокация баскычы менен жайгашкан жериңизди аныктаңыз же картадан унаа келчү жерди белгилеңиз.'),
      ));
      return;
    }
    final pickupLat = _pickupPoint.latitude;
    final pickupLng = _pickupPoint.longitude;
    if (!pickupLat.isFinite || !pickupLng.isFinite ||
        pickupLat < -90 || pickupLat > 90 ||
        pickupLng < -180 || pickupLng > 180) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: TaxiLocalizedText(russian: 'Не удалось определить точку подачи. Выберите её на карте ещё раз.', kyrgyz: 'Унаа келчү жерди аныктоо мүмкүн болгон жок. Аны картадан кайра тандаңыз.'),
      ));
      return;
    }
    if (_passengerCount < 1 || _passengerCount > 4) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: TaxiLocalizedText(russian: 'Количество пассажиров должно быть от 1 до 4.', kyrgyz: 'Жүргүнчүлөрдүн саны 1ден 4кө чейин болушу керек.'),
      ));
      return;
    }
    if (!_isByContract && !['Наличные', 'QR-код'].contains(_paymentMethod)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: TaxiLocalizedText(russian: 'Выберите допустимый способ оплаты.', kyrgyz: 'Туура төлөм ыкмасын тандаңыз.'),
      ));
      return;
    }
    final selectedFare = _isIntercity ? _intercityFareSom : _cityFareSom;
    if (!_tariffsLoaded || selectedFare <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: TaxiLocalizedText(russian: 'Диспетчер ещё не установил цену для этого тарифа. Заказ пока нельзя отправить.', kyrgyz: 'Диспетчер бул тарифке баа коё элек. Азырынча буйрутма жөнөтүлбөйт.'),
      ));
      return;
    }
    if (client == null || FirebaseService.auth.currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: TaxiLocalizedText(russian: 'Сначала войдите или зарегистрируйтесь как клиент.', kyrgyz: 'Адегенде кардар катары кириңиз же катталыңыз.')));
      return;
    }

    final orderId = DateTime.now().microsecondsSinceEpoch.toString();
    final tariff = _isIntercity ? 'Межгород' : 'По городу';
    final payment = _isByContract ? 'По договору' : _paymentMethod;
    setState(() => _sendingOrder = true);
    try {
      final orderData = <String, dynamic>{
        'id': orderId,
        'customerUid': FirebaseService.auth.currentUser!.uid,
        'pickup': 'Точка подачи на карте — Сулюкта',
        'pickupLat': pickupLat,
        'pickupLng': pickupLng,
        'destination': destination,
        'people': _passengerCount,
        'payment': payment,
        'tariff': tariff,
        'comment': '',
        'status': 'new',
        // JSON-совместимое время: заказ отправляется в Worker через jsonEncode.
        'createdAt': DateTime.now().toIso8601String(),
      };
      // Заказы хранятся в D1 через защищённый Cloudflare Worker.
      // Прямая запись из приложения в Firestore здесь не нужна и блокировалась
      // правилами Firestore (permission-denied).
      await WorkerApi.publishOrder(orderData);
      if (!mounted) return;
      final price = _isIntercity ? _intercityFareSom : _cityFareSom;
      setState(() {
        TaxiParkState.activeOrder = TaxiOrder(
          id: orderId,
          pickupPoint: _pickupPoint,
          destination: destination,
          client: client,
          isIntercity: _isIntercity,
          fixedPrice: price,
          isByContract: _isByContract,
        );
      });
      _orderStatusTimer?.cancel();
      _orderStatusTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (mounted && TaxiParkState.activeOrder?.id == orderId) {
          // Rebuild even when the network is temporarily unavailable so GPS freshness expires on screen.
          setState(() {});
          unawaited(_refreshOrderStatus(orderId));
        }
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: TaxiLocalizedText(russian: 'Заказ отправлен на сервер. Водители могут его увидеть.', kyrgyz: 'Буйрутма серверге жөнөтүлдү. Айдоочулар аны көрө алышат.'),
        ));
      }
    } on WorkerApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: TaxiText('Сервер не подтвердил публикацию заказа: ${e.message}')),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: TaxiText('Не удалось отправить заказ. Проверьте интернет и повторите попытку: $e')),
      );
    } finally {
      if (mounted) setState(() => _sendingOrder = false);
    }
  }

  Future<void> _loadApproachRoute(LatLng driverPoint) async {
    // Refresh the road route after roughly 100 m of movement, not every GPS tick.
    final order = TaxiParkState.activeOrder;
    final driverId = order?.assignedDriver?.id;
    final orderId = order?.id ?? '';
    if (order == null ||
        driverId == null ||
        orderId.isEmpty ||
        order.status != 'accepted') return;
    final driver = order.assignedDriver!;
    if (!driver.isOnline || !isGpsTimestampFresh(driver.locationUpdatedAt)) return;
    // Include both endpoints: a pickup-point change during an in-flight
    // request must invalidate the old route just like a taxi GPS movement.
    final pickupPoint = _pickupPoint;
    final key = '$orderId:$driverId:${pickupPoint.latitude.toStringAsFixed(5)},${pickupPoint.longitude.toStringAsFixed(5)}:${driverPoint.latitude.toStringAsFixed(3)},${driverPoint.longitude.toStringAsFixed(3)}';
    if (_routeLoading) return;
    final routeCheckTime = DateTime.now();
    if (RouteCachePolicy.isFresh(
      cachedKey: _routeLoadedKey,
      requestedKey: key,
      fetchedAt: _routeLoadedAt,
      now: routeCheckTime,
    )) return;
    if (_lastRouteKey == key &&
        _routeRetryAfter != null &&
        routeCheckTime.isBefore(_routeRetryAfter!)) return;
    _lastRouteKey = key;
    _routeLoadedKey = null;
    _routeLoadedAt = null;
    if (mounted) {
      setState(() {
        _routeLoading = true;
        _routeError = null;
        // The previous line belongs to an older taxi position; hide it while refreshing.
        _approachRoute = null;
      });
    }
    var refreshAfterRoute = false;
    try {
      final route = await RouteService.drivingRoute(driverPoint, pickupPoint);
      if (!mounted) return;
      final latestOrder = TaxiParkState.activeOrder;
      if (latestOrder?.id != orderId ||
          latestOrder?.assignedDriver?.id != driverId ||
          latestOrder?.status != 'accepted') return;
      final latestPoint = latestOrder!.assignedDriver!.currentLocation;
      final latestPickupPoint = _pickupPoint;
      final latestKey = '$orderId:$driverId:${latestPickupPoint.latitude.toStringAsFixed(5)},${latestPickupPoint.longitude.toStringAsFixed(5)}:${latestPoint.latitude.toStringAsFixed(3)},${latestPoint.longitude.toStringAsFixed(3)}';
      if (latestKey != key) {
        // GPS moved while routing was in flight: never show a route from an old position.
        refreshAfterRoute = latestOrder.status == 'accepted';
        return;
      }
      setState(() {
        _approachRoute = route;
        _routeRetryAfter = null;
        _routeLoadedKey = key;
        _routeLoadedAt = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;
      final latestOrder = TaxiParkState.activeOrder;
      if (latestOrder?.id != orderId ||
          latestOrder?.assignedDriver?.id != driverId ||
          latestOrder?.status != 'accepted') return;
      final latestPoint = latestOrder!.assignedDriver!.currentLocation;
      final latestPickupPoint = _pickupPoint;
      final latestKey = '$orderId:$driverId:${latestPickupPoint.latitude.toStringAsFixed(5)},${latestPickupPoint.longitude.toStringAsFixed(5)}:${latestPoint.latitude.toStringAsFixed(3)},${latestPoint.longitude.toStringAsFixed(3)}';
      if (latestKey != key) {
        refreshAfterRoute = latestOrder.status == 'accepted';
        return;
      }
      setState(() {
        _approachRoute = null;
        _routeLoadedKey = null;
        _routeLoadedAt = null;
        _routeError = 'Не удалось построить маршрут. Проверьте интернет; положение такси обновится автоматически.';
        _routeRetryAfter = DateTime.now().add(const Duration(seconds: 30));
      });
    } finally {
      if (mounted) {
        setState(() => _routeLoading = false);
        if (refreshAfterRoute) {
          final latestOrder = TaxiParkState.activeOrder;
          final latestDriver = latestOrder?.assignedDriver;
          if (latestOrder?.id == orderId &&
              latestDriver?.id == driverId &&
              latestOrder?.status == 'accepted' &&
              latestDriver != null) {
            unawaited(_loadApproachRoute(latestDriver.currentLocation));
          }
        }
      }
    }
  }
  double? _readValidCoordinate(dynamic value, {required double min, required double max}) {
    final parsed = double.tryParse((value ?? '').toString());
    if (parsed == null || !parsed.isFinite || parsed < min || parsed > max) return null;
    return parsed;
  }

  Future<void> _refreshOrderStatus(String orderId) async {
    // Timer ticks must not create overlapping requests on a slow mobile network.
    if (_orderStatusRequestInProgress) return;
    _orderStatusRequestInProgress = true;
    try {
      final data = await WorkerApi.orderStatus(orderId);
      final order = TaxiParkState.activeOrder;
      if (!mounted || order == null || order.id != orderId) return;
      final status = (data['status'] ?? 'new').toString().trim().toLowerCase();
      setState(() {
        if (status == 'new') {
          order.status = 'searching';
          order.assignedDriver = null;
          _approachRoute = null;
          _lastRouteKey = null;
          _routeLoadedKey = null;
          _routeLoadedAt = null;
          _routeError = null;
          _routeRetryAfter = null;
        } else if (status == 'driver_assigned' || status == 'arrived') {
          order.status = status == 'arrived' ? 'arrived' : 'accepted';
          if (status == 'arrived') {
            _approachRoute = null;
            _lastRouteKey = null;
          _routeLoadedKey = null;
          _routeLoadedAt = null;
            _routeError = null;
          }
          order.assignedDriver = null;
          final raw = data['driver'];
          if (raw is Map) {
            final uid = (raw['uid'] ?? '').toString().trim();
            final lat = _readValidCoordinate(raw['latitude'], min: -90, max: 90);
            final lng = _readValidCoordinate(raw['longitude'], min: -180, max: 180);
            if (uid.isNotEmpty && lat != null && lng != null) {
              final locationUpdatedAt = parseGpsTimestamp(raw['location_updated_at']);
              order.assignedDriver = DriverModel(
              id: uid,
              name: (raw['name'] ?? 'Водитель').toString(),
              phone: (raw['phone'] ?? '').toString(),
              carBrand: (raw['car_model'] ?? 'Автомобиль').toString(),
              carColor: '',
              plateNumber: (raw['car_number'] ?? '').toString(),
              pinCode: '',
              currentLocation: LatLng(lat, lng),
              locationUpdatedAt: locationUpdatedAt,
              isApproved: true,
              isOnline: (raw['online'] == true || raw['online'] == 1 || raw['online']?.toString().trim().toLowerCase() == 'true' || raw['online']?.toString().trim() == '1') &&
                  isGpsTimestampFresh(locationUpdatedAt),
              );
            }
          }
          // Continue polling while the taxi is driving so its live GPS marker moves.
        } else if (status == 'completed') {
          order.status = 'completed';
          order.assignedDriver = null;
          _approachRoute = null;
          _lastRouteKey = null;
          _routeLoadedKey = null;
          _routeLoadedAt = null;
          _routeError = null;
          _routeRetryAfter = null;
          _orderStatusTimer?.cancel();
        } else if (status == 'cancelled_by_customer') {
          order.status = 'cancelled';
          order.assignedDriver = null;
          _approachRoute = null;
          _lastRouteKey = null;
          _routeLoadedKey = null;
          _routeLoadedAt = null;
          _routeError = null;
          _routeRetryAfter = null;
          _orderStatusTimer?.cancel();
        }
      });
      final assigned = order.assignedDriver;
      // Once the taxi has arrived, stop recalculating the approach route.
      if (assigned != null && assigned.isOnline && order.status == 'accepted') {
        unawaited(_loadApproachRoute(assigned.currentLocation));
      }
    } on WorkerApiException {
      // A short network interruption is retried on the next timer tick.
    } catch (_) {
      // Keep the last known order status until the next successful refresh.
    } finally {
      _orderStatusRequestInProgress = false;
    }
  }

  Future<void> _logoutClient() async {
    if (!mounted || _clientLoggingOut) return;
    final hasActiveOrder = TaxiParkState.activeOrder != null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const TaxiLocalizedText(russian: 'Выйти из аккаунта?', kyrgyz: 'Аккаунттан чыгасызбы?'),
        content: TaxiText(
          hasActiveOrder
              ? 'Вы выйдете из аккаунта. Текущий заказ не будет отменён, но после выхода вы перестанете видеть его обновления на этом устройстве.'
              : 'Вы действительно хотите выйти из аккаунта пассажира?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const TaxiLocalizedText(russian: 'ОСТАТЬСЯ', kyrgyz: 'КАЛУУ'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const TaxiLocalizedText(russian: 'ВЫЙТИ', kyrgyz: 'ЧЫГУУ'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _clientLoggingOut) return;
    setState(() => _clientLoggingOut = true);
    try {
      await FirebaseService.signOut().timeout(const Duration(seconds: 20));
      if (!mounted) return;
      _orderStatusTimer?.cancel();
      _nearbyDriversTimer?.cancel();
      TaxiParkState.currentLoggedInClient = null;
      TaxiParkState.activeOrder = null;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const RoleSelectionScreen()),
        (route) => false,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: TaxiText('Не удалось выйти из аккаунта: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _clientLoggingOut = false);
    }
  }

  Future<void> _cancelClientOrder() async {
    final order = TaxiParkState.activeOrder;
    if (order == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const TaxiLocalizedText(russian: 'Отменить заказ?', kyrgyz: 'Буйрутманы жокко чыгарасызбы?'),
        content: const TaxiLocalizedText(russian: 'Вы можете отменить заказ, пока водитель не прибыл к месту подачи.', kyrgyz: 'Айдоочу унаа келчү жерге жеткенге чейин буйрутманы жокко чыгара аласыз.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const TaxiLocalizedText(russian: 'ОСТАТЬСЯ', kyrgyz: 'КАЛУУ')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const TaxiLocalizedText(russian: 'ОТМЕНИТЬ', kyrgyz: 'ЖОККО ЧЫГАРУУ')),
        ],
      ),
    );
    if (confirm != true || !mounted || _cancellingOrder) return;
    setState(() => _cancellingOrder = true);
    try {
      await WorkerApi.cancelOrder(orderId: order.id, role: 'customer');
      _orderStatusTimer?.cancel();
      if (mounted) setState(() {
        order.status = 'cancelled';
        order.assignedDriver = null;
        _approachRoute = null;
        _lastRouteKey = null;
          _routeLoadedKey = null;
          _routeLoadedAt = null;
        _routeError = null;
      });
    } on WorkerApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: TaxiText(e.message)));
    } finally {
      if (mounted) setState(() => _cancellingOrder = false);
    }
  }

  void _cancelOrResetOrder() {
    _orderStatusTimer?.cancel();
    setState(() {
      TaxiParkState.activeOrder = null;
      _approachRoute = null;
      _lastRouteKey = null;
          _routeLoadedKey = null;
          _routeLoadedAt = null;
      _routeError = null;
      _routeLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final order = TaxiParkState.activeOrder;
    final gpsAgeSeconds = calculateGpsAgeSeconds(order?.assignedDriver?.locationUpdatedAt);
    final gpsIsFresh = order?.assignedDriver?.isOnline == true &&
        isGpsTimestampFresh(order?.assignedDriver?.locationUpdatedAt);

    return Scaffold(
      appBar: AppBar(
        title: const TaxiText('ЖОЛ АМАН КЕНЧИ • ТАКСИ',
          style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.2)),
        backgroundColor: const Color(0xFFFFD400),
        foregroundColor: const Color(0xFF171717),
        elevation: 3,
        actions: [
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: TaxiLanguageSwitcher(),
          ),
          IconButton(
            tooltip: 'Выйти из аккаунта пассажира',
            onPressed: _clientLoggingOut ? null : _logoutClient,
            icon: _clientLoggingOut
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
              mapController: _clientMapController,
              options: MapOptions(
                initialCenter: _pickupPoint,
                initialZoom: 14.5,
                onMapReady: () {
                  _clientMapReady = true;
                  final current = _clientCurrentLocation;
                  if (current != null && mounted && !_clientPickupManuallySelected) {
                    _clientMapController.move(current, 16.0);
                  }
                },
                onTap: (tapPosition, point) {
                  if (TaxiParkState.activeOrder == null) {
                    setState(() {
                      _pickupPoint = point;
                      _pickupPointConfirmed = true;
                      _clientPickupManuallySelected = true;
                    });
                    unawaited(_refreshNearbyDrivers());
                  }
                },
              ),
              children: [
                ...buildTaxiDarkMapLayers(),
                if (_approachRoute != null && gpsIsFresh)
                  PolylineLayer(polylines: [Polyline(points: _approachRoute!.points, color: Colors.cyanAccent, strokeWidth: 5)]),
                if (_approachRoute == null && order?.assignedDriver != null && gpsIsFresh)
                  PolylineLayer(polylines: [Polyline(points: [order!.assignedDriver!.currentLocation, _pickupPoint], color: Colors.blueGrey, strokeWidth: 3, isDotted: true)]),
                MarkerLayer(
                  markers: [
                    ..._nearbyDriverPoints.map((entry) => Marker(
                      point: entry.key,
                      width: 38,
                      height: 38,
                      child: const Icon(Icons.local_taxi, color: Colors.green, size: 30),
                    )),
                    Marker(
                      point: _pickupPoint,
                      width: 50,
                      height: 50,
                      child: const Icon(Icons.location_on,
                          color: Colors.red, size: 45),
                    ),
                    if (order?.assignedDriver != null && gpsIsFresh)
                      Marker(
                        point: order!.assignedDriver!.currentLocation,
                        width: 32,
                        height: 32,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFD400),
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFF171717), width: 1.5),
                            boxShadow: const [
                              BoxShadow(color: Colors.black38, blurRadius: 5, offset: Offset(0, 2)),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.local_taxi_rounded,
                            color: Color(0xFF171717),
                            size: 21,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
                ),
                if (order == null)
                  Positioned(
                    left: 14,
                    top: 14,
                    right: 64,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: _pickupPointConfirmed
                            ? Colors.green.shade800.withOpacity(0.94)
                            : Colors.orange.shade900.withOpacity(0.96),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                        child: Row(
                          children: [
                            Icon(
                              _pickupPointConfirmed ? Icons.check_circle : Icons.info_outline,
                              color: Colors.white,
                              size: 19,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TaxiText(
                                _pickupPointConfirmed
                                    ? 'Точка подачи выбрана'
                                    : 'Определите местоположение или отметьте точку на карте',
                                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (order == null)
                  Positioned(
                    right: 14,
                    top: 14,
                    child: FloatingActionButton.small(
                      heroTag: 'centerClientOnMyLocation',
                      tooltip: 'Моё местоположение',
                      onPressed: _clientLocationLoading
                          ? null
                          : () => unawaited(_locateClient(showMessage: true)),
                      child: _clientLocationLoading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.my_location),
                    ),
                  ),
                if (order?.assignedDriver != null && gpsIsFresh)
                  Positioned(
                    right: 14,
                    bottom: 14,
                    child: FloatingActionButton.small(
                      heroTag: 'centerTaxiOnClientMap',
                      tooltip: 'Показать такси на карте',
                      onPressed: () {
                        final point = order!.assignedDriver!.currentLocation;
                        _clientMapController.move(point, 15.5);
                      },
                      child: const Icon(Icons.local_taxi),
                    ),
                  ),
              ],
            ),
          ),
          if (order?.assignedDriver != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TaxiText(!gpsIsFresh ? 'Нет актуального GPS: положение машины и маршрут временно скрыты.' : (_routeLoading ? 'Обновляем положение такси и маршрут…' : (_approachRoute != null ? 'Маршрут до вас: ${_approachRoute!.distanceLabel} · примерно ${_approachRoute!.etaLabel}' : (_routeError ?? 'Маршрут уточняется'))), style: const TextStyle(fontWeight: FontWeight.w600)),
                  TaxiText(
                    gpsAgeSeconds == null
                        ? 'Положение автомобиля получено; время GPS пока неизвестно.'
                        : (!gpsIsFresh
                            ? 'Водитель не на линии или GPS устарел ($gpsAgeSeconds сек.). Положение машины скрыто.'
                            : 'GPS обновлён $gpsAgeSeconds сек. назад. Конечный адрес водитель уточнит у вас устно.'),
                    style: TextStyle(
                      fontSize: 12,
                      color: !gpsIsFresh ? Colors.red : Colors.grey.shade700,
                    ),
                  ),
                  TaxiText('Такси: ${order?.assignedDriver?.carBrand ?? ''} ${order?.assignedDriver?.plateNumber ?? ''}', style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFEFA),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border.all(color: const Color(0xFFE6A900), width: 1.5),
              boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 12, offset: Offset(0, -3))],
            ),
            child: order == null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8, left: 2),
                        child: TaxiLocalizedText(russian: 'ВЫБЕРИТЕ ТАРИФ', kyrgyz: 'ТАРИФТИ ТАНДАҢЫЗ',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900,
                            letterSpacing: 0.8, color: Color(0xFF65522A))),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: ChoiceChip(
                              label: TaxiText(
                                  'По городу (${_cityFareSom > 0 ? '$_cityFareSom сом' : 'цена не задана'})',
                                  style: TextStyle(fontWeight: FontWeight.w800,
                                    color: !_isIntercity ? const Color(0xFF171717) : const Color(0xFF555555))),
                              selectedColor: const Color(0xFFFFD400),
                              backgroundColor: const Color(0xFFF1EDE3),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                              selected: !_isIntercity,
                              onSelected: (val) =>
                                  setState(() => _isIntercity = false),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ChoiceChip(
                              label: TaxiText('Межгород (${_intercityFareSom > 0 ? '$_intercityFareSom сом' : 'цена не задана'})',
                                  style: TextStyle(fontWeight: FontWeight.w800,
                                    color: _isIntercity ? const Color(0xFF171717) : const Color(0xFF555555))),
                              selectedColor: const Color(0xFFFFD400),
                              backgroundColor: const Color(0xFFF1EDE3),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                              selected: _isIntercity,
                              onSelected: (val) =>
                                  setState(() => _isIntercity = true),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (_isIntercity) ...[
                        TaxiText(
                          _intercityFareSom > 0
                              ? 'Фиксированная цена межгорода: $_intercityFareSom сом.'
                              : 'Диспетчер ещё не установил цену межгорода. Уточните стоимость перед заказом.',
                          style: const TextStyle(color: Colors.grey, fontSize: 13),
                        ),
                        const SizedBox(height: 10),
                        SwitchListTile(
                          title: const TaxiText(
                              'Оплата по договору (безнал / корп.)',
                              style: TextStyle(fontSize: 14)),
                          value: _isByContract,
                          onChanged: (val) =>
                              setState(() => _isByContract = val),
                        ),
                      ],
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF4F0E6),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                        children: [
                          const Icon(Icons.people_alt_rounded, color: Color(0xFF171717)),
                          const SizedBox(width: 6),
                          const TaxiLocalizedText(russian: 'Пассажиры: ', kyrgyz: 'Жүргүнчүлөр: ', style: TextStyle(fontWeight: FontWeight.w800)),
                          DropdownButton<int>(
                            value: _passengerCount,
                            items: List.generate(4, (i) => DropdownMenuItem(
                              value: i + 1, child: TaxiText('${i + 1}'),
                            )),
                            onChanged: (value) => setState(() => _passengerCount = value ?? 1),
                          ),
                          const Spacer(),
                          if (!_isByContract)
                            DropdownButton<String>(
                              value: _paymentMethod,
                              items: const [
                                DropdownMenuItem(value: 'Наличные', child: TaxiLocalizedText(russian: 'Наличные', kyrgyz: 'Накталай')),
                                DropdownMenuItem(value: 'QR-код', child: TaxiText('QR-код')),
                              ],
                              onChanged: (value) => setState(() => _paymentMethod = value ?? 'Наличные'),
                            ),
                        ],
                      ),
                      ),
                      TaxiText(
                        !_tariffsLoaded
                            ? 'Загружаем тарифы…'
                            : ((_isIntercity ? _intercityFareSom : _cityFareSom) > 0
                                ? 'Фиксированная стоимость: ${_isIntercity ? _intercityFareSom : _cityFareSom} сом.'
                                : 'Цена пока не установлена диспетчером.'),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.brown),
                      ),
                      const SizedBox(height: 5),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF3B0),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE6A900)),
                        ),
                        child: const Row(children: [
                          Icon(Icons.location_on_rounded, color: Color(0xFF171717)),
                          SizedBox(width: 8),
                          Expanded(child: TaxiLocalizedText(russian: 'Точка подачи: нажмите на карту, чтобы передвинуть метку.', kyrgyz: 'Унаа келчү жер: белгини жылдыруу үчүн картаны басыңыз.',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF171717)))),
                        ]),
                      ),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _destinationController,
                        maxLength: 200,
                        textCapitalization: TextCapitalization.sentences,
                        textInputAction: TextInputAction.done,
                        decoration: InputDecoration(
                            labelText: 'Куда едем? (Центр, Рынок, Раззаков...)',
                            prefixIcon: const Icon(Icons.flag_rounded, color: Color(0xFF171717)),
                            filled: true,
                            fillColor: Colors.white,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: const BorderSide(color: Color(0xFFE6A900), width: 1.4)),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: const BorderSide(color: Color(0xFF171717), width: 2))),
                      ),
                      const SizedBox(height: 10),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFFD400),
                          foregroundColor: const Color(0xFF171717),
                          minimumSize: const Size.fromHeight(60),
                          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          elevation: 4,
                        ),
                        onPressed: _sendingOrder ? null : _createOrder,
                        icon: const Icon(Icons.local_taxi_rounded, size: 27),
                        label: TaxiText(_sendingOrder ? 'ОТПРАВКА...' : 'ВЫЗВАТЬ МАШИНУ',
                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 17, letterSpacing: 0.4)),
                      ),
                    ],
                  )
                : _buildOrderStatus(order),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _orderStatusTimer?.cancel();
    _nearbyDriversTimer?.cancel();
    _destinationController.dispose();
    super.dispose();
  }

  Widget _buildOrderStatus(TaxiOrder order) {
    if (order.status == 'searching') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const CircularProgressIndicator(color: Colors.amber),
              const SizedBox(width: 16),
              Expanded(
                  child: TaxiText(
                      order.isIntercity
                          ? 'Ищем машину на межгород Сулюкта-Раззаков...'
                          : 'Ищем свободную машину по городу (${order.fixedPrice} сом)...',
                      style: const TextStyle(fontWeight: FontWeight.bold))),
            ],
          ),
          const SizedBox(height: 10),
          const TaxiLocalizedText(russian: 'Заказ опубликован. Статус обновляется автоматически.', kyrgyz: 'Буйрутма жарыяланды. Абалы автоматтык түрдө жаңыланат.',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _cancellingOrder ? null : _cancelClientOrder,
            icon: const Icon(Icons.close),
            label: TaxiText(_cancellingOrder ? 'ОТМЕНЯЕМ...' : 'ОТМЕНИТЬ ЗАКАЗ'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
          ),
        ],
      );
    }

    if (order.status == 'accepted' && order.assignedDriver != null) {
      final d = order.assignedDriver!;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TaxiLocalizedText(russian: 'Машина назначена и едет к вам!', kyrgyz: 'Унаа дайындалды жана сизге келе жатат!',
              style:
                  TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
          TaxiText('Водитель: ${d.name} (${d.phone})'),
          TaxiText('Авто: ${d.fullCarInfo}'),
          const TaxiText('Синяя линия показывает прямое направление к точке подачи, а не дорожный маршрут.',
              style: TextStyle(fontSize: 11, color: Colors.black54)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _cancellingOrder ? null : _cancelClientOrder,
            icon: const Icon(Icons.close),
            label: TaxiText(_cancellingOrder ? 'ОТМЕНЯЕМ...' : 'ОТМЕНИТЬ ЗАКАЗ ДО ПРИЕЗДА'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
          ),
        ],
      );
    }

    if (order.status == 'arrived' && order.assignedDriver != null) {
      final d = order.assignedDriver!;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TaxiText('ВОДИТЕЛЬ ПРИБЫЛ НА МЕСТО ПОДАЧИ',
              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
          TaxiText('Водитель: ${d.name} (${d.phone})'),
          TaxiText('Автомобиль: ${d.fullCarInfo}'),
        ],
      );
    }

    if (order.status == 'cancelled') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TaxiLocalizedText(russian: 'Заказ отменён.', kyrgyz: 'Буйрутма жокко чыгарылды.', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
          ElevatedButton(onPressed: _cancelOrResetOrder, child: const TaxiLocalizedText(russian: 'СОЗДАТЬ НОВЫЙ ЗАКАЗ', kyrgyz: 'ЖАҢЫ БУЙРУТМА ТҮЗҮҮ')),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const TaxiLocalizedText(russian: 'Поездка завершена!', kyrgyz: 'Жол жүрүү аяктады!',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.green)),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.amber),
          onPressed: _cancelOrResetOrder,
          child: const TaxiLocalizedText(russian: 'Новый заказ', kyrgyz: 'Жаңы буйрутма'),
        ),
      ],
    );
  }
}

class DriverEntryScreen extends StatefulWidget {
  const DriverEntryScreen({super.key});

  @override
  State<DriverEntryScreen> createState() => _DriverEntryScreenState();
}

class _DriverEntryScreenState extends State<DriverEntryScreen> {
  bool _isEnabled(dynamic value) {
    if (value == true || value == 1) return true;
    final normalized = value?.toString().trim().toLowerCase();
    return normalized == 'true' || normalized == '1';
  }

  @override
  void initState() {
    super.initState();
    TaxiLanguage.current.addListener(_handleLanguageChanged);
  }
  void _handleLanguageChanged() { if (mounted) setState(() {}); }

  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    TaxiLanguage.current.removeListener(_handleLanguageChanged);
    _phoneController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: TaxiText(message)),
    );
  }

  Future<void> _loginDriver() async {
    final phone = _phoneController.text.trim();
    final password = _passwordController.text;
    if (!TaxiParkState.isValidKgPhone(phone) || password.length < 6) {
      _showMessage('Введите телефон 0XXXXXXXXX и пароль не короче 6 символов.');
      return;
    }
    setState(() => _busy = true);
    try {
      await FirebaseService.signInWithPhone(phone: phone, password: password);

      // First distinguish a missing driver profile from a temporary server
      // failure. Do not sign the user out merely because the API is offline.
      final access = await WorkerApi.checkAuth();
      if (access['driver'] != true) {
        await FirebaseService.signOut();
        _showMessage('Для этого номера анкета водителя не найдена. Подайте заявку или проверьте другой номер.');
        return;
      }

      final profile = await WorkerApi.driverProfile();
      final data = profile['driver'];
      if (data == null) {
        await FirebaseService.signOut();
        _showMessage('Анкета водителя не найдена. Подайте заявку на регистрацию.');
        return;
      }
      final approvalValue = data['approved'];
      final isApproved = approvalValue == true || approvalValue == 1 || approvalValue.toString() == '1';
      if (!isApproved) {
        if (!mounted) return;
        Navigator.pushReplacement(context, MaterialPageRoute(
          builder: (_) => DriverReviewStatusScreen(profile: Map<String, dynamic>.from(data as Map)),
        ));
        return;
      }

      final driverUid =
          (data['uid'] ?? FirebaseService.auth.currentUser!.uid).toString();
      final restoreOnline = _isEnabled(data['online']) ||
          await _readDriverLinePreference(driverUid);
      final driver = DriverModel(
        id: driverUid,
        name: (data['name'] ?? 'Водитель').toString(),
        phone: (data['phone'] ?? phone).toString(),
        carBrand: (data['car_model'] ?? '').toString(),
        carColor: '',
        plateNumber: (data['car_number'] ?? '').toString(),
        pinCode: '',
        currentLocation: TaxiParkState.sulyuktaCenter,
        isApproved: true,
        isOnline: restoreOnline,
      );
      TaxiParkState.currentLoggedInDriver = driver;
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const DriverMapScreen()),
      );
    } on WorkerApiException catch (e) {
      _showMessage('Не удалось связаться с сервером таксопарка: ${e.message} Проверьте интернет и повторите вход.');
    } on FirebaseAuthException catch (e) {
      _showMessage(_authError(e));
    } catch (e) {
      _showMessage('Не удалось войти: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _authError(FirebaseAuthException e) {
    switch (e.code) {
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Неверный телефон или пароль.';
      case 'too-many-requests':
        return 'Слишком много попыток. Попробуйте позже.';
      case 'network-request-failed':
        return 'Проверьте подключение к интернету.';
      default:
        return e.message ?? 'Ошибка авторизации Firebase (${e.code}).';
    }
  }

  Widget _documentPickRow(String label, XFile? file, VoidCallback onPick) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(children: [
      Expanded(child: TaxiText(file == null ? '$label · не выбрано' : '$label · выбрано')),
      TextButton.icon(onPressed: onPick, icon: const Icon(Icons.add_a_photo_outlined), label: TaxiText(file == null ? 'Добавить' : 'Заменить')),
    ]),
  );

  Future<String> _uploadDriverDocument(XFile file, String uid, String kind) async {
    final ref = taxiFirebaseStorage.ref().child('drivers/$uid/$kind.jpg');
    final bytes = await file.readAsBytes();
    final task = await ref.putData(
      bytes,
      SettableMetadata(contentType: 'image/jpeg', customMetadata: {'ownerUid': uid}),
    );
    return task.ref.fullPath;
  }

  Future<void> _showDriverRegistration() async {
    final submitted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const DriverRegistrationScreen()),
    );
    if (submitted == true && mounted) {
      _showMessage('Анкета отправлена. Фотографии при регистрации необязательны; диспетчер запросит их отдельно. Дождитесь проверки.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const TaxiLocalizedText(russian: 'Кабинет водителя', kyrgyz: 'Айдоочунун кабинети'),
        backgroundColor: Colors.amber,
        actions: const [Padding(padding: EdgeInsets.only(right: 12), child: TaxiLanguageSwitcher())],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.drive_eta, size: 80, color: Colors.amber),
                const SizedBox(height: 20),
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: TaxiLanguage.isKyrgyz ? 'Айдоочунун телефону' : 'Телефон водителя',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: TaxiLanguage.isKyrgyz ? 'Сырсөз' : 'Пароль',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: _busy ? null : _loginDriver,
                  child: TaxiLocalizedText(russian: _busy ? 'ПОДОЖДИТЕ...' : 'ВОЙТИ КАК ВОДИТЕЛЬ', kyrgyz: _busy ? 'КҮТҮҢҮЗ...' : 'АЙДООЧУ КАТАРЫ КИРҮҮ',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _showDriverRegistration,
                  icon: const Icon(Icons.assignment_ind),
                  label: TaxiLocalizedText(russian: 'ПОДАТЬ ЗАЯВКУ ВОДИТЕЛЯ', kyrgyz: 'АЙДООЧУ БОЛУУГА ӨТҮНМӨ БЕРҮҮ'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class DriverReviewStatusScreen extends StatefulWidget {
  final Map<String, dynamic> profile;
  const DriverReviewStatusScreen({super.key, required this.profile});

  @override
  State<DriverReviewStatusScreen> createState() => _DriverReviewStatusScreenState();
}

class _DriverReviewStatusScreenState extends State<DriverReviewStatusScreen> {
  XFile? _license;
  XFile? _driverPhoto;
  XFile? _carPhoto;
  bool _busy = false;
  final ImagePicker _picker = ImagePicker();
  Timer? _documentRequestTimer;
  bool _documentRequestCheckRunning = false;
  String? _documentTransferMessage;
  String? _lastHandledRequestId;
  DateTime? _lastDocumentSendAt;
  DriverDocumentTransferLiveKit? _activeDocumentTransfer;

  @override
  void initState() {
    super.initState();
    unawaited(_startDocumentRequestPolling());
  }

  Future<void> _startDocumentRequestPolling() async {
    await _restoreLocalDocuments();
    if (!mounted || (widget.profile['review_status'] ?? 'pending').toString() == 'rejected') return;
    await _checkDocumentRequest();
    _documentRequestTimer = Timer.periodic(const Duration(seconds: 6), (_) => unawaited(_checkDocumentRequest()));
  }

  Future<void> _checkDocumentRequest() async {
    if (!mounted || _documentRequestCheckRunning || _busy) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;
    _documentRequestCheckRunning = true;
    try {
      final data = await WorkerApi.driverDocumentRequest();
      final raw = data['request'];
      if (raw is! Map) {
        final previous = _activeDocumentTransfer;
        _activeDocumentTransfer = null;
        _lastHandledRequestId = null;
        _lastDocumentSendAt = null;
        if (previous != null) await previous.dispose();
        return;
      }
      final request = Map<String, dynamic>.from(raw);
      final requestId = (request['request_id'] ?? '').toString().trim();
      final status = (request['status'] ?? '').toString();
      if (requestId.isEmpty || !{'requested', 'transferring'}.contains(status)) return;
      if (_lastHandledRequestId == requestId && _activeDocumentTransfer != null) {
        final lastSent = _lastDocumentSendAt;
        if (lastSent != null && DateTime.now().difference(lastSent) < const Duration(seconds: 20)) return;
        // Re-send the same immutable local files periodically. Reliable
        // delivery covers a single connection, while this retry also recovers
        // packets lost during a temporary disconnect/reconnect.
        await _activeDocumentTransfer!.sendDriverDocuments();
        _lastDocumentSendAt = DateTime.now();
        if (mounted) setState(() => _documentTransferMessage = 'Повторно отправляем документы для проверки получения…');
        return;
      }
      final docs = await Future.wait([
        DriverDocumentStore.find(uid: uid, documentType: 'license'),
        DriverDocumentStore.find(uid: uid, documentType: 'driver_photo'),
        DriverDocumentStore.find(uid: uid, documentType: 'car_photo'),
      ]);
      if (docs.any((file) => file == null)) {
        if (mounted) setState(() => _documentTransferMessage = 'Диспетчер запросил документы, но на телефоне не хватает одной или нескольких фотографий. Выберите недостающие фото повторно.');
        return;
      }
      final session = await DriverDocumentTransferLiveKit.connect(requestId: requestId, driverUid: uid, isDispatcher: false);
      if (!mounted) { await session.dispose(); return; }
      _activeDocumentTransfer = session;
      _lastHandledRequestId = requestId;
      setState(() => _documentTransferMessage = 'Диспетчер запросил документы. Отправляем три фотографии…');
      await session.sendDriverDocuments();
      _lastDocumentSendAt = DateTime.now();
      if (mounted) setState(() => _documentTransferMessage = 'Фотографии отправлены по защищённому каналу. Ожидаем подтверждения диспетчера…');
    } catch (error) {
      final failed = _activeDocumentTransfer;
      _activeDocumentTransfer = null;
      if (failed != null) await failed.dispose();
      if (mounted) setState(() => _documentTransferMessage = 'Не удалось передать документы: $error. Повторим автоматически.');
    } finally {
      _documentRequestCheckRunning = false;
    }
  }

  @override
  void dispose() {
    _documentRequestTimer?.cancel();
    final session = _activeDocumentTransfer;
    if (session != null) unawaited(session.dispose());
    super.dispose();
  }

  Future<void> _restoreLocalDocuments() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;
    try {
      final license = await DriverDocumentStore.find(uid: uid, documentType: 'license');
      final driverPhoto = await DriverDocumentStore.find(uid: uid, documentType: 'driver_photo');
      final carPhoto = await DriverDocumentStore.find(uid: uid, documentType: 'car_photo');
      if (!mounted) return;
      setState(() {
        if (license != null) _license = XFile(license.path);
        if (driverPhoto != null) _driverPhoto = XFile(driverPhoto.path);
        if (carPhoto != null) _carPhoto = XFile(carPhoto.path);
      });
    } catch (_) {
      // Selecting the files again remains available if local restore fails.
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: TaxiText(message)),
    );
  }

  Future<void> _pick(String kind) async {
    if (_busy || !mounted) return;
    if (!{'license', 'driver', 'car'}.contains(kind)) return;
    try {
      final file = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 82,
        maxWidth: 1600,
      );
      if (!mounted || file == null) return;
      final size = await file.length().timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (size <= 0 || size > 8 * 1024 * 1024) {
        _message('Фото пустое или больше 8 МБ. Выберите фотографию меньшего размера.');
        return;
      }
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null || uid.isEmpty) {
        _message('Срок входа истёк. Войдите снова и выберите документы.');
        return;
      }
      final documentType = kind == 'driver' ? 'driver_photo' :
          kind == 'car' ? 'car_photo' : 'license';
      final retained = await DriverDocumentStore.persistPickedImage(
        uid: uid, documentType: documentType, source: file,
      );
      if (!mounted) return;
      final localFile = XFile(retained.path);
      setState(() {
        if (kind == 'license') _license = localFile;
        if (kind == 'driver') _driverPhoto = localFile;
        if (kind == 'car') _carPhoto = localFile;
      });
    } catch (e) {
      _message('Не удалось выбрать фотографию: $e');
    }
  }

  Future<void> _logout() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await FirebaseService.signOut().timeout(const Duration(seconds: 20));
      if (mounted) Navigator.popUntil(context, (route) => route.isFirst);
    } catch (e) {
      _message('Не удалось выйти из аккаунта: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resubmit() async {
    if (_busy) return;
    if (_license == null || _driverPhoto == null || _carPhoto == null) {
      _message('Для повторной проверки выберите все три фотографии.');
      return;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.uid.isEmpty) {
      _message('Срок входа истёк. Войдите снова.');
      return;
    }
    final files = [_license!, _driverPhoto!, _carPhoto!];
    var totalBytes = 0;
    try {
      for (var i = 0; i < files.length; i++) {
        final size = await files[i].length().timeout(const Duration(seconds: 15));
        if (!mounted) return;
        if (size <= 0 || size > 8 * 1024 * 1024) {
          _message('Фото номер ${i + 1} пустое или превышает 8 МБ. Замените его.');
          return;
        }
        totalBytes += size;
      }
      if (totalBytes > 18 * 1024 * 1024) {
        _message('Общий размер трёх фотографий превышает 18 МБ. Уменьшите их.');
        return;
      }
      setState(() => _busy = true);
      final uid = user.uid;
      for (var i = 0; i < files.length; i++) {
        if (FirebaseAuth.instance.currentUser?.uid != uid) {
          throw const WorkerApiException('Аккаунт изменился. Войдите снова.');
        }
        await DriverDocumentStore.persistPickedImage(
          uid: uid,
          documentType: const ['license', 'driver_photo', 'car_photo'][i],
          source: files[i],
        );
      }
      await WorkerApi.resubmitDriverDocuments();
      if (!mounted) return;
      widget.profile['review_status'] = 'pending';
      widget.profile['rejection_reason'] = null;
      setState(() {
        _license = null;
        _driverPhoto = null;
        _carPhoto = null;
      });
      await _startDocumentRequestPolling();
      _message('Фотографии сохранены на телефоне. Диспетчер сможет запросить их для повторной проверки.');
    } catch (e) {
      _message('Не удалось подготовить повторную проверку: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _pickRow(String title, XFile? file, String kind) => ListTile(
    leading: Icon(file == null ? Icons.add_a_photo : Icons.check_circle, color: file == null ? Colors.grey : Colors.green),
    title: TaxiText(title), subtitle: TaxiText(file == null ? 'Не выбрано' : 'Файл выбран'),
    trailing: TextButton(onPressed: _busy ? null : () => _pick(kind), child: TaxiText(file == null ? 'Выбрать' : 'Заменить')),
  );

  @override
  Widget build(BuildContext context) {
    final status = (widget.profile['review_status'] ?? 'pending').toString();
    final rejected = status == 'rejected';
    final documentsApproved = status == 'approved';
    final accessMessage = documentsApproved
        ? 'Документы уже одобрены. Диспетчер должен восстановить допуск к работе. Повторно отправлять фотографии не нужно.'
        : 'Диспетчер проверит документы. До одобрения выход на линию недоступен.';
    return Scaffold(
      appBar: AppBar(title: const TaxiLocalizedText(russian: 'Проверка анкеты', kyrgyz: 'Анкетаны текшерүү'), backgroundColor: Colors.amber,
        actions: [IconButton(onPressed: _busy ? null : _logout, icon: const Icon(Icons.logout), tooltip: 'Выйти')]),
      body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: ListView(padding: const EdgeInsets.all(20), children: [
        const Icon(Icons.fact_check_outlined, size: 64, color: Colors.amber),
        TaxiText(widget.profile['name']?.toString() ?? 'Водитель', textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Card(color: rejected ? Colors.red.shade50 : Colors.amber.shade50, child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
          TaxiText(rejected ? 'Заявка отклонена' : documentsApproved ? 'Документы одобрены · допуск отключён' : 'Документы ожидают проверки', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          if (rejected) ...[const SizedBox(height: 8), TaxiText('Причина: ${widget.profile['rejection_reason'] ?? 'Не указана'}')],
          if (!rejected) TaxiText(accessMessage),
        ]))),
        if (!rejected && _documentTransferMessage != null) ...[
          const SizedBox(height: 10),
          Card(color: Colors.blue.shade50, child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.sync, color: Colors.blue),
              const SizedBox(width: 8),
              Expanded(child: TaxiText(_documentTransferMessage!)),
            ]),
          )),
        ],
        const SizedBox(height: 14),
        TaxiLocalizedText(
          russian: rejected
              ? 'Выберите три фотографии для повторной проверки. Они сохранятся на телефоне и будут переданы диспетчеру по его запросу.'
              : 'Фотографии можно добавить сейчас или позже. Регистрация и ожидание одобрения не требуют вложения фотографий. Для одобрения диспетчер запросит три документа с телефона.',
          kyrgyz: rejected
              ? 'Кайра текшерүү үчүн үч сүрөттү тандаңыз. Алар телефондо сакталып, диспетчердин суроосу боюнча жөнөтүлөт.'
              : 'Сүрөттөрдү азыр же кийин кошсоңуз болот. Катталуу үчүн сүрөттөр милдеттүү эмес. Бекитүү үчүн диспетчер телефондон үч документти сурайт.',
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        _pickRow('Водительское удостоверение', _license, 'license'),
        _pickRow('Фото водителя', _driverPhoto, 'driver'),
        _pickRow('Фото автомобиля', _carPhoto, 'car'),
        if (rejected) ...[
          const SizedBox(height: 12),
          ElevatedButton.icon(onPressed: _busy ? null : _resubmit, icon: const Icon(Icons.check), label: TaxiText(_busy ? 'СОХРАНЕНИЕ...' : 'СОХРАНИТЬ И ОТПРАВИТЬ НА ПРОВЕРКУ')),
        ],
      ]))),
    );
  }
}

class DriverMapScreen extends StatefulWidget {
  const DriverMapScreen({super.key});

  @override
  State<DriverMapScreen> createState() => _DriverMapScreenState();
}

class _DriverMapScreenState extends State<DriverMapScreen> with WidgetsBindingObserver {
  final MapController _driverMapController = MapController();
  bool _driverMapReady = false;
  StreamSubscription<Position>? _positionSubscription;
  StreamSubscription<String>? _pushTokenSubscription;
  Timer? _heartbeatTimer;
  Timer? _ordersPollTimer;
  bool _ordersPollInProgress = false;
  bool _ordersPollRefreshPending = false;
  DateTime? _lastOrderPollNoticeAt;
  String? _lastOrderPollNotice;
  bool _driverAccessWarningShown = false;
  bool _locationUpdateInProgress = false;
  bool _heartbeatCheckInProgress = false;
  bool _locationStreamErrorShown = false;
  bool _locationTrackingStarting = false;
  Timer? _locationRetryTimer;
  List<Map<String, dynamic>> _serverOpenOrders = [];
  List<Map<String, dynamic>> _serverAssignedOrders = [];
  Map<String, dynamic> _driverEarnings = <String, dynamic>{};
  bool _driverEarningsLoading = false;
  bool _driverShiftClosing = false;
  bool _dispatcherForcedOffline = false;
  String? _driverEarningsError;
  final Set<String> _respondingOrderIds = <String>{};
  final Set<String> _orderActionIds = <String>{};
  RoadRoute? _driverApproachRoute;
  bool _driverRouteLoading = false;
  String? _driverRouteOrderId;
  String? _driverRouteError;
  String? _driverRouteKey;
  DateTime? _driverRouteRetryAfter;
  bool _driverWantsOnline = false;
  bool _driverGpsReady = false;
  bool _availabilityChanging = false;
  bool _logoutInProgress = false;
  bool _offlineSyncInProgress = false;
  Timer? _offlineSyncRetryTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Restore the server-confirmed line state. A driver who explicitly went
    // offline must stay offline after closing and reopening the app.
    final currentDriver = TaxiParkState.currentLoggedInDriver;
    _driverWantsOnline = currentDriver?.isOnline ?? false;
    if(currentDriver!=null)_registerDriverPushNotifications();
    if (_driverWantsOnline && currentDriver != null) {
      // Restore GPS/server presence first; only then request the open queue.
      unawaited(_saveDriverLinePreference(currentDriver.id, true));
      unawaited(_restoreDriverAfterResume());
    } else {
      // Offline drivers still need to restore an already assigned trip.
      unawaited(_pollServerOrders());
    }
    // Earnings are independent of GPS and order-list restoration.
    unawaited(_loadDriverEarnings());
    _ordersPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _pollServerOrders();
    });
  }

  void _registerDriverPushNotifications() {
    unawaited(() async {
      try {
        final permission=await FirebaseMessaging.instance.requestPermission(alert:true,badge:true,sound:true);
        if(permission.authorizationStatus==AuthorizationStatus.denied)return;
        final token=await FirebaseMessaging.instance.getToken();
        if(token!=null&&token.isNotEmpty)await WorkerApi.registerDriverPushToken(token);
        await _pushTokenSubscription?.cancel();
        _pushTokenSubscription=FirebaseMessaging.instance.onTokenRefresh.listen((value) async {
          try{await WorkerApi.registerDriverPushToken(value);}catch(_){}
        });
      }catch(_){/* Push failure must not block driver login or order handling. */}
    }());
  }

  bool _resumeRestoreInProgress = false;

  Future<void> _restoreDriverAfterResume() async {
    if (!mounted || _resumeRestoreInProgress) return;
    _resumeRestoreInProgress = true;
    try {
      final driver = TaxiParkState.currentLoggedInDriver;
      if (_driverWantsOnline && driver != null) {
        // Android may pause the GPS stream while the screen is locked.
        // Confirm a fresh GPS publication before asking for new offers.
        if (_positionSubscription == null) {
          await _startLocationTracking();
        } else {
          await _refreshDriverHeartbeat(driver);
        }
      }
      if (mounted) await _pollServerOrders();
      if (mounted) unawaited(_loadDriverEarnings());
    } finally {
      _resumeRestoreInProgress = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    unawaited(_restoreDriverAfterResume());
  }

  String _serverOrderId(Map<String, dynamic> order) {
    final id = (order['id'] ?? order['firebase_order_id'] ?? '').toString().trim();
    return RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id) ? id : '';
  }

  Future<void> _loadDriverEarnings() async {
    if (!mounted || _driverEarningsLoading) return;
    _driverEarningsLoading = true;
    try {
      final data = await WorkerApi.getDriverEarnings();
      final raw = data['earnings'];
      if(!mounted||raw is! Map)return;
      setState(()=>_driverEarnings=Map<String,dynamic>.from(raw));
      _driverEarningsError=null;
    }catch(error){
      if(mounted)setState(()=>_driverEarningsError=error.toString());
      // A temporary finance request failure must not interrupt order handling.
    }finally{
      _driverEarningsLoading = false;
    }
  }

  Future<void> _closeOwnDriverShift() async {
    if(_driverShiftClosing||_driverEarnings['can_close_shift']!=true)return;
    final gross=(_driverEarnings['gross_earnings_som'] as num?)?.toInt()??0;
    final percent=(_driverEarnings['commission_percent'] as num?)?.toInt();
    final share=(_driverEarnings['driver_share_som'] as num?)?.toInt()??0;
    if(percent==null||gross<=0)return;
    final confirm=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:const TaxiText('Закрыть свою смену?'),
      content:TaxiText('Заработок: $gross сом\\nВаша доля: $percent% ($share сом)\\nТаксопарку: ${gross-share} сом.\\n\\nПосле закрытия суммы сохранятся в истории. Повторное закрытие за сегодня будет недоступно.'),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const TaxiLocalizedText(russian:'Отмена',kyrgyz:'Жокко чыгаруу')),
        ElevatedButton(onPressed:()=>Navigator.pop(ctx,true),child:const TaxiLocalizedText(russian:'Закрыть смену',kyrgyz:'Сменаны жабуу')),
      ],
    ));
    if(confirm!=true||!mounted)return;
    setState(()=>_driverShiftClosing=true);
    try{
      final result=await WorkerApi.closeOwnDriverShift();
      final shift=Map<String,dynamic>.from(result['shift'] as Map? ?? {});
      await _loadDriverEarnings();
      if(mounted)_showLocationMessage('Смена закрыта. Вам: ${shift['driver_share_som']??0} сом; таксопарку: ${shift['park_share_som']??0} сом.');
    }catch(error){
      if(mounted)_showLocationMessage(error.toString());
      await _loadDriverEarnings();
    }finally{if(mounted)setState(()=>_driverShiftClosing=false);}
  }

  Future<void> _pollServerOrders() async {
    // Coalesce timer/lifecycle refreshes while a slow request is active.
    // One follow-up request then fetches the newest server state.
    if (!mounted) return;
    if (_ordersPollInProgress) {
      _ordersPollRefreshPending = true;
      return;
    }
    final pollingUid = FirebaseAuth.instance.currentUser?.uid;
    if (pollingUid == null) return;
    _ordersPollInProgress = true;
    try {
      final data = await WorkerApi.openOrders();
      // A response from a previous account must never replace the current UI.
      if (!mounted || FirebaseAuth.instance.currentUser?.uid != pollingUid) return;
      final snapshot = ServerOrderSnapshot.parse(data);
      final open = snapshot.openOrders;
      final assigned = snapshot.assignedOrders;
      // Offline drivers may restore an assigned trip, but never see new offers.
      final visibleOpen = _driverWantsOnline ? open : <Map<String, dynamic>>[];
      if (!mounted) return;
      _driverAccessWarningShown = false;
      _lastOrderPollNoticeAt = null;
      _lastOrderPollNotice = null;
      final hadAssignedOrder = _serverAssignedOrders.isNotEmpty;
      final activeAssignedId = assigned.isEmpty ? null : _serverOrderId(assigned.first);
      setState(() {
        _serverOpenOrders = visibleOpen;
        _serverAssignedOrders = assigned;
        // Never leave the previous passenger's route on the map after an
        // assignment changes or is cancelled.
        if (activeAssignedId != _driverRouteOrderId) {
          _driverApproachRoute = null;
          _driverRouteOrderId = null;
          _driverRouteKey = null;
          _driverRouteError = null;
          _driverRouteRetryAfter = null;
        }
        if (assigned.isEmpty) {
          _driverApproachRoute = null;
          _driverRouteOrderId = null;
          _driverRouteKey = null;
          _driverRouteError = null;
          _driverRouteRetryAfter = null;
        }
      });
      if (hadAssignedOrder && assigned.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: TaxiText('Активный заказ закрыт или снят. Вы снова можете принимать заказы.'),
        ));
      }
      if (assigned.isNotEmpty) unawaited(_loadDriverApproachRoute());
    } on WorkerApiException catch (e) {
      if (e.statusCode == 403 && mounted) {
        // A revoked approval must not leave previously fetched offers or
        // an obsolete pickup route visible on the driver's screen.
        setState(() {
          _serverOpenOrders = [];
          _serverAssignedOrders = [];
          _driverApproachRoute = null;
          _driverRouteOrderId = null;
          _driverRouteKey = null;
          _driverRouteError = null;
          _driverRouteRetryAfter = null;
        });
        if (!_driverAccessWarningShown) {
          _driverAccessWarningShown = true;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: TaxiText(e.message),
          ));
        }
      } else if (mounted) {
        final now = DateTime.now();
        final shouldNotify = _lastOrderPollNotice != e.message ||
            _lastOrderPollNoticeAt == null ||
            now.difference(_lastOrderPollNoticeAt!) >= const Duration(seconds: 30);
        if (shouldNotify) {
          _lastOrderPollNotice = e.message;
          _lastOrderPollNoticeAt = now;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: TaxiText(e.message)));
        }
      }
    } catch (_) {
      // A transient network error is retried by the next scheduled poll.
    } finally {
      _ordersPollInProgress = false;
      if (mounted && _ordersPollRefreshPending) {
        _ordersPollRefreshPending = false;
        scheduleMicrotask(() => _pollServerOrders());
      }
    }
  }

  Future<void> _respondToServerOrder(Map<String, dynamic> order) async {
    final id = _serverOrderId(order);
    if (id.isEmpty || _respondingOrderIds.contains(id)) return;
    setState(() => _respondingOrderIds.add(id));
    try {
      final result = await WorkerApi.respondToOrder(id);
      if (!mounted) return;
      final message = (result['message'] ?? 'Отклик отправлен. Ожидайте выбора ближайшего водителя.').toString();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: TaxiText(message)));
      await _pollServerOrders();
    } on WorkerApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: TaxiText(e.message)));
      await _pollServerOrders();
    } finally {
      if (mounted) setState(() => _respondingOrderIds.remove(id));
    }
  }

  Future<void> _completeAssignedOrder(Map<String, dynamic> order) async {
    final id = _serverOrderId(order);
    if (id.isEmpty || _orderActionIds.contains(id)) return;
    final isIntercity = (order['tariff_type'] ?? '').toString().toLowerCase().contains('меж');
    var suggestedFare = 0;
    try {
      final tariffs = await WorkerApi.getTariffs();
      final raw = tariffs['tariffs'];
      if (raw is Map) {
        suggestedFare = ((raw[isIntercity ? 'intercity_fare_som' : 'city_fare_som'] as num?)?.toInt() ?? 0);
      }
    } catch (_) {
      // The driver can still enter the agreed fare manually.
    }
    int? fare = suggestedFare > 0 ? suggestedFare : null;
    if (fare == null) {
      final fareController = TextEditingController();
      fare = await showDialog<int>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const TaxiLocalizedText(russian: 'Стоимость заказа', kyrgyz: 'Буйрутманын баасы'),
          content: TextField(
            controller: fareController,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Итоговая стоимость (сом)', border: OutlineInputBorder()),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const TaxiLocalizedText(russian: 'Назад', kyrgyz: 'Артка')),
            ElevatedButton(
              onPressed: () {
                final value = int.tryParse(fareController.text.trim());
                if (value != null && value > 0 && value <= 1000000) Navigator.pop(ctx, value);
              },
              child: const TaxiLocalizedText(russian: 'ПОДТВЕРДИТЬ СУММУ', kyrgyz: 'СУММАНЫ ЫРАСТОО'),
            ),
          ],
        ),
      );
      Future<void>.delayed(const Duration(milliseconds: 350), () => fareController.dispose());
    }
    if (fare == null || !mounted) return;
    setState(() => _orderActionIds.add(id));
    try {
      await WorkerApi.completeDriverOrder(orderId: id, fareSom: fare);
      await _loadDriverEarnings();
      if (mounted) _showLocationMessage('Заказ завершён. В финансовый отчёт записано $fare сом.');
    } on WorkerApiException catch (e) {
      if (mounted) _showLocationMessage(e.message);
    } catch (_) {
      if (mounted) _showLocationMessage('Не удалось завершить заказ из-за сети. Обновите список и проверьте статус поездки.');
    } finally {
      if (mounted) setState(() => _orderActionIds.remove(id));
      if (mounted) await _pollServerOrders();
    }
  }

  Future<void> _cancelAssignedOrder(Map<String, dynamic> order) async {
    final id = _serverOrderId(order);
    if (id.isEmpty || _orderActionIds.contains(id)) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const TaxiLocalizedText(russian: 'Отказаться от заказа?', kyrgyz: 'Буйрутмадан баш тартасызбы?'),
        content: const TaxiLocalizedText(russian: 'Заказ вернётся в общий список и станет доступен другим водителям. Это можно сделать только до прибытия к пассажиру.', kyrgyz: 'Буйрутма жалпы тизмеге кайтарылып, башка айдоочуларга жеткиликтүү болот. Муну жүргүнчүгө жеткенге чейин гана жасоого болот.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const TaxiLocalizedText(russian: 'НЕТ', kyrgyz: 'ЖОК')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const TaxiLocalizedText(russian: 'ОТКАЗАТЬСЯ', kyrgyz: 'БАШ ТАРТУУ')),
        ],
      ),
    );
    if (confirm != true || !mounted || _orderActionIds.contains(id)) return;
    setState(() => _orderActionIds.add(id));
    try {
      final result = await WorkerApi.cancelOrder(orderId: id, role: 'driver');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: TaxiText((result['message'] ?? 'Вы отказались от заказа.').toString()),
        ));
      }
    } on WorkerApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: TaxiText(e.message)));
    } catch (_) {
      if (mounted) _showLocationMessage('Не удалось отказаться от заказа из-за ошибки сети. Проверьте связь и обновите список.');
    } finally {
      if (mounted) setState(() => _orderActionIds.remove(id));
      if (mounted) await _pollServerOrders();
    }
  }

  LatLng? _orderPickup(Map<String, dynamic> order) {
    final lat = double.tryParse((order['pickup_lat'] ?? '').toString());
    final lng = double.tryParse((order['pickup_lng'] ?? '').toString());
    if (lat == null || lng == null || !lat.isFinite || !lng.isFinite ||
        lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
    return LatLng(lat, lng);
  }

  String? _currentDriverRouteKey(String orderId) {
    final driver = TaxiParkState.currentLoggedInDriver;
    if (driver == null || _serverAssignedOrders.isEmpty ||
        _serverOrderId(_serverAssignedOrders.first) != orderId) return null;
    final pickup = _orderPickup(_serverAssignedOrders.first);
    final point = driver.currentLocation;
    if (pickup == null || !point.latitude.isFinite || !point.longitude.isFinite ||
        point.latitude < -90 || point.latitude > 90 ||
        point.longitude < -180 || point.longitude > 180) return null;
    return '$orderId:${pickup.latitude.toStringAsFixed(5)},${pickup.longitude.toStringAsFixed(5)}:${point.latitude.toStringAsFixed(3)},${point.longitude.toStringAsFixed(3)}';
  }

  Future<void> _loadDriverApproachRoute() async {
    final driver = TaxiParkState.currentLoggedInDriver;
    if (driver == null || _serverAssignedOrders.isEmpty || _driverRouteLoading) return;
    final order = _serverAssignedOrders.first;
    final id = _serverOrderId(order);
    final pickup = _orderPickup(order);
    if (id.isEmpty) return;
    if (pickup == null) {
      if (mounted) setState(() {
        _driverApproachRoute = null;
        _driverRouteOrderId = id;
        _driverRouteKey = null;
        _driverRouteError = 'Не удалось определить точку подачи пассажира.';
        _driverRouteRetryAfter = null;
      });
      return;
    }
    final driverPoint = driver.currentLocation;
    if (!isGpsTimestampFresh(driver.locationUpdatedAt)) {
      if (_driverRouteRetryAfter != null &&
          DateTime.now().isBefore(_driverRouteRetryAfter!)) return;
      if (mounted) setState(() {
        _driverApproachRoute = null;
        _driverRouteOrderId = id;
        _driverRouteKey = null;
        _driverRouteError = 'Ожидаем свежие координаты GPS. Включите геолокацию и выйдите на линию.';
        _driverRouteRetryAfter = DateTime.now().add(const Duration(seconds: 20));
      });
      return;
    }
    if (!driverPoint.latitude.isFinite || !driverPoint.longitude.isFinite ||
        driverPoint.latitude < -90 || driverPoint.latitude > 90 ||
        driverPoint.longitude < -180 || driverPoint.longitude > 180) return;
    final routeKey = '$id:${pickup.latitude.toStringAsFixed(5)},${pickup.longitude.toStringAsFixed(5)}:${driverPoint.latitude.toStringAsFixed(3)},${driverPoint.longitude.toStringAsFixed(3)}';
    if (_driverRouteKey == routeKey && _driverApproachRoute != null) return;
    if (_driverRouteKey == routeKey &&
        _driverRouteRetryAfter != null &&
        DateTime.now().isBefore(_driverRouteRetryAfter!)) return;
    _driverRouteKey = routeKey;
    if (mounted) {
      setState(() {
        _driverRouteLoading = true;
        // Remove the previous line immediately; it belongs to the old GPS point.
        _driverApproachRoute = null;
        _driverRouteOrderId = id;
        _driverRouteError = null;
        _driverRouteRetryAfter = null;
      });
    } else {
      _driverRouteLoading = true;
    }
    var refreshAfterRoute = false;
    try {
      final route = await RouteService.drivingRoute(driverPoint, pickup);
      if (!mounted) return;
      if (TaxiParkState.currentLoggedInDriver?.id != driver.id) return;
      final latestAssignedId = _serverAssignedOrders.isEmpty
          ? ''
          : _serverOrderId(_serverAssignedOrders.first);
      if (latestAssignedId != id) {
        refreshAfterRoute = latestAssignedId.isNotEmpty;
        return;
      }
      final latestPoint = TaxiParkState.currentLoggedInDriver!.currentLocation;
      final latestRouteKey = _currentDriverRouteKey(id);
      if (latestRouteKey != routeKey) {
        refreshAfterRoute = latestRouteKey != null;
        return;
      }
      setState(() {
        _driverApproachRoute = route;
        _driverRouteOrderId = id;
        _driverRouteError = null;
        _driverRouteRetryAfter = null;
      });
      _focusDriverMapOnRoute(latestPoint, pickup);
    } catch (e) {
      if (!mounted || TaxiParkState.currentLoggedInDriver?.id != driver.id) return;
      final latestAssignedId = _serverAssignedOrders.isEmpty
          ? ''
          : _serverOrderId(_serverAssignedOrders.first);
      if (latestAssignedId != id) {
        refreshAfterRoute = latestAssignedId.isNotEmpty;
        return;
      }
      final latestPoint = TaxiParkState.currentLoggedInDriver!.currentLocation;
      final latestRouteKey = _currentDriverRouteKey(id);
      if (latestRouteKey != routeKey) {
        refreshAfterRoute = latestRouteKey != null;
        return;
      }
      setState(() {
        _driverApproachRoute = null;
        _driverRouteOrderId = id;
        _driverRouteError = 'Не удалось построить маршрут. Проверьте интернет и попробуйте ещё раз.';
        _driverRouteRetryAfter = DateTime.now().add(const Duration(seconds: 30));
      });
      _focusDriverMapOnRoute(latestPoint, pickup);
    } finally {
      if (mounted) {
        setState(() => _driverRouteLoading = false);
      } else {
        _driverRouteLoading = false;
      }
      if (refreshAfterRoute && mounted) {
        unawaited(_loadDriverApproachRoute());
      }
    }
  }

  void _focusDriverMapOnRoute(LatLng driverPoint, LatLng pickupPoint) {
    if (!_driverMapReady) return;
    final center = LatLng(
      (driverPoint.latitude + pickupPoint.latitude) / 2,
      (driverPoint.longitude + pickupPoint.longitude) / 2,
    );
    final latSpan = (driverPoint.latitude - pickupPoint.latitude).abs();
    final lngSpan = (driverPoint.longitude - pickupPoint.longitude).abs();
    final span = latSpan > lngSpan ? latSpan : lngSpan;
    final zoom = span > 0.5 ? 9.5 : span > 0.15 ? 11.0 : span > 0.04 ? 12.5 : 14.0;
    _driverMapController.move(center, zoom);
  }

  bool _isUsableDriverPosition(Position position) {
    return isUsableGpsFix(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracyMeters: position.accuracy,
      timestamp: position.timestamp,
    );
  }

  Future<bool> _publishDriverLocation(DriverModel driver) async {
    // Serialize GPS stream updates and heartbeat publications. A heartbeat
    // must wait for an earlier request instead of mistaking it for a failure.
    final waitUntil = DateTime.now().add(const Duration(seconds: 42));
    while (_locationUpdateInProgress && DateTime.now().isBefore(waitUntil)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted || !_driverWantsOnline ||
          TaxiParkState.currentLoggedInDriver?.id != driver.id) return false;
    }
    if (!mounted || !_driverWantsOnline || _locationUpdateInProgress ||
        TaxiParkState.currentLoggedInDriver?.id != driver.id) return false;
    // Read the latest point only after the previous request has completed.
    final point = driver.currentLocation;
    if (!point.latitude.isFinite || !point.longitude.isFinite ||
        point.latitude < -90 || point.latitude > 90 ||
        point.longitude < -180 || point.longitude > 180) return false;
    _locationUpdateInProgress = true;
    try {
      final result = await WorkerApi.setDriverOnline(
        online: true,
        latitude: point.latitude,
        longitude: point.longitude,
      );
      if (result['dispatcher_forced_offline'] == true) {
        _dispatcherForcedOffline = true;
        driver.isOnline = false;
        return true; // GPS remains active for a trip that was already assigned.
      }
      // If the driver switched off while this request was in flight, the final
      // server state must remain offline rather than being overwritten by GPS.
      if (!mounted || !_driverWantsOnline) {
        await WorkerApi.setDriverOnline(online: false);
        driver.isOnline = false;
        return false;
      }
      driver.isOnline = true;
      return true;
    } catch (_) {
      // The caller can distinguish a failed server update from a fresh GPS fix.
      return false;
    } finally {
      _locationUpdateInProgress = false;
    }
  }

  Future<void> _refreshDriverHeartbeat(DriverModel driver) async {
    if (!mounted || !_driverWantsOnline || _positionSubscription == null ||
        _heartbeatCheckInProgress ||
        TaxiParkState.currentLoggedInDriver?.id != driver.id) return;
    _heartbeatCheckInProgress = true;
    var freshGpsReceived = false;
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 15),
      );
      if (!mounted || !_driverWantsOnline || _positionSubscription == null ||
          TaxiParkState.currentLoggedInDriver?.id != driver.id) return;
      if (!_isUsableDriverPosition(position)) {
        throw StateError('GPS не предоставил свежие и точные координаты.');
      }
      freshGpsReceived = true;
      driver.currentLocation = LatLng(position.latitude, position.longitude);
      driver.locationUpdatedAt = position.timestamp;
      _driverRouteRetryAfter = null;
      setState(() {});
      final published = await _publishDriverLocation(driver);
      if (!published) {
        // A temporary Worker timeout is not a driver's decision to leave.
        _setDriverGpsReady(false);
        _scheduleLocationRetry();
        return;
      }
      _setDriverGpsReady(true);
    } catch (_) {
      if (!mounted || !_driverWantsOnline || TaxiParkState.currentLoggedInDriver?.id != driver.id) return;
      _setDriverGpsReady(false);
      if (freshGpsReceived) {
        // GPS is healthy; retry only the server publication.
        _scheduleLocationRetry();
      } else {
        // Without a fresh fix, stop advertising the previous location.
        _positionSubscription?.cancel();
        _positionSubscription = null;
        _stopLocationHeartbeat();
        unawaited(WorkerApi.setDriverOnline(online: false).then<void>((_) {}).catchError((_) {}));
        _scheduleLocationRetry();
      }
    } finally {
      _heartbeatCheckInProgress = false;
    }
  }

  void _stopLocationHeartbeat() {
    // A heartbeat is valid only while a live GPS stream is active.
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _setDriverGpsReady(bool ready) {
    // A late GPS callback must never put an offline/disposed driver back on line.
    final confirmedReady = ready && mounted && _driverWantsOnline && !_dispatcherForcedOffline;
    final driver = TaxiParkState.currentLoggedInDriver;
    if (driver != null) driver.isOnline = confirmedReady;
    if (!mounted || _driverGpsReady == confirmedReady) return;
    setState(() => _driverGpsReady = confirmedReady);
  }

  void _scheduleLocationRetry() {
    if (!mounted || !_driverWantsOnline || _locationRetryTimer?.isActive == true) return;
    _locationRetryTimer = Timer(const Duration(seconds: 20), () {
      _locationRetryTimer = null;
      if (!mounted || !_driverWantsOnline) return;
      final driver = TaxiParkState.currentLoggedInDriver;
      if (driver == null) return;
      if (_positionSubscription == null) {
        unawaited(_startLocationTracking());
      } else {
        unawaited(_refreshDriverHeartbeat(driver));
      }
    });
  }

  Future<void> _startLocationTracking() async {
    final driver = TaxiParkState.currentLoggedInDriver;
    if (driver == null || !mounted || !_driverWantsOnline || _locationTrackingStarting ||
        _positionSubscription != null) return;
    _locationTrackingStarting = true;
    _setDriverGpsReady(false);
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        unawaited(WorkerApi.setDriverOnline(online: false).then<void>((_) {}).catchError((_) {}));
        _showLocationMessage('Включите геолокацию на телефоне, чтобы выйти на линию.');
        _scheduleLocationRetry();
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        unawaited(WorkerApi.setDriverOnline(online: false).then<void>((_) {}).catchError((_) {}));
        _showLocationMessage('Разрешите приложению доступ к геолокации.');
        return;
      }
      final firstPosition = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 20),
      );
      // Экран мог закрыться, пока телефон определял координаты.
      if (!mounted || !_driverWantsOnline) return;
      if (!_isUsableDriverPosition(firstPosition)) {
        unawaited(WorkerApi.setDriverOnline(online: false).then<void>((_) {}).catchError((_) {}));
        _showLocationMessage('GPS пока определяет координаты недостаточно точно. Повторяем попытку.');
        _scheduleLocationRetry();
        return;
      }
      driver.currentLocation = LatLng(firstPosition.latitude, firstPosition.longitude);
      driver.locationUpdatedAt = firstPosition.timestamp;
      _driverRouteRetryAfter = null;
      if (mounted) setState(() {});
      // A temporary server outage must not erase the driver's line intent.
      final published = await _publishDriverLocation(driver);
      if (!mounted || !_driverWantsOnline) return;
      if (!published) {
        _setDriverGpsReady(false);
        _showLocationMessage(
          'GPS определён, но сервер временно не подтвердил связь. Повторяем подключение.',
        );
        _scheduleLocationRetry();
        return;
      }
      _setDriverGpsReady(true);

      // Avoid duplicate timers if tracking is restarted after a GPS interruption.
      _stopLocationHeartbeat();
      // Re-read the device GPS instead of refreshing the server with an old cached point.
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (!mounted || _positionSubscription == null) return;
        unawaited(_refreshDriverHeartbeat(driver));
      });
      _positionSubscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 20,
        ),
      ).listen((position) {
        if (!mounted || !_driverWantsOnline) return;
        // Ignore inaccurate or malformed fixes instead of moving the taxi marker.
        if (!_isUsableDriverPosition(position)) return;
        final latitude = position.latitude;
        final longitude = position.longitude;

        driver.currentLocation = LatLng(latitude, longitude);
        driver.locationUpdatedAt = position.timestamp;
        _driverRouteRetryAfter = null;
        _locationStreamErrorShown = false;
        setState(() {});
        if (_serverAssignedOrders.isNotEmpty) {
          unawaited(_loadDriverApproachRoute());
        }
        unawaited(_publishDriverLocation(driver).then<void>((published) {
          _setDriverGpsReady(published);
        }));
      }, onError: (Object error) {
        if (!mounted || !_driverWantsOnline) return;
        _setDriverGpsReady(false);
        _positionSubscription?.cancel();
        _positionSubscription = null;
        _stopLocationHeartbeat();
        if (!_locationStreamErrorShown) {
          _locationStreamErrorShown = true;
          _showLocationMessage('Временно потеряно обновление геолокации. Повторно подключаем GPS.');
        }
        // Stop advertising an old position as live while GPS is unavailable.
        unawaited(WorkerApi.setDriverOnline(online: false).then<void>((_) {}).catchError((_) {}));
        _scheduleLocationRetry();
      });
    } catch (e) {
      if (!mounted || !_driverWantsOnline) return;
      _setDriverGpsReady(false);
      // Do not leave the driver advertised as available after GPS startup failed.
      _stopLocationHeartbeat();
      unawaited(WorkerApi.setDriverOnline(online: false).then<void>((_) {}).catchError((_) {}));
      _showLocationMessage('Не удалось включить геолокацию: $e');
      _scheduleLocationRetry();
    } finally {
      _locationTrackingStarting = false;
    }
  }

  void _scheduleOfflineStateRetry() {
    if (!mounted || _driverWantsOnline || _offlineSyncRetryTimer?.isActive == true) return;
    _offlineSyncRetryTimer = Timer(const Duration(seconds: 10), () {
      _offlineSyncRetryTimer = null;
      unawaited(_retryOfflineStateSync());
    });
  }

  Future<void> _retryOfflineStateSync() async {
    if (!mounted || _driverWantsOnline || _offlineSyncInProgress) return;
    _offlineSyncInProgress = true;
    try {
      final result = await WorkerApi.setDriverOnline(online: false);
      if (result['online'] != false) {
        throw StateError('Сервер не подтвердил отключение водителя.');
      }
      _offlineSyncRetryTimer?.cancel();
      _offlineSyncRetryTimer = null;
    } catch (_) {
      _scheduleOfflineStateRetry();
    } finally {
      _offlineSyncInProgress = false;
    }
  }

  Future<void> _toggleDriverAvailability() async {
    if (!mounted || _availabilityChanging) return;
    if (_offlineSyncInProgress) {
      _showLocationMessage('Подождите подтверждения предыдущего изменения статуса.');
      return;
    }
    if (_serverAssignedOrders.isNotEmpty) {
      _showLocationMessage('Сначала завершите активный заказ. Во время поездки нельзя уходить с линии.');
      return;
    }
    setState(() => _availabilityChanging = true);
    try {
      if (_driverWantsOnline) {
        await _saveDriverLinePreference(
          TaxiParkState.currentLoggedInDriver?.id ?? '',
          false,
        );
        setState(() {
          _driverWantsOnline = false;
          _driverGpsReady = false;
          _serverOpenOrders = [];
          if (TaxiParkState.currentLoggedInDriver != null) {
            TaxiParkState.currentLoggedInDriver!.isOnline = false;
          }
        });
        _locationRetryTimer?.cancel();
        _locationRetryTimer = null;
        await _positionSubscription?.cancel();
        _positionSubscription = null;
        _stopLocationHeartbeat();
        try {
          final result = await WorkerApi.setDriverOnline(online: false);
          if (result['online'] != false) {
            throw StateError('Сервер не подтвердил отключение водителя.');
          }
          _offlineSyncRetryTimer?.cancel();
          _offlineSyncRetryTimer = null;
          if (mounted) _showLocationMessage('Вы вышли с линии. Новые заказы поступать не будут.');
        } catch (_) {
          _scheduleOfflineStateRetry();
          if (mounted) _showLocationMessage('Нет подтверждения от сервера. Приложение повторит отключение автоматически.');
        }
      } else {
        try {
          await WorkerApi.returnDriverToLine();
          _dispatcherForcedOffline = false;
        } catch (error) {
          if (mounted) _showLocationMessage(error.toString());
          return;
        }
        _offlineSyncRetryTimer?.cancel();
        _offlineSyncRetryTimer = null;
        setState(() {
          _driverWantsOnline = true;
          _driverGpsReady = false;
        });
        await _saveDriverLinePreference(
          TaxiParkState.currentLoggedInDriver?.id ?? '',
          true,
        );
        await _startLocationTracking();
        if (mounted) unawaited(_pollServerOrders());
      }
    } finally {
      if (mounted) setState(() => _availabilityChanging = false);
    }
  }

  void _showLocationMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: TaxiText(message)));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _driverWantsOnline = false;
    _positionSubscription?.cancel();
    _heartbeatTimer?.cancel();
    _locationRetryTimer?.cancel();
    _offlineSyncRetryTimer?.cancel();
    _ordersPollTimer?.cancel();
    unawaited(_pushTokenSubscription?.cancel());
    // Mark the driver offline when leaving the live driver screen.
    unawaited(WorkerApi.setDriverOnline(online: false).then<void>((_) {}).catchError((_) {}));
    super.dispose();
  }

  Future<void> _logoutDriver() async {
    if (_logoutInProgress || _availabilityChanging || _offlineSyncInProgress) return;

    setState(() => _logoutInProgress = true);
    try {
      // Always obtain a fresh server snapshot before signing out so a
      // temporary network failure cannot hide an active assigned trip.
      final data = await WorkerApi.openOrders();
      final snapshot = ServerOrderSnapshot.parse(data);
      if (!mounted) return;
      setState(() {
        _serverAssignedOrders = snapshot.assignedOrders;
        _serverOpenOrders = _driverWantsOnline
            ? snapshot.openOrders
            : <Map<String, dynamic>>[];
      });

      if (snapshot.assignedOrders.isNotEmpty) {
        _showLocationMessage(
          'Нельзя выйти из аккаунта во время назначенного заказа. '
          'Сначала завершите поездку или согласуйте её отмену с диспетчером.',
        );
        return;
      }

      // No active trip: stop local tracking and ask the server to confirm
      // offline state before ending Firebase authentication.
      setState(() {
        _driverWantsOnline = false;
        _driverGpsReady = false;
        _serverOpenOrders = [];
        if (TaxiParkState.currentLoggedInDriver != null) {
          TaxiParkState.currentLoggedInDriver!.isOnline = false;
        }
      });
      await _saveDriverLinePreference(
        TaxiParkState.currentLoggedInDriver?.id ?? '',
        false,
      );
      _locationRetryTimer?.cancel();
      _locationRetryTimer = null;
      _offlineSyncRetryTimer?.cancel();
      _offlineSyncRetryTimer = null;
      await _positionSubscription?.cancel();
      _positionSubscription = null;
      _stopLocationHeartbeat();

      final result = await WorkerApi.setDriverOnline(online: false)
          .timeout(const Duration(seconds: 20));
      if (result['online'] != false) {
        throw StateError('Сервер не подтвердил отключение от линии.');
      }

      await FirebaseService.signOut().timeout(const Duration(seconds: 20));
      TaxiParkState.currentLoggedInDriver = null;
      if (mounted) Navigator.popUntil(context, (route) => route.isFirst);
    } catch (e) {
      // If the active-order check itself failed, do not guess that the trip
      // list is empty and do not sign out while the server is unreachable.
      if (!_driverWantsOnline) _scheduleOfflineStateRetry();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: TaxiText(
              'Не удалось проверить активные заказы или завершить выход. '
              'Проверьте интернет и повторите попытку: $e',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _logoutInProgress = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final driver = TaxiParkState.currentLoggedInDriver;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: const SizedBox.shrink(),
        title: TaxiText(
          'Водитель: ${driver?.name ?? ""} (${driver?.fullCarInfo ?? ""})',
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: const Color(0xFF087A42),
        foregroundColor: Colors.white,
        actions: [
          const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: TaxiLanguageSwitcher()),
          Tooltip(
            message: !_driverWantsOnline
                ? 'Выйти на линию'
                : (_driverGpsReady ? 'Выйти с линии' : 'Отменить выход на линию'),
            child: TextButton.icon(
              onPressed: _availabilityChanging ? null : _toggleDriverAvailability,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: _driverWantsOnline
                    ? const Color(0xFF075B32)
                    : const Color(0xFF145C3A),
                disabledForegroundColor: Colors.white70,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
                minimumSize: const Size(0, 54),
                textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                side: const BorderSide(color: Color(0xFFFFD400), width: 3),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: Icon(!_driverWantsOnline
                  ? Icons.toggle_off
                  : (_driverGpsReady ? Icons.toggle_on : Icons.gps_not_fixed),
                  size: 27),
              label: TaxiText(_availabilityChanging
                  ? 'Подождите…'
                  : (!_driverWantsOnline
                      ? 'Не на линии'
                      : (_driverGpsReady ? 'На линии' : 'GPS не подтверждён'))),
            ),
          ),
          IconButton(
            tooltip: _logoutInProgress ? 'Завершаем выход…' : 'Выйти из кабинета',
            onPressed: (_availabilityChanging || _logoutInProgress) ? null : _logoutDriver,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              mapController: _driverMapController,
              options: MapOptions(
                  initialCenter:
                      driver?.currentLocation ?? TaxiParkState.sulyuktaCenter,
                  initialZoom: 14.5,
                  onMapReady: () {
                    _driverMapReady = true;
                    if (_driverApproachRoute != null && _serverAssignedOrders.isNotEmpty) {
                      final pickup = _orderPickup(_serverAssignedOrders.first);
                      final current = TaxiParkState.currentLoggedInDriver?.currentLocation;
                      if (pickup != null && current != null) _focusDriverMapOnRoute(current, pickup);
                    } else if (driver != null) {
                      _driverMapController.move(driver.currentLocation, 14.0);
                    }
                  }),
              children: [
                ...buildTaxiDarkMapLayers(),
                if (_driverApproachRoute != null &&
                    _serverAssignedOrders.isNotEmpty &&
                    _driverRouteOrderId ==
                        (_serverAssignedOrders.first['id'] ??
                                _serverAssignedOrders.first['firebase_order_id'] ??
                                '')
                            .toString())
                  PolylineLayer(polylines: [Polyline(points: _driverApproachRoute!.points, color: const Color(0xFFFFD400), strokeWidth: 6)]),
                MarkerLayer(
                  markers: [
                    if (driver != null)
                      Marker(
                        point: driver.currentLocation,
                        width: 40,
                        height: 40,
                        child: Container(
                          decoration: BoxDecoration(color: const Color(0xFF171717), shape: BoxShape.circle, border: Border.all(color: const Color(0xFFFFD400), width: 2), boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 8)]),
                          child: const Icon(Icons.local_taxi, color: Color(0xFFFFD400), size: 27),
                        ),
                      ),
                    ..._serverOpenOrders.map((item) => _orderPickup(item)).whereType<LatLng>().map((point) => Marker(
                      point: point,
                      width: 42,
                      height: 42,
                      child: Container(decoration: BoxDecoration(color: const Color(0xFF171717), shape: BoxShape.circle, border: Border.all(color: const Color(0xFFFFD400), width: 2)), child: const Icon(Icons.location_on, color: Color(0xFFFFD400), size: 27)),
                    )),
                    ..._serverAssignedOrders.map((item) => _orderPickup(item)).whereType<LatLng>().map((point) => Marker(
                      point: point,
                      width: 42,
                      height: 42,
                      child: Container(decoration: BoxDecoration(color: const Color(0xFFFFD400), shape: BoxShape.circle, border: Border.all(color: const Color(0xFF171717), width: 2)), child: const Icon(Icons.flag, color: Color(0xFF171717), size: 25)),
                    )),
                  ],
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(color: const Color(0xFFFFFEFA), border: Border(top: BorderSide(color: const Color(0xFF087A42), width: 3)), borderRadius: const BorderRadius.vertical(top: Radius.circular(22))),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.42,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                Card(
                  color: const Color(0xFFFFF7D6),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const TaxiLocalizedText(russian: 'ВАШ ЗАРАБОТОК СЕГОДНЯ', kyrgyz: 'БҮГҮНКҮ КИРЕШЕҢИЗ',
                        style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF765500))),
                      const SizedBox(height: 5),
                      TaxiText('Выполнено заказов: ${_driverEarnings['completed_trips'] ?? 0}'),
                      TaxiText('Общая сумма поездок: ${_driverEarnings['gross_earnings_som'] ?? 0} сом'),
                      if(_driverEarnings.isNotEmpty)
                        TaxiText('Ваша доля (${_driverEarnings['commission_percent']}%): ${_driverEarnings['driver_share_som']??0} сом',
                          style:const TextStyle(fontWeight:FontWeight.bold,fontSize:16)),
                      if(_driverEarnings.isEmpty)
                        TaxiText(_driverEarningsError??(_driverEarningsLoading?'Загружаем финансовые данные…':'Процент и заработок пока не подтверждены сервером.'),
                          style:const TextStyle(fontSize:11,color:Colors.black54)),
                      if(_driverEarnings['can_close_shift']==true)
                        Padding(padding:const EdgeInsets.only(top:10),child:SizedBox(width:double.infinity,
                          child:ElevatedButton.icon(
                            onPressed:_driverShiftClosing?null:_closeOwnDriverShift,
                            icon:const Icon(Icons.lock_clock),
                            label:TaxiText(_driverShiftClosing?'ЗАКРЫТИЕ СМЕНЫ…':'ЗАКРЫТЬ СМЕНУ'),
                          ))),
                    ]),
                  ),
                ),
                const SizedBox(height: 8),
                const TaxiLocalizedText(russian: 'Заказы и их статусы обновляются с сервера', kyrgyz: 'Буйрутмалар жана алардын абалы серверден жаңыланат',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF087A42))),
                const SizedBox(height: 10),
                if (_serverAssignedOrders.isNotEmpty) ...[
                  const TaxiLocalizedText(russian: 'ВАШ НАЗНАЧЕННЫЙ ЗАКАЗ', kyrgyz: 'СИЗГЕ ДАЙЫНДАЛГАН БУЙРУТМА', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF087A42))),
                  ..._serverAssignedOrders.map((item) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.flag, color: Colors.green),
                      title: TaxiText((item['destination_address'] ?? 'Пункт назначения не указан').toString()),
                      subtitle: TaxiText('Подача: ${item['pickup_address'] ?? 'На карте'}\nПассажиров: ${item['passenger_count'] ?? 1} · ${item['payment_method'] ?? ''}\n${_driverRouteLoading ? 'Строим маршрут…' : (_driverApproachRoute != null && _driverRouteOrderId == (item['id'] ?? item['firebase_order_id'] ?? '').toString() ? 'По дорогам: ${_driverApproachRoute!.distanceLabel} · примерно ${_driverApproachRoute!.etaLabel}' : (_driverRouteError ?? 'Маршрут пока не рассчитан'))}'),
                      trailing: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton.icon(
                            onPressed: _orderActionIds.contains(_serverOrderId(item)) ? null : () => _completeAssignedOrder(item),
                            icon: const Icon(Icons.check_circle, color: Colors.green),
                            label: const TaxiLocalizedText(russian: 'ЗАКАЗ ИСПОЛНЕН', kyrgyz: 'БУЙРУТМА АТКАРЫЛДЫ', style: TextStyle(color: Colors.green)),
                          ),
                        ],
                      ),
                    ),
                  )),
                ],
                if (_serverOpenOrders.isNotEmpty) ...[
                  const TaxiLocalizedText(russian: 'ОТКРЫТЫЕ ЗАКАЗЫ РЯДОМ', kyrgyz: 'ЖАКЫНДАГЫ АЧЫК БУЙРУТМАЛАР', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF087A42))),
                  ..._serverOpenOrders.map((item) {
                    final id = (item['id'] ?? '').toString();
                    final pickup = item['pickup_address'] ?? 'Точка на карте';
                    final destination = item['destination_address'] ?? 'Пункт назначения не указан';
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.local_taxi, color: Colors.amber),
                        title: TaxiText(destination.toString()),
                        subtitle: TaxiText('Подача: $pickup\nПассажиров: ${item['passenger_count'] ?? 1} · ${item['payment_method'] ?? ''} · ${item['tariff_type'] ?? ''}'),
                        trailing: ElevatedButton(
                          onPressed: _respondingOrderIds.contains(id) ? null : () => _respondToServerOrder(item),
                          child: TaxiText(_respondingOrderIds.contains(id) ? 'ОЖИДАНИЕ' : 'ПРИНЯТЬ ЗАКАЗ'),
                        ),
                      ),
                    );
                  }),
                ] else if (_serverAssignedOrders.isEmpty)
                  const TaxiLocalizedText(russian: 'Новых заказов пока нет. Ожидаем...', kyrgyz: 'Азырынча жаңы буйрутма жок. Күтүп жатабыз...', style: TextStyle(color: Colors.grey)),
                const SizedBox(height: 10),
                WalkieTalkieWidget(senderName: driver?.name ?? 'Водитель', allowText: _serverAssignedOrders.isEmpty),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class DispatcherScreen extends StatefulWidget {
  const DispatcherScreen({super.key});

  @override
  State<DispatcherScreen> createState() => _DispatcherScreenState();
}

class _DispatcherScreenState extends State<DispatcherScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _drivers = [];
  List<Map<String, dynamic>> _orders = [];
  List<Map<String, dynamic>> _cancellations = [];
  bool _hasMoreCancellations = false;
  bool _loadingMoreCancellations = false;
  int? _cancellationCursorAt;
  String? _cancellationCursorId;
  List<Map<String, dynamic>> _today = [];
  List<Map<String, dynamic>> _earnings = [];
  List<Map<String, dynamic>> _closedShifts = [];
  String _businessDate = '';
  int _cityFareSom = 0;
  int _intercityFareSom = 0;
  List<String> _dispatcherPhones = [];
  bool _working = false;
  bool _dispatcherLoadInProgress = false;
  bool _dispatcherRefreshPending = false;
  String? _dispatcherRefreshError;
  Timer? _dispatcherRefreshTimer;
  Timer? _documentTransferMonitor;
  final Map<String, DriverDocumentTransferLiveKit> _documentTransferSessions = {};
  final Map<String, String> _documentTransferStates = {};
  bool _documentTransferMonitorRunning = false;

  @override
  void initState() {
    super.initState();
    _load();
    _dispatcherRefreshTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted && !_working) unawaited(_load(showLoading: false));
    });
    _documentTransferMonitor = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_monitorDocumentTransfers()));
  }

  @override
  void dispose() {
    _dispatcherRefreshTimer?.cancel();
    _documentTransferMonitor?.cancel();
    for (final session in _documentTransferSessions.values) { unawaited(session.dispose()); }
    _documentTransferSessions.clear();
    super.dispose();
  }

  Future<void> _requestDriverDocuments(Map<String, dynamic> driver) async {
    final uid = (driver['uid'] ?? '').toString().trim();
    if (uid.isEmpty || uid.length > 128 || _documentTransferSessions.containsKey(uid)) return;
    setState(() => _documentTransferStates[uid] = 'Подключаемся к телефону водителя…');
    try {
      final request = await WorkerApi.requestDriverDocuments(uid);
      final requestId = (request['request_id'] ?? '').toString().trim();
      if (requestId.isEmpty) throw const FormatException('Сервер не вернул номер запроса.');
      final session = await DriverDocumentTransferLiveKit.connect(requestId: requestId, driverUid: uid, isDispatcher: true);
      if (!mounted) { await session.dispose(); return; }
      _documentTransferSessions[uid] = session;
      setState(() => _documentTransferStates[uid] = 'Ожидаем фотографии: 0 из 3');
      _notice('Запрос отправлен. Телефон водителя должен быть подключён к интернету.');
    } catch (error) {
      if (mounted) setState(() => _documentTransferStates[uid] = 'Ошибка передачи: $error');
    }
  }

  Future<void> _monitorDocumentTransfers() async {
    if (!mounted || _documentTransferSessions.isEmpty || _documentTransferMonitorRunning) return;
    _documentTransferMonitorRunning = true;
    try {
      for (final entry in List<MapEntry<String, DriverDocumentTransferLiveKit>>.from(_documentTransferSessions.entries)) {
      final uid = entry.key, session = entry.value;
      if (!mounted || !identical(_documentTransferSessions[uid], session)) continue;
      if (!session.isComplete) {
        // Retry a completed chunk assembly when an earlier local file write
        // failed; otherwise no new network packet may arrive to trigger it.
        await session.retryPendingPersistence();
        final status = 'Получено фотографий: ${session.receivedDocumentCount} из 3';
        if (_documentTransferStates[uid] != status) setState(() => _documentTransferStates[uid] = status);
        continue;
      }
      if (!session.isConfirmed) {
        try { await session.retryConfirmation(); } catch (_) {
          if (mounted) setState(() => _documentTransferStates[uid] = 'Все фото получены, подтверждаем получение…');
          continue;
        }
      }
      if (!session.isConfirmed) continue;
      final docs = await Future.wait([
        DriverDocumentStore.find(uid: uid, documentType: 'license'),
        DriverDocumentStore.find(uid: uid, documentType: 'driver_photo'),
        DriverDocumentStore.find(uid: uid, documentType: 'car_photo'),
      ]);
      if (docs.any((file) => file == null)) {
        if (mounted) setState(() => _documentTransferStates[uid] = 'Не удалось проверить сохранённые файлы. Запросите повторно.');
        continue;
      }
      _documentTransferSessions.remove(uid);
      if (mounted) setState(() => _documentTransferStates[uid] = 'Все 3 документа получены и сохранены на телефоне диспетчера');
      await session.dispose();
      }
    } finally {
      _documentTransferMonitorRunning = false;
    }
  }

  Future<void> _load({bool showLoading = true}) async {
    if (_dispatcherLoadInProgress) {
      _dispatcherRefreshPending = true;
      return;
    }
    final requestUid = FirebaseAuth.instance.currentUser?.uid;
    _dispatcherLoadInProgress = true;
    // При обновлении данных после изменения тарифа не убираем всю панель
    // с экрана: это сохраняет состояние вложенных виджетов и диалогов.
    if (mounted) {
      setState(() {
        if (showLoading) _loading = true;
        _error = null;
      });
    }
    try {
      final data = await WorkerApi.dispatcherOverview();
      final snapshot = DispatcherOverviewSnapshot.parse(data);
      final tariffData = await WorkerApi.getTariffs();
      final tariffs = Map<String, dynamic>.from(tariffData['tariffs'] as Map? ?? {});
      List<String> dispatcherPhones = _dispatcherPhones;
      try {
        final phoneData = await WorkerApi.getPublicDispatcherPhones();
        final rawPhones = phoneData['phones'];
        if (rawPhones is List && rawPhones.length <= 3 && rawPhones.every((value) => value is String)) {
          dispatcherPhones = rawPhones.map((value) => value.toString()).toList();
        }
      } catch (_) {}
      // Do not let a response started by a previous dispatcher account replace
      // the current screen after logout or an account switch.
      if (!mounted || requestUid == null ||
          FirebaseAuth.instance.currentUser?.uid != requestUid) return;
      setState(() {
        _cityFareSom = (tariffs['city_fare_som'] as num?)?.toInt() ?? 0;
        _intercityFareSom = (tariffs['intercity_fare_som'] as num?)?.toInt() ?? 0;
        _dispatcherPhones = dispatcherPhones;
        _drivers = snapshot.drivers.map((e) => Map<String, dynamic>.from(e)).toList();
        _orders = snapshot.orders.map((e) => Map<String, dynamic>.from(e)).toList();
        _today = snapshot.today.map((e) => Map<String, dynamic>.from(e)).toList();
        _earnings = snapshot.earnings.map((e) => Map<String, dynamic>.from(e)).toList();
        _closedShifts = snapshot.closedShifts.map((e) => Map<String, dynamic>.from(e)).toList();
        _businessDate = snapshot.businessDate;
        _dispatcherRefreshError = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (showLoading) {
          _error = e.toString();
        } else {
          _dispatcherRefreshError = e.toString();
        }
      });
    } finally {
      _dispatcherLoadInProgress = false;
      if (mounted && _dispatcherRefreshPending) {
        _dispatcherRefreshPending = false;
        scheduleMicrotask(() => _load(showLoading: false));
      }
    }
  }

  Future<void> _logoutDispatcher() async {
    if (_working) return;
    try {
      await FirebaseService.signOut().timeout(const Duration(seconds: 20));
      if (mounted) Navigator.popUntil(context, (route) => route.isFirst);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: TaxiText('Не удалось выйти из кабинета: $e')),
        );
      }
    }
  }

  Map<String, dynamic> _parseCancellationPage(Map<String, dynamic> data) {
    final rawRows = data['cancellations'];
    final hasMore = data['has_more'];
    if (rawRows is! List || hasMore is! bool) {
      throw const FormatException('Сервер вернул неверный формат истории отмен.');
    }
    final rows = <Map<String, dynamic>>[];
    final pageIds = <String>{};
    for (final raw in rawRows) {
      if (raw is! Map) {
        throw const FormatException('В истории отмен обнаружена неверная запись.');
      }
      final row = Map<String, dynamic>.from(raw);
      final orderId = (row['order_id'] ?? '').toString().trim();
      if (orderId.isEmpty || !pageIds.add(orderId)) {
        throw const FormatException('В истории отмен обнаружен пустой или повторный номер заказа.');
      }
      row['order_id'] = orderId;
      rows.add(row);
    }
    int? cursorAt;
    String? cursorId;
    final rawCursor = data['next_cursor'];
    if (hasMore) {
      if (rawCursor is! Map || rows.isEmpty) {
        throw const FormatException('Сервер не передал указатель следующей страницы истории отмен.');
      }
      final cursor = Map<String, dynamic>.from(rawCursor);
      final rawAt = cursor['before_at'];
      final rawId = (cursor['before_id'] ?? '').toString().trim();
      if (rawAt is! num || !rawAt.isFinite || rawAt < 0 ||
          rawAt % 1 != 0 || rawAt > 9007199254740991 ||
          rawId.isEmpty || rawId.length > 128 ||
          RegExp(r'[\x00-\x1F\x7F]').hasMatch(rawId)) {
        throw const FormatException('Сервер вернул неверный указатель следующей страницы истории отмен.');
      }
      cursorAt = rawAt.toInt();
      cursorId = rawId;
    }
    return {
      'rows': rows,
      'has_more': hasMore,
      'cursor_at': cursorAt,
      'cursor_id': cursorId,
    };
  }

  Future<void> _refreshCancellationHistory({bool silent = false}) async {
    if (!mounted || _loadingMoreCancellations) return;
    setState(() => _loadingMoreCancellations = true);
    try {
      final data = await WorkerApi.dispatcherCancellations();
      final page = _parseCancellationPage(data);
      if (!mounted) return;
      setState(() {
        _cancellations = page['rows'] as List<Map<String, dynamic>>;
        _hasMoreCancellations = page['has_more'] as bool;
        _cancellationCursorAt = page['cursor_at'] as int?;
        _cancellationCursorId = page['cursor_id'] as String?;
      });
    } catch (error) {
      if (!mounted) return;
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: TaxiText('Не удалось обновить историю отмен: $error'),
        ));
      }
    } finally {
      if (mounted) setState(() => _loadingMoreCancellations = false);
    }
  }

  Future<void> _loadMoreCancellationHistory() async {
    final beforeAt = _cancellationCursorAt;
    final beforeId = _cancellationCursorId;
    if (!mounted || _loadingMoreCancellations || !_hasMoreCancellations ||
        beforeAt == null || beforeId == null || beforeId.isEmpty) return;
    setState(() => _loadingMoreCancellations = true);
    try {
      final data = await WorkerApi.dispatcherCancellations(
        beforeAt: beforeAt,
        beforeId: beforeId,
      );
      final page = _parseCancellationPage(data);
      final nextAt = page['cursor_at'] as int?;
      final nextId = page['cursor_id'] as String?;
      if (page['has_more'] == true &&
          nextAt == beforeAt && nextId == beforeId) {
        throw const FormatException('История отмен не перешла к следующей странице. Повторите обновление.');
      }
      if (!mounted) return;
      setState(() {
        final knownIds = _cancellations
            .map((item) => (item['order_id'] ?? '').toString())
            .toSet();
        _cancellations.addAll((page['rows'] as List<Map<String, dynamic>>).where(
          (item) => !knownIds.contains((item['order_id'] ?? '').toString()),
        ));
        _hasMoreCancellations = page['has_more'] as bool;
        _cancellationCursorAt = nextAt;
        _cancellationCursorId = nextId;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: TaxiText('Не удалось загрузить следующие отмены: $error'),
        ));
      }
    } finally {
      if (mounted) setState(() => _loadingMoreCancellations = false);
    }
  }

  Widget _dispatcherDriverMap() {
    final markers = <Marker>[];
    for (final driver in _drivers) {
      final approved = driver['approved'] == true || driver['approved'] == 1 || driver['approved'].toString() == '1';
      final online = driver['online'] == true || driver['online'] == 1 || driver['online'].toString() == '1';
      if (!approved || !online) continue;
      final latitude = double.tryParse((driver['latitude'] ?? '').toString());
      final longitude = double.tryParse((driver['longitude'] ?? '').toString());
      final updatedAt = parseGpsTimestamp(driver['location_updated_at']);
      if (latitude == null || longitude == null || !latitude.isFinite || !longitude.isFinite ||
          latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180 ||
          !isGpsTimestampFresh(updatedAt)) continue;
      final name = (driver['name'] ?? 'Водитель').toString();
      markers.add(Marker(
        point: LatLng(latitude, longitude),
        width: 44,
        height: 48,
        child: Tooltip(
          message: name,
          child: const Icon(Icons.local_taxi, color: Colors.green, size: 34),
        ),
      ));
    }
    final center = markers.isEmpty
        ? TaxiParkState.sulyuktaCenter
        : LatLng(
            markers.map((marker) => marker.point.latitude).reduce((a, b) => a + b) / markers.length,
            markers.map((marker) => marker.point.longitude).reduce((a, b) => a + b) / markers.length,
          );
    final latitudeSpan = markers.isEmpty ? 0.0 : markers.map((marker) => marker.point.latitude).reduce((a, b) => a > b ? a : b) - markers.map((marker) => marker.point.latitude).reduce((a, b) => a < b ? a : b);
    final longitudeSpan = markers.isEmpty ? 0.0 : markers.map((marker) => marker.point.longitude).reduce((a, b) => a > b ? a : b) - markers.map((marker) => marker.point.longitude).reduce((a, b) => a < b ? a : b);
    final fleetZoom = markers.length < 2 ? 12.5 : (latitudeSpan > 0.5 || longitudeSpan > 0.5 ? 8.5 : (latitudeSpan > 0.1 || longitudeSpan > 0.1 ? 10.5 : 12.5));
    return Card(child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TaxiText('На линии с актуальным GPS: ${markers.length}', style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        SizedBox(height: 260, child: FlutterMap(
          options: MapOptions(initialCenter: center, initialZoom: fleetZoom),
          children: [
            ...buildTaxiDarkMapLayers(),
            MarkerLayer(markers: markers),
          ],
        )),
        const SizedBox(height: 6),
        const TaxiText('Показываются только одобренные водители на линии с GPS не старше 60 секунд.',
          style: TextStyle(fontSize: 12, color: Colors.black54)),
      ]),
    ));
  }

  Future<void> _approve(Map<String, dynamic> driver, bool approved) async {
    final uid = (driver['uid'] ?? '').toString();
    if (uid.isEmpty) return;
    if (!approved) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Отключить допуск водителя?'),
          content: const Text('Водитель будет снят с линии. Одобрение документов сохранится, и допуск можно будет восстановить без повторной проверки.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Отключить допуск')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _working = true);
    try {
      await WorkerApi.approveDriver(uid: uid, approved: approved);
      await _load();
      if (mounted) _notice(approved ? 'Водитель одобрен' : 'Допуск водителя отключён');
    } catch (e) {
      if (mounted) _notice(e.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _review(Map<String, dynamic> driver, String decision) async {
    final uid = (driver['uid'] ?? '').toString();
    if (uid.isEmpty) return;
    final reasonController = TextEditingController();
    final reason = decision == 'rejected' ? await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const TaxiLocalizedText(russian: 'Причина отклонения', kyrgyz: 'Четке кагуу себеби'),
        content: TextField(
          controller: reasonController,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'Например: фото удостоверения нечёткое',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const TaxiLocalizedText(russian: 'Отмена', kyrgyz: 'Жокко чыгаруу')),
          ElevatedButton(onPressed: () {
            final value = reasonController.text.trim();
            if (value.length < 5) return;
            Navigator.pop(ctx, value);
          }, child: const TaxiLocalizedText(russian: 'Отклонить', kyrgyz: 'Четке кагуу')),
        ],
      ),
    ) : '';
    if (decision == 'rejected' && reason == null) return;
    setState(() => _working = true);
    try {
      await WorkerApi.reviewDriver(uid: uid, decision: decision, reason: reason ?? '');
      await _load();
      if (mounted) _notice(decision == 'approved' ? 'Документы одобрены. Водитель допущен.' : 'Заявка отклонена. Водитель увидит причину.');
    } catch (e) {
      if (mounted) _notice(e.toString());
    } finally {
      // Даём окну причины завершить анимацию закрытия до dispose контроллера.
      Future<void>.delayed(const Duration(milliseconds: 350), () => reasonController.dispose());
      if (mounted) setState(() => _working = false);
    }
  }

  bool _driverCanReceiveAssignment(Map<String, dynamic> driver) {
    final approved = driver['approved'] == true || driver['approved'] == 1 ||
        driver['approved']?.toString().trim().toLowerCase() == 'true' ||
        driver['approved']?.toString().trim() == '1';
    final online = driver['online'] == true || driver['online'] == 1 ||
        driver['online']?.toString().trim().toLowerCase() == 'true' ||
        driver['online']?.toString().trim() == '1';
    final uid = (driver['uid'] ?? '').toString().trim();
    final activeOrderId = (driver['active_order_id'] ?? '').toString().trim();
    final latitude = double.tryParse((driver['latitude'] ?? '').toString());
    final longitude = double.tryParse((driver['longitude'] ?? '').toString());
    final gpsUpdatedAt = parseGpsTimestamp(driver['location_updated_at']);
    return approved && online && uid.isNotEmpty && uid.length <= 128 &&
        activeOrderId.isEmpty &&
        latitude != null && longitude != null &&
        latitude.isFinite && longitude.isFinite &&
        latitude >= -90 && latitude <= 90 &&
        longitude >= -180 && longitude <= 180 &&
        isGpsTimestampFresh(gpsUpdatedAt);
  }

  Future<void> _removeOpenOrder(Map<String, dynamic> order) async {
    final orderId = (order['id'] ?? '').toString().trim();
    if (orderId.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const TaxiLocalizedText(russian: 'Убрать старый заказ?', kyrgyz: 'Эски буйрутманы тизмеден алып саласызбы?'),
        content: const TaxiLocalizedText(
          russian: 'Заказ исчезнет из открытого списка водителей и диспетчера. Запись останется в базе, а принятые и завершённые поездки не затрагиваются.',
          kyrgyz: 'Буйрутма айдоочулардын жана диспетчердин ачык тизмесинен алынат. Маалымат базада сакталат, кабыл алынган жана аяктаган сапарларга таасир этпейт.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const TaxiLocalizedText(russian: 'Отмена', kyrgyz: 'Жокко чыгаруу')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const TaxiLocalizedText(russian: 'Убрать', kyrgyz: 'Алып салуу')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _working = true);
    try {
      await WorkerApi.removeOpenOrder(orderId: orderId);
      await _load(showLoading: false);
      if (mounted) _notice('Заказ убран из открытого списка. История сохранена.');
    } catch (e) {
      if (mounted) _notice(e.toString());
      await _load(showLoading: false);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _assign(Map<String, dynamic> order) async {
    final orderId = (order['id'] ?? '').toString().trim();
    if (orderId.isEmpty || orderId.length > 128) {
      _notice('Не удалось назначить заказ: неверный номер заявки.');
      return;
    }
    if ((order['status'] ?? '').toString() != 'new') {
      _notice('Этот заказ уже изменил статус. Обновите список заявок.');
      await _load(showLoading: false);
      return;
    }
    final available = _drivers.where(_driverCanReceiveAssignment).toList();
    if (available.isEmpty) {
      final approved = _drivers.any((d) =>
          d['approved'] == true || d['approved'] == 1 ||
          d['approved']?.toString().trim().toLowerCase() == 'true' ||
          d['approved']?.toString().trim() == '1');
      _notice(approved
          ? 'Нет свободных водителей на линии с актуальной геолокацией. Проверьте, что водитель включил GPS и завершил предыдущую поездку.'
          : 'Нет одобренных водителей. Сначала проверьте и одобрите документы водителя.');
      return;
    }
    String? selected = available.first['uid']?.toString();
    final confirmed = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDialog) => AlertDialog(
        title: const TaxiLocalizedText(russian: 'Назначить водителя', kyrgyz: 'Айдоочуну дайындоо'),
        content: DropdownButtonFormField<String>(
          value: selected,
          isExpanded: true,
          items: available.map((d) => DropdownMenuItem<String>(
            value: d['uid'].toString(),
            child: TaxiText('${d['name'] ?? 'Водитель'} · ${d['car_number'] ?? 'без номера'} · на линии'),
          )).toList(),
          onChanged: (v) => setDialog(() => selected = v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const TaxiLocalizedText(russian: 'Отмена', kyrgyz: 'Жокко чыгаруу')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, selected), child: const TaxiText('Назначить')),
        ],
      )),
    );
    if (confirmed == null) return;
    final selectedDriver = _drivers.firstWhere(
      (driver) => (driver['uid'] ?? '').toString() == confirmed,
      orElse: () => <String, dynamic>{},
    );
    if (!_driverCanReceiveAssignment(selectedDriver)) {
      _notice('Водитель уже не готов принять заказ: он ушёл с линии, GPS устарел или выполняет другую поездку. Обновите список.');
      await _load(showLoading: false);
      return;
    }
    setState(() => _working = true);
    try {
      await WorkerApi.assignOrder(orderId: orderId, driverUid: confirmed);
      await _load();
      if (mounted) _notice('Заказ назначен водителю');
    } catch (e) {
      if (mounted) _notice(e.toString());
      await _load();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _editDispatcherPhones() async {
    final controllers = List.generate(3, (index) => TextEditingController(
      text: index < _dispatcherPhones.length ? _dispatcherPhones[index] : '',
    ));
    final values = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const TaxiLocalizedText(russian: 'Телефоны диспетчера', kyrgyz: 'Диспетчердин телефондору'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < controllers.length; i++) ...[
            TextField(controller: controllers[i], keyboardType: TextInputType.phone,
              decoration: InputDecoration(labelText: 'Телефон ${i + 1}', hintText: '0555123456')),
            if (i < 2) const SizedBox(height: 10),
          ],
          const SizedBox(height: 8),
          const TaxiLocalizedText(russian: 'Оставьте поле пустым, если номер не нужен. Максимум три номера.',
            kyrgyz: 'Номер кереги жок болсо, талааны бош калтырыңыз. Эң көп дегенде үч номер.'),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const TaxiLocalizedText(russian: 'Отмена', kyrgyz: 'Жокко чыгаруу')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx,
            controllers.map((controller) => controller.text.trim()).where((value) => value.isNotEmpty).toList()),
            child: const TaxiLocalizedText(russian: 'Сохранить', kyrgyz: 'Сактоо')),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      for (final controller in controllers) { controller.dispose(); }
    });
    if (values == null || !mounted) return;
    setState(() => _working = true);
    try {
      final result = await WorkerApi.saveDispatcherPhones(values);
      final raw = result['phones'];
      if (raw is! List || raw.length > 3 || raw.any((value) => value is! String)) {
        throw const FormatException('Сервер вернул неверный список телефонов.');
      }
      if (mounted) setState(() => _dispatcherPhones = raw.map((value) => value.toString()).toList());
      if (mounted) _notice('Телефоны сохранены. Клиенты увидят изменения без переустановки приложения.');
    } catch (error) {
      if (mounted) _notice(error.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _createPhoneOrder() async {
    final phone = TextEditingController(), pickup = TextEditingController();
    final destination = TextEditingController(), comment = TextEditingController();
    String payment = 'Наличные', tariff = 'По городу';
    int people = 1;
    final values = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDialog) => AlertDialog(
        title: const TaxiLocalizedText(russian: 'Заказ по телефону', kyrgyz: 'Телефон аркылуу буйрутма'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: phone, keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Телефон клиента', hintText: '0555123456')),
          const SizedBox(height: 10),
          TextField(controller: pickup, maxLength: 200,
            decoration: const InputDecoration(labelText: 'Откуда забрать', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextField(controller: destination, maxLength: 200,
            decoration: const InputDecoration(labelText: 'Куда отвезти', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(value: tariff, decoration: const InputDecoration(labelText: 'Тариф'),
            items: const [DropdownMenuItem(value: 'По городу', child: Text('По городу')), DropdownMenuItem(value: 'Межгород', child: Text('Межгород'))],
            onChanged: (value) { if (value != null) setDialog(() => tariff = value); }),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(value: payment, decoration: const InputDecoration(labelText: 'Оплата'),
            items: const [DropdownMenuItem(value: 'Наличные', child: Text('Наличные')), DropdownMenuItem(value: 'QR-код', child: Text('QR-код')), DropdownMenuItem(value: 'По договору', child: Text('По договору'))],
            onChanged: (value) { if (value != null) setDialog(() => payment = value); }),
          const SizedBox(height: 10),
          DropdownButtonFormField<int>(value: people, decoration: const InputDecoration(labelText: 'Пассажиров'),
            items: [1, 2, 3, 4].map((value) => DropdownMenuItem(value: value, child: Text('$value'))).toList(),
            onChanged: (value) { if (value != null) setDialog(() => people = value); }),
          const SizedBox(height: 10),
          TextField(controller: comment, maxLength: 500, decoration: const InputDecoration(labelText: 'Комментарий (необязательно)')),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const TaxiLocalizedText(russian: 'Отмена', kyrgyz: 'Жокко чыгаруу')),
          ElevatedButton(onPressed: () {
            if (phone.text.trim().isEmpty || pickup.text.trim().isEmpty || destination.text.trim().isEmpty) return;
            Navigator.pop(ctx, {'phone': phone.text.trim(), 'pickup': pickup.text.trim(),
              'destination': destination.text.trim(), 'payment': payment, 'tariff': tariff,
              'people': people, 'comment': comment.text.trim()});
          }, child: const TaxiLocalizedText(russian: 'Создать заказ', kyrgyz: 'Буйрутма түзүү')),
        ],
      )),
    );
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      phone.dispose(); pickup.dispose(); destination.dispose(); comment.dispose();
    });
    if (values == null || !mounted) return;
    setState(() => _working = true);
    try {
      final result = await WorkerApi.createDispatcherPhoneOrder(
        customerPhone: values['phone'] as String, pickup: values['pickup'] as String,
        destination: values['destination'] as String, payment: values['payment'] as String,
        tariff: values['tariff'] as String, people: values['people'] as int,
        comment: values['comment'] as String,
      );
      final orderId = (result['order_id'] ?? '').toString().trim();
      if (orderId.isEmpty) throw const FormatException('Сервер не вернул номер заказа.');
      await _load(showLoading: false);
      if (mounted) _notice('Заказ создан. Теперь выберите водителя для назначения.');
      if (mounted) await _assign({'id': orderId, 'status': 'new'});
    } catch (error) {
      if (mounted) _notice(error.toString());
      await _load(showLoading: false);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }


  Future<void> _editTariffs() async {
    final cityController = TextEditingController(text: _cityFareSom.toString());
    final intercityController = TextEditingController(text: _intercityFareSom.toString());
    final values = await showDialog<List<int>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const TaxiLocalizedText(russian: 'Фиксированные тарифы', kyrgyz: 'Туруктуу тарифтер'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: cityController, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'По городу · сом', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: intercityController, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Межгород · сом', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          const TaxiLocalizedText(russian: 'Ноль означает, что цена ещё не установлена.', kyrgyz: 'Нөл болсо, баа коюла элек дегенди билдирет.', style: TextStyle(fontSize: 12, color: Colors.black54)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const TaxiLocalizedText(russian: 'Отмена', kyrgyz: 'Жокко чыгаруу')),
          ElevatedButton(onPressed: () {
            final city = int.tryParse(cityController.text.trim());
            final intercity = int.tryParse(intercityController.text.trim());
            if (city == null || intercity == null || city < 0 || intercity < 0) return;
            Navigator.pop(ctx, [city, intercity]);
          }, child: const TaxiLocalizedText(russian: 'СОХРАНИТЬ', kyrgyz: 'САКТОО')),
        ],
      ),
    );
    // Освобождаем контроллеры после завершения анимации закрытия диалога.
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      cityController.dispose();
      intercityController.dispose();
    });
    if (values == null || !mounted) return;
    setState(() => _working = true);
    try {
      await WorkerApi.saveTariffs(cityFareSom: values[0], intercityFareSom: values[1]);
      // Обновляем тарифы и сводку без полной замены дерева панели.
      await _load(showLoading: false);
      if (mounted) _notice('Тарифы сохранены. Клиенты увидят новые цены.');
    } catch (e) {
      if (mounted) _notice(e.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _completeTrip(Map<String, dynamic> order) async {
    final id = (order['id'] ?? '').toString();
    if (id.isEmpty) return;
    final isIntercity = (order['tariff_type'] ?? '').toString().toLowerCase().contains('меж');
    final suggestedFare = isIntercity ? _intercityFareSom : _cityFareSom;
    final fareController = TextEditingController(text: suggestedFare > 0 ? suggestedFare.toString() : '');
    final fare = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const TaxiLocalizedText(russian: 'Завершить поездку', kyrgyz: 'Жол жүрүүнү аяктоо'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TaxiText('Заказ №$id'),
          const SizedBox(height: 10),
          TextField(controller: fareController, autofocus: true, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Стоимость поездки (сом)', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          const TaxiLocalizedText(russian: 'Подставлена цена из тарифа. При необходимости диспетчер может изменить сумму перед закрытием.', kyrgyz: 'Тарифтеги баа коюлду. Зарыл болсо, диспетчер жабуудан мурун сумманы өзгөртө алат.', style: TextStyle(fontSize: 12, color: Colors.black54)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const TaxiText('Назад')),
          ElevatedButton(onPressed: () {
            final value = int.tryParse(fareController.text.trim());
            if (value == null || value < 1) return;
            Navigator.pop(ctx, value);
          }, child: const TaxiLocalizedText(russian: 'ЗАВЕРШИТЬ', kyrgyz: 'АЯКТОО')),
        ],
      ),
    );
    // Контроллер поля суммы нельзя освобождать до отсоединения закрытого диалога.
    Future<void>.delayed(const Duration(milliseconds: 350), () => fareController.dispose());
    if (fare == null || !mounted) return;
    setState(() => _working = true);
    try {
      await WorkerApi.completeOrder(orderId: id, fareSom: fare);
      await _load();
      if (mounted) _notice('Поездка завершена. В заработок водителя записано $fare сом.');
    } catch (e) {
      if (mounted) _notice(e.toString());
      await _load();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _storageObjectPath(dynamic raw) {
    final value = (raw ?? '').toString();
    if (value.startsWith('drivers/')) return value;
    // Backward compatibility with Stage 12 records that stored Firebase download URLs.
    final uri = Uri.tryParse(value);
    if (uri == null) return '';
    final marker = '/o/';
    final index = uri.path.indexOf(marker);
    if (index < 0) return '';
    return Uri.decodeComponent(uri.path.substring(index + marker.length));
  }

  Future<void> _showDriverDocument(String label, dynamic rawPath, {String? driverUid, String? documentType}) async {
    final path = _storageObjectPath(rawPath);
    File? localFile;
    if (driverUid != null && documentType != null) {
      localFile = await DriverDocumentStore.find(uid: driverUid, documentType: documentType);
    }
    if (!mounted) return;
    if (localFile == null && path.isEmpty) { _notice('Документ ещё не получен. Запросите фотографии у водителя.'); return; }
    await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
      title: TaxiText(label),
      content: SizedBox(width: 420, child: localFile != null
        ? InteractiveViewer(child: Image.file(localFile, fit: BoxFit.contain))
        : FutureBuilder<Uint8List?>(
            future: taxiFirebaseStorage.ref(path).getData(8 * 1024 * 1024),
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) return const SizedBox(height: 180, child: Center(child: CircularProgressIndicator()));
              if (snapshot.hasError || snapshot.data == null) return const TaxiText('Не удалось загрузить документ. Проверьте правила Firebase Storage и подключение.');
              return InteractiveViewer(child: Image.memory(snapshot.data!, fit: BoxFit.contain));
            },
          )),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const TaxiLocalizedText(russian: 'Закрыть', kyrgyz: 'Жабуу'))],
    ));
  }

  Widget _documentLink(String label, dynamic value, {String? driverUid, String? documentType}) {
    final path = _storageObjectPath(value);
    final canOpen = path.isNotEmpty || (driverUid != null && documentType != null);
    return TextButton.icon(
      onPressed: canOpen ? () => _showDriverDocument(label, value, driverUid: driverUid, documentType: documentType) : null,
      icon: const Icon(Icons.image_search, size: 16),
      label: TaxiText(canOpen ? label : '$label · нет'),
    );
  }

  Future<void> _forceDriverOffline(Map<String,dynamic> driver) async {
    final uid=(driver['uid']??driver['driver_uid']??'').toString();
    final name=(driver['name']??driver['driver_name']??'Водитель').toString();
    final online=driver['online']==true||driver['online']==1||driver['online'].toString()=='1';
    if(uid.isEmpty||!online)return;
    final confirm=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:const TaxiText('Снять водителя с линии?'),
      content:TaxiText('$name будет исключён из новых заказов. Уже назначенный заказ останется у него и не будет отменён.'),
      actions:[
        TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const TaxiLocalizedText(russian:'Отмена',kyrgyz:'Жокко чыгаруу')),
        ElevatedButton(onPressed:()=>Navigator.pop(ctx,true),child:const TaxiLocalizedText(russian:'Снять с линии',kyrgyz:'Линиядан алуу')),
      ],
    ));
    if(confirm!=true||!mounted)return;
    setState(()=>_working=true);
    try{
      final result=await WorkerApi.forceDriverOffline(driverUid:uid);
      await _load(showLoading:false);
      if(mounted)_notice(result['active_order_preserved']==true?'Водитель снят с линии. Назначенный заказ сохранён.':'Водитель снят с линии.');
    }catch(error){if(mounted)_notice(error.toString());}
    finally{if(mounted)setState(()=>_working=false);}
  }

  Future<void> _editDriverCommission(Map<String, dynamic> driver) async {
    final uid = (driver['driver_uid'] ?? '').toString();
    if (uid.isEmpty) return;
    final current = (driver['commission_percent'] as num?)?.toInt() ?? 0;
    final controller = TextEditingController(text: current.toString());
    final percent = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: TaxiText('Процент водителя · ${driver['driver_name'] ?? 'Водитель'}'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Доля водителя, %',
            helperText: 'Например, 20 означает: 20% водителю и 80% таксопарку.',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const TaxiLocalizedText(russian: 'Отмена', kyrgyz: 'Жокко чыгаруу')),
          ElevatedButton(onPressed: () {
            final value = int.tryParse(controller.text.trim());
            if (value == null || value < 0 || value > 100) return;
            Navigator.pop(ctx, value);
          }, child: const TaxiLocalizedText(russian: 'Сохранить', kyrgyz: 'Сактоо')),
        ],
      ),
    );
    // Не освобождаем TextField-контроллер до завершения анимации закрытия.
    Future<void>.delayed(const Duration(milliseconds: 350), () => controller.dispose());
    if (percent == null || !mounted) return;
    setState(() => _working = true);
    try {
      await WorkerApi.setDriverCommission(driverUid: uid, commissionPercent: percent);
      await _load(showLoading: false);
      if (mounted) _notice('Установлено: $percent% водителю, ${100 - percent}% таксопарку.');
    } catch (e) {
      if (mounted) _notice(e.toString());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _closeDriverShift(Map<String, dynamic> driver) async {
    final uid = (driver['driver_uid'] ?? '').toString();
    final name = (driver['driver_name'] ?? 'Водитель').toString();
    final earned = (driver['earned_som'] as num?)?.toInt() ?? 0;
    if (uid.isEmpty || earned <= 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const TaxiText('Закрыть смену водителя?'),
        content: TaxiText('Водитель: $name\\nЗаработок за день: $earned сом\nПроцент водителя: ${driver['commission_percent'] ?? 'не установлен'}%\n\nПосле закрытия сумма и процент сохранятся в истории. Повторно закрыть эту смену будет нельзя.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const TaxiLocalizedText(russian: 'Отмена', kyrgyz: 'Жокко чыгаруу')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const TaxiLocalizedText(russian: 'Закрыть смену', kyrgyz: 'Сменаны жабуу')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _working = true);
    try {
      final result = await WorkerApi.closeDriverShift(driverUid: uid);
      final shift = Map<String, dynamic>.from(result['shift'] as Map? ?? {});
      await _load(showLoading: false);
      if (mounted) {
        _notice('Смена закрыта. Водителю: ${shift['driver_share_som'] ?? 0} сом; таксопарку: ${shift['park_share_som'] ?? 0} сом.');
      }
    } catch (e) {
      if (mounted) _notice(e.toString());
      await _load(showLoading: false);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  int _sumField(List<Map<String, dynamic>> rows, String field) =>
      rows.fold<int>(0, (sum, row) => sum + ((row[field] as num?)?.toInt() ?? 0));

  void _notice(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: TaxiText(message)));
  }

  int _sumToday() => _today.fold<int>(0, (sum, row) => sum + ((row['count'] as num?)?.toInt() ?? 0));

  Widget _sectionTitle(String value, IconData icon) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Colors.brown),
        const SizedBox(width: 8),
        Expanded(
          child: TaxiLocalizedText(
            russian: value,
            kyrgyz: TaxiLanguage.translate(value),
            softWrap: true,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final pending = _drivers.where((d) => (d['review_status'] ?? 'pending').toString() == 'pending' && !(d['approved'] == true || d['approved'] == 1 || d['approved'].toString() == '1')).toList();
    final rejected = _drivers.where((d) => d['review_status'] == 'rejected').toList();
    final activeOrders = _orders.where((o) => o['status'] == 'new').toList();
    final closedToday = _closedShifts.where((row) => row['shift_date'] == _businessDate).toList();
    final todayGross = _sumField(_earnings, 'earned_som') + _sumField(closedToday, 'gross_earnings_som');
    final todayDriverShare = _sumField(_earnings, 'driver_share_som') + _sumField(closedToday, 'driver_share_som');
    final todayParkShare = _sumField(_earnings, 'park_share_som') + _sumField(closedToday, 'park_share_som');
    return Scaffold(
      backgroundColor: const Color(0xFFF6F2E9),
      appBar: AppBar(
        title: const TaxiText(
          'Диспетчер · ЖОЛ АМАН КЕНЧИ',
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: const Color(0xFF087A42),
        foregroundColor: Colors.white,
        actions: [
          const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: TaxiLanguageSwitcher()),
          IconButton(onPressed: _working ? null : _load, icon: const Icon(Icons.refresh), tooltip: 'Обновить'),
          IconButton(
            tooltip: 'Выйти из кабинета диспетчера',
            onPressed: _working ? null : _logoutDispatcher,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(
              mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.lock_outline, size: 48), const SizedBox(height: 12),
                const TaxiLocalizedText(russian: 'Не удалось открыть диспетчерскую панель', kyrgyz: 'Диспетчер панелин ачуу мүмкүн болгон жок', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                const SizedBox(height: 8), TaxiText(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 12), const TaxiLocalizedText(russian: 'Для доступа требуется вход в Firebase под учётной записью диспетчера. Старый локальный ПИН-код не заменяет серверную авторизацию.', kyrgyz: 'Кирүү үчүн диспетчердин Firebase аккаунту менен авторизациядан өтүү керек. Эски PIN-код сервердик авторизацияны алмаштырбайт.', textAlign: TextAlign.center),
                const SizedBox(height: 12), ElevatedButton(onPressed: _load, child: const TaxiLocalizedText(russian: 'Повторить', kyrgyz: 'Кайталоо')),
              ])))
          : RefreshIndicator(onRefresh: _load, child: ListView(
              padding: const EdgeInsets.all(16), children: [
                if (_dispatcherRefreshError != null)
                  Card(color: Colors.orange.shade100, child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(children: [
                      const Icon(Icons.wifi_off, size: 18),
                      const SizedBox(width: 8),
                      const Expanded(child: TaxiLocalizedText(russian: 'Нет связи с сервером. Показаны последние загруженные данные; повторное обновление будет выполнено автоматически.', kyrgyz: 'Сервер менен байланыш жок. Акыркы жүктөлгөн маалымат көрсөтүлдү; кайра жаңылоо автоматтык түрдө аткарылат.', style: TextStyle(fontSize: 12))),
                      IconButton(tooltip: 'Скрыть сообщение', onPressed: () => setState(() => _dispatcherRefreshError = null), icon: const Icon(Icons.close, size: 18)),
                    ]),
                  )),
                Card(color: Colors.amber.shade100, child: Padding(
                  padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const TaxiLocalizedText(russian: 'Сводка за сегодня', kyrgyz: 'Бүгүнкү жыйынтык', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                    const SizedBox(height: 8),
                    TaxiText('Всего заказов: ${_sumToday()}'),
                    TaxiText('Ожидают назначения: ${activeOrders.length}'),
                    TaxiText('Водителей в базе: ${_drivers.length}'),
                  ]))),
                const WalkieTalkieWidget(senderName: 'Диспетчер', allowText: true),
                _sectionTitle('Карта водителей на линии', Icons.map_outlined),
                _dispatcherDriverMap(),
                _sectionTitle('Тарифы для клиентов', Icons.price_change),
                Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                    TaxiText('По городу: ${_cityFareSom > 0 ? '$_cityFareSom сом' : 'не установлено'}'),
                    TaxiText('Межгород: ${_intercityFareSom > 0 ? '$_intercityFareSom сом' : 'не установлено'}'),
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: ElevatedButton.icon(
                      onPressed: _working ? null : _editTariffs,
                      icon: const Icon(Icons.edit), label: const TaxiLocalizedText(russian: 'ИЗМЕНИТЬ ТАРИФЫ', kyrgyz: 'ТАРИФТЕРДИ ӨЗГӨРТҮҮ'))),
                  ]))),
                _sectionTitle('Телефоны диспетчера для клиентов', Icons.phone),
                Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (_dispatcherPhones.isEmpty)
                      const TaxiLocalizedText(russian: 'Номера ещё не добавлены.', kyrgyz: 'Номерлер азырынча кошулган жок.')
                    else ..._dispatcherPhones.map((phone) => TaxiText(phone, style: const TextStyle(fontWeight: FontWeight.w700))),
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: OutlinedButton.icon(
                      onPressed: _working ? null : _editDispatcherPhones, icon: const Icon(Icons.edit),
                      label: const TaxiLocalizedText(russian: 'ИЗМЕНИТЬ ТЕЛЕФОНЫ', kyrgyz: 'ТЕЛЕФОНДОРДУ ӨЗГӨРТҮҮ'))),
                  ]))),
                _sectionTitle('Заказ от клиента по телефону', Icons.add_call),
                Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const TaxiLocalizedText(russian: 'Создайте заявку за клиента, который позвонил диспетчеру и не пользуется приложением.',
                      kyrgyz: 'Тиркемени колдонбогон кардар диспетчерге чалса, анын атынан буйрутма түзүңүз.'),
                    const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: ElevatedButton.icon(
                      onPressed: _working ? null : _createPhoneOrder, icon: const Icon(Icons.add_call),
                      label: const TaxiLocalizedText(russian: 'СОЗДАТЬ ЗАКАЗ ПО ТЕЛЕФОНУ', kyrgyz: 'ТЕЛЕФОН АРКЫЛУУ БУЙРУТМА ТҮЗҮҮ'))),
                  ]))),

                _sectionTitle('Заявки водителей · ожидают решения', Icons.verified_user),
                if (pending.isEmpty) const TaxiLocalizedText(russian: 'Нет новых заявок водителей.', kyrgyz: 'Жаңы айдоочу арыздары жок.'),
                ...pending.map((d) => Card(child: Padding(
                  padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    TaxiText((d['name'] ?? 'Водитель').toString(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    TaxiText('${d['phone'] ?? ''} · ${d['car_model'] ?? ''} · ${d['car_number'] ?? ''}'),
                    TaxiText('UID: ${d['uid'] ?? ''}', style: const TextStyle(fontSize: 11, color: Colors.black54)),
                    Wrap(spacing: 8, children: [
                      _documentLink('Удостоверение', d['license_url'], driverUid: (d['uid'] ?? '').toString(), documentType: 'license'),
                      _documentLink('Фото водителя', d['driver_photo_url'], driverUid: (d['uid'] ?? '').toString(), documentType: 'driver_photo'),
                      _documentLink('Фото авто', d['car_photo_url'], driverUid: (d['uid'] ?? '').toString(), documentType: 'car_photo'),
                    ]),
                    if ((d['local_transfer_request_id'] ?? '').toString().isEmpty &&
                        ((d['license_url'] ?? '').toString().isEmpty ||
                         (d['driver_photo_url'] ?? '').toString().isEmpty ||
                         (d['car_photo_url'] ?? '').toString().isEmpty))
                      const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: TaxiLocalizedText(russian: 'Не все документы загружены. Проверьте заявку перед одобрением.', kyrgyz: 'Бардык документтер жүктөлгөн эмес. Бекитүүдөн мурун арызды текшериңиз.',
                          style: TextStyle(color: Colors.deepOrange, fontSize: 12)),
                      ),
                    if (_documentTransferStates[(d['uid'] ?? '').toString()] != null)
                      Padding(padding: const EdgeInsets.only(top: 6), child: TaxiText(_documentTransferStates[(d['uid'] ?? '').toString()]!, style: const TextStyle(fontSize: 12, color: Colors.blueGrey))),
                    SizedBox(width: double.infinity, child: OutlinedButton.icon(
                      onPressed: _working || _documentTransferSessions.containsKey((d['uid'] ?? '').toString()) ? null : () => _requestDriverDocuments(d),
                      icon: const Icon(Icons.download_for_offline),
                      label: const TaxiLocalizedText(russian: 'ЗАПРОСИТЬ ДОКУМЕНТЫ С ТЕЛЕФОНА', kyrgyz: 'ТЕЛЕФОНДОН ДОКУМЕНТТЕРДИ СУРОО'),
                    )),
                    Row(children: [
                      Expanded(child: OutlinedButton.icon(onPressed: _working ? null : () => _review(d, 'rejected'), icon: const Icon(Icons.close, color: Colors.red), label: const TaxiLocalizedText(russian: 'Отклонить', kyrgyz: 'Четке кагуу'))),
                      const SizedBox(width: 8),
                      Expanded(child: ElevatedButton.icon(onPressed: _working ? null : () => _review(d, 'approved'), icon: const Icon(Icons.verified), label: const TaxiLocalizedText(russian: 'Одобрить', kyrgyz: 'Бекитүү'))),
                    ]),
                  ]),
                ))),
                _sectionTitle('Отклонённые заявки · ждут повторной подачи', Icons.assignment_late_outlined),
                if (rejected.isEmpty) const TaxiLocalizedText(russian: 'Отклонённых заявок нет.', kyrgyz: 'Четке кагылган арыздар жок.'),
                ...rejected.map((d) => Card(child: Padding(
                  padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    TaxiText((d['name'] ?? 'Водитель').toString(), style: const TextStyle(fontWeight: FontWeight.bold)),
                    TaxiText('Причина: ${d['rejection_reason'] ?? 'Не указана'}'),
                    Wrap(spacing: 8, children: [
                      _documentLink('Удостоверение', d['license_url'], driverUid: (d['uid'] ?? '').toString(), documentType: 'license'),
                      _documentLink('Фото водителя', d['driver_photo_url'], driverUid: (d['uid'] ?? '').toString(), documentType: 'driver_photo'),
                      _documentLink('Фото авто', d['car_photo_url'], driverUid: (d['uid'] ?? '').toString(), documentType: 'car_photo'),
                    ]),
                    if (_documentTransferStates[(d['uid'] ?? '').toString()] != null)
                      Padding(padding: const EdgeInsets.only(top: 6), child: TaxiText(_documentTransferStates[(d['uid'] ?? '').toString()]!)),
                    SizedBox(width: double.infinity, child: OutlinedButton.icon(
                      onPressed: _working || _documentTransferSessions.containsKey((d['uid'] ?? '').toString()) ? null : () => _requestDriverDocuments(d),
                      icon: const Icon(Icons.download_for_offline),
                      label: const TaxiLocalizedText(russian: 'ЗАПРОСИТЬ ДОКУМЕНТЫ С ТЕЛЕФОНА', kyrgyz: 'ТЕЛЕФОНДОН ДОКУМЕНТТЕРДИ СУРОО'),
                    )),
                  ]),
                ))),
                _sectionTitle('Все водители', Icons.directions_car),
                if (_drivers.isEmpty) const TaxiLocalizedText(russian: 'В базе пока нет водителей.', kyrgyz: 'Базада азырынча айдоочулар жок.'),
                ..._drivers.map((d) {
                  final approved = d['approved'] == true || d['approved'] == 1 || d['approved'].toString() == '1';
                  final online = d['online'] == true || d['online'] == 1 || d['online'].toString() == '1';
                  final reviewStatus = (d['review_status'] ?? 'not_submitted').toString();
                  final approvalLabel = approved
                      ? 'Допущен'
                      : reviewStatus == 'approved'
                          ? 'Документы одобрены · допуск отключён'
                          : reviewStatus == 'pending'
                              ? 'Ожидает проверки документов'
                              : reviewStatus == 'rejected'
                                  ? 'Заявка отклонена'
                                  : 'Не одобрен · документы не отправлены';
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.local_taxi, color: online ? Colors.green : Colors.grey),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    TaxiText((d['name'] ?? 'Водитель').toString(),
                                      style: const TextStyle(fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 3),
                                    TaxiText('${d['car_model'] ?? ''} · ${d['car_number'] ?? ''}'),
                                    TaxiText('$approvalLabel · ${online ? 'На линии' : 'Не на линии'}'),
                                    TaxiText('Проверка документов: $reviewStatus',
                                      style: const TextStyle(fontSize: 12, color: Colors.black54)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            alignment: WrapAlignment.end,
                            children: [
                              if (online)
                                OutlinedButton.icon(
                                  onPressed: _working ? null : () => _forceDriverOffline(d),
                                  icon: const Icon(Icons.power_settings_new, size: 17),
                                  label: const Text('СНЯТЬ С ЛИНИИ'),
                                ),
                              if (approved)
                                OutlinedButton.icon(
                                  onPressed: _working ? null : () => _approve(d, false),
                                  icon: const Icon(Icons.block, color: Colors.red),
                                  label: const Text('ОТКЛЮЧИТЬ ДОПУСК'),
                                )
                              else if (reviewStatus == 'approved')
                                ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  ),
                                  onPressed: _working ? null : () => _approve(d, true),
                                  icon: const Icon(Icons.check_circle, size: 18),
                                  label: const Text('ВОССТАНОВИТЬ ДОПУСК'),
                                )
                              else
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      reviewStatus == 'pending' ? Icons.hourglass_empty : Icons.warning_amber_rounded,
                                      color: reviewStatus == 'pending' ? Colors.orange : Colors.redAccent,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(reviewStatus == 'pending' ? 'Ожидает проверки' : 'Нет допуска'),
                                  ],
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                _sectionTitle('Открытые заказы', Icons.receipt_long),
                if (activeOrders.isEmpty) const TaxiLocalizedText(russian: 'Нет заказов, ожидающих назначения.', kyrgyz: 'Дайындоону күтүп жаткан буйрутмалар жок.'),
                ...activeOrders.map((o) => Card(child: Padding(
                  padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    TaxiText('Заказ №${o['id'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    TaxiText('Откуда: ${o['pickup_address'] ?? 'Точка на карте'}'),
                    TaxiText('Куда: ${o['destination_address'] ?? 'Не указано'}'),
                    TaxiText('Пассажиров: ${o['passenger_count'] ?? 1} · Оплата: ${o['payment_method'] ?? '—'}'),
                    TaxiText('Тариф: ${o['tariff_type'] ?? '—'}'),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _working ? null : () => _removeOpenOrder(o),
                          icon: const Icon(Icons.archive_outlined),
                          label: const TaxiLocalizedText(russian: 'Убрать из списка', kyrgyz: 'Тизмеден алып салуу'),
                        ),
                        ElevatedButton.icon(
                          onPressed: _working ? null : () => _assign(o),
                          icon: const Icon(Icons.person_add_alt_1),
                          label: const TaxiLocalizedText(russian: 'Назначить водителя', kyrgyz: 'Айдоочуну дайындоо'),
                        ),
                      ],
                    ),
                  ])))),
                _sectionTitle('Финансовый итог за сегодня · $_businessDate', Icons.account_balance_wallet_outlined),
                Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                    TaxiText('Общий заработок: $todayGross сом', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                    const SizedBox(height: 5),
                    TaxiText('Водителям: $todayDriverShare сом'),
                    TaxiText('Таксопарку: $todayParkShare сом'),
                    const SizedBox(height: 5),
                    const TaxiText('Итог включает ещё не закрытые поездки и уже закрытые смены за местный день Кыргызстана (UTC+6).', style: TextStyle(fontSize: 11, color: Colors.black54)),
                  ],
                ))),
                _sectionTitle('Заработок водителей за сегодня', Icons.account_balance_wallet_outlined),
                if (_earnings.isEmpty) const TaxiLocalizedText(russian: 'В базе пока нет водителей.', kyrgyz: 'Базада азырынча айдоочулар жок.'),
                ..._earnings.map((row) {
                  final earned = (row['earned_som'] as num?)?.toInt() ?? 0;
                  final trips = (row['completed_trips'] as num?)?.toInt() ?? 0;
                  final percent = (row['commission_percent'] as num?)?.toInt();
                  final driverShare = (row['driver_share_som'] as num?)?.toInt() ?? 0;
                  final parkShare = (row['park_share_som'] as num?)?.toInt() ?? 0;
                  return Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start, children: [
                      TaxiText((row['driver_name'] ?? 'Водитель').toString(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      TaxiText('Авто: ${row['car_number'] ?? '—'} · Поездок: $trips'),
                      TaxiText('Общий заработок: $earned сом'),
                      TaxiText(percent == null
                        ? 'Доля водителя: не установлена'
                        : 'Доля водителя: $percent% · $driverShare сом'),
                      TaxiText(percent == null
                        ? 'Доля таксопарка: не рассчитана'
                        : 'Доля таксопарка: ${100 - percent}% · $parkShare сом'),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        OutlinedButton.icon(
                          onPressed: _working ? null : () => _editDriverCommission(row),
                          icon: const Icon(Icons.percent), label: const TaxiLocalizedText(russian: 'Изменить процент', kyrgyz: 'Пайызды өзгөртүү')),
                        if (earned > 0) ElevatedButton.icon(
                          onPressed: _working ? null : () => _closeDriverShift(row),
                          icon: const Icon(Icons.lock_clock), label: const TaxiLocalizedText(russian: 'Закрыть смену', kyrgyz: 'Сменаны жабуу')),
                      ]),
                    ],
                  )));
                }),
                _sectionTitle('История закрытых смен', Icons.history),
                if (_closedShifts.isEmpty) const TaxiLocalizedText(russian: 'Закрытых смен пока нет.', kyrgyz: 'Азырынча жабылган сменалар жок.'),
                ..._closedShifts.take(15).map((row) => Card(child: ListTile(
                  leading: const Icon(Icons.verified, color: Colors.green),
                  title: TaxiText((row['driver_name'] ?? 'Водитель').toString()),
                  subtitle: TaxiText('Дата: ${row['shift_date']} · Поездок: ${row['trip_count']} · Процент водителя: ${row['driver_percent']}%'),
                  trailing: SizedBox(
                    width: 116,
                    child: TaxiText(
                      '${row['gross_earnings_som']} сом\nВодителю: ${row['driver_share_som']} сом',
                      maxLines: 2,
                      softWrap: true,
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ))),
                _sectionTitle('Статусы заказов за сегодня', Icons.analytics_outlined),
                ..._today.map((row) => ListTile(dense: true, title: TaxiText((row['status'] ?? '—').toString()), trailing: TaxiText('${row['count'] ?? 0}'))),
                const SizedBox(height: 20),
                const TaxiText('Сумма поездки записывается при её завершении. При закрытии смены процент фиксируется в истории: указанная доля принадлежит водителю, остаток — таксопарку.', style: TextStyle(color: Colors.black54)),
              ],
            )),
      floatingActionButton: _working ? const FloatingActionButton(onPressed: null, child: CircularProgressIndicator()) : null,
    );
  }
}
