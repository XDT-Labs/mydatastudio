# Feature Implementation Plan: Outlook Mail Integration

## 🔍 Analysis & Context
*   **Objective:** Integrate Microsoft Outlook/Office 365 email as a new local-first, IMAP-based data source, following the pattern established by the Yahoo Mail integration.
*   **Affected Files:**
    *   `client/lib/scanners/scanner_manager.dart`
    *   `client/lib/modules/email/pages/new_email_page.dart`
    *   `client/lib/app_constants.dart` (Already contains `scannerEmailOutlook`)
    *   `plans/00_MASTER_ROADMAP.md`
*   **New Files to Create:**
    *   `client/lib/modules/email/services/scanners/outlook_scanner.dart`
    *   `client/lib/modules/email/services/scanners/outlook_scanner_isolate.dart`
    *   `client/lib/modules/email/widgets/email_setup/outlook_idle_view.dart`
    *   `client/lib/modules/email/widgets/email_setup/outlook_loading_view.dart`
    *   `client/lib/modules/email/widgets/email_setup/outlook_success_view.dart`
    *   `client/lib/modules/email/widgets/email_setup/outlook_error_view.dart`
    *   Test files corresponding to the above in `client/test/`.
*   **Key Dependencies:** `enough_mail` for IMAP communication, Dart Isolates for background processing, `Drift` for local DB persistence.
*   **Risks/Edge Cases:** Microsoft's strict App Password policies (requires 2FA enabled). App Passwords might not work if Conditional Access policies are enforced by a corporate tenant. Proper error handling for `AUTH` failures must surface these requirements.

## 📋 Micro-Step Checklist
- [x] Phase 1: Core Scanner & Isolate Logic
  - [x] Step 1.A: Create `OutlookScannerIsolate` (Status: ✅ Implemented)
  - [x] Step 1.B: Create `OutlookScanner` (Status: ✅ Implemented)
- [x] Phase 2: UI Setup Views
  - [x] Step 2.A: Create Outlook Setup State Views (Idle, Loading, Success, Error) (Status: ✅ Implemented)
- [x] Phase 3: Wire up Orchestration
  - [x] Step 3.A: Register Scanner in `ScannerManager` (Status: ✅ Implemented)
  - [x] Step 3.B: Add Outlook Tab to `NewEmailPage` (Status: ✅ Implemented)
- [x] Phase 4: Master Roadmap Update
  - [x] Step 4.A: Update `00_MASTER_ROADMAP.md` (Status: ✅ Completed)

## 📝 Step-by-Step Implementation Details

### Prerequisites
Verify that `AppConstants.scannerEmailOutlook` exists and is defined as `"email.outlook"`. It is already present in `client/lib/app_constants.dart`.

#### Phase 1: Core Scanner & Isolate Logic
1.  **Step 1.A (The Implementation): Create `OutlookScannerIsolate` [DONE]**
    *   *Target File:* `client/lib/modules/email/services/scanners/outlook_scanner_isolate.dart`
    *   *Exact Change:* Duplicate the logic from `yahoo_scanner_isolate.dart`. Rename classes to `OutlookScannerIsolate` and `OutlookScannerIsolateWorker`.
    *   *Critical Modification:* Change the IMAP connection string in `worker()`:
        ```dart
        // Connect to Microsoft/Outlook IMAP
        await client.connectToServer('outlook.office365.com', 993, isSecure: true);
        ```
    *   *Logging:* Update all logger instances to output `"OutlookScanner:"` and `"Outlook sync..."` instead of Yahoo.

2.  **Step 1.B (The Implementation): Create `OutlookScanner` [DONE]**
    *   *Target File:* `client/lib/modules/email/services/scanners/outlook_scanner.dart`
    *   *Exact Change:* Duplicate `yahoo_scanner.dart`, rename to `OutlookScanner`.
    *   *Dependencies:* Import `outlook_scanner_isolate.dart` and instantiate `OutlookScannerIsolate` inside the `start()` and `moveToTrash()` methods.

#### Phase 2: UI Setup Views
1.  **Step 2.A (The Implementation): Create Outlook Setup Views**
    *   *Target Files:*
        *   `client/lib/modules/email/widgets/email_setup/outlook_loading_view.dart`
        *   `client/lib/modules/email/widgets/email_setup/outlook_success_view.dart`
        *   `client/lib/modules/email/widgets/email_setup/outlook_error_view.dart`
    *   *Action:* Duplicate the corresponding Yahoo views and rename `Yahoo` to `Outlook`. Change any styling constants (e.g., `_yahooPurple` to `_outlookBlue = Color(0xFF0078D4)`). Change the icons to `Icons.mail` or an Outlook specific icon if available.
    *   *Target File:* `client/lib/modules/email/widgets/email_setup/outlook_idle_view.dart`
    *   *Exact Change:* Create the setup instruction widget using `StepIndicatorWidget`.
        ```dart
        // Instructions for Microsoft App Passwords:
        const StepIndicatorWidget(number: 1, text: 'Enable Two-Step Verification on your Microsoft Account.'),
        const StepIndicatorWidget(number: 2, text: 'Go to Security -> Advanced Security Options -> App passwords.'),
        const StepIndicatorWidget(number: 3, text: 'Click "Create a new app password".'),
        const StepIndicatorWidget(number: 4, text: 'Copy the generated password and paste it below.'),
        ```
    *   Update the `onLaunchSecurity` button to point to `https://account.live.com/proofs/Manage/additional`.

#### Phase 3: Wire up Orchestration
1.  **Step 3.A (The Implementation): Register Scanner in `ScannerManager`**
    *   *Target File:* `client/lib/scanners/scanner_manager.dart`
    *   *Exact Change:* Inside `_doRegisterScanner()`, add a new case to the `switch(c.scanner)` statement:
        ```dart
        case AppConstants.scannerEmailOutlook:
          logger.i("Register '${c.scanner}' scanner for ${c.name} | ${c.path}");
          SendPort emailWriterPort = await DatabaseManager.instance.writerPort;
          scanner = OutlookScanner(
            dbPath: p.join(
              DatabaseManager.instance.storagePath!,
              'data',
              AppConstants.dbName,
            ),
            collection: c,
            appDir: DatabaseManager.instance.storagePath!,
            dbWriterPort: emailWriterPort,
          );
          break;
        ```

2.  **Step 3.B (The Implementation): Add Outlook Tab to `NewEmailPage`**
    *   *Target File:* `client/lib/modules/email/pages/new_email_page.dart`
    *   *Exact Change:*
        1.  In `_NewEmailPage` state, add `Tab(icon: Icon(Icons.email), text: 'Outlook')` to the `TabBar` before `Outlook PST`.
        2.  In the `TabBarView`, add `const _OutlookTab()` to match the newly added tab.
        3.  Create the `_OutlookTab` stateful widget at the bottom of the file (replicating `_YahooTab`).
        4.  Inside `_OutlookTabState._connectOutlook()`, ensure `Collection` creation uses:
            ```dart
            scanner: AppConstants.scannerEmailOutlook,
            oauthService: 'outlook_app_password', // Custom oauth tag
            ```
        5.  Map the UI states to the newly created `OutlookIdleView`, `OutlookLoadingView`, `OutlookSuccessView`, and `OutlookErrorView`.

#### Phase 4: Master Roadmap Update
1.  **Step 4.A (The Implementation): Mark Campaign Active**
    *   *Target File:* `plans/00_MASTER_ROADMAP.md`
    *   *Exact Change:* Under "Phase 3: New Features", add the following campaign:
        ```markdown
        *   **[In Progress] Campaign: Outlook Mail Integration**
            *   **Goal:** Implement IMAP synchronization and app password authentication for Microsoft Outlook/Office 365 accounts, expanding supported cloud email providers.
            *   **Plan File:** `plans/PHASE_01_OUTLOOK_MAIL.md`
        ```

### 🧪 Global Testing Strategy
*   **Unit Tests:** Verify that UI widgets render correctly and `FormGroup` validation works (e.g., rejecting an empty password or invalid email format). Tests should be added to `client/test/modules/email/widgets/email_setup/outlook_idle_view_test.dart` and siblings.
*   **Integration Tests:** Verify that `ScannerManager` successfully resolves `AppConstants.scannerEmailOutlook` into an instance of `OutlookScanner`.

## 🎯 Success Criteria
*   User can navigate to "Add New Email" and see a distinct "Outlook" tab.
*   User can provide Outlook credentials and a Microsoft App Password, successfully saving the `Collection` into Drift DB.
*   The `OutlookScannerIsolate` initializes, connects to `outlook.office365.com:993`, and pulls folders/messages without throwing unhandled exceptions.
*   The Campaign is marked as `[In Progress]` in the `00_MASTER_ROADMAP.md` document.