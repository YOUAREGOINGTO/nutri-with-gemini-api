import 'dart:io';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:image_picker/image_picker.dart';

class FoodImagePicker extends StatelessWidget {
  const FoodImagePicker({
    super.key,
    required this.images,
    required this.canUseCamera,
    required this.onPickImage,
    required this.onRemoveImage,
  });
  final List<File> images;
  final bool canUseCamera;
  final void Function(ImageSource source) onPickImage;
  final ValueChanged<int> onRemoveImage;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (images.isEmpty)
          GestureDetector(
            onTap: () => onPickImage(ImageSource.gallery),
            child: Container(
              height: 200,
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_a_photo, size: 40, color: Colors.grey),
                  Gap(8),
                  Text(
                    'Tap to add photos',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ),
          )
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: images.length + 1,
            itemBuilder: (context, index) {
              if (index == images.length) {
                return InkWell(
                  onTap: () => onPickImage(ImageSource.gallery),
                  borderRadius: BorderRadius.circular(8),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.add_photo_alternate),
                  ),
                );
              }

              return Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(images[index], fit: BoxFit.cover),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: IconButton.filledTonal(
                      visualDensity: VisualDensity.compact,
                      onPressed: () => onRemoveImage(index),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ],
              );
            },
          ),
        const Gap(16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton.icon(
              onPressed: canUseCamera
                  ? () => onPickImage(ImageSource.camera)
                  : null,
              icon: const Icon(Icons.camera_alt),
              label: const Text('Camera'),
            ),
            TextButton.icon(
              onPressed: () => onPickImage(ImageSource.gallery),
              icon: const Icon(Icons.photo_library),
              label: const Text('Gallery'),
            ),
          ],
        ),
      ],
    );
  }
}
