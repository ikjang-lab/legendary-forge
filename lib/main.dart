import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const ForgeApp());
}

class ForgeApp extends StatelessWidget {
  const ForgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '대장간 자동강화',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFB8860B),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: _isDesktop() ? const DesktopControlScreen() : const SetupScreen(),
    );
  }

  bool _isDesktop() =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows;
}

// ══════════════════════════════════════════════════════════════════════════════
// Desktop Control Screen (macOS / Windows)
// ══════════════════════════════════════════════════════════════════════════════

class DesktopControlScreen extends StatefulWidget {
  const DesktopControlScreen({super.key});

  @override
  State<DesktopControlScreen> createState() => _DesktopControlScreenState();
}

class _DesktopControlScreenState extends State<DesktopControlScreen> {
  static const _ch = MethodChannel('com.ikjang.legendary_forge/forge');

  bool _isRunning = false;
  bool _accessibilityGranted = true; // Windows는 항상 true
  int _targetLevel = 10;
  int _currentLevel = 0;
  int _currentGold = 0;
  String _statusText = '대기 중';
  Color _statusColor = const Color(0xFFAAAAAA);

  @override
  void initState() {
    super.initState();
    _ch.setMethodCallHandler(_onNativeCall);
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final t = await _ch.invokeMethod<int>('getTargetLevel') ?? 10;
    final running = await _ch.invokeMethod<bool>('getIsRunning') ?? false;

    // macOS는 접근성 권한 확인
    bool axGranted = true;
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      axGranted = await _ch.invokeMethod<bool>('isAccessibilityEnabled') ?? false;
    }

    if (mounted) {
      setState(() {
        _targetLevel = t;
        _isRunning = running;
        _accessibilityGranted = axGranted;
      });
    }
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    if (call.method == 'onStatus') {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      setState(() {
        _statusText   = args['text'] as String? ?? _statusText;
        _statusColor  = _hexColor(args['color'] as String? ?? '#AAAAAA');
        _currentLevel = args['level'] as int? ?? _currentLevel;
        _currentGold  = (args['gold'] as num?)?.toInt() ?? _currentGold;
        if (_statusText.contains('달성') || _statusText.contains('중지')) {
          _isRunning = false;
        }
      });
    }
  }

  Color _hexColor(String hex) {
    final h = hex.replaceFirst('#', '');
    return Color(int.parse('FF$h', radix: 16));
  }

  Future<void> _toggleStartStop() async {
    if (_isRunning) {
      await _ch.invokeMethod('stopAutomation');
      setState(() => _isRunning = false);
    } else {
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        final granted = await _ch.invokeMethod<bool>('isAccessibilityEnabled') ?? false;
        if (!granted) {
          setState(() => _accessibilityGranted = false);
          return;
        }
      }
      await _ch.invokeMethod('startAutomation', {'targetLevel': _targetLevel});
      setState(() => _isRunning = true);
    }
  }

  Future<void> _changeTarget(int delta) async {
    if (_isRunning) return;
    final next = (_targetLevel + delta).clamp(1, 20);
    await _ch.invokeMethod('saveTargetLevel', {'level': next});
    setState(() => _targetLevel = next);
  }

  Future<void> _resetLevel() async {
    if (_isRunning) return;
    await _ch.invokeMethod('setCurrentLevel', {'level': 0});
    setState(() => _currentLevel = 0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Row(
          children: [
            Text('⚔️', style: TextStyle(fontSize: 22)),
            SizedBox(width: 8),
            Text(
              '대장간 자동강화',
              style: TextStyle(
                color: Color(0xFFFFD700),
                fontWeight: FontWeight.bold,
                fontSize: 20,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white54),
            tooltip: '새로고침',
            onPressed: _loadPrefs,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // macOS 접근성 권한 카드
            if (defaultTargetPlatform == TargetPlatform.macOS && !_accessibilityGranted)
              _permissionBanner(),

            if (defaultTargetPlatform == TargetPlatform.macOS && !_accessibilityGranted)
              const SizedBox(height: 16),

            // 상태 카드
            _statusCard(),
            const SizedBox(height: 16),

            // 레벨 카드
            _levelCard(),
            const SizedBox(height: 16),

            // 시작/중지 버튼
            _startStopButton(),
            const SizedBox(height: 16),

            // 사용 안내
            _usageCard(),
          ],
        ),
      ),
    );
  }

  Widget _permissionBanner() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF3A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.redAccent.withAlpha(120)),
      ),
      child: Row(
        children: [
          const Text('⚠️', style: TextStyle(fontSize: 22)),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              '접근성 권한이 필요합니다.\n시스템 설정 → 개인 정보 보호 → 손쉬운 사용에서 이 앱을 허용해주세요.',
              style: TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: () async {
              await _ch.invokeMethod('openAccessibilitySettings');
            },
            child: const Text('설정 열기', style: TextStyle(color: Color(0xFFFFD700))),
          ),
        ],
      ),
    );
  }

  Widget _statusCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1C),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('상태', style: TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 1.2)),
          const SizedBox(height: 8),
          Text(
            _statusText,
            style: TextStyle(color: _statusColor, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          if (_currentGold > 0) ...[
            const SizedBox(height: 6),
            Text(
              '보유 골드: ${_fmtGold(_currentGold)}G',
              style: const TextStyle(color: Color(0xFFFFD700), fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }

  Widget _levelCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1C),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('현재 강화', style: TextStyle(color: Colors.white70)),
              Row(
                children: [
                  Text(
                    '+$_currentLevel',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _resetLevel,
                    child: const Text('(리셋)', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  ),
                ],
              ),
            ],
          ),
          const Divider(color: Color(0xFF333333), height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('목표 강화', style: TextStyle(color: Colors.white70)),
              Row(
                children: [
                  _smallBtn('-', () => _changeTarget(-1)),
                  const SizedBox(width: 8),
                  Text(
                    '+$_targetLevel',
                    style: const TextStyle(
                      color: Color(0xFFFFD700),
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _smallBtn('+', () => _changeTarget(1)),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _startStopButton() {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: _toggleStartStop,
        style: ElevatedButton.styleFrom(
          backgroundColor: _isRunning
              ? const Color(0xFF8B0000)
              : const Color(0xFFB8860B),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Text(
          _isRunning ? '⏹  중지' : '🔨 시작',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _usageCard() {
    final isMac = defaultTargetPlatform == TargetPlatform.macOS;
    final steps = [
      if (isMac) ('1', '시스템 설정 → 손쉬운 사용에서 이 앱을 허용합니다.'),
      ('2', '카카오톡 대장간 채팅방을 열어둡니다.'),
      ('3', '목표 강화 수치를 설정합니다.'),
      ('4', '"🔨 시작" 버튼을 누르면 자동강화 시작!'),
      ('5', '목표 달성 또는 "⏹ 중지" 버튼으로 중단합니다.'),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1C),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('사용 방법', style: TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 1.2)),
          const SizedBox(height: 10),
          ...steps.map((s) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 20, height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFB8860B),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(s.$1, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(s.$2, style: const TextStyle(color: Colors.white70, fontSize: 13))),
              ],
            ),
          )),
        ],
      ),
    );
  }

  Widget _smallBtn(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28, height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF44FFFFFF & 0xFFFFFFFF).withAlpha(60),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.white24),
        ),
        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
      ),
    );
  }

  String _fmtGold(int g) {
    if (g >= 1000000) return '${(g / 1000000).toStringAsFixed(1)}M';
    return g.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Android Setup Screen (기존 코드 유지)
// ══════════════════════════════════════════════════════════════════════════════

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> with WidgetsBindingObserver {
  static const _ch = MethodChannel('com.ikjang.legendary_forge/forge');

  bool _accessibilityEnabled = false;
  bool _overlayGranted = false;
  int _targetLevel = 10;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadState();
  }

  Future<void> _loadState() async {
    final a = await _ch.invokeMethod<bool>('isAccessibilityEnabled') ?? false;
    final o = await _ch.invokeMethod<bool>('isOverlayPermissionGranted') ?? false;
    final t = await _ch.invokeMethod<int>('getTargetLevel') ?? 10;
    if (mounted) setState(() { _accessibilityEnabled = a; _overlayGranted = o; _targetLevel = t; });
  }

  Future<void> _saveTarget(int level) async {
    await _ch.invokeMethod('saveTargetLevel', {'level': level});
    setState(() => _targetLevel = level);
  }

  @override
  Widget build(BuildContext context) {
    final allGranted = _accessibilityEnabled && _overlayGranted;

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Row(
          children: [
            Text('⚔️', style: TextStyle(fontSize: 22)),
            SizedBox(width: 8),
            Text(
              '대장간 자동강화',
              style: TextStyle(
                color: Color(0xFFFFD700),
                fontWeight: FontWeight.bold,
                fontSize: 20,
              ),
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: allGranted ? const Color(0xFF1A3A1A) : const Color(0xFF3A2A00),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: allGranted
                      ? Colors.greenAccent.withAlpha(100)
                      : Colors.orangeAccent.withAlpha(100),
                ),
              ),
              child: Row(
                children: [
                  Text(allGranted ? '✅' : '⚠️', style: const TextStyle(fontSize: 24)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      allGranted
                          ? '모든 권한이 허용됐습니다.\n카카오톡 채팅방을 열면 오버레이가 자동으로 나타납니다.'
                          : '아래 권한을 모두 허용해야 자동강화가 작동합니다.',
                      style: TextStyle(
                        color: allGranted ? Colors.greenAccent : Colors.orangeAccent,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _sectionTitle('권한 설정'),
            const SizedBox(height: 10),
            _permissionCard(
              icon: '♿', title: '접근성 서비스',
              desc: '카카오톡 화면을 읽고 텍스트를 자동 입력합니다.',
              granted: _accessibilityEnabled,
              onTap: () async { await _ch.invokeMethod('openAccessibilitySettings'); },
            ),
            const SizedBox(height: 10),
            _permissionCard(
              icon: '🪟', title: '다른 앱 위에 표시',
              desc: '카카오톡 위에 제어 패널을 오버레이로 띄웁니다.',
              granted: _overlayGranted,
              onTap: () async { await _ch.invokeMethod('requestOverlayPermission'); },
            ),
            const SizedBox(height: 24),
            _sectionTitle('기본 목표 강화 설정'),
            const SizedBox(height: 4),
            const Text('오버레이의 +/- 버튼으로도 변경 가능합니다.',
                style: TextStyle(color: Colors.white38, fontSize: 12)),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF1C1C1C),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF333333)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('목표 강화', style: TextStyle(color: Colors.white70)),
                      Text('+$_targetLevel',
                          style: const TextStyle(color: Color(0xFFFFD700), fontSize: 22, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      activeTrackColor: const Color(0xFFFFD700),
                      inactiveTrackColor: const Color(0xFF3A3A3A),
                      thumbColor: const Color(0xFFFFD700),
                    ),
                    child: Slider(
                      value: _targetLevel.toDouble(), min: 1, max: 20, divisions: 19,
                      label: '+$_targetLevel',
                      onChanged: (v) => _saveTarget(v.round()),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            _sectionTitle('사용 방법'),
            const SizedBox(height: 10),
            _howToCard(),
            const SizedBox(height: 20),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _loadState,
        backgroundColor: const Color(0xFFB8860B),
        child: const Icon(Icons.refresh, color: Colors.white),
      ),
    );
  }

  Widget _sectionTitle(String text) => Text(text,
      style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 1.2));

  Widget _permissionCard({
    required String icon, required String title,
    required String desc, required bool granted, required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1C),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: granted ? Colors.greenAccent.withAlpha(80) : const Color(0xFF333333)),
      ),
      child: ListTile(
        leading: Text(icon, style: const TextStyle(fontSize: 26)),
        title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        subtitle: Text(desc, style: const TextStyle(color: Colors.white38, fontSize: 12)),
        trailing: granted
            ? const Chip(label: Text('허용됨', style: TextStyle(fontSize: 11)),
                backgroundColor: Color(0xFF1A3A1A), labelStyle: TextStyle(color: Colors.greenAccent))
            : ElevatedButton(
                onPressed: onTap,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFB8860B), foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  textStyle: const TextStyle(fontSize: 12),
                ),
                child: const Text('허용'),
              ),
      ),
    );
  }

  Widget _howToCard() {
    const steps = [
      ('1', '이 앱에서 두 가지 권한을 모두 허용합니다.'),
      ('2', '카카오톡에서 대장간 채팅방으로 이동합니다.'),
      ('3', '화면 오른쪽에 자동강화 패널이 나타납니다.'),
      ('4', '패널에서 목표 강화 수치(+/-)를 설정합니다.'),
      ('5', '"🔨 시작" 버튼을 누르면 자동으로 강화 시작!'),
      ('6', '목표 달성 또는 "⏹ 중지" 버튼으로 중단합니다.'),
    ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1C),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: Column(
        children: steps.map((s) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 22, height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: const Color(0xFFB8860B), borderRadius: BorderRadius.circular(11)),
                child: Text(s.$1, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(s.$2, style: const TextStyle(color: Colors.white70, fontSize: 13))),
            ],
          ),
        )).toList(),
      ),
    );
  }
}
