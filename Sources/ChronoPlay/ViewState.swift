import SwiftUI

/// 用 `@ViewState` 代替 `@State`。
///
/// macOS 27 SDK 裡，`@State` 會先被解析成 SwiftUI 的 macro，而這個 macro 的 plugin（SwiftUIMacros）只隨 Xcode 提供。
/// 本專案只用 Command Line Tools 建置，所以改用 typealias 直接指向原本的 property wrapper，效果完全相同。
typealias ViewState<Value> = SwiftUI.State<Value>
