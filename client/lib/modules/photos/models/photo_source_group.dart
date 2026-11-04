import 'package:mydatastudio/app_constants.dart';

/// Which source a photo-bearing collection came from, as the Photos module
/// presents it to the user.
///
/// Coarser than the raw scanner list on purpose: Outlook's live IMAP scanner
/// and its one-time PST import are two different code paths, but to someone
/// looking at their gallery both are simply "Outlook". Anywhere the user is
/// shown where photos came from — the drawer's Sources list, the hide
/// confirmation dialog — must agree on that grouping, so the mapping lives
/// here rather than being repeated per widget.
enum PhotoSourceGroup { local, gdrive, gmail, yahoo, outlook, other }

/// Display order for the Sources list and any per-source summary.
const List<PhotoSourceGroup> kPhotoSourceGroupOrder = [
  PhotoSourceGroup.local,
  PhotoSourceGroup.gdrive,
  PhotoSourceGroup.gmail,
  PhotoSourceGroup.yahoo,
  PhotoSourceGroup.outlook,
  PhotoSourceGroup.other,
];

/// [emailProviderId] is the collection's `emailProviderId`; it groups generic
/// `email.imap` collections with the provider the user actually connected.
PhotoSourceGroup photoSourceGroupFor(
  String? scanner, {
  String? emailProviderId,
}) {
  switch (scanner) {
    case AppConstants.scannerFileLocal:
      return PhotoSourceGroup.local;
    case AppConstants.scannerFileGDrive:
      return PhotoSourceGroup.gdrive;
    case AppConstants.scannerEmailYahoo:
      return PhotoSourceGroup.yahoo;
    // Live IMAP and PST import are one source as far as the user is concerned.
    case AppConstants.scannerEmailOutlook:
    case AppConstants.scannerEmailOutlookPst:
      return PhotoSourceGroup.outlook;
    case AppConstants.scannerEmailImap:
      switch (emailProviderId) {
        case 'gmail':
          return PhotoSourceGroup.gmail;
        case 'yahoo':
          return PhotoSourceGroup.yahoo;
        case 'outlook':
          return PhotoSourceGroup.outlook;
      }
      return PhotoSourceGroup.other;
    default:
      return PhotoSourceGroup.other;
  }
}

String photoSourceGroupLabel(PhotoSourceGroup group) {
  switch (group) {
    case PhotoSourceGroup.local:
      return 'Local Folders';
    case PhotoSourceGroup.gdrive:
      return 'Google Drive';
    case PhotoSourceGroup.gmail:
      return 'Gmail';
    case PhotoSourceGroup.yahoo:
      return 'Yahoo Mail';
    case PhotoSourceGroup.outlook:
      return 'Outlook';
    case PhotoSourceGroup.other:
      return 'Other';
  }
}
