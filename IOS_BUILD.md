# iPhone Build

This Flutter app already shares the Android feature code with iPhone through the `lib/` directory. AI reasoning, Gemini/OpenRouter settings, photo-based food logging, review marks, export/import, and diary storage are not Android-only.

The installable iPhone file is an `.ipa`. Apple requires that file to be built and signed with Xcode on macOS, so it cannot be produced directly from Windows.

## Build on a Mac

1. Install Xcode from the Mac App Store and open it once.
2. Install Flutter on the Mac.
3. Copy this project to the Mac.
4. Open `ios/Runner.xcworkspace` in Xcode.
5. Select `Runner`, then `Signing & Capabilities`.
6. Choose your Apple Team and make sure the bundle identifier is unique for your Apple account.
7. From the project folder, run:

```bash
flutter pub get
cd ios
pod install
cd ..
bash tool/build_ios_ipa.sh
```

The IPA will be created under:

```text
build/ios/ipa/
```

## Build with GitHub Actions

This repo includes a manual workflow at `.github/workflows/build-ios.yml`.

1. Push the project to GitHub.
2. Open the repository on GitHub.
3. Go to **Actions**.
4. Select **Build iOS IPA**.
5. Click **Run workflow**.
6. When it finishes, download the `nutrinutri-ios-unsigned-ipa` artifact.

That workflow creates:

```text
nutrinutri-ios-unsigned.ipa
```

This is similar to downloading an APK from a GitHub workflow, but it is unsigned. iPhones require Apple signing before installation on a real device, TestFlight, or the App Store.

## Notes

- For TestFlight or App Store upload, use an Apple Developer Program account.
- For installing on your own iPhone for testing, connect the device to the Mac and run `flutter run -d <device-id>` after signing is configured in Xcode.
- Camera and photo-library privacy strings are already configured in `ios/Runner/Info.plist`.
