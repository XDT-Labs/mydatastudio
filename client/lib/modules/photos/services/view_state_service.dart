import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:rxdart/rxdart.dart';

enum PhotoViewMode { grid, list, timeline, map }

class ViewStateService {
  static final ViewStateService _instance = ViewStateService._();
  static ViewStateService get instance => _instance;
  
  ViewStateService._();

  final BehaviorSubject<PhotoViewMode> viewMode = BehaviorSubject<PhotoViewMode>.seeded(PhotoViewMode.grid);
  final BehaviorSubject<File?> infoMedia = BehaviorSubject<File?>.seeded(null);
  final BehaviorSubject<bool> isInfoOpen = BehaviorSubject<bool>.seeded(false);
  final BehaviorSubject<File?> lightboxMedia = BehaviorSubject<File?>.seeded(null);
  final BehaviorSubject<PhotoFilter> activeFilter = BehaviorSubject<PhotoFilter>.seeded(const PhotoFilter());
  final BehaviorSubject<String> activeNav = BehaviorSubject<String>.seeded('all');
  final BehaviorSubject<double> gridItemSize = BehaviorSubject<double>.seeded(160.0);

  void setViewMode(PhotoViewMode mode) => viewMode.add(mode);
  void setGridItemSize(double size) => gridItemSize.add(size);
  void setInfoMedia(File? media) => infoMedia.add(media);
  void toggleInfo() => isInfoOpen.add(!isInfoOpen.value);
  void closeInfo() => isInfoOpen.add(false);
  void openInfo(File file) {
    infoMedia.add(file);
    isInfoOpen.add(true);
  }
  void openLightbox(File media) => lightboxMedia.add(media);
  void setLightboxMedia(File? media) => lightboxMedia.add(media);
  void closeLightboxAndInfo() {
    lightboxMedia.add(null);
    isInfoOpen.add(false);
  }
  void updateFilter(PhotoFilter filter) {
    closeLightboxAndInfo();
    SelectionService.instance.deselectAll();
    activeFilter.add(filter);
  }
  void setSortOrder(PhotoSortOrder sort) {
    final current = activeFilter.value;
    if (current.sortBy != sort) {
      activeFilter.add(current.copyWith(sortBy: sort));
    }
  }
  void setActiveNav(String nav) {
    closeLightboxAndInfo();
    SelectionService.instance.deselectAll();
    activeNav.add(nav);
  }
}
