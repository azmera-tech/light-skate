import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../theme.dart';

/// Opens the device camera (native camera UI, so preview/retake is handled by the OS), then shows
/// a final confirm/retake step on top before handing back resized JPEG bytes (downscaled the same
/// way the web app does — client-side, before upload — so uploads stay small and fast).
/// Returns null if the staff member skips or cancels.
Future<Uint8List?> captureCustomerPhoto(BuildContext context, {String title = 'Take a photo'}) async {
  final picker = ImagePicker();
  Uint8List? bytes;

  while (true) {
    if (bytes == null) {
      final choice = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
          child: Wrap(children: [
            ListTile(leading: const Icon(Icons.camera_alt), title: const Text('Take photo'), onTap: () => Navigator.pop(context, 'camera')),
            ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Choose from gallery'), onTap: () => Navigator.pop(context, 'gallery')),
            ListTile(leading: const Icon(Icons.close), title: const Text('Skip photo'), onTap: () => Navigator.pop(context, 'skip')),
          ]),
        ),
      );
      if (choice == null || choice == 'skip') return null;
      try {
        final file = await picker.pickImage(
          source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
          maxWidth: 1024,
          maxHeight: 1024,
          imageQuality: 85,
          preferredCameraDevice: CameraDevice.front,
        );
        if (file == null) continue; // user backed out of the picker; show the sheet again
        bytes = await file.readAsBytes();
      } catch (e) {
        if (!context.mounted) return null;
        final retry = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Camera unavailable'),
            content: Text('Could not access the camera or photo library: $e'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Skip photo')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Try again')),
            ],
          ),
        );
        if (retry != true) return null;
        continue;
      }
    }

    if (!context.mounted) return bytes;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.memory(bytes!, fit: BoxFit.cover)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Retake')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Use this photo')),
        ],
      ),
    );
    if (confirmed == true) return bytes;
    bytes = null; // retake
  }
}

/// A small inline tile showing "no photo yet" / a captured preview, used in forms before upload.
class PhotoPreviewTile extends StatelessWidget {
  final Uint8List? bytes;
  final VoidCallback onTap;
  const PhotoPreviewTile({super.key, required this.bytes, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 160,
        decoration: BoxDecoration(
          color: LsColors.surface2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: LsColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: bytes != null
            ? Image.memory(bytes!, fit: BoxFit.cover, width: double.infinity)
            : const Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.camera_alt_outlined, color: LsColors.muted, size: 32),
                  SizedBox(height: 6),
                  Text('Tap to take a photo', style: TextStyle(color: LsColors.muted)),
                ]),
              ),
      ),
    );
  }
}
