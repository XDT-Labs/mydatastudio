import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/services/rx_service.dart';

class PhotosByDateService
    extends RxService<PhotosByDateServiceCommand, Map<String, List<File>>> {
  static final PhotosByDateService _singleton = PhotosByDateService();
  static PhotosByDateService get instance => _singleton;

  final AppLogger logger = AppLogger(null);

  @override
  Future<Map<String, List<File>>> invoke(
    PhotosByDateServiceCommand command,
  ) async {
    isLoading.add(true);
    PhotosRepository repo = PhotosRepository();

    //load files and folders from db
    Map<String, List<File>> photos = await repo.photosByDate();
    sink.add(photos);
    isLoading.add(false);

    return Future(() => photos);
  }
}

class PhotosByDateServiceCommand extends RxCommand {}
