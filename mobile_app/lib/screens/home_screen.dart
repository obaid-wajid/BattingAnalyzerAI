import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;

// Custom MultipartRequest to stream bytes and calculate real-time upload progress
class MultipartRequestWithProgress extends http.MultipartRequest {
  final void Function(int bytes, int totalBytes)? onProgress;

  MultipartRequestWithProgress(
    super.method,
    super.url, {
    this.onProgress,
  });

  @override
  http.ByteStream finalize() {
    final byteStream = super.finalize();
    if (onProgress == null) return byteStream;

    final total = contentLength;
    int bytes = 0;

    final stream = byteStream.transform(
      StreamTransformer.fromHandlers(
        handleData: (List<int> data, EventSink<List<int>> sink) {
          bytes += data.length;
          sink.add(data);
          onProgress!(bytes, total);
        },
      ),
    );

    return http.ByteStream(stream);
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ImagePicker _picker = ImagePicker();

  File? _selectedVideoFile;
  String? _videoFileName;
  Duration? _videoDuration;
  String? _videoFileSize;
  VideoPlayerController? _videoPlayerController;

  bool _isProcessingVideo = false;
  bool _isPlaying = false;
  String? _videoErrorMessage;

  // Cloudinary Upload State
  bool _isUploading = false;
  double _uploadProgress = 0.0;
  bool _isUploaded = false;
  String? _uploadedVideoId;
  String? _uploadedPublicId;
  String? _uploadedSecureUrl;
  http.Client? _activeHttpClient;

  @override
  void dispose() {
    _disposeVideoController();
    _activeHttpClient?.close();
    super.dispose();
  }

  void _disposeVideoController() {
    if (_videoPlayerController != null) {
      _videoPlayerController!.removeListener(_videoListener);
      _videoPlayerController!.dispose();
      _videoPlayerController = null;
    }
  }

  void _videoListener() {
    if (!mounted || _videoPlayerController == null) return;
    final isPlaying = _videoPlayerController!.value.isPlaying;
    if (isPlaying != _isPlaying) {
      setState(() {
        _isPlaying = isPlaying;
      });
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _pickVideo() async {
    if (_isUploading) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot change video while upload is in progress.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    try {
      final XFile? pickedFile = await _picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 2),
      );

      if (pickedFile == null) return;

      setState(() {
        _isProcessingVideo = true;
        _videoErrorMessage = null;
      });

      final file = File(pickedFile.path);
      final tempController = VideoPlayerController.file(file);

      await tempController.initialize();
      final duration = tempController.value.duration;

      // Reject if video is longer than 2 minutes (120 seconds)
      if (duration.inSeconds > 120) {
        await tempController.dispose();
        if (!mounted) return;

        final formattedLength = _formatDuration(duration);
        final errorMsg =
            'Selected video is too long ($formattedLength). Maximum allowed duration is 2:00 minutes.';

        setState(() {
          _isProcessingVideo = false;
          _videoErrorMessage = errorMsg;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(child: Text(errorMsg)),
              ],
            ),
            backgroundColor: Colors.redAccent.shade700,
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      // Valid video: clean up previous controller and set new one
      _disposeVideoController();
      _videoPlayerController = tempController;
      _videoPlayerController!.addListener(_videoListener);

      String sizeString = '';
      try {
        final bytes = await file.length();
        sizeString = _formatFileSize(bytes);
      } catch (_) {}

      if (!mounted) return;

      setState(() {
        _selectedVideoFile = file;
        _videoFileName = pickedFile.name.isNotEmpty
            ? pickedFile.name
            : file.path.split(Platform.pathSeparator).last;
        _videoDuration = duration;
        _videoFileSize = sizeString;
        _isProcessingVideo = false;
        _videoErrorMessage = null;
        _isPlaying = false;
        // Reset upload state for newly picked video
        _isUploading = false;
        _uploadProgress = 0.0;
        _isUploaded = false;
        _uploadedVideoId = null;
        _uploadedPublicId = null;
        _uploadedSecureUrl = null;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: const [
              Icon(Icons.check_circle_outline, color: Colors.greenAccent),
              SizedBox(width: 10),
              Text('Batting video selected and ready for preview!'),
            ],
          ),
          backgroundColor: const Color(0xFF1E293B),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessingVideo = false;
        _videoErrorMessage =
            'Failed to load video. Please select a valid video file.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_videoErrorMessage!),
          backgroundColor: Colors.redAccent.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _removeVideo() {
    if (_isUploading) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot remove video while upload is in progress.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    _disposeVideoController();
    setState(() {
      _selectedVideoFile = null;
      _videoFileName = null;
      _videoDuration = null;
      _videoFileSize = null;
      _videoErrorMessage = null;
      _isPlaying = false;
      _isUploading = false;
      _uploadProgress = 0.0;
      _isUploaded = false;
      _uploadedVideoId = null;
      _uploadedPublicId = null;
      _uploadedSecureUrl = null;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Video removed.'),
        backgroundColor: Color(0xFF1E293B),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _togglePlayPause() {
    if (_videoPlayerController == null ||
        !_videoPlayerController!.value.isInitialized) {
      return;
    }
    setState(() {
      if (_videoPlayerController!.value.isPlaying) {
        _videoPlayerController!.pause();
      } else {
        _videoPlayerController!.play();
      }
    });
  }

  // Cloudinary Unsigned Video Upload with Multipart HTTP
  Future<void> _uploadVideoToCloudinary() async {
    // Prevent duplicate upload taps while an upload is in progress
    if (_isUploading) return;

    if (_selectedVideoFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a batting video first.'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // Prevent unauthenticated users from uploading
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You must be logged in to upload video.'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() {
      _isUploading = true;
      _uploadProgress = 0.0;
      _videoErrorMessage = null;
    });

    String? uploadedSecureUrl;
    String? uploadedPublicId;
    double? detectedDuration;

    // STEP A: Upload video file to Cloudinary via unsigned preset
    try {
      const cloudName = 'j6yqqxmw';
      const uploadPreset = 'batting_analyzer';
      final uri =
          Uri.parse('https://api.cloudinary.com/v1_1/$cloudName/video/upload');

      final client = http.Client();
      _activeHttpClient = client;

      final request = MultipartRequestWithProgress(
        'POST',
        uri,
        onProgress: (bytes, total) {
          if (mounted && total > 0) {
            setState(() {
              _uploadProgress = bytes / total;
            });
          }
        },
      );

      // Unsigned upload preset provided by Cloudinary
      request.fields['upload_preset'] = uploadPreset;
      request.fields['folder'] = 'batting_videos/${user.uid}';

      final fileBytes = await http.MultipartFile.fromPath(
        'file',
        _selectedVideoFile!.path,
      );
      request.files.add(fileBytes);

      final streamedResponse = await client.send(request);
      final responseBody = await streamedResponse.stream.bytesToString();

      if (streamedResponse.statusCode == 200 ||
          streamedResponse.statusCode == 201) {
        final jsonResponse = jsonDecode(responseBody) as Map<String, dynamic>;
        uploadedSecureUrl = jsonResponse['secure_url'] as String?;
        uploadedPublicId = jsonResponse['public_id'] as String?;
        detectedDuration = (jsonResponse['duration'] as num?)?.toDouble() ??
            (_videoDuration?.inSeconds.toDouble() ?? 0.0);

        if (uploadedSecureUrl == null || uploadedPublicId == null) {
          throw Exception('Incomplete upload response received from Cloudinary.');
        }
      } else {
        String errorMsg =
            'Cloudinary upload failed (status ${streamedResponse.statusCode})';
        try {
          final errorJson = jsonDecode(responseBody);
          if (errorJson['error']?['message'] != null) {
            errorMsg = errorJson['error']['message'];
          }
        } catch (_) {}
        throw Exception(errorMsg);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isUploading = false;
        _videoErrorMessage = 'Upload error: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_videoErrorMessage!),
          backgroundColor: Colors.redAccent.shade700,
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    } finally {
      _activeHttpClient = null;
    }

    // STEP B: Save Cloudinary metadata to Cloud Firestore
    try {
      const uuid = Uuid();
      final videoId = uuid.v4();
      final durationValue =
          detectedDuration ?? (_videoDuration?.inSeconds.toDouble() ?? 0.0);

      // Save fields to match Firestore schema & Recent Analyses readers
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('videos')
          .doc(videoId)
          .set({
        'videoId': videoId,
        'userId': user.uid,
        'filename': _videoFileName ?? 'batting_video.mp4',
        'fileName': _videoFileName ?? 'batting_video.mp4', // compatibility
        'secure_url': uploadedSecureUrl,
        'videoUrl': uploadedSecureUrl, // compatibility
        'public_id': uploadedPublicId,
        'duration': durationValue,
        'uploadedAt': FieldValue.serverTimestamp(),
        'status': 'uploaded',
      });

      if (!mounted) return;

      setState(() {
        _isUploading = false;
        _uploadProgress = 1.0;
        _isUploaded = true;
        _uploadedVideoId = videoId;
        _uploadedPublicId = uploadedPublicId;
        _uploadedSecureUrl = uploadedSecureUrl;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: const [
              Icon(Icons.check_circle, color: Colors.greenAccent),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Video uploaded to Cloudinary and saved to your profile!',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF13271D),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      // Step B Failure: Cloudinary succeeded, BUT Firestore metadata save failed!
      if (!mounted) return;

      final partialError =
          'Video uploaded to Cloudinary, but failed to save session to Firestore: $e';

      setState(() {
        _isUploading = false;
        _videoErrorMessage = partialError;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.amberAccent),
                  SizedBox(width: 8),
                  Text(
                    'Cloudinary Succeeded, Firestore Failed',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Video was stored in Cloudinary ($uploadedPublicId), but metadata could not be saved to your Firestore profile: $e',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
          backgroundColor: Colors.orange.shade900,
          duration: const Duration(seconds: 7),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _handleLogout(BuildContext context) async {
    if (_isUploading) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: const Text('Upload in Progress',
              style: TextStyle(color: Colors.white)),
          content: const Text(
            'A video is currently uploading to Cloudinary. Logging out will cancel the upload. Do you wish to continue?',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child:
                  const Text('Cancel', style: TextStyle(color: Colors.white60)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent.shade700,
              ),
              child: const Text('Log Out Anyway'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
      _activeHttpClient?.close();
    }

    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text(
          'Log Out',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'Are you sure you want to log out of Batting Analyzer AI?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent.shade700,
              foregroundColor: Colors.white,
            ),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );

    if (shouldLogout == true) {
      _disposeVideoController();
      await FirebaseAuth.instance.signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final userEmail = user?.email ?? 'Player';

    return Scaffold(
      backgroundColor: const Color(0xFF0A0F1D), // Dark navy/black background
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        centerTitle: false,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.greenAccent.withOpacity(0.3),
                ),
              ),
              child: const Icon(
                Icons.sports_cricket,
                color: Colors.greenAccent,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'BATTING ANALYZER AI',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
                color: Colors.white,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white70),
            tooltip: 'Logout',
            onPressed: () => _handleLogout(context),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Welcome Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [
                      Color(0xFF13271D),
                      Color(0xFF0F1E2E),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.greenAccent.withOpacity(0.25),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 20,
                          backgroundColor: Colors.green.withOpacity(0.2),
                          child: const Icon(
                            Icons.person,
                            color: Colors.greenAccent,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Welcome back,',
                                style: TextStyle(
                                  color: Colors.white60,
                                  fontSize: 13,
                                ),
                              ),
                              Text(
                                userEmail,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Select and upload your cricket batting video to analyze stance, stroke execution, and posture.',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // Error notification if selection or upload failed
              if (_videoErrorMessage != null) ...[
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.redAccent.withOpacity(0.4),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.redAccent,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _videoErrorMessage!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              // Video Section: Either Upload Prompt Card or Playable Preview Card
              if (_selectedVideoFile == null)
                _buildUploadPromptCard()
              else
                _buildVideoPreviewCard(),

              const SizedBox(height: 30),

              // Recent Analyses Section (Listens to Firestore metadata)
              _buildRecentAnalysesSection(user?.uid),

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  // Upload Batting Video Card
  Widget _buildUploadPromptCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.greenAccent.withOpacity(0.4),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.green.withOpacity(0.1),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.green.withOpacity(0.15),
              border: Border.all(
                color: Colors.greenAccent,
                width: 2,
              ),
            ),
            child: Center(
              child: _isProcessingVideo
                  ? const CircularProgressIndicator(
                      color: Colors.greenAccent,
                      strokeWidth: 3,
                    )
                  : const Icon(
                      Icons.video_call_rounded,
                      size: 42,
                      color: Colors.greenAccent,
                    ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Upload Batting Video',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Select a video of your batting session from gallery to inspect shot execution and stance.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white60,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),

          // Max duration badge
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFF1F2937),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white12,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(
                  Icons.timer_outlined,
                  size: 16,
                  color: Colors.amberAccent,
                ),
                SizedBox(width: 6),
                Text(
                  'Maximum video duration: 2 minutes',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Action Button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isProcessingVideo ? null : _pickVideo,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.greenAccent.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 2,
              ),
              icon: _isProcessingVideo
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.video_library_outlined),
              label: Text(
                _isProcessingVideo
                    ? 'VERIFYING DURATION...'
                    : 'SELECT FROM GALLERY',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Playable Video Preview Card with Real-time Cloudinary Upload
  Widget _buildVideoPreviewCard() {
    final controller = _videoPlayerController;
    final isInitialized = controller != null && controller.value.isInitialized;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _isUploaded
              ? Colors.greenAccent
              : Colors.greenAccent.withOpacity(0.5),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.green.withOpacity(0.12),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header inside the card
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.greenAccent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.play_circle_fill_rounded,
                    color: Colors.greenAccent,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Video Selected',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _isUploaded
                        ? Colors.green.withOpacity(0.3)
                        : Colors.green.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.greenAccent.withOpacity(0.4),
                    ),
                  ),
                  child: Text(
                    _isUploaded
                        ? 'Uploaded'
                        : (_isUploading ? 'Uploading...' : 'Ready'),
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Video Player Screen
          if (isInitialized) ...[
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: Colors.black,
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AspectRatio(
                    aspectRatio: controller.value.aspectRatio > 0
                        ? controller.value.aspectRatio
                        : 16 / 9,
                    child: VideoPlayer(controller),
                  ),

                  // Tap Area for Play/Pause
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _togglePlayPause,
                      child: AnimatedOpacity(
                        opacity: _isPlaying ? 0.0 : 1.0,
                        duration: const Duration(milliseconds: 200),
                        child: Container(
                          color: Colors.black38,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.black.withOpacity(0.65),
                                border: Border.all(
                                  color: Colors.greenAccent,
                                  width: 2,
                                ),
                              ),
                              child: const Icon(
                                Icons.play_arrow_rounded,
                                size: 44,
                                color: Colors.greenAccent,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  if (_isPlaying)
                    Positioned(
                      top: 10,
                      right: 10,
                      child: GestureDetector(
                        onTap: _togglePlayPause,
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.pause,
                            size: 18,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Video Progress Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: VideoProgressIndicator(
                controller,
                allowScrubbing: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                colors: const VideoProgressColors(
                  playedColor: Colors.greenAccent,
                  bufferedColor: Colors.white24,
                  backgroundColor: Colors.white12,
                ),
              ),
            ),
          ] else ...[
            Container(
              height: 180,
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: Colors.black45,
              ),
              child: const Center(
                child: CircularProgressIndicator(
                  color: Colors.greenAccent,
                ),
              ),
            ),
          ],

          // Video Metadata Section
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.movie_outlined,
                        color: Colors.greenAccent,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _videoFileName ?? 'batting_video.mp4',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.access_time_rounded,
                            size: 16,
                            color: Colors.amberAccent,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _videoDuration != null
                                ? '${_formatDuration(_videoDuration!)} / 02:00'
                                : '--:--',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      if (_videoFileSize != null &&
                          _videoFileSize!.isNotEmpty) ...[
                        Row(
                          children: [
                            const Icon(
                              Icons.data_usage_rounded,
                              size: 16,
                              color: Colors.lightBlueAccent,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _videoFileSize!,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Real-time Upload Progress Bar
          if (_isUploading) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F1E2E),
                  borderRadius: BorderRadius.circular(12),
                  border:
                      Border.all(color: Colors.greenAccent.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: const [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.greenAccent,
                              ),
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Uploading to Cloudinary...',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '${(_uploadProgress * 100).toInt()}%',
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: _uploadProgress,
                        minHeight: 8,
                        backgroundColor: Colors.white12,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                            Colors.greenAccent),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          // Uploaded Confirmation Banner
          if (_isUploaded) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: Colors.greenAccent.withOpacity(0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle,
                        color: Colors.greenAccent, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Uploaded to Cloudinary & Saved in Firestore',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (_uploadedPublicId != null)
                            Text(
                              'Cloudinary ID: $_uploadedPublicId',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          // Action Buttons: Change Video, Remove
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isUploading ? null : _pickVideo,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Change Video'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isUploading ? null : _removeVideo,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: BorderSide(
                          color: Colors.redAccent.withOpacity(0.4)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Remove'),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // Upload Video Button
          if (!_isUploaded) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isUploading ? null : _uploadVideoToCloudinary,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.greenAccent.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 2,
                  ),
                  icon: _isUploading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.cloud_upload_rounded),
                  label: Text(
                    _isUploading
                        ? 'UPLOADING (${(_uploadProgress * 100).toInt()}%)...'
                        : 'UPLOAD TO CLOUDINARY',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
              ),
            ),
          ],

          const SizedBox(height: 12),

          // Analyze Video Button (Disabled pending future AI analysis integration)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: null, // Kept disabled for now
                style: ElevatedButton.styleFrom(
                  disabledBackgroundColor: const Color(0xFF1E293B),
                  disabledForegroundColor: Colors.white38,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.sports_cricket),
                label: Text(
                  _isUploaded
                      ? 'ANALYZE VIDEO (CRICKET AI - COMING SOON)'
                      : 'UPLOAD VIDEO TO ANALYZE',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Recent Analyses Section connected to Firestore
  Widget _buildRecentAnalysesSection(String? userId) {
    if (userId == null) {
      return _buildEmptyState(0);
    }

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('videos')
          .snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? [];
        final count = docs.length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Recent Analyses',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '$count session${count == 1 ? '' : 's'}',
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (count == 0)
              _buildEmptyState(0)
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: docs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final data =
                      docs[index].data() as Map<String, dynamic>? ?? {};
                  // Read filename with fallback for both camelCase and lowercase
                  final fileName = data['filename'] as String? ??
                      data['fileName'] as String? ??
                      'Batting Session';
                  final durationSec = data['duration'] as num? ?? 0;
                  final status = data['status'] as String? ?? 'uploaded';
                  final publicId = data['public_id'] as String? ?? '';

                  return Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white.withOpacity(0.06)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.sports_cricket,
                            color: Colors.greenAccent,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                fileName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Text(
                                    '${durationSec.toInt()}s duration',
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  const Text('•',
                                      style: TextStyle(color: Colors.white38)),
                                  const SizedBox(width: 8),
                                  Text(
                                    status.toUpperCase(),
                                    style: const TextStyle(
                                      color: Colors.greenAccent,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              if (publicId.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  'Cloudinary: $publicId',
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.35),
                                    fontSize: 10,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
  }

  Widget _buildEmptyState(int count) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: 20,
        vertical: 36,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withOpacity(0.06),
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.03),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.analytics_outlined,
              size: 44,
              color: Colors.white38,
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'No Analyses Yet',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Upload your batting clip to see AI shot analysis, posture breakdowns, and metrics here.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white38,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
