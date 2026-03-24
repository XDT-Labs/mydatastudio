import 'dart:convert';
import 'dart:io' as io;
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/modules/files/files_constants.dart';
import 'package:image/image.dart' as img;

class ThumbnailGenerator {
  Future<String?> imageToBase64(File file) async {
    return pathImageToBase64(file.path, file.contentType);
  }

  Future<String?> pathImageToBase64(String filePath, String? contentType) async {
    bool thumbGenerated = false;
    if (contentType == FilesConstants.mimeTypeImage) {
      var localFile = io.File(filePath);
      if (localFile.existsSync()) {
        // Read a image from file.
        img.Image? image = img.decodeImage(localFile.readAsBytesSync());
        if (image != null) {
          img.Image? thumb;
          //resize to something around 320x240 (small enough to use as a thumbnail big enough to do other things, like phash or ml)
          if (image.height >= image.width && image.height > 240) {
            thumb = img.copyResize(image, height: 240);
          } else if (image.width >= image.height && image.width > 320) {
            thumb = img.copyResize(image, width: 320);
          } else {
            thumb = image; // Use original if it's already small enough
          }

          //save as jpeg and encode to base64
          thumbGenerated = true;
          final jpg = img.encodeJpg(thumb); // thumb will not be null here
          var enc = base64Encode(jpg);
          return enc;
        }
      }
    }

    if (!thumbGenerated) {
      // TODO, check EXIF data and see if thumbnail exists in exif (TIF, JPG often have this)
    }

    return null;
  }
}
