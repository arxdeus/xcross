# iOS app extensions

xcross builds, embeds, signs and installs iOS **app extensions** (share
extensions, action extensions) alongside the host app, without Xcode.

This is what makes plugins like
[receive_sharing_intent](https://github.com/KasemJaffer/receive_sharing_intent)
work: the extension is what puts your app in the iOS share sheet.

---

## What works out of the box

Nothing to configure. If your Xcode project declares app-extension targets,
`xcross flutter build` and `xcross flutter run` pick them up automatically:

```
✓ Compiling Runner                      0.6s
✓ Building ActionExtension              0.5s
✓ Building Share Extension              0.5s
›  App ID       com.example.app → XCR-TEAMID.com.example.app
›  Extension    XCR-TEAMID.com.example.app.ActionExtension
›  Extension    XCR-TEAMID.com.example.app.Share-Extension
✓ Signing app                           5.0s
✓ Installing to device                  9.8s
```

For each extension target xcross:

1. reads the target out of `ios/Runner.xcodeproj/project.pbxproj` (sources,
   resources, `Info.plist`, entitlements, deployment target),
2. compiles its Swift sources against the Darwin SDK, linking the same Flutter
   plugin library the app uses, so an extension may `import` a plugin module,
3. assembles `<App>.app/PlugIns/<Name>.appex`,
4. registers a separate App ID and provisioning profile for it,
5. signs it with its own profile and entitlements.

Extension versions are forced to match the host app's, which iOS requires.

---

## Requirements

* The extension's `PRODUCT_BUNDLE_IDENTIFIER` must be **nested under the app's**
  (`com.example.app.Share-Extension` for `com.example.app`). Extensions that are
  not are skipped with a warning; iOS refuses to install them.
* Extension sources must be **Swift**. An Objective-C extension target is
  skipped with a warning; the app still builds and installs without it.
* Each extension consumes one App ID. A free Apple account is limited to
  **10 App IDs per 7 days**, and an app with two extensions uses three.

---

## App Groups (sharing data with the app)

An extension runs in its own sandbox. To hand data back to the app (the file
you shared, for example) both sides must belong to the same **App Group**.

xcross does this for you when you sign in with an **Apple ID**
(`xcross auth --apple-id <email>`). It registers the group, enables the App
Groups capability on the app's App ID and on every extension's, links the
group to each, and issues profiles carrying the resulting
`com.apple.security.application-groups` entitlement. Nothing to configure and
nothing to click on developer.apple.com.

> **With an App Store Connect API key** Apple exposes no App Groups API, so
> xcross cannot create the group for you. You can still use one you added
> yourself: see [App Store Connect API keys](#app-store-connect-api-keys)
> below.

You can confirm the entitlement landed:

```sh
xcross flutter build ios
strings "build/xcross-ios/<app>.app/PlugIns/<Name>.appex/<Name>" \
  | grep application-groups
```

### Why the group name is rewritten

App Group identifiers are globally unique across **all** Apple developers, so a
project's literal `group.com.example.Shared` is usually already taken (Apple
answers `409 not available`). xcross qualifies it per account, exactly as it
does for App IDs:

```
group.com.example.Shared → group.XCR-<TEAM>.com.example.Shared
```

Plugins read the group name at runtime from the `AppGroupId` key in
`Info.plist`, so xcross rewrites that key in the app and in every `.appex` to
match. No source changes are needed.

### App Store Connect API keys

An API key cannot *create* an App Group or attach one to an App ID. Every
route was checked against a live key:

| Route | Result |
| --- | --- |
| `GET /v1/appGroups`, `/v1/applicationGroups` | `404` — no such resource. Apple's own OpenAPI spec declares 966 paths and none mentions App Groups |
| `POST /v1/bundleIdCapabilities` `APP_GROUPS` | `201` — the capability turns on, but nothing can be linked to it |
| … with `settings[].key = APP_GROUP_IDENTIFIERS` (POST and PATCH) | `409` — only `ICLOUD_VERSION`, `DATA_PROTECTION_PERMISSION_LEVEL`, `APPLE_ID_AUTH_APP_CONSENT` are accepted |
| `POST /v1/bundleIds` with a `group.` identifier | `201` — but it is an App ID, and no relationship links it as a group |
| Profile issued with the capability on, no group | grants `com.apple.security.application-groups: []` |
| Signing a real group against that profile | installd refuses: `0xe8008015` |
| developerservices2 / portal hosts (which *do* expose App Groups) | `403`/`401` for API keys under every audience and header set tried |

**But you can still use one.** xcross reads the group out of the issued
profile rather than assuming, so a group attached to your App IDs by any other
means flows straight through:

1. Add the App Group to the app's App ID **and every extension's** — in Xcode
   (Signing & Capabilities) or at
   [developer.apple.com](https://developer.apple.com/account/resources/identifiers/list).
2. Tell xcross to use that exact group instead of qualifying its own:

```sh
XCROSS_APP_GROUP=group.com.example.Shared xcross flutter run
```

`XCROSS_APP_GROUP` skips the per-account rewrite described above, because the
group already exists and is already yours. From then on the full share flow
works on an API key.

If no group is provisioned, xcross says so once and leaves the entitlement
out, because signing with an ungranted group is what produces `0xe8008015`.
The app and its extensions still build, install and run.

### Which API this uses

With an Apple ID session, App Groups go over the pre-JSON `QH65B2` plist
protocol Xcode itself speaks:

```
ios/listApplicationGroups.action
ios/addApplicationGroup.action
ios/updateAppId.action                    (feature key APG3427HIY)
ios/assignApplicationGroupToAppId.action
```

Resource ids are shared with the JSON:API, so xcross mixes the two: App IDs and
profiles come from the modern endpoints, App Groups from these.

## Storyboards and asset catalogs

Compiling `.storyboard` and `.xcassets` requires Apple's `ibtool` and `actool`,
which are macOS-only and are not part of the Xcode SDK xcross extracts.

* **Storyboards**: an extension's `NSExtensionMainStoryboard` is replaced with
  the equivalent `NSExtensionPrincipalClass`, read from the storyboard's
  initial view controller. This is a documented, storyboard-free entry point,
  so extensions whose storyboard only instantiates a view controller (the
  normal case, and what `receive_sharing_intent` does) behave identically.
  An extension with real layout in its storyboard will lose that layout.
* **Asset catalogs**: skipped with a warning. Images from an `.xcassets` inside
  an extension will not be available.

---

## Troubleshooting

**The app installs but the extension is missing from the share sheet.**
Check that the `.appex` is present:

```sh
ls build/xcross-ios/<app>.app/PlugIns/
```

If it is missing, the target was skipped: look for a warning about the bundle
id not being nested under the app's, or about the target having no Swift
sources. Skipping is deliberate, so an extension xcross cannot build never
costs you the app build.

**`MissingBundleDisplayNameString` on install.**
The extension's `Info.plist` needs a non-empty `CFBundleDisplayName`. xcross
sets one from the target name, so this should not occur; please report it.

**The extension appears but the app never receives the shared file.**
The two are not in the same App Group. Check that the app binary and the
`.appex` both carry `com.apple.security.application-groups` with the same
value (see above). If they carry none, xcross said so during the run: either
sign in with an Apple ID, or attach a group yourself and pass
`XCROSS_APP_GROUP`.

**`Could not provision the app extension …`.**
Usually the free-account App ID quota (10 per 7 days). Either wait, or delete
unused identifiers at developer.apple.com.
