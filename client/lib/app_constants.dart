class AppConstants {
  static const String appName = "MyDataStudio";
  static const String configFileName = "config.json";
  static const String dbName = "mydata.db"; //sqlite

  /// Alias of the model the client downloads at startup and uses for every
  /// on-device generation task: chat, file descriptions, and photo group
  /// labels.
  ///
  /// One constant because the alias was previously repeated at every call site,
  /// which meant upgrading the bundled model quietly left some features on the
  /// old one. Anything generating from the user's own data should name this
  /// rather than a literal, so a model upgrade is a single edit here.
  ///
  /// Note this is only the alias. The Hugging Face repo and GGUF filenames that
  /// go with it still live in `ModelDownloadManager.items` and the
  /// `aichat_models` seed in `database_manager.dart`, so a model upgrade means
  /// changing those too.
  static const String defaultChatModelAlias = 'gemma4:12b';

  //DB Constants
  static const int schemaVersion = 2;
  static const bool shouldDeleteIfMigrationNeeded = true;

  /// Secure Storage Keys
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
