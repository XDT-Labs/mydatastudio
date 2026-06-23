class AppConstants {
  static const String appName = "MyDataStudio";
  static const String configFileName = "config.json";
  static const String dbName = "mydata.db"; //sqlite

  //DB Constants
  static const int schemaVersion = 2;
  static const bool shouldDeleteIfMigrationNeeded = true;

  /// Secure Storage Keys
  static const String securePassword = "password";
  static const String secureRememberMe = "remember-me";
  static const String securePrivateKey = "private-key";
  static const String securePublicKey = "public-key";
  static const String secureStorageLocation = "storage-location";

  /// Scanner type constants — used in [Collection.scanner] and [FileSourceRegistry].
  static const String scannerEmailGmail = "email.gmail";
  static const String scannerEmailOutlook = "email.outlook";
  static const String scannerEmailOutlookPst = "email.outlook.pst";

  static const String scannerEmailYahoo = "email.yahoo";

  // File source scanners
  static const String scannerFileLocal = "file.local";
  static const String scannerFileGDrive = "file.gdrive";
  static const String scannerFileDropbox = "file.dropbox"; // future
  static const String scannerFileOneDrive = "file.onedrive"; // future
}
