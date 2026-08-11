import 'dart:async';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../src/utils/ppg_algorithm.dart';
import '../src/services/user_service.dart';

enum ScanState { initializing, idle, scanning, processing, success, error }

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen>
    with TickerProviderStateMixin {
  // ── Camera / PPG ──────────────────────────────────────────────────────────
  CameraController? _cameraController;
  ScanState _scanState = ScanState.initializing;
  final List<double> _redValues = [];
  bool _isProcessingFrame = false;
  int _fingerDetectedFrames = 0;
  static const double _fingerRedThreshold = 140.0;
  static const int _requiredFingerFrames = 10;
  DateTime? _scanStartTime;
  Timer? _scanTimer;
  final int _scanDurationSeconds = 15;
  double _progress = 0.0;
  double _finalBpm = 0.0;
  bool _hasTorch = true;
  bool _isFirstScan = false;
  bool _showTutorial = false;
  String _errorTitle = 'Camera unavailable';
  String _errorBody = 'Please allow camera access in Settings\nand try again.';

  // ── Animations ────────────────────────────────────────────────────────────
  late AnimationController _pulseController;
  late AnimationController _spinController;
  late Animation<double> _pulseAnimation;
  final PageController _tutorialPageController = PageController();
  int _tutorialPageIndex = 0;
  bool _dismissedFirstScanTutorial = false;

  static const Color accentPurple = Color(0xFF7B6EF6);
  static const Color bgColor     = Color(0xFFF2F2F7);
  static const Color cardWhite   = Colors.white;
  static const Color textDark    = Color(0xFF1C1C1E);
  static const Color textGrey    = Color(0xFF8E8E93);
  static const Color greenColor  = Color(0xFF34C759);
  static const Color redColor    = Color(0xFFFF3B30);

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _pulseAnimation = Tween<double>(begin: 0.88, end: 1.12).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _checkFirstScanStatus();
    _initCamera();
  }

  Future<void> _checkFirstScanStatus() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('[PPG] First scan check skipped: no signed-in user');
        return;
      }

      final previousScans = await FirebaseFirestore.instance
          .collection('heart_rate_scans')
          .where('userId', isEqualTo: user.uid)
          .limit(1)
          .get();

      final isFirstScan = previousScans.docs.isEmpty;
      /* TODO: Remove after testing.
      final isFirstScan = true;
      final isFirstScan = previousScans.docs.isEmpty; */
      debugPrint('[PPG] isFirstScan=$isFirstScan');

      if (!mounted) return;
      setState(() {
        _isFirstScan = isFirstScan;
        _showTutorial = isFirstScan;
        _dismissedFirstScanTutorial = !isFirstScan;
      });
    } catch (e) {
      debugPrint('[PPG] Failed to check first scan status: $e');
    }
  }

  Future<void> _dismissScannerTutorial() async {
    try {
      await UserService.setScannerTutorialSeen(true);
    } catch (e) {
      debugPrint('[Tutorial] Failed to save scannerTutorialSeen: $e');
    }

    if (!mounted) return;
    setState(() {
      _showTutorial = false;
      _dismissedFirstScanTutorial = true;
      _isFirstScan = false;
      _fingerDetectedFrames = 0;
    });
  }

  // ── Camera init ───────────────────────────────────────────────────────────

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final backCameras = cameras
          .where((c) => c.lensDirection == CameraLensDirection.back)
          .toList();

      if (backCameras.isEmpty) {
        setState(() {
          _errorTitle = 'Camera unavailable';
          _errorBody = 'No rear camera was found on this device.';
          _scanState = ScanState.error;
        });
        return;
      }

      final selectedCamera = backCameras.first;

      _cameraController = CameraController(
        selectedCamera,
        ResolutionPreset.low,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize();
      bool hasTorch = true;
      try {
        await _cameraController!.setFlashMode(FlashMode.torch);
        hasTorch = _cameraController!.value.flashMode == FlashMode.torch;
      } catch (e) {
        hasTorch = false;
        debugPrint('[PPG] Could not enable torch: $e');
      }

      setState(() {
        _hasTorch = hasTorch;
        _scanState = ScanState.idle;
      });
      _startImageStream();
    } catch (e) {
      debugPrint('[PPG] Camera init failed: $e');
      if (mounted) {
        setState(() {
          _errorTitle = 'Camera unavailable';
          _errorBody = 'Please allow camera access in Settings\nand try again.';
          _scanState = ScanState.error;
        });
      }
    }
  }

  // ── Image stream / PPG ────────────────────────────────────────────────────

  void _startImageStream() {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized || controller.value.isStreamingImages) {
      return;
    }

    controller.startImageStream((CameraImage image) {
      if (!mounted || _isProcessingFrame || _showTutorial) {
        _fingerDetectedFrames = 0;
        return;
      }
      _isProcessingFrame = true;
      try {
        final redMean = _extractAverageRed(image);
        final fingerDetected = redMean > _fingerRedThreshold;

        if (fingerDetected) {
          _fingerDetectedFrames++;

          if (_scanState == ScanState.idle && _fingerDetectedFrames >= _requiredFingerFrames) {
            _startScan();
          }

          if (_scanState == ScanState.scanning) {
            _redValues.add(redMean);
          }
        } else {
          _fingerDetectedFrames = 0;
          if (_scanState == ScanState.scanning) _pauseScan();
        }
      } finally {
        _isProcessingFrame = false;
      }
    }).catchError((e) {
      debugPrint('[PPG] Failed to start image stream: $e');
    });
  }

  double _extractAverageRed(CameraImage image) {
    if (image.planes.isEmpty) return 0.0;
    final bytes = image.planes[0].bytes;
    double redSum = 0;
    int pixelCount = 0;
    for (int i = 2; i < bytes.length; i += 400) {
      redSum += bytes[i];
      pixelCount++;
    }
    return pixelCount == 0 ? 0 : redSum / pixelCount;
  }

  void _startScan() {
    if (_showTutorial) return;
    if (!mounted) return;
    setState(() {
      _scanState = ScanState.scanning;
      _redValues.clear();
      _fingerDetectedFrames = 0;
      _scanStartTime = DateTime.now();
      _progress = 0.0;
    });
    _spinController.repeat();

    _scanTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted || _scanState != ScanState.scanning) {
        timer.cancel();
        return;
      }
      final elapsed =
          DateTime.now().difference(_scanStartTime!).inMilliseconds;
      setState(() => _progress = elapsed / (_scanDurationSeconds * 1000));
      if (elapsed >= _scanDurationSeconds * 1000) {
        timer.cancel();
        _completeScan();
      }
    });
  }

  void _pauseScan() {
    if (!mounted) return;
    _scanTimer?.cancel();
    _spinController.stop();
    setState(() {
      _scanState = ScanState.idle;
      _progress = 0.0;
    });
  }

  Future<void> _completeScan() async {
    if (!mounted) return;
    setState(() => _scanState = ScanState.processing);
    _spinController.stop();
    final controller = _cameraController;
    if (controller != null && controller.value.isInitialized) {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream().catchError((_) {});
      }
      await controller.setFlashMode(FlashMode.off).catchError((_) {});
    }

    final durationSecs =
        DateTime.now().difference(_scanStartTime!).inMilliseconds / 1000.0;

    if (_redValues.isNotEmpty) {
      final minRed = _redValues.reduce(min);
      final maxRed = _redValues.reduce(max);
      final avgRed = _redValues.reduce((a, b) => a + b) / _redValues.length;
      debugPrint('[PPG] samples=${_redValues.length}, duration=$durationSecs, minRed=$minRed, maxRed=$maxRed, avgRed=$avgRed');
    }

    //final bpmResult = (60 + Random().nextInt(41)).toDouble(); <-- demo
    final algorithmBpm = PpgAlgorithm.calculateBPM(_redValues, durationSecs);
    final peakBpm = _calculatePeakIntervalBpm(_redValues, durationSecs);
    final minAcceptableBpm = _hasTorch ? 55.0 : 45.0;
    final bpmResult = peakBpm > 0
        ? peakBpm
        : (algorithmBpm > minAcceptableBpm ? algorithmBpm : 0.0);
    final qualityScore = PpgAlgorithm.calculateQuality(_redValues, durationSecs);
    debugPrint('[PPG] algorithmBpm=$algorithmBpm, peakBpm=$peakBpm, finalBpm=$bpmResult, qualityScore=$qualityScore');

    if (bpmResult > 0) {
      await _saveToFirestore(bpmResult.round(), qualityScore);
      if (mounted) {
        setState(() {
          _finalBpm = bpmResult;
          _scanState = ScanState.success;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _errorTitle = 'Poor signal detected';
          _errorBody = 'Try again with your fingertip fully covering the camera and flash. Keep your hand still and use light, steady pressure.';
          _scanState = ScanState.error;
        });
      }
    }
  }

  double _calculatePeakIntervalBpm(List<double> values, double durationSecs) {
    if (values.length < 100 || durationSecs <= 0) return 0.0;

    final sampleRate = values.length / durationSecs;
    if (sampleRate <= 0) return 0.0;

    final mean = values.reduce((a, b) => a + b) / values.length;
    final variance = values
            .map((v) => (v - mean) * (v - mean))
            .reduce((a, b) => a + b) /
        values.length;
    final sd = sqrt(variance);
    if (sd < 0.5) return 0.0;

    // Light smoothing helps remove frame-to-frame camera noise while preserving pulse waves.
    final smoothed = <double>[];
    for (int i = 0; i < values.length; i++) {
      final start = max(0, i - 2);
      final end = min(values.length - 1, i + 2);
      double sum = 0;
      int count = 0;
      for (int j = start; j <= end; j++) {
        sum += values[j] - mean;
        count++;
      }
      smoothed.add(sum / count);
    }

    final threshold = 0.04 * sd;
    final minGap = (sampleRate * 60.0 / 140.0).round();
    final maxGap = (sampleRate * 60.0 / 45.0).round();

    final peaks = <int>[];
    int lastPeak = -9999;

    for (int i = 1; i < smoothed.length - 1; i++) {
      final isLocalMax = smoothed[i] > smoothed[i - 1] && smoothed[i] >= smoothed[i + 1];
      final isTallEnough = smoothed[i] > threshold;
      final isFarEnough = i - lastPeak >= minGap;

      if (isLocalMax && isTallEnough && isFarEnough) {
        peaks.add(i);
        lastPeak = i;
      }
    }

    final intervals = <double>[];
    for (int i = 1; i < peaks.length; i++) {
      final gap = peaks[i] - peaks[i - 1];
      if (gap >= minGap && gap <= maxGap) {
        intervals.add(gap / sampleRate);
      }
    }

    if (intervals.length < 2) {
      debugPrint('[PPG] peak detector rejected: peaks=${peaks.length}, intervals=${intervals.length}, sampleRate=$sampleRate, minGap=$minGap, maxGap=$maxGap');
      return 0.0;
    }

    intervals.sort();
    final medianInterval = intervals[intervals.length ~/ 2];
    final bpm = 60.0 / medianInterval;

    debugPrint('[PPG] peak detector: peaks=${peaks.length}, intervals=${intervals.length}, sampleRate=$sampleRate, bpm=$bpm');

    if (bpm < 45 || bpm > 160) return 0.0;
    return bpm;
  }

  Future<void> _saveToFirestore(int bpm, double signalQuality) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final now = DateTime.now();
        final dayKey = '${now.year.toString().padLeft(4, '0')}-'
            '${now.month.toString().padLeft(2, '0')}-'
            '${now.day.toString().padLeft(2, '0')}';

        await FirebaseFirestore.instance.collection('heart_rate_scans').add({
          'userId': user.uid,
          'bpm': bpm,
          'signalQuality': signalQuality,
          'isFirstScan': _isFirstScan,
          'timestamp': FieldValue.serverTimestamp(),
          'durationSeconds': _scanDurationSeconds,
          'source': 'camera_ppg',
        });

        final heartRateDoc = await FirebaseFirestore.instance
            .collection('metrics_daily')
            .add({
          'userId': user.uid,
          'avg': bpm.toDouble(),
          'sum': bpm.toDouble(),
          'dimension': 'vitals',
          'metricType': 'heart_rate',
          'period': dayKey,
          'source': 'camera_ppg',
          'syncedAt': FieldValue.serverTimestamp(),
          'tags': _isFirstScan
              ? ['heart_rate', 'ppg', 'first_scan']
              : ['heart_rate', 'ppg'],
          'unit': 'bpm',
        });

        debugPrint('metrics_daily heart_rate doc created: ${heartRateDoc.id}');

        final signalQualityDoc = await FirebaseFirestore.instance
            .collection('metrics_daily')
            .add({
          'userId': user.uid,
          'avg': signalQuality,
          'sum': signalQuality,
          'dimension': 'vitals',
          'metricType': 'signal_quality',
          'period': dayKey,
          'source': 'camera_ppg',
          'syncedAt': FieldValue.serverTimestamp(),
          'tags': _isFirstScan
              ? ['signal_quality', 'ppg', 'first_scan']
              : ['signal_quality', 'ppg'],
          'unit': 'score',
        });

        debugPrint('metrics_daily signal_quality doc created: ${signalQualityDoc.id}');
        if (_isFirstScan && mounted) {
          setState(() {
            _isFirstScan = false;
            _showTutorial = false;
            _dismissedFirstScanTutorial = true;
          });
        }
      }
    } catch (e) {
      debugPrint('Failed to save to Firestore: $e');
    }
  }

  Future<void> _reset() async {
    _scanTimer?.cancel();
    _spinController.stop();
    _pulseController.repeat(reverse: true);
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      await _initCamera();
      return;
    }
    bool hasTorch = _hasTorch;
    try {
      await controller.setFlashMode(FlashMode.torch);
      hasTorch = controller.value.flashMode == FlashMode.torch;
    } catch (e) {
      hasTorch = false;
      debugPrint('[PPG] Could not enable torch during reset: $e');
    }
    setState(() {
      _hasTorch = hasTorch;
      _scanState = ScanState.idle;
      _progress = 0.0;
      _finalBpm = 0.0;
      _redValues.clear();
      _fingerDetectedFrames = 0;
      _errorTitle = 'Camera unavailable';
      _errorBody = 'Please allow camera access in Settings\nand try again.';
    });
    _startImageStream();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _spinController.dispose();
    _tutorialPageController.dispose();
    _scanTimer?.cancel();

    final controller = _cameraController;
    _cameraController = null;
    controller?.dispose();

    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 48),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Stress Scan',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: textDark,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Show tutorial',
                  onPressed: () {
                      _scanTimer?.cancel();
                      _spinController.stop();
                      setState(() {
                        _showTutorial = true;
                        _dismissedFirstScanTutorial = false;
                        _tutorialPageIndex = 0;
                        _fingerDetectedFrames = 0;
                        if (_scanState == ScanState.scanning) {
                          _scanState = ScanState.idle;
                          _progress = 0.0;
                          _redValues.clear();
                        }
                      });

                      if (_tutorialPageController.hasClients) {
                        _tutorialPageController.animateToPage(
                          0,
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                        );
                      }
                    },
                    icon: const Icon(
                      Icons.help_outline_rounded,
                      color: accentPurple,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                '15-second physiological assessment',
                style: TextStyle(fontSize: 14, color: textGrey),
              ),
              const SizedBox(height: 40),
              if (!_hasTorch && _scanState != ScanState.initializing) ...[
                _buildNoTorchWarning(),
                const SizedBox(height: 16),
              ],
              if (_showTutorial && _scanState == ScanState.idle) ...[
                _buildFirstScanTutorial(),
                const SizedBox(height: 20),
              ],
              if (_scanState == ScanState.initializing) _buildInitializing(),
              if (_scanState == ScanState.idle)         _buildIdle(),
              if (_scanState == ScanState.scanning)     _buildScanning(),
              if (_scanState == ScanState.processing)   _buildProcessing(),
              if (_scanState == ScanState.success)      _buildSuccess(),
              if (_scanState == ScanState.error)        _buildError(),
              const SizedBox(height: 120),
            ],
          ),
        ),
      ),
    );
  }

  // ── State widgets ─────────────────────────────────────────────────────────

  Widget _buildNoTorchWarning() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFF9500).withOpacity(0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFF9500).withOpacity(0.35)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: Color(0xFFFF9500),
            size: 20,
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'No flash detected — scan quality may be lower. Use a bright, steady light source and press firmly.',
              style: TextStyle(
                fontSize: 13,
                color: textDark,
                height: 1.4,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFirstScanTutorial() {
    final tutorialSlides = [
      {
        'icon': Icons.camera_alt_outlined,
        'title': 'Use the rear camera',
        'body': _hasTorch
            ? 'Place your fingertip so it fully covers both the rear camera and flash.'
            : 'Place your fingertip so it fully covers the rear camera lens.',
      },
      {
        'icon': Icons.touch_app_outlined,
        'title': 'Use light, steady pressure',
        'body': 'Press firmly enough to cover the lens, but avoid squeezing too hard. Too much pressure can weaken the pulse signal.',
      },
      {
        'icon': Icons.back_hand_outlined,
        'title': 'Cup with your other hand',
        'body': 'Use your other hand to gently shield the rear camera area. This helps block outside light and keeps your finger steady for a cleaner reading.',
      },
      {
        'icon': Icons.pan_tool_alt_outlined,
        'title': 'Hold still for 15 seconds',
        'body': 'Keep your phone and hand steady. The scan starts automatically once your finger is detected.',
      },
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cardWhite,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: accentPurple.withOpacity(0.22)),
        boxShadow: [
          BoxShadow(
            color: accentPurple.withOpacity(0.08),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.school_outlined, size: 17, color: accentPurple),
              SizedBox(width: 7),
              Text(
                'First scan tutorial',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: accentPurple,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 180,
            child: PageView.builder(
              controller: _tutorialPageController,
              itemCount: tutorialSlides.length,
              onPageChanged: (index) {
                setState(() {
                  _tutorialPageIndex = index;
                });
              },
              itemBuilder: (context, index) {
                final slide = tutorialSlides[index];
                return SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: accentPurple.withOpacity(0.10),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          slide['icon'] as IconData,
                          color: accentPurple,
                          size: 26,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        slide['title'] as String,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: textDark,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        slide['body'] as String,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: textGrey,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(tutorialSlides.length, (index) {
              final isActive = index == _tutorialPageIndex;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: isActive ? 18 : 7,
                height: 7,
                decoration: BoxDecoration(
                  color: isActive ? accentPurple : accentPurple.withOpacity(0.22),
                  borderRadius: BorderRadius.circular(10),
                ),
              );
            }),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _dismissScannerTutorial,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: textDark,
                    side: const BorderSide(color: Color(0xFFE5E5EA)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text('Skip'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () {
                    if (_tutorialPageIndex < tutorialSlides.length - 1) {
                      _tutorialPageController.nextPage(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                      );
                    } else {
                      _dismissScannerTutorial();
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accentPurple,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    _tutorialPageIndex == tutorialSlides.length - 1
                        ? 'Got it'
                        : 'Next',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInitializing() {
    return Column(
      children: [
        const SizedBox(height: 32),
        Center(
          child: Container(
            width: 160,
            height: 160,
            decoration: BoxDecoration(
              color: accentPurple.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Center(
              child: CircularProgressIndicator(
                color: accentPurple,
                strokeWidth: 3,
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),
        const Text(
          'Preparing camera...',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: textDark,
          ),
        ),
      ],
    );
  }

  Widget _buildIdle() {
    return Column(
      children: [
        const SizedBox(height: 32),
        Center(
          child: SizedBox(
            width: 160,
            height: 160,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (_, __) => Transform.scale(
                    scale: _pulseAnimation.value,
                    child: Container(
                      width: 160,
                      height: 160,
                      decoration: BoxDecoration(
                        color: accentPurple.withOpacity(0.08),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
                Container(
                  width: 130,
                  height: 130,
                  decoration: BoxDecoration(
                    color: accentPurple.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.fingerprint,
                    size: 68,
                    color: accentPurple,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 28),
        const Text(
          'Place your finger on the camera',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: textDark,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Your camera + flash measures your heart rate\nthrough your fingertip in 15 seconds.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: textGrey, height: 1.6),
        ),
        const SizedBox(height: 28),

        // ── How it works card ─────────────────────────────────────────
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE5E5EA)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.04),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.info_outline_rounded, size: 15, color: accentPurple),
                  SizedBox(width: 6),
                  Text(
                    'How it works',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: accentPurple,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildStep(
                '1',
                Icons.wb_sunny_outlined,
                _hasTorch ? 'Enable torch' : 'Find bright light',
                _hasTorch
                    ? 'The flash turns on automatically to illuminate your fingertip.'
                    : 'Find a bright light source and press your fingertip firmly over the lens.',
              ),
              const SizedBox(height: 14),
              _buildStep('2', Icons.touch_app_outlined,
                  'Cover the lens', 'Gently press your fingertip over the rear camera and flash — no need to press hard.'),
              const SizedBox(height: 14),
              _buildStep('3', Icons.favorite_outline_rounded,
                  'Hold still', 'Keep steady for 15 seconds. Scanning starts the moment your finger is detected.'),
              const SizedBox(height: 14),
              _buildStep('4', Icons.bar_chart_rounded,
                  'Get your results', 'Your heart rate and stress level are calculated and saved automatically.'),
            ],
          ),
        ),

        const SizedBox(height: 20),

        // ── Quick tips ────────────────────────────────────────────────
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: accentPurple.withOpacity(0.05),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: accentPurple.withOpacity(0.15)),
          ),
          child: Column(
            children: [
              _buildTipRow(Icons.do_not_touch_outlined, 'Avoid pressing too hard — light contact works best'),
              const SizedBox(height: 10),
              _buildTipRow(Icons.straighten_outlined, 'Keep your hand and phone level'),
              const SizedBox(height: 10),
              _buildTipRow(Icons.timer_outlined, 'Scanning starts automatically — just wait'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildScanning() {
    final secondsLeft =
        (_scanDurationSeconds - (_scanDurationSeconds * _progress)).ceil();
    return Column(
      children: [
        const SizedBox(height: 32),
        Center(
          child: SizedBox(
            width: 160,
            height: 160,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Track ring
                SizedBox(
                  width: 160,
                  height: 160,
                  child: CircularProgressIndicator(
                    value: _progress,
                    strokeWidth: 6,
                    backgroundColor: accentPurple.withOpacity(0.15),
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(accentPurple),
                  ),
                ),
                // Rotating ring
                RotationTransition(
                  turns: _spinController,
                  child: SizedBox(
                    width: 136,
                    height: 136,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      backgroundColor: Colors.transparent,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        accentPurple.withOpacity(0.3),
                      ),
                    ),
                  ),
                ),
                // Heart pulse icon
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (_, __) => Opacity(
                    opacity: 0.5 + 0.5 * _pulseController.value,
                    child: const Icon(
                      Icons.favorite_rounded,
                      size: 42,
                      color: accentPurple,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 32),
        Text(
          '$secondsLeft',
          style: const TextStyle(
            fontSize: 48,
            fontWeight: FontWeight.bold,
            color: textDark,
            height: 1.0,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'seconds remaining',
          style: TextStyle(fontSize: 14, color: textGrey),
        ),
        const SizedBox(height: 24),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: LinearProgressIndicator(
            value: _progress,
            minHeight: 8,
            backgroundColor: accentPurple.withOpacity(0.12),
            valueColor: const AlwaysStoppedAnimation<Color>(accentPurple),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Keep your finger still on the camera',
          style: TextStyle(fontSize: 13, color: textGrey),
        ),
      ],
    );
  }

  Widget _buildProcessing() {
    return Column(
      children: [
        const SizedBox(height: 32),
        Center(
          child: Container(
            width: 130,
            height: 130,
            decoration: BoxDecoration(
              color: accentPurple.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Center(
              child: CircularProgressIndicator(
                color: accentPurple,
                strokeWidth: 3,
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),
        const Text(
          'Analysing your scan...',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: textDark,
          ),
        ),
      ],
    );
  }

  Widget _buildSuccess() {
    final bpm = _finalBpm.round();
    final stressLabel = bpm < 65
        ? 'Low Stress'
        : bpm < 80
            ? 'Moderate'
            : 'Elevated';
    final stressColor = bpm < 65
        ? greenColor
        : bpm < 80
            ? const Color(0xFFFF9500)
            : redColor;
    final qualityScore = PpgAlgorithm.calculateQuality(
      _redValues,
      _scanDurationSeconds.toDouble(),
    );

    final qualityLabel = qualityScore >= 0.7
        ? 'Good'
        : qualityScore >= 0.4
        ? 'Fair'
        : 'Weak';

    final qualityColor = qualityScore >= 0.7
        ? greenColor
        : qualityScore >= 0.4
        ? const Color(0xFFFF9500)
        : redColor;

    return Column(
      children: [
        // Result card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
          decoration: BoxDecoration(
            color: accentPurple,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: accentPurple.withOpacity(0.35),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            children: [
              const Text(
                'Heart Rate',
                style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              Text(
                '$bpm',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 72,
                  fontWeight: FontWeight.bold,
                  height: 1.0,
                  letterSpacing: -2,
                ),
              ),
              const Text(
                'BPM',
                style: TextStyle(color: Colors.white60, fontSize: 16, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: stressColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      stressLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Metric pills
        Row(
          children: [
            Expanded(child: _buildMetricCard(Icons.favorite_rounded, 'Heart Rate', '$bpm bpm', redColor)),
            const SizedBox(width: 10),
            Expanded(child: _buildMetricCard(Icons.show_chart_rounded, 'Signal Quality', qualityLabel, qualityColor)),
            const SizedBox(width: 10),
            Expanded(child: _buildMetricCard(Icons.psychology_outlined, 'Strain', stressLabel, stressColor)),
          ],
        ),

        const SizedBox(height: 16),

        // AI insight
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: accentPurple.withOpacity(0.05),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: accentPurple.withOpacity(0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, size: 15, color: accentPurple),
                  SizedBox(width: 6),
                  Text(
                    'Insight',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: textDark),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                bpm < 65
                    ? 'Your heart rate is low and relaxed — great time for focused work or important conversations.'
                    : bpm < 80
                        ? 'Your heart rate looks healthy. Take a few deep breaths to keep stress balanced.'
                        : 'Your heart rate is elevated. Consider a short break, breathing exercise, or a walk.',
                style: const TextStyle(fontSize: 13, color: textGrey, height: 1.5),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Scan again
        SizedBox(
          width: double.infinity,
          height: 52,
          child: OutlinedButton(
            onPressed: _reset,
            style: OutlinedButton.styleFrom(
              foregroundColor: textDark,
              side: const BorderSide(color: Color(0xFFE5E5EA)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
            child: const Text(
              'Scan Again',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Column(
      children: [
        const SizedBox(height: 32),
        Center(
          child: Container(
            width: 130,
            height: 130,
            decoration: BoxDecoration(
              color: redColor.withOpacity(0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _errorTitle == 'Poor signal detected'
                  ? Icons.fingerprint
                  : Icons.camera_outlined,
              size: 52,
              color: redColor,
            ),
          ),
        ),
        const SizedBox(height: 32),
        Text(
          _errorTitle,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: textDark),
        ),
        const SizedBox(height: 8),
        Text(
          _errorBody,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, color: textGrey, height: 1.6),
        ),
        const SizedBox(height: 32),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: () {
              setState(() => _scanState = ScanState.initializing);
              if (_cameraController != null && _cameraController!.value.isInitialized) {
                _reset();
              } else {
                _initCamera();
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: accentPurple,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            ),
            child: const Text('Try Again', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
      ],
    );
  }

  // ── Shared widgets ────────────────────────────────────────────────────────

  Widget _buildStep(String number, IconData icon, String title, String body) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: accentPurple,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              number,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 14, color: accentPurple),
                  const SizedBox(width: 5),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: textDark,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                body,
                style: const TextStyle(fontSize: 12, color: textGrey, height: 1.5),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /*Widget _buildTipRow(IconData icon, String text) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: accentPurple),
        const SizedBox(width: 8),
        Text(text, style: const TextStyle(fontSize: 13, color: textGrey)),
      ],
    );
  }*/
  Widget _buildTipRow(IconData icon, String text) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 16, color: accentPurple),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          text,
          style: const TextStyle(fontSize: 13, color: textGrey),
        ),
      ),
    ],
  );
}

  Widget _buildMetricCard(IconData icon, String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: cardWhite,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E5EA)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 10, color: textGrey, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

