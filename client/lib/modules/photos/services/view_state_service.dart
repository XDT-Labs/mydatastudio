import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
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

  void setViewMode(PhotoViewMode mode) => viewMode.add(mode);
  void setInfoMedia(File? media) => infoMedia.add(media);
  void toggleInfo() => isInfoOpen.add(!isInfoOpen.value);
  void closeInfo() => isInfoOpen.add(false);
  void openInfo(File file) {
    infoMedia.add(file);
    isInfoOpen.add(true);
  }
  void openLightbox(File media) => lightboxMedia.add(media);
  void setLightboxMedia(File? media) => lightboxMedia.add(media);
  void updateFilter(PhotoFilter filter) => activeFilter.add(filter);
  void setActiveNav(String nav) => activeNav.add(nav);
}
