import AppKit
import AuthenticationServices
import ChronoPlayCore
import SwiftUI

/// 第一次使用時的引導畫面：填 Client ID、登入。
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                VStack(spacing: 6) {
                    Text("ChronoPlay")
                        .font(.largeTitle.bold())
                    Text("把藝人的作品從最舊排到最新，一路連續播放，不會中途跳到推薦歌曲。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                AccountForm()
                    .padding(24)
                    .frame(maxWidth: 560)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Settings 視窗（⌘,）
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Spotify 帳號") {
                AccountForm()
            }
            Section {
                Picker("每次送出給播放器的歌曲數", selection: $model.windowSize) {
                    ForEach(AppModel.windowSizeOptions, id: \.self) { size in
                        Text(size == AppModel.defaultWindowSize ? "\(size) 首（預設）" : "\(size) 首").tag(size)
                    }
                }
            } header: {
                Text("進階")
            } footer: {
                Text("先送出這麼多首，播到最後一首時再把後面的歌補進佇列。設小一點（例如 3）可以快速測試補佇列是否正常。")
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Client ID、Redirect URI 與登入按鈕。引導畫面和設定共用。
private struct AccountForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @ViewState private var draftClientID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.isLoggedIn {
                HStack {
                    Label("已登入 Spotify", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("登出", role: .destructive) { model.logout() }
                }
                LabeledContent("Client ID") {
                    Text(model.clientID).textSelection(.enabled).font(.caption.monospaced())
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. 到 Spotify Developer Dashboard 建立 app（APIs 勾選 Web API）")
                    Link("打開 developer.spotify.com/dashboard", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                        .padding(.leading, 18)
                    HStack {
                        Text("2. Redirect URI 填入")
                        Text(SpotifyAuthConfig.redirectURI)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Button("拷貝", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(SpotifyAuthConfig.redirectURI, forType: .string)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                    Text("3. 把 Client ID 貼到下面，按「登入 Spotify」")
                }
                .font(.callout)

                TextField("Client ID", text: $draftClientID, prompt: Text("例如 1a2b3c4d…（32 個字元）"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit(login)

                HStack {
                    Spacer()
                    Button(action: login) {
                        if model.isLoggingIn {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("登入 Spotify", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(draftClientID.trimmingCharacters(in: .whitespaces).isEmpty || model.isLoggingIn)
                }
            }
        }
        .onAppear { draftClientID = model.clientID }
    }

    private func login() {
        model.setClientID(draftClientID)
        Task { await model.login(using: webAuthenticationSession) }
    }
}
