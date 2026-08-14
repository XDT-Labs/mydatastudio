import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/services/rx_service.dart';
import 'package:rxdart/rxdart.dart';

import 'package:mydatastudio/modules/photos/services/view_state_service.dart';

class PhotosServiceCommand extends RxCommand {
  final PhotoFilter filter;
  PhotosServiceCommand(this.filter);
}

class PhotosService extends RxService<PhotosServiceCommand, List<File>> {
  static final PhotosService _instance = PhotosService._();
  static PhotosService get instance => _instance;
  
  PhotosService._();

  final AppLogger logger = AppLogger(null);

  final BehaviorSubject<Map<String, List<File>>> photosByDate = BehaviorSubject<Map<String, List<File>>>();
  final BehaviorSubject<Map<String, List<File>>> photosByMonth = BehaviorSubject<Map<String, List<File>>>();
  final BehaviorSubject<List<File>> photosWithLocation = BehaviorSubject<List<File>>();
  final BehaviorSubject<Map<String, int>> tagCounts = BehaviorSubject<Map<String, int>>();
  final BehaviorSubject<Map<String, int>> locationCounts = BehaviorSubject<Map<String, int>>();
  final BehaviorSubject<Map<String, int>> collectionPhotoCounts = BehaviorSubject<Map<String, int>>();

  Future<List<File>> refresh() async {
    final filter = ViewStateService.instance.activeFilter.valueOrNull ?? const PhotoFilter();
    return invoke(PhotosServiceCommand(filter));
  }

  @override
  Future<List<File>> invoke(PhotosServiceCommand command) async {
    isLoading.add(true);
    PhotosRepository repo = PhotosRepository();

    try {
      final photos = await repo.photos(filter: command.filter);
      final byDate = await repo.photosByDate(filter: command.filter);
      final byMonth = await repo.photosByMonth(filter: command.filter);
      final withLocation = await repo.photosWithLocation(filter: command.filter);
      
      final tCounts = await repo.allTags();
      final lCounts = await repo.allLocations();
      final cCounts = await repo.photoCountsByCollection();

      sink.add(photos);
      photosByDate.add(byDate);
      photosByMonth.add(byMonth);
      photosWithLocation.add(withLocation);
      tagCounts.add(tCounts);
      locationCounts.add(lCounts);
      collectionPhotoCounts.add(cCounts);

      return photos;
    } catch (e, st) {
      sink.addError(e, st);
      rethrow;
    } finally {
      isLoading.add(false);
    }
  }
}
