# LifeFLASH

Your personal Digital Asset Manager, digital take out tool, backup manager.

All stored locally on your machine. No ads. No tracking. No selling your data. Just you and your data.
         

# client Build

### TODO:
- Add archive for social sites
- Add Social Network Archives
  - figure out oauth plan
- Build private Social Network into app
  - research https://atproto.com/ and https://solid.mit.edu/


# Build
* Regenerate Models 
```bash
dart run build_runner build
```

* Build macos 
```bash
flutter build macos --no-tree-shake-icons --release
```

* Create DMG  
@see https://retroportalstudio.medium.com/creating-dmg-file-for-flutter-macos-apps-e448ff1cb0f

```bash
#if needed (1st time) 
npm install -g appdmg
```
```bash
cd installers/dmg_creator
```
```bash
appdmg installers/dmg_creator/config.json installers/mydata.tools.dmg
```

# Tests

* Run all tests
  ```bash
  flutter test
  ```

* Run integration tests
  ```bash
  flutter test test/integration
  ```

* Run unit tests
  ```bash
  flutter test test/unit
  ```

* Run widget tests
  ```bash
  flutter test test/widget
  ```

* Run all tests
  ```bash
  flutter test --coverage
  ```

* Generate coverage report
  ```bash
  flutter test --coverage
  genhtml coverage/lcov.info -o coverage/html
  ```   
  